import Foundation
import Testing
@testable import SomabarCore

private let docker = ItemKey(bundleID: "com.docker.docker")
private let tailscale = ItemKey(bundleID: "io.tailscale.ipn.macos")
private let slack = ItemKey(bundleID: "com.tinyspeck.slackmacgap")

@Suite struct TriggerRuntimeTests {
    private func makeDocument() -> SomabarDocument {
        SomabarDocument.makeDefault(layout: Layout(shown: [docker, slack], hidden: [tailscale]))
    }

    @Test func showAndHideAreAppliedThenUndone() {
        var document = makeDocument()
        var runtime = TriggerRuntime()

        let started = runtime.apply(TriggerEffects(show: [tailscale], hide: [slack]), to: &document)
        #expect(started.layoutChanged)
        #expect(started.profileChange == nil)
        #expect(document.active.layout.applying(runtime.applied).shown == [tailscale, docker])
        #expect(document.active.layout == Layout(shown: [docker, slack], hidden: [tailscale]), "The stored layout never changes")

        let again = runtime.apply(TriggerEffects(show: [tailscale], hide: [slack]), to: &document)
        #expect(again.isEmpty, "The same effects twice change nothing")

        let ended = runtime.apply(TriggerEffects(), to: &document)
        #expect(ended.layoutChanged)
        #expect(runtime.applied.isEmpty)
        #expect(document.active.layout.applying(runtime.applied) == document.active.layout)
    }

    @Test func profileIsSwitchedAndRestored() {
        var document = makeDocument()
        var runtime = TriggerRuntime()

        let switched = runtime.apply(TriggerEffects(profile: Profile.presentingName), to: &document)
        #expect(switched.profileChange == .switched(to: Profile.presentingName))
        #expect(document.activeProfile == Profile.presentingName)
        #expect(document.profileBeforeTriggers == Profile.everydayName)

        let held = runtime.apply(TriggerEffects(profile: Profile.presentingName), to: &document)
        #expect(held.isEmpty)

        let restored = runtime.apply(TriggerEffects(), to: &document)
        #expect(restored.profileChange == .restored(to: Profile.everydayName))
        #expect(document.activeProfile == Profile.everydayName)
        #expect(document.profileBeforeTriggers == nil)
    }

    @Test func aProfileThePersonPicksWhileATriggerHoldsIsKept() {
        var document = makeDocument()
        var runtime = TriggerRuntime()
        _ = runtime.apply(TriggerEffects(profile: Profile.presentingName), to: &document)

        // What the controller does on a manual switch.
        document.activeProfile = Profile.focusName
        document.profileBeforeTriggers = nil

        let held = runtime.apply(TriggerEffects(profile: Profile.presentingName), to: &document)
        #expect(held.isEmpty)
        #expect(document.activeProfile == Profile.focusName, "The trigger does not take the profile back")

        let ended = runtime.apply(TriggerEffects(), to: &document)
        #expect(ended.isEmpty)
        #expect(document.activeProfile == Profile.focusName, "Nothing to restore")
    }

    @Test func aLaterProfileTriggerTakesOverAndTheFirstOneRestores() {
        var document = makeDocument()
        var runtime = TriggerRuntime()
        _ = runtime.apply(TriggerEffects(profile: Profile.presentingName), to: &document)

        let focus = runtime.apply(TriggerEffects(profile: Profile.focusName), to: &document)
        #expect(focus.profileChange == .switched(to: Profile.focusName))
        #expect(document.profileBeforeTriggers == Profile.everydayName, "The original profile is kept, not Presenting")

        let back = runtime.apply(TriggerEffects(profile: Profile.presentingName), to: &document)
        #expect(back.profileChange == .switched(to: Profile.presentingName))

        let restored = runtime.apply(TriggerEffects(), to: &document)
        #expect(restored.profileChange == .restored(to: Profile.everydayName))
    }

    @Test func unknownProfileIsReportedAndIgnored() {
        var document = makeDocument()
        var runtime = TriggerRuntime()
        let outcome = runtime.apply(TriggerEffects(profile: "Nope"), to: &document)
        #expect(outcome.unknownProfile == "Nope")
        #expect(outcome.profileChange == nil)
        #expect(document.activeProfile == Profile.everydayName)
        #expect(document.profileBeforeTriggers == nil)
    }

    @Test func relaunchWhileATriggerHoldsAProfileStillRestoresIt() {
        var document = makeDocument()
        document.activeProfile = Profile.presentingName
        document.profileBeforeTriggers = Profile.everydayName
        var runtime = TriggerRuntime()

        let stillHeld = runtime.apply(TriggerEffects(profile: Profile.presentingName), to: &document)
        #expect(stillHeld.isEmpty)
        #expect(document.profileBeforeTriggers == Profile.everydayName)

        let restored = runtime.apply(TriggerEffects(), to: &document)
        #expect(restored.profileChange == .restored(to: Profile.everydayName))
    }

