import Foundation
import Observation
import SomabarCore

/// The Settings window's view of the controller. It holds no copy of the document: every read
/// goes to `controller.document` and every write lands there, so a trigger switching profile
/// while the window is open shows up. `revision` is the only observed state; the controller
/// bumps it whenever the document is saved or what holds changes.
@Observable
@MainActor
final class SettingsModel {
    @ObservationIgnored private weak var controller: SomabarController?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReason: String?
    private(set) var revision = 0
    /// Shown under the notification toggle when macOS says no.
    var notificationNote: String?

    init(controller: SomabarController) {
        self.controller = controller
    }

    func documentDidChange() {
        revision &+= 1
    }

    // MARK: Reading

    var document: SomabarDocument {
        _ = revision
        return controller?.document ?? .makeDefault()
    }

    var activeTriggerNames: [String] {
        _ = revision
        return controller?.activeTriggerNames ?? []
    }

    var itemChoices: [ItemChoice] {
        _ = revision
        return controller?.triggerItemChoices ?? []
    }

    var currentRouter: String? {
        _ = revision
        return controller?.currentRouter
    }

    // MARK: Preferences

    var preferences: Preferences {
        get { document.preferences }
        set {
            guard let controller, newValue != controller.document.preferences else { return }
            let old = controller.document.preferences
            controller.document.preferences = newValue
            controller.preferencesDidChange(from: old)
            changed("Settings: preferences")
        }
    }

    func rememberCurrentRouter() {
        controller?.rememberCurrentRouter()
        documentDidChange()
    }

    /// Turning the notification on asks macOS the first time; a refusal turns it back off.
    func setNotifyWhenTriggerFires(_ isOn: Bool) {
        preferences.notifyWhenTriggerFires = isOn
        notificationNote = nil
        guard isOn else { return }
        Task { @MainActor in
            let granted = await TriggerNotifier.shared.requestAuthorization()
            if !granted {
                preferences.notifyWhenTriggerFires = false
                notificationNote = "Notifications are off for Somabar. Turn them on in System Settings › Notifications."
            }
        }
    }

    /// Turning real item images on asks for Screen Recording. A refusal keeps the setting; the
    /// view says app icons are shown instead.
    func setRealItemImages(_ isOn: Bool) {
        preferences.realItemImages = isOn
        guard isOn else { return }
        ScreenRecordingPermission.shared.request()
    }

    // MARK: Hot keys

    /// Nil when saved; the clash otherwise, and nothing changes.
    func setCombo(_ combo: KeyCombo?, for action: HotkeyAction) -> HotkeyClash? {
        guard let controller else { return nil }
        if let clash = controller.document.setCombo(combo, for: action) {
            return clash
        }
        controller.hotkeysDidChange()
        changed("Settings: hot key for \(action.displayName)")
        return nil
    }

    func setRecording(_ isRecording: Bool) {
        if isRecording {
            controller?.suspendHotkeys()
        } else {
            controller?.hotkeysDidChange()
        }
    }

    // MARK: Profiles

    func renameProfile(_ oldName: String, to newName: String) throws(ProfileEditError) {
        try editProfiles("Settings: renamed \(oldName)") { (document: inout SomabarDocument) throws(ProfileEditError) in
            try document.renameProfile(oldName, to: newName)
        }
    }

    func removeProfile(named name: String) throws(ProfileEditError) {
        try editProfiles("Settings: removed \(name)") { (document: inout SomabarDocument) throws(ProfileEditError) in
            try document.removeProfile(named: name)
        }
    }

    @discardableResult
    func addProfile() -> String? {
        var name: String?
        try? editProfiles("Settings: added a profile") { name = $0.addProfile() }
        return name
    }

    func updateProfile(_ profile: Profile) {
        guard let controller, controller.document.profiles.contains(where: { $0.id == profile.id }) else { return }
        controller.document.update(profile)
        // The profile's notch settings may name different activities.
        controller.activities.settingsChanged()
        changed("Settings: \(profile.name)")
    }

