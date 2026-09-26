import Testing
@testable import SomabarCore

private let docker = ItemKey(bundleID: "com.docker.docker")
private let tailscale = ItemKey(bundleID: "io.tailscale.ipn.macos")
private let slack = ItemKey(bundleID: "com.tinyspeck.slackmacgap")
private let onePassword = ItemKey(bundleID: "com.1password.1password")

@Suite struct ConditionTests {
    let evaluator = TriggerEvaluator(knownRouters: ["aa:bb:cc:dd:ee:ff"])

    @Test func powerAndBattery() {
        var context = ContextSnapshot()
        context.powerSource = .battery
        context.batteryPercent = 15
        #expect(evaluator.holds(.powerSource(.battery), in: context))
        #expect(evaluator.holds(.batteryBelow(percent: 20), in: context))
        #expect(!evaluator.holds(.batteryBelow(percent: 10), in: context))
        context.batteryPercent = nil
        #expect(!evaluator.holds(.batteryBelow(percent: 50), in: context), "No battery reading never fires")
    }

    @Test func knownAndUnknownNetworks() {
        var context = ContextSnapshot()
        context.isWiFi = true
        context.routerAddress = "aa:bb:cc:dd:ee:ff"
        #expect(evaluator.holds(.network(.knownRouter), in: context))
        #expect(!evaluator.holds(.network(.unknownNetwork), in: context))

        context.routerAddress = "11:22:33:44:55:66"
        #expect(!evaluator.holds(.network(.knownRouter), in: context))
        #expect(evaluator.holds(.network(.unknownNetwork), in: context))

        context.isWiFi = false
        #expect(!evaluator.holds(.network(.unknownNetwork), in: context), "Offline is not an unknown network")
        #expect(evaluator.holds(.network(.offline), in: context))
    }

    @Test func timeOfDayWrapsMidnight() {
        let evening = TimeRange(fromMinute: 19 * 60, toMinute: 7 * 60)
        #expect(evening.contains(minute: 23 * 60))
        #expect(evening.contains(minute: 2 * 60))
        #expect(!evening.contains(minute: 12 * 60))
        #expect(!evening.contains(minute: 7 * 60), "The end is exclusive")

        let office = TimeRange(fromMinute: 9 * 60, toMinute: 17 * 60)
        #expect(office.contains(minute: 9 * 60))
        #expect(!office.contains(minute: 17 * 60))
    }

    @Test func focusIsCaseInsensitive() {
        var context = ContextSnapshot()
        context.focus = "Work"
        #expect(evaluator.holds(.focus(name: "work"), in: context))
        #expect(!evaluator.holds(.focus(name: "Sleep"), in: context))
    }

    @Test func composition() {
        var context = ContextSnapshot()
        context.frontmostApp = "com.apple.dt.Xcode"
        context.runningApps = ["com.apple.dt.Xcode", "com.docker.docker"]
        let both = Condition.allOf([.appFrontmost(bundleID: "com.apple.dt.Xcode"), .appRunning(bundleID: "com.docker.docker")])
        #expect(evaluator.holds(both, in: context))
        #expect(!evaluator.holds(.not(both), in: context))
        #expect(evaluator.holds(.anyOf([.screenSharing, .appRunning(bundleID: "com.docker.docker")]), in: context))
    }

    @Test func externalConditionsComeFromTheCLI() {
        var context = ContextSnapshot()
        context.externalConditions = ["docker"]
        #expect(evaluator.holds(.external(name: "docker"), in: context))
        #expect(evaluator.holds(.external(name: "Docker"), in: context), "the URL lower-cases names; the trigger need not")
        #expect(!evaluator.holds(.external(name: "vpn"), in: context))
    }

    @Test func snapshotDescribesItselfForTheLog() {
        var context = ContextSnapshot()
        context.isWiFi = true
        context.routerAddress = "b0:39:56:0b:e1:e5"
        context.displayCount = 2
        context.hasExternalDisplay = true
        context.microphoneInUse = true
        context.focus = "Work"
        context.minuteOfDay = 9 * 60 + 5
        context.externalConditions = ["docker"]
        #expect(context.description == "adapter, wifi, router b0:39:56:0b:e1:e5, 2 displays (external), mic, focus Work, 09:05, external docker")
        #expect(ContextSnapshot().description == "adapter, offline, 1 display, 00:00")
    }

    @Test func onlyIconChangeNeedsScreenRecording() {
        #expect(Condition.iconChanged(docker).requiresScreenRecording)
        #expect(Condition.not(.anyOf([.screenSharing, .iconChanged(docker)])).requiresScreenRecording)
        #expect(!Condition.allOf([.screenSharing, .network(.vpn)]).requiresScreenRecording)
    }
}

@Suite struct TriggerEffectTests {
    let evaluator = TriggerEvaluator()

    @Test func showBeatsHideAndLastProfileWins() {
        var context = ContextSnapshot()
        context.isScreenShared = true
        let triggers = [
            Trigger(condition: .screenSharing, action: .hide(docker)),
            Trigger(condition: .screenSharing, action: .show(docker)),
            Trigger(condition: .screenSharing, action: .switchProfile(name: "Focus")),
            Trigger(condition: .screenSharing, action: .switchProfile(name: "Presenting")),
            Trigger(isEnabled: false, condition: .screenSharing, action: .hide(tailscale)),
        ]
        let effects = evaluator.effects(of: triggers, in: context)
        #expect(effects.show == [docker])
        #expect(effects.hide.isEmpty)
        #expect(effects.profile == "Presenting")
    }

    @Test func applyingEffectsKeepsVisibleItemsStill() {
        let layout = Layout(shown: [docker, slack], hidden: [tailscale], locked: [onePassword])
        let effects = TriggerEffects(show: [tailscale, onePassword], hide: [slack])
        let result = layout.applying(effects)
        #expect(result.shown == [tailscale, docker], "Shown by trigger lands next to the divider")
        #expect(result.hidden == [slack])
        #expect(result.locked == [onePassword], "Locked items are never shown by a trigger")
    }

    @Test func noEffectsMeansNoChange() {
        let layout = Layout(shown: [docker], hidden: [tailscale])
        #expect(layout.applying(TriggerEffects()) == layout)
    }
}