    @Test func relaunchAfterTheConditionEndedRestoresAtOnce() {
        var document = makeDocument()
        document.activeProfile = Profile.presentingName
        document.profileBeforeTriggers = Profile.everydayName
        var runtime = TriggerRuntime()
        let restored = runtime.apply(TriggerEffects(), to: &document)
        #expect(restored.profileChange == .restored(to: Profile.everydayName))
        #expect(document.activeProfile == Profile.everydayName)
    }

    @Test func anItemThePersonMovesIsSuspendedUntilTheTriggerEnds() {
        var document = makeDocument()
        var runtime = TriggerRuntime()
        _ = runtime.apply(TriggerEffects(show: [tailscale]), to: &document)
        #expect(runtime.applied.show == [tailscale])

        let heldTailscale = runtime.suspend(tailscale)
        let heldDocker = runtime.suspend(docker)
        #expect(heldTailscale)
        #expect(!heldDocker, "Docker is not held by any trigger")
        #expect(runtime.applied.isEmpty)
        #expect(runtime.heldItems == [tailscale])

        let stillHeld = runtime.apply(TriggerEffects(show: [tailscale]), to: &document)
        #expect(stillHeld.isEmpty, "The suspended item stays out while the trigger holds")

        let ended = runtime.apply(TriggerEffects(), to: &document)
        #expect(ended.isEmpty, "Nothing was applied, so nothing changed")
        #expect(runtime.suspended.isEmpty)

        let fired = runtime.apply(TriggerEffects(show: [tailscale]), to: &document)
        #expect(fired.layoutChanged)
        #expect(runtime.applied.show == [tailscale], "The next time the condition starts, the trigger acts again")
    }

    @Test func suspensionOfOneItemLeavesTheOthersApplied() {
        var document = makeDocument()
        var runtime = TriggerRuntime()
        _ = runtime.apply(TriggerEffects(show: [tailscale], hide: [slack]), to: &document)
        runtime.suspend(slack)
        #expect(runtime.applied == TriggerEffects(show: [tailscale]))
        let outcome = runtime.apply(TriggerEffects(show: [tailscale], hide: [slack]), to: &document)
        #expect(outcome.isEmpty)
    }
}

@Suite struct TriggerDescriptionTests {
    @Test func namesFallBackToTheAction() {
        #expect(Trigger(condition: .screenSharing, action: .show(docker)).displayName == "show com.docker.docker")
        #expect(Trigger(name: "Calls", condition: .screenSharing, action: .hide(slack)).displayName == "Calls")
        #expect(TriggerAction.switchProfile(name: "Presenting").summary == "switch to Presenting")
    }

    @Test func timeDependenceIsFoundInsideCompositions() {
        let evening = Condition.timeOfDay(TimeRange(fromMinute: 19 * 60, toMinute: 7 * 60))
        #expect(evening.dependsOnTime)
        #expect(Condition.not(.anyOf([.screenSharing, evening])).dependsOnTime)
        #expect(!Condition.allOf([.screenSharing, .network(.vpn)]).dependsOnTime)
        var document = SomabarDocument.makeDefault()
        document.triggers = [Trigger(isEnabled: false, condition: evening, action: .hide(slack))]
        #expect(!document.triggersDependOnTime, "A disabled trigger does not keep the clock running")
        document.triggers[0].isEnabled = true
        #expect(document.triggersDependOnTime)
    }
}

@Suite struct ExternalConditionCommandTests {
    @Test func parsesNamesAndValues() {
        let parsed = ExternalConditionCommand.parse(query: "docker=on&VPN=off&Meeting&bad=maybe&=on")
        #expect(parsed.map(\.name) == ["docker", "vpn", "meeting"])
        #expect(parsed.map(\.isOn) == [true, false, true])
        #expect(ExternalConditionCommand.parse(query: nil).isEmpty)
        #expect(ExternalConditionCommand.parse(query: "").isEmpty)
    }
}

@Suite struct TunnelInterfaceTests {
    @Test func recognisesTunnelNames() {
        #expect(TunnelInterfaces.isTunnel("utun4"))
        #expect(TunnelInterfaces.isTunnel("ipsec0"))
        #expect(TunnelInterfaces.isTunnel("ppp0"))
        #expect(TunnelInterfaces.isTunnel("wg0"))
        #expect(!TunnelInterfaces.isTunnel("en0"))
        #expect(!TunnelInterfaces.isTunnel("bridge100"))
        #expect(!TunnelInterfaces.isTunnel("utun"))
    }
}

