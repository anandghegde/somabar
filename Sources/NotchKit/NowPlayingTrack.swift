/// The players Somabar can read without private API: both post a distributed notification on
/// every change and take AppleScript for the controls.
public enum MediaPlayer: String, CaseIterable, Sendable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    public var bundleID: String { rawValue }

    /// The application name AppleScript addresses.
    public var scriptName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }

    /// The distributed notification posted on every play, pause and track change.
    public var notificationName: String {
        switch self {
        case .music: "com.apple.Music.playerInfo"
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        }
    }
}

/// What is playing, from one player's notification. Pure: position is extrapolated from the
/// moment it was read, so the display ticks without asking the player again.
public struct NowPlayingTrack: Equatable, Sendable {
    public enum State: String, Sendable {
        case playing, paused, stopped
    }

    public var player: MediaPlayer
    /// Changes with the track; artwork is fetched once per id.
    public var id: String
    public var title: String
    public var artist: String
    public var state: State
    /// Seconds; nil when the player did not say (a stream).
    public var duration: Double?
    /// Seconds into the track when it was read; nil when unknown.
    public var position: Double?
    /// When `position` was read, on the caller's clock.
    public var readAt: Double

    public init(
        player: MediaPlayer, id: String, title: String, artist: String, state: State,
        duration: Double?, position: Double?, readAt: Double
    ) {
        self.player = player
        self.id = id
        self.title = title
        self.artist = artist
        self.state = state
        self.duration = duration
        self.position = position
        self.readAt = readAt
    }

    public var isPlaying: Bool { state == .playing }

    /// Seconds into the track at `now`, never past its end.
    public func position(at now: Double) -> Double? {
        guard let position else { return nil }
        let moved = isPlaying ? position + max(0, now - readAt) : position
        return duration.map { min(moved, $0) } ?? moved
    }

    public func remaining(at now: Double) -> Double? {
        guard let duration, let position = position(at: now) else { return nil }
        return max(0, duration - position)
    }

    /// 0...1 for a static progress bar; nil when there is no duration.
    public func progress(at now: Double) -> Double? {
        guard let duration, duration > 0, let position = position(at: now) else { return nil }
        return min(1, max(0, position / duration))
    }

    /// Reads a notification's `userInfo`. nil for a stop or an info dictionary without a title.
    ///
    /// Music sends "Player State", "Name", "Artist", "Total Time" (ms) and "PersistentID", but no
    /// position; Spotify sends "Duration" (ms), "Playback Position" (s) and "Track ID".
    public static func parse(_ info: [String: Any], player: MediaPlayer, at now: Double) -> NowPlayingTrack? {
        let stateText = (info["Player State"] as? String)?.lowercased() ?? ""
        guard let state = State(rawValue: stateText), state != .stopped,
              let title = info["Name"] as? String, !title.isEmpty
        else { return nil }
        let artist = info["Artist"] as? String ?? ""
        let milliseconds: Double? = switch player {
        case .music: number(info["Total Time"])
        case .spotify: number(info["Duration"])
        }
        let duration = milliseconds.flatMap { $0 > 0 ? $0 / 1000 : nil }
        let position = player == .spotify ? number(info["Playback Position"]) : nil
        let idKey = player == .music ? "PersistentID" : "Track ID"
        let id = info[idKey].map { "\($0)" } ?? "\(title)|\(artist)"
        return NowPlayingTrack(
            player: player, id: id, title: title, artist: artist, state: state,
            duration: duration, position: position, readAt: now)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as Int64: Double(value)
        default: nil
        }
    }
}
