import AppKit
import BarEngine
import os
import SomabarCore

/// Discovery: scanning the bar, learning from it, the Items window, and workspace events that ask for a scan.
extension SomabarController {
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

    // MARK: - Items window

    func showItems() {
        clearNewItemsDot()
        if itemsWindow == nil {
            itemsWindow = ItemsWindowController(actions: ItemsActions(
                rescan: { [weak self] in self?.scanNow(reason: "items window") },
                grantAccess: { [weak self] in self?.requestAccessibility() },
                moveGroup: { [weak self] id, section in self?.moveGroup(id, to: section) },
                assign: { [weak self] key, id in self?.assign(key, toGroup: id) },
                newGroup: { [weak self] key in self?.addGroup(with: key) }
            ))
        }
        refreshItemsWindow()
        itemsWindow?.present()
    }

    func refreshItemsWindow() {
        guard let itemsWindow else { return }
        var note: String?
        if case .glyphOnly(let reason) = engine.capability {
            note = reason
        }
        itemsWindow.model.canMoveItems = canMoveItems
        itemsWindow.update(document: document, items: items, unidentifiedBySection: unidentifiedBySection, lastScan: lastScan, backendNote: note)
    }

    // MARK: - Workspace events

    func observeWorkspace() {
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
