import AppKit
import CoreFoundation
import os
import SomabarCore

/// M10: writes the per-host global defaults macOS reads when an app creates its status items.
/// Only apps started afterwards pick the values up; a log-out applies them to every item.
@MainActor
enum StatusItemSpacing {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"
    private static let log = Logger(subsystem: "app.somabar", category: "Spacing")

    // MARK: Reading

    static var currentSpacing: Int? { read(spacingKey) }
    static var currentPadding: Int? { read(paddingKey) }

    private static func read(_ key: String) -> Int? {
        let value = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (value as? NSNumber)?.intValue
    }

    // MARK: Writing

    /// Makes the defaults match `spacing`. Default removes the keys, but only when they hold
    /// values Somabar writes, so a value the person set by hand is left alone.
    static func apply(_ spacing: Spacing, reason: String) {
        let spacingNow = currentSpacing
        let paddingNow = currentPadding
        if spacing == .default {
            guard spacingNow != nil || paddingNow != nil else { return }
            guard Spacing.isSomabarValue(spacing: spacingNow, padding: paddingNow) else {
                let found = describe(spacingNow, paddingNow)
                log.notice("Left item spacing alone (\(reason, privacy: .public)): \(found, privacy: .public) was not set by Somabar")
                return
            }
        } else if spacingNow == spacing.statusItemSpacing, paddingNow == spacing.selectionPadding {
            return
        }
        write(spacingKey, spacing.statusItemSpacing)
        write(paddingKey, spacing.selectionPadding)
        let synced = CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let result = describe(spacing.statusItemSpacing, spacing.selectionPadding)
        if synced {
            log.notice("Item spacing set to \(spacing.rawValue, privacy: .public), \(result, privacy: .public) (\(reason, privacy: .public))")
        } else {
            log.error("Could not save item spacing \(spacing.rawValue, privacy: .public) (\(reason, privacy: .public))")
        }
    }

    /// M19: on quit, spacing goes back to the system default.
    static func restoreSystemDefault(reason: String) {
        apply(.default, reason: reason)
    }

    private static func write(_ key: String, _ value: Int?) {
        let number = value.map { NSNumber(value: $0) }
        CFPreferencesSetValue(key as CFString, number, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    private static func describe(_ spacing: Int?, _ padding: Int?) -> String {
        guard let spacing, let padding else { return "system default" }
        return "spacing \(spacing) pt, padding \(padding) pt"
    }
}

// MARK: - Controller wiring

extension SomabarController {
    /// Launch: the saved preference wins over whatever an earlier run left behind.
    func applySpacingAtLaunch() {
        StatusItemSpacing.apply(document.preferences.spacing, reason: "launch")
    }

    func restoreSpacingAtQuit() {
        StatusItemSpacing.restoreSystemDefault(reason: "quit")
    }

    /// Settings changed the spacing. The first non-default choice explains the log-out once.
    func spacingDidChange() {
        let spacing = document.preferences.spacing
        StatusItemSpacing.apply(spacing, reason: "Settings")
        guard spacing != .default, !document.preferences.spacingNoticeShown else { return }
        document.preferences.spacingNoticeShown = true
        saveDocument(reason: "Showed the spacing note")
        // Not from inside the picker's update: a modal alert there stalls SwiftUI.
        Task { @MainActor in self.showSpacingNotice() }
    }

    /// The notice offers to log out now; that asks once more, since apps get asked to quit.
    private func showSpacingNotice() {
        let alert = NSAlert()
        alert.messageText = "Spacing applies to apps opened from now on"
        alert.informativeText = "Apps that are already running keep their current spacing until they restart. "
            + "Logging out and back in applies the new spacing to every item in the menu bar."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Log Out…")
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn, confirmLogOut() else { return }
        StatusItemSpacing.logOut()
    }

    private func confirmLogOut() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Log out now?"
        alert.informativeText = "Every app will be asked to quit. Apps with unsaved changes may ask you to save them first."
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Log out

extension StatusItemSpacing {
    /// Apple event errors: Automation is off for System Events, and an app cancelled the log-out.
    private static let notPermitted = -1743
    private static let userCancelled = -128

    /// Logs out through System Events, which asks every app to quit.
    /// Needs the Automation permission for System Events; without it, says where to turn it on.
    static func logOut() {
        guard let script = NSAppleScript(source: "tell application \"System Events\" to log out") else { return }
        log.notice("Logging out to apply item spacing")
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        guard number != userCancelled else {
            log.notice("Log-out cancelled")
            return
        }
        log.error("Could not log out through System Events (\(number))")
        let alert = NSAlert()
        alert.messageText = "Somabar could not log out"
        alert.informativeText = number == notPermitted
            ? "Allow Somabar to control System Events in System Settings › Privacy & Security › Automation, "
                + "or choose Log Out from the Apple menu."
            : "Choose Log Out from the Apple menu instead."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
