import SwiftUI

/// One line saying Screen Recording is off, with a button to its pane in System Settings. Shown
/// under "Show real item images" and under an icon-change condition while the permission is
/// missing.
struct ScreenRecordingNote: View {
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(text, systemImage: "rectangle.dashed.badge.record")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open System Settings") { ScreenRecordingPermission.shared.openSystemSettings() }
                .controlSize(.small)
        }
    }
}
