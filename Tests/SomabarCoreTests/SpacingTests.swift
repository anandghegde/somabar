import Foundation
import Testing
@testable import SomabarCore

@Suite struct SpacingTests {
    @Test func defaultRemovesBothKeys() {
        #expect(Spacing.default.statusItemSpacing == nil)
        #expect(Spacing.default.selectionPadding == nil)
    }

    @Test func snugAndTightValues() {
        #expect(Spacing.snug.statusItemSpacing == 12)
        #expect(Spacing.snug.selectionPadding == 8)
        #expect(Spacing.tight.statusItemSpacing == 6)
        #expect(Spacing.tight.selectionPadding == 6)
    }

    @Test func tighterSpacingIsNeverWider() {
        for spacing in [Spacing.snug, .tight] {
            #expect((spacing.statusItemSpacing ?? 16) < 16)
            #expect((spacing.selectionPadding ?? 16) < 16)
        }
    }

    @Test func recognisesOnlySomabarsOwnValues() {
        #expect(Spacing.isSomabarValue(spacing: 12, padding: 8))
        #expect(Spacing.isSomabarValue(spacing: 6, padding: 6))
        #expect(!Spacing.isSomabarValue(spacing: nil, padding: nil))
        #expect(!Spacing.isSomabarValue(spacing: 10, padding: 8))
        #expect(!Spacing.isSomabarValue(spacing: 12, padding: nil))
    }

    @Test func noticeIsNotShownByDefaultAndOlderFilesDecode() throws {
        #expect(Preferences().spacingNoticeShown == false)
        let data = Data(#"{"spacing": "snug"}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.spacing == .snug)
        #expect(decoded.spacingNoticeShown == false)
    }

    @Test func noticeFlagRoundTrips() throws {
        var preferences = Preferences()
        preferences.spacing = .tight
        preferences.spacingNoticeShown = true
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(Preferences.self, from: data) == preferences)
    }
}
