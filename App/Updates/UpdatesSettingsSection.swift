import SwiftUI

/// Settings › General › Updates: the switch for Sparkle's automatic checks.
struct UpdatesSettingsSection: View {
    private let updates = UpdateController.shared

    var body: some View {
        SwiftUI.Section {
            Toggle("Check for updates automatically", isOn: automaticallyChecks)
                .disabled(!updates.isConfigured)
        } header: {
            Text("Updates")
        } footer: {
            Text(updates.isConfigured
                ? "Checking for updates is the only time Somabar goes online."
                : UpdateController.notConfiguredNote)
                .foregroundStyle(.secondary)
        }
    }

    private var automaticallyChecks: Binding<Bool> {
        Binding(
            get: { updates.automaticallyChecks },
            set: { updates.setAutomaticallyChecks($0) }
        )
    }
}
