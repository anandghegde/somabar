import AppKit
import SomabarCore

/// A running process that might own status items.
public struct AppIdentity: Equatable, Sendable {
    public var bundleID: String?
    public var name: String

    public init(bundleID: String?, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Finds every status item in the bar.
///
/// The window list gives each item's frame without any permission. On macOS 26 every status
/// item window is hosted by Control Center, so the window says nothing about the owning app;
/// identity comes from Accessibility, matched to windows by position, when Somabar is trusted.
/// Older systems put each item's window in its own app's process, which identifies it directly.
@MainActor
public enum BarScanner {
    /// Scans the bar. Accessibility queries run off the main thread.
    public static func scan(ownFrames: [CGRect]) async -> [DiscoveredItem] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        // Status windows sit on the top edge of a screen; anything else at that level is not an item.
        let screenTops = Set(NSScreen.screens.map { ScreenGeometry.topLeft($0.frame).minY.rounded() })
        let windows = StatusWindows.current(excludingPID: myPID).filter { window in
            screenTops.contains(window.bounds.minY.rounded())
                && !ownFrames.contains { own in own.midX >= window.bounds.minX && own.midX <= window.bounds.maxX }
        }

        let running = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != myPID }
        var apps: [pid_t: AppIdentity] = [:]
        for app in running {
            apps[app.processIdentifier] = AppIdentity(bundleID: app.bundleIdentifier, name: app.localizedName ?? "")
        }
        let hostPIDs = Set(running.filter { $0.bundleIdentifier == SystemItems.controlCenter }.map(\.processIdentifier))

        var axItems: [pid_t: [AXItem]] = [:]
        if AccessibilityPermission.isTrusted {
            let pids = Array(apps.keys)
            axItems = await Task.detached(priority: .userInitiated) {
                AccessibilityDiscovery.items(forPIDs: pids)
            }.value
        }
        return assemble(windows: windows, apps: apps, axItems: axItems, hostPIDs: hostPIDs, ownBundleID: Bundle.main.bundleIdentifier)
    }

    /// Joins windows with the apps that own them and numbers duplicates left to right. Pure, so
    /// the matching is testable.
    ///
    /// - Parameters:
    ///   - hostPIDs: processes whose windows show other apps' items (Control Center on macOS 26).
    ///     A window of theirs with no Accessibility match stays unidentified.
    ///   - ownBundleID: Somabar's own. Its items are never items to manage, whichever process
    ///     they belong to; a second copy's glyph and dividers must not end up in the layout.
    nonisolated public static func assemble(
        windows: [StatusWindow],
        apps: [pid_t: AppIdentity],
        axItems: [pid_t: [AXItem]],
        hostPIDs: Set<pid_t>,
        ownBundleID: String? = nil
    ) -> [DiscoveredItem] {
        var items = match(windows: windows, apps: apps, axItems: axItems, hostPIDs: hostPIDs)
        if let ownBundleID {
            items.removeAll { $0.key.bundleID == ownBundleID }
        }

        var seen: [ItemKey: Int] = [:]
        for index in items.indices {
            let base = items[index].key
            let count = seen[base, default: 0]
            items[index].key.ordinal = count
            seen[base] = count + 1
        }
        return items
    }

    private nonisolated static func match(
        windows: [StatusWindow],
        apps: [pid_t: AppIdentity],
        axItems: [pid_t: [AXItem]],
        hostPIDs: Set<pid_t>
    ) -> [DiscoveredItem] {
        var items: [DiscoveredItem] = []
        for window in windows.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            if let (pid, match) = closestAXItem(to: window, in: axItems, hostPIDs: hostPIDs) {
                let app = apps[pid] ?? AppIdentity(bundleID: nil, name: "")
                let hosted = !hostPIDs.contains(pid) && hostExposes(window, in: axItems, hostPIDs: hostPIDs)
                items.append(DiscoveredItem(
                    key: ItemKey(bundleID: app.bundleID ?? fallbackBundleID(ownerName: app.name), title: match.title),
                    pid: pid,
                    appName: app.name,
                    frame: window.bounds,
                    windowID: window.windowID,
                    ax: match.handle,
                    isHostedByMacOS: hosted
                ))
            } else if !hostPIDs.contains(window.pid) {
                let app = apps[window.pid]
                let name = app?.name ?? window.ownerName
                items.append(DiscoveredItem(
                    key: ItemKey(bundleID: app?.bundleID ?? fallbackBundleID(ownerName: name)),
                    pid: window.pid,
                    appName: name,
                    frame: window.bounds,
                    windowID: window.windowID
                ))
            } else {
                items.append(DiscoveredItem(
                    key: ItemKey(bundleID: DiscoveredItem.unknownBundleID),
                    pid: window.pid,
                    appName: "",
                    frame: window.bounds,
                    windowID: window.windowID,
                    isIdentified: false
                ))
            }
        }
        return items
    }

    /// The accessibility item whose centre lies inside the window, nearest to the window's own
    /// centre. An item from the owning app beats one from a host: Control Center exposes an
    /// untitled element over each Apple agent's item with exactly the window's frame, while the
    /// agent's own element carries the name.
    nonisolated static func closestAXItem(
        to window: StatusWindow,
        in axItems: [pid_t: [AXItem]],
        hostPIDs: Set<pid_t> = []
    ) -> (pid_t, AXItem)? {
        var best: (pid_t, AXItem)?
        var bestRank = MatchRank.worst
        for (pid, items) in axItems.sorted(by: { $0.key < $1.key }) {
            for item in items {
                let centre = item.frame.midX
                guard centre >= window.bounds.minX - 1, centre <= window.bounds.maxX + 1 else { continue }
                let rank = MatchRank(isHost: hostPIDs.contains(pid), distance: abs(centre - window.bounds.midX), isUntitled: item.title.isEmpty)
                if rank < bestRank {
                    bestRank = rank
                    best = (pid, item)
                }
            }
        }
        return best
    }

    /// True when a host (Control Center) exposes its own element over the window: the item is an
    /// Apple agent's that Control Center hosts and keeps on screen.
    nonisolated static func hostExposes(_ window: StatusWindow, in axItems: [pid_t: [AXItem]], hostPIDs: Set<pid_t>) -> Bool {
        hostPIDs.contains { pid in
            (axItems[pid] ?? []).contains { item in
                item.frame.midX >= window.bounds.minX - 1 && item.frame.midX <= window.bounds.maxX + 1
            }
        }
    }

    /// Lower is better: the owning app before a host, then the nearest centre, then a named item.
    private struct MatchRank: Comparable {
        var isHost: Bool
        var distance: CGFloat
        var isUntitled: Bool

        static let worst = MatchRank(isHost: true, distance: .infinity, isUntitled: true)

        static func < (lhs: MatchRank, rhs: MatchRank) -> Bool {
            (lhs.isHost ? 1 : 0, lhs.distance, lhs.isUntitled ? 1 : 0) < (rhs.isHost ? 1 : 0, rhs.distance, rhs.isUntitled ? 1 : 0)
        }
    }

    /// For processes without a bundle, such as helper tools.
    nonisolated static func fallbackBundleID(ownerName: String) -> String {
        let slug = ownerName.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        return "process." + (slug.isEmpty ? "unknown" : slug)
    }
}
