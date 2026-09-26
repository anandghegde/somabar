import Foundation
import os
import UserNotifications

extension Notification.Name {
    /// Posted when a trigger starts holding or switches profile. `userInfo["names"]` is the
    /// `[String]` of trigger names. The notch listens for it to pulse.
    static let somabarTriggerFired = Notification.Name("app.somabar.triggerFired")
}

/// Delivers "Docker from a script is holding" as a system notification when the person asked
/// for it (`Preferences.notifyWhenTriggerFires`).
@MainActor
final class TriggerNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TriggerNotifier()

    private let log = Logger(subsystem: "app.somabar", category: "Triggers")
    private var didSetDelegate = false

    private var center: UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        if !didSetDelegate {
            didSetDelegate = true
            center.delegate = self
        }
        return center
    }

    /// Asks once; macOS remembers the answer. Returns true when notifications may be shown.
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            log.notice("Notification permission: \(granted ? "granted" : "denied", privacy: .public)")
            return granted
        } catch {
            log.error("Could not ask for notification permission: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// True when the person has turned Somabar's notifications off in System Settings.
    func isDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    func deliver(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Somabar"
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = center
        let log = log
        Task {
            do {
                try await center.add(request)
            } catch {
                log.error("Could not deliver a trigger notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Somabar is an agent app and may count as frontmost while its Settings window is open; show
    /// the banner anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
