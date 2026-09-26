import AppKit
import BarEngine
import Observation
import os
import SomabarCore
import SwiftUI

// MARK: - Palette

/// What a palette line opens: an item's window, a group (M9), or an entry in the menu the
/// palette is showing, by its `MenuEntry.path` (1.1).
enum PaletteTarget: Hashable, Sendable {
    case window(CGWindowID)
    case group(UUID)
    case menuEntry([Int])
}

/// One line in the search palette.
struct PaletteRow: Identifiable {
    var id: PaletteTarget
    var appName: String
    /// The item's own title, searched as well as shown.
    var title: String
    var detail: String
    /// Nil for menu entries, which show their shortcut instead.
    var tag: SearchTag?
    var icon: NSImage
    var shortcut = ""
    var hasSubmenu = false
    var isEnabled = true
    var isChecked = false
}

@Observable
@MainActor
final class PaletteModel {
    var rows: [PaletteRow] = []
    var selection: Int?
    var emptyMessage = ""
}

struct PaletteList: View {
    static let rowHeight: CGFloat = 44

    var model: PaletteModel
    var onActivate: @MainActor (Int) -> Void

    var body: some View {
        if model.rows.isEmpty {
            Text(model.emptyMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isSelected: index == model.selection)
                                .id(row.id)
                                .onTapGesture { onActivate(index) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { _, selection in
                    guard let selection, model.rows.indices.contains(selection) else { return }
                    proxy.scrollTo(model.rows[selection].id)
                }
            }
        }
    }

    private func rowView(_ row: PaletteRow, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: row.icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.appName).lineLimit(1)
                if !row.detail.isEmpty {
                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if row.isChecked {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
            }
            if !row.shortcut.isEmpty {
                Text(row.shortcut).font(.callout).foregroundStyle(.secondary)
            }
            if row.hasSubmenu {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            if let tag = row.tag {
                Text(tag.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .opacity(row.isEnabled ? 1 : 0.45)
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.3) : .clear))
        .contentShape(Rectangle())
    }
}

