import AppKit
import NotchKit
import os
import SomabarCore

/// Owns the notch's live activities and decides what the notch shows of them.
///
/// Sources: the timer (on the surface), calls (the context's microphone and camera state),
/// Now Playing (Music and Spotify notifications), file drags (drop to share), power changes
/// (charging pulses), the Focus (pulses) and screen sharing (the guard's red dot). Every change
/// rebuilds the list and hands it to `ActivityBoard`, which applies the profile's switches and
/// the screen-share rule; the winner goes to Compact and the rest to Expanded. A 1 s tick runs
/// only while a call or a track is counting.
@MainActor
final class ActivityCenter {
    /// The active profile's notch settings.
    var settings: @MainActor () -> NotchSettings = { .everyday }
    /// The active profile, and the one a trigger switched away from (for the guard's undo).
    var profiles: @MainActor () -> (active: String, beforeTriggers: String?) = { ("", nil) }
    var switchProfile: @MainActor (String) -> Void = { _ in }

    private weak var surface: NotchSurface?
    private var snapshot = ContextSnapshot()
    private var isStarted = false
    private let charging = ChargingWatcher()
    private let nowPlaying = NowPlayingWatcher()
    private let drop = DropToShareWatcher()
    private var tickTask: Task<Void, Never>?

    /// When each activity became live, so the older of two equal ranks keeps Compact.
    private var startedAt: [ActivityKind: Double] = [:]
    /// Double optional: nil until the first snapshot, so the Focus at launch does not pulse.
    private var lastFocus: String??
    private var lastWinner: ActivityKind?
    private let log = Logger(subsystem: "app.somabar", category: "activities")

    private static var clock: Double {
        Date().timeIntervalSinceReferenceDate
    }

    // MARK: - Lifecycle

