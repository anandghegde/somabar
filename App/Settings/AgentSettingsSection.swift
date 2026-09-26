import SomabarCore
import SwiftUI

/// Settings › Advanced › Coding agents (N11): the switch for the local agent socket.
struct AgentSettingsSection: View {
    @Binding var isOn: Bool

    var body: some View {
        SwiftUI.Section {
            Toggle("Listen for coding agents", isOn: $isOn)
        } header: {
            Text("Coding agents")
        } footer: {
            Text("Opens a socket only your user can reach, in Application Support › Somabar › agent.sock, "
                + "and takes somabar://agent links. Signed tools such as nc send reports from an agent's "
                + "hooks; the notch shows which sessions are working and which need you. "
                + "Somabar never answers an agent or types into a terminal.")
                .foregroundStyle(.secondary)
        }
    }
}
