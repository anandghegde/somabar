import CoreGraphics
import Testing
@testable import BarEngine

@Suite struct StatusWindowMatchingTests {
    private let windows = [
        StatusWindow(windowID: 1, pid: 437, ownerName: "Control Center", bounds: CGRect(x: 1400, y: 0, width: 40, height: 30)),
        StatusWindow(windowID: 2, pid: 437, ownerName: "Control Center", bounds: CGRect(x: 1440, y: 0, width: 8, height: 30)),
        StatusWindow(windowID: 3, pid: 437, ownerName: "Control Center", bounds: CGRect(x: 1448, y: 0, width: 24, height: 30)),
    ]

    @Test func matchesByRowCentreAndWidth() {
        let divider = CGRect(x: 1440, y: 0, width: 8, height: 30)
        #expect(StatusWindows.window(matching: divider, in: windows)?.windowID == 2)
        let slightlyOff = CGRect(x: 1439, y: 1, width: 9, height: 30)
        #expect(StatusWindows.window(matching: slightlyOff, in: windows)?.windowID == 2)
    }

    @Test func rejectsOtherRowsAndWidths() {
        #expect(StatusWindows.window(matching: CGRect(x: 1440, y: 100, width: 8, height: 30), in: windows) == nil)
        #expect(StatusWindows.window(matching: CGRect(x: 1400, y: 0, width: 80, height: 30), in: windows) == nil)
    }
}

@Suite struct MenuWindowTests {
    private let bar = CGRect(x: 0, y: 0, width: 1920, height: 24)

    @Test func parsesAPopUpMenuWindow() {
        let info: [String: Any] = [
            "kCGWindowLayer": MenuWindows.popUpLevel,
            "kCGWindowNumber": 77,
            "kCGWindowOwnerPID": 501,
            "kCGWindowBounds": ["X": 1429, "Y": 31, "Width": 124, "Height": 58],
        ]
        #expect(MenuWindows.parse(info) == MenuWindow(windowID: 77, pid: 501, bounds: CGRect(x: 1429, y: 31, width: 124, height: 58)))
        #expect(MenuWindows.popUpLevel == 101)
    }

    @Test func ignoresOtherLayers() {
        let info: [String: Any] = [
            "kCGWindowLayer": 25, "kCGWindowNumber": 1, "kCGWindowOwnerPID": 1,
            "kCGWindowBounds": ["X": 0, "Y": 31, "Width": 100, "Height": 50],
        ]
        #expect(MenuWindows.parse(info) == nil)
    }

    @Test func aMenuHangsWhenItsTopSitsJustUnderTheBar() {
        #expect(MenuWindows.hangs(CGRect(x: 1429, y: 31, width: 124, height: 58), from: bar))
        #expect(MenuWindows.hangs(CGRect(x: 1429, y: 24, width: 124, height: 58), from: bar))
        #expect(!MenuWindows.hangs(CGRect(x: 1429, y: 200, width: 124, height: 58), from: bar), "a context menu in a window")
        #expect(!MenuWindows.hangs(CGRect(x: 2000, y: 31, width: 124, height: 58), from: bar), "another screen")
    }
}

@Suite struct EmptyBarHitTestTests {
    private let bar = CGRect(x: 0, y: 0, width: 1920, height: 24)
    private let glyph = CGRect(x: 1570, y: 0, width: 30, height: 30)
    private let collapsedDivider = CGRect(x: -8430, y: 0, width: 10_000, height: 30)
    /// On macOS 26 Control Center owns every status window, Somabar's glyph and divider included.
    private var items: [StatusWindow] {
        [
            StatusWindow(windowID: 1, pid: 437, ownerName: "Control Center", bounds: CGRect(x: 1600, y: 0, width: 320, height: 30)),
            StatusWindow(windowID: 2, pid: 437, ownerName: "Control Center", bounds: glyph),
            StatusWindow(windowID: 3, pid: 437, ownerName: "Control Center", bounds: collapsedDivider),
        ]
    }

    private func isEmpty(_ x: CGFloat, y: CGFloat = 12) -> Bool {
        EmptyBarHitTest.isEmpty(
            point: CGPoint(x: x, y: y), bar: bar, statusWindows: items, ownFrames: [glyph, collapsedDivider], appMenusMaxX: 400
        )
    }

    @Test func emptyBetweenTheAppMenusAndTheItems() {
        #expect(isEmpty(1000))
        #expect(isEmpty(401))
    }

    @Test func notEmptyOnMenusItemsOrTheGlyph() {
        #expect(!isEmpty(300), "app menus")
        #expect(!isEmpty(400), "the last menu's right edge")
        #expect(!isEmpty(1700), "a status item")
        #expect(!isEmpty(1580), "Somabar's glyph")
    }

    @Test func notEmptyOffTheBar() {
        #expect(!isEmpty(1000, y: 40))
        #expect(!isEmpty(1000, y: 24), "the bar's bottom edge is outside")
    }

    @Test func aCollapsedDividerDoesNotCountAsAnItem() {
        // The 10,000 pt divider lies under the whole empty bar, and Control Center lists its
        // window like any other item's; a point over it is still empty.
        #expect(isEmpty(1000))
        #expect(EmptyBarHitTest.isOwn(collapsedDivider, window: items[2]))
        #expect(!EmptyBarHitTest.isOwn(collapsedDivider, window: items[0]))
    }
}

@Suite struct ItemMoverGeometryTests {
    private let target = CGRect(x: 1440, y: 0, width: 8, height: 30)

    @Test func endPointIsTheTargetEdgeOnItsCentreLine() {
        #expect(ItemMover.endPoint(for: .leftOf, target: target) == CGPoint(x: 1440, y: 15))
        #expect(ItemMover.endPoint(for: .rightOf, target: target) == CGPoint(x: 1448, y: 15))
    }

    @Test func verifiedWhenTouchingTheRightEdge() {
        let leftNeighbour = CGRect(x: 1400, y: 0, width: 40, height: 30)
        let rightNeighbour = CGRect(x: 1448, y: 0, width: 24, height: 30)
        #expect(ItemMover.isVerified(item: leftNeighbour, target: target, side: .leftOf))
        #expect(!ItemMover.isVerified(item: leftNeighbour, target: target, side: .rightOf))
        #expect(ItemMover.isVerified(item: rightNeighbour, target: target, side: .rightOf))
        #expect(!ItemMover.isVerified(item: rightNeighbour, target: target, side: .leftOf))
    }

    @Test func toleranceAndRowMatter() {
        let nearlyTouching = CGRect(x: 1397, y: 0, width: 40, height: 30)
        #expect(ItemMover.isVerified(item: nearlyTouching, target: target, side: .leftOf, tolerance: 4))
        #expect(!ItemMover.isVerified(item: nearlyTouching, target: target, side: .leftOf, tolerance: 2))
        let lifted = CGRect(x: 1400, y: 1079, width: 40, height: 30)
        #expect(!ItemMover.isVerified(item: lifted, target: target, side: .leftOf))
    }
}
