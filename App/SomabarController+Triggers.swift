import AppKit
import os
import SomabarCore

/// Triggers: *when [condition], [show / hide / switch profile], until [condition ends].*
///
/// The `ContextMonitor` reports what the Mac is doing, the `TriggerEvaluator` says which
/// triggers hold, and the `TriggerRuntime` turns that into effects over time. Show and hide
/// effects never touch the stored layout: the bar is reconciled to `effectiveLayout`, which
/// lays them over the active profile.
extension SomabarController {
    /// The active profile's layout with the current trigger effects laid over it: what the bar
    /// should look like right now.
    var effectiveLayout: Layout {
        // Display rules first (M12, `App/Notch/SomabarController+Notch.swift`), so a trigger's hide
        // still wins on a wide display.
        document.preferences.displayRules
            .apply(to: document.active.layout, screenWidthPoints: displayRuleWidthPoints)
            .applying(triggers.applied)
    }

    func startTriggers() {
        context.onChange = { [weak self] reason in self?.evaluateTriggers(reason: reason) }
        context.wantsClock = document.triggersDependOnTime
        context.start()
        // The icon-change condition's detector and real item images (`App/ItemImages/`).
        startItemImages()
        evaluateTriggers(reason: "launch")
    }

    /// Evaluates every trigger against the current context and acts on what changed.
    func evaluateTriggers(reason: String) {
        let evaluator = TriggerEvaluator(knownRouters: Set(document.preferences.knownRouters))
        let snapshot = context.snapshot
        let holding = document.triggers.filter { $0.isEnabled && evaluator.holds($0.condition, in: snapshot) }
        let names = holding.map(\.displayName)
        let previousNames = activeTriggerNames
        if names != activeTriggerNames {
            activeTriggerNames = names
            let list = names.isEmpty ? "none" : names.joined(separator: ", ")
            triggerLog.notice("Triggers holding (\(reason, privacy: .public)): \(list, privacy: .public)")
            settingsWindow?.documentDidChange()
        }

        let hadProfileMemory = document.profileBeforeTriggers != nil
        let outcome = triggers.apply(evaluator.effects(of: holding, in: snapshot), to: &document)
        if let name = outcome.unknownProfile {
            triggerLog.error("A trigger asks for the profile \(name, privacy: .public), which the layout file does not have")
        }
        switch outcome.profileChange {
        case .switched(let name):
            lastObserved = nil
            triggerLog.notice("Switched to profile \(name, privacy: .public) by trigger")
            saveDocument(reason: "Trigger switched to \(name)")
        case .restored(let name):
            lastObserved = nil
            triggerLog.notice("Trigger ended; back to profile \(name, privacy: .public)")
            saveDocument(reason: "Back to \(name) after a trigger")
        case nil:
            if hadProfileMemory, document.profileBeforeTriggers == nil {
                saveDocument(reason: "Trigger ended")
            }
        }
        if outcome.layoutChanged {
            let applied = triggers.applied
            let show = applied.show.map(\.description).joined(separator: ", ")
            let hide = applied.hide.map(\.description).joined(separator: ", ")
            triggerLog.notice("Triggers apply: show [\(show, privacy: .public)], hide [\(hide, privacy: .public)]")
        }
        if outcome.layoutChanged || outcome.profileChange != nil {
            abandonReconcile(reason: "triggers: \(reason)")
            scanNow(reason: "triggers: \(reason)")
        }
        var switchedTo: String?
        if case .switched(let name) = outcome.profileChange { switchedTo = name }
        announce(started: holding.filter { !previousNames.contains($0.displayName) }, holding: holding, switchedTo: switchedTo, reason: reason)
    }

