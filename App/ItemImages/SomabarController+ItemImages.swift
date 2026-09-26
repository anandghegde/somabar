import AppKit
import BarEngine
import SomabarCore

/// Real item images and the icon-change condition, wired to the scan and the status-window
/// watcher. Both need Screen Recording and do nothing without it (M18).
extension SomabarController {
    func startItemImages() {
        statusWindows.onPass = { [weak self] in self?.checkIconChanges() }
        ScreenRecordingPermission.shared.onChange = { [weak self] in
            guard let self else { return }
            IconChangeDetector.shared.reset()
            refreshItemImages(force: true)
        }
    }

    /// After every scan, and when the preference or the permission changes.
    func refreshItemImages(force: Bool = false) {
        ItemImageProvider.shared.update(items: items, isEnabled: document.preferences.realItemImages, force: force)
    }

    /// The item's own image when "Show real item images" has one, else its app's icon.
    func itemImage(windowID: CGWindowID?, bundleID: String, pid: pid_t?) -> NSImage {
        ItemImageProvider.shared.image(for: windowID) ?? ItemIcons.icon(bundleID: bundleID, pid: pid)
    }

    /// One pass of the icon-change detector, from the status-window watcher's poll.
    private func checkIconChanges() {
        let watched = document.watchedIcons
        guard !watched.isEmpty else {
            IconChangeDetector.shared.reset()
            return
        }
        // A menu open on the bar highlights its item, and a reconcile drags items about: neither
        // is the icon changing.
        guard !reconciler.isRunning, !MenuWatcher.anyMenuOpen() else { return }
        IconChangeDetector.shared.check(watched: watched, items: items) { [weak self] changed in
            self?.context.setChangedIcons(changed)
        }
    }
}
