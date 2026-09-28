import Foundation
import SomabarCore

// N11: coding agents (Claude Code, Codex, Gemini CLI) report their sessions to Somabar through
// their own hooks. Everything here is pure: the socket and the URL handler hand it messages,
// and the activity center reads the table.

/// What a session is doing, as its hook reports it.
public enum AgentState: String, Codable, CaseIterable, Sendable {
    case working
    case needsYou
    case done
    case ended

    /// Accepts the spellings scripts tend to use: "needs_you", "needs-you", "waiting", "stop".
    public init?(loose text: String) {
        let key = text.lowercased().filter { $0.isLetter }
        switch key {
        case "working", "busy", "running", "start", "started": self = .working
        case "needsyou", "waiting", "needsinput", "permission", "notification": self = .needsYou
        case "done", "stop", "stopped", "finished", "idle": self = .done
        case "ended", "end", "sessionend", "exit", "closed": self = .ended
        default: return nil
        }
    }
}

/// One status report from an agent's hook.
///
/// On the socket it is one line of JSON:
/// `{"session":"id","project":"name or path","state":"working|needsYou|done|ended","detail":"…","terminal":"…"}`.
/// Only `session` and `state` are required. `terminal` is a bundle identifier or a
/// `TERM_PROGRAM` value, used by "Show terminal".
public struct AgentMessage: Equatable, Sendable {
    public var session: String
    public var project: String
    public var state: AgentState
    public var detail: String?
    public var terminal: String?

    public static let maxLineBytes = 16 * 1024
    static let maxSessionLength = 128
    static let maxProjectLength = 120
    static let maxDetailLength = 240
    static let maxTerminalLength = 128

    public init(session: String, project: String, state: AgentState, detail: String? = nil, terminal: String? = nil) {
        self.session = session
        self.project = project
        self.state = state
        self.detail = detail
        self.terminal = terminal
    }

    /// One line from the socket; nil when it is not a JSON object with a session and a state.
    /// The socket reads lines with `AgentLine.parse`, which also knows permission requests.
    public static func parse(line: some StringProtocol) -> AgentMessage? {
        fields(line: line).flatMap(parse(fields:))
    }

    /// A JSON object's string and number values; nil when the line is not one, or too long.
    static func fields(line: some StringProtocol) -> [String: String]? {
        let data = Data(line.utf8)
        guard data.count <= maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String {
                fields[key] = text
            } else if let number = value as? NSNumber {
                fields[key] = number.stringValue
            }
        }
        return fields
    }

    /// `somabar://agent?session=…&state=…&project=…&detail=…&terminal=…`.
    public static func parse(queryItems: [URLQueryItem]) -> AgentMessage? {
        var fields: [String: String] = [:]
        for item in queryItems {
            if let value = item.value { fields[item.name] = value }
        }
        return parse(fields: fields)
    }

    static func parse(fields: [String: String]) -> AgentMessage? {
        guard let session = clean(fields["session"] ?? fields["session_id"], limit: maxSessionLength),
              let state = (fields["state"]).flatMap(AgentState.init(loose:))
        else { return nil }
        let project = clean(fields["project"] ?? fields["cwd"], limit: 1024).map(projectName(from:)) ?? ""
        return AgentMessage(
            session: session,
            project: String(project.prefix(maxProjectLength)),
            state: state,
            detail: clean(fields["detail"], limit: maxDetailLength),
            terminal: clean(fields["terminal"], limit: maxTerminalLength))
    }

    /// A path becomes its last component: "/Users/me/src/somabar/" is "somabar".
    public static func projectName(from text: String) -> String {
        guard text.contains("/") else { return text }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? text
    }

    /// Trimmed, control characters turned into spaces, cut to `limit`; nil when empty.
    static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let flat = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}

/// A session Somabar has heard from.
public struct AgentSession: Equatable, Sendable, Identifiable {
    public var id: String
    public var project: String
    public var state: AgentState
    /// The pending tool call, or what the agent last said.
    public var detail: String?
    public var terminal: String?
    /// When the session was first heard from, on the caller's clock.
    public var startedAt: Double
    /// When it last reported.
    public var updatedAt: Double
}

/// The sessions of one project, most urgent first.
public struct AgentProjectGroup: Equatable, Sendable {
    public var project: String
    public var sessions: [AgentSession]

    /// The most urgent state among the project's sessions.
    public var state: AgentState {
        sessions.map(\.state).min(by: AgentSessionTable.urgency) ?? .done
    }
}

/// A change worth a pulse.
public enum AgentPulse: Equatable, Sendable {
    case needsYou(project: String)
    case finished(project: String)

    public var text: String {
        switch self {
        case .needsYou(let project): project.isEmpty ? "Agent needs you" : "\(project) needs you"
        case .finished(let project): project.isEmpty ? "Agent finished" : "\(project) finished"
        }
    }

    public var symbol: String {
        switch self {
        case .needsYou: "exclamationmark.bubble.fill"
        case .finished: "checkmark.circle"
        }
    }
}

/// Every live session, keyed by id. Sessions that stay silent for `expirySeconds` are dropped,
/// so a crashed agent does not leave "working" in the notch forever.
public struct AgentSessionTable: Equatable, Sendable {
    public static let expirySeconds = 10.0 * 60
    /// More sessions than this and the oldest silent one makes room.
    public static let maxSessions = 32

    public private(set) var sessions: [String: AgentSession] = [:]

    public init() {}

