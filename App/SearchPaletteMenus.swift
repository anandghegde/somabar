import AppKit
import BarEngine
import SomabarCore

/// One status item's menu as the search palette lists it (1.1): where the palette is inside it,
/// the element behind each entry, and what to say when there is nothing to list.
struct PaletteMenu {
    var windowID: CGWindowID
    var drill: MenuDrillDown
    var icon: NSImage
    var elements: [[Int]: AXHandle]
    /// Shown when the menu has no entries Somabar could read.
    var emptyNote: String
}

/// How the palette reads an item's menu and presses an entry in it. The controller supplies both.
struct PaletteMenuActions {
    var read: @MainActor (CGWindowID) async -> PaletteMenu?
    var press: @MainActor (AXHandle, String) -> Void
}

extension PaletteRow {
    /// A line for one menu entry. Its trail, the submenus between the level shown and the entry,
    /// is the detail line, so a match found deeper down says where it lives.
    init(match: MenuMatch, icon: NSImage) {
        let entry = match.entry
        self.init(
            id: .menuEntry(entry.path), appName: entry.title, title: "", detail: match.trail.joined(separator: " › "),
            tag: nil, icon: icon, shortcut: entry.shortcut?.displayString ?? "",
            hasSubmenu: entry.hasSubmenu, isEnabled: entry.isEnabled, isChecked: entry.isChecked
        )
    }
}

extension SomabarController {
    var paletteMenuActions: PaletteMenuActions {
        PaletteMenuActions(
            read: { [weak self] windowID in await self?.paletteMenu(windowID: windowID) },
            press: { [weak self] handle, title in self?.pressMenuEntry(handle, title: title) }
        )
    }

    /// Reads the item's menu off the main thread. Nil when the item has left the bar. Items
    /// Somabar cannot act on get an empty menu with a note, as do apps that build their menu only
    /// when it opens; ↩ then opens the item as before.
    private func paletteMenu(windowID: CGWindowID) async -> PaletteMenu? {
        guard let item = items.first(where: { $0.windowID == windowID }) else { return nil }
        let name = item.appName.isEmpty ? item.key.bundleID : item.appName
        let icon = itemImage(windowID: item.windowID, bundleID: item.key.bundleID, pid: item.pid)
        guard item.isIdentified, !item.isManagedByMacOS, let ax = item.ax else {
            return PaletteMenu(
                windowID: windowID, drill: MenuDrillDown(itemName: name, root: []), icon: icon, elements: [:],
                emptyNote: "Somabar cannot read this item’s menu"
            )
        }
        let menu = await Task.detached(priority: .userInitiated) { StatusMenuReader.read(ax) }.value
        log.info("Read \(menu.elements.count) menu entries from \(item.key.description, privacy: .public)")
        return PaletteMenu(
            windowID: windowID, drill: MenuDrillDown(itemName: name, root: menu.entries), icon: icon, elements: menu.elements,
            emptyNote: "\(name) builds its menu when clicked, so it cannot be listed. ↩ opens it."
        )
    }

    /// `AXPress` on the entry, off the main thread. The item stays where it is: a menu can be
    /// pressed without being open, so nothing needs revealing.
    private func pressMenuEntry(_ handle: AXHandle, title: String) {
        closeItemPanels()
        Task { @MainActor [weak self] in
            let pressed = await Task.detached(priority: .userInitiated) { StatusMenuReader.press(handle) }.value
            if pressed {
                self?.log.info("Pressed menu entry \(title, privacy: .public)")
            } else {
                self?.log.error("Could not press menu entry \(title, privacy: .public)")
            }
        }
    }
}
