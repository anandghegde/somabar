import ApplicationServices
import CoreGraphics
import SomabarCore
import Testing
@testable import BarEngine

@Suite struct StatusWindowTests {
    @Test func statusLevelIsTwentyFive() {
        #expect(StatusWindows.statusLevel == 25)
    }

    @Test func parsesAStatusItemWindow() {
        let info: [String: Any] = [
            "kCGWindowLayer": 25,
            "kCGWindowNumber": 4242,
            "kCGWindowOwnerPID": 501,
            "kCGWindowOwnerName": "Docker Desktop",
            "kCGWindowBounds": ["X": 1200, "Y": 0, "Width": 32, "Height": 24],
        ]
        let window = StatusWindows.parse(info)
        #expect(window == StatusWindow(windowID: 4242, pid: 501, ownerName: "Docker Desktop", bounds: CGRect(x: 1200, y: 0, width: 32, height: 24)))
    }

    @Test func ignoresOtherLayersAndTallWindows() {
        let normal: [String: Any] = [
            "kCGWindowLayer": 0, "kCGWindowNumber": 1, "kCGWindowOwnerPID": 1,
            "kCGWindowBounds": ["X": 0, "Y": 0, "Width": 800, "Height": 600],
        ]
        let tall: [String: Any] = [
            "kCGWindowLayer": 25, "kCGWindowNumber": 2, "kCGWindowOwnerPID": 1,
            "kCGWindowBounds": ["X": 0, "Y": 0, "Width": 300, "Height": 300],
        ]
        #expect(StatusWindows.parse(normal) == nil)
        #expect(StatusWindows.parse(tall) == nil)
    }
}

@Suite struct BarScannerTests {
    private let controlCenterPID: pid_t = 437
    private let dockerPID: pid_t = 20
    private let handle = AXHandle(AXUIElementCreateSystemWide())

    private var apps: [pid_t: AppIdentity] {
        [
            controlCenterPID: AppIdentity(bundleID: SystemItems.controlCenter, name: "Control Center"),
            dockerPID: AppIdentity(bundleID: "com.docker.docker", name: "Docker Desktop"),
        ]
    }

    /// macOS 26: every status item window belongs to Control Center.
    private func hosted(_ id: CGWindowID, x: CGFloat, width: CGFloat = 38) -> StatusWindow {
        StatusWindow(windowID: id, pid: controlCenterPID, ownerName: "Control Center", bounds: CGRect(x: x, y: 0, width: width, height: 30))
    }

    private func axItem(_ title: String, x: CGFloat, width: CGFloat = 22) -> AXItem {
        AXItem(title: title, frame: CGRect(x: x, y: 4, width: width, height: 22), handle: handle)
    }