    /// Tells the notch (`.somabarTriggerFired`) and, when the person asked for it, Notification
    /// Center that triggers started holding or one switched profile.
    private func announce(started: [Trigger], holding: [Trigger], switchedTo profile: String?, reason: String) {
        var fired = started
        if let profile, let switcher = holding.last(where: { $0.action == .switchProfile(name: profile) }),
           !fired.contains(where: { $0.id == switcher.id }) {
            fired.append(switcher)
        }
        guard !fired.isEmpty else { return }
        let names = fired.map(\.displayName)
        NotificationCenter.default.post(name: .somabarTriggerFired, object: nil, userInfo: ["names": names])
        // Not at launch: triggers that already held when Somabar quit would announce themselves
        // on every start.
        guard document.preferences.notifyWhenTriggerFires, reason != "launch" else { return }
        let lines = fired.map { trigger in
            if let profile, trigger.action == .switchProfile(name: profile) {
                return "Switched to \(profile) by \(trigger.displayName)"
            }
            return "\(trigger.displayName) is holding"
        }
        TriggerNotifier.shared.deliver(body: lines.joined(separator: "\n"))
    }

    /// Settings edited the triggers: the clock may be needed now, and what holds may differ.
    func triggersDidChange() {
        context.wantsClock = document.triggersDependOnTime
        evaluateTriggers(reason: "triggers edited")
    }

    /// The person moved items a trigger holds: the trigger leaves them alone until it ends.
    func suspendTriggers(for moved: [ItemKey]) {
        let held = moved.filter { triggers.heldItems.contains($0) }
        guard !held.isEmpty else { return }
        for key in held {
            triggers.suspend(key)
        }
        let list = held.map(\.description).joined(separator: ", ")
        triggerLog.notice("Moved by hand while a trigger holds them, left alone until it ends: \(list, privacy: .public)")
    }

    /// `somabar://set?docker=on&vpn=off` switches `external` conditions.
    func setExternalConditions(from url: URL) {
        let updates = ExternalConditionCommand.parse(query: url.query())
        guard !updates.isEmpty else {
            log.error("somabar://set needs name=on or name=off: \(url.absoluteString, privacy: .public)")
            return
        }
        context.setExternalConditions(updates)
    }

    // MARK: - Menu

    /// A "Triggers" submenu: what holds, which profile comes back, and this router.
    func addTriggersMenu(to menu: NSMenu) {
        let router = context.snapshot.routerAddress
        guard !document.triggers.isEmpty || router != nil else { return }
        let submenu = NSMenu()
        if activeTriggerNames.isEmpty {
            let title = document.triggers.isEmpty ? "No triggers in the layout file" : "No trigger holds right now"
            submenu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        }
        for name in activeTriggerNames {
            submenu.addItem(withTitle: "Holding: \(name)", action: nil, keyEquivalent: "").isEnabled = false
        }
        if let original = document.profileBeforeTriggers {
            submenu.addItem(withTitle: "Back to \(original) when the trigger ends", action: nil, keyEquivalent: "").isEnabled = false
        }
        if let router {
            submenu.addItem(.separator())
            let known = document.preferences.knownRouters.contains(router)
            let item = submenu.addItem(
                withTitle: known ? "Forget This Router (\(router))" : "Remember This Router (\(router))",
                action: known ? #selector(forgetRouterAction) : #selector(rememberRouterAction), keyEquivalent: "")
            item.target = self
        }
        menu.addItem(withTitle: "Triggers", action: nil, keyEquivalent: "").submenu = submenu
    }

    @objc private func rememberRouterAction() {
        rememberCurrentRouter()
    }

    /// The router the Mac is on right now, if any: for "Remember This Router" in Settings.
    var currentRouter: String? { context.snapshot.routerAddress }

    func rememberCurrentRouter() {
        guard let router = context.snapshot.routerAddress else { return }
        document.preferences.addKnownRouter(router)
        saveDocument(reason: "Remembered router \(router)")
        evaluateTriggers(reason: "router remembered")
    }

    @objc private func forgetRouterAction() {
        guard let router = context.snapshot.routerAddress else { return }
        document.preferences.knownRouters.removeAll { $0 == router }
        saveDocument(reason: "Forgot router \(router)")
        evaluateTriggers(reason: "router forgotten")
    }
}
