import CoreGraphics

/// What the engine saw in the real bar: every item with its frame, and where the dividers are.
///
/// x values use the top-left origin. A divider's x is its right edge, so the test works whether
/// the divider is at its visible width or inflated to push items off-screen.
public struct ObservedBar: Equatable, Sendable {
    public var items: [PlacedItem]
    public var hiddenDividerX: CGFloat
    public var tuckedDividerX: CGFloat

    public init(items: [PlacedItem], hiddenDividerX: CGFloat, tuckedDividerX: CGFloat) {
        self.items = items
        self.hiddenDividerX = hiddenDividerX
        self.tuckedDividerX = tuckedDividerX
    }

    /// The section an item sits in, by position. Tucked and Locked share the same region, so
    /// `known` decides between them.
    public func section(of item: PlacedItem, known: Layout) -> Section {
        let x = item.frame.midX
        if x < tuckedDividerX {
            return known.section(of: item.key) == .locked ? .locked : .tucked
        }
        if x < hiddenDividerX {
            return .hidden
        }
        return .shown
    }

    /// The layout the bar shows right now, in bar order. Items macOS manages are left in Shown.
    public func layout(known: Layout) -> Layout {
        var layout = Layout()
        for item in items.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            let section: Section = SystemItems.isManagedByMacOS(item.key) ? .shown : self.section(of: item, known: known)
            layout[section].append(item.key)
        }
        return layout
    }
}

/// One item that is not where the layout says.
public struct Drift: Equatable, Sendable {
    public var item: ItemKey
    public var expected: Section
    public var actual: Section

    public init(item: ItemKey, expected: Section, actual: Section) {
        self.item = item
        self.expected = expected
        self.actual = actual
    }
}

/// M16: the layout is the source of truth and the bar is reconciled to it. These are the pure
/// comparisons; the engine decides when to act on them (at most once per event, never in a loop).
public enum Reconciler {
    /// Items in the bar that no layout knows yet. They land in Shown with a dot on the glyph.
    public static func newItems(observed: [ItemKey], layout: Layout) -> [ItemKey] {
        observed.filter { !layout.contains($0) && !SystemItems.isManagedByMacOS($0) }
    }

    /// Items in the layout whose app is not showing them right now. Their slot is kept.
    public static func missingItems(observed: [ItemKey], layout: Layout) -> [ItemKey] {
        let present = Set(observed)
        return layout.allItems.filter { !present.contains($0) }
    }

    /// Items present in both whose section differs. System-managed items never count.
    public static func drift(desired: Layout, observed: Layout) -> [Drift] {
        var result: [Drift] = []
        for key in observed.allItems where !SystemItems.isManagedByMacOS(key) {
            guard let expected = desired.section(of: key), let actual = observed.section(of: key), expected != actual else {
                continue
            }
            result.append(Drift(item: key, expected: expected, actual: actual))
        }
        return result
    }

    /// The drifted items in the order to move them so that each section ends up in the
    /// layout's order. A move drops an item at its section's divider end: the left end of
    /// Shown, the right end of everything else. Items moved later push earlier ones away from
    /// the divider, so Shown is moved last-to-first and the other sections first-to-last.
    public static func orderedMoves(_ drifts: [Drift], desired: Layout) -> [Drift] {
        var result: [Drift] = []
        for section in Section.barOrder {
            let order = desired[section]
            var moves = drifts.filter { $0.expected == section }
            moves.sort { (order.firstIndex(of: $0.item) ?? .max) < (order.firstIndex(of: $1.item) ?? .max) }
            if section == .shown {
                moves.reverse()
            }
            result += moves
        }
        return result
    }
}
