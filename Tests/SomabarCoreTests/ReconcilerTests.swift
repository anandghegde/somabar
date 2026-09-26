import CoreGraphics
import Testing
@testable import SomabarCore

private func placed(_ key: ItemKey, x: CGFloat, width: CGFloat = 30) -> PlacedItem {
    PlacedItem(key: key, frame: CGRect(x: x, y: 0, width: width, height: 24))
}

private let docker = ItemKey(bundleID: "com.docker.docker")
private let tailscale = ItemKey(bundleID: "io.tailscale.ipn.macos")
private let slack = ItemKey(bundleID: "com.tinyspeck.slackmacgap")
private let onePassword = ItemKey(bundleID: "com.1password.1password")
private let clock = ItemKey(bundleID: SystemItems.controlCenter, title: "Clock")

@Suite struct ObservedBarTests {
    // Both dividers inflated to 10,000 pt. The hidden divider spans [-9000, 1000) and pushes the
    // hidden items to x < -9000; the tucked divider then spans [-19_060, -9060) and pushes the
    // tucked items to x < -19_060. Each divider's x is its right edge.
    let bar = ObservedBar(
        items: [
            placed(onePassword, x: -19_500),
            placed(slack, x: -19_100),
            placed(tailscale, x: -9_050),
            placed(docker, x: 1000),
            placed(clock, x: 1400),
        ],
        hiddenDividerX: 990,
        tuckedDividerX: -9_060
    )

    @Test func sectionsFollowTheDividers() {
        let known = Layout(locked: [onePassword])
        #expect(bar.section(of: placed(docker, x: 1000), known: known) == .shown)
        #expect(bar.section(of: placed(tailscale, x: -9_050), known: known) == .hidden)
        #expect(bar.section(of: placed(slack, x: -19_100), known: known) == .tucked)
        #expect(bar.section(of: placed(onePassword, x: -19_500), known: known) == .locked, "The known layout tells Locked from Tucked")
    }

    @Test func observedLayoutIsInBarOrderWithSystemItemsShown() {
        let layout = bar.layout(known: Layout(locked: [onePassword]))
        #expect(layout.locked == [onePassword])
        #expect(layout.tucked == [slack])
        #expect(layout.hidden == [tailscale])
        #expect(layout.shown == [docker, clock])
    }
}

@Suite struct ReconcilerTests {
    @Test func newItemsExcludeSystemOnes() {
        let layout = Layout(shown: [docker])
        #expect(Reconciler.newItems(observed: [docker, tailscale, clock], layout: layout) == [tailscale])
    }

    @Test func missingItemsKeepTheirSlot() {
        let layout = Layout(shown: [docker], hidden: [tailscale])
        #expect(Reconciler.missingItems(observed: [docker], layout: layout) == [tailscale])
    }

    @Test func driftListsOnlyDifferences() {
        let desired = Layout(shown: [docker, clock], hidden: [tailscale, slack])
        let observed = Layout(shown: [docker, tailscale, clock], hidden: [slack])
        let drift = Reconciler.drift(desired: desired, observed: observed)
        #expect(drift == [Drift(item: tailscale, expected: .hidden, actual: .shown)])
    }
}
