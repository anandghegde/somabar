import Foundation

/// The reveal gestures (M2) as pure state: hover on the empty bar, click on the empty bar and
/// scroll down on the bar. The app feeds it pointer, click and scroll events and applies the
/// actions it returns. Nothing here touches AppKit, so every rule is testable.
public struct RevealGestureRecognizer: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case reveal
        case hide
    }

    /// Where the pointer is, as far as the gestures care.
    public enum PointerSpot: Equatable, Sendable {
        case emptyBar
        /// On the bar, over an item or the app menus.
        case item
        case offBar
    }

    /// Points of scroll, in one direction within the gap, that count as a gesture.
    public static let scrollThreshold: CGFloat = 20
    /// A pause longer than this between scroll events starts a new gesture.
    public static let scrollGapSeconds: TimeInterval = 0.4
    /// After a scroll gesture fires, further scrolling is ignored for this long.
    public static let scrollCooldownSeconds: TimeInterval = 1
    public static let maxHoverDelayMilliseconds = 800

    public var gestures: RevealGestures
    /// When the armed hover fires, in the caller's clock. Nil while the pointer is elsewhere.
    public private(set) var hoverDeadline: TimeInterval?
    /// True once the bar has been revealed while the pointer has been on it. A bar hidden under
    /// a resting pointer stays hidden: hover reveals again only after the pointer leaves the bar.
    private var revealedThisVisit = false
    private var scrollTotal: CGFloat = 0
    private var lastScrollAt: TimeInterval = -.infinity
    private var lastScrollActionAt: TimeInterval = -.infinity

    public init(gestures: RevealGestures) {
        self.gestures = gestures
    }

    /// The configured hover delay, clamped to something usable.
    public var hoverDelay: TimeInterval {
        TimeInterval(min(max(gestures.hoverDelayMilliseconds, 0), Self.maxHoverDelayMilliseconds)) / 1000
    }

    /// The pointer moved. On the empty bar with hover on, arms the deadline once; anywhere
    /// else, disarms it. Leaving the bar ends the visit.
    public mutating func pointerMoved(to spot: PointerSpot, revealed: Bool, at now: TimeInterval) {
        if revealed {
            revealedThisVisit = true
        }
        switch spot {
        case .offBar:
            revealedThisVisit = false
            hoverDeadline = nil
        case .item:
            hoverDeadline = nil
        case .emptyBar:
            guard gestures.hoverEmptyBar, !revealedThisVisit else {
                hoverDeadline = nil
                return
            }
            if hoverDeadline == nil {
                hoverDeadline = now + hoverDelay
            }
        }
    }

    /// Fires the armed hover once its deadline has passed.
    public mutating func tick(at now: TimeInterval) -> Action? {
        guard let deadline = hoverDeadline, now >= deadline else { return nil }
        hoverDeadline = nil
        revealedThisVisit = true
        return .reveal
    }

    /// A click on the bar that hit nothing: reveal, or hide when revealed. A click is deliberate,
    /// so a hover armed under it never fires. The caller drops the action if the click opened a menu.
    public mutating func click(onEmptyBar: Bool, revealed: Bool) -> Action? {
        hoverDeadline = nil
        if revealed {
            revealedThisVisit = true
        }
        guard gestures.clickEmptyBar, onEmptyBar else { return nil }
        revealedThisVisit = true
        return revealed ? .hide : .reveal
    }

    /// A scroll on the bar. `deltaY` follows `NSEvent.scrollingDeltaY`: negative scrolls a page
    /// down, whatever the natural-scrolling setting. Down reveals, up hides.
    public mutating func scroll(deltaY: CGFloat, at now: TimeInterval, revealed: Bool) -> Action? {
        if revealed {
            revealedThisVisit = true
        }
        guard gestures.scrollDownOnBar else { return nil }
        if now - lastScrollAt > Self.scrollGapSeconds {
            scrollTotal = 0
        }
        lastScrollAt = now
        scrollTotal += deltaY
        guard now - lastScrollActionAt > Self.scrollCooldownSeconds, abs(scrollTotal) >= Self.scrollThreshold else { return nil }
        let down = scrollTotal < 0
        scrollTotal = 0
        lastScrollActionAt = now
        let action: Action? = down ? (revealed ? nil : .reveal) : (revealed ? .hide : nil)
        if action != nil {
            hoverDeadline = nil
            revealedThisVisit = true
        }
        return action
    }
}
