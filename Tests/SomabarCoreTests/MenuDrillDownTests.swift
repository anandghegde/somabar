import Testing
@testable import SomabarCore

@Suite struct MenuDrillDownTests {
    /// A CleanShot-like menu. Paths skip the separators the reader dropped.
    private let menu: [MenuEntry] = [
        MenuEntry(path: [0], title: "Capture Area", shortcut: MenuShortcut(key: "4", shift: true)),
        MenuEntry(path: [1], title: "Record Screen"),
        MenuEntry(path: [3], title: "Export", children: [
            MenuEntry(path: [3, 0], title: "PNG"),
            MenuEntry(path: [3, 1], title: "Other", children: [
                MenuEntry(path: [3, 1, 0], title: "TIFF"),
                MenuEntry(path: [3, 1, 1], title: "Capture Raw", isEnabled: false),
            ]),
        ]),
        MenuEntry(path: [5], title: "Settings…", shortcut: MenuShortcut(key: ",")),
    ]

    private func titles(_ matches: [MenuMatch]) -> [String] {
        matches.map(\.entry.title)
    }

    @Test func blankQueryListsTheCurrentLevelOnly() {
        let drill = MenuDrillDown(itemName: "CleanShot X", root: menu)
        #expect(titles(drill.matches(query: "")) == ["Capture Area", "Record Screen", "Export", "Settings…"])
        #expect(titles(drill.matches(query: "  ")) == ["Capture Area", "Record Screen", "Export", "Settings…"])
        #expect(drill.matches(query: "").allSatisfy { $0.trail.isEmpty })
    }

    @Test func queryReachesIntoSubmenusWithTheirTrail() {
        let drill = MenuDrillDown(itemName: "CleanShot X", root: menu)
        let matches = drill.matches(query: "tiff")
        #expect(titles(matches) == ["TIFF"])
        #expect(matches.first?.trail == ["Export", "Other"])
    }

    @Test func queryRanksLikeItemSearch() {
        let drill = MenuDrillDown(itemName: "CleanShot X", root: menu)
        // Two prefixes in menu order, depth first, then the substring in "Screen".
        #expect(titles(drill.matches(query: "c")) == ["Capture Area", "Capture Raw", "Record Screen"])
        #expect(titles(drill.matches(query: "ure")) == ["Capture Area", "Capture Raw"])
        #expect(titles(drill.matches(query: "rcsc")) == ["Record Screen"])
    }

    @Test func enteringAndLeavingASubmenuRestoresTheQuery() {
        var drill = MenuDrillDown(itemName: "CleanShot X", root: menu)
        let entered = drill.enter(menu[2], query: "ex", selection: 0)
        #expect(entered)
        #expect(drill.breadcrumb == ["CleanShot X", "Export"])
        #expect(titles(drill.matches(query: "")) == ["PNG", "Other"])
        // A query inside a submenu only searches below it.
        #expect(titles(drill.matches(query: "cap")) == ["Capture Raw"])
        let back = drill.back()
        #expect(back?.query == "ex")
        #expect(back?.selection == 0)
        #expect(drill.isAtRoot)
        let pastTop = drill.back()
        #expect(pastTop == nil)
    }

    @Test func enteringADeepMatchOpensEachSubmenuOnTheWay() throws {
        var drill = MenuDrillDown(itemName: "CleanShot X", root: menu)
        let other = try #require(drill.matches(query: "other").first?.entry)
        let entered = drill.enter(other, query: "other", selection: 0)
        #expect(entered)
        #expect(drill.breadcrumb == ["CleanShot X", "Export", "Other"])
        #expect(titles(drill.matches(query: "")) == ["TIFF", "Capture Raw"])
        // Back first to Export, with an empty query, then to the top with the one typed there.
        let toExport = drill.back()
        #expect(toExport?.query == "")
        #expect(drill.breadcrumb == ["CleanShot X", "Export"])
        let toTop = drill.back()
        #expect(toTop?.query == "other")
    }

    @Test func leavesAndEntriesOutsideTheLevelCannotBeEntered() {
        var drill = MenuDrillDown(itemName: "CleanShot X", root: menu)
        let leaf = drill.enter(menu[0], query: "", selection: nil)
        let export = drill.enter(menu[2], query: "", selection: nil)
        let gone = MenuEntry(path: [9], title: "Gone", children: [MenuEntry(path: [9, 0], title: "x")])
        let outside = drill.enter(gone, query: "", selection: nil)
        #expect(!leaf)
        #expect(export)
        #expect(!outside)
        #expect(drill.breadcrumb == ["CleanShot X", "Export"])
    }

    @Test func shortcutsDecodeAccessibilityModifiers() {
        #expect(MenuShortcut(axKey: "q", axModifiers: 0)?.displayString == "⌘Q")
        #expect(MenuShortcut(axKey: "4", axModifiers: 1)?.displayString == "⇧⌘4")
        #expect(MenuShortcut(axKey: "k", axModifiers: 2 | 4)?.displayString == "⌃⌥⌘K")
        #expect(MenuShortcut(axKey: "x", axModifiers: 8 | 4)?.displayString == "⌃X")
        #expect(MenuShortcut(axKey: nil, axModifiers: 0) == nil)
        #expect(MenuShortcut(axKey: " ", axModifiers: 8) == nil)
    }

    @Test func displayTitleTakesTheFirstLine() {
        #expect(MenuEntry.displayTitle("  Quit ") == "Quit")
        #expect(MenuEntry.displayTitle("\nCost, Today: 864M\nLast 30 days: 3B") == "Cost, Today: 864M")
        #expect(MenuEntry.displayTitle("") == nil)
        #expect(MenuEntry.displayTitle(" \n ") == nil)
        #expect(MenuEntry.displayTitle(nil) == nil)
    }
}
