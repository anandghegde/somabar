import AppKit
import ApplicationServices
import BarEngine
import os
import SomabarCore

/// Feeds pointer, click and scroll events on the menu bar to the gesture recognizer (M2).
///
/// A global monitor sees other apps' events; a local one sees Somabar's own, which is where
/// hovers and scrolls over the collapsed dividers arrive. Neither needs a permission. Clicks on
/// Somabar's own windows are button actions (the glyph, or a divider via `clickOnEmptyBar`),
/// so the local monitor leaves clicks alone.
@MainActor
final class GestureMonitor {
    static let windowCacheSeconds: TimeInterval = 0.3
    /// A click that opened a menu shows the menu within this time.
    static let menuCheckDelay: Duration = .milliseconds(150)

    var onAction: (@MainActor (RevealGestureRecognizer.Action) -> Void)?
    var isRevealed: @MainActor () -> Bool = { false }

    private let engine: any BarEngine
    private var recognizer: RevealGestureRecognizer
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var cachedWindows: [StatusWindow] = []
    private var cachedWindowsAt: TimeInterval = -1
    /// Right edge of each app's menu titles, measured through Accessibility when it activates.
    private var appMenusMaxX: [pid_t: CGFloat] = [:]
    private let log = Logger(subsystem: "app.somabar", category: "Gestures")

    init(engine: any BarEngine, gestures: RevealGestures) {
        self.engine = engine
        recognizer = RevealGestureRecognizer(gestures: gestures)
    }

    var gestures: RevealGestures {
        get { recognizer.gestures }
        set { recognizer.gestures = newValue }
    }

    func start() {
        guard monitors.isEmpty else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp, .scrollWheel]) { event in
            MainActor.assumeIsolated { GestureMonitor.shared?.handle(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { event in
            MainActor.assumeIsolated { GestureMonitor.shared?.handle(event) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
        Self.shared = self
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        if let front = NSWorkspace.shared.frontmostApplication {
            measureAppMenus(of: front.processIdentifier)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        hoverTask?.cancel()
        hoverTask = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if Self.shared === self {
            Self.shared = nil
        }
    }

    /// A click on the empty bar, from the global monitor or one of Somabar's collapsed dividers.
    /// The recognizer decides on the state at the click; the action waits for the menu check.
    func clickOnEmptyBar() {
        log.info("Click on the empty bar; gesture on: \(self.recognizer.gestures.clickEmptyBar)")
        guard !ItemMover.isMoving else { return }
        guard let action = recognizer.click(onEmptyBar: true, revealed: isRevealed()) else { return }
        syncHoverTask()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.menuCheckDelay)
            guard let self else { return }
            guard !MenuWatcher.anyMenuOpen() else {
                self.log.info("The click opened a menu; ignoring it")
                return
            }
            self.fire(action, from: "click")
        }
    }

    // MARK: - Events

    /// The monitor blocks are plain (not `@Sendable`) and run on the main thread; they reach the
    /// monitor through this rather than capturing it.
    private static weak var shared: GestureMonitor?

    private func handle(_ event: NSEvent) {
        guard !ItemMover.isMoving else { return }
        let appKitPoint = NSEvent.mouseLocation
        let point = ScreenGeometry.topLeft(appKitPoint)
        let now = ProcessInfo.processInfo.systemUptime
        let bar = ScreenGeometry.screen(containingAppKitPoint: appKitPoint).map(ScreenGeometry.menuBarRect(of:))
        let onBar = bar.map { $0.contains(point) } ?? false

        switch event.type {
        case .mouseMoved:
            guard recognizer.gestures.hoverEmptyBar else { return }
            let spot: RevealGestureRecognizer.PointerSpot
            if let bar, onBar {
                spot = isEmptyBar(point, bar: bar) ? .emptyBar : .item
            } else {
                spot = .offBar
            }
            recognizer.pointerMoved(to: spot, revealed: isRevealed(), at: now)
            syncHoverTask()
        case .leftMouseUp:
            guard onBar, let bar else { return }
            let empty = isEmptyBar(point, bar: bar)
            log.info("Click on the bar at x=\(Int(point.x)) from another app; empty: \(empty)")
            guard empty else { return }
            clickOnEmptyBar()
        case .scrollWheel:
            guard onBar else { return }
            if let action = recognizer.scroll(deltaY: event.scrollingDeltaY, at: now, revealed: isRevealed()) {
                fire(action, from: "scroll")
            }
        default:
            break
        }
    }

    private func syncHoverTask() {
        guard let deadline = recognizer.hoverDeadline else {
            hoverTask?.cancel()
            hoverTask = nil
            return
        }
        guard hoverTask == nil else { return }
        let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.hoverTask = nil
            if let action = self.recognizer.tick(at: ProcessInfo.processInfo.systemUptime) {
                self.fire(action, from: "hover")
            }
        }
    }

    private func fire(_ action: RevealGestureRecognizer.Action, from gesture: String) {
        log.info("Gesture \(gesture, privacy: .public): \(String(describing: action), privacy: .public)")
        onAction?(action)
    }

    // MARK: - Hit testing

    private func isEmptyBar(_ point: CGPoint, bar: CGRect) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - cachedWindowsAt > Self.windowCacheSeconds {
            cachedWindows = StatusWindows.current(excludingPID: ProcessInfo.processInfo.processIdentifier)
            cachedWindowsAt = now
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let menusMaxX = front.flatMap { appMenusMaxX[$0] } ?? bar.midX
        log.debug("Hit test at x=\(Int(point.x)): app menus end at \(Int(menusMaxX)), \(self.cachedWindows.count) status windows")
        return EmptyBarHitTest.isEmpty(
            point: point, bar: bar, statusWindows: cachedWindows, ownFrames: engine.ownFrames, appMenusMaxX: menusMaxX
        )
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        measureAppMenus(of: app.processIdentifier)
    }

    /// Without trust the right half of the bar is assumed free of app menus.
    private func measureAppMenus(of pid: pid_t) {
        guard appMenusMaxX[pid] == nil, AXIsProcessTrusted() else { return }
        Task { @MainActor [weak self] in
            let maxX = await Task.detached { AccessibilityDiscovery.appMenusMaxX(forPID: pid) }.value
            guard let maxX else { return }
            self?.appMenusMaxX[pid] = maxX
        }
    }
}
