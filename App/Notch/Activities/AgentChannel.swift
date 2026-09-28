import AppKit
import NotchKit
import os
import SomabarCore

/// N11: coding agents' sessions, as their hooks report them.
///
/// Reports arrive on the local socket (`AgentSocketServer`, only while Settings › Advanced ›
/// "Listen for coding agents" is on) or through `somabar://agent?…`. Nothing is polled: the
/// timers are one-shots for the next session to expire, 10 minutes after it last reported, and
/// for the next permission prompt to time out.
///
/// Permission prompts (P2) come only over the socket, and wait for Allow or Deny only while
/// "Answer permission prompts" is on too; otherwise, and on a timeout, a dismissal, the session
/// finishing or the socket closing, the hook hears "ask" and the agent asks in its terminal.
/// Somabar never types into a terminal; "Show terminal" only brings the terminal app forward.
@MainActor
final class AgentChannel {
    /// The table or the prompts changed.
    var onChange: (@MainActor () -> Void)?
    /// A session started waiting or finished.
    var onPulse: (@MainActor (AgentPulse) -> Void)?

    private(set) var table = AgentSessionTable()
    private(set) var prompts = AgentPromptQueue()
    private var server: AgentSocketServer?
    private var repliesOn = false
    private var expiryTask: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?
    private let log = Logger(subsystem: "app.somabar", category: "activities")

    var isListening: Bool { server != nil }

    private static var clock: Double {
        Date().timeIntervalSinceReferenceDate
    }

    // MARK: - Listening

