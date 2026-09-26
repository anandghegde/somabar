import AppKit
import BarEngine
import NotchKit
import os
import SomabarCore
import SwiftUI

/// The notch surface: draws `NotchMachine`'s states around the camera housing, or around a drawn
/// notch on a display without one.
///
/// The machine decides; this feeds it pointer and click events, runs the timers it asks for, and
/// owns the notch timer, the one activity so far. All geometry here is in the screen's points
/// with the origin at its top-left corner, like `NotchGeometry`.
@MainActor
final class NotchSurface: NSObject {
    /// Posted by the trigger runtime with `userInfo["names"]` as `[String]`.
    static let triggerFiredNotification = Notification.Name("app.somabar.triggerFired")
    /// Beside a real camera: room for the timer on each side.
    static let compactExtension: CGFloat = 56
    static let expandedSize = CGSize(width: 460, height: 180)
    static let animationSeconds = 0.35
    /// A little slack so a pointer on the panel's edge does not count as leaving.
    static let leaveSlack: CGFloat = 4

    let geometry: NotchGeometry
    let screenFrame: CGRect

    private weak var controller: SomabarController?
    private let model = NotchModel()
    private let window: NotchWindow
    /// The window's frame in screen coordinates; every state's shape fits inside it.
    private let canvas: CGRect
    private var machine = NotchMachine()
    private var hover = HoverIntentDetector()
    private(set) var timer = NotchTimer()
    private var machineTasks: [NotchMachineTimer: Task<Void, Never>] = [:]
    private var tickTask: Task<Void, Never>?
    private var presentTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var pointerInsideExpanded = false
    private let log = Logger(subsystem: "app.somabar", category: "Notch")

    /// The surface for this screen, or nil when there is none to draw: the preference is off,
    /// or the display has no notch and the drawn one is off.
    static func geometry(for screen: NSScreen, preferences: Preferences) -> NotchGeometry? {
        guard preferences.notchSurface else { return nil }
        let hardware = ScreenGeometry.notchGeometry(for: screen)
        if hardware.hasSurface { return hardware }
        guard preferences.drawnNotch else { return nil }
        return .drawn(screenWidth: screen.frame.width, menuBarHeight: ScreenGeometry.menuBarHeight(of: screen))
    }

    init?(screen: NSScreen, geometry: NotchGeometry, controller: SomabarController) {
        guard let notch = geometry.notch,
              let widest = geometry.compactFrame(extensionPerSide: NotchGeometry.maxCompactExtensionPerSide),
              let expanded = geometry.expandedFrame(size: Self.expandedSize)
        else { return nil }
        self.geometry = geometry
        self.controller = controller
        screenFrame = screen.frame
        canvas = widest.union(expanded).union(notch)
        window = NotchWindow(frame: Self.appKit(canvas, screenFrame: screen.frame), model: model)
        super.init()
        let camera = geometry.isDrawn ? CGRect(x: notch.midX, y: notch.minY, width: 0, height: notch.height) : notch
        model.cameraRect = local(camera)
        model.shapeRect = seedRect
        model.actions = NotchActions(
            click: { [weak self] in self?.send(.click) },
            switchProfile: { [weak self] name in self?.switchProfile(to: name) },
            revealHidden: { [weak self] in self?.controller?.reveal(includingTucked: false) },
            startTimer: { [weak self] minutes in self?.startTimer(minutes: minutes) },
            cancelTimer: { [weak self] in self?.cancelTimer() },
            togglePause: { [weak self] in self?.togglePause() }
        )
    }

