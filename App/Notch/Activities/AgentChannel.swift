import AppKit
import NotchKit
import os
import SomabarCore

/// N11: coding agents' sessions, as their hooks report them.
///
/// Reports arrive on the local socket (`AgentSocketServer`, only while Settings › Advanced ›
/// "Listen for coding agents" is on) or through `somabar://agent?…`. Nothing is polled: the
/// only timer is a one-shot for the next session to expire, 10 minutes after it last reported.
/// Somabar never writes to the socket and never types into a terminal; "Show terminal" only
/// brings the terminal app forward.
@MainActor
final class AgentChannel {
    /// The table changed.
    var onChange: (@MainActor () -> Void)?
    /// A session started waiting or finished.
    var onPulse: (@MainActor (AgentPulse) -> Void)?

    private(set) var table = AgentSessionTable()
    private var server: AgentSocketServer?
    private var expiryTask: Task<Void, Never>?
    private let log = Logger(subsystem: "app.somabar", category: "activities")

    var isListening: Bool { server != nil }

    private static var clock: Double {
        Date().timeIntervalSinceReferenceDate
    }

    // MARK: - Listening

    /// Opens or closes the socket. Closing also forgets every session.
    func setListening(_ isOn: Bool) {
        if isOn, server == nil {
            let server = AgentSocketServer(path: AgentSocketServer.defaultPath)
            server.onMessage = { message in
                Task { @MainActor [weak self] in self?.receive(message) }
            }
            do {
                try server.start()
                self.server = server
            } catch {
                log.error("Agent socket could not open: \(String(describing: error), privacy: .public)")
            }
        } else if !isOn, let server {
            server.stop()
            self.server = nil
            clear()
        }
    }

    // MARK: - Reports

    /// A report from the socket or a URL.
    func receive(_ message: AgentMessage) {
        let now = Self.clock
        table.expire(at: now)
        let pulse = table.apply(message, at: now)
        log.info("Agent \(message.state.rawValue, privacy: .public) (\(self.table.sessions.count) sessions)")
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
        guard !table.isEmpty else { return }
        table = AgentSessionTable()
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

    // MARK: - Show terminal

    /// Brings forward the terminal of the session that waits longest, or the latest one.
    /// Activation only: nothing is typed.
    func showTerminal() {
        guard let bundleID = AgentTerminal.bundleID(for: table.focusSession?.terminal),
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
    /// by project, the pending tool call (only where file names may show) and "Show terminal".
    @MainActor
    static func agents(_ channel: AgentChannel, startedAt: Double, settings: NotchSettings) -> NotchActivity? {
        let table = channel.table
        guard let state = table.compactState, let rank = table.rank else { return nil }
        let groups = table.groups
        let summary = AgentText.summary(groups)
        let symbol = state == .needsYou ? "exclamationmark.bubble.fill" : "sparkles"
        let pending = settings.showsArtworkAndFileNames
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
                detail: pending ?? "", controls: controls))
    }
}