/// The Spotlight-like search palette (⌃⌥/): type to filter every item the last scan found, ↩ or
/// a click opens the item's menu. It never activates Somabar, so the front app keeps its menus.
///
/// → at the end of the query lists the selected item's menu instead (1.1), read through
/// Accessibility: typing filters it and its submenus, → or ↩ opens a submenu, ↩ presses an entry,
/// and ← at the start of the query or ⌫ on an empty one goes back a level.
@MainActor
final class SearchPaletteController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let width: CGFloat = 600
    static let fieldHeight: CGFloat = 54
    static let maxVisibleRows = 8

    private let panel = SomabarPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: fieldHeight))
    private let field = NSTextField()
    private let crumbs = NSTextField(labelWithString: "")
    private let model = PaletteModel()
    private let outsideClicks = OutsideClickMonitor()
    private let onActivate: @MainActor (PaletteTarget) -> Void
    private let menus: PaletteMenuActions
    private var allRows: [PaletteRow] = []
    private var emptyNote = ""
    /// Set while the palette lists one item's menu rather than the bar.
    private var menu: PaletteMenu?
    private var menuMatches: [MenuMatch] = []
    private var menuLoad: Task<Void, Never>?
    /// The item list's query and selection, put back on leaving the menu.
    private var itemQuery = ""
    private var itemSelection: Int?
    /// The palette's top edge stays put while its height follows the list.
    private var top: CGFloat = 0

    var isVisible: Bool { panel.isVisible }

    init(menus: PaletteMenuActions, onActivate: @escaping @MainActor (PaletteTarget) -> Void) {
        self.menus = menus
        self.onActivate = onActivate
        super.init()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = SomabarPanel.backing(for: makeContent(), material: .popover, cornerRadius: 14)
    }

    /// Shows the palette with `rows` in bar order. `emptyNote` explains an empty bar.
    func present(rows: [PaletteRow], emptyNote: String) {
        allRows = rows
        self.emptyNote = emptyNote
        leaveMenu()
        field.stringValue = ""
        let screen = NSScreen.main ?? ScreenGeometry.primaryScreen
        if let visible = screen?.visibleFrame {
            top = visible.maxY - visible.height * 0.18
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.width / 2, y: top - Self.fieldHeight))
        }
        refilter()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        outsideClicks.start { [weak self] in self?.close() }
    }

    func close() {
        leaveMenu()
        outsideClicks.stop()
        panel.orderOut(nil)
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        magnifier.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        magnifier.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .light)
        field.placeholderString = Self.itemPlaceholder
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail

        crumbs.font = .systemFont(ofSize: 13)
        crumbs.textColor = .secondaryLabelColor
        crumbs.lineBreakMode = .byTruncatingHead
        crumbs.setContentHuggingPriority(.required, for: .horizontal)
        crumbs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator
        let list = NSHostingView(rootView: PaletteList(model: model) { [weak self] index in self?.activate(index) })

        let container = NSView()
        for view in [magnifier, field, crumbs, separator, list] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            magnifier.centerYAnchor.constraint(equalTo: container.topAnchor, constant: Self.fieldHeight / 2),
            magnifier.widthAnchor.constraint(equalToConstant: 22),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: crumbs.leadingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: magnifier.centerYAnchor),
            crumbs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            crumbs.centerYAnchor.constraint(equalTo: magnifier.centerYAnchor),
            crumbs.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.fieldHeight),
            list.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            list.topAnchor.constraint(equalTo: separator.bottomAnchor),
            list.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func resizeToFit() {
        let visibleRows = min(model.rows.count, Self.maxVisibleRows)
        let listHeight = visibleRows > 0 ? CGFloat(visibleRows) * PaletteList.rowHeight + 12 : 60
        let height = Self.fieldHeight + 1 + listHeight
        let frame = NSRect(x: panel.frame.minX, y: top - height, width: Self.width, height: height)
        panel.setFrame(frame, display: true)
    }

    // MARK: - Filtering and keys

    private static let itemPlaceholder = "Search menu bar items (→ lists an item’s menu)"

    /// Refills the list for the query, selecting `selection` when it is still a row, else the top.
    private func refilter(selecting selection: Int? = nil) {
        let query = field.stringValue
        if let menu {
            menuMatches = menu.drill.matches(query: query)
            model.rows = menuMatches.map { PaletteRow(match: $0, icon: menu.icon) }
            model.emptyMessage = menu.drill.entries.isEmpty ? menu.emptyNote : "No menu items match “\(query)”"
        } else {
            let candidates = allRows.map { SearchCandidate(id: $0.id, appName: $0.appName, title: $0.title, tag: $0.tag ?? .shown) }
            let byID = Dictionary(allRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            model.rows = ItemSearch.rank(candidates, query: query).compactMap { byID[$0.id] }
            model.emptyMessage = allRows.isEmpty ? emptyNote : "No items match “\(query)”"
        }
        let crumbs = menu?.drill.breadcrumb ?? []
        self.crumbs.stringValue = crumbs.joined(separator: " › ")
        field.placeholderString = crumbs.last.map { "Search \($0)" } ?? Self.itemPlaceholder
        if model.rows.isEmpty {
            model.selection = nil
        } else {
            model.selection = selection.map { min(max($0, 0), model.rows.count - 1) } ?? 0
        }
        resizeToFit()
    }

    private func activate(_ index: Int) {
        guard model.rows.indices.contains(index) else {
            // An item whose menu could not be listed still opens the ordinary way.
            if let menu, menu.drill.entries.isEmpty {
                close()
                onActivate(.window(menu.windowID))
            }
            return
        }
        let id = model.rows[index].id
        if case .menuEntry = id {
            if !drillIn() {
                pressMenuEntry(index)
            }
            return
        }
        close()
        onActivate(id)
    }

    // MARK: - Menus

    /// Lists the selected item's menu, or opens the selected submenu. False when the selection is
    /// neither an item nor a submenu, so the key can do its usual job.
    private func drillIn() -> Bool {
        guard let selection = model.selection, model.rows.indices.contains(selection) else { return false }
        switch model.rows[selection].id {
        case .window(let windowID):
            loadMenu(of: windowID, name: model.rows[selection].appName, selection: selection)
            return true
        case .menuEntry:
            guard var menu, menuMatches.indices.contains(selection),
                  menu.drill.enter(menuMatches[selection].entry, query: field.stringValue, selection: selection)
            else { return false }
            self.menu = menu
            field.stringValue = ""
            refilter()
            return true
        case .group:
            return false
        }
    }

    private func loadMenu(of windowID: CGWindowID, name: String, selection: Int) {
        itemQuery = field.stringValue
        itemSelection = selection
        model.rows = []
        model.selection = nil
        model.emptyMessage = "Reading \(name)’s menu…"
        resizeToFit()
        menuLoad?.cancel()
        menuLoad = Task { [weak self] in
            guard let loaded = await self?.menus.read(windowID), let self, !Task.isCancelled, self.panel.isVisible else {
                if !Task.isCancelled {
                    NSSound.beep()
                    self?.refilter(selecting: selection)
                }
                return
            }
            self.menu = loaded
            self.field.stringValue = ""
            self.refilter()
        }
    }

    /// Up one submenu, or from the top of the menu back to the items with the query put back.
    private func goBack() {
        guard var menu else { return }
        if let restored = menu.drill.back() {
            self.menu = menu
            field.stringValue = restored.query
            refilter(selecting: restored.selection)
        } else {
            leaveMenu()
            field.stringValue = itemQuery
            refilter(selecting: itemSelection)
        }
    }

    private func leaveMenu() {
        menuLoad?.cancel()
        menuLoad = nil
        menu = nil
        menuMatches = []
    }

    private func pressMenuEntry(_ index: Int) {
        guard let menu, menuMatches.indices.contains(index) else { return }
        let entry = menuMatches[index].entry
        guard entry.isEnabled, let handle = menu.elements[entry.path] else {
            NSSound.beep()
            return
        }
        close()
        menus.press(handle, (menu.drill.breadcrumb + menuMatches[index].trail + [entry.title]).joined(separator: " › "))
    }

    func controlTextDidChange(_ notification: Notification) {
        refilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            model.selection = ItemSearch.moveSelection(model.selection, by: -1, count: model.rows.count)
        case #selector(NSResponder.moveDown(_:)):
            model.selection = ItemSearch.moveSelection(model.selection, by: 1, count: model.rows.count)
        case #selector(NSResponder.moveRight(_:)):
            return isCaretAtEnd(textView) && drillIn()
        case #selector(NSResponder.moveLeft(_:)):
            guard menu != nil, textView.selectedRange() == NSRange(location: 0, length: 0) else { return false }
            goBack()
        case #selector(NSResponder.deleteBackward(_:)):
            guard menu != nil, field.stringValue.isEmpty else { return false }
            goBack()
        case #selector(NSResponder.insertNewline(_:)):
            activate(model.selection ?? -1)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    private func isCaretAtEnd(_ textView: NSTextView) -> Bool {
        let range = textView.selectedRange()
        return range.length == 0 && range.location == (textView.string as NSString).length
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

// MARK: - Opening items

/// The palette, the tray, and opening an item's menu, which both of them do.
extension SomabarController {
    func toggleSearchPalette() {
        if let searchPalette, searchPalette.isVisible {
            searchPalette.close()
            return
        }
        trayWindow?.close()
        if searchPalette == nil {
            searchPalette = SearchPaletteController(menus: paletteMenuActions) { [weak self] target in
                switch target {
                case .window(let windowID): self?.activateItem(windowID: windowID)
                case .group(let id): self?.revealGroup(id)
                case .menuEntry: break  // The palette presses those itself.
                }
            }
        }
        let windows = StatusWindows.all()
        let rows = items.map { paletteRow(for: $0, windows: windows) } + groupPaletteRows
        let note = AccessibilityPermission.isTrusted
            ? "Somabar has not found any items yet"
            : "Grant Accessibility access so Somabar can find and name items"
        searchPalette?.present(rows: rows, emptyNote: note)
    }

    @objc func searchItemsAction() { toggleSearchPalette() }
    @objc func openTrayAction() { toggleTray() }

    func closeItemPanels() {
        searchPalette?.close()
        trayWindow?.close()
        groupRow?.close()
    }

    /// One row per group with members, after the items. Choosing it reveals the group's section.
    private var groupPaletteRows: [PaletteRow] {
        let layout = effectiveLayout
        return document.groups.filter { !$0.members.isEmpty }.map { group in
            let section = group.members.lazy.compactMap { layout.section(of: $0) }.first ?? .shown
            let count = group.members.count
            let symbol: String
            switch group.face {
            case .symbol(let name): symbol = name
            case .letter(let letter): symbol = "\(letter.lowercased()).square"
            }
            let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: group.name)
                ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: group.name) ?? NSImage()
            return PaletteRow(
                id: .group(group.id), appName: group.name, title: "group",
                detail: "Group of \(count) item\(count == 1 ? "" : "s")",
                tag: SearchTag(section: section, isManagedByMacOS: false), icon: icon
            )
        }
    }

    private func paletteRow(for item: DiscoveredItem, windows: [StatusWindow]) -> PaletteRow {
        let tag = SearchTag(section: barSection(of: item, in: windows), isManagedByMacOS: item.isManagedByMacOS)
        guard item.isIdentified else {
            return PaletteRow(
                id: .window(item.windowID), appName: "Unidentified item", title: "", detail: "Somabar can point at it but not open it",
                tag: tag, icon: itemImage(windowID: item.windowID, bundleID: DiscoveredItem.unknownBundleID, pid: nil)
            )
        }
        let appName = item.appName.isEmpty ? item.key.bundleID : item.appName
        var detail = item.key.title == appName ? "" : item.key.title
        if item.key.ordinal > 0 {
            detail += detail.isEmpty ? "#\(item.key.ordinal + 1)" : " (\(item.key.ordinal + 1))"
        }
        return PaletteRow(
            id: .window(item.windowID), appName: appName, title: item.key.title, detail: detail,
            tag: tag, icon: itemImage(windowID: item.windowID, bundleID: item.key.bundleID, pid: item.pid)
        )
    }

    /// Where the item sits in the bar now, read from its window rather than the last scan, since
    /// a reveal or hide since then moved every frame. macOS's own items count as Shown.
    func barSection(of item: DiscoveredItem, in windows: [StatusWindow]) -> SomabarCore.Section {
        guard !SystemItems.isManagedByMacOS(item.key), let boundaries = engine.dividerBoundaries else { return .shown }
        let frame = windows.first { $0.windowID == item.windowID }?.bounds ?? item.frame
        let observed = ObservedBar(items: [], hiddenDividerX: boundaries.hidden, tuckedDividerX: boundaries.tucked)
        return observed.section(of: PlacedItem(key: item.key, frame: frame), known: effectiveLayout)
    }

    /// Reveals the section the item lives in, then opens its menu: `AXPress` on its element, or a
    /// click on its window when it has none. Items Somabar cannot act on (Apple's, hosted,
    /// unidentified) only get the pointer placed over them.
    func activateItem(windowID: CGWindowID) {
        closeItemPanels()
        guard let item = items.first(where: { $0.windowID == windowID }) else {
            log.error("The item to open (window \(windowID)) is no longer in the bar")
            return
        }
        let section = barSection(of: item, in: StatusWindows.all())
        let needsReveal = section != .shown
        if needsReveal {
            reveal(includingTucked: section.isAlwaysHidden)
        }
        let canAct = item.isIdentified && !item.isManagedByMacOS
        let name = item.key.description
        Task { @MainActor [weak self] in
            let frame = await Self.settledFrame(of: item.windowID, fallback: item.frame, afterReveal: needsReveal)
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            guard canAct else {
                CGWarpMouseCursorPosition(centre)
                self?.log.info("Pointed at \(name, privacy: .public); Somabar does not open items it cannot manage")
                return
            }
            if let ax = item.ax, await Self.press(ax) {
                self?.log.info("Opened \(name, privacy: .public) with AXPress")
                return
            }
            do {
                try await ItemMover.click(item.windowID, at: centre)
                self?.log.info("Opened \(name, privacy: .public) with a click")
            } catch {
                CGWarpMouseCursorPosition(centre)
                self?.log.error("Could not click \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The item's window frame once the bar has laid it out: on a screen and unchanged between
    /// two looks, or whatever it is after a second.
    private static func settledFrame(of windowID: CGWindowID, fallback: CGRect, afterReveal: Bool) async -> CGRect {
        let screens = NSScreen.screens.map { ScreenGeometry.topLeft($0.frame) }
        var last = StatusWindows.all().first { $0.windowID == windowID }?.bounds ?? fallback
        guard afterReveal else { return last }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(60))
            guard let now = StatusWindows.all().first(where: { $0.windowID == windowID })?.bounds else { continue }
            let onScreen = screens.contains { $0.contains(CGPoint(x: now.midX, y: now.midY)) }
            if onScreen, now == last {
                return now
            }
            last = now
        }
        return last
    }

    /// `AXPress` off the main thread, as discovery does. A timeout counts as pressed: some apps
    /// answer only once their menu closes.
    private static func press(_ handle: AXHandle) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            AXUIElementSetMessagingTimeout(handle.element, 0.5)
            let result = AXUIElementPerformAction(handle.element, kAXPressAction as CFString)
            return result == .success || result == .cannotComplete
        }.value
    }
}