@Suite struct TriggerDocumentTests {
    @Test func profileBeforeTriggersIsOptionalInTheFile() throws {
        let json = """
        {
          "version": 1,
          "activeProfile": "Everyday",
          "profiles": [
            { "id": "6B3A5C1E-1111-4C2B-9E1D-000000000001", "name": "Everyday",
              "layout": { "shown": [], "hidden": [], "tucked": [], "locked": [] },
              "newItemsGoTo": "shown",
              "notch": { "enabledActivities": [], "showsArtworkAndFileNames": true } }
          ],
          "triggers": [], "hotkeys": [], "aliases": [], "preferences": {}
        }
        """
        let document = try SomabarDocument.decode(Data(json.utf8))
        #expect(document.profileBeforeTriggers == nil)
        let text = String(bytes: try document.encoded(), encoding: .utf8) ?? ""
        #expect(!text.contains("profileBeforeTriggers"), "Nil is left out of the file")

        var held = document
        held.profileBeforeTriggers = "Everyday"
        #expect(try SomabarDocument.decode(held.encoded()).profileBeforeTriggers == "Everyday")
    }

    /// The JSON shape the README documents. Conditions and actions are enums with associated
    /// values, so the file spells them as `{"case": {"_0": …}}` or `{"case": {"label": …}}`.
    @Test func readmeExamplesDecode() throws {
        let json = """
        [
          { "id": "6B3A5C1E-2222-4C2B-9E1D-000000000001", "name": "Battery when unplugged", "isEnabled": true,
            "condition": { "powerSource": { "_0": "battery" } },
            "action": { "show": { "_0": { "bundleID": "com.apple.controlcenter", "title": "Battery", "ordinal": 0 } } } },
          { "id": "6B3A5C1E-2222-4C2B-9E1D-000000000002", "name": "Present when sharing", "isEnabled": true,
            "condition": { "screenSharing": {} },
            "action": { "switchProfile": { "name": "Presenting" } } },
          { "id": "6B3A5C1E-2222-4C2B-9E1D-000000000003", "name": "VPN on unknown Wi-Fi", "isEnabled": true,
            "condition": { "allOf": { "_0": [ { "network": { "_0": "wifi" } }, { "network": { "_0": "unknownNetwork" } } ] } },
            "action": { "show": { "_0": { "bundleID": "io.tailscale.ipn.macos", "title": "", "ordinal": 0 } } } },
          { "id": "6B3A5C1E-2222-4C2B-9E1D-000000000004", "name": "No Slack after 19:00", "isEnabled": true,
            "condition": { "timeOfDay": { "_0": { "fromMinute": 1140, "toMinute": 420 } } },
            "action": { "hide": { "_0": { "bundleID": "com.tinyspeck.slackmacgap", "title": "", "ordinal": 0 } } } },
          { "id": "6B3A5C1E-2222-4C2B-9E1D-000000000005", "name": "Docker from a script", "isEnabled": true,
            "condition": { "external": { "name": "docker" } },
            "action": { "show": { "_0": { "bundleID": "com.docker.docker", "title": "", "ordinal": 0 } } } },
          { "id": "6B3A5C1E-2222-4C2B-9E1D-000000000006", "name": "Simulator with Xcode", "isEnabled": true,
            "condition": { "appFrontmost": { "bundleID": "com.apple.dt.Xcode" } },
            "action": { "show": { "_0": { "bundleID": "com.apple.iphonesimulator", "title": "", "ordinal": 0 } } } },
          { "id": "6B3A5C1E-2222-4C2B-9E1D-000000000007", "name": "Work Focus", "isEnabled": true,
            "condition": { "focus": { "name": "Work" } },
            "action": { "switchProfile": { "name": "Focus" } } },
          { "id": "6B3A5C1E-2222-4C2B-9E1D-000000000008", "name": "Low battery", "isEnabled": true,
            "condition": { "allOf": { "_0": [ { "batteryBelow": { "percent": 20 } },
                                              { "not": { "_0": { "display": { "_0": { "externalConnected": {} } } } } } ] } },
            "action": { "show": { "_0": { "bundleID": "com.apple.controlcenter", "title": "Battery", "ordinal": 0 } } } }
        ]
        """
        let triggers = try JSONDecoder().decode([Trigger].self, from: Data(json.utf8))
        #expect(triggers.count == 8)
        #expect(triggers[0].condition == .powerSource(.battery))
        #expect(triggers[1].condition == .screenSharing)
        #expect(triggers[1].action == .switchProfile(name: "Presenting"))
        #expect(triggers[2].condition == .allOf([.network(.wifi), .network(.unknownNetwork)]))
        #expect(triggers[3].condition == .timeOfDay(TimeRange(fromMinute: 1140, toMinute: 420)))
        #expect(triggers[4].condition == .external(name: "docker"))
        #expect(triggers[5].condition == .appFrontmost(bundleID: "com.apple.dt.Xcode"))
        #expect(triggers[6].condition == .focus(name: "Work"))
        #expect(triggers[7].condition == .allOf([.batteryBelow(percent: 20), .not(.display(.externalConnected))]))
    }
}
