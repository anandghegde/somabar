import Foundation
import Testing
@testable import SomabarCore

private let slack = ItemKey(bundleID: "com.tinyspeck.slackmacgap")
private let docker = ItemKey(bundleID: "com.docker.docker")

@Suite struct IconChangeConditionTests {
    let evaluator = TriggerEvaluator()

    @Test func holdsOnlyForItemsInTheChangedSet() {
        var context = ContextSnapshot()
        #expect(!evaluator.holds(.iconChanged(slack), in: context))
        context.changedIcons = [slack]
        #expect(evaluator.holds(.iconChanged(slack), in: context))
        #expect(!evaluator.holds(.iconChanged(docker), in: context))
        #expect(evaluator.holds(.anyOf([.iconChanged(docker), .iconChanged(slack)]), in: context))
    }

    @Test func watchedIconsComeFromEnabledTriggersOnly() {
        #expect(Condition.not(.anyOf([.screenSharing, .iconChanged(slack)])).watchedIcons == [slack])
        #expect(Condition.network(.wifi).watchedIcons.isEmpty)

        var document = SomabarDocument.makeDefault()
        document.triggers = [
            Trigger(condition: .iconChanged(slack), action: .show(slack)),
            Trigger(isEnabled: false, condition: .iconChanged(docker), action: .show(docker)),
            Trigger(condition: .external(name: "docker"), action: .show(docker)),
        ]
        #expect(document.watchedIcons == [slack])
        document.triggers[0].isEnabled = false
        #expect(document.watchedIcons.isEmpty)
    }
}

@Suite struct IconFingerprintTests {
    private func fingerprint(alpha: (Int) -> UInt8, colour: (Int) -> UInt8 = { _ in 0 }) throws -> IconFingerprint {
        let size = IconFingerprint.planeSize
        return try #require(IconFingerprint(bytes: (0..<size).map(alpha) + (0..<size).map(colour)))
    }

    /// A 6 × 6 block of coverage in the middle, like a glyph.
    private func glyph(_ index: Int) -> UInt8 {
        let (row, column) = (index / IconFingerprint.side, index % IconFingerprint.side)
        return (5..<11).contains(row) && (5..<11).contains(column) ? 220 : 0
    }

    @Test func needsTwoFullPlanes() {
        #expect(IconFingerprint(bytes: [1, 2, 3]) == nil)
    }

    @Test func blankMeansNothingDrawn() throws {
        #expect(try fingerprint(alpha: { _ in 3 }).isBlank)
        let drawn = try fingerprint(alpha: glyph)
        #expect(!drawn.isBlank)
    }

    @Test func redrawsOfTheSameGlyphDoNotCount() throws {
        let base = try fingerprint(alpha: glyph)
        // Anti-aliasing noise on every pixel, and a few edge pixels moving further.
        let noisy = try fingerprint(alpha: { index in
            let value = Int(glyph(index)) + (index % 3 == 0 ? 20 : -10)
            return UInt8(clamping: index < 4 ? value + 120 : value)
        })
        #expect(!noisy.differs(from: base))
    }

    @Test func aBadgeCounts() throws {
        let base = try fingerprint(alpha: glyph)
        // A 3 × 3 dot in the top-right corner.
        let badged = try fingerprint(alpha: { index in
            let (row, column) = (index / IconFingerprint.side, index % IconFingerprint.side)
            return row < 3 && column >= 13 ? 255 : glyph(index)
        })
        #expect(badged.differs(from: base))
        #expect(badged.changedPixels(from: base) == 9)
    }

    @Test func aColourChangeCountsButALightDarkFlipDoesNot() throws {
        let grey = try fingerprint(alpha: glyph)
        let red = try fingerprint(alpha: glyph, colour: { index in glyph(index) > 0 ? 200 : 0 })
        #expect(red.differs(from: grey))
        // A template glyph drawn black or white has the same coverage and no colour.
        let flipped = try fingerprint(alpha: glyph)
        #expect(!flipped.differs(from: grey))
    }
}

@Suite struct IconChangeHoldTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func changesMergeAndRestartTheHold() {
        var hold = IconChangeHold()
        let first = hold.noteChange([slack], at: start)
        #expect(first)
        #expect(hold.until == start.addingTimeInterval(IconChange.holdSeconds))
        let second = hold.noteChange([docker], at: start.addingTimeInterval(4))
        #expect(second, "A second item joins the first")
        #expect(hold.keys == [slack, docker])
        let again = hold.noteChange([slack], at: start.addingTimeInterval(8))
        #expect(!again, "Same set: nothing to evaluate again")
        #expect(hold.until == start.addingTimeInterval(8 + IconChange.holdSeconds), "but the hold starts again")
        let empty = hold.noteChange([], at: start.addingTimeInterval(9))
        #expect(!empty)
        #expect(hold.until == start.addingTimeInterval(8 + IconChange.holdSeconds))
    }

    @Test func expiresOnlyOnceTheHoldIsOver() {
        var hold = IconChangeHold()
        let idle = hold.expire(at: start)
        #expect(!idle, "Nothing holds")
        hold.noteChange([slack], at: start)
        let early = hold.expire(at: start.addingTimeInterval(IconChange.holdSeconds - 1))
        #expect(!early)
        #expect(hold.keys == [slack])
        let due = hold.expire(at: start.addingTimeInterval(IconChange.holdSeconds))
        #expect(due)
        #expect(hold == IconChangeHold())
    }
}