    func start() {
        guard monitors.isEmpty else { return }
        Self.shared = self
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { NotchSurface.shared?.pointerMoved() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            MainActor.assumeIsolated { NotchSurface.shared?.pointerMoved() }
            return event
        }
        monitors = [global, local].compactMap { $0 }
        NotificationCenter.default.addObserver(
            self, selector: #selector(triggerFired(_:)), name: Self.triggerFiredNotification, object: nil)
        let kind = geometry.isDrawn ? "drawn" : "camera"
        let notch = geometry.notch ?? .zero
        log.notice("Notch surface up (\(kind, privacy: .public) notch at x=\(Int(notch.minX)), \(Int(notch.width)) pt wide)")
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        NotificationCenter.default.removeObserver(self, name: Self.triggerFiredNotification, object: nil)
        for task in machineTasks.values {
            task.cancel()
        }
        machineTasks = [:]
        tickTask?.cancel()
        presentTask?.cancel()
        window.orderOut(nil)
        window.close()
        if Self.shared === self {
            Self.shared = nil
        }
    }

    // MARK: - Events

    /// A one-off event: the notch shows `text` for 2 s.
    func pulse(text: String) {
        model.pulseText = text
        log.info("Pulse: \(text, privacy: .public)")
        send(.oneOffEvent)
    }

    private func send(_ event: NotchEvent) {
        let before = machine.state
        let effects = machine.handle(event)
        run(effects)
        guard machine.state != before else { return }
        log.debug("Notch \(String(describing: before), privacy: .public) → \(String(describing: self.machine.state), privacy: .public)")
        if machine.state == .expanded {
            refreshPanel()
        } else {
            pointerInsideExpanded = false
            hover.reset()
        }
        present()
    }

    private func run(_ effects: [NotchEffect]) {
        for effect in effects {
            switch effect {
            case .start(let which, let seconds):
                machineTasks[which]?.cancel()
                machineTasks[which] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled, let self else { return }
                    self.machineTasks[which] = nil
                    self.send(which == .pulse ? .pulseElapsed : .leaveElapsed)
                }
            case .cancel(let which):
                machineTasks[which]?.cancel()
                machineTasks[which] = nil
            }
        }
    }

    /// The monitor blocks are plain (not `@Sendable`) and run on the main thread; they reach the
    /// surface through this rather than capturing it, as `GestureMonitor` does.
    private static weak var shared: NotchSurface?

    private func pointerMoved() {
        let appKitPoint = NSEvent.mouseLocation
        let point = CGPoint(x: appKitPoint.x - screenFrame.minX, y: screenFrame.maxY - appKitPoint.y)
        if machine.state == .expanded {
            let inside = (shapeFrame(for: .expanded)?.insetBy(dx: -Self.leaveSlack, dy: -Self.leaveSlack).contains(point)) ?? false
            if inside != pointerInsideExpanded {
                pointerInsideExpanded = inside
                send(inside ? .pointerReturned : .pointerLeft)
            }
        } else {
            // Idle has no shape: the notch itself is the area.
            let area = shapeFrame(for: machine.state) ?? geometry.compactFrame(extensionPerSide: 0) ?? .zero
            let sample = PointerSample(point: point, time: ProcessInfo.processInfo.systemUptime)
            if hover.feed(sample, inside: area.contains(point)) {
                pointerInsideExpanded = true
                send(.hoverIntent)
            }
        }
        updateMouseAcceptance(pointer: point)
    }

    /// Clicks go through the transparent canvas to whatever is under it.
    private func updateMouseAcceptance(pointer: CGPoint) {
        let onShape = window.isVisible && (shapeFrame(for: machine.state)?.contains(pointer) ?? false)
        if window.ignoresMouseEvents == onShape {
            window.ignoresMouseEvents = !onShape
        }
    }

    @objc private func triggerFired(_ notification: Notification) {
        let names = notification.userInfo?["names"] as? [String] ?? []
        guard !names.isEmpty else { return }
        pulse(text: names.joined(separator: ", "))
    }

    // MARK: - Drawing

    /// The shape for a state in screen coordinates; nil for idle.
    private func shapeFrame(for state: NotchState) -> CGRect? {
        switch state {
        case .idle: nil
        // A drawn notch has room inside it; a real one needs the sides.
        case .compact: geometry.compactFrame(extensionPerSide: geometry.isDrawn ? 0 : Self.compactExtension)
        case .pulse: geometry.compactFrame(extensionPerSide: NotchGeometry.maxCompactExtensionPerSide)
        case .expanded: geometry.expandedFrame(size: Self.expandedSize)
        }
    }

    /// Where a shape grows from and shrinks back to: the camera housing. A drawn notch fades
    /// instead, so it starts at its full size.
    private var seedRect: CGRect {
        guard !geometry.isDrawn, let notch = geometry.notch else {
            return local(geometry.compactFrame(extensionPerSide: 0) ?? .zero)
        }
        return local(notch)
    }

