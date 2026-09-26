import ApplicationServices
import Foundation
import SomabarCore

/// A status item's menu as Accessibility shows it while closed, and the element behind each entry.
public struct StatusMenu: Sendable {
    public var entries: [MenuEntry]
    /// Keyed by `MenuEntry.path`.
    public var elements: [[Int]: AXHandle]
}

/// Reads the menu under a status item's `AXMenuBarItem`: its `AXMenu` child, and each submenu's
/// below that. Only menus the app attached ahead of time are there; an app that builds its menu
/// when clicked shows none until it is open. Separators and untitled custom views are left out.
/// Blocking; call it off the main thread.
public enum StatusMenuReader {
    /// Submenus nested deeper than this are listed without their entries.
    public static let maxDepth = 6
    public static let messagingTimeoutSeconds: Float = 0.5

    public static func read(_ item: AXHandle) -> StatusMenu {
        AXUIElementSetMessagingTimeout(item.element, messagingTimeoutSeconds)
        var elements: [[Int]: AXHandle] = [:]
        let entries = menuElement(under: item.element).map { readEntries(of: $0, path: [], depth: 0, elements: &elements) } ?? []
        return StatusMenu(entries: entries, elements: elements)
    }

    /// `AXPress` on a menu entry. A timeout counts as pressed, as it does for the item itself.
    public static func press(_ handle: AXHandle) -> Bool {
        AXUIElementSetMessagingTimeout(handle.element, messagingTimeoutSeconds)
        let result = AXUIElementPerformAction(handle.element, kAXPressAction as CFString)
        return result == .success || result == .cannotComplete
    }

    // MARK: - Walking

    private static func menuElement(under element: AXUIElement) -> AXUIElement? {
        children(of: element).first { string(kAXRoleAttribute, of: $0) == kAXMenuRole }
    }

    private static func readEntries(of menu: AXUIElement, path: [Int], depth: Int, elements: inout [[Int]: AXHandle]) -> [MenuEntry] {
        children(of: menu).enumerated().compactMap { index, child -> MenuEntry? in
            guard string(kAXRoleAttribute, of: child) == kAXMenuItemRole else { return nil }
            let title = MenuEntry.displayTitle(string(kAXTitleAttribute, of: child))
                ?? MenuEntry.displayTitle(string(kAXDescriptionAttribute, of: child))
            guard let title else { return nil }
            let entryPath = path + [index]
            elements[entryPath] = AXHandle(child)
            let submenu = depth < maxDepth ? menuElement(under: child) : nil
            let mark = string(kAXMenuItemMarkCharAttribute, of: child) ?? ""
            return MenuEntry(
                path: entryPath, title: title,
                isEnabled: bool(kAXEnabledAttribute, of: child) ?? true,
                isChecked: !mark.trimmingCharacters(in: .whitespaces).isEmpty,
                shortcut: MenuShortcut(
                    axKey: string(kAXMenuItemCmdCharAttribute, of: child),
                    axModifiers: (value(kAXMenuItemCmdModifiersAttribute, of: child) as? NSNumber)?.intValue ?? 0
                ),
                children: submenu.map { readEntries(of: $0, path: entryPath, depth: depth + 1, elements: &elements) } ?? []
            )
        }
    }

    // MARK: - Attribute helpers

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let array = value(kAXChildrenAttribute, of: element) as? [AnyObject] else { return [] }
        return array.compactMap { object in
            CFGetTypeID(object) == AXUIElementGetTypeID() ? unsafeDowncast(object, to: AXUIElement.self) : nil
        }
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        value(attribute, of: element) as? String
    }

    private static func bool(_ attribute: String, of element: AXUIElement) -> Bool? {
        (value(attribute, of: element) as? NSNumber)?.boolValue
    }
}
