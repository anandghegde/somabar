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

    var id: ItemKey { key }
}

struct ItemSection: Identifiable {
    var section: SomabarCore.Section
    var rows: [ItemRow]

    var id: SomabarCore.Section { section }
}

@Observable
@MainActor
final class ItemsModel {
    var sections: [ItemSection] = []
    var profileName = ""
    var isTrusted = false
    var lastScan: Date?
    var backendNote: String?
}

struct ItemsView: View {
    @Bindable var model: ItemsModel
    var onRescan: @MainActor () -> Void
    var onGrantAccess: @MainActor () -> Void

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
                        if section.rows.isEmpty {
                            Text("Nothing here").foregroundStyle(.tertiary)
                        }
                        ForEach(section.rows) { row in
                            rowView(row)
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
                Text("Profile: \(model.profileName). Hold ⌘ and drag an item across a divider to move it; Somabar remembers where it went.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rescan", action: onRescan)
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
                Button("Grant Access…", action: onGrantAccess)
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

    private func rowView(_ row: ItemRow) -> some View {
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
    }
}

/// Hosts `ItemsView` in a plain window. Closing it leaves the app running.
@MainActor
final class ItemsWindowController: NSWindowController {
    let model = ItemsModel()

    init(onRescan: @escaping @MainActor () -> Void, onGrantAccess: @escaping @MainActor () -> Void) {
        let view = ItemsView(model: model, onRescan: onRescan, onGrantAccess: onGrantAccess)
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
    /// hidden and what is not.
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
        // Shown first: that is what people see. Then the sections in bar order, right to left.
        let order: [SomabarCore.Section] = [.shown, .hidden, .tucked, .locked]
        model.sections = order.map { section in
            let rows = profile.layout[section].map { key -> ItemRow in
                let item = present[key]
                let baseName = key.title.isEmpty ? (item?.appName ?? key.bundleID) : key.title
                let name = key.ordinal > 0 ? "\(baseName) (\(key.ordinal + 1))" : baseName
                var detail = item?.appName ?? key.bundleID
                if let item, !key.title.isEmpty, item.appName != key.title {
                    detail = "\(item.appName) · \(key.bundleID)"
                }
                let isManaged = item?.isManagedByMacOS ?? SystemItems.isManagedByMacOS(key)
                return ItemRow(key: key, name: name, detail: detail, isPresent: item != nil, isManaged: isManaged)
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
            return ItemSection(section: section, rows: rows + placeholders)
        }
    }

    /// Placeholder rows need ids that differ across sections as well as within one.
    private static func placeholderOrdinal(section: SomabarCore.Section, index: Int) -> Int {
        let base = SomabarCore.Section.allCases.firstIndex(of: section) ?? 0
        return base * 1_000 + index
    }
}
