// The icon-change condition: which items to watch, and when two captures of an item count as
// different. Capturing is the app's job (it needs Screen Recording); the rules live here so
// they are unit-tested.

import Foundation

public enum IconChange {
    /// How long the icon-change condition holds after an item's icon changes. A change during
    /// the hold starts it again.
    public static let holdSeconds: Double = 10
}

// MARK: - Hold

/// The items whose icon changed recently, and when they stop holding. The app keeps one, feeds
/// it each detected change, and arms a one-shot timer for `until`.
public struct IconChangeHold: Equatable, Sendable {
    public private(set) var keys: Set<ItemKey> = []
    /// When the hold ends; nil while nothing holds.
    public private(set) var until: Date?

    public init() {}

    /// Adds `changed` to what holds and restarts the hold from `now`. True when the set grew,
    /// which is when the triggers need evaluating again.
    @discardableResult
    public mutating func noteChange(_ changed: Set<ItemKey>, at now: Date, holdSeconds: Double = IconChange.holdSeconds) -> Bool {
        guard !changed.isEmpty else { return false }
        until = now.addingTimeInterval(holdSeconds)
        let before = keys.count
        keys.formUnion(changed)
        return keys.count != before
    }

    /// Clears the hold once `now` has reached `until`. True when something was cleared.
    @discardableResult
    public mutating func expire(at now: Date) -> Bool {
        guard let until, now >= until else { return false }
        self = IconChangeHold()
        return true
    }
}

// MARK: - Watched items

extension Condition {
    /// The items whose icons this condition, or anything inside it, watches.
    public var watchedIcons: Set<ItemKey> {
        switch self {
        case .iconChanged(let key): [key]
        case .not(let inner): inner.watchedIcons
        case .allOf(let inner), .anyOf(let inner): inner.reduce(into: []) { $0.formUnion($1.watchedIcons) }
        default: []
        }
    }
}

extension SomabarDocument {
    /// The items an enabled trigger watches for an icon change. Empty means nothing is captured.
    public var watchedIcons: Set<ItemKey> {
        triggers.filter(\.isEnabled).reduce(into: []) { $0.formUnion($1.condition.watchedIcons) }
    }
}

// MARK: - Fingerprint

/// A cheap perceptual hash of an item's image: the image squeezed to `side` × `side`, kept as two
/// planes of bytes. The first is coverage (alpha), so a template glyph that flips between light
/// and dark with the wallpaper stays the same; the second is colourfulness (the spread between
/// the strongest and weakest channel, times alpha), so a dot turning red counts as a change.
public struct IconFingerprint: Equatable, Sendable {
    public static let side = 16
    public static let planeSize = side * side
    /// A pixel differs when a plane moves by more than this, out of 255. Anti-aliasing and
    /// subpixel redraws of the same glyph stay under it.
    public static let pixelTolerance = 40
    /// Two fingerprints differ when more pixels than this differ; a badge dot is well over it.
    public static let changedPixelsTolerance = 5

    /// `planeSize` coverage bytes followed by `planeSize` colour bytes.
    public let bytes: [UInt8]

    /// Nil unless `bytes` holds exactly two planes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.planeSize * 2 else { return nil }
        self.bytes = bytes
    }

    /// Nothing drawn: an off-screen window macOS would not render, or a failed capture.
    public var isBlank: Bool {
        !bytes.prefix(Self.planeSize).contains { $0 > 8 }
    }

    /// How many pixels differ by more than `pixelTolerance` in either plane.
    public func changedPixels(from other: IconFingerprint) -> Int {
        var count = 0
        for index in 0..<Self.planeSize {
            let alpha = abs(Int(bytes[index]) - Int(other.bytes[index]))
            let colour = abs(Int(bytes[index + Self.planeSize]) - Int(other.bytes[index + Self.planeSize]))
            if alpha > Self.pixelTolerance || colour > Self.pixelTolerance {
                count += 1
            }
        }
        return count
    }

    /// True when the two captures show a different icon, not a redraw of the same one.
    public func differs(from other: IconFingerprint) -> Bool {
        changedPixels(from: other) > Self.changedPixelsTolerance
    }
}
