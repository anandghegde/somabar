import AppKit
import BarEngine
import os
import SomabarCore

/// Groups (M9) and per-item hot keys (M11).
///
/// Each group has a glyph of its own in the bar, an SF Symbol or a letter. Clicking it opens a
/// compact row of the members, the tray's panel with one row; a member opens the way the
/// search palette opens it. The members themselves always share one section, so a group moves
/// as one (`Layout.keepGroupsTogether`, `SomabarDocument.gatherGroup`).
extension SomabarController {
    private static let groupLog = Logger(subsystem: "app.somabar", category: "Groups")

    // MARK: - Glyphs

    static func groupAutosaveName(_ id: UUID) -> String {
        "somabar.group.\(id.uuidString)"
    }

    /// Adds, updates and removes the glyphs so there is one per group.
    func syncGroupGlyphs() {
        let wanted = Dictionary(document.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, statusItem) in groupGlyphs where wanted[id] == nil {
            NSStatusBar.system.removeStatusItem(statusItem)
            groupGlyphs[id] = nil
            UserDefaults.standard.removeObject(forKey: Self.preferredPositionKey(id))
        }
        for group in document.groups {
            let statusItem = groupGlyphs[group.id] ?? makeGroupGlyph(for: group.id)
            style(statusItem, for: group)
        }
    }

    /// The group glyphs' frames, top-left origin. They are Somabar's own status items, so the
    /// scan leaves them out as it does the glyph and the dividers; Accessibility cannot name them
    /// (Somabar does not query itself), and they would otherwise show as unidentified items.
    var groupGlyphFrames: [CGRect] {
        groupGlyphs.values.compactMap { $0.button?.window?.frame }.map(ScreenGeometry.topLeft)
    }

