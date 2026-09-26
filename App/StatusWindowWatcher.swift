import BarEngine
import CoreGraphics
import Foundation
import OSLog

/// Notices status items coming and going without an app-launch notification (M18). An app can
/// add its item long after it launched, and an agent launchd starts posts no notification at
/// all, so the window list is read every few seconds; that costs well under a millisecond.
@MainActor
final class StatusWindowWatcher {
    static let pollSeconds: Double = 3

    var onChange: (@MainActor () -> Void)?
    /// Called on every pass, changed or not: the icon-change detector rides this poll rather
    /// than adding its own.
    var onPass: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?
    private var known: Set<CGWindowID>?
    private let log = Logger(subsystem: "app.somabar", category: "Items")

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            // The first look waits too, so Somabar's own windows, still appearing, are not "new".
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
                guard !Task.isCancelled else { return }
                self.look()
                self.onPass?()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func look() {
        let now = Set(StatusWindows.all().map(\.windowID))
        defer { known = now }
        guard let known, known != now else { return }
        let arrived = now.subtracting(known).count
        let left = known.subtracting(now).count
        log.info("Status windows changed: \(arrived) new, \(left) gone")
        onChange?()
    }
}
