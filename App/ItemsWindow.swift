import AppKit
import BarEngine
import Observation
import SomabarCore
import SwiftUI

/// One line in the Items window.
struct ItemRow: Identifiable, Hashable {
    var key: ItemKey
    var name: String
    var detail: String
    /// False when the layout remembers the item but its app is not showing it right now.
    var isPresent: Bool
    var isManaged: Bool
    /// False for an item in the bar whose app Somabar cannot tell without Accessibility access.
    var isIdentified = true
    /// The group the item is in, if any.
    var groupID: UUID?

    var id: ItemKey { key }
}

/// A group's members in one section, under the group's header.
struct ItemGroupBlock: Identifiable {
    var id: UUID
    var name: String
    var face: ItemGroup.Face
    var rows: [ItemRow]
}

struct ItemSection: Identifiable {
    var section: SomabarCore.Section
    var groups: [ItemGroupBlock]
    /// The items in no group, and the placeholders.
    var rows: [ItemRow]

    var id: SomabarCore.Section { section }
    var isEmpty: Bool { groups.isEmpty && rows.isEmpty }
}

/// A group an item can join from its context menu.
struct GroupChoice: Identifiable {
    var id: UUID
    var name: String
    var isFull: Bool
}

@Observable
@MainActor
final class ItemsModel {
    private static let collapsedKey = "somabar.items.collapsedGroups"

    var sections: [ItemSection] = []
    var groupChoices: [GroupChoice] = []
    var profileName = ""
    var isTrusted = false
    /// False when a move would only change the layout: the bar stays as it is and the next scan
    /// adopts it again.
    var canMoveItems = false
    var lastScan: Date?
    var backendNote: String?
    /// Groups folded to their header. Remembered across launches; a view preference, so it
    /// lives in the defaults, not the layout file.
    var collapsedGroups: Set<UUID> {
        didSet { UserDefaults.standard.set(collapsedGroups.map(\.uuidString), forKey: Self.collapsedKey) }
    }

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
        collapsedGroups = Set(stored.compactMap(UUID.init(uuidString:)))
    }
}

/// What the Items window asks the controller to do.
struct ItemsActions {
    var rescan: @MainActor () -> Void
    var grantAccess: @MainActor () -> Void
    var moveGroup: @MainActor (UUID, SomabarCore.Section) -> Void
    /// A nil group takes the item out of its group.
    var assign: @MainActor (ItemKey, UUID?) -> Void
    var newGroup: @MainActor (ItemKey) -> Void
}

struct ItemsView: View {
    /// Where a group can go from here. Locked asks for Touch ID, so it stays a Settings choice.
    private static let groupDestinations: [SomabarCore.Section] = [.shown, .hidden, .tucked]

