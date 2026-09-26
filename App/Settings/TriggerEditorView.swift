import SomabarCore
import SwiftUI

/// The sheet that edits one trigger: a name, a condition (leaves combined one level deep), and an
/// action. A condition deeper than that is kept as it is unless the person replaces it.
struct TriggerEditorView: View {
    enum ActionKind: String, CaseIterable {
        case show
        case hide
        case switchProfile
    }

    let original: Trigger
    let items: [ItemChoice]
    let profiles: [String]
    var onSave: (Trigger) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var isEnabled: Bool
    /// Nil while the original condition is too deep for the editor and has not been replaced.
    @State private var draft: ConditionDraft?
    @State private var actionKind: ActionKind
    @State private var item: ItemKey?
    @State private var profile: String

    init(trigger: Trigger, items: [ItemChoice], profiles: [String], onSave: @escaping (Trigger) -> Void, onCancel: @escaping () -> Void) {
        original = trigger
        self.profiles = profiles
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: trigger.name)
        _isEnabled = State(initialValue: trigger.isEnabled)
        _draft = State(initialValue: ConditionDraft(trigger.condition))
        var choices = items
        switch trigger.action {
        case .show(let key), .hide(let key):
            _actionKind = State(initialValue: trigger.action == .show(key) ? .show : .hide)
            _item = State(initialValue: key)
            _profile = State(initialValue: profiles.first ?? "")
            if !choices.contains(where: { $0.key == key }) {
                choices.insert(ItemChoice(key: key, appName: nil), at: 0)
            }
        case .switchProfile(let target):
            _actionKind = State(initialValue: .switchProfile)
            _item = State(initialValue: items.first?.key)
            _profile = State(initialValue: target)
        }
        self.items = choices
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                SwiftUI.Section {
                    TextField("Name", text: $name, prompt: Text("Docker from a script"))
                    Toggle("Enabled", isOn: $isEnabled)
                }
                conditionSection
                actionSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { if let trigger = edited { onSave(trigger) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(edited == nil)
            }
            .padding()
        }
        .frame(width: 560, height: 540)
    }

    // MARK: Condition

    @ViewBuilder private var conditionSection: some View {
        if let draft {
            SwiftUI.Section {
                Picker("Holds when", selection: Binding(get: { draft.match }, set: { self.draft?.match = $0 })) {
                    Text(draft.leaves.count > 1 ? "All of these hold" : "This holds").tag(ConditionMatch.all)
                    Text("Any of these holds").tag(ConditionMatch.any)
                    Text(draft.leaves.count > 1 ? "None of these holds" : "This does not hold").tag(ConditionMatch.none)
                }
                ForEach(draft.leaves) { leaf in
                    ConditionLeafEditor(
                        leaf: leafBinding(leaf.id),
                        canRemove: draft.leaves.count > 1,
                        items: items,
                        onRemove: { self.draft?.leaves.removeAll { $0.id == leaf.id } }
                    )
                }
                Button("Add Condition") { self.draft?.leaves.append(LeafConditionDraft(kind: .screenSharing)) }
            } header: {
                Text("When")
            }
        } else {
            SwiftUI.Section("When") {
                Text(ConditionText.describe(original.condition))
                Text("This condition nests deeper than the editor goes. It is kept as it is; edit it in the layout file, or start over here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Replace Condition") { draft = ConditionDraft() }
            }
        }
    }

    private func leafBinding(_ id: UUID) -> Binding<LeafConditionDraft> {
        Binding(
            get: { draft?.leaves.first { $0.id == id } ?? LeafConditionDraft(kind: .screenSharing) },
            set: { value in
                guard let index = draft?.leaves.firstIndex(where: { $0.id == id }) else { return }
                draft?.leaves[index] = value
            }
        )
    }

    // MARK: Action

    private var actionSection: some View {
        SwiftUI.Section("Then, until it ends") {
            Picker("Action", selection: $actionKind) {
                Text("Show an item").tag(ActionKind.show)
                Text("Hide an item").tag(ActionKind.hide)
                Text("Switch profile").tag(ActionKind.switchProfile)
            }
            if actionKind == .switchProfile {
                Picker("Profile", selection: $profile) {
                    if !profiles.contains(profile) {
                        Text("\(profile) (missing)").tag(profile)
                    }
                    ForEach(profiles, id: \.self) { Text($0).tag($0) }
                }
            } else if items.isEmpty {
                Text("No items known yet. Grant Accessibility access so Somabar can tell items apart.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Item", selection: $item) {
                    Text("Choose an item").tag(ItemKey?.none)
                    ForEach(items) { choice in
                        Text(choice.label).tag(ItemKey?.some(choice.key))
                    }
                }
            }
        }
    }

    // MARK: Result

    /// The edited trigger, or nil while something required is missing.
    private var edited: Trigger? {
        let condition: Condition
        if let draft {
            guard let built = draft.condition else { return nil }
            condition = built
        } else {
            condition = original.condition
        }
        let action: TriggerAction
        switch actionKind {
        case .show:
            guard let item else { return nil }
            action = .show(item)
        case .hide:
            guard let item else { return nil }
            action = .hide(item)
        case .switchProfile:
            guard !profile.isEmpty else { return nil }
            action = .switchProfile(name: profile)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Trigger(id: original.id, name: trimmed, isEnabled: isEnabled, condition: condition, action: action)
    }
}