    @Test func hostedWindowsAreIdentifiedThroughAccessibility() {
        let windows = [hosted(1, x: 1300), hosted(2, x: 1200), hosted(3, x: 900)]
        let axItems: [pid_t: [AXItem]] = [
            controlCenterPID: [axItem("Clock", x: 1308), axItem("Wi‑Fi", x: 1208)],
            dockerPID: [axItem("Docker Desktop", x: 908)],
        ]
        let items = BarScanner.assemble(windows: windows, apps: apps, axItems: axItems, hostPIDs: [controlCenterPID])
        #expect(items.map(\.key) == [
            ItemKey(bundleID: "com.docker.docker", title: "Docker Desktop"),
            ItemKey(bundleID: SystemItems.controlCenter, title: "Wi‑Fi"),
            ItemKey(bundleID: SystemItems.controlCenter, title: "Clock"),
        ])
        #expect(items.allSatisfy { $0.isIdentified })
        #expect(items.allSatisfy { $0.ax != nil })
        #expect(items[0].pid == dockerPID, "The owner is the app that answered, not the host")
        #expect(items[0].appName == "Docker Desktop")
        #expect(items[1].isManagedByMacOS)
        #expect(SystemItems.isPresentingEssential(items[1].key))
    }

    @Test func somabarsOwnItemsAreNeverItemsWhicheverCopyOwnsThem() {
        let somabarPID: pid_t = 30
        var apps = self.apps
        apps[somabarPID] = AppIdentity(bundleID: "app.somabar.Somabar", name: "Somabar")
        let windows = [hosted(1, x: 1300), hosted(2, x: 1200), hosted(3, x: 1100), hosted(4, x: 900)]
        let axItems: [pid_t: [AXItem]] = [
            controlCenterPID: [axItem("Clock", x: 1308)],
            somabarPID: [axItem("Hide items", x: 1208), axItem("", x: 1108)],
            dockerPID: [axItem("Docker Desktop", x: 908)],
        ]
        let items = BarScanner.assemble(
            windows: windows, apps: apps, axItems: axItems, hostPIDs: [controlCenterPID], ownBundleID: "app.somabar.Somabar"
        )
        #expect(items.map(\.key) == [
            ItemKey(bundleID: "com.docker.docker", title: "Docker Desktop"),
            ItemKey(bundleID: SystemItems.controlCenter, title: "Clock"),
        ])
    }

    @Test func anAgentItemTheHostAlsoExposesIsManagedByMacOS() {
        // Screen Sharing: SSMenuAgent names it; Control Center exposes an untitled element over it.
        let agentPID: pid_t = 30
        var apps = apps
        apps[agentPID] = AppIdentity(bundleID: "com.apple.SSMenuAgent", name: "SSMenuAgent")
        let axItems: [pid_t: [AXItem]] = [
            controlCenterPID: [axItem("", x: 1200, width: 38)],
            agentPID: [axItem("Screen Sharing", x: 1207, width: 24)],
            dockerPID: [axItem("Docker Desktop", x: 908)],
        ]
        let items = BarScanner.assemble(windows: [hosted(1, x: 1200), hosted(2, x: 900)], apps: apps, axItems: axItems, hostPIDs: [controlCenterPID])
        #expect(items.map(\.key) == [
            ItemKey(bundleID: "com.docker.docker", title: "Docker Desktop"),
            ItemKey(bundleID: "com.apple.SSMenuAgent", title: "Screen Sharing"),
        ])
        #expect(items[1].pid == agentPID)
        #expect(items[1].isHostedByMacOS)
        #expect(items[1].isManagedByMacOS)
        #expect(!items[0].isHostedByMacOS)
        #expect(!items[0].isManagedByMacOS)
    }

    @Test func hostedWindowsWithoutAccessibilityStayUnidentified() {
        let windows = [hosted(1, x: 1300), hosted(2, x: 1200), hosted(3, x: 900)]
        let items = BarScanner.assemble(windows: windows, apps: apps, axItems: [:], hostPIDs: [controlCenterPID])
        #expect(items.count == 3)
        #expect(items.allSatisfy { !$0.isIdentified })
        #expect(items.map(\.key) == [
            ItemKey(bundleID: DiscoveredItem.unknownBundleID, ordinal: 0),
            ItemKey(bundleID: DiscoveredItem.unknownBundleID, ordinal: 1),
            ItemKey(bundleID: DiscoveredItem.unknownBundleID, ordinal: 2),
        ])
        #expect(items.allSatisfy { !$0.isManagedByMacOS }, "Unknown items are not treated as system items")
    }

    @Test func ownWindowsIdentifyItemsOnOlderSystems() {
        let windows = [
            StatusWindow(windowID: 1, pid: dockerPID, ownerName: "Docker Desktop", bounds: CGRect(x: 900, y: 0, width: 30, height: 24)),
            StatusWindow(windowID: 2, pid: 77, ownerName: "My Helper (beta)", bounds: CGRect(x: 950, y: 0, width: 30, height: 24)),
        ]
        let items = BarScanner.assemble(windows: windows, apps: apps, axItems: [:], hostPIDs: [])
        #expect(items.map(\.key) == [ItemKey(bundleID: "com.docker.docker"), ItemKey(bundleID: "process.my-helper-beta")])
        #expect(items.allSatisfy { $0.isIdentified })
        #expect(items[1].appName == "My Helper (beta)")
    }

    @Test func sameTitledItemsAreNumberedLeftToRight() {
        let windows = [hosted(1, x: 1300), hosted(2, x: 1200)]
        let axItems: [pid_t: [AXItem]] = [dockerPID: [axItem("", x: 1308), axItem("", x: 1208)]]
        let items = BarScanner.assemble(windows: windows, apps: apps, axItems: axItems, hostPIDs: [controlCenterPID])
        #expect(items.map(\.key.ordinal) == [0, 1])
        #expect(items.map(\.frame.minX) == [1200, 1300])
    }

    @Test func nearestCentreWinsWhenItemsCrowd() {
        let window = hosted(1, x: 1200, width: 40)
        let axItems: [pid_t: [AXItem]] = [
            dockerPID: [axItem("edge", x: 1199, width: 4), axItem("centre", x: 1215, width: 10)],
        ]
        let match = BarScanner.closestAXItem(to: window, in: axItems)
        #expect(match?.1.title == "centre")
    }

    /// Seen on macOS 26: Control Center exposes an untitled element with the window's exact frame
    /// over Screen Sharing's item, and SSMenuAgent exposes the real one, inset and named.
    @Test func theOwningAppBeatsTheHostOnATie() {
        let agentPID: pid_t = 5604
        let window = hosted(1, x: 1526, width: 38)
        let axItems: [pid_t: [AXItem]] = [
            controlCenterPID: [axItem("", x: 1526, width: 38)],
            agentPID: [axItem("Screen Sharing", x: 1533, width: 24)],
        ]
        var apps = self.apps
        apps[agentPID] = AppIdentity(bundleID: "com.apple.SSMenuAgent", name: "SSMenuAgent")
        let items = BarScanner.assemble(windows: [window], apps: apps, axItems: axItems, hostPIDs: [controlCenterPID])
        #expect(items.map(\.key) == [ItemKey(bundleID: "com.apple.SSMenuAgent", title: "Screen Sharing")])
        #expect(items.first?.pid == agentPID)
    }

    @Test func fallbackBundleIDIsASlug() {
        #expect(BarScanner.fallbackBundleID(ownerName: "My Helper (beta)") == "process.my-helper-beta")
        #expect(BarScanner.fallbackBundleID(ownerName: "") == "process.unknown")
    }
}

@Suite struct ScreenGeometryTests {
    @Test func flipIsItsOwnInverse() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let flipped = ScreenGeometry.flip(rect, primaryHeight: 900)
        #expect(flipped == CGRect(x: 10, y: 840, width: 30, height: 40))
        #expect(ScreenGeometry.flip(flipped, primaryHeight: 900) == rect)
    }
}
