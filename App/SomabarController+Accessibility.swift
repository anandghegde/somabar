import AppKit
import BarEngine
import SomabarCore

/// Accessibility access: the offer at first launch, the request, and the wait for trust.
extension SomabarController {
    func offerAccessibilityIfNeeded() {
        guard !AccessibilityPermission.isTrusted else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didOfferAccessibilityKey) else { return }
        defaults.set(true, forKey: Self.didOfferAccessibilityKey)

        let alert = NSAlert()
        alert.messageText = "Somabar works best with Accessibility access"
        alert.informativeText = """
        Somabar uses Accessibility to tell which app each menu bar item belongs to, read its name, \
        and move it when you ask. It reads nothing else.

        If you say no: Somabar can still hide and reveal items you place with ⌘-drag. \
        It can't tell which items they are, name them, search or arrange them.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibility()
        }
    }

    func requestAccessibility() {
        guard !AccessibilityPermission.isTrusted else { return }
        AccessibilityPermission.requestWithSystemPrompt()
        AccessibilityPermission.openSystemSettings()
        trustTask?.cancel()
        trustTask = Task { @MainActor [weak self] in
            // Trust flips without a notification; look for it for a few minutes.
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if AccessibilityPermission.isTrusted {
                    self.log.notice("Accessibility access granted")
                    self.scanNow(reason: "accessibility granted")
                    return
                }
            }
        }
    }

    func showUnsupportedAlert(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Somabar can't manage the menu bar on this macOS"
        alert.informativeText = "\(reason). Somabar shows its icon and hides nothing."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
