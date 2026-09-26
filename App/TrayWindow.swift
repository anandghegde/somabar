import AppKit
import BarEngine
import Observation
import SomabarCore
import SwiftUI

/// One tile in the tray: the app's icon with the item's title under it.
struct TrayTile: Identifiable {
    var key: ItemKey
    var title: String
    var appName: String
    var icon: NSImage
    /// Nil when the layout remembers the item but its app is not showing it right now.
    var windowID: CGWindowID?

    var id: ItemKey { key }
}

struct TrayGroup: Identifiable {
    var section: SomabarCore.Section
    var tiles: [TrayTile]

    var id: SomabarCore.Section { section }
}

@Observable
@MainActor
final class TrayModel {
    var groups: [TrayGroup] = []
    var profileName = ""
}

struct TrayView: View {
    static let columns = 5
    static let tileWidth: CGFloat = 84

    var model: TrayModel
    var onActivate: @MainActor (TrayTile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.groups.allSatisfy(\.tiles.isEmpty) {
                Text("Nothing is hidden in \(model.profileName)")
                    .foregroundStyle(.secondary)
                    .frame(width: Self.tileWidth * 3)
                    .padding(.vertical, 12)
            }
            ForEach(model.groups.filter { !$0.tiles.isEmpty }) { group in
                Text(group.section.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                    ForEach(group.tiles) { tile in
                        TrayTileView(tile: tile) { onActivate(tile) }
                    }
                }
            }
        }
        .padding(12)
        .fixedSize()
    }

    /// Every group shares the widest group's column count, so the tiles line up.
    private var gridColumns: [GridItem] {
        let widest = model.groups.map(\.tiles.count).max() ?? 1
        let count = max(1, min(widest, Self.columns))
        return Array(repeating: GridItem(.fixed(Self.tileWidth), spacing: 4), count: count)
    }
}

struct TrayTileView: View {
    var tile: TrayTile
    var action: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(nsImage: tile.icon)
                    .resizable()
                    .frame(width: 40, height: 40)
                Text(tile.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: TrayView.tileWidth - 8, height: 30, alignment: .top)
            }
            .padding(.vertical, 6)
            .frame(width: TrayView.tileWidth)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovered && tile.windowID != nil ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(tile.windowID == nil)
        .opacity(tile.windowID == nil ? 0.45 : 1)
        .help(tile.windowID == nil ? "\(tile.appName) is not showing this item right now" : tile.appName)
        .onHover { isHovered = $0 }
    }
}

/// The Hidden items tray (⌃⌥↓): the active profile's Hidden and Tucked items as a grid hanging
/// under the menu bar. It never reveals the bar; clicking a tile opens that item the way the
/// search palette does.
@MainActor
final class TrayWindowController: NSObject, NSWindowDelegate {
    /// Gap between the menu bar and the tray, and the tray and a screen edge.
    static let margin: CGFloat = 6

    private let panel = SomabarPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120))
    private let model = TrayModel()
    private let hosting: NSHostingView<TrayView>
    private let outsideClicks = OutsideClickMonitor()

    var isVisible: Bool { panel.isVisible }

    init(onActivate: @escaping @MainActor (CGWindowID) -> Void) {
        let onTile: @MainActor (TrayTile) -> Void = { tile in
            if let windowID = tile.windowID {
                onActivate(windowID)
            }
        }
        hosting = NSHostingView(rootView: TrayView(model: model, onActivate: onTile))
        super.init()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = SomabarPanel.backing(for: hosting, material: .menu, cornerRadius: 10)
    }

    /// Shows `groups` on `screen`, under the glyph when the glyph is on that screen.
    func present(groups: [TrayGroup], profileName: String, screen: NSScreen, glyphFrame: NSRect?) {
        model.groups = groups
        model.profileName = profileName
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let frame = Self.frame(
            size: size, screen: screen.frame, menuBarHeight: ScreenGeometry.menuBarHeight(of: screen), glyphFrame: glyphFrame
        )
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        outsideClicks.start { [weak self] in self?.close() }
    }

    func close() {
        outsideClicks.stop()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Centred under the glyph when it is on this screen, else at the top-right, kept on screen.
    /// AppKit coordinates.
    static func frame(size: CGSize, screen: NSRect, menuBarHeight: CGFloat, glyphFrame: NSRect?) -> NSRect {
        let top = screen.maxY - menuBarHeight - margin
        var x = screen.maxX - size.width - margin
        if let glyph = glyphFrame, glyph.midX >= screen.minX, glyph.midX <= screen.maxX {
            x = glyph.midX - size.width / 2
        }
        x = min(max(x, screen.minX + margin), screen.maxX - size.width - margin)
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}

extension SomabarController {
    func toggleTray() {
        if let trayWindow, trayWindow.isVisible {
            trayWindow.close()
            return
        }
        searchPalette?.close()
        if trayWindow == nil {
            trayWindow = TrayWindowController { [weak self] windowID in self?.activateItem(windowID: windowID) }
        }
        guard let screen = trayScreen else { return }
        let layout = effectiveLayout
        let present = Dictionary(items.filter(\.isIdentified).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = [SomabarCore.Section.hidden, .tucked].map { section in
            TrayGroup(section: section, tiles: layout[section].map { key in
                let item = present[key]
                let appName = item?.appName ?? key.bundleID
                var title = key.title.isEmpty ? appName : key.title
                if key.ordinal > 0 {
                    title += " (\(key.ordinal + 1))"
                }
                return TrayTile(
                    key: key, title: title, appName: appName,
                    icon: ItemIcons.icon(bundleID: key.bundleID, pid: item?.pid), windowID: item?.windowID
                )
            })
        }
        trayWindow?.present(groups: groups, profileName: document.active.name, screen: screen, glyphFrame: engine.controlButton?.window?.frame)
    }

    /// The built-in display when the display rule asks for it and there is one, else the screen
    /// with the pointer.
    private var trayScreen: NSScreen? {
        if document.preferences.displayRules.trayOnlyOnBuiltInDisplay, let builtIn = ScreenGeometry.builtInScreen {
            return builtIn
        }
        return ScreenGeometry.screen(containingAppKitPoint: NSEvent.mouseLocation) ?? NSScreen.main ?? ScreenGeometry.primaryScreen
    }
}
