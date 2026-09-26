import AppKit
import ApplicationServices

/// Accessibility is the one permission Somabar needs (M17). It is asked for once, with the
/// three-line explanation from the PRD, and never nagged about.
public enum AccessibilityPermission {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to add Somabar to the Accessibility list and show its own prompt.
    @discardableResult
    public static func requestWithSystemPrompt() -> Bool {
        // The literal key avoids `kAXTrustedCheckOptionPrompt`, whose `Unmanaged` type is not
        // Sendable under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @MainActor
    public static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
