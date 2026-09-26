import AppIntents
import Foundation

/// A Focus Filter. In System Settings › Focus, a Focus can be given a "Somabar" filter with a
/// name; while that Focus is on, `Condition.focus(name:)` with the same name holds.
///
/// macOS runs `perform` when a Focus with the filter turns on, and again with no name when it
/// turns off. The result is posted as a notification the `ContextMonitor` observes.
struct SomabarFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Somabar's Focus"
    static let description: IntentDescription? = IntentDescription(
        "Tells Somabar which Focus is on, so its triggers can react to it.")

    static let didChangeNotification = Notification.Name("app.somabar.focusChanged")
    static let focusNameKey = "focus"

    @Parameter(title: "Focus name", description: "The name Somabar's triggers look for, such as Work.")
    var focusName: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Somabar", subtitle: LocalizedStringResource(stringLiteral: focusName ?? "No Focus"))
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        var info: [AnyHashable: Any] = [:]
        if let focusName, !focusName.isEmpty {
            info[Self.focusNameKey] = focusName
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil, userInfo: info)
        return .result()
    }
}
