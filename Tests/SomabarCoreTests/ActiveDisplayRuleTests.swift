import Foundation
import Testing
@testable import SomabarCore

@Suite struct ActiveDisplayRuleTests {
    private func context(active: Int, widest: Int) -> ContextSnapshot {
        var snapshot = ContextSnapshot()
        snapshot.activeDisplayPoints = active
        snapshot.widestDisplayPoints = widest
        snapshot.displayCount = 2
        return snapshot
    }

    @Test func leavingInactiveDisplaysUntouchedIsTheDefault() {
        #expect(DisplayRules().leaveInactiveDisplaysUntouched)
    }

    @Test func activeDisplayDecidesByDefault() {
        let rules = DisplayRules()
        let onLaptop = context(active: 1512, widest: 3008)
        #expect(rules.evaluatedWidthPoints(in: onLaptop) == 1512)
        #expect(!rules.showsEverything(screenWidthPoints: rules.evaluatedWidthPoints(in: onLaptop)),
                "A wide display nobody is using does not show everything")
        let onStudioDisplay = context(active: 3008, widest: 3008)
        #expect(rules.showsEverything(screenWidthPoints: rules.evaluatedWidthPoints(in: onStudioDisplay)))
    }

    @Test func turnedOffFollowsTheWidestDisplay() {
        var rules = DisplayRules()
        rules.leaveInactiveDisplaysUntouched = false
        let onLaptop = context(active: 1512, widest: 3008)
        #expect(rules.evaluatedWidthPoints(in: onLaptop) == 3008)
        #expect(rules.showsEverything(screenWidthPoints: rules.evaluatedWidthPoints(in: onLaptop)))
    }

    @Test func unknownActiveDisplayFallsBackToTheWidest() {
        let rules = DisplayRules()
        #expect(rules.evaluatedWidthPoints(in: context(active: 0, widest: 2560)) == 2560)
    }

    @Test func settingSurvivesARoundTripAndOlderFilesKeepTheDefault() throws {
        var preferences = Preferences()
        preferences.displayRules.leaveInactiveDisplaysUntouched = false
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(!decoded.displayRules.leaveInactiveDisplaysUntouched)
        let older = try JSONDecoder().decode(Preferences.self, from: Data(#"{"displayRules":{}}"#.utf8))
        #expect(older.displayRules.leaveInactiveDisplaysUntouched)
    }
}
