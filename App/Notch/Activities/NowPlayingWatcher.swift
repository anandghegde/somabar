import AppKit
import NotchKit
import os

/// N1: what Music or Spotify is playing, from public API only.
///
/// Both players post a distributed notification on every play, pause and track change, so
/// nothing is polled. MediaRemote, which would cover every player, is private and is not used.
/// Music's notification carries no position, so it is asked for once per notification over
/// AppleScript, as is the artwork; Spotify's carries the position, and its artwork is never
/// fetched because it would be a network call. The first AppleScript call makes macOS ask the
/// person for Automation permission; if they decline, the time and artwork are left out.
@MainActor
final class NowPlayingWatcher {
    /// Called on the main actor after the track or its state changed.
    var onChange: (@MainActor () -> Void)?
    /// Artwork is fetched only while this is true (`NotchSettings.showsArtworkAndFileNames`).
    var fetchesArtwork = false

    private(set) var track: NowPlayingTrack?
    /// Music's artwork for `track`, when it was fetched.
    private(set) var artwork: NSImage?
    private var artworkTrackID: String?
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "app.somabar", category: "activities")

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for player in MediaPlayer.allCases {
            let observer = center.addObserver(forName: Notification.Name(player.notificationName), object: nil, queue: .main) { [weak self] note in
                let now = Date().timeIntervalSinceReferenceDate
                let info = (note.userInfo as? [String: Any]) ?? [:]
                let parsed = NowPlayingTrack.parse(info, player: player, at: now)
                MainActor.assumeIsolated { self?.received(parsed, from: player) }
            }
            observers.append(observer)
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
        track = nil
        artwork = nil
        artworkTrackID = nil
    }

    /// The app's icon, used in place of artwork.
    func appIcon(for player: MediaPlayer) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Notifications

    private func received(_ parsed: NowPlayingTrack?, from player: MediaPlayer) {
        guard var parsed else {
            // Stopped, or quit. Another player's track stays.
            guard track?.player == player else { return }
            track = nil
            artwork = nil
            artworkTrackID = nil
            log.info("Now Playing: \(player.scriptName, privacy: .public) stopped")
            onChange?()
            return
        }
        // A paused player does not take over from one that is playing.
        if let track, track.player != player, track.isPlaying, !parsed.isPlaying { return }
        if parsed.player == .music, let position = readMusicPosition() {
            parsed.position = position
        }
        if parsed.id != track?.id {
            log.info("Now Playing: \(player.scriptName, privacy: .public) \(parsed.state.rawValue, privacy: .public)")
        }
        track = parsed
        updateArtwork()
        onChange?()
    }

    private func updateArtwork() {
        guard let track, track.player == .music, fetchesArtwork else {
            if !fetchesArtwork {
                artwork = nil
                artworkTrackID = nil
            }
            return
        }
        guard artworkTrackID != track.id else { return }
        artworkTrackID = track.id
        artwork = Self.run("tell application \"Music\" to get raw data of artwork 1 of current track", player: .music)
            .flatMap { $0.data.isEmpty ? nil : NSImage(data: $0.data) }
    }

    /// Call after `fetchesArtwork` changed.
    func settingsChanged() {
        updateArtwork()
    }

    private func readMusicPosition() -> Double? {
        Self.run("tell application \"Music\" to get player position", player: .music)?.doubleValue
    }

    // MARK: - Controls

    enum Command: String {
        case previous = "previous track"
        case playPause = "playpause"
        case next = "next track"
    }

    func send(_ command: Command) {
        guard let player = track?.player else { return }
        _ = Self.run("tell application \"\(player.scriptName)\" to \(command.rawValue)", player: player)
    }

    /// Moves the playhead: `set player position to …`, which Music and Spotify both take.
    func seek(to seconds: Double) {
        guard var current = track, seconds.isFinite else { return }
        let target = max(0, current.duration.map { min(seconds, $0) } ?? seconds)
        let script = "tell application \"\(current.player.scriptName)\" to set player position to \(String(format: "%.1f", target))"
        guard Self.run(script, player: current.player) != nil else { return }
        current.position = target
        current.readAt = Date().timeIntervalSinceReferenceDate
        track = current
        onChange?()
    }

    /// Runs a one-line script, only while the player is running: `tell application` would
    /// otherwise launch it.
    private static func run(_ source: String, player: MediaPlayer) -> NSAppleEventDescriptor? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty,
              let script = NSAppleScript(source: source)
        else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            Logger(subsystem: "app.somabar", category: "activities")
                .info("AppleScript to \(player.scriptName, privacy: .public) failed (\(number)); Automation may be off")
            return nil
        }
        return result
    }
}
