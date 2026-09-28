import SomabarCore
import SwiftUI

/// Known routers, item images, the notch, and the trigger notification.
struct AdvancedSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            routersSection
            SwiftUI.Section("Items") {
                Toggle("Show real item images", isOn: Binding(
                    get: { model.preferences.realItemImages },
                    set: { model.setRealItemImages($0) }
                ))
                Text("Needs Screen Recording access. Off shows each app's icon and name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.preferences.realItemImages && !ScreenRecordingPermission.shared.isGranted {
                    ScreenRecordingNote(text: "Screen Recording is off. Somabar shows app icons instead.")
                }
            }
            .onAppear { ScreenRecordingPermission.shared.refresh() }
            SwiftUI.Section("Notch") {
                Toggle("Move items out from under the notch", isOn: $model.preferences.notchGuard)
                Toggle("Notch surface", isOn: $model.preferences.notchSurface)
            }
            AgentSettingsSection(isOn: $model.preferences.agentSocket, answersPrompts: $model.preferences.agentReplies)
            SwiftUI.Section("Triggers") {
                Toggle("Notify when a trigger fires", isOn: Binding(
                    get: { model.preferences.notifyWhenTriggerFires },
                    set: { model.setNotifyWhenTriggerFires($0) }
                ))
                if let note = model.notificationNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var routersSection: some View {
        SwiftUI.Section {
            if model.preferences.knownRouters.isEmpty {
                Text("No known routers").foregroundStyle(.secondary)
            }
            ForEach(model.preferences.knownRouters, id: \.self) { router in
                HStack {
                    Text(router).monospaced()
                    if router == model.currentRouter {
                        Text("This network").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        model.preferences.knownRouters.removeAll { $0 == router }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Forget this router")
                }
            }
            if let router = model.currentRouter, !model.preferences.knownRouters.contains(router) {
                Button("Remember This Router (\(router))") { model.rememberCurrentRouter() }
            }
        } header: {
            Text("Known routers")
        } footer: {
            Text("Routers are known by their hardware address, for the “known router” and “unknown network” conditions.")
                .foregroundStyle(.secondary)
        }
    }
}
