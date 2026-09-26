import SomabarCore

/// The words and numbers the activities show. Pure so the formats are tested.
public enum ActivityText {
    /// Elapsed time: m:ss under an hour, then h:mm:ss. Rounded down, so a call reads 0:00 for its
    /// first second.
    public static func elapsed(seconds: Double) -> String {
        clock(Int(max(0, seconds).rounded(.down)))
    }

    /// Time left, with a leading minus: "-3:21". Rounded up, so it reads -0:00 only at the end.
    public static func remaining(seconds: Double) -> String {
        "-" + clock(Int(max(0, seconds).rounded(.up)))
    }

    private static func clock(_ whole: Int) -> String {
        let hours = whole / 3600
        let minutes = whole / 60 % 60
        let seconds = whole % 60
        let ss = (seconds < 10 ? "0" : "") + "\(seconds)"
        guard hours > 0 else { return "\(whole / 60):\(ss)" }
        return "\(hours):" + (minutes < 10 ? "0" : "") + "\(minutes):\(ss)"
    }

    /// "1 h 20 min", "45 min", "2 h".
    public static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(rest) min"
        }
    }

    /// The pulse when the power source changes; nil when it did not.
    ///
    /// "Charging · 63 % · 1 h 20 min to full", "Charged · 100 %", "On battery · 63 % · 5 h left".
    /// A time macOS has not estimated yet is left out.
    public static func powerPulse(from old: PowerReading, to new: PowerReading) -> String? {
        guard old.source != new.source else { return nil }
        let percent = new.percent.map { "\($0) %" }
        switch new.source {
        case .adapter:
            if new.percent == 100 || new.isCharged {
                return ["Charged", percent].compactMap(\.self).joined(separator: " · ")
            }
            let toFull = new.minutesToFull.map { duration(minutes: $0) + " to full" }
            return ["Charging", percent, toFull].compactMap(\.self).joined(separator: " · ")
        case .battery:
            let left = new.minutesToEmpty.map { duration(minutes: $0) + " left" }
            return ["On battery", percent, left].compactMap(\.self).joined(separator: " · ")
        }
    }
}

/// The internal battery and what powers the Mac, with macOS's estimates.
public struct PowerReading: Equatable, Sendable {
    public var source: PowerSource
    public var percent: Int?
    /// nil while macOS is still estimating, or when not charging.
    public var minutesToFull: Int?
    /// nil while macOS is still estimating, or when on the adapter.
    public var minutesToEmpty: Int?
    public var isCharged: Bool

    public init(source: PowerSource, percent: Int? = nil, minutesToFull: Int? = nil, minutesToEmpty: Int? = nil, isCharged: Bool = false) {
        self.source = source
        self.percent = percent
        self.minutesToFull = minutesToFull
        self.minutesToEmpty = minutesToEmpty
        self.isCharged = isCharged
    }

    /// A plug-in whose time to full is not known yet: worth waiting a moment for the estimate.
    public var isAwaitingEstimate: Bool {
        source == .adapter && !isCharged && percent != 100 && minutesToFull == nil
    }
}

/// Which app a call is probably in, from what is running. macOS says only that the microphone or
/// the camera is in use, not by whom, so this is a best guess and says so in plain words.
public enum CallSource {
    /// Meeting apps first: Slack and Discord are often running without a call.
    public static let knownApps: [(bundleID: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("zoom.us", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
    ]

    /// A call in a browser (Meet, Teams on the web) cannot be told apart from other browsing, so
    /// it is only named while a browser is in front.
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// The known call app in front, else the first one running, else "Browser call" when a
    /// browser is in front; nil when there is nothing to go on.
    public static func name(runningApps: Set<String>, frontmostApp: String?) -> String? {
        if let frontmostApp, let known = knownApps.first(where: { $0.bundleID == frontmostApp }) {
            return known.name
        }
        if let running = knownApps.first(where: { runningApps.contains($0.bundleID) }) {
            return running.name
        }
        if let frontmostApp, browsers.contains(frontmostApp) {
            return "Browser call"
        }
        return nil
    }

    /// The fallback title when no app can be named.
    public static func deviceTitle(microphone: Bool, camera: Bool) -> String {
        switch (microphone, camera) {
        case (true, true): "Microphone and camera in use"
        case (false, true): "Camera in use"
        default: "Microphone in use"
        }
    }
}
