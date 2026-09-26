import AppKit
import BarEngine
import Observation
import os
import SomabarCore
import SwiftUI

// MARK: - Shared panel

/// A borderless panel that takes the keyboard without activating Somabar, so the app the person
/// was using stays in front. The search palette and the Hidden items tray both use it.
final class SomabarPanel: NSPanel {
    /// ⎋, when no text field claims it first.
    var onCancel: (@MainActor () -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Rounded translucent backing with `content` pinned inside it.
    static func backing(for content: NSView, material: NSVisualEffectView.Material, cornerRadius: CGFloat) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }
}

/// Calls back on any click in another app, so a panel closes when the person clicks away. A
/// non-activating panel does not always lose key status when another app is clicked.
@MainActor
final class OutsideClickMonitor {
    private var monitor: Any?

    func start(_ onClick: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            MainActor.assumeIsolated { onClick() }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

/// App icons by bundle ID, falling back to the running process's icon for helpers without a bundle.
@MainActor
enum ItemIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String, pid: pid_t?) -> NSImage {
        if let cached = cache[bundleID] {
            return cached
        }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else if let pid, let running = NSRunningApplication(processIdentifier: pid)?.icon {
            icon = running
        } else {
            icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = icon
        return icon
    }
}

// MARK: - Palette

/// One line in the search palette.
struct PaletteRow: Identifiable {
    var id: CGWindowID
    var appName: String
    /// The item's own title, searched as well as shown.
    var title: String
    var detail: String
    var tag: SearchTag
    var icon: NSImage
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
            Text(row.tag.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.3) : .clear))
        .contentShape(Rectangle())
    }
}

/// The Spotlight-like search palette (⌃⌥/): type to filter every item the last scan found, ↩ or
/// a click opens the item's menu. It never activates Somabar, so the front app keeps its menus.
@MainActor
final class SearchPaletteController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let width: CGFloat = 600
    static let fieldHeight: CGFloat = 54
    static let maxVisibleRows = 8

    private let panel = SomabarPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: fieldHeight))
    private let field = NSTextField()
    private let model = PaletteModel()
    private let outsideClicks = OutsideClickMonitor()
    private let onActivate: @MainActor (CGWindowID) -> Void
    private var allRows: [PaletteRow] = []
    private var emptyNote = ""
    /// The palette's top edge stays put while its height follows the list.
    private var top: CGFloat = 0

    var isVisible: Bool { panel.isVisible }

    init(onActivate: @escaping @MainActor (CGWindowID) -> Void) {
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
        field.placeholderString = "Search menu bar items"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail

        let separator = NSBox()
        separator.boxType = .separator
        let list = NSHostingView(rootView: PaletteList(model: model) { [weak self] index in self?.activate(index) })

        let container = NSView()
        for view in [magnifier, field, separator, list] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            magnifier.centerYAnchor.constraint(equalTo: container.topAnchor, constant: Self.fieldHeight / 2),
            magnifier.widthAnchor.constraint(equalToConstant: 22),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: magnifier.centerYAnchor),
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

    private func refilter() {
        let query = field.stringValue
        let candidates = allRows.map { SearchCandidate(id: $0.id, appName: $0.appName, title: $0.title, tag: $0.tag) }
        let byID = Dictionary(allRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        model.rows = ItemSearch.rank(candidates, query: query).compactMap { byID[$0.id] }
        model.selection = model.rows.isEmpty ? nil : 0
        model.emptyMessage = allRows.isEmpty ? emptyNote : "No items match “\(query)”"
        resizeToFit()
    }

    private func activate(_ index: Int) {
        guard model.rows.indices.contains(index) else { return }
        let id = model.rows[index].id
        close()
        onActivate(id)
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
        case #selector(NSResponder.insertNewline(_:)):
            if let selection = model.selection {
                activate(selection)
            }
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
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
            searchPalette = SearchPaletteController { [weak self] windowID in self?.activateItem(windowID: windowID) }
        }
        let windows = StatusWindows.all()
        let rows = items.map { paletteRow(for: $0, windows: windows) }
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
    }

    private func paletteRow(for item: DiscoveredItem, windows: [StatusWindow]) -> PaletteRow {
        let tag = SearchTag(section: barSection(of: item, in: windows), isManagedByMacOS: item.isManagedByMacOS)
        guard item.isIdentified else {
            return PaletteRow(
                id: item.windowID, appName: "Unidentified item", title: "", detail: "Somabar can point at it but not open it",
                tag: tag, icon: itemImage(windowID: item.windowID, bundleID: DiscoveredItem.unknownBundleID, pid: nil)
            )
        }
        let appName = item.appName.isEmpty ? item.key.bundleID : item.appName
        var detail = item.key.title == appName ? "" : item.key.title
        if item.key.ordinal > 0 {
            detail += detail.isEmpty ? "#\(item.key.ordinal + 1)" : " (\(item.key.ordinal + 1))"
        }
        return PaletteRow(
            id: item.windowID, appName: appName, title: item.key.title, detail: detail,
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