    private func editProfiles(_ reason: String, _ edit: (inout SomabarDocument) throws(ProfileEditError) -> Void) throws(ProfileEditError) {
        guard let controller else { return }
        let activeBefore = controller.document.activeProfile
        var document = controller.document
        try edit(&document)
        controller.document = document
        controller.profilesDidChange(activeBefore: activeBefore)
        changed(reason)
    }

    // MARK: Triggers

    func setTrigger(_ trigger: Trigger) {
        guard let controller else { return }
        if let index = controller.document.triggers.firstIndex(where: { $0.id == trigger.id }) {
            controller.document.triggers[index] = trigger
        } else {
            controller.document.triggers.append(trigger)
        }
        controller.triggersDidChange()
        changed("Settings: trigger \(trigger.displayName)")
        // An icon-change trigger needs Screen Recording; Somabar asks once, ever.
        if trigger.isEnabled, trigger.condition.requiresScreenRecording {
            ScreenRecordingPermission.shared.requestOnceForTriggers()
        }
    }

    func removeTrigger(id: UUID) {
        guard let controller else { return }
        let name = controller.document.triggers.first { $0.id == id }?.displayName ?? ""
        controller.document.triggers.removeAll { $0.id == id }
        controller.triggersDidChange()
        changed("Settings: removed trigger \(name)")
    }

    // MARK: Saving

    /// Saves shortly after the last change, so a slider drag or a burst of clicks leaves one
    /// entry in the file's history rather than dozens.
    private func changed(_ reason: String) {
        documentDidChange()
        pendingReason = reason
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let reason = pendingReason else { return }
        pendingReason = nil
        controller?.saveDocument(reason: reason)
    }
}

// MARK: - Groups and item hot keys

extension SettingsModel {
    @discardableResult
    func addGroup() -> UUID? {
        var id: UUID?
        try? editGroups("Settings: added a group") { id = $0.addGroup() }
        return id
    }

    func renameGroup(_ id: UUID, to newName: String) throws(GroupEditError) {
        try editGroups("Settings: renamed a group") { (document: inout SomabarDocument) throws(GroupEditError) in
            try document.renameGroup(id, to: newName)
        }
    }

    func setGroupGlyph(_ id: UUID, to glyph: String) {
        try? editGroups("Settings: group glyph") { (document: inout SomabarDocument) throws(GroupEditError) in
            try document.setGroupGlyph(id, to: glyph)
        }
    }

    func setGroupMembers(_ id: UUID, _ members: [ItemKey]) throws(GroupEditError) {
        try editGroups("Settings: group members") { (document: inout SomabarDocument) throws(GroupEditError) in
            try document.setGroupMembers(id, members)
        }
    }

    func moveGroup(_ id: UUID, to section: Section) {
        try? editGroups("Settings: moved a group to \(section.displayName)") { (document: inout SomabarDocument) throws(GroupEditError) in
            try document.moveGroup(id, to: section)
        }
    }

    func removeGroup(_ id: UUID) {
        try? editGroups("Settings: removed a group") { $0.removeGroup(id) }
    }

    private func editGroups(_ reason: String, _ edit: (inout SomabarDocument) throws(GroupEditError) -> Void) throws(GroupEditError) {
        guard let controller else { return }
        var document = controller.document
        try edit(&document)
        guard document != controller.document else { return }
        controller.document = document
        controller.groupsDidChange()
        changed(reason)
    }

    func addItemHotKey(for target: HotKeyTarget) {
        guard let controller else { return }
        controller.document.addItemHotKey(for: target)
        changed("Settings: hot key row for \(controller.document.label(for: target))")
    }

    func removeItemHotKey(for target: HotKeyTarget) {
        guard let controller else { return }
        controller.document.removeItemHotKey(for: target)
        controller.hotkeysDidChange()
        changed("Settings: removed the hot key for \(controller.document.label(for: target))")
    }

    /// Nil when saved; the clash otherwise, and nothing changes.
    func setCombo(_ combo: KeyCombo?, for target: HotKeyTarget) -> HotkeyClash? {
        guard let controller else { return nil }
        if let clash = controller.document.setCombo(combo, for: target) {
            return clash
        }
        controller.hotkeysDidChange()
        changed("Settings: hot key for \(controller.document.label(for: target))")
        return nil
    }
}
