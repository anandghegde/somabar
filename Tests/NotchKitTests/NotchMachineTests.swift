import CoreGraphics
import Testing
@testable import NotchKit

@Suite struct NotchMachineTests {
    @Test func idleIsTheDefault() {
        let machine = NotchMachine()
        #expect(machine.state == .idle)
        #expect(machine.liveActivities == 0)
    }

    @Test func activitiesMoveBetweenIdleAndCompact() {
        var machine = NotchMachine()
        #expect(machine.handle(.activityStarted).isEmpty)
        #expect(machine.state == .compact)
        _ = machine.handle(.activityStarted)
        _ = machine.handle(.activityEnded)
        #expect(machine.state == .compact, "One activity is still live")
        _ = machine.handle(.activityEnded)
        #expect(machine.state == .idle)
        _ = machine.handle(.activityEnded)
        #expect(machine.liveActivities == 0, "Never negative")
    }

    @Test func pulseReturnsToWhereItWas() {
        var machine = NotchMachine()
        #expect(machine.handle(.oneOffEvent) == [.start(.pulse, seconds: NotchMachine.pulseHoldSeconds)])
        #expect(machine.state == .pulse)
        _ = machine.handle(.pulseElapsed)
        #expect(machine.state == .idle)

        _ = machine.handle(.activityStarted)
        _ = machine.handle(.oneOffEvent)
        _ = machine.handle(.pulseElapsed)
        #expect(machine.state == .compact)
    }

    @Test func pulseFollowsActivityChangesWhilePulsing() {
        var machine = NotchMachine()
        _ = machine.handle(.oneOffEvent)
        _ = machine.handle(.activityStarted)
        _ = machine.handle(.pulseElapsed)
        #expect(machine.state == .compact, "An activity that started during the pulse shows afterwards")
    }

    @Test func repeatedPulseRestartsTheTimer() {
        var machine = NotchMachine()
        _ = machine.handle(.oneOffEvent)
        #expect(machine.handle(.oneOffEvent) == [.cancel(.pulse), .start(.pulse, seconds: NotchMachine.pulseHoldSeconds)])
    }

    @Test func hoverIntentAndClickExpand() {
        var idle = NotchMachine()
        #expect(idle.handle(.hoverIntent).isEmpty)
        #expect(idle.state == .expanded)

        var compact = NotchMachine()
        _ = compact.handle(.activityStarted)
        _ = compact.handle(.click)
        #expect(compact.state == .expanded)

        var pulsing = NotchMachine()
        _ = pulsing.handle(.oneOffEvent)
        #expect(pulsing.handle(.hoverIntent) == [.cancel(.pulse)])
        #expect(pulsing.state == .expanded)
    }

    @Test func oneOffEventsAreIgnoredWhileExpanded() {
        var machine = NotchMachine()
        _ = machine.handle(.click)
        #expect(machine.handle(.oneOffEvent).isEmpty)
        #expect(machine.state == .expanded)
    }

    @Test func leavingExpandedWaitsThenRests() {
        var machine = NotchMachine()
        _ = machine.handle(.activityStarted)
        _ = machine.handle(.hoverIntent)
        #expect(machine.handle(.pointerLeft) == [.start(.leave, seconds: NotchMachine.leaveDelaySeconds)])
        #expect(machine.state == .expanded, "Still expanded until the delay passes")
        #expect(machine.handle(.pointerReturned) == [.cancel(.leave)])
        _ = machine.handle(.pointerLeft)
        _ = machine.handle(.leaveElapsed)
        #expect(machine.state == .compact)

        _ = machine.handle(.activityEnded)
        _ = machine.handle(.click)
        _ = machine.handle(.pointerLeft)
        _ = machine.handle(.leaveElapsed)
        #expect(machine.state == .idle, "Nothing live: back to Idle")
    }

    @Test func timersOnlyMatterInTheirState() {
        var machine = NotchMachine()
        #expect(machine.handle(.pulseElapsed).isEmpty)
        #expect(machine.handle(.leaveElapsed).isEmpty)
        #expect(machine.handle(.pointerLeft).isEmpty)
        #expect(machine.state == .idle)
    }
}

@Suite struct HoverIntentTests {
    private func sample(_ x: CGFloat, at time: Double) -> PointerSample {
        PointerSample(point: CGPoint(x: x, y: 10), time: time)
    }

    @Test func slowPointerInsideFiresAfterTheDwell() {
        var detector = HoverIntentDetector()
        #expect(detector.feed(sample(100, at: 0.00), inside: true) == false)
        #expect(detector.feed(sample(101, at: 0.05), inside: true) == false)
        #expect(detector.feed(sample(102, at: 0.10), inside: true) == false)
        #expect(detector.feed(sample(103, at: 0.16), inside: true) == true)
        #expect(detector.feed(sample(104, at: 0.20), inside: true) == false, "Fires once")
    }

    @Test func passingThroughNeverFires() {
        var detector = HoverIntentDetector()
        // 200 pt in 0.2 s: 1000 pt/s, well above 120 pt/s.
        #expect(detector.feed(sample(0, at: 0.0), inside: true) == false)
        #expect(detector.feed(sample(50, at: 0.05), inside: true) == false)
        #expect(detector.feed(sample(100, at: 0.10), inside: true) == false)
        #expect(detector.feed(sample(150, at: 0.15), inside: true) == false)
        #expect(detector.feed(sample(200, at: 0.20), inside: true) == false)
        #expect(detector.feed(sample(400, at: 0.25), inside: false) == false)
    }

    @Test func speedingUpResetsTheDwell() {
        var detector = HoverIntentDetector()
        _ = detector.feed(sample(0, at: 0.00), inside: true)
        _ = detector.feed(sample(1, at: 0.10), inside: true)
        _ = detector.feed(sample(60, at: 0.12), inside: true)  // a quick flick
        #expect(detector.feed(sample(61, at: 0.20), inside: true) == false, "Dwell restarted at the flick")
        #expect(detector.feed(sample(62, at: 0.28), inside: true) == false, "Only 80 ms slow since the flick")
        #expect(detector.feed(sample(63, at: 0.36), inside: true) == true)
    }

    @Test func leavingRearms() {
        var detector = HoverIntentDetector()
        _ = detector.feed(sample(0, at: 0.0), inside: true)
        #expect(detector.feed(sample(1, at: 0.2), inside: true) == true)
        _ = detector.feed(sample(500, at: 0.3), inside: false)
        _ = detector.feed(sample(0, at: 0.4), inside: true)
        #expect(detector.feed(sample(1, at: 0.6), inside: true) == true)
    }
}
