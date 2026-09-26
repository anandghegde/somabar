import Foundation
import Testing
@testable import SomabarCore

private let docker = ItemKey(bundleID: "com.docker.docker")
private let tailscale = ItemKey(bundleID: "io.tailscale.ipn.macos")
private let slack = ItemKey(bundleID: "com.tinyspeck.slackmacgap")

@Suite struct DocumentTests {
    @Test func defaultDocumentHasThreeProfilesAndDefaultHotkeys() {
        let document = SomabarDocument.makeDefault()
        #expect(document.profiles.map(\.name) == [Profile.everydayName, Profile.presentingName, Profile.focusName])
        #expect(document.active.name == Profile.everydayName)
        #expect(document.combo(for: .toggleHidden)?.display == "⌃⌥B")
        #expect(document.combo(for: .searchItems)?.display == "⌃⌥/")
        #expect(document.combo(for: .openTray)?.display == "⌃⌥↓")
        #expect(document.combo(for: .startTimer25) == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        var document = SomabarDocument.makeDefault(layout: Layout(shown: [docker], hidden: [tailscale]))
        document.triggers = [
            Trigger(name: "VPN on unknown Wi-Fi", condition: .allOf([.network(.wifi), .network(.unknownNetwork)]), action: .show(tailscale)),
            Trigger(condition: .timeOfDay(TimeRange(fromMinute: 19 * 60, toMinute: 7 * 60)), action: .hide(slack)),
            Trigger(condition: .not(.iconChanged(docker)), action: .switchProfile(name: "Focus")),
        ]
        document.aliases = [ItemAlias(item: tailscale, aliases: ["vpn"])]
        document.preferences.addKnownRouter("aa:bb:cc:dd:ee:ff")
        document.preferences.stillMode = true

        let data = try document.encoded()
        let decoded = try SomabarDocument.decode(data)
        #expect(decoded == document)
    }

    @Test func encodingIsStable() throws {
        let document = SomabarDocument.makeDefault(layout: Layout(shown: [docker, tailscale]))
        let first = try document.encoded()
        let second = try SomabarDocument.decode(first).encoded()
        #expect(first == second)
        let text = String(bytes: first, encoding: .utf8) ?? ""
        #expect(text.contains("\"activeProfile\" : \"Everyday\""))
        #expect(text.contains("com.docker.docker"))
    }

