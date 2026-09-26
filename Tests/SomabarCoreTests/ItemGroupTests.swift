import Foundation
import Testing
@testable import SomabarCore

private let docker = ItemKey(bundleID: "com.docker.docker")
private let tailscale = ItemKey(bundleID: "io.tailscale.ipn.macos")
private let github = ItemKey(bundleID: "com.github.GitHubClient")
private let slack = ItemKey(bundleID: "com.tinyspeck.slackmacgap")
private let dropbox = ItemKey(bundleID: "com.getdropbox.dropbox")

private func document(_ layout: Layout) -> SomabarDocument {
    SomabarDocument.makeDefault(layout: layout)
}

@Suite struct ItemGroupModelTests {
    @Test func olderFilesWithoutGroupsOrItemHotKeysLoad() throws {
        let original = SomabarDocument.makeDefault()
        var json = try #require(try JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
        json.removeValue(forKey: "groups")
        json.removeValue(forKey: "itemHotKeys")
        let decoded = try SomabarDocument.decode(JSONSerialization.data(withJSONObject: json))
        #expect(decoded.groups.isEmpty)
        #expect(decoded.itemHotKeys.isEmpty)
        #expect(decoded.profiles == original.profiles)
    }

    @Test func groupsAndItemHotKeysRoundTrip() throws {
        var doc = document(Layout(shown: [docker, tailscale]))
        let id = doc.addGroup(baseName: "Dev")
        try doc.setGroupMembers(id, [docker, tailscale])
        try doc.setGroupGlyph(id, to: "hammer")
        doc.setCombo(KeyCombo(key: "d", modifiers: [.control, .option]), for: .item(docker))
        doc.setCombo(KeyCombo(key: "g", modifiers: [.control, .option]), for: .group(id))
        doc.triggers = [Trigger(condition: .screenSharing, action: .hideGroup(id))]
        let decoded = try SomabarDocument.decode(doc.encoded())
        #expect(decoded == doc)
    }