    @Bindable var model: ItemsModel
    var actions: ItemsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let note = model.backendNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .padding()
            }
            List {
                ForEach(model.sections) { section in
                    SwiftUI.Section {
                        if section.isEmpty {
                            Text("Nothing here").foregroundStyle(.tertiary)
                        }
                        ForEach(section.groups) { group in
                            DisclosureGroup(isExpanded: expansion(of: group.id)) {
                                ForEach(group.rows) { row in
                                    rowView(row, in: section.section)
                                }
                            } label: {
                                groupHeader(group, in: section.section)
                            }
                        }
                        if !section.groups.isEmpty, !section.rows.isEmpty {
                            Text("Not in a group").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(section.rows) { row in
                            rowView(row, in: section.section)
                        }
                    } header: {
                        Text(section.section.displayName)
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .frame(minWidth: 440, minHeight: 360)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Menu bar items").font(.headline)
                Text(
                    "Profile: \(model.profileName). Hold ⌘ and drag an item across a divider to move it; Somabar remembers where it went. "
                        + "Right-click an item or a group to regroup or move it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rescan", action: actions.rescan)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if model.isTrusted {
                Label("Accessibility access granted. Apps and names come from the items themselves.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("Without Accessibility access, Somabar can't tell which app an item belongs to.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Grant Access…", action: actions.grantAccess)
            }
            if model.isTrusted {
                Spacer()
            }
            if let lastScan = model.lastScan {
                Text("Scanned \(lastScan, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: Groups

    private func expansion(of id: UUID) -> Binding<Bool> {
        Binding(
            get: { !model.collapsedGroups.contains(id) },
            set: { expanded in
                if expanded {
                    model.collapsedGroups.remove(id)
                } else {
                    model.collapsedGroups.insert(id)
                }
            }
        )
    }

    private func groupHeader(_ group: ItemGroupBlock, in section: SomabarCore.Section) -> some View {
        HStack {
            GroupGlyph(face: group.face)
            Text(group.name).fontWeight(.medium)
            Text("\(group.rows.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu {
                moveGroupButtons(group.id, from: section)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!model.canMoveItems)
            .help(model.canMoveItems ? "Move the whole group to another section" : "Somabar can't move items without Accessibility access")
        }
        .contentShape(Rectangle())
        .contextMenu {
            if model.canMoveItems {
                moveGroupButtons(group.id, from: section)
            }
        }
    }

    @ViewBuilder
    private func moveGroupButtons(_ id: UUID, from section: SomabarCore.Section) -> some View {
        ForEach(Self.groupDestinations, id: \.self) { destination in
            Button("Move Group to \(destination.displayName)") { actions.moveGroup(id, destination) }
                .disabled(destination == section)
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: ItemRow, in section: SomabarCore.Section) -> some View {
        if row.isIdentified {
            Menu(row.groupID == nil ? "Add to Group" : "Move to Group") {
                ForEach(model.groupChoices) { choice in
                    Button(choice.isFull ? "\(choice.name) (full)" : choice.name) { actions.assign(row.key, choice.id) }
                        .disabled(choice.isFull || choice.id == row.groupID)
                }
                if !model.groupChoices.isEmpty {
                    Divider()
                }
                Button("New Group") { actions.newGroup(row.key) }
            }
            if let groupID = row.groupID {
                let name = model.groupChoices.first { $0.id == groupID }?.name ?? "its group"
                Button("Remove from “\(name)”") { actions.assign(row.key, nil) }
                if model.canMoveItems {
                    Divider()
                    moveGroupButtons(groupID, from: section)
                }
            }
        }
    }

    // MARK: Rows

    private func rowView(_ row: ItemRow, in section: SomabarCore.Section) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).foregroundStyle(row.isIdentified ? .primary : .secondary)
                Text(row.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if row.isManaged {
                Text("macOS").font(.caption2).foregroundStyle(.tertiary)
            }
            if !row.isPresent {
                Text("not in the bar").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .opacity(row.isPresent ? 1 : 0.55)
        .contextMenu { rowMenu(row, in: section) }
    }
}

/// A group's glyph as the bar draws it: its SF Symbol, or the squared letter.
private struct GroupGlyph: View {
    var face: ItemGroup.Face

    var body: some View {
        if let name = symbolName, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            Image(systemName: name).foregroundStyle(.secondary)
        } else {
            Text(String(face.text.prefix(2))).font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    private var symbolName: String? {
        switch face {
        case .symbol(let name): name
        case .letter(let letter): "\(letter.lowercased()).square"
        }
    }
}

/// Hosts `ItemsView` in a plain window. Closing it leaves the app running.
@MainActor
final class ItemsWindowController: NSWindowController {
    let model = ItemsModel()

    init(actions: ItemsActions) {
        let view = ItemsView(model: model, actions: actions)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Somabar Items"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 480))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not used")
    }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Rebuilds the rows from the active profile and what the scan saw. Items the scan could not
    /// attribute to an app are listed by section as placeholders, so the person still sees what is
    /// hidden and what is not. Within a section, each group's members sit under its header
    /// (`GroupedItems`), and the items in no group follow.
    func update(
        document: SomabarDocument,
        items: [DiscoveredItem],
        unidentifiedBySection: [SomabarCore.Section: Int],
        lastScan: Date?,
        backendNote: String?
    ) {
        let profile = document.active
        let present = Dictionary(items.filter(\.isIdentified).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        model.profileName = profile.name
        model.isTrusted = AccessibilityPermission.isTrusted
        model.lastScan = lastScan
        model.backendNote = backendNote
        model.groupChoices = document.groups.map {
            GroupChoice(id: $0.id, name: $0.name, isFull: $0.members.count >= ItemGroup.maxMembers)
        }
        // Shown first: that is what people see. Then the sections in bar order, right to left.
        let order: [SomabarCore.Section] = [.shown, .hidden, .tucked, .locked]
        model.sections = order.map { section in
            let listing = GroupedItems(keys: profile.layout[section], groups: document.groups)
            let row = { (key: ItemKey) -> ItemRow in
                let item = present[key]
                let baseName = key.title.isEmpty ? (item?.appName ?? key.bundleID) : key.title
                let name = key.ordinal > 0 ? "\(baseName) (\(key.ordinal + 1))" : baseName
                var detail = item?.appName ?? key.bundleID
                if let item, !key.title.isEmpty, item.appName != key.title {
                    detail = "\(item.appName) · \(key.bundleID)"
                }
                let isManaged = item?.isManagedByMacOS ?? SystemItems.isManagedByMacOS(key)
                return ItemRow(
                    key: key, name: name, detail: detail, isPresent: item != nil, isManaged: isManaged,
                    groupID: document.group(containing: key)?.id
                )
            }
            let groups = listing.blocks.map { block in
                ItemGroupBlock(id: block.id, name: block.group.name, face: block.group.face, rows: block.members.map(row))
            }
            let unknownCount = unidentifiedBySection[section] ?? 0
            let placeholders = (0..<unknownCount).map { index in
                ItemRow(
                    key: ItemKey(bundleID: DiscoveredItem.unknownBundleID, ordinal: Self.placeholderOrdinal(section: section, index: index)),
                    name: unknownCount == 1 ? "An item" : "Item \(index + 1)",
                    detail: "Grant Accessibility access to see which app this is",
                    isPresent: true,
                    isManaged: false,
                    isIdentified: false
                )
            }
            return ItemSection(section: section, groups: groups, rows: listing.ungrouped.map(row) + placeholders)
        }
    }

    /// Placeholder rows need ids that differ across sections as well as within one.
    private static func placeholderOrdinal(section: SomabarCore.Section, index: Int) -> Int {
        let base = SomabarCore.Section.allCases.firstIndex(of: section) ?? 0
        return base * 1_000 + index
    }
}