    private var stillMode: Bool {
        controller?.document.preferences.stillMode ?? false
    }

    /// Moves the drawing to the machine's state: a spring, or a plain fade in Still Mode. Idle
    /// hides the window once the shape has gone.
    private func present() {
        presentTask?.cancel()
        presentTask = nil
        let still = stillMode
        let animation: Animation = still ? .easeInOut(duration: 0.2) : .spring(response: Self.animationSeconds, dampingFraction: 0.82)
        let state = machine.state

        guard let target = shapeFrame(for: state).map(local) else {
            guard window.isVisible else { return }
            window.ignoresMouseEvents = true
            withAnimation(animation) {
                if !still { model.shapeRect = seedRect }
                model.opacity = 0
            }
            presentTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.animationSeconds))
                guard !Task.isCancelled, let self else { return }
                self.window.orderOut(nil)
                self.model.displayedState = .idle
                self.model.shapeRect = self.seedRect
            }
            return
        }

        if !window.isVisible || still {
            // Start from the seed (or, in Still Mode, from nothing) and let one frame draw it
            // before animating; SwiftUI would otherwise only see the end state.
            withTransaction(Transaction(animation: nil)) {
                model.displayedState = state
                model.shapeRect = still ? target : seedRect
                model.opacity = still && window.isVisible ? 0.3 : 0
            }
            window.orderFrontRegardless()
            presentTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                withAnimation(animation) {
                    self.model.shapeRect = target
                    self.model.opacity = 1
                }
            }
            return
        }

        withAnimation(animation) {
            model.displayedState = state
            model.shapeRect = target
            model.opacity = 1
        }
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
    }

    /// Screen coordinates (top-left origin) to AppKit's global ones.
    private static func appKit(_ rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + rect.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Expanded panel

    /// Reads the profiles and the Hidden section when the panel opens.
    private func refreshPanel() {
        guard let controller else { return }
        model.profiles = controller.document.profiles.map(\.name)
        model.activeProfile = controller.document.activeProfile
        let hidden = controller.effectiveLayout.hidden
        var seen: Set<String> = []
        let bundleIDs = hidden.map(\.bundleID).filter { seen.insert($0).inserted }
        model.hiddenIcons = bundleIDs.compactMap(Self.icon(forBundleID:))
        model.hiddenCount = hidden.count
    }

    private func switchProfile(to name: String) {
        controller?.switchProfile(to: name)
        refreshPanel()
    }

    private static func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Timer

    private static var clock: Double {
        Date().timeIntervalSinceReferenceDate
    }

    func startTimer(minutes: Int) {
        apply(timer.start(seconds: Double(minutes) * 60, at: Self.clock))
        log.notice("Timer started: \(minutes) min")
        startTicking()
    }

    func cancelTimer() {
        guard timer.isActive else { return }
        apply(timer.cancel())
        tickTask?.cancel()
        log.notice("Timer cancelled")
    }

    private func togglePause() {
        if timer.isPaused {
            timer.resume(at: Self.clock)
            startTicking()
        } else {
            timer.pause(at: Self.clock)
            tickTask?.cancel()
        }
        updateTimerText()
    }

    /// Takes over a timer from the surface this one replaces.
    func adopt(_ other: NotchTimer) {
        guard other.isActive else { return }
        timer = other
        send(.activityStarted)
        updateTimerText()
        if timer.isRunning { startTicking() }
    }

    private func apply(_ events: [NotchEvent]) {
        updateTimerText()
        for event in events {
            send(event)
        }
    }

    private func updateTimerText() {
        model.timerText = timer.isActive ? timer.display(at: Self.clock) : nil
        model.timerPaused = timer.isPaused
    }

    /// Wakes when the m:ss display changes, and once more at zero.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while let self, self.timer.isRunning, !Task.isCancelled {
                let remaining = self.timer.remaining(at: Self.clock)
                let fraction = remaining - remaining.rounded(.down)
                try? await Task.sleep(for: .seconds(fraction > 0.01 ? fraction : 1))
                guard !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let ended = timer.tick(at: Self.clock)
        apply(ended)
        guard !ended.isEmpty else { return }
        log.notice("Timer finished")
        pulse(text: "Time's up")
    }
}
