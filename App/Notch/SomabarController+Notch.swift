import AppKit
import BarEngine
import NotchKit
import os
import SomabarCore

/// The notch surface and the notch timer, wired to the controller.
extension SomabarController {
    /// Builds the surface for the display with a camera housing, or the primary display when
    /// the drawn notch is on. Keeps a running timer across the rebuild.
    func startNotchSurface() {
        let timer = notchSurface?.timer
        notchSurface?.stop()
        notchSurface = nil
        guard let screen = Self.notchScreen(preferences: document.preferences),
              let geometry = NotchSurface.geometry(for: screen, preferences: document.preferences),
              let surface = NotchSurface(screen: screen, geometry: geometry, controller: self)
        else {
            log.info("No notch surface (surface on: \(self.document.preferences.notchSurface), drawn notch: \(self.document.preferences.drawnNotch))")
            return
        }
        surface.start()
        notchSurface = surface
        // Before adopting the timer, so the timer arrives as an activity.
        activities.attach(surface)
        if let timer {
            surface.adopt(timer)
        }
    }

    /// At quit: the surface and the activities feeding it.
    func stopNotchSurface() {
        stopMenuBarStyle()
        activities.stop()
        notchSurface?.stop()
        notchSurface = nil
        activities.attach(nil)
    }

    /// The notch surface lives on the built-in display: around its camera, or drawn when it has
    /// none and the drawn notch is on. External displays never get one while the built-in
    /// display is on; a Mac without one (a desktop, or a laptop with its lid closed) gets the
    /// drawn notch on the primary display.
    private static func notchScreen(preferences: Preferences) -> NSScreen? {
        ScreenGeometry.builtInScreen ?? ScreenGeometry.primaryScreen
    }

    // MARK: - Activities

    /// One per app, like the controller. Kept outside the controller's body, which is at
    /// SwiftLint's length limit.
    static let activityCenter = ActivityCenter()

    /// `App/Notch/Activities/`: the notch's live activities.
    var activities: ActivityCenter { Self.activityCenter }

    /// Starts the live activities and feeds them the context and the active profile. Runs from
    /// `startDisplayRules`, before the surface exists; `startNotchSurface` attaches it.
    func startActivities() {
        activities.settings = { [weak self] in self?.document.active.notch ?? .everyday }
        activities.profiles = { [weak self] in
            (self?.document.activeProfile ?? "", self?.document.profileBeforeTriggers)
        }
        activities.switchProfile = { [weak self] name in self?.switchProfile(to: name) }
        context.onSnapshotChange = { [weak self] reason in
            guard let self else { return }
            self.activities.contextChanged(self.context.snapshot)
            // The active display may have moved (an app on another display came forward).
            self.evaluateDisplayRules(reason: reason)
        }
        activities.start(snapshot: context.snapshot)
        activities.attach(notchSurface)
        activities.agents.setReplies(document.preferences.agentReplies)
        activities.agents.setListening(document.preferences.agentSocket)
    }

    /// `somabar://agent?session=…&state=…`: a coding agent's report (N11).
    func handleAgentURL(_ url: URL) {
        activities.agents.receive(url: url)
    }

    /// New items noticed by a scan pulse the notch.
    func pulseNotchForNewItems(_ keys: [ItemKey]) {
        guard let notchSurface, let first = keys.first else { return }
        let text = keys.count == 1 ? "New item: \(Self.appName(forBundleID: first.bundleID))" : "\(keys.count) new items"
        notchSurface.pulse(text: text)
    }

    static func appName(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: - Timer

    func startNotchTimer(minutes: Int) {
        guard let notchSurface else {
            log.notice("No notch surface to run the timer in; turn on notchSurface, or drawnNotch on a display without a notch")
            return
        }
        notchSurface.startTimer(minutes: minutes)
    }

    /// `somabar://timer?25` starts 25 minutes, `somabar://timer?stop` stops; no query is 25.
    func handleTimerURL(_ url: URL) {
        let query = url.query(percentEncoded: false)?.lowercased() ?? ""
        if query == "stop" || query == "cancel" {
            notchSurface?.cancelTimer()
        } else if query.isEmpty {
            startNotchTimer(minutes: 25)
        } else if let minutes = Int(query), (1...600).contains(minutes) {
            startNotchTimer(minutes: minutes)
        } else {
            log.error("somabar://timer takes minutes or stop: \(url.absoluteString, privacy: .public)")
        }
    }

    // MARK: - Display rules (M12)

    static let displayLog = Logger(subsystem: "app.somabar", category: "Displays")

    /// The width the rules look at: the active display's, or the widest one's when inactive
    /// displays are not left alone (`DisplayRules.evaluatedWidthPoints`).
    var displayRuleWidthPoints: Double {
        document.preferences.displayRules.evaluatedWidthPoints(in: context.snapshot)
    }

    func startDisplayRules() {
        context.onDisplaysChanged = { [weak self] in self?.displaysChanged() }
        startActivities()
        evaluateDisplayRules(reason: "launch")
        applyMenuBarStyle()
    }

    func displaysChanged() {
        evaluateDisplayRules(reason: "displays changed")
        applyMenuBarStyle()
        // The notification also fires for changes that leave the notch where it was.
        if let current = notchSurface, let screen = Self.notchScreen(preferences: document.preferences),
           screen.frame == current.screenFrame,
           NotchSurface.geometry(for: screen, preferences: document.preferences) == current.geometry {
            return
        }
        startNotchSurface()
    }

    /// Logs the show-everything decision when it changes and rescans so the bar follows.
    /// `effectiveLayout` applies the rule itself, so this only reports and nudges.
    func evaluateDisplayRules(reason: String) {
        let width = displayRuleWidthPoints
        let rules = document.preferences.displayRules
        let showsEverything = rules.showsEverything(screenWidthPoints: width)
        guard showsEverything != displayRuleDecision else { return }
        let isFirst = displayRuleDecision == nil
        displayRuleDecision = showsEverything
        let threshold = rules.showEverythingAbovePoints.map { "\($0) pt" } ?? "off"
        let effect = showsEverything ? "showing Hidden and Tucked items" : "layout as stored"
        let display = rules.leaveInactiveDisplaysUntouched ? "Active" : "Widest"
        let decision = "\(display) display \(Int(width)) pt, show all above \(threshold)"
        Self.displayLog.notice("\(decision, privacy: .public) (\(reason, privacy: .public)): \(effect, privacy: .public)")
        guard !isFirst else { return }
        abandonReconcile(reason: "display rules")
        scanNow(reason: "display rules")
    }
}