    func removeGroupGlyphs() {
        for statusItem in groupGlyphs.values {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        groupGlyphs.removeAll()
        groupRow?.close()
    }

    private static func preferredPositionKey(_ id: UUID) -> String {
        "NSStatusItem Preferred Position \(groupAutosaveName(id))"
    }

    private func makeGroupGlyph(for id: UUID) -> NSStatusItem {
        // A new status item lands at the far left, which is Tucked. The first time, ask for the
        // spot just left of Somabar's glyph instead, which is Shown. macOS keeps the position
        // under the autosave name after that.
        let key = Self.preferredPositionKey(id)
        if UserDefaults.standard.object(forKey: key) == nil,
           let glyph = engine.controlButton?.window?.frame,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: glyph.midX, y: glyph.midY)) }) {
            UserDefaults.standard.set(Double(screen.frame.maxX - glyph.minX + 1), forKey: key)
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.groupAutosaveName(id)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(groupGlyphClicked(_:))
        statusItem.button?.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        groupGlyphs[id] = statusItem
        return statusItem
    }

    private func style(_ statusItem: NSStatusItem, for group: ItemGroup) {
        guard let button = statusItem.button else { return }
        button.toolTip = "\(group.name): click for its items"
        button.imagePosition = .imageOnly
        let image: NSImage?
        switch group.face {
        case .symbol(let name):
            image = NSImage(systemSymbolName: name, accessibilityDescription: group.name)
        case .letter(let letter):
            // SF Symbols has a squared letter for a to z and 0 to 9.
            image = NSImage(systemSymbolName: "\(letter.lowercased()).square", accessibilityDescription: group.name)
        }
        if let image {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = String(group.face.text.prefix(2))
        }
    }

    @objc private func groupGlyphClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if let groupRow, groupRow.isVisible {
            groupRow.close()
            return
        }
        showGroupRow(id)
    }

    /// The compact row of a group's members, under its glyph.
    func showGroupRow(_ id: UUID) {
        guard let group = document.group(id: id), let screen = trayScreen else { return }
        closeItemPanels()
        if groupRow == nil {
            groupRow = TrayWindowController { [weak self] windowID in self?.activateItem(windowID: windowID) }
        }
        let present = Dictionary(items.filter(\.isIdentified).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let section = document.section(ofGroup: id) ?? .shown
        let row = TrayGroup(section: section, tiles: group.members.map { trayTile(for: $0, present: present) }, title: group.name)
        groupRow?.present(
            groups: [row], profileName: document.active.name, screen: screen,
            glyphFrame: groupGlyphs[id]?.button?.window?.frame,
            emptyMessage: "\(group.name) has no items yet. Add them in Settings › Groups."
        )
    }

    // MARK: - Opening from hot keys and search

    /// A per-item hot key fired: open the item's menu, or reveal the group's section.
    func open(_ target: HotKeyTarget) {
        switch target {
        case .item(let key):
            guard let item = items.first(where: { $0.key == key }) else {
                Self.groupLog.error("The item for this hot key (\(key.description, privacy: .public)) is not in the bar right now")
                NSSound.beep()
                return
            }
            activateItem(windowID: item.windowID)
        case .group(let id):
            revealGroup(id)
        }
    }

    /// Reveals the section the group's members are in. When they are already Shown, opens the
    /// group's row instead, so the shortcut always does something visible.
    func revealGroup(_ id: UUID) {
        guard let group = document.group(id: id) else {
            Self.groupLog.error("No group with id \(id.uuidString, privacy: .public)")
            return
        }
        closeItemPanels()
        let layout = effectiveLayout
        let section = group.members.lazy.compactMap { layout.section(of: $0) }.first ?? .shown
        if section == .shown {
            showGroupRow(id)
        } else {
            reveal(includingTucked: section.isAlwaysHidden)
        }
        Self.groupLog.info("Opened group \(group.name, privacy: .public) (\(section.displayName, privacy: .public))")
    }

    // MARK: - Settings

    /// Settings edited the groups: glyphs, trigger effects, hot keys and the bar follow.
    func groupsDidChange() {
        syncGroupGlyphs()
        triggersDidChange()
        hotkeysDidChange()
        abandonReconcile(reason: "groups edited")
        scanNow(reason: "groups edited")
    }

    // MARK: - Items window

    /// Moves every member of the group into `section`. The layout changes first; the rescan
    /// that follows finds the members out of place and the reconciler moves them in the bar,
    /// as it does for anything that drifts.
    func moveGroup(_ id: UUID, to section: Section) {
        let name = document.group(id: id)?.name ?? "group"
        editGroupsFromItemsWindow("Items: moved \(name) to \(section.displayName)") { (document: inout SomabarDocument) throws(GroupEditError) in
            try document.moveGroup(id, to: section)
        }
    }

    /// Puts an item in a group, or takes it out of its group with a nil id.
    func assign(_ key: ItemKey, toGroup id: UUID?) {
        guard let id else {
            editGroupsFromItemsWindow("Items: took \(key.description) out of its group") { $0.removeFromGroup(key) }
            return
        }
        let name = document.group(id: id)?.name ?? "group"
        editGroupsFromItemsWindow("Items: added \(key.description) to \(name)") { (document: inout SomabarDocument) throws(GroupEditError) in
            try document.assign(key, toGroup: id)
        }
    }

    /// A new group holding just this item, under a free name. Renaming is in Settings › Groups.
    func addGroup(with key: ItemKey) {
        editGroupsFromItemsWindow("Items: new group with \(key.description)") { (document: inout SomabarDocument) throws(GroupEditError) in
            try document.assign(key, toGroup: document.addGroup())
        }
    }

    private func editGroupsFromItemsWindow(_ reason: String, _ edit: (inout SomabarDocument) throws(GroupEditError) -> Void) {
        var edited = document
        do {
            try edit(&edited)
        } catch {
            Self.groupLog.error("\(reason, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return
        }
        guard edited != document else { return }
        document = edited
        saveDocument(reason: reason)
        groupsDidChange()
        refreshItemsWindow()
    }
}

extension ItemGroup.Face {
    var text: String {
        switch self {
        case .letter(let letter): letter
        case .symbol(let name): name
        }
    }
}
