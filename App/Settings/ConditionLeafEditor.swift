import SomabarCore
import SwiftUI

/// One leaf condition: a kind picker and the fields that kind needs.
struct ConditionLeafEditor: View {
    @Binding var leaf: LeafConditionDraft
    var canRemove: Bool
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Condition", selection: $leaf.kind) {
                    ForEach(ConditionKind.allCases) { Text($0.displayName).tag($0) }
                }
                if canRemove {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this condition")
                }
            }
            fields
        }
    }

    @ViewBuilder private var fields: some View {
        switch leaf.kind {
        case .powerSource:
            Picker("Source", selection: $leaf.powerSource) {
                Text("Battery").tag(PowerSource.battery)
                Text("Power adapter").tag(PowerSource.adapter)
            }
        case .batteryBelow:
            Stepper("\(leaf.percent)%", value: $leaf.percent, in: 1...99, step: 5)
        case .network:
            Picker("Network", selection: $leaf.network) {
                ForEach(LeafConditionDraft.networks, id: \.self) { Text(NetworkText.name($0)).tag($0) }
            }
        case .display:
            Picker("Display", selection: $leaf.display) {
                Text("Built-in display only").tag(DisplayKind.builtInOnly)
                Text("External display connected").tag(DisplayKind.externalConnected)
                Text("A display wider than…").tag(DisplayKind.widerThan)
            }
            if leaf.display == .widerThan {
                TextField("Points", value: $leaf.points, format: .number)
            }
        case .screenSharing:
            Text("Read off the bar: macOS shows a Screen Sharing item while someone views the screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .mediaInUse:
            Picker("Device", selection: $leaf.media) {
                Text("Microphone").tag(MediaDevice.microphone)
                Text("Camera").tag(MediaDevice.camera)
                Text("Camera or microphone").tag(MediaDevice.either)
            }
        case .appRunning, .appFrontmost:
            TextField("Bundle ID", text: $leaf.bundleID, prompt: Text("com.docker.docker"))
        case .focus:
            TextField("Focus name", text: $leaf.name, prompt: Text("Work"))
        case .timeOfDay:
            DatePicker("From", selection: minuteBinding(\.fromMinute), displayedComponents: .hourAndMinute)
            DatePicker("Until", selection: minuteBinding(\.toMinute), displayedComponents: .hourAndMinute)
        case .external:
            TextField("Name", text: $leaf.name, prompt: Text("docker"))
            Text("Switched with open \"somabar://set?\(leaf.name.isEmpty ? "name" : leaf.name)=on\" and =off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Minutes since midnight as a time of day today, for the date picker.
    private func minuteBinding(_ path: WritableKeyPath<LeafConditionDraft, Int>) -> Binding<Date> {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        return Binding(
            get: { calendar.date(byAdding: .minute, value: leaf[keyPath: path], to: midnight) ?? midnight },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                leaf[keyPath: path] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
