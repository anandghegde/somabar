import AppKit
import BarEngine
import os
import SomabarCore

/// Slice 2: the layout is the truth (M16). A scan is absorbed into the document only where the
/// person moved something; everything else is reconciled to the layout by moving items.
extension SomabarController {
    /// True when Somabar can move items itself: a real backend plus Accessibility trust.
    var canMoveItems: Bool {
        engine.capability == .full && AccessibilityPermission.isTrusted
    }

    // MARK: - Absorbing a scan

    /// Folds the latest scan into the active profile. Returns true when the document changed.
    ///
    /// - An item that was where the layout said at the last scan and is elsewhere now was
    ///   dragged by the person: the layout learns.
    /// - An item that just appeared, or drifted while Somabar was not looking, goes where the
    ///   layout says; an unknown one goes where `newItemsGoTo` says (M18).
    /// - With an empty layout, or when Somabar cannot move items, the bar is adopted as it is.
    func absorbScan() -> Bool {
        guard let boundaries = engine.dividerBoundaries else { return false }
        let identified = items.filter(\.isIdentified)
        guard !identified.isEmpty else { return false }
        let managed = Set(identified.filter(\.isManagedByMacOS).map(\.key))
        let observed = ObservedBar(items: identified.map(\.placed), hiddenDividerX: boundaries.hidden, tuckedDividerX: boundaries.tucked)
        var profile = document.active
        // What the bar should show: the stored layout with the trigger effects laid over it.
        let desired = effectiveLayout
        let seen = observed.layout(known: desired)
        let previous = lastObserved
        lastObserved = seen
        let before = profile.layout
        let adoptEverything = before.isEmpty || !canMoveItems

        let baseline = ScanBaseline(before: before, desired: desired, previous: previous, adoptEverything: adoptEverything, managed: managed)
        var sorted = Self.sort(seen: seen, against: baseline)
        var layout = sorted.layout
        let newKeys = sorted.newKeys
        for key in newKeys where adoptEverything || managed.contains(key) {
            layout.insertIfNew(key, in: seen.section(of: key) ?? .shown)
        }
        // Items still in the section the layout wants take the order the bar shows.
        for section in Section.barOrder {
            let onBar = seen[section].filter { layout.section(of: $0) == section }
            layout[section] = onBar + layout[section].filter { !onBar.contains($0) }
        }
        profile.layout = layout
        let guarded = guardNotch(&profile, observed: observed, managed: managed)
        document.update(profile)
        suspendTriggers(for: sorted.movedByPerson)

        let arrivals = document.insertNewItems(newKeys.filter { !managed.contains($0) })
        for key in arrivals where !adoptEverything {
            let wanted = effectiveLayout.section(of: key) ?? .shown
            if let actual = seen.section(of: key), actual != wanted {
                sorted.drifts.append(Drift(item: key, expected: wanted, actual: actual))
            }
        }
        if !arrivals.isEmpty, !before.isEmpty {
            pendingNewItems.formUnion(arrivals)
            engine.showsNewItemsDot = true
            pulseNotchForNewItems(arrivals)
            log.notice("New items:\(arrivals.map(\.description).joined(separator: ", "), privacy: .public)")
        }
        let drifts = reconciler.actionable(sorted.drifts + guardDrifts(observed: observed, for: guarded))
        needsReconcile = canMoveItems && !drifts.isEmpty
        if !drifts.isEmpty {
            let summary = drifts.map { "\($0.item.description) \($0.actual.displayName)→\($0.expected.displayName)" }
            log.info("Drift: \(summary.joined(separator: ", "), privacy: .public)")
        }
        return document != lastSavedDocument
    }

    /// What the bar shows, split into learned moves (applied to the layout), unknown items, and drift.
    struct SortedScan {
        var layout: Layout
        var newKeys: [ItemKey] = []
        var drifts: [Drift] = []
        /// Items whose move was the person's doing, in case a trigger holds them.
        var movedByPerson: [ItemKey] = []
    }

    /// The layouts a scan is sorted against.
    struct ScanBaseline {
        /// The stored layout, where learned moves go.
        var before: Layout
        /// What the bar should show: the stored layout plus trigger effects.
        var desired: Layout
        /// What the last scan showed, so a change tells a person's drag from drift.
        var previous: Layout?
        var adoptEverything: Bool
        var managed: Set<ItemKey>
    }

    private static func sort(seen: Layout, against baseline: ScanBaseline) -> SortedScan {
        var sorted = SortedScan(layout: baseline.before)
        for section in Section.barOrder {
            for key in seen[section] {
                guard let wanted = baseline.desired.section(of: key) else {
                    sorted.newKeys.append(key)
                    continue
                }
                guard wanted != section else { continue }
                let personMovedIt = baseline.previous?.section(of: key) == wanted
                if baseline.adoptEverything || personMovedIt || baseline.managed.contains(key) {
                    sorted.layout.move(key, to: section)
                    if personMovedIt { sorted.movedByPerson.append(key) }
                } else {
                    sorted.drifts.append(Drift(item: key, expected: wanted, actual: section))
                }
            }
        }
        return sorted
    }

    /// Items the person has not looked at since they arrived Shown (M18).
    func clearNewItemsDot() {
        pendingNewItems = []
        engine.showsNewItemsDot = false
    }

    // MARK: - Notch guard (M6)

