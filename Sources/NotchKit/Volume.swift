// MARK: - Keys

/// The three volume keys, as macOS reports them in a system-defined event (subtype 8).
public enum VolumeKey: Int, Equatable, Sendable {
    /// `NX_KEYTYPE_SOUND_UP`
    case up = 0
    /// `NX_KEYTYPE_SOUND_DOWN`
    case down = 1
    /// `NX_KEYTYPE_MUTE`
    case mute = 7

    /// The subtype of a system-defined event that carries the media and volume keys
    /// (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`).
    public static let auxControlSubtype = 8

    /// A volume key press or release from a system-defined event's `data1`; nil for any other
    /// key. The key code sits in the high 16 bits; the low 16 hold the state (0xA down, 0xB up)
    /// and a repeat bit.
    public static func decode(data1: Int) -> VolumeKeyPress? {
        let code = (data1 & 0xFFFF_0000) >> 16
        guard let key = VolumeKey(rawValue: code) else { return nil }
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        return VolumeKeyPress(key: key, isDown: state == 0xA, isRepeat: flags & 0x1 == 1)
    }
}

/// One press or release of a volume key.
public struct VolumeKeyPress: Equatable, Sendable {
    public var key: VolumeKey
    /// Down (and repeats while held); false for the release.
    public var isDown: Bool
    public var isRepeat: Bool
}

// MARK: - Stepping

/// Volume steps like the system's: sixteenths, or sixty-fourths with ⌥⇧. Pure.
public enum VolumeStep {
    public static let coarse: Float = 1.0 / 16
    public static let fine: Float = 1.0 / 64

    /// The next level up or down from `level`, on the step's grid and within 0...1. A level
    /// between two steps moves to the next one in the key's direction.
    public static func next(from level: Float, up: Bool, fine isFine: Bool) -> Float {
        let step = isFine ? fine : coarse
        let clamped = min(1, max(0, level))
        let position = clamped / step
        // A little slack so 0.37499994 counts as 6/16.
        let slack: Float = 0.001
        let target = up ? (position + slack).rounded(.down) + 1 : (position - slack).rounded(.up) - 1
        return min(1, max(0, target * step))
    }
}

// MARK: - Words

/// What the volume pulse shows. Pure.
public enum VolumeText {
    /// "45 %", rounded to the nearest percent.
    public static func percent(_ level: Float) -> String {
        "\(Int((min(1, max(0, level)) * 100).rounded())) %"
    }

    /// The speaker glyph: slashed when muted or at zero, then one to three waves.
    public static func symbol(level: Float, muted: Bool) -> String {
        if muted || level <= 0 { return "speaker.slash.fill" }
        if level < 1.0 / 3 { return "speaker.wave.1.fill" }
        if level < 2.0 / 3 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// The pulse's text: "45 %", or "Muted".
    public static func pulse(level: Float, muted: Bool) -> String {
        muted ? "Muted" : percent(level)
    }

    /// What VoiceOver hears.
    public static func accessibilityLabel(level: Float, muted: Bool) -> String {
        muted ? "Volume muted" : "Volume \(percent(level))"
    }
}
