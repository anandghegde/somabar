import Foundation
import Testing
@testable import NotchKit

@Suite struct AgentPermissionRequestTests {
    @Test func parsesARequestLine() throws {
        let line = #"{"request":"4242.1","session":"abc","project":"/Users/me/src/somabar","tool":"Bash","detail":"npm test","terminal":"ghostty"}"#
        guard case .request(let request) = AgentLine.parse(line: line) else {
            Issue.record("Not a request")
            return
        }
        #expect(request.id == "4242.1")
        #expect(request.tool == "Bash")
        #expect(request.detail == "npm test")
        #expect(request.message == AgentMessage(
            session: "abc", project: "somabar", state: .needsYou, detail: "Bash: npm test", terminal: "ghostty"))
    }

    @Test func statusLinesStayStatus() {
        let line = #"{"session":"a","state":"working"}"#
        #expect(AgentLine.parse(line: line) == .status(AgentMessage(session: "a", project: "", state: .working)))
        #expect(AgentLine.parse(line: "nope") == nil)
    }

    @Test func aRequestIsNeverTakenForAStatus() {
        // A request whose id or tool is bad is dropped, not read as a report.
        #expect(AgentLine.parse(line: #"{"request":"a b","session":"s","tool":"Bash","state":"working"}"#) == nil)
        #expect(AgentLine.parse(line: #"{"request":"r1","session":"s","state":"working"}"#) == nil)
        #expect(AgentLine.parse(line: #"{"request":"r1","tool":"Bash"}"#) == nil, "A session is still required")
        let long = String(repeating: "a", count: 65)
        #expect(AgentLine.parse(line: #"{"request":"\#(long)","session":"s","tool":"Bash"}"#) == nil)
        #expect(AgentLine.parse(line: #"{"request":"é","session":"s","tool":"Bash"}"#) == nil)
    }

    @Test func linksCannotAsk() {
        // somabar:// reports go through AgentMessage alone, which has no notion of a request.
        let items = [URLQueryItem(name: "request", value: "r1"), URLQueryItem(name: "session", value: "s"),
                     URLQueryItem(name: "tool", value: "Bash"), URLQueryItem(name: "state", value: "needsYou")]
        #expect(AgentMessage.parse(queryItems: items) == AgentMessage(session: "s", project: "", state: .needsYou))
    }

    @Test func toolWithoutDetail() {
        let request = request("r", session: "s", detail: nil)
        #expect(request.message.detail == "Bash")
    }

    @Test func repliesAreOneJSONLine() throws {
        let data = request("r-1", session: "s").reply(.allow)
        #expect(String(bytes: data, encoding: .utf8) == #"{"decision":"allow","id":"r-1"}"# + "\n")
        #expect(String(bytes: request("r", session: "s").reply(.ask), encoding: .utf8)?.contains(#""decision":"ask""#) == true)
    }
}

@Suite struct AgentPromptQueueTests {
    private func key(_ connection: UInt64, _ id: String = "r") -> AgentPromptKey {
        AgentPromptKey(connection: connection, id: id)
    }

    /// Adds and returns whether the queue took it.
    private func add(_ queue: inout AgentPromptQueue, _ session: String, _ connection: UInt64, at now: Double = 0,
                     detail: String? = "npm test") -> Bool {
        queue.add(request("r", session: session, detail: detail), connection: connection, at: now)
    }

    @Test func eachSessionAnswersInOrder() {
        var queue = AgentPromptQueue()
        let first = add(&queue, "a", 1, detail: "one")
        let other = add(&queue, "b", 2, at: 1)
        let second = add(&queue, "a", 3, at: 2, detail: "two")
        #expect(first && other && second)
        #expect(queue.heads.map(\.id) == [key(1), key(2)])
        #expect(!queue.canDecide(key(3), .deny, at: 10), "Queued behind the session's first")
        let early = queue.decide(key(3), .deny, at: 10)
        #expect(early == nil)
        let allowed = queue.decide(key(1), .allow, at: 10)
        #expect(allowed?.detail == "one")
        #expect(queue.heads.map(\.id) == [key(2), key(3)])
        #expect(queue.hasPrompts(session: "a"))
    }

    @Test func allowWaitsToArm() {
        var queue = AgentPromptQueue()
        _ = add(&queue, "a", 1, at: 100)
        let tooSoon = queue.decide(key(1), .allow, at: 100.5)
        #expect(tooSoon == nil, "Too soon to allow")
        #expect(queue.prompts.count == 1)
        #expect(queue.canDecide(key(1), .deny, at: 100.5), "Deny needs no wait")
        let armed = queue.decide(key(1), .allow, at: 100 + AgentPromptQueue.armSeconds)
        #expect(armed != nil)
        #expect(queue.isEmpty)
    }

    @Test func refusesDuplicatesAndOverflow() {
        var queue = AgentPromptQueue()
        let first = add(&queue, "a", 1)
        let duplicate = add(&queue, "a", 1)
        let sameIDOtherHook = add(&queue, "b", 2)
        #expect(first)
        #expect(!duplicate, "Same connection and id")
        #expect(sameIDOtherHook, "Same id, another hook")
        for connection in 3...UInt64(AgentPromptQueue.maxPerSession + 1) {
            _ = add(&queue, "a", connection)
        }
        #expect(queue.prompts.count(where: { $0.session == "a" }) == AgentPromptQueue.maxPerSession)
        for connection in 100..<UInt64(100 + AgentPromptQueue.maxPending) {
            _ = add(&queue, "s\(connection)", connection)
        }
        #expect(queue.prompts.count == AgentPromptQueue.maxPending)
    }

    @Test func timesOutAfterSixtySeconds() {
        var queue = AgentPromptQueue()
        _ = add(&queue, "a", 1, at: 0)
        _ = add(&queue, "b", 2, at: 30)
        #expect(queue.nextDeadline == 60)
        let early = queue.expire(at: 59.9)
        #expect(early.isEmpty)
        let due = queue.expire(at: 60)
        #expect(due.map(\.id) == [key(1)])
        #expect(queue.nextDeadline == 90)
        let late = queue.decide(key(1), .allow, at: 61)
        #expect(late == nil, "A timed-out prompt cannot be allowed")
    }

    @Test func closesAndEndsRemovePrompts() {
        var queue = AgentPromptQueue()
        _ = add(&queue, "a", 1)
        _ = add(&queue, "a", 2)
        _ = add(&queue, "b", 3)
        let closed = queue.remove(connection: 2)
        #expect(closed.map(\.id) == [key(2)])
        let ended = queue.remove(session: "a")
        #expect(ended.map(\.id) == [key(1)])
        let dismissed = queue.remove(key(3))
        #expect(dismissed?.session == "b")
        let again = queue.remove(key(3))
        #expect(again == nil)
        _ = add(&queue, "c", 4)
        let all = queue.removeAll()
        #expect(all.count == 1)
        #expect(queue.nextDeadline == nil)
    }

    @Test func text() {
        var queue = AgentPromptQueue()
        _ = add(&queue, "a", 1)
        #expect(AgentPromptText.title(queue.prompts[0]) == "somabar · Bash")
        #expect(AgentPromptText.footer(queued: 0) == nil)
        #expect(AgentPromptText.footer(queued: 2) == "and 2 more waiting")
    }
}

private func request(_ id: String, session: String, detail: String? = "npm test") -> AgentPermissionRequest {
    var fields = ["request": id, "session": session, "project": "somabar", "tool": "Bash"]
    fields["detail"] = detail
    return AgentPermissionRequest.parse(fields: fields)!
}