    /// Moves Shown items that fall under the camera housing into Hidden, and brings them back
    /// when the bar has room. Only the layout changes here; the reconciler moves the items.
    /// Returns the items the guard moved.
    private func guardNotch(_ profile: inout Profile, observed: ObservedBar, managed: Set<ItemKey>) -> Set<ItemKey> {
        guard canMoveItems, document.preferences.notchGuard, let notchMaxX = Self.notchMaxX() else { return [] }
        let shown = observed.items.filter { observed.section(of: $0, known: profile.layout) == .shown && !managed.contains($0.key) }
        let plan = NotchGuard.plan(shown: shown, notchMaxX: notchMaxX, guarded: profile.notchGuarded)
        guard !plan.isEmpty else { return [] }
        for guarded in plan.hide {
            profile.layout.move(guarded.key, to: .hidden)
            profile.notchGuarded.removeAll { $0.key == guarded.key }
            profile.notchGuarded.append(guarded)
        }
        for key in plan.restore {
            profile.layout.move(key, to: .shown, at: 0)
            profile.notchGuarded.removeAll { $0.key == key }
        }
        log.notice("Notch guard: hid \(plan.hide.count), restored \(plan.restore.count)")
        return Set(plan.hide.map(\.key)).union(plan.restore)
    }

    /// Drift the guard just created, so the reconciler runs for it. Every other drift is already
    /// in the sorted scan; listing it again here would move an item twice.
    private func guardDrifts(observed: ObservedBar, for keys: Set<ItemKey>) -> [Drift] {
        guard !keys.isEmpty else { return [] }
        let layout = effectiveLayout
        return Reconciler.drift(desired: layout, observed: observed.layout(known: layout)).filter { keys.contains($0.item) }
    }

    /// The right edge of the notch on the built-in display, when it is the primary display and
    /// has one. Frames from the window list hang off the primary display's top-left corner.
    static func notchMaxX() -> CGFloat? {
        guard let screen = ScreenGeometry.builtInScreen, screen == ScreenGeometry.primaryScreen else { return nil }
        return ScreenGeometry.notchGeometry(for: screen).notchMaxX
    }

    // MARK: - Reconciling

    /// Moves drifted items to where the layout says, once, then rescans.
    func reconcileBar(reason: String) {
        guard canMoveItems, needsReconcile, !reconciler.isRunning, reconcileTask == nil else { return }
        needsReconcile = false
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reconcileTask = nil }
            let wasRevealed = self.engine.isHiddenRevealed
            self.rehide.cancel()
            let outcome = await self.reconciler.run(desired: self.effectiveLayout)
            self.log.notice("Reconciled the bar (\(reason, privacy: .public)): \(outcome.description, privacy: .public)")
            if let waiting = self.scanAfterReconcile {
                self.scanAfterReconcile = nil
                self.scheduleScan(after: 0.6, reason: waiting)
            } else if outcome.moved > 0 || outcome.abandoned {
                self.scheduleScan(after: 0.6, reason: "after reconcile")
            }
            if wasRevealed, self.engine.isHiddenRevealed {
                self.scheduleRehide()
            }
        }
    }

    /// The layout the bar should show has changed. A pass in flight would keep moving items
    /// toward the old one, so it stops after the move it is on; the scan that follows the
    /// change starts a fresh pass for the new layout.
    func abandonReconcile(reason: String) {
        guard let task = reconcileTask else { return }
        task.cancel()
        log.notice("Layout changed (\(reason, privacy: .public)); stopping the reconcile in flight")
    }

    // MARK: - Profiles

    func switchProfile(to name: String) {
        guard let profile = document.profile(named: name) else {
            log.error("No profile named \(name, privacy: .public)")
            return
        }
        guard profile.name != document.activeProfile else { return }
        document.activeProfile = profile.name
        if document.profileBeforeTriggers != nil {
            // The person's choice wins over the trigger's; nothing to go back to when it ends.
            document.profileBeforeTriggers = nil
            triggerLog.notice("Profile picked by hand while a trigger holds one; the trigger will not switch back")
        }
        // The bar shows the old profile; nothing in it is the person's doing for the new one.
        lastObserved = nil
        saveDocument(reason: "Switched to \(profile.name)")
        log.notice("Switched to profile \(profile.name, privacy: .public)")
        activities.settingsChanged()
        abandonReconcile(reason: "profile \(profile.name)")
        scanNow(reason: "profile \(profile.name)")
    }

    // MARK: - Gestures and menus

    func configureGestures() {
        guard engine.capability == .full else { return }
        let monitor = GestureMonitor(engine: engine, gestures: document.preferences.revealGestures)
        monitor.isRevealed = { [weak self] in self?.isRevealed ?? false }
        monitor.onAction = { [weak self] action in self?.apply(gesture: action) }
        monitor.start()
        gestures = monitor
        engine.onDividerClick = { [weak self] in self?.gestures?.clickOnEmptyBar() }
        rehide.isMenuOpen = { [weak self] in self?.menus.isMenuOpen ?? false }
        menus.onMenuClosed = { [weak self] in self?.menuClosed() }
    }

    func apply(gesture action: RevealGestureRecognizer.Action) {
        switch action {
        case .reveal:
            guard !isRevealed else { return }
            reveal(includingTucked: false)
        case .hide:
            guard isRevealed else { return }
            hideAll()
        }
    }

    func menuClosed() {
        guard let delay = RehidePolicy.delayAfterMenuClosed(preferences: document.preferences, revealed: isRevealed) else { return }
        rehide.onFire = { [weak self] in self?.hideAll() }
        rehide.schedule(after: delay)
    }
}
