import Testing
@testable import SomabarCore

@Suite struct OrderedMovesTests {
    private let a = ItemKey(bundleID: "a")
    private let b = ItemKey(bundleID: "b")
    private let c = ItemKey(bundleID: "c")
    private let d = ItemKey(bundleID: "d")

    @Test func shownIsMovedLastToFirstSoTheFirstEndsUpLeftmost() {
        // Each move lands at the left end of Shown, so the item the layout wants leftmost moves last.
        let desired = Layout(shown: [a, b, c])
        let drifts = [Drift(item: a, expected: .shown, actual: .hidden), Drift(item: c, expected: .shown, actual: .hidden)]
        #expect(Reconciler.orderedMoves(drifts, desired: desired).map(\.item) == [c, a])
    }

    @Test func otherSectionsAreMovedFirstToLast() {
        // Each move lands at the right end (next to the divider), pushing earlier ones left.
        let desired = Layout(hidden: [a, b, c], tucked: [d])
        let drifts = [
            Drift(item: c, expected: .hidden, actual: .shown),
            Drift(item: d, expected: .tucked, actual: .shown),
            Drift(item: a, expected: .hidden, actual: .shown),
        ]
        #expect(Reconciler.orderedMoves(drifts, desired: desired).map(\.item) == [d, a, c])
    }

    @Test func sectionsComeOutInBarOrder() {
        let desired = Layout(shown: [a], hidden: [b], tucked: [c], locked: [d])
        let drifts = [
            Drift(item: a, expected: .shown, actual: .hidden),
            Drift(item: b, expected: .hidden, actual: .shown),
            Drift(item: c, expected: .tucked, actual: .shown),
            Drift(item: d, expected: .locked, actual: .shown),
        ]
        #expect(Reconciler.orderedMoves(drifts, desired: desired).map(\.expected) == [.locked, .tucked, .hidden, .shown])
    }

    @Test func unknownItemsGoLast() {
        let desired = Layout(hidden: [a])
        let drifts = [Drift(item: b, expected: .hidden, actual: .shown), Drift(item: a, expected: .hidden, actual: .shown)]
        #expect(Reconciler.orderedMoves(drifts, desired: desired).map(\.item) == [a, b])
    }
}
