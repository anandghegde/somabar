import AppKit
import Observation
import os
import Sparkle

/// Sparkle 2 updates. The update check is the only network call Somabar makes, so nothing
/// starts unless the build carries both a feed URL and a public EdDSA key, and automatic checks
/// can be turned off in Settings › General. Sparkle keeps that choice in its own defaults.
@Observable
@MainActor
final class UpdateController {
    static let shared = UpdateController()
    static let notConfiguredNote = "Updates are not configured in this build."

    /// Both `SUFeedURL` and `SUPublicEDKey` are present and non-empty in Info.plist.
    let isConfigured: Bool
    /// Mirrors the updater's setting, which Sparkle's first-launch question can also change.
    private(set) var automaticallyChecks = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private let log = Logger(subsystem: "app.somabar", category: "Updates")

    init(bundle: Bundle = .main) {
        isConfigured = Self.hasValue("SUFeedURL", in: bundle) && Self.hasValue("SUPublicEDKey", in: bundle)
    }

    private static func hasValue(_ key: String, in bundle: Bundle) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both come from build settings (Config/Somabar.xcconfig); an unexpanded one is unset.
        return !trimmed.isEmpty && !trimmed.hasPrefix("$(")
    }

    // MARK: Lifecycle

    /// Called once at launch. Without a feed and key it does nothing and touches no network.
    func start() {
        guard controller == nil else { return }
        guard isConfigured else {
            log.notice("Updates are off: this build has no SUFeedURL or SUPublicEDKey")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
            guard let isOn = change.newValue else { return }
            Task { @MainActor in self?.automaticallyChecks = isOn }
        }
        log.notice("Updater started; automatic checks \(self.automaticallyChecks ? "on" : "off", privacy: .public)")
    }

    // MARK: Actions

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates() {
        guard let controller else { return }
        log.notice("Checking for updates")
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ isOn: Bool) {
        guard let controller else { return }
        controller.updater.automaticallyChecksForUpdates = isOn
        automaticallyChecks = isOn
        log.notice("Automatic update checks \(isOn ? "on" : "off", privacy: .public)")
    }
}

// MARK: - Controller wiring

extension SomabarController {
    func startUpdates() {
        UpdateController.shared.start()
    }

    /// "Check for Updates…" in the glyph menu, just above Settings. Without an action the menu
    /// shows it disabled, which is how it looks when updates are not configured or busy.
    func addUpdatesItem(to menu: NSMenu) {
        let updates = UpdateController.shared
        let item = menu.addItem(withTitle: "Check for Updates…", action: nil, keyEquivalent: "")
        if updates.canCheckForUpdates {
            item.action = #selector(checkForUpdatesAction)
        } else if !updates.isConfigured {
            item.toolTip = UpdateController.notConfiguredNote
        }
    }

    @objc func checkForUpdatesAction() {
        UpdateController.shared.checkForUpdates()
    }
}
