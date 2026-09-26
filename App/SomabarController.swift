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
    private(set) var items: [DiscoveredItem] = []
    private(set) var lastScan: Date?

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

    private let hotkeys = HotkeyCenter()
    private let menu = NSMenu()
    /// `SearchPalette.swift` and `TrayWindow.swift`.
    var searchPalette: SearchPaletteController?
    var trayWindow: TrayWindowController?
    private var itemsWindow: ItemsWindowController?
    /// `App/Settings/`.
    var settingsWindow: SettingsWindowController?
    private var scanTask: Task<Void, Never>?
    private var activeScan: Task<Void, Never>?
    private var pendingScanReason: String?
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
        hotkeys.register(document.hotkeys)
        observeWorkspace()
        statusWindows.onChange = { [weak self] in self?.scheduleScan(after: 1.0, reason: "status windows changed") }
        statusWindows.start()
        configureGestures()
        startTriggers()
        startDisplayRules()
        startNotchSurface()
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

    // MARK: - Hide and reveal

    var isRevealed: Bool { engine.isHiddenRevealed }

    func reveal(includingTucked: Bool) {
        guard !reconciler.isRunning else { return }
        engine.setHiddenRevealed(true)
        if includingTucked {
            engine.setTuckedRevealed(true)
        }
        clearNewItemsDot()
        menus.start()
        scheduleRehide()
        scheduleScan(after: 0.6, reason: "reveal")
    }

    func hideAll() {
        guard !reconciler.isRunning else { return }
        engine.setTuckedRevealed(false)
        engine.setHiddenRevealed(false)
        rehide.cancel()
        menus.stop()
        scheduleScan(after: 0.6, reason: "hide")
    }

    func toggleHidden() {
        if engine.isHiddenRevealed {
            hideAll()
        } else {
            reveal(includingTucked: false)
        }
    }

    func toggleTucked() {
        if engine.isTuckedRevealed {
            hideAll()
        } else {
            reveal(includingTucked: true)
        }
    }

    func scheduleRehide() {
        let seconds = document.preferences.rehideAfterSeconds
        guard seconds > 0, !document.preferences.stillMode else {
            rehide.cancel()
            return
        }
        rehide.onFire = { [weak self] in self?.hideAll() }
        rehide.schedule(after: seconds)
    }

    // MARK: - Discovery and learning

    func scheduleScan(after seconds: Double, reason: String) {
        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.scanNow(reason: reason)
        }
    }

    /// Scans on the next turn; a scan already running finishes first and this one follows it.
    func scanNow(reason: String) {
        pendingScanReason = reason
        guard activeScan == nil else { return }
        activeScan = Task { @MainActor [weak self] in
            while let self, let reason = self.pendingScanReason {
                self.pendingScanReason = nil
                await self.performScan(reason: reason)
            }
            self?.activeScan = nil
        }
    }

    private func performScan(reason: String) async {
        // While the reconciler drags items a scan sees one mid-move and could learn from it.
        guard !reconciler.isRunning else {
            scanAfterReconcile = reason
            log.info("Scan (\(reason, privacy: .public)) waits for the reconcile to end")
            return
        }
        let found = await BarScanner.scan(ownFrames: engine.ownFrames)
        items = found
        lastScan = Date()
        refreshItemImages()
        // Before absorbing: a screen-sharing trigger changes what the bar should look like.
        context.setScreenShared(found.contains { $0.key.bundleID == SystemItems.screenSharingAgent })
        if absorbScan() {
            saveDocument(reason: "Learned from the bar")
        }
        refreshItemsWindow()
        let identified = found.filter(\.isIdentified).count
        log.info("Scanned the bar (\(reason, privacy: .public)): \(found.count) items, \(identified) identified, trusted: \(AccessibilityPermission.isTrusted)")
        if needsReconcile {
            reconcileBar(reason: reason)
        }
    }

    /// Items the scan saw but could not attribute to an app, placed by section.
    private var unidentifiedBySection: [SomabarCore.Section: Int] {
        guard let boundaries = engine.dividerBoundaries else { return [:] }
        let unknown = items.filter { !$0.isIdentified }
        let observed = ObservedBar(items: unknown.map(\.placed), hiddenDividerX: boundaries.hidden, tuckedDividerX: boundaries.tucked)
        let layout = observed.layout(known: Layout())
        var counts: [SomabarCore.Section: Int] = [:]
        for section in SomabarCore.Section.allCases where !layout[section].isEmpty {
            counts[section] = layout[section].count
        }
        return counts
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

    // MARK: - Glyph and menu

    private func configureControlButton() {
        guard let button = engine.controlButton else { return }
        button.target = self
        button.action = #selector(controlClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func controlClicked(_ sender: NSStatusBarButton) {
        guard !ItemMover.isMoving else { return }
        log.notice("Glyph clicked: \(NSApp.currentEvent.map { String(describing: $0.type) } ?? "no event", privacy: .public)")
        guard let event = NSApp.currentEvent else {
            toggleHidden()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        } else if event.modifierFlags.contains(.option) {
            toggleTucked()
        } else {
            toggleHidden()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = menu.addItem(withTitle: engine.isHiddenRevealed ? "Hide Items" : "Reveal Hidden Items",
                                  action: #selector(toggleHiddenAction), keyEquivalent: "")
        apply(document.combo(for: .toggleHidden), to: toggle)
        menu.addItem(withTitle: engine.isTuckedRevealed ? "Hide Tucked Items" : "Reveal Tucked Items Too",
                     action: #selector(toggleTuckedAction), keyEquivalent: "")
        menu.addItem(.separator())

        let searchItem = menu.addItem(withTitle: "Search Items…", action: #selector(searchItemsAction), keyEquivalent: "")
        apply(document.combo(for: .searchItems), to: searchItem)
        let trayItem = menu.addItem(withTitle: "Hidden Items Tray…", action: #selector(openTrayAction), keyEquivalent: "")
        apply(document.combo(for: .openTray), to: trayItem)
        menu.addItem(withTitle: "Items…", action: #selector(showItemsAction), keyEquivalent: "")

        let profiles = NSMenu()
        for profile in document.profiles {
            let item = profiles.addItem(withTitle: profile.name, action: #selector(switchProfileAction(_:)), keyEquivalent: "")
            item.state = profile.name == document.activeProfile ? .on : .off
            item.representedObject = profile.name
            item.target = self
        }
        if !canMoveItems {
            profiles.addItem(.separator())
            let note = profiles.addItem(withTitle: "Rearranging items needs Accessibility access", action: nil, keyEquivalent: "")
            note.isEnabled = false
        }
        let profileItem = menu.addItem(withTitle: "Profile", action: nil, keyEquivalent: "")
        apply(document.combo(for: .cycleProfile), to: profileItem)
        profileItem.submenu = profiles
        addTriggersMenu(to: menu)
        menu.addItem(.separator())

        let dividers = menu.addItem(withTitle: "Show Dividers", action: #selector(toggleDividersAction), keyEquivalent: "")
        dividers.state = engine.showsDividers ? .on : .off
        menu.addItem(withTitle: "Rescan Menu Bar", action: #selector(rescanAction), keyEquivalent: "")
        menu.addItem(withTitle: "Reset Somabar's Positions", action: #selector(resetPositionsAction), keyEquivalent: "")
        if !AccessibilityPermission.isTrusted {
            menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(grantAccessAction), keyEquivalent: "")
        }
        addUpdatesItem(to: menu)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",")
        menu.addItem(.separator())

        let about: String
        switch engine.capability {
        case .full: about = "Somabar \(Self.version) · macOS 26 backend"
        case .glyphOnly: about = "Somabar \(Self.version) · no backend for this macOS"
        }
        menu.addItem(withTitle: about, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Quit Somabar", action: #selector(quitAction), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    private func apply(_ combo: KeyCombo?, to item: NSMenuItem) {
        guard let combo else { return }
        item.keyEquivalent = KeyCodes.menuKeyEquivalent(for: combo.key)
        item.keyEquivalentModifierMask = KeyCodes.modifierFlags(combo.modifiers)
    }

    @objc private func toggleHiddenAction() { toggleHidden() }
    @objc private func toggleTuckedAction() { toggleTucked() }
    @objc private func showItemsAction() { showItems() }
    @objc private func rescanAction() { scanNow(reason: "menu") }
    @objc private func quitAction() { NSApp.terminate(nil) }

    @objc private func switchProfileAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        switchProfile(to: name)
    }

    @objc private func toggleDividersAction() {
        engine.showsDividers.toggle()
        document.preferences.showDividers = engine.showsDividers
        saveDocument(reason: engine.showsDividers ? "Showed dividers" : "Hid dividers")
    }

    @objc private func resetPositionsAction() {
        engine.resetPositions()
        scheduleScan(after: 1.0, reason: "reset positions")
    }

    @objc private func grantAccessAction() {
        requestAccessibility()
    }

    // MARK: - Hot keys from Settings

    /// Settings changed a combo: register the document's hot keys again.
    func hotkeysDidChange() {
        hotkeys.register(document.hotkeys)
    }

    /// While Settings records a combo, Carbon must not swallow the keystroke.
    func suspendHotkeys() {
        hotkeys.unregisterAll()
    }

    // MARK: - Items window

    func showItems() {
        clearNewItemsDot()
        if itemsWindow == nil {
            itemsWindow = ItemsWindowController(
                onRescan: { [weak self] in self?.scanNow(reason: "items window") },
                onGrantAccess: { [weak self] in self?.requestAccessibility() }
            )
        }
        refreshItemsWindow()
        itemsWindow?.present()
    }

    private func refreshItemsWindow() {
        guard let itemsWindow else { return }
        var note: String?
        if case .glyphOnly(let reason) = engine.capability {
            note = reason
        }
        itemsWindow.update(document: document, items: items, unidentifiedBySection: unidentifiedBySection, lastScan: lastScan, backendNote: note)
    }

    // MARK: - Workspace events

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func appActivated(_ notification: Notification) {
        guard engine.isHiddenRevealed, document.preferences.rehideWhenAppChanges, !document.preferences.stillMode else { return }
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        // Not straight away: the click that switched apps may have been on a revealed item.
        rehide.onFire = { [weak self] in self?.hideAll() }
        rehide.schedule(after: 1.0)
    }

    @objc private func appsChanged(_ notification: Notification) {
        scheduleScan(after: 2.0, reason: "apps changed")
    }
}
