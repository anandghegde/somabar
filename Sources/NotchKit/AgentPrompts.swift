import Foundation

// N11 (P2): answering an agent's permission prompt from the notch. A hook that wants a decision
// sends a request line on the socket and keeps the connection open; Somabar writes back one
// reply line and closes. Off unless both "Listen for coding agents" and "Answer permission
// prompts" are on, and never reachable through somabar://. Everything here is pure: the socket
// hands requests to the channel, which keeps them in an `AgentPromptQueue`.

/// What Somabar answers a permission request with.
public enum AgentDecision: String, Equatable, Sendable {
    case allow
    case deny
    /// No decision: the agent asks in its terminal as it would without Somabar. Sent on a
    /// timeout, a dismissal, a refusal (replies off, too many waiting) and when Somabar stops.
    case ask
}

/// A hook asking Somabar to decide on a tool call.
///
/// On the socket it is one line of JSON with a `request` id instead of a `state`:
/// `{"request":"id","session":"id","project":"…","tool":"Bash","detail":"npm test","terminal":"…"}`.
/// `request`, `session` and `tool` are required. The request also reports the session as waiting.
public struct AgentPermissionRequest: Equatable, Sendable {
    /// Chosen by the hook; echoed in the reply. Letters, digits, `.`, `_` and `-`, at most 64.
    public var id: String
    public var tool: String
    /// What the tool is about to do: the command, the file or the URL.
    public var detail: String?
    /// The status half: the session, waiting, with "tool: detail".
    public var message: AgentMessage

    static let maxIDLength = 64
    static let maxToolLength = 64

    public init(id: String, tool: String, detail: String?, message: AgentMessage) {
        self.id = id
        self.tool = tool
        self.detail = detail
        self.message = message
    }

    static func parse(fields: [String: String]) -> AgentPermissionRequest? {
        guard let id = fields["request"], isValidID(id),
              let tool = AgentMessage.clean(fields["tool"] ?? fields["tool_name"], limit: maxToolLength)
        else { return nil }
        let detail = AgentMessage.clean(fields["detail"], limit: AgentMessage.maxDetailLength)
        var status = fields
        status["state"] = AgentState.needsYou.rawValue
        status["detail"] = detail.map { "\(tool): \($0)" } ?? tool
        guard let message = AgentMessage.parse(fields: status) else { return nil }
        return AgentPermissionRequest(id: id, tool: tool, detail: detail, message: message)
    }

