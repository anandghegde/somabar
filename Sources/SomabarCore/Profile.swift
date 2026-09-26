import Foundation

/// The notch live activities (N1 to N11).
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case nowPlaying
    case timer
    case call
    case charging
    case dropToShare
    case transfers
    case volumeHUD
    case focus
    case hiddenItemsTray
    case screenShareGuard
    case agentActivity

    /// The P0 activities, on by default.
    public static let defaultsOn: Set<ActivityKind> = [
        .nowPlaying, .timer, .call, .charging, .dropToShare, .hiddenItemsTray,
    ]
}

/// What the notch shows while a profile is active.
public struct NotchSettings: Codable, Equatable, Sendable {
    public var enabledActivities: Set<ActivityKind>
    /// Off in Presenting: artwork and file names are never visible to viewers.
    public var showsArtworkAndFileNames: Bool

    public init(enabledActivities: Set<ActivityKind>, showsArtworkAndFileNames: Bool) {
        self.enabledActivities = enabledActivities
        self.showsArtworkAndFileNames = showsArtworkAndFileNames
    }

    public static let everyday = NotchSettings(enabledActivities: ActivityKind.defaultsOn, showsArtworkAndFileNames: true)
    public static let presenting = NotchSettings(enabledActivities: ActivityKind.defaultsOn, showsArtworkAndFileNames: false)
    public static let focus = NotchSettings(enabledActivities: [.call, .timer], showsArtworkAndFileNames: true)

    private enum CodingKeys: String, CodingKey {
        case enabledActivities, showsArtworkAndFileNames
    }

    // Encoded sorted so the .somabar file is stable between saves.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabledActivities.map(\.rawValue).sorted(), forKey: .enabledActivities)
        try container.encode(showsArtworkAndFileNames, forKey: .showsArtworkAndFileNames)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String].self, forKey: .enabledActivities) ?? []
        // Unknown kinds from a newer file are dropped rather than failing the whole document.
        enabledActivities = Set(raw.compactMap(ActivityKind.init(rawValue:)))
        showsArtworkAndFileNames = try container.decodeIfPresent(Bool.self, forKey: .showsArtworkAndFileNames) ?? true
    }
}

/// A saved layout plus notch settings. Somabar ships with three that users can edit.
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var layout: Layout
    /// Where an item that appears for the first time lands while this profile is active.
    public var newItemsGoTo: Section
    public var notch: NotchSettings
    /// Items the notch guard (M6) has hidden while this profile is active, with the width each
    /// took, so they come back once the bar has room again.
    public var notchGuarded: [GuardedItem]

    public init(
        id: UUID = UUID(), name: String, layout: Layout, newItemsGoTo: Section, notch: NotchSettings, notchGuarded: [GuardedItem] = []
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.newItemsGoTo = newItemsGoTo
        self.notch = notch
        self.notchGuarded = notchGuarded
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, layout, newItemsGoTo, notch, notchGuarded
    }

    // Files written before the guard existed have no `notchGuarded`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        layout = try container.decode(Layout.self, forKey: .layout)
        newItemsGoTo = try container.decode(Section.self, forKey: .newItemsGoTo)
        notch = try container.decode(NotchSettings.self, forKey: .notch)
        notchGuarded = try container.decodeIfPresent([GuardedItem].self, forKey: .notchGuarded) ?? []
    }

    public static let everydayName = "Everyday"
    public static let presentingName = "Presenting"
    public static let focusName = "Focus"

    /// The default layout.
    public static func everyday(layout: Layout = Layout()) -> Profile {
        Profile(name: everydayName, layout: layout, newItemsGoTo: .shown, notch: .everyday)
    }

    /// Everything but Clock, Battery, Wi-Fi and Control Center goes to Tucked. Locked stays locked.
    public static func presenting(from everyday: Layout) -> Profile {
        var layout = Layout()
        for key in everyday.allItems {
            let target: Section
            if SystemItems.isPresentingEssential(key) || SystemItems.isManagedByMacOS(key) {
                target = .shown
            } else if everyday.section(of: key) == .locked {
                target = .locked
            } else {
                target = .tucked
            }
            layout[target].append(key)
        }
        return Profile(name: presentingName, layout: layout, newItemsGoTo: .tucked, notch: .presenting)
    }

    /// Only the Clock (and the Control Center button macOS pins beside it) is shown. Tucked and
    /// Locked keep their items; everything else is Hidden.
    public static func focus(from everyday: Layout) -> Profile {
        var layout = Layout()
        for key in everyday.allItems {
            let target: Section
            if SystemItems.isPinnedByMacOS(key) {
                target = .shown
            } else if let section = everyday.section(of: key), section.isAlwaysHidden {
                target = section
            } else {
                target = .hidden
            }
            layout[target].append(key)
        }
        return Profile(name: focusName, layout: layout, newItemsGoTo: .hidden, notch: .focus)
    }
}
