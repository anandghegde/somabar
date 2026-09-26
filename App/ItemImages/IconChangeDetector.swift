import AppKit
import BarEngine
import os
import SomabarCore

/// The icon-change condition's eyes. On each pass of the status-window watcher (every 3 s, the
/// one poll Somabar has), and only when an enabled trigger watches an item and Screen Recording
/// is granted, it captures the watched items' windows and compares each with the last capture.
/// A different fingerprint reports the item as changed.
@MainActor
final class IconChangeDetector {
    static let shared = IconChangeDetector()

    private var fingerprints: [ItemKey: IconFingerprint] = [:]
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "app.somabar", category: "icons")

    /// One pass. `watched` comes from the enabled triggers; `onChange` gets the items whose icon
    /// changed since the last pass, never an empty set.
    func check(watched: Set<ItemKey>, items: [DiscoveredItem], onChange: @escaping @MainActor (Set<ItemKey>) -> Void) {
        guard !watched.isEmpty, ScreenRecordingPermission.shared.isGranted else {
            reset()
            return
        }
        // The last pass is still capturing; this one is skipped rather than queued.
        guard task == nil else { return }
        fingerprints = fingerprints.filter { watched.contains($0.key) }
        var windows: [CGWindowID: ItemKey] = [:]
        for item in items where watched.contains(item.key) && !windows.values.contains(item.key) {
            windows[item.windowID] = item.key
        }
        guard !windows.isEmpty else { return }
        task = Task { @MainActor [weak self] in
            let images = await WindowCapture.images(of: Set(windows.keys))
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            var changed: Set<ItemKey> = []
            for (windowID, image) in images {
                guard let key = windows[windowID], let print = WindowCapture.fingerprint(of: image), !print.isBlank else { continue }
                if let previous = self.fingerprints[key], print.differs(from: previous) {
                    changed.insert(key)
                    self.log.notice("Icon changed: \(key.description, privacy: .public) (\(print.changedPixels(from: previous)) pixels)")
                }
                self.fingerprints[key] = print
            }
            if !changed.isEmpty {
                onChange(changed)
            }
        }
    }

    /// Forgets every capture, so the next pass starts a fresh baseline instead of firing.
    func reset() {
        task?.cancel()
        task = nil
        fingerprints = [:]
    }
}
