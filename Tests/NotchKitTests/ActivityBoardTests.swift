import SomabarCore
import Testing
@testable import NotchKit

@Suite struct ActivityBoardTests {
    private let everything = Set(ActivityKind.allCases)

    private func live(_ kind: ActivityKind, _ rank: ActivityRank, at startedAt: Double = 0) -> LiveActivity {
        LiveActivity(kind: kind, rank: rank, startedAt: startedAt)
    }

    @Test func priorityFollowsThePRD() {
        let order: [ActivityRank] = [.call, .timerEnding, .agentNeedsYou, .transfer, .nowPlaying, .timer, .agentWorking]
        #expect(order == order.sorted())
    }

    @Test func callWinsCompactAndTheRestAreListed() {
        let board = ActivityBoard(enabled: everything, isScreenShared: false)
        let music = live(.nowPlaying, .nowPlaying, at: 1)
        let call = live(.call, .call, at: 5)
        let timer = live(.timer, .timer, at: 0)
        let selection = board.select([music, timer, call])
        #expect(selection.compact == call)
        #expect(selection.expanded == [call, music, timer])
        #expect(selection.rest == [music, timer])
    }

    @Test func timerInItsLastMinuteBeatsNowPlaying() {
        #expect(ActivityRank.timer(remaining: 61, isRunning: true) == .timer)
        #expect(ActivityRank.timer(remaining: 60, isRunning: true) == .timerEnding)
        #expect(ActivityRank.timer(remaining: 30, isRunning: false) == .timer, "A paused timer is not urgent")
        let board = ActivityBoard(enabled: everything, isScreenShared: false)
        let music = live(.nowPlaying, .nowPlaying)
        #expect(board.select([live(.timer, .timer), music]).compact == music)
        #expect(board.select([live(.timer, .timerEnding), music]).compact?.kind == .timer)
    }

    @Test func olderActivityWinsATie() {
        let board = ActivityBoard(enabled: everything, isScreenShared: false)
        let first = live(.nowPlaying, .nowPlaying, at: 1)
        let second = live(.transfers, .nowPlaying, at: 2)
        #expect(board.select([second, first]).compact == first)
    }

    @Test func switchedOffActivitiesAreNeitherShownNorListed() {
        let board = ActivityBoard(settings: .focus, isScreenShared: false)
        let selection = board.select([live(.nowPlaying, .nowPlaying), live(.timer, .timer)])
        #expect(selection.compact?.kind == .timer)
        #expect(selection.expanded.map(\.kind) == [.timer])
    }

    @Test func screenSharingLeavesOnlyCallAndTimerInCompact() {
        let board = ActivityBoard(enabled: everything, isScreenShared: true)
        let music = live(.nowPlaying, .nowPlaying)
        #expect(board.select([music]).compact == nil, "Now Playing is not shown to viewers")
        #expect(board.select([music]).expanded == [music], "It is still listed when the person opens the notch")
        #expect(board.select([music, live(.timer, .timer)]).compact?.kind == .timer)
        #expect(board.select([music, live(.call, .call)]).compact?.kind == .call)
    }

    @Test func nothingLiveLeavesTheNotchIdle() {
        let selection = ActivityBoard(enabled: everything, isScreenShared: false).select([])
        #expect(selection.compact == nil)
        #expect(selection.expanded.isEmpty)
    }

    @Test func dropTargetAlwaysWins() {
        let board = ActivityBoard(enabled: everything, isScreenShared: true)
        #expect(board.select([live(.call, .call), live(.dropToShare, .dropTarget)]).compact?.kind == .dropToShare)
    }
}

@Suite struct ActivityTextTests {
    @Test func elapsedTimeGrowsAnHourField() {
        #expect(ActivityText.elapsed(seconds: 0.9) == "0:00")
        #expect(ActivityText.elapsed(seconds: 65) == "1:05")
        #expect(ActivityText.elapsed(seconds: 3599) == "59:59")
        #expect(ActivityText.elapsed(seconds: 3600) == "1:00:00")
        #expect(ActivityText.elapsed(seconds: 3600 + 9 * 60 + 7) == "1:09:07")
    }

    @Test func remainingRoundsUp() {
        #expect(ActivityText.remaining(seconds: 200.2) == "-3:21")
        #expect(ActivityText.remaining(seconds: 0) == "-0:00")
    }

    @Test func durations() {
        #expect(ActivityText.duration(minutes: 45) == "45 min")
        #expect(ActivityText.duration(minutes: 80) == "1 h 20 min")
        #expect(ActivityText.duration(minutes: 120) == "2 h")
    }