    @Test func rejectsNewerFormat() throws {
        var document = SomabarDocument.makeDefault()
        document.version = SomabarDocument.formatVersion + 1
        let data = try document.encoded()
        #expect(throws: DocumentError.newerFormat(version: SomabarDocument.formatVersion + 1)) {
            try SomabarDocument.decode(data)
        }
    }

    @Test func missingPreferenceKeysFallBackToDefaults() throws {
        let json = """
        {
          "version": 1,
          "activeProfile": "Everyday",
          "profiles": [
            { "id": "6B3A5C1E-1111-4C2B-9E1D-000000000001", "name": "Everyday",
              "layout": { "shown": [], "hidden": [], "tucked": [], "locked": [] },
              "newItemsGoTo": "shown",
              "notch": { "enabledActivities": ["timer", "somethingFromTheFuture"], "showsArtworkAndFileNames": true } }
          ],
          "triggers": [], "hotkeys": [], "aliases": [],
          "preferences": { "stillMode": true }
        }
        """
        let document = try SomabarDocument.decode(Data(json.utf8))
        #expect(document.preferences.stillMode == true)
        #expect(document.preferences.rehideAfterSeconds == 8)
        #expect(document.preferences.showDividers == true)
        #expect(document.active.notch.enabledActivities == [.timer], "Unknown activities are dropped, not fatal")
    }

    @Test func newItemsLandWhereEachProfileSays() {
        var document = SomabarDocument.makeDefault(layout: Layout(shown: [docker]))
        let added = document.insertNewItems([tailscale, docker])
        #expect(added == [tailscale])
        #expect(document.profile(named: Profile.everydayName)?.layout.shown == [docker, tailscale])
        #expect(document.profile(named: Profile.presentingName)?.layout.tucked == [docker, tailscale])
        #expect(document.profile(named: Profile.focusName)?.layout.hidden == [docker, tailscale])
    }

    @Test func forgetRemovesEverywhere() {
        var document = SomabarDocument.makeDefault(layout: Layout(shown: [docker, tailscale]))
        document.aliases = [ItemAlias(item: docker, aliases: ["whale"])]
        document.triggers = [
            Trigger(condition: .screenSharing, action: .hide(docker)),
            Trigger(condition: .screenSharing, action: .switchProfile(name: "Focus")),
        ]
        document.forget(docker)
        #expect(document.profiles.allSatisfy { !$0.layout.contains(docker) })
        #expect(document.aliases.isEmpty)
        #expect(document.triggers.count == 1)
    }

    @Test func forgettingAnAppClearsEveryProfileAndTheNotchGuard() {
        let glyph = ItemKey(bundleID: "app.somabar.Somabar", title: "Hide items")
        let divider = ItemKey(bundleID: "app.somabar.Somabar", ordinal: 1)
        var document = SomabarDocument.makeDefault(layout: Layout(shown: [docker, glyph], hidden: [divider]))
        document.profiles[0].notchGuarded = [GuardedItem(key: glyph, width: 38)]
        #expect(document.forgetItems(ofApp: "app.somabar.Somabar") == 2)
        #expect(document.profiles.allSatisfy { $0.layout.allItems == [docker] })
        #expect(document.profiles.allSatisfy { $0.notchGuarded.isEmpty })
        #expect(document.forgetItems(ofApp: "app.somabar.Somabar") == 0)
    }

    @Test func nextProfileWraps() {
        var document = SomabarDocument.makeDefault()
        #expect(document.nextProfileName == Profile.presentingName)
        document.activeProfile = Profile.focusName
        #expect(document.nextProfileName == Profile.everydayName)
    }
}

@Suite struct DocumentStoreTests {
    private func makeStore() throws -> DocumentStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SomabarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return DocumentStore(directory: directory)
    }

    @Test func loadReturnsNilBeforeFirstSave() throws {
        let store = try makeStore()
        #expect(try store.load() == nil)
    }

    @Test func saveThenLoad() throws {
        let store = try makeStore()
        let document = SomabarDocument.makeDefault(layout: Layout(shown: [docker]))
        try store.save(document, reason: "test")
        #expect(try store.load() == document)
        #expect(try store.history().isEmpty, "The first save has nothing to push into history")
    }

    @Test func changedSavesPushThePreviousVersionIntoHistory() throws {
        let store = try makeStore()
        var document = SomabarDocument.makeDefault(layout: Layout(shown: [docker]))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(document, reason: "first", now: start)
        try store.save(document, reason: "unchanged", now: start.addingTimeInterval(1))
        #expect(try store.history().isEmpty, "Saving an identical document adds no history")

        document.active.layout.move(docker, to: .hidden)
        try store.save(document, reason: "moved docker", now: start.addingTimeInterval(2))
        let history = try store.history()
        #expect(history.count == 1)
        #expect(history.first?.reason == "moved docker")
        #expect(history.first?.document.active.layout.shown == [docker], "History holds the version before the change")
    }

    @Test func historyKeepsTheNewestTwenty() throws {
        let store = try makeStore()
        var document = SomabarDocument.makeDefault()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<25 {
            document.preferences.rehideAfterSeconds = Double(index)
            try store.save(document, reason: "change \(index)", now: start.addingTimeInterval(Double(index)))
        }
        let history = try store.history()
        #expect(history.count == DocumentStore.historyLimit)
        #expect(history.first?.reason == "change 24")
        #expect(history.last?.reason == "change 5")
    }
}
