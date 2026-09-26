import Foundation
import Testing
@testable import SomabarCore

private let docker = ItemKey(bundleID: "com.docker.docker")
private let tailscale = ItemKey(bundleID: "io.tailscale.ipn.macos")
private let github = ItemKey(bundleID: "com.github.GitHubClient")
private let slack = ItemKey(bundleID: "com.tinyspeck.slackmacgap")
private let dropbox = ItemKey(bundleID: "com.getdropbox.dropbox")

@Suite struct GroupedItemsTests {
    @Test func noGroupsListsEverythingUngrouped() {
        let listing = GroupedItems(keys: [docker, slack], groups: [])
        #expect(listing.blocks.isEmpty)
        #expect(listing.ungrouped == [docker, slack])
    }

    @Test func blocksFollowTheirLeftmostMemberAndKeepLayoutOrder() {
        let dev = ItemGroup(name: "Dev", members: [github, docker])
        let chat = ItemGroup(name: "Chat", members: [slack])
        let listing = GroupedItems(keys: [slack, dropbox, docker, tailscale, github], groups: [dev, chat])
        #expect(listing.blocks.map(\.group.name) == ["Chat", "Dev"])
        #expect(listing.blocks.map(\.members) == [[slack], [docker, github]])
        #expect(listing.ungrouped == [dropbox, tailscale])
    }

    @Test func groupsWithNoMemberInTheSectionAreLeftOut() {
        let dev = ItemGroup(name: "Dev", members: [docker])
        let empty = ItemGroup(name: "Empty")
        let listing = GroupedItems(keys: [slack], groups: [dev, empty])
        #expect(listing.blocks.isEmpty)
        #expect(listing.ungrouped == [slack])
    }

    @Test func assigningJoinsTheGroupsSectionAndLeavesTheOldGroup() throws {
        var doc = SomabarDocument.makeDefault(layout: Layout(shown: [slack], hidden: [docker, tailscale]))
        let dev = doc.addGroup(baseName: "Dev")
        let chat = doc.addGroup(baseName: "Chat")
        try doc.setGroupMembers(dev, [docker, tailscale])
        try doc.setGroupMembers(chat, [slack])
        try doc.assign(slack, toGroup: dev)
        #expect(doc.group(id: dev)?.members == [docker, tailscale, slack])
        #expect(doc.group(id: chat)?.members == [])
        #expect(doc.active.layout.hidden == [docker, tailscale, slack])
        #expect(doc.active.layout.shown.isEmpty)
    }

    @Test func assigningAMemberAgainChangesNothing() throws {
        var doc = SomabarDocument.makeDefault(layout: Layout(shown: [docker, slack]))
        let dev = doc.addGroup(baseName: "Dev")
        try doc.setGroupMembers(dev, [docker])
        let before = doc
        try doc.assign(docker, toGroup: dev)
        #expect(doc == before)
    }

    @Test func assigningToAFullOrMissingGroupThrows() throws {
        let keys = (0..<ItemGroup.maxMembers).map { ItemKey(bundleID: "app.\($0)") }
        var doc = SomabarDocument.makeDefault(layout: Layout(shown: keys + [slack]))
        let full = doc.addGroup(baseName: "Full")
        try doc.setGroupMembers(full, keys)
        #expect(throws: GroupEditError.tooManyMembers) { try doc.assign(slack, toGroup: full) }
        #expect(throws: GroupEditError.noSuchGroup) { try doc.assign(slack, toGroup: UUID()) }
        #expect(doc.group(id: full)?.members == keys)
    }

    @Test func removingFromAGroupLeavesTheItemWhereItIs() throws {
        var doc = SomabarDocument.makeDefault(layout: Layout(shown: [slack], hidden: [docker, tailscale]))
        let dev = doc.addGroup(baseName: "Dev")
        try doc.setGroupMembers(dev, [docker, tailscale])
        doc.removeFromGroup(docker)
        #expect(doc.group(id: dev)?.members == [tailscale])
        #expect(doc.active.layout.hidden == [docker, tailscale])
        doc.removeFromGroup(slack)
        #expect(doc.group(id: dev)?.members == [tailscale])
    }
}
