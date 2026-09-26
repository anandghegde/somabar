import Foundation
import Testing
@testable import SomabarCore

@Suite struct DisplayRulesTests {
    private let a = ItemKey(bundleID: "com.example.a")
    private let b = ItemKey(bundleID: "com.example.b")
    private let c = ItemKey(bundleID: "com.example.c")
    private let d = ItemKey(bundleID: "com.example.d")
    private let e = ItemKey(bundleID: "com.example.e")

    private var layout: Layout {
        Layout(shown: [a], hidden: [b, c], tucked: [d], locked: [e])
    }

    @Test func narrowDisplayLeavesTheLayoutAlone() {
        let rules = DisplayRules()
        #expect(!rules.showsEverything(screenWidthPoints: 1920))
        #expect(rules.apply(to: layout, screenWidthPoints: 1920) == layout)
    }

    @Test func thresholdItselfIsNotAbove() {
        let rules = DisplayRules()
        #expect(!rules.showsEverything(screenWidthPoints: 2560))
        #expect(rules.showsEverything(screenWidthPoints: 2561))
    }

    @Test func wideDisplayShowsHiddenAndTucked() {
        let result = DisplayRules().apply(to: layout, screenWidthPoints: 3008)
        #expect(result.shown == [d, b, c, a], "Tucked then Hidden join the left end of Shown")
        #expect(result.hidden.isEmpty)
        #expect(result.tucked.isEmpty)
        #expect(result.locked == [e], "Locked items are never shown")
        #expect(result.count == layout.count)
    }

    @Test func turnedOffRuleNeverShowsEverything() {
        var rules = DisplayRules()
        rules.showEverythingAbovePoints = nil
        #expect(!rules.showsEverything(screenWidthPoints: 10_000))
        #expect(rules.apply(to: layout, screenWidthPoints: 10_000) == layout)
    }

    @Test func customThreshold() {
        var rules = DisplayRules()
        rules.showEverythingAbovePoints = 1800
        #expect(rules.apply(to: layout, screenWidthPoints: 1920).hidden.isEmpty)
    }

    @Test func triggerEffectsStillApplyOnTop() {
        let wide = DisplayRules().apply(to: layout, screenWidthPoints: 3008)
        let result = wide.applying(TriggerEffects(show: [], hide: [a]))
        #expect(result.hidden == [a], "A trigger's hide beats the display rule")
        #expect(result.shown == [d, b, c])
    }

    @Test func turnedOffRuleSurvivesARoundTrip() throws {
        var preferences = Preferences()
        preferences.displayRules.showEverythingAbovePoints = nil
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.displayRules.showEverythingAbovePoints == nil)
    }
}

@Suite struct DrawnNotchPreferenceTests {
    @Test func olderFileDecodesWithTheDefault() throws {
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(!decoded.drawnNotch)
        #expect(decoded.notchSurface)
    }

    @Test func drawnNotchSurvivesARoundTrip() throws {
        var preferences = Preferences()
        preferences.drawnNotch = true
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.drawnNotch)
    }
}
