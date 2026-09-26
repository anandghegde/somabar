import SomabarCore
import SwiftUI

/// The trigger list: enable, add, edit, delete. Edits land in `document.triggers` and the
/// runtime re-evaluates at once.
struct TriggersSettingsView: View {
    @Bindable var model: SettingsModel
    /// The trigger in the editor sheet; a new one is not in the document until it is saved.
    @State private var editing: Trigger?

    var body: some View {
        Form {
            SwiftUI.Section {
                if model.document.triggers.isEmpty {
                    Text("No triggers yet").foregroundStyle(.secondary)
                }
                ForEach(model.document.triggers) { trigger in
                    TriggerRow(
                        trigger: trigger,
                        isHolding: model.activeTriggerNames.contains(trigger.displayName),
                        profileMissing: missingProfile(trigger),
                        groups: model.document.groups,
                        isEnabled: Binding(get: { trigger.isEnabled }, set: { isOn in
                            var changed = trigger
                            changed.isEnabled = isOn
                            model.setTrigger(changed)
                        }),
                        onEdit: { editing = trigger },
                        onDelete: { model.removeTrigger(id: trigger.id) }
                    )
                }
            } header: {
                HStack {
                    Text("When a condition holds, show or hide an item or switch profile, until it ends")
                    Spacer()
                    Button("Add Trigger…") { editing = Self.newTrigger }
                }
            } footer: {
                Text("Show and hide never change your layout; a profile switch goes back when the condition ends.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { trigger in
            TriggerEditorView(
                trigger: trigger,
                items: model.itemChoices,
                profiles: model.document.profiles.map(\.name),
                groups: model.document.groups,
                onSave: { saved in
                    model.setTrigger(saved)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    private static var newTrigger: Trigger {
        Trigger(name: "", isEnabled: true, condition: .external(name: ""), action: .switchProfile(name: Profile.presentingName))
    }

    private func missingProfile(_ trigger: Trigger) -> Bool {
        guard case .switchProfile(let name) = trigger.action else { return false }
        return model.document.profile(named: name) == nil
    }
}

private struct TriggerRow: View {
    var trigger: Trigger
    var isHolding: Bool
    var profileMissing: Bool
    var groups: [ItemGroup]
    var isEnabled: Binding<Bool>
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle("", isOn: isEnabled)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(trigger.displayName)
                    if isHolding {
                        Text("Holding").font(.caption).foregroundStyle(.green)
                    }
                }
                Text("When \(ConditionText.describe(trigger.condition)), \(trigger.action.summary(groups: groups))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if profileMissing {
                    Label("No profile has that name", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Edit…", action: onEdit)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this trigger")
        }
    }
}

/// Short English for a condition, for the list.
enum ConditionText {
    static func describe(_ condition: Condition) -> String {
        switch condition {
        case .powerSource(let source): source == .battery ? "on battery" : "on the power adapter"
        case .batteryBelow(let percent): "the battery is below \(percent)%"
        case .network(let network): "the network is \(NetworkText.name(network).lowercased())"
        case .display(.builtInOnly): "only the built-in display is on"
        case .display(.externalConnected): "an external display is connected"
        case .display(.widerThan(let points)): "a display is wider than \(points) points"
        case .screenSharing: "the screen is shared"
        case .mediaInUse(let device): "the \(device == .either ? "camera or microphone" : device.rawValue) is in use"
        case .appRunning(let bundleID): "\(bundleID) is running"
        case .appFrontmost(let bundleID): "\(bundleID) is in front"
        case .focus(let name): "the \(name) Focus is on"
        case .timeOfDay(let range): "it is \(TimeText.format(range.fromMinute))–\(TimeText.format(range.toMinute))"
        case .iconChanged(let key): "\(key.description)'s icon changes"
        case .external(let name): "“\(name)” is set on"
        case .not(let inner): "not (\(describe(inner)))"
        case .allOf(let inner): inner.map(describe).joined(separator: " and ")
        case .anyOf(let inner): inner.map(describe).joined(separator: " or ")
        }
    }
}

enum NetworkText {
    static func name(_ network: NetworkCondition) -> String {
        switch network {
        case .ethernet: "Ethernet"
        case .wifi: "Wi-Fi"
        case .vpn: "A VPN"
        case .knownRouter: "A known router"
        case .unknownNetwork: "An unknown network"
        case .offline: "Offline"
        }
    }
}

enum TimeText {
    /// "19:00" from minutes since midnight.
    static func format(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60 % 24, minute % 60)
    }
}