    @Test func itemHotKeyIsStoredFlat() throws {
        let hotKey = ItemHotKey(target: .item(docker), combo: KeyCombo(key: "d", modifiers: [.option, .control]))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(hotKey)) as? [String: Any])
        #expect(json["group"] == nil)
        #expect((json["item"] as? [String: Any])?["bundleID"] as? String == docker.bundleID)
        #expect((json["combo"] as? [String: Any])?["key"] as? String == "d")
    }

    @Test func groupGlyphFace() {
        #expect(ItemGroup(name: "dev").face == .letter("D"))
        #expect(ItemGroup(name: "Dev", glyph: "x").face == .letter("X"))
        #expect(ItemGroup(name: "Dev", glyph: "hammer.fill").face == .symbol("hammer.fill"))
        #expect(ItemGroup(name: "").face == .letter("G"))
    }

    @Test func addingGroupsPicksFreeNames() {
        var doc = document(Layout())
        doc.addGroup()
        doc.addGroup()
        #expect(doc.groups.map(\.name) == ["New Group", "New Group 2"])
    }

    @Test func renameRefusesEmptyAndTakenNames() throws {
        var doc = document(Layout())
        let first = doc.addGroup(baseName: "Dev")
        doc.addGroup(baseName: "Chat")
        #expect(throws: GroupEditError.nameTaken) { try doc.renameGroup(first, to: "Chat") }
        #expect(throws: GroupEditError.emptyName) { try doc.renameGroup(first, to: "  ") }
        try doc.renameGroup(first, to: " Tools ")
        #expect(doc.group(id: first)?.name == "Tools")
    }

    @Test func atMostEightMembers() throws {
        var doc = document(Layout())
        let id = doc.addGroup()
        let nine = (0..<9).map { ItemKey(bundleID: "app.\($0)") }
        #expect(throws: GroupEditError.tooManyMembers) { try doc.setGroupMembers(id, nine) }
        try doc.setGroupMembers(id, Array(nine.prefix(8)))
        #expect(doc.group(id: id)?.members.count == 8)
    }

    @Test func anItemJoinsOneGroupOnly() throws {
        var doc = document(Layout(shown: [docker, tailscale, slack]))
        let dev = doc.addGroup(baseName: "Dev")
        let chat = doc.addGroup(baseName: "Chat")
        try doc.setGroupMembers(dev, [docker, tailscale])
        try doc.setGroupMembers(chat, [slack, docker])
        #expect(doc.group(id: dev)?.members == [tailscale])
        #expect(doc.group(containing: docker)?.id == chat)
    }

    @Test func settingMembersGathersThemInEveryProfile() throws {
        var doc = document(Layout(shown: [slack, docker], hidden: [tailscale], tucked: [github]))
        let id = doc.addGroup()
        try doc.setGroupMembers(id, [tailscale, docker, github])
        for profile in doc.profiles {
            let sections = Set([tailscale, docker, github].compactMap { profile.layout.section(of: $0) })
            #expect(sections.count == 1, "\(profile.name) keeps the group in one section")
        }
        #expect(doc.active.layout.hidden == [tailscale, docker, github])
        #expect(doc.active.layout.shown == [slack])
    }

    @Test func movingAGroupMovesEveryMemberInTheActiveProfile() throws {
        var doc = document(Layout(shown: [slack, docker, tailscale]))
        let id = doc.addGroup()
        try doc.setGroupMembers(id, [docker, tailscale])
        try doc.moveGroup(id, to: .tucked)
        #expect(doc.active.layout.tucked == [docker, tailscale])
        #expect(doc.section(ofGroup: id) == .tucked)
        #expect(doc.profile(named: Profile.focusName)?.layout.section(of: docker) == .hidden, "Other profiles keep their own layout")
    }

    @Test func removingAGroupDropsItsTriggersAndHotKey() throws {
        var doc = document(Layout(shown: [docker]))
        let id = doc.addGroup()
        try doc.setGroupMembers(id, [docker])
        doc.triggers = [
            Trigger(condition: .screenSharing, action: .showGroup(id)),
            Trigger(condition: .screenSharing, action: .show(docker)),
        ]
        doc.setCombo(KeyCombo(key: "g", modifiers: [.command, .option]), for: .group(id))
        doc.removeGroup(id)
        #expect(doc.groups.isEmpty)
        #expect(doc.triggers.map(\.action) == [.show(docker)])
        #expect(doc.itemHotKeys.isEmpty)
        #expect(doc.active.layout.shown == [docker], "Members stay where they are")
    }

    @Test func forgettingAnItemLeavesItsGroupAndHotKey() throws {
        var doc = document(Layout(shown: [docker, tailscale]))
        let id = doc.addGroup()
        try doc.setGroupMembers(id, [docker, tailscale])
        doc.setCombo(KeyCombo(key: "d", modifiers: [.command, .option]), for: .item(docker))
        doc.forget(docker)
        #expect(doc.group(id: id)?.members == [tailscale])
        #expect(doc.itemHotKeys.isEmpty)
    }
}

@Suite struct GroupLayoutTests {
    @Test func gatherKeepsTheAnchorAndPutsTheRestBesideIt() {
        var layout = Layout(shown: [slack, docker, dropbox], hidden: [tailscale, github])
        layout.gather([docker, github, tailscale], into: nil)
        #expect(layout.shown == [slack, docker, github, tailscale, dropbox])
        #expect(layout.hidden.isEmpty)
    }

    @Test func gatherSkipsItemsTheLayoutDoesNotKnow() {
        var layout = Layout(hidden: [tailscale])
        layout.gather([docker, tailscale, github], into: .tucked)
        #expect(layout.tucked == [tailscale])
        #expect(!layout.contains(docker))
    }

    @Test func aMovedMemberPullsTheRestOfItsGroup() {
        let group = ItemGroup(name: "Dev", members: [docker, tailscale, github])
        // The person dragged Tailscale from Hidden to Shown.
        var layout = Layout(shown: [slack, tailscale], hidden: [docker, github, dropbox])
        let followed = layout.keepGroupsTogether([group], moved: [tailscale])
        #expect(Set(followed) == [docker, github])
        #expect(layout.shown == [slack, tailscale, docker, github])
        #expect(layout.hidden == [dropbox])
    }

    @Test func itemsOutsideGroupsMoveAlone() {
        let group = ItemGroup(name: "Dev", members: [docker, tailscale])
        var layout = Layout(shown: [slack], hidden: [docker, tailscale])
        let followed = layout.keepGroupsTogether([group], moved: [slack])
        #expect(followed.isEmpty)
        #expect(layout == Layout(shown: [slack], hidden: [docker, tailscale]))
    }

