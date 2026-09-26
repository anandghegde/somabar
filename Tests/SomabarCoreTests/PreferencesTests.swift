import Foundation
import Testing
@testable import SomabarCore

@Suite struct PreferencesTests {
    @Test func triggerNotificationIsOffByDefault() {
        #expect(Preferences().notifyWhenTriggerFires == false)
    }

    @Test func olderFileWithoutTheKeyDecodesToTheDefault() throws {
        let data = Data(#"{"stillMode": true}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.notifyWhenTriggerFires == false)
        #expect(decoded.stillMode)
    }

    @Test func triggerNotificationRoundTrips() throws {
        var preferences = Preferences()
        preferences.notifyWhenTriggerFires = true
        let data = try JSONEncoder().encode(preferences)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["notifyWhenTriggerFires"] as? Bool == true)
        #expect(try JSONDecoder().decode(Preferences.self, from: data) == preferences)
    }

    @Test func documentRoundTripKeepsTheSetting() throws {
        var document = SomabarDocument.makeDefault()
        document.preferences.notifyWhenTriggerFires = true
        let decoded = try SomabarDocument.decode(document.encoded())
        #expect(decoded.preferences.notifyWhenTriggerFires)
    }
}

@Suite struct HotkeyClashTests {
    @Test func anotherActionsComboClashes() {
        var document = SomabarDocument.makeDefault()
        let taken = KeyCombo(key: "b", modifiers: [.control, .option])
        let clash = document.setCombo(taken, for: .cycleProfile)
        #expect(clash == .action(.toggleHidden))
        #expect(document.combo(for: .cycleProfile) == KeyCombo(key: "p", modifiers: [.control, .option]))
    }

    @Test func systemShortcutsClash() {
        var document = SomabarDocument.makeDefault()
        let system = [KeyCombo(key: "space", modifiers: [.command]), KeyCombo(key: "tab", modifiers: [.command]), KeyCombo(key: "space", modifiers: [.control])]
        for combo in system {
            #expect(document.setCombo(combo, for: .startTimer25) != nil)
        }
        #expect(document.combo(for: .startTimer25) == nil)
    }

    @Test func reassigningTheSameComboToItsOwnActionIsFine() {
        var document = SomabarDocument.makeDefault()
        let own = KeyCombo(key: "b", modifiers: [.option, .control])
        #expect(document.setCombo(own, for: .toggleHidden) == nil)
    }

    @Test func freeComboIsSavedAndNilClears() {
        var document = SomabarDocument.makeDefault()
        let combo = KeyCombo(key: "t", modifiers: [.control, .option])
        #expect(document.setCombo(combo, for: .startTimer25) == nil)
        #expect(document.combo(for: .startTimer25) == combo)
        document.setCombo(nil, for: .startTimer25)
        #expect(document.combo(for: .startTimer25) == nil)
    }
}

@Suite struct ProfileEditingTests {
    @Test func renameFollowsReferences() throws {
        var document = SomabarDocument.makeDefault()
        document.activeProfile = Profile.presentingName
        document.profileBeforeTriggers = Profile.presentingName
        document.triggers = [Trigger(condition: .screenSharing, action: .switchProfile(name: Profile.presentingName))]
        try document.renameProfile(Profile.presentingName, to: " Meetings ")
        #expect(document.profile(named: "Meetings") != nil)
        #expect(document.activeProfile == "Meetings")
        #expect(document.profileBeforeTriggers == "Meetings")
        #expect(document.triggers[0].action == .switchProfile(name: "Meetings"))
    }

    @Test func renameRefusesEmptyAndTakenNames() {
        var document = SomabarDocument.makeDefault()
        #expect(throws: ProfileEditError.emptyName) { try document.renameProfile(Profile.focusName, to: "  ") }
        #expect(throws: ProfileEditError.nameTaken) { try document.renameProfile(Profile.focusName, to: Profile.everydayName) }
    }

    @Test func removeKeepsTheLastProfileAndMovesTheActiveOne() throws {
        var document = SomabarDocument.makeDefault()
        document.activeProfile = Profile.everydayName
        try document.removeProfile(named: Profile.everydayName)
        #expect(document.activeProfile == Profile.presentingName)
        try document.removeProfile(named: Profile.focusName)
        #expect(throws: ProfileEditError.lastProfile) { try document.removeProfile(named: Profile.presentingName) }
    }

    @Test func addPicksAFreeName() {
        var document = SomabarDocument.makeDefault()
        #expect(document.addProfile() == "New Profile")
        #expect(document.addProfile() == "New Profile 2")
        #expect(document.profiles.count == 5)
        #expect(document.profiles[3].id != document.profiles[4].id)
    }
}

@Suite struct ConditionDraftTests {
    private func roundTrip(_ condition: Condition) -> Condition? {
        ConditionDraft(condition)?.condition
    }

    @Test func leavesRoundTrip() {
        let leaves: [Condition] = [
            .powerSource(.battery), .batteryBelow(percent: 15), .network(.unknownNetwork),
            .display(.widerThan(points: 3000)), .display(.builtInOnly), .screenSharing, .mediaInUse(.camera),
            .appRunning(bundleID: "com.docker.docker"), .appFrontmost(bundleID: "us.zoom.xos"), .focus(name: "Work"),
            .timeOfDay(TimeRange(fromMinute: 1140, toMinute: 420)), .external(name: "docker"),
        ]
        for leaf in leaves {
            #expect(roundTrip(leaf) == leaf)
        }
    }

    @Test func combinatorsOneLevelDeepRoundTrip() {
        let wifiUnknown: [Condition] = [.network(.wifi), .network(.unknownNetwork)]
        #expect(roundTrip(.allOf(wifiUnknown)) == .allOf(wifiUnknown))
        #expect(roundTrip(.anyOf(wifiUnknown)) == .anyOf(wifiUnknown))
        #expect(roundTrip(.not(.screenSharing)) == .not(.screenSharing))
        #expect(roundTrip(.not(.anyOf(wifiUnknown))) == .not(.anyOf(wifiUnknown)))
        #expect(ConditionDraft(.not(.screenSharing))?.match == ConditionMatch.none)
    }

    @Test func deeperConditionsAreNotEditable() {
        #expect(ConditionDraft(.allOf([.not(.screenSharing), .network(.wifi)])) == nil)
        #expect(ConditionDraft(.not(.allOf([.screenSharing, .network(.wifi)]))) == nil)
        #expect(ConditionDraft(.iconChanged(ItemKey(bundleID: "x"))) == nil)
    }

    @Test func incompleteDraftHasNoCondition() {
        var draft = ConditionDraft(match: .all, leaves: [LeafConditionDraft(kind: .appRunning)])
        #expect(draft.condition == nil)
        draft.leaves[0].bundleID = "com.docker.docker"
        #expect(draft.condition == .appRunning(bundleID: "com.docker.docker"))
        draft.leaves = []
        #expect(draft.condition == nil)
    }

    @Test func switchingKindKeepsTypedFields() {
        var leaf = LeafConditionDraft(kind: .external)
        leaf.name = "docker"
        leaf.kind = .focus
        leaf.kind = .external
        #expect(leaf.condition == .external(name: "docker"))
    }
}
