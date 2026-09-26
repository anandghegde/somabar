import Testing
@testable import SomabarCore

@Suite struct ItemSearchTests {
    private typealias Candidate = SearchCandidate<Int>

    /// Bar order, left to right.
    private let bar: [Candidate] = [
        Candidate(id: 0, appName: "Dropbox", title: "Dropbox", tag: .tucked),
        Candidate(id: 1, appName: "Docker Desktop", title: "Docker", tag: .hidden),
        Candidate(id: 2, appName: "Tailscale", title: "Tailscale", tag: .hidden),
        Candidate(id: 3, appName: "1Password", title: "Password Manager", tag: .shown),
        Candidate(id: 4, appName: "Control Center", title: "Wi‑Fi", tag: .managed),
        Candidate(id: 5, appName: "Control Center", title: "Clock", tag: .managed),
    ]

    private func ids(_ query: String) -> [Int] {
        ItemSearch.rank(bar, query: query).map(\.id)
    }

    @Test func emptyQueryListsEverythingInBarOrder() {
        #expect(ids("") == [0, 1, 2, 3, 4, 5])
        #expect(ids("   ") == [0, 1, 2, 3, 4, 5])
    }

    @Test func appPrefixBeatsTitlePrefixBeatsSubstringBeatsFuzzy() {
        let candidates: [Candidate] = [
            Candidate(id: 0, appName: "Xylo", title: "Cold Air Tap", tag: .shown),  // fuzzy
            Candidate(id: 1, appName: "Bobcat", title: "", tag: .shown),           // substring
            Candidate(id: 2, appName: "Zed", title: "Catalog", tag: .hidden),      // title prefix
            Candidate(id: 3, appName: "Catch", title: "", tag: .tucked),           // app prefix
            Candidate(id: 4, appName: "Clearance", title: "t", tag: .shown),       // fuzzy
            Candidate(id: 5, appName: "Nothing", title: "here", tag: .shown),
        ]
        #expect(ItemSearch.rank(candidates, query: "cat").map(\.id) == [3, 2, 1, 0, 4])
    }

    @Test func matchKinds() {
        #expect(ItemSearch.match(query: "doc", appName: "Docker Desktop", title: "Docker") == .appPrefix)
        #expect(ItemSearch.match(query: "pass", appName: "1Password", title: "Password Manager") == .titlePrefix)
        #expect(ItemSearch.match(query: "desk", appName: "Docker Desktop", title: "Docker") == .substring)
        #expect(ItemSearch.match(query: "manager", appName: "1Password", title: "Password Manager") == .substring)
        #expect(ItemSearch.match(query: "tlsc", appName: "Tailscale", title: "Tailscale") == .fuzzy)
        #expect(ItemSearch.match(query: "zzz", appName: "Tailscale", title: "Tailscale") == nil)
    }

    @Test func tiesKeepBarOrder() {
        // Both Control Center items are app-prefix matches; Wi-Fi is left of Clock in the bar.
        #expect(ids("control") == [4, 5])
        // Two app prefixes left to right, then 1Password's substring.
        #expect(ids("d") == [0, 1, 3])
    }

    @Test func titlePrefixOutranksAnEarlierSubstring() {
        #expect(ids("clock") == [5])
        #expect(ids("pass") == [3])
        #expect(ids("box") == [0])
    }

    @Test func caseAndDiacriticsAreIgnored() {
        let candidates = [Candidate(id: 0, appName: "Café Menu", title: "Überblick", tag: .shown)]
        #expect(ItemSearch.rank(candidates, query: "CAFE").map(\.id) == [0])
        #expect(ItemSearch.match(query: "uber", appName: "Café Menu", title: "Überblick") == .titlePrefix)
    }

    @Test func fuzzyIgnoresSpacesInTheQueryAndSpansAppAndTitle() {
        #expect(ItemSearch.match(query: "d d", appName: "Docker Desktop", title: "Docker") == .fuzzy)
        #expect(ItemSearch.match(query: "ccclk", appName: "Control Center", title: "Clock") == .fuzzy)
        #expect(ItemSearch.match(query: "kcolc", appName: "Control Center", title: "Clock") == nil)
    }

    @Test func noMatchIsAnEmptyList() {
        #expect(ids("qqq").isEmpty)
    }

    @Test func selectionMovesAndClamps() {
        #expect(ItemSearch.moveSelection(nil, by: 1, count: 3) == 0)
        #expect(ItemSearch.moveSelection(nil, by: -1, count: 3) == 2)
        #expect(ItemSearch.moveSelection(0, by: 1, count: 3) == 1)
        #expect(ItemSearch.moveSelection(2, by: 1, count: 3) == 2)
        #expect(ItemSearch.moveSelection(0, by: -1, count: 3) == 0)
        #expect(ItemSearch.moveSelection(1, by: 1, count: 0) == nil)
    }

    @Test func tagsFollowTheSectionUnlessMacOSManagesTheItem() {
        #expect(SearchTag(section: .shown, isManagedByMacOS: false) == .shown)
        #expect(SearchTag(section: .hidden, isManagedByMacOS: false) == .hidden)
        #expect(SearchTag(section: .tucked, isManagedByMacOS: false) == .tucked)
        #expect(SearchTag(section: .locked, isManagedByMacOS: false) == .locked)
        #expect(SearchTag(section: .hidden, isManagedByMacOS: true) == .managed)
        #expect(SearchTag.managed.displayName == "managed")
    }
}