    @Test func pluggingInPulsesPercentAndTimeToFull() {
        let battery = PowerReading(source: .battery, percent: 63)
        let charging = PowerReading(source: .adapter, percent: 63, minutesToFull: 80)
        #expect(ActivityText.powerPulse(from: battery, to: charging) == "Charging · 63 % · 1 h 20 min to full")
        let estimating = PowerReading(source: .adapter, percent: 63)
        #expect(ActivityText.powerPulse(from: battery, to: estimating) == "Charging · 63 %")
        #expect(estimating.isAwaitingEstimate)
        let full = PowerReading(source: .adapter, percent: 100, isCharged: true)
        #expect(ActivityText.powerPulse(from: battery, to: full) == "Charged · 100 %")
        #expect(!full.isAwaitingEstimate)
    }

    @Test func unpluggingPulsesPercentAndTimeLeft() {
        let adapter = PowerReading(source: .adapter, percent: 63)
        #expect(ActivityText.powerPulse(from: adapter, to: PowerReading(source: .battery, percent: 63)) == "On battery · 63 %")
        let known = PowerReading(source: .battery, percent: 63, minutesToEmpty: 305)
        #expect(ActivityText.powerPulse(from: adapter, to: known) == "On battery · 63 % · 5 h 5 min left")
    }

    @Test func noPulseWithoutASourceChange() {
        let before = PowerReading(source: .adapter, percent: 63)
        #expect(ActivityText.powerPulse(from: before, to: PowerReading(source: .adapter, percent: 64)) == nil)
    }

    @Test func callSourceNamesTheLikeliestApp() {
        #expect(CallSource.name(runningApps: ["com.tinyspeck.slackmacgap", "us.zoom.xos"], frontmostApp: nil) == "Zoom")
        #expect(CallSource.name(runningApps: ["com.tinyspeck.slackmacgap", "us.zoom.xos"], frontmostApp: "com.tinyspeck.slackmacgap") == "Slack",
                "The app in front wins")
        #expect(CallSource.name(runningApps: ["com.google.Chrome"], frontmostApp: "com.google.Chrome") == "Browser call")
        #expect(CallSource.name(runningApps: ["com.google.Chrome"], frontmostApp: "com.apple.finder") == nil,
                "A browser in the background says nothing")
        #expect(CallSource.deviceTitle(microphone: true, camera: false) == "Microphone in use")
        #expect(CallSource.deviceTitle(microphone: false, camera: true) == "Camera in use")
    }
}

@Suite struct NowPlayingTrackTests {
    @Test func spotifyGivesPositionAndDuration() throws {
        let info: [String: Any] = [
            "Player State": "Playing", "Name": "Song", "Artist": "Band", "Duration": 200_000,
            "Playback Position": 20.0, "Track ID": "spotify:track:1",
        ]
        let track = try #require(NowPlayingTrack.parse(info, player: .spotify, at: 100))
        #expect(track.isPlaying)
        #expect(track.duration == 200)
        #expect(track.remaining(at: 100) == 180)
        #expect(track.remaining(at: 110) == 170, "Playing extrapolates the position")
        #expect(track.progress(at: 100) == 0.1)
        #expect(track.id == "spotify:track:1")
    }

    @Test func musicHasNoPositionUntilAsked() throws {
        let info: [String: Any] = ["Player State": "Paused", "Name": "Song", "Artist": "Band", "Total Time": 180_000, "PersistentID": 42]
        var track = try #require(NowPlayingTrack.parse(info, player: .music, at: 0))
        #expect(track.state == .paused)
        #expect(track.remaining(at: 0) == nil)
        track.position = 60
        #expect(track.remaining(at: 500) == 120, "Paused does not move")
        #expect(track.id == "42")
    }

    @Test func stoppedOrUntitledIsNothing() {
        #expect(NowPlayingTrack.parse(["Player State": "Stopped", "Name": "Song"], player: .music, at: 0) == nil)
        #expect(NowPlayingTrack.parse(["Player State": "Playing"], player: .spotify, at: 0) == nil)
    }

    @Test func positionNeverPassesTheEnd() throws {
        let info: [String: Any] = ["Player State": "Playing", "Name": "Song", "Duration": 10_000, "Playback Position": 9.0]
        let track = try #require(NowPlayingTrack.parse(info, player: .spotify, at: 0))
        #expect(track.remaining(at: 50) == 0)
    }
}
