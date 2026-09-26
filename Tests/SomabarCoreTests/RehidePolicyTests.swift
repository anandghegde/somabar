import Testing
@testable import SomabarCore

@Suite struct RehidePolicyTests {
    @Test func anOpenMenuWinsThenThePointer() {
        #expect(RehidePolicy.whenTimerFires(menuOpen: true, pointerOnBar: true) == .waitForMenu)
        #expect(RehidePolicy.whenTimerFires(menuOpen: true, pointerOnBar: false) == .waitForMenu)
        #expect(RehidePolicy.whenTimerFires(menuOpen: false, pointerOnBar: true) == .waitForPointer)
        #expect(RehidePolicy.whenTimerFires(menuOpen: false, pointerOnBar: false) == .hide)
    }

    @Test func menuCloseHidesSoonWhenAsked() {
        var preferences = SomabarDocument.makeDefault().preferences
        preferences.rehideWhenMenuCloses = true
        #expect(RehidePolicy.delayAfterMenuClosed(preferences: preferences, revealed: true) == RehidePolicy.afterMenuCloseSeconds)
        #expect(RehidePolicy.delayAfterMenuClosed(preferences: preferences, revealed: false) == nil)
    }

    @Test func menuCloseLeavesTheOrdinaryTimerAloneOtherwise() {
        var preferences = SomabarDocument.makeDefault().preferences
        preferences.rehideWhenMenuCloses = false
        #expect(RehidePolicy.delayAfterMenuClosed(preferences: preferences, revealed: true) == nil)
    }

    @Test func stillModeAndNoTimerNeverHide() {
        var still = SomabarDocument.makeDefault().preferences
        still.stillMode = true
        #expect(RehidePolicy.delayAfterMenuClosed(preferences: still, revealed: true) == nil)

        var never = SomabarDocument.makeDefault().preferences
        never.rehideAfterSeconds = 0
        #expect(RehidePolicy.delayAfterMenuClosed(preferences: never, revealed: true) == nil)
    }
}
