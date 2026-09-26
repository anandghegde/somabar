import Testing
@testable import NotchKit

@Suite struct CallHangUpTests {
    @Test func matchesLeaveTitlesLoosely() {
        #expect(CallHangUp.matchRank(title: "Leave Meeting", bundleID: "us.zoom.xos") == 0)
        #expect(CallHangUp.matchRank(title: "  leave meeting… ", bundleID: "us.zoom.xos") == 0)
        #expect(CallHangUp.matchRank(title: "Leave Meeting...", bundleID: "us.zoom.xos") == 0)
        #expect(CallHangUp.matchRank(title: "End", bundleID: "com.apple.FaceTime") == 0)
        #expect(CallHangUp.matchRank(title: "Leave", bundleID: "com.microsoft.teams2") == 0)
    }

    @Test func neverEndsAMeetingForEveryone() {
        #expect(CallHangUp.matchRank(title: "End Meeting", bundleID: "us.zoom.xos") == nil)
        #expect(CallHangUp.matchRank(title: "End Meeting for All", bundleID: "us.zoom.xos") == nil)
        #expect(CallHangUp.matchRank(title: "End Meeting", bundleID: "com.cisco.webexmeetingsapp") == nil)
    }

    @Test func ignoresUnknownAppsAndTitles() {
        #expect(CallHangUp.matchRank(title: "Leave Meeting", bundleID: "com.apple.Safari") == nil)
        #expect(CallHangUp.matchRank(title: "Leave Meeting Room", bundleID: "us.zoom.xos") == nil)
        #expect(CallHangUp.matchRank(title: "", bundleID: "us.zoom.xos") == nil)
    }

    @Test func picksTheAppsFirstChoice() {
        let titles = ["About Zoom", "Leave", "Leave Meeting", "Quit Zoom"]
        #expect(CallHangUp.bestTitle(in: titles, bundleID: "us.zoom.xos") == "Leave Meeting")
        #expect(CallHangUp.bestTitle(in: ["Mute Audio"], bundleID: "us.zoom.xos") == nil)
    }

    @Test func picksTheCallApp() {
        let running: Set<String> = ["com.tinyspeck.slackmacgap", "us.zoom.xos"]
        #expect(CallHangUp.appBundleID(runningApps: running, frontmostApp: nil) == "us.zoom.xos")
        #expect(CallHangUp.appBundleID(runningApps: running, frontmostApp: "com.tinyspeck.slackmacgap") == "com.tinyspeck.slackmacgap")
        #expect(CallHangUp.appBundleID(runningApps: [], frontmostApp: "com.apple.Safari") == nil)
    }
}
