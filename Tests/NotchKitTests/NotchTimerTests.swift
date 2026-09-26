import Testing
@testable import NotchKit

@Suite struct NotchTimerTests {
    @Test func startingIsAnActivity() {
        var timer = NotchTimer()
        #expect(!timer.isActive)
        #expect(timer.start(seconds: 1500, at: 100) == [.activityStarted])
        #expect(timer.isRunning)
        #expect(timer.remaining(at: 100) == 1500)
        #expect(timer.remaining(at: 160) == 1440)
    }

    @Test func restartingKeepsOneActivity() {
        var timer = NotchTimer()
        timer.start(seconds: 300, at: 0)
        #expect(timer.start(seconds: 3000, at: 10).isEmpty)
        #expect(timer.duration == 3000)
        #expect(timer.remaining(at: 10) == 3000)
    }

    @Test func finishingEndsTheActivityOnce() {
        var timer = NotchTimer()
        timer.start(seconds: 60, at: 0)
        #expect(timer.tick(at: 59.5).isEmpty)
        #expect(timer.tick(at: 60) == [.activityEnded])
        #expect(!timer.isActive)
        #expect(timer.tick(at: 61).isEmpty)
        #expect(timer.remaining(at: 61) == 0)
    }

    @Test func cancellingEndsTheActivity() {
        var timer = NotchTimer()
        #expect(timer.cancel().isEmpty, "Nothing to cancel")
        timer.start(seconds: 60, at: 0)
        #expect(timer.cancel() == [.activityEnded])
        #expect(!timer.isActive)
        #expect(timer.tick(at: 100).isEmpty)
    }

    @Test func pauseHoldsTheRemainingTime() {
        var timer = NotchTimer()
        timer.start(seconds: 300, at: 0)
        timer.pause(at: 100)
        #expect(timer.isPaused && !timer.isRunning && timer.isActive)
        #expect(timer.remaining(at: 1000) == 200)
        #expect(timer.tick(at: 1000).isEmpty, "A paused timer never finishes")
        timer.resume(at: 1000)
        #expect(timer.isRunning)
        #expect(timer.remaining(at: 1100) == 100)
        #expect(timer.tick(at: 1200) == [.activityEnded])
    }

    @Test func pausedTimerCancelsAndRestarts() {
        var timer = NotchTimer()
        timer.start(seconds: 300, at: 0)
        timer.pause(at: 10)
        #expect(timer.start(seconds: 60, at: 20).isEmpty, "Still one activity")
        #expect(timer.isRunning && !timer.isPaused)
        timer.pause(at: 30)
        #expect(timer.cancel() == [.activityEnded])
    }

    @Test func pauseAndResumeAreIgnoredWhenTheyDoNotApply() {
        var timer = NotchTimer()
        timer.pause(at: 0)
        timer.resume(at: 0)
        #expect(!timer.isActive)
        timer.start(seconds: 60, at: 0)
        timer.resume(at: 30)
        #expect(timer.remaining(at: 30) == 30)
    }

    @Test func displayIsMinutesAndSecondsRoundedUp() {
        #expect(NotchTimer.format(seconds: 1500) == "25:00")
        #expect(NotchTimer.format(seconds: 1499.2) == "25:00")
        #expect(NotchTimer.format(seconds: 1499) == "24:59")
        #expect(NotchTimer.format(seconds: 65) == "1:05")
        #expect(NotchTimer.format(seconds: 0.4) == "0:01")
        #expect(NotchTimer.format(seconds: 0) == "0:00")
        #expect(NotchTimer.format(seconds: -3) == "0:00")
        #expect(NotchTimer.format(seconds: 3000) == "50:00")
        var timer = NotchTimer()
        timer.start(seconds: 300, at: 0)
        #expect(timer.display(at: 1) == "4:59")
    }

    @Test func timerDrivesTheMachine() {
        var machine = NotchMachine()
        var timer = NotchTimer()
        for event in timer.start(seconds: 60, at: 0) { _ = machine.handle(event) }
        #expect(machine.state == .compact)
        for event in timer.tick(at: 60) { _ = machine.handle(event) }
        _ = machine.handle(.oneOffEvent)
        #expect(machine.state == .pulse)
        _ = machine.handle(.pulseElapsed)
        #expect(machine.state == .idle)
    }
}
