import AppKit
import SomabarCore

/// What the Settings window asks of the controller. The window edits `document` directly and
/// calls these so the running app follows without a relaunch.
extension SomabarController {
    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(controller: self)
        }
        settingsWindow?.present()
    }

    @objc func showSettingsAction() {
        showSettings()
    }

    /// Applies preferences that live in running objects rather than being read on demand.
    func preferencesDidChange(from old: Preferences) {
        let new = document.preferences
        if new.revealGestures != old.revealGestures {
            gestures?.gestures = new.revealGestures
        }
        if new.showDividers != engine.showsDividers {
            engine.showsDividers = new.showDividers
        }
        if new.rehideAfterSeconds != old.rehideAfterSeconds || new.stillMode != old.stillMode, isRevealed {
            scheduleRehide()
        }
        if new.knownRouters != old.knownRouters {
            evaluateTriggers(reason: "known routers edited")
        }
        if new.notchGuard != old.notchGuard {
            scheduleScan(after: 0.3, reason: "notch guard \(new.notchGuard ? "on" : "off")")
        }
        if new.realItemImages != old.realItemImages {
            refreshItemImages(force: true)
        }
        if new.spacing != old.spacing {
            spacingDidChange()
        }
        if new.agentSocket != old.agentSocket {
            activities.agents.setListening(new.agentSocket)
        }
        if new.menuBarStyle != old.menuBarStyle {
            applyMenuBarStyle()
        }
    }

    /// A profile was renamed, added or removed. Triggers may name it; the active one may be new.
    func profilesDidChange(activeBefore: String) {
        if document.activeProfile != activeBefore {
            lastObserved = nil
            abandonReconcile(reason: "profile \(document.activeProfile)")
            scanNow(reason: "profile \(document.activeProfile)")
        }
        evaluateTriggers(reason: "profiles edited")
        activities.settingsChanged()
    }

    /// Items a trigger can show or hide: what the bar has now plus what any profile remembers.
    /// Items macOS manages are left out; Somabar never moves them.
    var triggerItemChoices: [ItemChoice] {
        var seen = Set<ItemKey>()
        var choices: [ItemChoice] = []
        for item in items where item.isIdentified && !item.isManagedByMacOS && seen.insert(item.key).inserted {
            choices.append(ItemChoice(key: item.key, appName: item.appName))
        }
        for profile in document.profiles {
            for section in SomabarCore.Section.allCases {
                for key in profile.layout[section] where !SystemItems.isManagedByMacOS(key) && seen.insert(key).inserted {
                    choices.append(ItemChoice(key: key, appName: nil))
                }
            }
        }
        return choices.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

/// One item in the trigger editor's picker.
struct ItemChoice: Identifiable, Hashable {
    var key: ItemKey
    var appName: String?

    var id: ItemKey { key }

    var label: String {
        let app = appName ?? key.bundleID
        var label = key.title.isEmpty || key.title == app ? app : "\(app) · \(key.title)"
        if key.ordinal > 0 { label += " (\(key.ordinal + 1))" }
        return label
    }
}
