import SomabarCore
import SwiftUI

/// The group list, and per group: its name, its glyph, the section its members share in the
/// active profile, and up to eight members.
struct GroupsSettingsView: View {
    @Bindable var model: SettingsModel
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(model.document.groups, selection: $selection) { group in
                    HStack {
                        Text(group.name)
                        Spacer()
                        Text("\(group.members.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(group.id)
                }
                Divider()
                HStack(spacing: 0) {
                    Button { selection = model.addGroup() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("Add a group")
                    Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil)
                        .help("Remove the selected group; its items stay where they are")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 180)
            Divider()
            if let id = selection, let group = model.document.group(id: id) {
                GroupDetailView(model: model, group: group)
                    .id(group.id)
            } else {
                Text(model.document.groups.isEmpty ? "Click + to add a group" : "Select a group")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? model.document.groups.first?.id }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        model.removeGroup(id)
        selection = model.document.groups.first?.id
    }
}

private struct GroupDetailView: View {
    var model: SettingsModel
    var group: ItemGroup
    @State private var name = ""
    @State private var glyph = ""
    @State private var error: String?

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("Name", text: $name)
                    .onSubmit(rename)
                TextField("Glyph", text: $glyph, prompt: Text("A letter, or an SF Symbol name"))
                    .onSubmit { model.setGroupGlyph(group.id, to: glyph) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("Members are in", selection: sectionBinding) {
                    ForEach(SomabarCore.Section.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                    if sectionBinding.wrappedValue == nil {
                        Text("Not placed yet").tag(SomabarCore.Section?.none)
                    }
                }
                .disabled(group.members.isEmpty)
            } footer: {
                Text("The glyph opens a row of the members. The members move together, in \(model.document.active.name) and every other profile.")
                    .foregroundStyle(.secondary)
            }
            SwiftUI.Section("Items (\(group.members.count) of \(ItemGroup.maxMembers))") {
                if group.members.isEmpty {
                    Text("No items yet").foregroundStyle(.secondary)
                }
                ForEach(group.members, id: \.self) { key in
                    HStack {
                        Text(label(for: key))
                        Spacer()
                        Button(role: .destructive) {
                            setMembers(group.members.filter { $0 != key })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Take this item out of the group")
                    }
                }
                Menu("Add Item") {
                    ForEach(candidates) { choice in
                        Button(choice.label) { setMembers(group.members + [choice.key]) }
                    }
                }
                .disabled(group.members.count >= ItemGroup.maxMembers || candidates.isEmpty)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = group.name
            glyph = group.glyph
        }
    }

    /// Items not in this group yet. One in another group moves here.
    private var candidates: [ItemChoice] {
        model.itemChoices.filter { !group.members.contains($0.key) }
    }

    private var sectionBinding: Binding<SomabarCore.Section?> {
        Binding(
            get: { model.document.section(ofGroup: group.id) },
            set: { section in
                if let section { model.moveGroup(group.id, to: section) }
            }
        )
    }

    private func label(for key: ItemKey) -> String {
        let choice = model.itemChoices.first { $0.key == key } ?? ItemChoice(key: key, appName: nil)
        if let other = model.document.group(containing: key), other.id != group.id {
            return "\(choice.label) (in \(other.name))"
        }
        return choice.label
    }

    private func rename() {
        do {
            try model.renameGroup(group.id, to: name)
            error = nil
        } catch {
            self.error = switch error {
            case .emptyName: "A group needs a name"
            case .nameTaken: "Another group has that name"
            case .noSuchGroup, .tooManyMembers: "The group could not be renamed"
            }
        }
    }

    private func setMembers(_ members: [ItemKey]) {
        do {
            try model.setGroupMembers(group.id, members)
            error = nil
        } catch {
            self.error = error == .tooManyMembers ? "A group holds up to \(ItemGroup.maxMembers) items" : "The items could not be changed"
        }
    }
}
