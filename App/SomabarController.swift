import AppKit
import BarEngine
import os
import SomabarCore

/// Wires the engine, the layout document, discovery, hot keys, gestures and the menu together.
///
/// Slice 2: the layout is the truth. Somabar hides, reveals, and moves items to match the
/// active profile; what the person drags is learned (`SomabarController+Layout.swift`).
@MainActor
final class SomabarController: NSObject, NSMenuDelegate {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let didOfferAccessibilityKey = "didOfferAccessibility"

    let engine: any BarEngine
    let store: DocumentStore
    var document: SomabarDocument
    var items: [DiscoveredItem] = []
    var lastScan: Date?

    let rehide = RehideController()
    let menus = MenuWatcher()
    let statusWindows = StatusWindowWatcher()
    let reconciler: BarReconciler
    var gestures: GestureMonitor?
    /// The sections the last scan showed, so a change tells a person's drag from a newcomer.
    var lastObserved: Layout?
    /// Items that arrived since the person last looked (M18: the dot on the glyph).
    var pendingNewItems: Set<ItemKey> = []
    var needsReconcile = false
    var reconcileTask: Task<Void, Never>?
    /// A scan asked for while the reconciler was dragging items; it runs once the pass ends.
    var scanAfterReconcile: String?
    var lastSavedDocument: SomabarDocument?
    let log = Logger(subsystem: "app.somabar", category: "Controller")

    /// Triggers (`SomabarController+Triggers.swift`).
    let context = ContextMonitor()
    var triggers = TriggerRuntime()
    /// The names of the triggers whose conditions hold, for the menu.
    var activeTriggerNames: [String] = []
    let triggerLog = Logger(subsystem: "app.somabar", category: "Triggers")
    /// `App/Notch/`: the notch surface, and the display rule's last decision (nil until launch).
    var notchSurface: NotchSurface?
    var displayRuleDecision: Bool?

    let hotkeys = HotkeyCenter()
    let menu = NSMenu()
    /// `SearchPalette.swift` and `TrayWindow.swift`.
    var searchPalette: SearchPaletteController?
    var trayWindow: TrayWindowController?
    /// `App/Groups/`: one glyph per group, and the row of members a glyph opens.
    var groupGlyphs: [UUID: NSStatusItem] = [:]
    var groupRow: TrayWindowController?
    var itemsWindow: ItemsWindowController?
    /// `App/Settings/`.
    var settingsWindow: SettingsWindowController?
    var scanTask: Task<Void, Never>?
    var activeScan: Task<Void, Never>?
    var pendingScanReason: String?
    var trustTask: Task<Void, Never>?
    private var didReportSaveFailure = false

    override init() {
        let engine = BarEngineFactory.make()
        self.engine = engine
        reconciler = BarReconciler(engine: engine) { await BarScanner.scan(ownFrames: engine.ownFrames) }
        store = DocumentStore(directory: DocumentStore.defaultDirectory())
        document = .makeDefault()
        super.init()
        menu.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        loadDocument()
        engine.install()
        engine.showsDividers = document.preferences.showDividers
        configureControlButton()
        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.onTarget = { [weak self] target in self?.open(target) }
        hotkeys.register(document.hotkeys, items: document.itemHotKeys)
        observeWorkspace()
        statusWindows.onChange = { [weak self] in self?.scheduleScan(after: 1.0, reason: "status windows changed") }
        statusWindows.start()
        configureGestures()
        startTriggers()
        startDisplayRules()
        startNotchSurface()
        syncGroupGlyphs()
        applySpacingAtLaunch()
        startUpdates()

        if case .glyphOnly(let reason) = engine.capability {
            log.error("\(reason, privacy: .public)")
            Task { @MainActor in self.showUnsupportedAlert(reason) }
        } else {
            Task { @MainActor in self.offerAccessibilityIfNeeded() }
        }
        scheduleScan(after: 1.0, reason: "launch")
        log.notice("Somabar \(Self.version, privacy: .public) started")
    }