    @Test func groupTriggersActOnEveryMember() {
        let group = ItemGroup(name: "Dev", members: [docker, tailscale])
        var context = ContextSnapshot()
        context.isScreenShared = true
        let triggers = [
            Trigger(condition: .screenSharing, action: .hideGroup(group.id)),
            Trigger(condition: .screenSharing, action: .show(tailscale)),
        ]
        let effects = TriggerEvaluator().effects(of: triggers, in: context, groups: [group])
        #expect(effects.hide == [docker])
        #expect(effects.show == [tailscale], "Show still beats hide for one member")
    }

    @Test func groupTriggerSummaryNamesTheGroup() {
        let group = ItemGroup(name: "Dev")
        #expect(TriggerAction.showGroup(group.id).summary(groups: [group]) == "show group Dev")
        #expect(TriggerAction.hideGroup(UUID()).summary == "hide group (removed)")
    }
}

@Suite struct ItemHotKeyClashTests {
    private let optD = KeyCombo(key: "d", modifiers: [.control, .option])

    @Test func itemHotKeyCannotTakeAnActionsCombo() {
        var doc = document(Layout(shown: [docker]))
        let clash = doc.setCombo(KeyCombo(key: "b", modifiers: [.control, .option]), for: .item(docker))
        #expect(clash == .action(.toggleHidden))
        #expect(doc.itemHotKeys.isEmpty)
    }

    @Test func actionCannotTakeAnItemsCombo() {
        var doc = document(Layout(shown: [docker]))
        doc.setCombo(optD, for: .item(docker))
        let clash = doc.setCombo(optD, for: .startTimer25)
        #expect(clash == .item(doc.label(for: .item(docker))))
        #expect(doc.combo(for: .startTimer25) == nil)
    }

    @Test func twoItemsCannotShareACombo() throws {
        var doc = document(Layout(shown: [docker, tailscale]))
        let id = doc.addGroup(baseName: "Dev")
        doc.setCombo(optD, for: .group(id))
        #expect(doc.setCombo(optD, for: .item(tailscale)) == .item("Group “Dev”"))
        #expect(doc.combo(for: .item(tailscale)) == nil)
    }

    @Test func systemShortcutsAreRefused() {
        var doc = document(Layout())
        let clash = doc.setCombo(KeyCombo(key: "space", modifiers: [.command]), for: .item(docker))
        #expect(clash == .system("Spotlight"))
    }

    @Test func reassigningTheSameComboToItsOwnerIsFine() {
        var doc = document(Layout())
        doc.setCombo(optD, for: .item(docker))
        #expect(doc.setCombo(optD, for: .item(docker)) == nil)
        #expect(doc.itemHotKeys.count == 1)
    }

    @Test func clearingKeepsTheRowAndRemovingDropsIt() {
        var doc = document(Layout())
        doc.addItemHotKey(for: .item(docker))
        doc.addItemHotKey(for: .item(docker))
        #expect(doc.itemHotKeys == [ItemHotKey(target: .item(docker), combo: nil)])
        doc.setCombo(optD, for: .item(docker))
        doc.setCombo(nil, for: .item(docker))
        #expect(doc.itemHotKeys.count == 1)
        #expect(doc.combo(for: .item(docker)) == nil)
        doc.removeItemHotKey(for: .item(docker))
        #expect(doc.itemHotKeys.isEmpty)
    }

    @Test func unassignedRowsNeverClash() {
        var doc = document(Layout())
        doc.addItemHotKey(for: .item(docker))
        #expect(doc.setCombo(optD, for: .item(tailscale)) == nil)
    }
}

@Suite struct GroupArrivalTests {
    @Test func aNewMemberJoinsItsGroupsSection() throws {
        var doc = document(Layout(shown: [slack], tucked: [docker]))
        let id = doc.addGroup()
        try doc.setGroupMembers(id, [docker, tailscale])
        let arrivals = doc.insertNewItems([tailscale, dropbox])
        #expect(arrivals == [tailscale, dropbox])
        #expect(doc.active.layout.tucked == [docker, tailscale])
        #expect(doc.active.layout.shown == [slack, dropbox], "Items outside groups go where newItemsGoTo says")
    }
}
