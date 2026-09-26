import Testing
@testable import SomabarCore

@Suite struct RevealGestureTests {
    private func recognizer(hover: Bool = false, click: Bool = true, scroll: Bool = false, delay: Int = 300) -> RevealGestureRecognizer {
        var gestures = RevealGestures()
        gestures.hoverEmptyBar = hover
        gestures.clickEmptyBar = click
        gestures.scrollDownOnBar = scroll
        gestures.hoverDelayMilliseconds = delay
        return RevealGestureRecognizer(gestures: gestures)
    }

    // MARK: Hover

    @Test func hoverArmsOnceAndFiresAfterTheDelay() {
        var r = recognizer(hover: true, delay: 300)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 10)
        #expect(r.hoverDeadline == 10.3)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 10.1)
        #expect(r.hoverDeadline == 10.3, "moving within the empty bar keeps the first deadline")
        #expect(r.tick(at: 10.2) == nil)
        #expect(r.tick(at: 10.3) == .reveal)
        #expect(r.hoverDeadline == nil)
        #expect(r.tick(at: 10.4) == nil, "fires once")
    }

    @Test func leavingTheEmptyBarDisarmsTheHover() {
        var r = recognizer(hover: true)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 0)
        r.pointerMoved(to: .item, revealed: false, at: 0.1)
        #expect(r.hoverDeadline == nil)
        #expect(r.tick(at: 1) == nil)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 2)
        r.pointerMoved(to: .offBar, revealed: false, at: 2.1)
        #expect(r.hoverDeadline == nil)
    }

    @Test func hoverOffNeverArms() {
        var r = recognizer(hover: false)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 0)
        #expect(r.hoverDeadline == nil)
    }

    @Test func hoverDoesNotArmOverARevealedBar() {
        var r = recognizer(hover: true)
        r.pointerMoved(to: .emptyBar, revealed: true, at: 0)
        #expect(r.hoverDeadline == nil)
    }

    @Test func aBarHiddenUnderTheRestingPointerStaysHidden() {
        var r = recognizer(hover: true, scroll: true)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 0)
        #expect(r.tick(at: 0.3) == .reveal)
        #expect(r.scroll(deltaY: 30, at: 2, revealed: true) == .hide, "the person hides it again")
        r.pointerMoved(to: .emptyBar, revealed: false, at: 2.1)
        #expect(r.hoverDeadline == nil, "no second reveal until the pointer leaves the bar")
        r.pointerMoved(to: .item, revealed: false, at: 2.5)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 2.6)
        #expect(r.hoverDeadline == nil, "an item is still the bar")
        r.pointerMoved(to: .offBar, revealed: false, at: 3)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 4)
        #expect(r.hoverDeadline == 4.3, "a fresh visit arms again")
    }

    @Test func aScrollGestureDisarmsThePendingHover() {
        var r = recognizer(hover: true, scroll: true)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 0)
        #expect(r.scroll(deltaY: -30, at: 0.1, revealed: false) == .reveal)
        #expect(r.hoverDeadline == nil)
        #expect(r.tick(at: 0.3) == nil)
    }

    @Test func aClickDisarmsThePendingHover() {
        var r = recognizer(hover: true)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 0)
        #expect(r.click(onEmptyBar: true, revealed: false) == .reveal)
        #expect(r.hoverDeadline == nil)
        #expect(r.tick(at: 1) == nil, "the hover never fires on top of the click")
        r.pointerMoved(to: .emptyBar, revealed: true, at: 1.1)
        #expect(r.click(onEmptyBar: true, revealed: true) == .hide)
        r.pointerMoved(to: .emptyBar, revealed: false, at: 1.2)
        #expect(r.hoverDeadline == nil, "hidden by hand under the pointer; hover waits for a fresh visit")
    }

    @Test func hoverDelayIsClamped() {
        #expect(recognizer(delay: -5).hoverDelay == 0)
        #expect(recognizer(delay: 5000).hoverDelay == 0.8)
        #expect(recognizer(delay: 250).hoverDelay == 0.25)
    }

    // MARK: Click

    @Test func clickOnEmptyBarToggles() {
        var r = recognizer(click: true)
        #expect(r.click(onEmptyBar: true, revealed: false) == .reveal)
        #expect(r.click(onEmptyBar: true, revealed: true) == .hide)
        #expect(r.click(onEmptyBar: false, revealed: false) == nil)
    }

    @Test func clickOffDoesNothing() {
        var r = recognizer(click: false)
        #expect(r.click(onEmptyBar: true, revealed: false) == nil)
    }

    // MARK: Scroll

    @Test func scrollDownAccumulatesToAReveal() {
        var r = recognizer(scroll: true)
        #expect(r.scroll(deltaY: -8, at: 1.0, revealed: false) == nil)
        #expect(r.scroll(deltaY: -8, at: 1.1, revealed: false) == nil)
        #expect(r.scroll(deltaY: -8, at: 1.2, revealed: false) == .reveal)
    }

    @Test func scrollUpHidesOnlyWhenRevealed() {
        var r = recognizer(scroll: true)
        #expect(r.scroll(deltaY: 25, at: 1.0, revealed: false) == nil)
        #expect(r.scroll(deltaY: 25, at: 3.0, revealed: true) == .hide)
    }

    @Test func aPauseStartsANewScrollGesture() {
        var r = recognizer(scroll: true)
        #expect(r.scroll(deltaY: -15, at: 1.0, revealed: false) == nil)
        #expect(r.scroll(deltaY: -15, at: 2.0, revealed: false) == nil, "0.6 s later: the first 15 pt no longer count")
        #expect(r.scroll(deltaY: -15, at: 2.1, revealed: false) == .reveal)
    }

    @Test func scrollCooldownSwallowsTheFollowThrough() {
        var r = recognizer(scroll: true)
        #expect(r.scroll(deltaY: -30, at: 1.0, revealed: false) == .reveal)
        #expect(r.scroll(deltaY: 30, at: 1.5, revealed: true) == nil, "within the cooldown")
        #expect(r.scroll(deltaY: 30, at: 2.5, revealed: true) == .hide)
    }

    @Test func scrollOffDoesNothing() {
        var r = recognizer(scroll: false)
        #expect(r.scroll(deltaY: -100, at: 1.0, revealed: false) == nil)
    }
}
