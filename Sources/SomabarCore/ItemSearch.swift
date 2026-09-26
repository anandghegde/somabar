import Foundation

/// The small tag the search palette shows beside each item.
public enum SearchTag: String, Sendable, CaseIterable {
    case shown
    case hidden
    case tucked
    case locked
    /// macOS owns the item, or Control Center hosts it; Somabar can only point at it.
    case managed

    public init(section: Section, isManagedByMacOS: Bool) {
        if isManagedByMacOS {
            self = .managed
            return
        }
        switch section {
        case .shown: self = .shown
        case .hidden: self = .hidden
        case .tucked: self = .tucked
        case .locked: self = .locked
        }
    }

    public var displayName: String {
        switch self {
        case .shown: "Shown"
        case .hidden: "Hidden"
        case .tucked: "Tucked"
        case .locked: "Locked"
        case .managed: "managed"
        }
    }
}

/// One line the palette can show. Candidates are handed over in bar order, left to right.
public struct SearchCandidate<ID: Hashable & Sendable>: Equatable, Sendable {
    public var id: ID
    public var appName: String
    public var title: String
    public var tag: SearchTag

    public init(id: ID, appName: String, title: String, tag: SearchTag) {
        self.id = id
        self.appName = appName
        self.title = title
        self.tag = tag
    }
}

/// Filters and ranks menu bar items for the search palette. Pure, so the ranking is testable.
///
/// A prefix of the app name beats a prefix of the item title, which beats a substring of
/// either, which beats the query's letters appearing in order anywhere ("fuzzy"). Ties keep bar
/// order, so the list does not reshuffle while the person types within one kind of match.
public enum ItemSearch {
    public enum MatchKind: Int, Comparable, Sendable {
        case appPrefix
        case titlePrefix
        case substring
        case fuzzy

        public static func < (lhs: MatchKind, rhs: MatchKind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The candidates that match, best first. An empty or blank query returns every candidate.
    public static func rank<ID>(_ candidates: [SearchCandidate<ID>], query: String) -> [SearchCandidate<ID>] {
        let needle = normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return candidates }
        let matched = candidates.enumerated().compactMap { index, candidate -> Ranked<ID>? in
            guard let kind = match(needle: needle, appName: candidate.appName, title: candidate.title) else { return nil }
            return Ranked(kind: kind, barIndex: index, candidate: candidate)
        }
        return matched.sorted { ($0.kind, $0.barIndex) < ($1.kind, $1.barIndex) }.map(\.candidate)
    }

    /// How a query matches one item, or nil when it does not. Case and diacritics are ignored.
    public static func match(query: String, appName: String, title: String) -> MatchKind? {
        let needle = normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .substring }
        return match(needle: needle, appName: appName, title: title)
    }

    /// The row the selection lands on after moving `delta` rows, clamped to the list. Nil for an
    /// empty list; a list with no selection yet starts at the top.
    public static func moveSelection(_ current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta < 0 ? count - 1 : 0 }
        return min(max(current + delta, 0), count - 1)
    }

    // MARK: - Matching

    private struct Ranked<ID: Hashable & Sendable> {
        var kind: MatchKind
        var barIndex: Int
        var candidate: SearchCandidate<ID>
    }

    private static func match(needle: String, appName: String, title: String) -> MatchKind? {
        let app = normalized(appName)
        let name = normalized(title)
        if app.hasPrefix(needle) { return .appPrefix }
        if name.hasPrefix(needle) { return .titlePrefix }
        if app.contains(needle) || name.contains(needle) { return .substring }
        if isSubsequence(needle.filter { !$0.isWhitespace }, of: app + " " + name) { return .fuzzy }
        return nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return false
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
