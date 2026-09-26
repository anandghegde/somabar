/// M2: each gesture can be turned on or off.
public struct RevealGestures: Codable, Equatable, Sendable {
    public var hoverEmptyBar = false
    /// 0 to 800 ms.
    public var hoverDelayMilliseconds = 300
    public var clickEmptyBar = true
    public var scrollDownOnBar = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case hoverEmptyBar, hoverDelayMilliseconds, clickEmptyBar, scrollDownOnBar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RevealGestures()
        hoverEmptyBar = try c.decodeIfPresent(Bool.self, forKey: .hoverEmptyBar) ?? defaults.hoverEmptyBar
        hoverDelayMilliseconds = try c.decodeIfPresent(Int.self, forKey: .hoverDelayMilliseconds) ?? defaults.hoverDelayMilliseconds
        clickEmptyBar = try c.decodeIfPresent(Bool.self, forKey: .clickEmptyBar) ?? defaults.clickEmptyBar
        scrollDownOnBar = try c.decodeIfPresent(Bool.self, forKey: .scrollDownOnBar) ?? defaults.scrollDownOnBar
    }
}

public enum Spacing: String, Codable, Sendable {
    case `default`
    case snug
    case tight
}

/// M12: display rules.
public struct DisplayRules: Codable, Equatable, Sendable {
    /// Show everything on a display wider than this; nil turns the rule off.
    public var showEverythingAbovePoints: Int? = 2560
    public var trayOnlyOnBuiltInDisplay = true
    /// Somabar only manages the primary display's bar today, so every other display is already
    /// left untouched; nothing reads this until multi-display support exists.
    public var leaveInactiveDisplaysUntouched = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showEverythingAbovePoints, trayOnlyOnBuiltInDisplay, leaveInactiveDisplaysUntouched
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DisplayRules()
        // An explicit null turns the rule off; a missing key keeps the default.
        if c.contains(.showEverythingAbovePoints) {
            showEverythingAbovePoints = try c.decodeIfPresent(Int.self, forKey: .showEverythingAbovePoints)
        } else {
            showEverythingAbovePoints = defaults.showEverythingAbovePoints
        }
        trayOnlyOnBuiltInDisplay = try c.decodeIfPresent(Bool.self, forKey: .trayOnlyOnBuiltInDisplay) ?? defaults.trayOnlyOnBuiltInDisplay
        leaveInactiveDisplaysUntouched = try c.decodeIfPresent(Bool.self, forKey: .leaveInactiveDisplaysUntouched) ?? defaults.leaveInactiveDisplaysUntouched
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Encode the nil so a turned-off rule survives a round trip.
        try c.encode(showEverythingAbovePoints, forKey: .showEverythingAbovePoints)
        try c.encode(trayOnlyOnBuiltInDisplay, forKey: .trayOnlyOnBuiltInDisplay)
        try c.encode(leaveInactiveDisplaysUntouched, forKey: .leaveInactiveDisplaysUntouched)
    }
}

/// Settings that are not part of a profile. Every field has a default so an older file loads.
public struct Preferences: Codable, Equatable, Sendable {
    public var revealGestures = RevealGestures()
    /// M3: rehide after this many seconds.
    public var rehideAfterSeconds: Double = 8
    public var rehideWhenMenuCloses = true
    public var rehideWhenAppChanges = true
    /// One switch that removes springs and wobble.
    public var stillMode = false
    /// M5: dividers can be hidden once set up.
    public var showDividers = true
    public var spacing: Spacing = .default
    public var displayRules = DisplayRules()
    public var notchGuard = true
    public var notchSurface = true
    /// Draw a notch on a display without one, for the notch surface.
    public var drawnNotch = false
    /// Real item images need Screen Recording; off means app icons and titles (M18).
    public var realItemImages = false
    /// Hardware addresses of routers the user has marked as known, sorted.
    public var knownRouters: [String] = []
    /// Post a system notification when a trigger starts holding or switches profile.
    public var notifyWhenTriggerFires = false

    public init() {}

    public mutating func addKnownRouter(_ address: String) {
        guard !knownRouters.contains(address) else { return }
        knownRouters.append(address)
        knownRouters.sort()
    }

    private enum CodingKeys: String, CodingKey {
        case revealGestures, rehideAfterSeconds, rehideWhenMenuCloses, rehideWhenAppChanges, stillMode
        case showDividers, spacing, displayRules, notchGuard, notchSurface, realItemImages, knownRouters
        case drawnNotch
        case notifyWhenTriggerFires
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        revealGestures = try c.decodeIfPresent(RevealGestures.self, forKey: .revealGestures) ?? defaults.revealGestures
        rehideAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .rehideAfterSeconds) ?? defaults.rehideAfterSeconds
        rehideWhenMenuCloses = try c.decodeIfPresent(Bool.self, forKey: .rehideWhenMenuCloses) ?? defaults.rehideWhenMenuCloses
        rehideWhenAppChanges = try c.decodeIfPresent(Bool.self, forKey: .rehideWhenAppChanges) ?? defaults.rehideWhenAppChanges
        stillMode = try c.decodeIfPresent(Bool.self, forKey: .stillMode) ?? defaults.stillMode
        showDividers = try c.decodeIfPresent(Bool.self, forKey: .showDividers) ?? defaults.showDividers
        spacing = try c.decodeIfPresent(Spacing.self, forKey: .spacing) ?? defaults.spacing
        displayRules = try c.decodeIfPresent(DisplayRules.self, forKey: .displayRules) ?? defaults.displayRules
        notchGuard = try c.decodeIfPresent(Bool.self, forKey: .notchGuard) ?? defaults.notchGuard
        notchSurface = try c.decodeIfPresent(Bool.self, forKey: .notchSurface) ?? defaults.notchSurface
        drawnNotch = try c.decodeIfPresent(Bool.self, forKey: .drawnNotch) ?? defaults.drawnNotch
        realItemImages = try c.decodeIfPresent(Bool.self, forKey: .realItemImages) ?? defaults.realItemImages
        knownRouters = try c.decodeIfPresent([String].self, forKey: .knownRouters) ?? defaults.knownRouters
        notifyWhenTriggerFires = try c.decodeIfPresent(Bool.self, forKey: .notifyWhenTriggerFires) ?? defaults.notifyWhenTriggerFires
    }
}
