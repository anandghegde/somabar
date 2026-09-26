import Foundation

/// N3: "hang up where the app supports it". No call app offers a public API for it, so Somabar
/// looks for the app's own menu item through Accessibility and presses it. This is the pure
/// part: which app is in the call and which menu titles mean "leave".
///
/// Only titles that leave the call are listed. "End Meeting" for all is left out on purpose: a
/// notch button should never end a meeting for everyone else.
public enum CallHangUp {
    /// Menu titles per call app, preferred first. Compared without case, trailing ellipsis or
    /// surrounding spaces.
    public static let titles: [String: [String]] = [
        "us.zoom.xos": ["Leave Meeting", "Leave"],
        "zoom.us": ["Leave Meeting", "Leave"],
        "com.apple.FaceTime": ["End", "End Call", "Leave Call"],
        "com.microsoft.teams2": ["Leave", "Leave Meeting", "Hang Up"],
        "com.microsoft.teams": ["Leave", "Leave Meeting", "Hang Up"],
        "com.cisco.webexmeetingsapp": ["Leave Meeting", "Leave"],
        "com.tinyspeck.slackmacgap": ["Leave Huddle"],
        "com.hnc.Discord": ["Disconnect"],
    ]

    /// The call app to look in: the known one in front, else the first known one running.
    public static func appBundleID(runningApps: Set<String>, frontmostApp: String?) -> String? {
        let known = CallSource.knownApps.map(\.bundleID).filter { titles[$0] != nil }
        if let frontmostApp, known.contains(frontmostApp) { return frontmostApp }
        return known.first { runningApps.contains($0) }
    }

    /// How well a menu title matches: 0 is the app's first choice, nil is no match.
    public static func matchRank(title: String, bundleID: String) -> Int? {
        guard let candidates = titles[bundleID] else { return nil }
        let key = normalized(title)
        guard !key.isEmpty else { return nil }
        return candidates.firstIndex { normalized($0) == key }
    }

    /// Of the titles a menu bar offers, the best one to press; nil when none leaves the call.
    public static func bestTitle(in menuTitles: [String], bundleID: String) -> String? {
        menuTitles
            .compactMap { title in matchRank(title: title, bundleID: bundleID).map { (title, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    static func normalized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("…") || text.hasSuffix(".") {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
