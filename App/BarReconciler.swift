import AppKit
import BarEngine
import os
import SomabarCore

/// Moves items the bar shows in the wrong section next to the right divider (M16). One pass at
/// a time, with both sections revealed so every item has an on-screen window to address.
@MainActor
final class BarReconciler {
    struct Outcome: Equatable, CustomStringConvertible {
        var moved = 0
        var failed = 0
        var skipped = 0
        var stoppedForInput = false
        /// The layout changed under the pass, so it stopped rather than finish moving items
        /// toward a layout nobody wants any more.
        var abandoned = false

        var description: String {
            var text = "moved \(moved), failed \(failed), skipped \(skipped)"
            if stoppedForInput { text += ", stopped for input" }
            if abandoned { text += ", stopped because the layout changed" }
            return text
        }
    }

    static let idleWaitSeconds: Double = 10
    static let idlePollSeconds: Double = 0.25
    /// The bar re-lays out after a reveal; scanning before that reads stale frames.
    static let settleSeconds: Double = 0.5
    static let betweenMoves: Duration = .milliseconds(200)
    /// An item that would not move is left alone for this long.
    static let retryHoldSeconds: TimeInterval = 60
    /// An item asked to move again this soon after a successful move is treated as stuck.
    static let repeatWindowSeconds: TimeInterval = 10

    private(set) var isRunning = false
    private var heldUntil: [ItemKey: Date] = [:]
    /// Where each item was last moved to, and when. A second move to the same section right
    /// after means the item snapped back; a move somewhere else means the layout changed.
    private var movedAt: [ItemKey: (section: Section, at: Date)] = [:]
    private let engine: any BarEngine
    private let scan: @MainActor () async -> [DiscoveredItem]
    private let log = Logger(subsystem: "app.somabar", category: "Reconciler")

    init(engine: any BarEngine, scan: @escaping @MainActor () async -> [DiscoveredItem]) {
        self.engine = engine
        self.scan = scan
    }

    /// The drifts a pass would act on now: those not on hold after a failure.
    func actionable(_ drifts: [Drift]) -> [Drift] {
        let now = Date()
        return drifts.filter { drift in
            guard let until = heldUntil[drift.item] else { return true }
            return until <= now
        }
    }

    /// Reveals everything, scans, and moves each drifted item. Restores the reveal state after.
    ///
    /// Cancelling the task stops the pass after the move it is on and reports `abandoned`; the
    /// caller does that when the layout the pass works toward has changed.
    func run(desired: Layout) async -> Outcome {
        guard !isRunning else { return Outcome() }
        isRunning = true
        defer { isRunning = false }

        guard await waitForIdle() else {
            log.info("Bar not idle for \(Self.idleWaitSeconds) s; reconciling later")
            return Outcome(stoppedForInput: true)
        }
        guard !Task.isCancelled else { return Outcome(abandoned: true) }

        let wasHiddenRevealed = engine.isHiddenRevealed
        let wasTuckedRevealed = engine.isTuckedRevealed
        engine.setHiddenRevealed(true)
        engine.setTuckedRevealed(true)
        defer {
            engine.setTuckedRevealed(wasTuckedRevealed)
            engine.setHiddenRevealed(wasHiddenRevealed)
        }
        try? await Task.sleep(for: .seconds(Self.settleSeconds))
        guard !Task.isCancelled else { return Outcome(abandoned: true) }

        guard let hiddenDivider = engine.ownWindow(.hiddenDivider), let tuckedDivider = engine.ownWindow(.tuckedDivider),
              let boundaries = engine.dividerBoundaries, boundaries.tucked < boundaries.hidden else {
            log.error("Somabar's dividers are missing or out of order; not moving anything")
            return Outcome()
        }
        let dividers = Dividers(hidden: hiddenDivider.windowID, tucked: tuckedDivider.windowID)
        let items = await scan()
        let observed = ObservedBar(items: items.filter(\.isIdentified).map(\.placed), hiddenDividerX: boundaries.hidden, tuckedDividerX: boundaries.tucked)
        let drifts = Reconciler.drift(desired: desired, observed: observed.layout(known: desired))
        let moves = Reconciler.orderedMoves(actionable(drifts), desired: desired)
        var outcome = Outcome(skipped: drifts.count - moves.count)

        for drift in moves {
            guard !Task.isCancelled else {
                outcome.abandoned = true
                break
            }
            guard let item = items.first(where: { $0.key == drift.item }) else { continue }
            guard await move(item, for: drift, dividers: dividers, outcome: &outcome) else { break }
            try? await Task.sleep(for: Self.betweenMoves)
        }
        return outcome
    }

    private struct Dividers {
        var hidden: CGWindowID
        var tucked: CGWindowID
    }

    /// Moves one item, or holds it when it will not stay put. Returns false when the pass has
    /// to stop because the person started using the bar.
    private func move(_ item: DiscoveredItem, for drift: Drift, dividers: Dividers, outcome: inout Outcome) async -> Bool {
        if let last = movedAt[drift.item], last.section == drift.expected, Date().timeIntervalSince(last.at) < Self.repeatWindowSeconds {
            hold(drift.item, "moved to \(drift.expected.displayName) \(Int(Date().timeIntervalSince(last.at))) s ago and drifted again")
            outcome.failed += 1
            return true
        }
        do {
            let destination = Self.destination(for: drift.expected, hiddenDivider: dividers.hidden, tuckedDivider: dividers.tucked)
            try await ItemMover.move(item.windowID, to: destination)
            movedAt[drift.item] = (drift.expected, Date())
            outcome.moved += 1
            let path = "\(drift.actual.displayName) → \(drift.expected.displayName)"
            log.notice("Moved \(drift.item.description, privacy: .public): \(path, privacy: .public)")
        } catch ItemMover.MoveError.notIdle(let blockers) {
            log.info("Stopped reconciling; the bar is in use: \(String(describing: blockers), privacy: .public)")
            outcome.stoppedForInput = true
            return false
        } catch {
            hold(drift.item, String(describing: error))
            outcome.failed += 1
        }
        return true
    }

    static func destination(for section: Section, hiddenDivider: CGWindowID, tuckedDivider: CGWindowID) -> ItemMover.Destination {
        switch section {
        case .shown: ItemMover.Destination(.rightOf, hiddenDivider)
        case .hidden: ItemMover.Destination(.leftOf, hiddenDivider)
        case .tucked, .locked: ItemMover.Destination(.leftOf, tuckedDivider)
        }
    }

    private func hold(_ key: ItemKey, _ reason: String) {
        heldUntil[key] = Date().addingTimeInterval(Self.retryHoldSeconds)
        log.error("Could not move \(key.description, privacy: .public): \(reason, privacy: .public). Trying again in \(Int(Self.retryHoldSeconds)) s")
    }

    private func waitForIdle() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(Self.idleWaitSeconds)
        while !InputSafety.isIdle {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .seconds(Self.idlePollSeconds))
        }
        return true
    }
}
