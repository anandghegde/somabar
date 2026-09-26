import SomabarCore
import SwiftUI

/// Reveal gestures, auto-rehide, Still Mode, dividers and spacing.
struct GeneralSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            SwiftUI.Section("Reveal hidden items") {
                Toggle("Click on the empty menu bar", isOn: $model.preferences.revealGestures.clickEmptyBar)
                Toggle("Scroll down on the menu bar", isOn: $model.preferences.revealGestures.scrollDownOnBar)
                Toggle("Hover over the empty menu bar", isOn: $model.preferences.revealGestures.hoverEmptyBar)
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: hoverDelay, in: 0...800, step: 50)
                        Text("\(model.preferences.revealGestures.hoverDelayMilliseconds) ms")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                .disabled(!model.preferences.revealGestures.hoverEmptyBar)
            }
            SwiftUI.Section {
                LabeledContent("Hide again after") {
                    HStack {
                        Slider(value: $model.preferences.rehideAfterSeconds, in: 0...60, step: 1)
                        Text(model.preferences.rehideAfterSeconds == 0 ? "Off" : "\(Int(model.preferences.rehideAfterSeconds)) s")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Toggle("Hide when a menu closes", isOn: $model.preferences.rehideWhenMenuCloses)
                Toggle("Hide when the front app changes", isOn: $model.preferences.rehideWhenAppChanges)
                Toggle("Still Mode", isOn: $model.preferences.stillMode)
            } header: {
                Text("Hiding again")
            } footer: {
                Text("Still Mode never hides the bar on its own and turns off springs and wobble. "
                    + "“Hide when a menu closes” only shortens an auto-hide that is on.")
                    .foregroundStyle(.secondary)
            }
            SwiftUI.Section("Menu bar") {
                Toggle("Show dividers", isOn: $model.preferences.showDividers)
                Picker("Spacing", selection: $model.preferences.spacing) {
                    Text("Default").tag(Spacing.default)
                    Text("Snug").tag(Spacing.snug)
                    Text("Tight").tag(Spacing.tight)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The preference is whole milliseconds; the slider wants a Double.
    private var hoverDelay: Binding<Double> {
        Binding(
            get: { Double(model.preferences.revealGestures.hoverDelayMilliseconds) },
            set: { model.preferences.revealGestures.hoverDelayMilliseconds = Int($0.rounded()) }
        )
    }
}
