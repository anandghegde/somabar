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
    /// Expanded grows by one row per live activity, up to this many (`ActivityCenter`).
    static let maxActivityRows = 2
    static let activityRowHeight: CGFloat = 54
    /// The Hidden items row and the spacing above it, left out when the profile turns it off.
    static let hiddenRowHeight: CGFloat = 28
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
    /// Set by `ActivityCenter`: the timer is one activity among others, so its changes go there
    /// and the center tells the machine when Compact starts and ends.
    var onTimerChanged: (@MainActor () -> Void)?
    /// Something is drawn in Compact (`showActivities`).
    private var hasCompactActivity = false
    /// Compact is widened into the drop target (N5).
    private var widensCompact = false

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
              let expanded = geometry.expandedFrame(size: Self.expandedSize(rows: Self.maxActivityRows, linesHeight: ActivityRow.maxLinesHeight))
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
    func pulse(text: String, symbol: String = "bell.fill", level: Double? = nil) {
        model.pulseText = text
        model.pulseSymbol = symbol
        model.pulseLevel = level
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
        // A file dragged over the notch is dropped on it, not hovered open.
        guard !widensCompact else { return }
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
        case .compact where widensCompact: geometry.compactFrame(extensionPerSide: NotchGeometry.maxCompactExtensionPerSide)
        case .compact: geometry.compactFrame(extensionPerSide: geometry.isDrawn ? 0 : Self.compactExtension)
        case .pulse: geometry.compactFrame(extensionPerSide: NotchGeometry.maxCompactExtensionPerSide)
        case .expanded: geometry.expandedFrame(size: expandedPanelSize)
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

    /// Expanded as the model has it: its activity rows, and the Hidden items row when shown.
    private var expandedPanelSize: CGSize {
        let size = Self.expandedSize(rows: model.activities)
        return model.showsHidden ? size : CGSize(width: size.width, height: size.height - Self.hiddenRowHeight)
    }

    /// Expanded with room for the rows it shows and their lines.
    private static func expandedSize(rows: [ActivityRow]) -> CGSize {
        let shown = rows.prefix(maxActivityRows)
        return expandedSize(rows: shown.count, linesHeight: shown.reduce(0) { $0 + $1.linesHeight })
    }

    /// Expanded with room for `rows` activity rows and `linesHeight` of lines under them.
    private static func expandedSize(rows: Int, linesHeight: CGFloat) -> CGSize {
        let rows = min(max(rows, 0), maxActivityRows)
        return CGSize(width: expandedSize.width, height: expandedSize.height + CGFloat(rows) * activityRowHeight + linesHeight)
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
        model.showsHidden = controller.document.active.notch.enabledActivities.contains(.hiddenItemsTray)
    }

    private func switchProfile(to name: String) {
        controller?.switchProfile(to: name)
        refreshPanel()
        // The new profile may show or leave out the Hidden items row, which changes the height.
        if machine.state == .expanded, let target = shapeFrame(for: .expanded).map(local) {
            withAnimation(.easeInOut(duration: 0.2)) { model.shapeRect = target }
        }
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
        if onTimerChanged == nil {
            send(.activityStarted)
        }
        updateTimerText()
        if timer.isRunning { startTicking() }
    }

    private func apply(_ events: [NotchEvent]) {
        updateTimerText()
        // With the activity center wired, it decides what Compact shows.
        guard onTimerChanged == nil else { return }
        for event in events {
            send(event)
        }
    }

    private func updateTimerText() {
        model.timerText = timer.isActive ? timer.display(at: Self.clock) : nil
        model.timerPaused = timer.isPaused
        onTimerChanged?()
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

// MARK: - Activities

extension NotchSurface {
    /// What `ActivityCenter` picked: the Compact winner and the rows for Expanded. Tells the
    /// machine when Compact starts or ends; a change of winner cross-fades.
    func showActivities(compact: CompactPresentation?, rows: [ActivityRow], widened: Bool) {
        let winnerChanged = model.compact?.kind != compact?.kind
        // A download starting or ending changes the lines, and with them the height.
        let rowsChanged = model.activities.map(\.id) != rows.map(\.id)
            || model.activities.map(\.linesHeight) != rows.map(\.linesHeight)
        if winnerChanged || rowsChanged {
            let animation: Animation = stillMode ? .easeInOut(duration: 0.2) : .spring(response: Self.animationSeconds, dampingFraction: 0.82)
            withAnimation(animation) {
                model.compact = compact
                model.activities = rows
            }
        } else {
            // A tick: the text changes in place.
            withTransaction(Transaction(animation: nil)) {
                model.compact = compact
                model.activities = rows
            }
        }
        let hadCompact = hasCompactActivity
        let wasWidened = widensCompact
        hasCompactActivity = compact != nil
        widensCompact = widened
        if hasCompactActivity != hadCompact {
            send(hasCompactActivity ? .activityStarted : .activityEnded)
        } else if (wasWidened != widened && machine.state == .compact) || (rowsChanged && machine.state == .expanded) {
            present()
        }
    }

    /// The widened Compact shape in AppKit coordinates, with some room below it so a drop just
    /// under the menu bar still lands: where `DropToShareWatcher` puts its target.
    var dropTargetFrame: CGRect? {
        guard let shape = geometry.compactFrame(extensionPerSide: NotchGeometry.maxCompactExtensionPerSide) else { return nil }
        let target = CGRect(x: shape.minX, y: shape.minY, width: shape.width, height: shape.height + Self.dropTargetSlack)
        return CGRect(x: screenFrame.minX + target.minX, y: screenFrame.maxY - target.maxY, width: target.width, height: target.height)
    }

    static let dropTargetSlack: CGFloat = 24
}