    /// Applies a report. Returns the pulse it warrants: a session that starts waiting, or one that
    /// finishes after working.
    @discardableResult
    public mutating func apply(_ message: AgentMessage, at now: Double) -> AgentPulse? {
        let previous = sessions[message.session]
        guard message.state != .ended else {
            sessions[message.session] = nil
            return nil
        }
        var session = previous ?? AgentSession(
            id: message.session, project: message.project, state: message.state,
            detail: nil, terminal: nil, startedAt: now, updatedAt: now)
        if !message.project.isEmpty { session.project = message.project }
        if let terminal = message.terminal { session.terminal = terminal }
        session.state = message.state
        session.updatedAt = now
        switch message.state {
        // A wait without a detail keeps the tool call the agent was about to make.
        case .needsYou: session.detail = message.detail ?? previous?.detail
        case .working: session.detail = message.detail
        case .done, .ended: session.detail = nil
        }
        sessions[message.session] = session
        trim()
        switch message.state {
        case .needsYou where previous?.state != .needsYou: return .needsYou(project: session.project)
        case .done where previous != nil && previous?.state != .done: return .finished(project: session.project)
        default: return nil
        }
    }

    /// Drops sessions silent since `now - expirySeconds`. Returns true when any went.
    @discardableResult
    public mutating func expire(at now: Double) -> Bool {
        let before = sessions.count
        sessions = sessions.filter { now - $0.value.updatedAt < Self.expirySeconds }
        return sessions.count != before
    }

    /// When the next session expires, for a one-shot timer; nil when there are none.
    public var nextExpiry: Double? {
        sessions.values.map(\.updatedAt).min().map { $0 + Self.expirySeconds }
    }

    public var isEmpty: Bool { sessions.isEmpty }

    /// What Compact shows: "needs you" when any session waits, else "working" when any works.
    public var compactState: AgentState? {
        let states = Set(sessions.values.map(\.state))
        if states.contains(.needsYou) { return .needsYou }
        if states.contains(.working) { return .working }
        return nil
    }

    /// The board rank for Compact; nil when no session is working or waiting.
    public var rank: ActivityRank? {
        switch compactState {
        case .needsYou: .agentNeedsYou
        case .working: .agentWorking
        default: nil
        }
    }

    /// The oldest session still working or waiting, for the activity's start time.
    public var earliestActiveStart: Double? {
        sessions.values.filter { $0.state == .working || $0.state == .needsYou }.map(\.startedAt).min()
    }

    /// Sessions grouped by project: the most urgent project first, then by name.
    public var groups: [AgentProjectGroup] {
        let byProject = Dictionary(grouping: sessions.values, by: \.project)
        let groups = byProject.map { project, sessions in
            AgentProjectGroup(project: project, sessions: sessions.sorted(by: Self.sessionOrder))
        }
        return groups.sorted { lhs, rhs in
            if lhs.state != rhs.state { return Self.urgency(lhs.state, rhs.state) }
            return lhs.project.localizedStandardCompare(rhs.project) == .orderedAscending
        }
    }

    /// The session "Show terminal" goes to: the one waiting longest, else the latest to report.
    public var focusSession: AgentSession? {
        sessions.values.sorted(by: Self.sessionOrder).first
    }

    /// needsYou before working before done.
    static func urgency(_ lhs: AgentState, _ rhs: AgentState) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ state: AgentState) -> Int {
        switch state {
        case .needsYou: 0
        case .working: 1
        case .done: 2
        case .ended: 3
        }
    }

    /// Most urgent first; a wait that started earlier first; then the id, so the order is stable.
    private static func sessionOrder(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        if lhs.state != rhs.state { return urgency(lhs.state, rhs.state) }
        if lhs.state == .needsYou, lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private mutating func trim() {
        while sessions.count > Self.maxSessions,
              let oldest = sessions.values.min(by: { $0.updatedAt < $1.updatedAt }) {
            sessions[oldest.id] = nil
        }
    }
}

/// The words the agent activity shows.
public enum AgentText {
    /// Compact's text beside the glyph.
    public static func compact(_ state: AgentState) -> String {
        state == .needsYou ? "needs you" : "working"
    }

    public static func state(_ state: AgentState) -> String {
        switch state {
        case .working: "working"
        case .needsYou: "needs you"
        case .done: "done"
        case .ended: "ended"
        }
    }

    /// "somabar needs you · api working · web done". Projects with several sessions add a count:
    /// "api working (2)".
    public static func summary(_ groups: [AgentProjectGroup]) -> String {
        groups.map { group in
            let name = group.project.isEmpty ? "Agent" : group.project
            let count = group.sessions.count > 1 ? " (\(group.sessions.count))" : ""
            return "\(name) \(state(group.state))\(count)"
        }.joined(separator: " · ")
    }
}

/// Which app "Show terminal" brings forward. Hooks send `__CFBundleIdentifier`, which macOS sets
/// for every process an app starts, or `TERM_PROGRAM`.
public enum AgentTerminal {
    static let termPrograms: [String: String] = [
        "apple_terminal": "com.apple.Terminal",
        "iterm.app": "com.googlecode.iterm2",
        "vscode": "com.microsoft.VSCode",
        "warpterminal": "dev.warp.Warp-Stable",
        "ghostty": "com.mitchellh.ghostty",
        "wezterm": "com.github.wez.wezterm",
        "hyper": "co.zeit.hyper",
        "kitty": "net.kovidgoyal.kitty",
        "zed": "dev.zed.Zed",
        "tabby": "org.tabby",
    ]

    /// A bundle identifier for the value a hook sent; nil when it names nothing known.
    public static func bundleID(for value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let known = termPrograms[value.lowercased()] { return known }
        // Already a bundle identifier: reverse-DNS, letters, digits, dots and hyphens.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard value.contains("."), value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }
}