    func start(snapshot: ContextSnapshot) {
        guard !isStarted else { return }
        isStarted = true
        self.snapshot = snapshot
        lastProfile = profiles().active
        lastFocus = .some(snapshot.focus)
        charging.onPulse = { [weak self] text, symbol in self?.pulse(.charging, text: text, symbol: symbol) }
        nowPlaying.onChange = { [weak self] in self?.refresh() }
        drop.onDragChanged = { [weak self] _ in self?.refresh() }
        charging.start()
        syncSources()
        refresh()
        log.notice("Activities started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        charging.stop()
        nowPlaying.stop()
        drop.stop()
        tickTask?.cancel()
        tickTask = nil
    }

    /// A new notch surface (or none). The timer's changes come here from now on.
    func attach(_ surface: NotchSurface?) {
        self.surface = surface
        surface?.onTimerChanged = { [weak self] in self?.refresh() }
        drop.targetFrame = nil
        lastWinner = nil
        syncSources()
        refresh()
    }

    // MARK: - Inputs

    private var lastProfile: String?

    func contextChanged(_ next: ContextSnapshot) {
        let previous = snapshot
        snapshot = next
        if let lastFocus, lastFocus != next.focus {
            focusChanged(to: next.focus)
        }
        lastFocus = .some(next.focus)
        // A trigger may have switched the profile, and with it the activities switched on.
        let profile = profiles().active
        if profile != lastProfile {
            lastProfile = profile
            settingsChanged()
            return
        }
        guard previous.microphoneInUse != next.microphoneInUse || previous.cameraInUse != next.cameraInUse
            || previous.isScreenShared != next.isScreenShared || previous.runningApps != next.runningApps
            || previous.frontmostApp != next.frontmostApp
        else { return }
        refresh()
    }

    /// The profile or its notch settings changed.
    func settingsChanged() {
        syncSources()
        refresh()
    }

    /// Starts the sources the profile switched on and stops the others, so a switched-off
    /// activity costs nothing (and Now Playing sends no AppleScript).
    private func syncSources() {
        guard isStarted else { return }
        let settings = settings()
        nowPlaying.fetchesArtwork = settings.showsArtworkAndFileNames
        if settings.enabledActivities.contains(.nowPlaying) {
            nowPlaying.start()
            nowPlaying.settingsChanged()
        } else {
            nowPlaying.stop()
        }
        if settings.enabledActivities.contains(.dropToShare), surface != nil {
            drop.start()
        } else {
            drop.stop()
        }
    }

    // MARK: - Pulses

    private func pulse(_ kind: ActivityKind, text: String, symbol: String) {
        guard settings().enabledActivities.contains(kind), let surface else { return }
        surface.pulse(text: text, symbol: symbol)
    }

    /// N8: a pulse when the Focus changes.
    private func focusChanged(to focus: String?) {
        let text = focus.map { "Focus: \($0)" } ?? "Focus off"
        pulse(.focus, text: text, symbol: focus == nil ? "moon" : "moon.fill")
    }

    // MARK: - Choosing

    /// Rebuilds the live activities and shows the board's choice.
    func refresh() {
        guard isStarted else { return }
        let now = Self.clock
        let settings = settings()
        let activities = liveActivities(now: now, settings: settings)
        for kind in Set(startedAt.keys).subtracting(activities.map(\.kind)) {
            startedAt[kind] = nil
        }
        let board = ActivityBoard(settings: settings, isScreenShared: snapshot.isScreenShared)
        let selection = board.select(activities.map(\.live))
        let byKind = Dictionary(activities.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        let compact = selection.compact.flatMap { byKind[$0.kind]?.compact }
        var rows = selection.expanded.compactMap { byKind[$0.kind]?.row }
        if let paused = pausedTrackRow(now: now, settings: settings) {
            rows.append(paused)
        }
        if compact?.kind != lastWinner {
            lastWinner = compact?.kind
            let names = selection.expanded.map(\.kind.rawValue).joined(separator: ", ")
            log.info("Compact: \(compact?.kind.rawValue ?? "none", privacy: .public); live: \(names.isEmpty ? "none" : names, privacy: .public)")
        }
        let widened = compact?.kind == .dropToShare
        surface?.showActivities(compact: compact, rows: rows, widened: widened)
        drop.targetFrame = widened ? surface?.dropTargetFrame : nil
        updateTick(activities)
    }

    /// Every activity that is live right now, before the profile's switches.
    private func liveActivities(now: Double, settings: NotchSettings) -> [NotchActivity] {
        var result: [NotchActivity] = []
        if drop.isFileDragInProgress, surface != nil {
            result.append(dropActivity(now: now))
        }
        if let call = callActivity(now: now) {
            result.append(call)
        }
        if let timer = timerActivity(now: now) {
            result.append(timer)
        }
        if let track = nowPlaying.track, track.isPlaying {
            result.append(nowPlayingActivity(track, now: now, settings: settings))
        }
        if snapshot.isScreenShared {
            result.append(screenShareActivity(now: now))
        }
        return result
    }

    private func since(_ kind: ActivityKind, now: Double) -> Double {
        if let started = startedAt[kind] { return started }
        startedAt[kind] = now
        return now
    }

    /// One second while something counts up or down; the timer ticks on the surface.
    private func updateTick(_ activities: [NotchActivity]) {
        let needsTick = activities.contains { $0.kind == .call || $0.kind == .nowPlaying }
        if needsTick, tickTask == nil {
            tickTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.refresh()
                }
            }
        } else if !needsTick {
            tickTask?.cancel()
            tickTask = nil
        }
    }

    // MARK: - N5 Drop to share

    private func dropActivity(now: Double) -> NotchActivity {
        NotchActivity(
            kind: .dropToShare, rank: .dropTarget, startedAt: since(.dropToShare, now: now),
            compact: CompactPresentation(
                kind: .dropToShare, symbol: "square.and.arrow.up", text: "Share",
                accessibilityLabel: "Drop files on the notch to share them"),
            row: nil)
    }

    // MARK: - N3 Call

    private func callActivity(now: Double) -> NotchActivity? {
        let microphone = snapshot.microphoneInUse
        let camera = snapshot.cameraInUse
        guard microphone || camera else { return nil }
        let started = since(.call, now: now)
        let length = ActivityText.elapsed(seconds: now - started)
        let app = CallSource.name(runningApps: snapshot.runningApps, frontmostApp: snapshot.frontmostApp)
        let device = CallSource.deviceTitle(microphone: microphone, camera: camera)
        let symbol = camera ? "video.fill" : "mic.fill"
        let spoken = (app.map { "Call in \($0)" } ?? device) + ", \(length)"
        return NotchActivity(
            kind: .call, rank: .call, startedAt: started,
            compact: CompactPresentation(
                kind: .call, symbol: symbol, text: length, tint: .inUse, showsDot: true, accessibilityLabel: spoken),
            // Mute and hang up need each app's private API, so the row has no controls.
            row: ActivityRow(
                id: .call, symbol: symbol, title: app ?? device,
                detail: app == nil ? length : "\(length) · \(device)", tint: .inUse))
    }

