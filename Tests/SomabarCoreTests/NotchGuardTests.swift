import CoreGraphics
import Testing
@testable import SomabarCore

private func item(_ name: String, x: CGFloat, width: CGFloat = 30) -> PlacedItem {
    PlacedItem(key: ItemKey(bundleID: "com.example.\(name)"), frame: CGRect(x: x, y: 0, width: width, height: 24))
}

private let notchMaxX: CGFloat = 900  // a notch from 700 to 900 on a 1512 pt screen

@Suite struct NotchGuardTests {
    @Test func nothingToDoWhenEverythingFits() {
        let shown = [item("a", x: 1000), item("b", x: 1040), item("c", x: 1080)]
        let plan = NotchGuard.plan(shown: shown, notchMaxX: notchMaxX, guarded: [])
        #expect(plan.isEmpty)
    }

    @Test func hidesTheItemsNearestTheDividerFirst() {
        // Two items start left of the notch's right edge: they are under or beyond the camera.
        let shown = [item("under2", x: 850), item("under1", x: 880), item("fits", x: 910), item("right", x: 950)]
        let plan = NotchGuard.plan(shown: shown, notchMaxX: notchMaxX, guarded: [])
        #expect(plan.hide.map(\.key.bundleID) == ["com.example.under2", "com.example.under1"])
        #expect(plan.hide.map(\.width) == [30, 30])
        #expect(plan.restore.isEmpty)
    }

    @Test func orderComesFromPositionNotInputOrder() {
        let shown = [item("b", x: 880), item("a", x: 850)]
        let plan = NotchGuard.plan(shown: shown, notchMaxX: notchMaxX, guarded: [])
        #expect(plan.hide.map(\.key.bundleID) == ["com.example.a", "com.example.b"])
    }

    @Test func restoresTheMostRecentlyGuardedItemWhenSpaceFreesUp() {
        let guarded = [
            GuardedItem(key: ItemKey(bundleID: "com.example.first"), width: 40),
            GuardedItem(key: ItemKey(bundleID: "com.example.second"), width: 30),
        ]
        // 50 pt free between the notch and the leftmost Shown item: room for "second" only.
        let shown = [item("a", x: 950), item("b", x: 990)]
        let plan = NotchGuard.plan(shown: shown, notchMaxX: notchMaxX, guarded: guarded)
        #expect(plan.restore.map(\.bundleID) == ["com.example.second"])
        #expect(plan.hide.isEmpty)
    }

    @Test func restoresSeveralWhileTheyFit() {
        let guarded = [
            GuardedItem(key: ItemKey(bundleID: "com.example.first"), width: 40),
            GuardedItem(key: ItemKey(bundleID: "com.example.second"), width: 30),
        ]
        let shown = [item("a", x: 1000)]
        let plan = NotchGuard.plan(shown: shown, notchMaxX: notchMaxX, guarded: guarded)
        #expect(plan.restore.map(\.bundleID) == ["com.example.second", "com.example.first"])
    }

    @Test func emptyShownRestoresEverything() {
        let guarded = [GuardedItem(key: ItemKey(bundleID: "com.example.only"), width: 40)]
        let plan = NotchGuard.plan(shown: [], notchMaxX: notchMaxX, guarded: guarded)
        #expect(plan.restore.map(\.bundleID) == ["com.example.only"])
    }
}

@Suite struct NotchGeometryTests {
    @Test func notchIsTheGapBetweenAuxiliaryAreas() {
        let geometry = NotchGeometry.fromAuxiliaryAreas(
            screenWidth: 1512, menuBarHeight: 38,
            left: CGRect(x: 0, y: 0, width: 656, height: 38),
            right: CGRect(x: 856, y: 0, width: 656, height: 38)
        )
        #expect(geometry.notch == CGRect(x: 656, y: 0, width: 200, height: 38))
        #expect(geometry.notchMaxX == 856)
        #expect(geometry.hasSurface)
    }

    @Test func noAuxiliaryAreasMeansNoNotch() {
        let geometry = NotchGeometry.fromAuxiliaryAreas(screenWidth: 2560, menuBarHeight: 24, left: nil, right: nil)
        #expect(geometry.notch == nil)
        #expect(!geometry.hasSurface)
        #expect(geometry.compactFrame(extensionPerSide: 40) == nil)
    }

    @Test func drawnNotchIsCentred() {
        let geometry = NotchGeometry.drawn(screenWidth: 2560, menuBarHeight: 24)
        #expect(geometry.isDrawn)
        #expect(geometry.notch?.midX == 1280)
        #expect(geometry.notch?.size == NotchGeometry.drawnNotchSize)
    }

    @Test func compactExtensionIsCapped() {
        let geometry = NotchGeometry(screenWidth: 1512, menuBarHeight: 38, notch: CGRect(x: 656, y: 0, width: 200, height: 38))
        let frame = geometry.compactFrame(extensionPerSide: 500)
        #expect(frame == CGRect(x: 656 - 80, y: 0, width: 200 + 160, height: 38))
    }

    @Test func expandedIsCappedAndAnchoredToTheCamera() {
        let geometry = NotchGeometry(screenWidth: 1512, menuBarHeight: 38, notch: CGRect(x: 656, y: 0, width: 200, height: 38))
        let frame = geometry.expandedFrame(size: CGSize(width: 900, height: 400))
        #expect(frame?.size == NotchGeometry.maxExpandedSize)
        #expect(frame?.midX == 756)
        #expect(frame?.minY == 0)
    }

    @Test func expandedStaysOnScreen() {
        let geometry = NotchGeometry(screenWidth: 600, menuBarHeight: 38, notch: CGRect(x: 20, y: 0, width: 100, height: 38))
        let frame = geometry.expandedFrame(size: CGSize(width: 400, height: 100))
        #expect(frame?.minX == 0)
    }
}
