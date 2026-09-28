import SomabarCore
import SwiftUI

/// Settings › Advanced › Coding agents (N11): the switch for the local agent socket, and the
/// separate switch for answering permission prompts from the notch (P2).
struct AgentSettingsSection: View {
    @Binding var isOn: Bool
    @Binding var answersPrompts: Bool

    var body: some View {
        SwiftUI.Section {
            Toggle("Listen for coding agents", isOn: $isOn)
            Toggle("Answer permission prompts from the notch", isOn: $answersPrompts)
                .disabled(!isOn)
        } header: {
            Text("Coding agents")
        } footer: {
            Text("Opens a socket only your user can reach, in Application Support › Somabar › agent.sock, "
                + "and takes somabar://agent links. Signed tools such as nc send reports from an agent's "
                + "hooks; the notch shows which sessions are working and which need you. "
                + "With prompts on, a hook can wait on the socket for Allow or Deny; after 60 seconds, "
                + "or with no answer, the agent asks in its terminal. Links never answer a prompt, "
                + "and Somabar never types into a terminal.")
                .foregroundStyle(.secondary)
        }
    }
}
