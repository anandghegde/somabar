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
        if let timer {
            surface.adopt(timer)
        }
        notchSurface = surface
    }

    func stopNotchSurface() {
        notchSurface?.stop()
        notchSurface = nil
    }

    /// The built-in display when it has a notch; otherwise the primary display, which only gets
    /// a surface with the drawn notch on.
    private static func notchScreen(preferences: Preferences) -> NSScreen? {
        if let builtIn = ScreenGeometry.builtInScreen, ScreenGeometry.notchGeometry(for: builtIn).hasSurface {
            return builtIn
        }
        return ScreenGeometry.primaryScreen
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

    /// Somabar manages the primary display's bar only; the rules look at it.
    static var primaryDisplayWidthPoints: Double {
        Double(ScreenGeometry.primaryScreen?.frame.width ?? 0)
    }

    func startDisplayRules() {
        context.onDisplaysChanged = { [weak self] in self?.displaysChanged() }
        evaluateDisplayRules(reason: "launch")
    }

    func displaysChanged() {
        evaluateDisplayRules(reason: "displays changed")
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
        let width = Self.primaryDisplayWidthPoints
        let rules = document.preferences.displayRules
        let showsEverything = rules.showsEverything(screenWidthPoints: width)
        guard showsEverything != displayRuleDecision else { return }
        let isFirst = displayRuleDecision == nil
        displayRuleDecision = showsEverything
        let threshold = rules.showEverythingAbovePoints.map { "\($0) pt" } ?? "off"
        let effect = showsEverything ? "showing Hidden and Tucked items" : "layout as stored"
        Self.displayLog.notice(
            "Primary display \(Int(width)) pt, show all above \(threshold, privacy: .public) (\(reason, privacy: .public)): \(effect, privacy: .public)"
        )
        guard !isFirst else { return }
        abandonReconcile(reason: "display rules")
        scanNow(reason: "display rules")
    }
}
