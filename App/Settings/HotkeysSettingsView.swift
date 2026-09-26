import SomabarCore
import SwiftUI

/// One recorder per action. A combo that clashes is shown with the reason and not saved.
struct HotkeysSettingsView: View {
    @Bindable var model: SettingsModel
    /// The last refused combo per action, shown until the next attempt.
    @State private var clashes: [HotkeyAction: String] = [:]

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    row(for: action)
                }
            } footer: {
                Text("Click a shortcut, then press the new combination. ⌫ clears it, ⎋ cancels. Shortcuts need ⌃, ⌥ or ⌘.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(for action: HotkeyAction) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                KeyRecorder(
                    combo: model.document.combo(for: action),
                    onRecord: { result in record(result, for: action) },
                    onRecordingChanged: { model.setRecording($0) }
                )
                .frame(width: 150, height: 24)
                if let clash = clashes[action] {
                    Label(clash, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } label: {
            Text(action.displayName)
        }
    }

    private func record(_ result: KeyRecorderResult, for action: HotkeyAction) {
        switch result {
        case .combo(let combo):
            if let clash = model.setCombo(combo, for: action) {
                clashes[action] = "\(combo.display): \(clash.message)"
            } else {
                clashes[action] = nil
            }
        case .cleared:
            _ = model.setCombo(nil, for: action)
            clashes[action] = nil
        case .unsupported(let reason):
            clashes[action] = reason
        }
    }
}