    static func isValidID(_ id: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !id.isEmpty && id.count <= maxIDLength && id.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// The one line written back: `{"decision":"allow","id":"…"}` and a newline.
    public func reply(_ decision: AgentDecision) -> Data {
        let object = ["id": id, "decision": decision.rawValue]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// One line from the socket: a status report or a permission request.
public enum AgentLine: Equatable, Sendable {
    case status(AgentMessage)
    case request(AgentPermissionRequest)

    /// Nil when the line is neither. A line with a `request` key is only ever a request, so a
    /// malformed one is not taken as a report either.
    public static func parse(line: some StringProtocol) -> AgentLine? {
        guard let fields = AgentMessage.fields(line: line) else { return nil }
        if fields["request"] != nil {
            return AgentPermissionRequest.parse(fields: fields).map(AgentLine.request)
        }
        return AgentMessage.parse(fields: fields).map(AgentLine.status)
    }
}

/// Where a request came from: the socket's own number for the connection, and the hook's id.
/// Hooks choose ids, so two hooks may pick the same one; the connection keeps them apart.
public struct AgentPromptKey: Hashable, Sendable {
    public var connection: UInt64
    public var id: String

    public init(connection: UInt64, id: String) {
        self.connection = connection
        self.id = id
    }
}

/// A permission request waiting in the notch.
public struct AgentPrompt: Equatable, Sendable, Identifiable {
    public var id: AgentPromptKey
    public var session: String
    public var project: String
    public var tool: String
    public var detail: String?
    public var receivedAt: Double

    /// When it goes back to the terminal unanswered.
    public var deadline: Double { receivedAt + AgentPromptQueue.timeoutSeconds }
}

/// Why a prompt left the queue without an Allow or Deny.
public enum AgentPromptEnd: Equatable, Sendable {
    /// The hook went away (the agent answered in the terminal, or was stopped).
    case closed
    /// Nobody answered within `AgentPromptQueue.timeoutSeconds`.
    case timedOut
    /// The session ended or finished.
    case sessionEnded
    /// "Answer in terminal".
    case dismissed
}

/// Every permission request waiting for an answer, oldest first. Each session answers its own
/// requests in order: only its oldest can be decided, the rest queue behind it.
public struct AgentPromptQueue: Equatable, Sendable {
    /// Unanswered for this long, a request goes back to the terminal. The hook waits a little
    /// longer (75 s) so it hears the "ask".
    public static let timeoutSeconds = 60.0
    /// Allow does nothing until the prompt has been up this long, so a click meant for whatever
    /// was under the pointer cannot approve a request that appeared beneath it.
    public static let armSeconds = 1.0
    /// More than this and a request goes straight to the terminal. Each waiting request holds a
    /// socket connection, so this leaves room for status reports.
    public static let maxPending = 8
    public static let maxPerSession = 4

    public private(set) var prompts: [AgentPrompt] = []

    public init() {}

    public var isEmpty: Bool { prompts.isEmpty }

    /// Queues a request. False when it is a duplicate or the queue is full; the caller then sends
    /// "ask" so the terminal prompts at once.
    public mutating func add(_ request: AgentPermissionRequest, connection: UInt64, at now: Double) -> Bool {
        let key = AgentPromptKey(connection: connection, id: request.id)
        let session = request.message.session
        guard !prompts.contains(where: { $0.id == key }),
              prompts.count < Self.maxPending,
              prompts.count(where: { $0.session == session }) < Self.maxPerSession
        else { return false }
        prompts.append(AgentPrompt(
            id: key, session: session, project: request.message.project,
            tool: request.tool, detail: request.detail, receivedAt: now))
        return true
    }

    /// The oldest request of each session, oldest first: the ones the notch offers to answer.
    public var heads: [AgentPrompt] {
        var seen: Set<String> = []
        return prompts.filter { seen.insert($0.session).inserted }
    }

    /// Whether `decision` may be taken for this prompt now: it must head its session, and Allow
    /// must have been up for `armSeconds`.
    public func canDecide(_ key: AgentPromptKey, _ decision: AgentDecision, at now: Double) -> Bool {
        guard let prompt = heads.first(where: { $0.id == key }) else { return false }
        return decision != .allow || now - prompt.receivedAt >= Self.armSeconds
    }

    /// Takes a prompt out for an answer; nil when `canDecide` says no (or it has already gone).
    public mutating func decide(_ key: AgentPromptKey, _ decision: AgentDecision, at now: Double) -> AgentPrompt? {
        guard canDecide(key, decision, at: now) else { return nil }
        return remove(key)
    }

    /// Takes a prompt out whatever its place, for a dismissal.
    @discardableResult
    public mutating func remove(_ key: AgentPromptKey) -> AgentPrompt? {
        guard let index = prompts.firstIndex(where: { $0.id == key }) else { return nil }
        return prompts.remove(at: index)
    }

    /// The hook's connection closed.
    @discardableResult
    public mutating func remove(connection: UInt64) -> [AgentPrompt] {
        take { $0.id.connection == connection }
    }

    /// The session finished or ended: its requests are moot.
    @discardableResult
    public mutating func remove(session: String) -> [AgentPrompt] {
        take { $0.session == session }
    }

    /// Requests past their deadline.
    public mutating func expire(at now: Double) -> [AgentPrompt] {
        take { $0.deadline <= now }
    }

    /// Everything, for when replies are turned off or the socket closes.
    public mutating func removeAll() -> [AgentPrompt] {
        take { _ in true }
    }

    /// The earliest deadline, for a one-shot timer; nil when nothing waits.
    public var nextDeadline: Double? {
        prompts.map(\.deadline).min()
    }

    public func hasPrompts(session: String) -> Bool {
        prompts.contains { $0.session == session }
    }

    private mutating func take(where matches: (AgentPrompt) -> Bool) -> [AgentPrompt] {
        let taken = prompts.filter(matches)
        prompts.removeAll(where: matches)
        return taken
    }
}

/// The words a waiting prompt shows.
public enum AgentPromptText {
    /// Prompts listed under the agent row; the rest are counted in the footer.
    public static let maxLines = 2

    /// Shown in place of the command when the profile hides file names. Allow is not offered then:
    /// nothing is approved unseen.
    public static let hiddenDetail = "Details hidden in this profile"

    /// "somabar · Bash", or the tool alone.
    public static func title(_ prompt: AgentPrompt) -> String {
        prompt.project.isEmpty ? prompt.tool : "\(prompt.project) · \(prompt.tool)"
    }

    /// "and 2 more waiting"; nil for none. `queued` counts every prompt not listed.
    public static func footer(queued: Int) -> String? {
        queued > 0 ? "and \(queued) more waiting" : nil
    }
}
