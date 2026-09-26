import Foundation
import Testing
@testable import SomabarCore

@Suite struct MenuBarStyleTests {
    @Test func plainByDefault() {
        let preferences = Preferences()
        #expect(preferences.menuBarStyle.isPlain)
        #expect(preferences.agentSocket == false)
    }

    @Test func olderFilesDecodeWithDefaults() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(preferences.menuBarStyle == MenuBarStyle())
        #expect(preferences.agentSocket == false)
        let partial = try JSONDecoder().decode(MenuBarStyle.self, from: Data(#"{"dark":{"hairline":true}}"#.utf8))
        #expect(partial.light.isPlain)
        #expect(partial.dark.hairline)
        #expect(partial.dark.tint == .none)
    }

    @Test func roundTrips() throws {
        var preferences = Preferences()
        preferences.agentSocket = true
        preferences.menuBarStyle.light = MenuBarStyle.Appearance(
            tint: .color, color: MenuBarStyle.RGB(red: 0.2, green: 0.4, blue: 0.6), strength: 0.5, hairline: true)
        preferences.menuBarStyle.dark.tint = .accent
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded == preferences)
        #expect(decoded.menuBarStyle.appearance(isDark: true).tint == .accent)
        #expect(decoded.menuBarStyle.appearance(isDark: false).hairline)
    }

    @Test func unknownTintReadsAsNone() throws {
        let style = try JSONDecoder().decode(MenuBarStyle.Appearance.self, from: Data(#"{"tint":"gradient","hairline":true}"#.utf8))
        #expect(style.tint == .none)
        #expect(style.hairline)
    }

    @Test func valuesAreClamped() {
        let rgb = MenuBarStyle.RGB(red: 2, green: -1, blue: .nan)
        #expect(rgb == MenuBarStyle.RGB(red: 1, green: 0, blue: 0))
        #expect(MenuBarStyle.Appearance(strength: 0).strength == 0.1)
        #expect(MenuBarStyle.Appearance(strength: 5).strength == 1)
    }
}