    /// Opens or closes the socket. Closing also forgets every session, and hands every waiting
    /// prompt back to its terminal.
    func setListening(_ isOn: Bool) {
        if isOn, server == nil {
            let server = AgentSocketServer(path: AgentSocketServer.defaultPath)
            // The main queue keeps the server's order: a request is never seen after its close.
            server.onMessage = { [weak self] message in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(message) } }
            }
            server.onRequest = { [weak self] request, connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(request, connection: connection) } }
            }
            server.onRequestClosed = { [weak self] connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.requestClosed(connection) } }
            }
            server.setAcceptsRequests(repliesOn)
            do {
                try server.start()
                self.server = server
            } catch {
                log.error("Agent socket could not open: \(String(describing: error), privacy: .public)")
            }
        } else if !isOn, let server {
            // Stopping answers "ask" to every hook still waiting.
            server.stop()
            self.server = nil
            clear()
        }
    }

    /// Settings › Advanced › "Answer permission prompts". Takes effect only while the socket is
    /// open. Turning it off hands every waiting prompt back to its terminal.
    func setReplies(_ isOn: Bool) {
        repliesOn = isOn
        server?.setAcceptsRequests(isOn)
        guard !isOn else { return }
        answer(prompts.removeAll(), .ask)
        onChange?()
    }

    // MARK: - Reports

    /// A report from the socket or a URL.
    func receive(_ message: AgentMessage) {
        let now = Self.clock
        table.expire(at: now)
        let pulse = table.apply(message, at: now)
        log.info("Agent \(message.state.rawValue, privacy: .public) (\(self.table.sessions.count) sessions)")
        // A session that finished or ended asks nothing any more.
        if message.state == .done || message.state == .ended {
            answer(prompts.remove(session: message.session), .ask)
        }
        scheduleExpiry()
        onChange?()
        if let pulse { onPulse?(pulse) }
    }

    /// `somabar://agent?session=…&state=…&project=…&detail=…&terminal=…`. Taken only while the
    /// socket is on, so the same switch covers both ways in.
    func receive(url: URL) {
        guard isListening else {
            log.notice("somabar://agent ignored: Listen for coding agents is off")
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let message = AgentMessage.parse(queryItems: items) else {
            log.error("somabar://agent needs session and state")
            return
        }
        receive(message)
    }

    private func clear() {
        expiryTask?.cancel()
        expiryTask = nil
        promptTask?.cancel()
        promptTask = nil
        guard !table.isEmpty || !prompts.isEmpty else { return }
        table = AgentSessionTable()
        prompts = AgentPromptQueue()
        onChange?()
    }

    /// One sleep until the next session's expiry; nothing runs while there are no sessions.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let due = table.nextExpiry else { return }
        let delay = max(1, due - Self.clock)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if self.table.expire(at: Self.clock) {
                self.onChange?()
            }
            self.scheduleExpiry()
        }
    }

    // MARK: - Permission prompts

    /// A hook waits for a decision. The session shows as waiting either way; a request the queue
    /// has no room for goes back to the terminal at once.
    private func receive(_ request: AgentPermissionRequest, connection: UInt64) {
        let now = Self.clock
        prompts.expire(at: now).forEach { answer($0, .ask) }
        if !repliesOn || !prompts.add(request, connection: connection, at: now) {
            server?.answer(connection: connection, id: request.id, decision: .ask)
        }
        log.info("Agent permission request (\(self.prompts.prompts.count) waiting)")
        schedulePromptTimeout()
        receive(request.message)
    }

    /// The hook went away: the agent was answered in its terminal, or stopped.
    private func requestClosed(_ connection: UInt64) {
        guard !prompts.remove(connection: connection).isEmpty else { return }
        schedulePromptTimeout()
        onChange?()
    }

    /// Allow or Deny from the notch. Only the oldest prompt of a session can be answered, and
    /// Allow only once it has been up for a second (`AgentPromptQueue.armSeconds`).
    func decide(_ key: AgentPromptKey, _ decision: AgentDecision) {
        guard let prompt = prompts.decide(key, decision, at: Self.clock) else {
            log.info("Agent prompt not answered: not yet armed, or already gone")
            return
        }
        answer(prompt, decision)
        // The agent carries on; its next report says what it does.
        if !prompts.hasPrompts(session: prompt.session) {
            table.apply(AgentMessage(session: prompt.session, project: prompt.project, state: .working), at: Self.clock)
        }
        schedulePromptTimeout()
        onChange?()
    }

    /// "Answer in terminal": the hook hears "ask", and the terminal comes forward.
    func dismiss(_ key: AgentPromptKey) {
        guard let prompt = prompts.remove(key) else { return }
        answer(prompt, .ask)
        schedulePromptTimeout()
        onChange?()
        showTerminal(session: prompt.session)
    }

    private func answer(_ prompts: [AgentPrompt], _ decision: AgentDecision) {
        prompts.forEach { answer($0, decision) }
    }

    private func answer(_ prompt: AgentPrompt, _ decision: AgentDecision) {
        server?.answer(connection: prompt.id.connection, id: prompt.id.id, decision: decision)
    }

    /// One sleep until the next prompt times out.
    private func schedulePromptTimeout() {
        promptTask?.cancel()
        promptTask = nil
        guard let due = prompts.nextDeadline else { return }
        let delay = max(0.5, due - Self.clock)
        promptTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let expired = self.prompts.expire(at: Self.clock)
            if !expired.isEmpty {
                self.log.info("Agent permission request timed out; the terminal asks")
                self.answer(expired, .ask)
                self.onChange?()
            }
            self.schedulePromptTimeout()
        }
    }

    // MARK: - Show terminal

    /// Brings forward the terminal of the session that waits longest, or the latest one.
    /// Activation only: nothing is typed.
    func showTerminal() {
        activateTerminal(table.focusSession?.terminal)
    }

    private func showTerminal(session: String) {
        activateTerminal(table.sessions[session]?.terminal ?? table.focusSession?.terminal)
    }

    private func activateTerminal(_ terminal: String?) {
        guard let bundleID = AgentTerminal.bundleID(for: terminal),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        app.activate()
    }

    /// Whether "Show terminal" has somewhere to go.
    var canShowTerminal: Bool {
        guard let bundleID = AgentTerminal.bundleID(for: table.focusSession?.terminal) else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

// MARK: - The activity

extension NotchActivity {
    /// Compact: the agent glyph and "working" or "needs you". Expanded: one row with the sessions
    /// by project, the pending tool call (only where file names may show) and "Show terminal";
    /// under it, a line per waiting permission prompt with Allow, Deny and "Answer in terminal".
    @MainActor
    static func agents(_ channel: AgentChannel, startedAt: Double, settings: NotchSettings) -> NotchActivity? {
        let table = channel.table
        guard let state = table.compactState, let rank = table.rank else { return nil }
        let groups = table.groups
        let summary = AgentText.summary(groups)
        let symbol = state == .needsYou ? "exclamationmark.bubble.fill" : "sparkles"
        let lines = promptLines(channel, showsDetail: settings.showsArtworkAndFileNames)
        let pending = settings.showsArtworkAndFileNames && lines.isEmpty
            ? table.focusSession.flatMap { $0.state == .needsYou ? $0.detail : nil }
            : nil
        var controls: [ActivityControl] = []
        if channel.canShowTerminal {
            controls.append(ActivityControl(symbol: "terminal", label: "Show terminal") { channel.showTerminal() })
        }
        let text = AgentText.compact(state)
        return NotchActivity(
            kind: .agentActivity, rank: rank, startedAt: startedAt,
            compact: CompactPresentation(
                kind: .agentActivity, symbol: symbol, text: text,
                accessibilityLabel: "Agent \(text): \(summary)"),
            row: ActivityRow(
                id: .agentActivity, symbol: symbol, title: summary,
                detail: pending ?? "", controls: controls,
                lines: lines, linesFooter: lines.isEmpty ? nil : AgentPromptText.footer(queued: channel.prompts.prompts.count - lines.count)))
    }

    /// The oldest prompt of each session, at most `AgentPromptText.maxLines`. Allow is offered
    /// only where the command shows: a profile that hides file names gets Deny and the terminal.
    @MainActor
    private static func promptLines(_ channel: AgentChannel, showsDetail: Bool) -> [ActivityLine] {
        channel.prompts.heads.prefix(AgentPromptText.maxLines).map { prompt in
            let key = prompt.id
            var controls: [ActivityControl] = []
            if showsDetail {
                controls.append(ActivityControl(symbol: "checkmark", label: "Allow") { channel.decide(key, .allow) })
            }
            controls.append(ActivityControl(symbol: "xmark", label: "Deny") { channel.decide(key, .deny) })
            controls.append(ActivityControl(symbol: "terminal", label: "Answer in terminal") { channel.dismiss(key) })
            let detail = showsDetail ? (prompt.detail ?? "") : AgentPromptText.hiddenDetail
            return ActivityLine(
                id: "\(key.connection)-\(key.id)", title: AgentPromptText.title(prompt), detail: detail,
                controls: controls, help: showsDetail ? prompt.detail : nil)
        }
    }
}
