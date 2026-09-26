import Testing
@testable import SomabarCore

private let docker = ItemKey(bundleID: "com.docker.docker")
private let tailscale = ItemKey(bundleID: "io.tailscale.ipn.macos")
private let slack = ItemKey(bundleID: "com.tinyspeck.slackmacgap")
private let onePassword = ItemKey(bundleID: "com.1password.1password")
private let clock = ItemKey(bundleID: SystemItems.controlCenter, title: "Clock")
private let battery = ItemKey(bundleID: SystemItems.controlCenter, title: "Battery")

@Suite struct LayoutTests {
    @Test func moveBetweenSections() {
        var layout = Layout(shown: [docker, tailscale, slack])
        layout.move(docker, to: .hidden)
        #expect(layout.shown == [tailscale, slack])
        #expect(layout.hidden == [docker])
        #expect(layout.section(of: docker) == .hidden)
    }

    @Test func moveWithinSectionReorders() {
        var layout = Layout(shown: [docker, tailscale, slack])
        layout.move(slack, to: .shown, at: 0)
        #expect(layout.shown == [slack, docker, tailscale])
    }

    @Test func indexIsClamped() {
        var layout = Layout(shown: [docker])
        layout.move(tailscale, to: .shown, at: 99)
        layout.move(slack, to: .shown, at: -5)
        #expect(layout.shown == [slack, docker, tailscale])
    }

    @Test func barOrderIsLockedTuckedHiddenShown() {
        let layout = Layout(shown: [docker], hidden: [tailscale], tucked: [slack], locked: [onePassword])
        #expect(layout.allItems == [onePassword, slack, tailscale, docker])
    }

    @Test func insertIfNewOnlyAddsUnknownItems() {
        var layout = Layout(shown: [docker])
        #expect(layout.insertIfNew(docker, in: .hidden) == false)
        #expect(layout.insertIfNew(tailscale, in: .hidden) == true)
        #expect(layout.hidden == [tailscale])
        #expect(layout.count == 2)
    }

    @Test func retainDropsEverythingElse() {
        var layout = Layout(shown: [docker, tailscale], hidden: [slack])
        layout.retain([docker, slack])
        #expect(layout.shown == [docker])
        #expect(layout.hidden == [slack])
    }
}

@Suite struct ProfileTests {
    private let everyday = Layout(shown: [docker, tailscale, battery, clock], hidden: [slack], locked: [onePassword])

    @Test func presentingTucksEverythingButEssentials() {
        let profile = Profile.presenting(from: everyday)
        #expect(profile.layout.shown == [battery, clock])
        #expect(profile.layout.tucked == [slack, docker, tailscale], "Bar order: the Hidden item was left of the Shown ones")
        #expect(profile.layout.locked == [onePassword])
        #expect(profile.newItemsGoTo == .tucked)
        #expect(profile.notch.showsArtworkAndFileNames == false)
    }

    @Test func focusShowsOnlyTheClock() {
        let profile = Profile.focus(from: everyday)
        #expect(profile.layout.shown == [clock])
        #expect(profile.layout.hidden == [slack, docker, tailscale, battery])
        #expect(profile.layout.locked == [onePassword])
        #expect(profile.notch.enabledActivities == [.call, .timer])
    }

    @Test func essentialTitlesMatchLoosely() {
        #expect(SystemItems.isPresentingEssential(ItemKey(bundleID: SystemItems.controlCenter, title: "Wi\u{2011}Fi")))
        #expect(SystemItems.isPresentingEssential(ItemKey(bundleID: SystemItems.controlCenter, title: "Control Centre")))
        #expect(!SystemItems.isPresentingEssential(ItemKey(bundleID: SystemItems.controlCenter, title: "Screen Mirroring")))
        #expect(!SystemItems.isPresentingEssential(ItemKey(bundleID: "com.example.Clock", title: "Clock")))
    }
}