    func shutdown() {
        rehide.cancel()
        menus.stop()
        statusWindows.stop()
        context.stop()
        gestures?.stop()
        stopNotchSurface()
        removeGroupGlyphs()
        scanTask?.cancel()
        activeScan?.cancel()
        reconcileTask?.cancel()
        trustTask?.cancel()
        hotkeys.unregisterAll()
        closeItemPanels()
        settingsWindow?.close()
        saveDocument(reason: "Quit")
        engine.teardown()
        restoreSpacingAtQuit()
    }

    // MARK: - Document

    private func loadDocument() {
        do {
            if let loaded = try store.load() {
                document = loaded
            } else {
                document = .makeDefault()
                try store.save(document, reason: "First launch")
            }
        } catch {
            log.error("Could not read the layout file: \(error.localizedDescription, privacy: .public). Starting from defaults.")
            quarantineBrokenDocument()
            document = .makeDefault()
        }
        lastSavedDocument = document
        if let own = Bundle.main.bundleIdentifier {
            let dropped = document.forgetItems(ofApp: own)
            if dropped > 0 {
                log.notice("Dropped \(dropped) of Somabar's own items from the layout; a second copy must have been running")
                saveDocument(reason: "Dropped Somabar's own items")
            }
        }
    }

    private func quarantineBrokenDocument() {
        let url = store.documentURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingPathExtension().appendingPathExtension("broken-\(stamp).somabar")
        try? FileManager.default.moveItem(at: url, to: target)
        log.error("Moved the unreadable layout file to \(target.lastPathComponent, privacy: .public)")
    }

    func saveDocument(reason: String) {
        guard document != lastSavedDocument else { return }
        do {
            try store.save(document, reason: reason)
            lastSavedDocument = document
            settingsWindow?.documentDidChange()
            log.info("Saved the layout: \(reason, privacy: .public)")
        } catch {
            log.error("Could not save the layout: \(error.localizedDescription, privacy: .public)")
            if !didReportSaveFailure {
                didReportSaveFailure = true
                let alert = NSAlert()
                alert.messageText = "Somabar couldn't save your layout"
                alert.informativeText = "\(error.localizedDescription)\n\nFile: \(store.documentURL.path)"
                alert.runModal()
            }
        }
    }

    // MARK: - Hot keys and URLs

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleHidden:
            toggleHidden()
        case .searchItems:
            toggleSearchPalette()
        case .openTray:
            toggleTray()
        case .cycleProfile:
            switchProfile(to: document.nextProfileName)
        case .startTimer25:
            startNotchTimer(minutes: 25)
        }
    }

    /// `somabar://toggle`, `somabar://reveal`, `somabar://hide`, `somabar://items`, `somabar://rescan`,
    /// `somabar://profile?Name`, `somabar://set?docker=on`.
    func handle(_ url: URL) {
        log.notice("URL: \(url.absoluteString, privacy: .public)")
        switch url.host()?.lowercased() {
        case "toggle": toggleHidden()
        case "reveal": reveal(includingTucked: url.query() == "tucked")
        case "hide": hideAll()
        case "items": showItems()
        case "search": toggleSearchPalette()
        case "tray": toggleTray()
        case "rescan": scanNow(reason: "url")
        case "profile": switchProfile(to: url.query(percentEncoded: false) ?? "")
        case "set": setExternalConditions(from: url)
        case "timer": handleTimerURL(url)
        case "settings": showSettings()
        default: log.error("Unknown URL: \(url.absoluteString, privacy: .public)")
        }
    }

    // MARK: - Hot keys from Settings

    /// Settings changed a combo: register the document's hot keys again.
    func hotkeysDidChange() {
        hotkeys.register(document.hotkeys, items: document.itemHotKeys)
    }

    /// While Settings records a combo, Carbon must not swallow the keystroke.
    func suspendHotkeys() {
        hotkeys.unregisterAll()
    }
}
