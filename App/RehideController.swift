import AppKit
import BarEngine
import OSLog
import SomabarCore

/// Puts revealed items away again after a delay (M3). The timer waits while a menu hangs from
/// the bar or the pointer is on it, so items never vanish under either.
@MainActor
final class RehideController {
    static let pointerGraceSeconds: Double = 1.5
    /// While a menu is open the timer looks again this often. The menu watcher usually
    /// reschedules first, the moment the menu closes.
    static let menuPollSeconds: Double = 1

    var onFire: (@MainActor () -> Void)?
    /// Whether a menu hangs from the bar right now; the menu watcher answers.
    var isMenuOpen: @MainActor () -> Bool = { false }
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "app.somabar", category: "Rehide")

    var isScheduled: Bool { task != nil }

    func schedule(after seconds: Double) {
        cancel()
        task = Task { @MainActor [weak self] in
            var delay = seconds
            while true {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                switch RehidePolicy.whenTimerFires(menuOpen: self.isMenuOpen(), pointerOnBar: InputSafety.isPointerOnMenuBar()) {
                case .waitForMenu:
                    self.log.info("Rehide timer fired under an open menu; looking again in \(Self.menuPollSeconds) s")
                    delay = Self.menuPollSeconds
                case .waitForPointer:
                    self.log.info("Rehide timer fired with the pointer on the bar; looking again in \(Self.pointerGraceSeconds) s")
                    delay = Self.pointerGraceSeconds
                case .hide:
                    self.log.info("Rehide timer fired; hiding")
                    self.task = nil
                    self.onFire?()
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
