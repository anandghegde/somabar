import SomabarCore
import SwiftUI

/// One recorder per action. A combo that clashes is shown with the reason and not saved.
struct HotkeysSettingsView: View {
    @Bindable var model: SettingsModel
    /// The last refused combo per action, shown until the next attempt.
    @State private var clashes: [HotkeyAction: String] = [:]
    /// The same, per item or group.
    @State private var targetClashes: [HotKeyTarget: String] = [:]

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    row(for: action)
                }
            } footer: {
                Text("Click a shortcut, then press the new combination. ⌫ clears it, ⎋ cancels. Shortcuts need ⌃, ⌥ or ⌘.")
                    .foregroundStyle(.secondary)
            }
            itemSection
        }
        .formStyle(.grouped)
    }

    private func row(for action: HotkeyAction) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                KeyRecorder(
                    combo: model.document.combo(for: action),
                    onRecord: { result in record(result, for: action) },
                    onRecordingChanged: { model.setRecording($0) }
                )
                .frame(width: 150, height: 24)
                if let clash = clashes[action] {
                    Label(clash, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } label: {
            Text(action.displayName)
        }
    }

    // MARK: Items and groups

    /// A shortcut per item opens its menu, even when it is Hidden or Tucked. One per group
    /// reveals the group's section.
    private var itemSection: some View {
        SwiftUI.Section {
            if model.document.itemHotKeys.isEmpty {
                Text("No item shortcuts yet").foregroundStyle(.secondary)
            }
            ForEach(model.document.itemHotKeys, id: \.target) { hotKey in
                row(for: hotKey.target)
            }
        } header: {
            HStack {
                Text("Items and groups")
                Spacer()
                addMenu
            }
        } footer: {
            Text("An item's shortcut opens its menu, the way search does. A group's shortcut reveals its items.")
                .foregroundStyle(.secondary)
        }
    }

    private var addMenu: some View {
        let taken = Set(model.document.itemHotKeys.map(\.target))
        let items = model.itemChoices.filter { !taken.contains(.item($0.key)) }
        let groups = model.document.groups.filter { !taken.contains(.group($0.id)) }
        return Menu("Add") {
            if !groups.isEmpty {
                SwiftUI.Section("Groups") {
                    ForEach(groups) { group in
                        Button(group.name) { model.addItemHotKey(for: .group(group.id)) }
                    }
                }
            }
            SwiftUI.Section("Items") {
                ForEach(items) { choice in
                    Button(choice.label) { model.addItemHotKey(for: .item(choice.key)) }
                }
            }
        }
        .fixedSize()
        .disabled(items.isEmpty && groups.isEmpty)
    }

    private func row(for target: HotKeyTarget) -> some View {
        LabeledContent {
            HStack(alignment: .top) {
                VStack(alignment: .trailing, spacing: 4) {
                    KeyRecorder(
                        combo: model.document.combo(for: target),
                        onRecord: { result in record(result, for: target) },
                        onRecordingChanged: { model.setRecording($0) }
                    )
                    .frame(width: 150, height: 24)
                    if let clash = targetClashes[target] {
                        Label(clash, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Button(role: .destructive) {
                    targetClashes[target] = nil
                    model.removeItemHotKey(for: target)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this shortcut")
            }
        } label: {
            Text(label(for: target))
        }
    }

    private func label(for target: HotKeyTarget) -> String {
        guard case .item(let key) = target, let choice = model.itemChoices.first(where: { $0.key == key }) else {
            return model.document.label(for: target)
        }
        return choice.label
    }

    private func record(_ result: KeyRecorderResult, for target: HotKeyTarget) {
        switch result {
        case .combo(let combo):
            if let clash = model.setCombo(combo, for: target) {
                targetClashes[target] = "\(combo.display): \(clash.message)"
            } else {
                targetClashes[target] = nil
            }
        case .cleared:
            _ = model.setCombo(nil, for: target)
            targetClashes[target] = nil
        case .unsupported(let reason):
            targetClashes[target] = reason
        }
    }

    private func record(_ result: KeyRecorderResult, for action: HotkeyAction) {
        switch result {
        case .combo(let combo):
            if let clash = model.setCombo(combo, for: action) {
                clashes[action] = "\(combo.display): \(clash.message)"
            } else {
                clashes[action] = nil
            }
        case .cleared:
            _ = model.setCombo(nil, for: action)
            clashes[action] = nil
        case .unsupported(let reason):
            clashes[action] = reason
        }
    }
}