    // MARK: - N2 Timer

    private func timerActivity(now: Double) -> NotchActivity? {
        guard let timer = surface?.timer, timer.isActive else { return nil }
        let remaining = timer.remaining(at: now)
        let text = timer.display(at: now)
        let label = timer.isPaused ? "Timer paused, \(text) left" : "Timer, \(text) left"
        return NotchActivity(
            kind: .timer, rank: .timer(remaining: remaining, isRunning: timer.isRunning), startedAt: since(.timer, now: now),
            compact: CompactPresentation(
                kind: .timer, symbol: timer.isPaused ? "pause.circle" : "timer", text: text,
                tint: timer.isPaused ? .secondary : .primary, accessibilityLabel: label),
            // Expanded has the timer's own row with its presets.
            row: nil)
    }

    // MARK: - N1 Now Playing

    private func nowPlayingActivity(_ track: NowPlayingTrack, now: Double, settings: NotchSettings) -> NotchActivity {
        let remaining = track.remaining(at: now)
        let text = remaining.map(ActivityText.remaining(seconds:)) ?? ""
        let label = [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " by ")
            + (remaining.map { ", \(ActivityText.elapsed(seconds: $0)) left" } ?? "")
        return NotchActivity(
            kind: .nowPlaying, rank: .nowPlaying, startedAt: since(.nowPlaying, now: now),
            compact: CompactPresentation(
                kind: .nowPlaying, symbol: "music.note", text: text,
                image: image(for: track, settings: settings), accessibilityLabel: "Now playing: \(label)"),
            row: nowPlayingRow(track, now: now, settings: settings))
    }

    /// A paused track has no Compact but stays in Expanded, so it can be resumed.
    private func pausedTrackRow(now: Double, settings: NotchSettings) -> ActivityRow? {
        guard let track = nowPlaying.track, !track.isPlaying, settings.enabledActivities.contains(.nowPlaying) else { return nil }
        return nowPlayingRow(track, now: now, settings: settings)
    }

    private func nowPlayingRow(_ track: NowPlayingTrack, now: Double, settings: NotchSettings) -> ActivityRow {
        var detail = track.artist
        if let remaining = track.remaining(at: now) {
            detail += (detail.isEmpty ? "" : " · ") + ActivityText.remaining(seconds: remaining)
        }
        let watcher = nowPlaying
        return ActivityRow(
            id: .nowPlaying, symbol: "music.note", title: track.title, detail: detail,
            image: image(for: track, settings: settings), progress: track.progress(at: now),
            controls: [
                ActivityControl(symbol: "backward.fill", label: "Previous track") { watcher.send(.previous) },
                ActivityControl(symbol: track.isPlaying ? "pause.fill" : "play.fill", label: track.isPlaying ? "Pause" : "Play") {
                    watcher.send(.playPause)
                },
                ActivityControl(symbol: "forward.fill", label: "Next track") { watcher.send(.next) },
            ])
    }

    /// Music's artwork when the profile shows artwork; otherwise, and for Spotify, the app icon.
    private func image(for track: NowPlayingTrack, settings: NotchSettings) -> NSImage? {
        if settings.showsArtworkAndFileNames, let artwork = nowPlaying.artwork {
            return artwork
        }
        return nowPlaying.appIcon(for: track.player)
    }

    // MARK: - N10 Screen-share guard

    private func screenShareActivity(now: Double) -> NotchActivity {
        let profiles = profiles()
        var controls: [ActivityControl] = []
        if let before = profiles.beforeTriggers {
            let switchProfile = switchProfile
            controls.append(ActivityControl(symbol: "arrow.uturn.backward", label: "Back to \(before)") { switchProfile(before) })
        }
        return NotchActivity(
            kind: .screenShareGuard, rank: .screenShareGuard, startedAt: since(.screenShareGuard, now: now),
            compact: CompactPresentation(
                kind: .screenShareGuard, symbol: "rectangle.on.rectangle", text: "Live", tint: .recording, showsDot: true,
                accessibilityLabel: "The screen is being shared"),
            row: ActivityRow(
                id: .screenShareGuard, symbol: "rectangle.on.rectangle", title: "Screen is being shared",
                detail: "Profile: \(profiles.active)", tint: .recording, controls: controls))
    }
}
