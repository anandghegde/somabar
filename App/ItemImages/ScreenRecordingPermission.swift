import AppKit
import CoreGraphics
import Observation
import os

/// Screen Recording, which Somabar asks for only when "Show real item images" or an
/// icon-change trigger is turned on (M18). Core use never needs it, so nothing else here or
/// elsewhere may call `CGRequestScreenCaptureAccess`.
///
/// The state is read again when Somabar becomes active and when Settings appears; there is no
/// polling. macOS may keep reporting the old answer until Somabar relaunches.
@Observable
@MainActor
final class ScreenRecordingPermission {
    static let shared = ScreenRecordingPermission()
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    /// Set once Somabar has asked on behalf of an icon-change trigger, so it asks only once.
    static let askedForTriggersKey = "didAskScreenRecordingForTriggers"

    private(set) var isGranted = CGPreflightScreenCaptureAccess()
    /// Called when `isGranted` changes, for the item images and the icon detector.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let log = Logger(subsystem: "app.somabar", category: "icons")

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenRecordingPermission.shared.refresh() }
        }
    }

    /// True once Somabar has asked for an icon-change trigger.
    var askedForTriggers: Bool {
        UserDefaults.standard.bool(forKey: Self.askedForTriggersKey)
    }

    /// Reads the permission again.
    func refresh() {
        let now = CGPreflightScreenCaptureAccess()
        guard now != isGranted else { return }
        isGranted = now
        log.notice("Screen Recording is \(now ? "granted" : "off", privacy: .public)")
        onChange?()
    }

    /// Asks macOS, which shows its prompt the first time and answers from memory after that.
    /// Only for "Show real item images" being turned on.
    func request() {
        refresh()
        guard !isGranted else { return }
        log.notice("Asking for Screen Recording")
        let granted = CGRequestScreenCaptureAccess()
        if granted != isGranted {
            isGranted = granted
            onChange?()
        }
    }

    /// Asks once, ever, for an icon-change trigger that was saved or turned on.
    func requestOnceForTriggers() {
        refresh()
        guard !isGranted, !askedForTriggers else { return }
        UserDefaults.standard.set(true, forKey: Self.askedForTriggersKey)
        request()
    }

    func openSystemSettings() {
        guard let url = Self.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
