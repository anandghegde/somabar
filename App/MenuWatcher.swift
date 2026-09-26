import AppKit
import BarEngine
import OSLog

/// Watches the window list for menus hanging from the menu bar while items are revealed (M3).
/// A status item's menu, an app menu and Somabar's own menu all show up the same way, and none
/// of them needs a permission to see.
@MainActor
final class MenuWatcher {
    static let pollSeconds: Double = 0.2

    var onMenuClosed: (@MainActor () -> Void)?
    private(set) var isMenuOpen = false
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "app.somabar", category: "Menus")

    var isWatching: Bool { task != nil }

    /// Every screen's menu bar strip, global top-left coordinates.
    static func bars() -> [CGRect] {
        NSScreen.screens.map(ScreenGeometry.menuBarRect(of:))
    }

    /// One look at the bar right now.
    static func anyMenuOpen() -> Bool {
        !MenuWindows.open(hangingFrom: bars()).isEmpty
    }

    func start() {
        guard task == nil else { return }
        isMenuOpen = Self.anyMenuOpen()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
                guard !Task.isCancelled, let self else { return }
                let open = Self.anyMenuOpen()
                let closed = self.isMenuOpen && !open
                if open != self.isMenuOpen {
                    self.log.info("A menu \(open ? "opened" : "closed", privacy: .public) on the bar")
                }
                self.isMenuOpen = open
                if closed {
                    self.onMenuClosed?()
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isMenuOpen = false
    }
}
