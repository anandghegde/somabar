import AppKit
import BarEngine
import os

/// "Show real item images": each item's own image, captured from its window, for the search
/// palette and the tray. Off, or without Screen Recording, it holds nothing and callers show
/// the app's icon (M18).
///
/// Images are refreshed after a scan of the bar when the set of item windows changed, or when
/// the last capture is more than `staleSeconds` old. There is no timer of its own.
@MainActor
final class ItemImageProvider {
    static let shared = ItemImageProvider()
    /// A scan after this long captures again even when no item came or went.
    static let staleSeconds: Double = 60

    private(set) var images: [CGWindowID: NSImage] = [:]
    private var capturedWindows: Set<CGWindowID> = []
    private var lastCapture: Date?
    private var task: Task<Void, Never>?
    /// Asked for while a capture was running; captured once it ends.
    private var pending: [CGWindowID: CGSize]?
    private let log = Logger(subsystem: "app.somabar", category: "icons")

    /// The captured image for the item's window, if any.
    func image(for windowID: CGWindowID?) -> NSImage? {
        windowID.flatMap { images[$0] }
    }

    /// After a scan. `isEnabled` is the preference; the permission is checked here.
    func update(items: [DiscoveredItem], isEnabled: Bool, force: Bool = false) {
        guard isEnabled, ScreenRecordingPermission.shared.isGranted else {
            clear()
            return
        }
        let windows = Dictionary(items.map { ($0.windowID, $0.frame.size) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(windows.keys)
        images = images.filter { ids.contains($0.key) }
        let isStale = lastCapture.map { Date().timeIntervalSince($0) > Self.staleSeconds } ?? true
        guard force || isStale || ids != capturedWindows else { return }
        capture(windows)
    }

    func clear() {
        task?.cancel()
        task = nil
        pending = nil
        images = [:]
        capturedWindows = []
        lastCapture = nil
    }

    private func capture(_ windows: [CGWindowID: CGSize]) {
        guard task == nil else {
            pending = windows
            return
        }
        capturedWindows = Set(windows.keys)
        lastCapture = Date()
        task = Task { @MainActor [weak self] in
            let captured = await WindowCapture.images(of: Set(windows.keys))
            guard let self, !Task.isCancelled else { return }
            var fresh: [CGWindowID: NSImage] = [:]
            for (windowID, image) in captured {
                // A blank capture is an off-screen window macOS did not draw: the app icon it is.
                guard let print = WindowCapture.fingerprint(of: image), !print.isBlank else { continue }
                let size = windows[windowID] ?? CGSize(width: image.width, height: image.height)
                fresh[windowID] = NSImage(cgImage: image, size: size)
            }
            self.images = fresh
            self.task = nil
            self.log.info("Captured \(fresh.count) of \(windows.count) item images")
            if let next = self.pending {
                self.pending = nil
                self.capture(next)
            }
        }
    }
}
