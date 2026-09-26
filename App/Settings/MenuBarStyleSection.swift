import AppKit
import SomabarCore
import SwiftUI

/// Settings › General › Menu bar style (M13): a tint and a hairline, set apart for light and
/// dark mode. Off by default.
struct MenuBarStyleSection: View {
    @Binding var style: MenuBarStyle

    var body: some View {
        SwiftUI.Section {
            MenuBarAppearanceEditor(title: "Light mode", appearance: $style.light)
            MenuBarAppearanceEditor(title: "Dark mode", appearance: $style.dark)
        } header: {
            Text("Menu bar style")
        } footer: {
            Text("Drawn behind the menu bar, which is see-through on macOS 26. Not shown when the menu bar hides itself.")
                .foregroundStyle(.secondary)
        }
    }
}

/// The tint, its colour and strength, and the hairline for one appearance.
private struct MenuBarAppearanceEditor: View {
    let title: String
    @Binding var appearance: MenuBarStyle.Appearance

    var body: some View {
        Picker("\(title) tint", selection: $appearance.tint) {
            Text("None").tag(MenuBarStyle.Tint.none)
            Text("System accent").tag(MenuBarStyle.Tint.accent)
            Text("Colour").tag(MenuBarStyle.Tint.color)
        }
        if appearance.tint == .color {
            ColorPicker("\(title) colour", selection: color, supportsOpacity: false)
        }
        if appearance.tint != .none {
            LabeledContent("\(title) strength") {
                HStack {
                    Slider(value: $appearance.strength, in: MenuBarStyle.Appearance.strengthRange)
                        .accessibilityValue("\(Int((appearance.strength * 100).rounded())) percent")
                    Text("\(Int((appearance.strength * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
        Toggle("\(title) hairline border", isOn: $appearance.hairline)
    }

    /// The preference keeps plain sRGB numbers; the picker wants a Color.
    private var color: Binding<Color> {
        Binding(
            get: {
                Color(.sRGB, red: appearance.color.red, green: appearance.color.green, blue: appearance.color.blue)
            },
            set: { newValue in
                guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                appearance.color = MenuBarStyle.RGB(
                    red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
            }
        )
    }
}
