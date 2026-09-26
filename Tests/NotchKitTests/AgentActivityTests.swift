import Foundation
import SomabarCore
import Testing
@testable import NotchKit

@Suite struct AgentMessageTests {
    @Test func parsesAJSONLine() {
        let line = #"{"session":"abc","project":"/Users/me/src/somabar/","state":"needsYou","detail":"Bash: swift test","terminal":"com.apple.Terminal"}"#
        let message = AgentMessage.parse(line: line)
        #expect(message == AgentMessage(
            session: "abc", project: "somabar", state: .needsYou, detail: "Bash: swift test", terminal: "com.apple.Terminal"))
    }

    @Test func requiresSessionAndState() {
        #expect(AgentMessage.parse(line: #"{"state":"working"}"#) == nil)
        #expect(AgentMessage.parse(line: #"{"session":"a","state":"dancing"}"#) == nil)
        #expect(AgentMessage.parse(line: "not json") == nil)
        #expect(AgentMessage.parse(line: "[1,2]") == nil)
        #expect(AgentMessage.parse(line: #"{"session":"a","state":"working"}"#)?.project == "")
    }

    @Test func acceptsLooseStateSpellings() {
        #expect(AgentState(loose: "needs_you") == .needsYou)
        #expect(AgentState(loose: "Needs-You") == .needsYou)
        #expect(AgentState(loose: "waiting") == .needsYou)
        #expect(AgentState(loose: "stop") == .done)
        #expect(AgentState(loose: "SessionEnd") == .ended)
        #expect(AgentState(loose: "working") == .working)
        #expect(AgentState(loose: "") == nil)
    }

    @Test func acceptsClaudeCodeFieldNames() {
        let message = AgentMessage.parse(line: #"{"session_id":"s1","cwd":"/tmp/web","state":"working"}"#)
        #expect(message?.session == "s1")
        #expect(message?.project == "web")
    }

    @Test func parsesURLQueryItems() {
        let url = URL(string: "somabar://agent?session=s2&state=done&project=api&detail=All%20green")!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(AgentMessage.parse(queryItems: items) == AgentMessage(session: "s2", project: "api", state: .done, detail: "All green"))
    }

    @Test func cleansAndLimitsText() {
        let long = String(repeating: "x", count: 500)
        let line = #"{"session":"a","state":"working","detail":"line one\nline two","project":"\#(long)"}"#
        let message = AgentMessage.parse(line: line)
        #expect(message?.detail == "line one line two")
        #expect((message?.project.count ?? 0) <= AgentMessage.maxProjectLength)
        #expect(AgentMessage.parse(line: #"{"session":"   ","state":"working"}"#) == nil)
    }

    @Test func refusesOverlongLines() {
        let detail = String(repeating: "y", count: AgentMessage.maxLineBytes)
        #expect(AgentMessage.parse(line: #"{"session":"a","state":"working","detail":"\#(detail)"}"#) == nil)
    }
}

@Suite struct AgentSessionTableTests {
    private func message(_ session: String, _ state: AgentState, project: String = "somabar", detail: String? = nil) -> AgentMessage {
        AgentMessage(session: session, project: project, state: state, detail: detail)
    }

    @Test func pulsesWhenASessionWaitsOrFinishes() {
        var table = AgentSessionTable()
        let started = table.apply(message("a", .working), at: 0)
        #expect(started == nil)
        let waits = table.apply(message("a", .needsYou), at: 1)
        #expect(waits == .needsYou(project: "somabar"))
        let waitsAgain = table.apply(message("a", .needsYou), at: 2)
        #expect(waitsAgain == nil, "Only the change pulses")
        let finished = table.apply(message("a", .done), at: 3)
        #expect(finished == .finished(project: "somabar"))
        let unknownDone = table.apply(message("b", .done), at: 4)
        #expect(unknownDone == nil, "A done from a session never seen working does not pulse")
    }

    @Test func waitingKeepsThePendingToolCall() {
        var table = AgentSessionTable()
        table.apply(message("a", .working, detail: "Bash: rm -rf build"), at: 0)
        table.apply(message("a", .needsYou), at: 1)
        #expect(table.sessions["a"]?.detail == "Bash: rm -rf build")
        table.apply(message("a", .done), at: 2)
        #expect(table.sessions["a"]?.detail == nil)
    }

    @Test func compactStateAndRank() {
        var table = AgentSessionTable()
        #expect(table.compactState == nil)
        #expect(table.rank == nil)
        table.apply(message("a", .done), at: 0)
        #expect(table.compactState == nil, "Done sessions are listed but do not take Compact")
        table.apply(message("b", .working), at: 0)
        #expect(table.compactState == .working)
        #expect(table.rank == .agentWorking)
        table.apply(message("c", .needsYou, project: "api"), at: 0)
        #expect(table.compactState == .needsYou)
        #expect(table.rank == .agentNeedsYou)
    }

    @Test func endedRemovesTheSession() {
        var table = AgentSessionTable()
        table.apply(message("a", .working), at: 0)
        table.apply(message("a", .ended), at: 1)
        #expect(table.isEmpty)
    }

    @Test func silentSessionsExpireAfterTenMinutes() {
        var table = AgentSessionTable()
        table.apply(message("a", .working), at: 0)
        table.apply(message("b", .working), at: 300)
        #expect(table.nextExpiry == 600)
        let early = table.expire(at: 599)
        #expect(!early)
        let due = table.expire(at: 600)
        #expect(due)
        #expect(table.sessions.keys.sorted() == ["b"])
        #expect(table.nextExpiry == 900)
    }

    @Test func groupsByProjectMostUrgentFirst() {
        var table = AgentSessionTable()
        table.apply(message("a", .working, project: "web"), at: 0)
        table.apply(message("b", .done, project: "api"), at: 0)
        table.apply(message("c", .needsYou, project: "somabar"), at: 0)
        table.apply(message("d", .working, project: "web"), at: 1)
        let groups = table.groups
        #expect(groups.map(\.project) == ["somabar", "web", "api"])
        #expect(groups[1].sessions.map(\.id) == ["d", "a"], "Latest report first within a state")
        #expect(AgentText.summary(groups) == "somabar needs you · web working (2) · api done")
        #expect(table.focusSession?.id == "c")
    }

    @Test func keepsAtMostThirtyTwoSessions() {
        var table = AgentSessionTable()
        for index in 0..<40 {
            table.apply(message("s\(index)", .working), at: Double(index))
        }
        #expect(table.sessions.count == AgentSessionTable.maxSessions)
        #expect(table.sessions["s0"] == nil)
        #expect(table.sessions["s39"] != nil)
    }

    @Test func terminalBundleIDs() {
        #expect(AgentTerminal.bundleID(for: "Apple_Terminal") == "com.apple.Terminal")
        #expect(AgentTerminal.bundleID(for: "iTerm.app") == "com.googlecode.iterm2")
        #expect(AgentTerminal.bundleID(for: "com.mitchellh.ghostty") == "com.mitchellh.ghostty")
        #expect(AgentTerminal.bundleID(for: "not a bundle") == nil)
        #expect(AgentTerminal.bundleID(for: "tmux") == nil)
        #expect(AgentTerminal.bundleID(for: nil) == nil)
    }
}
