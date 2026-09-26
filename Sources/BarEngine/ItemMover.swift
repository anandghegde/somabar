import AppKit
import ApplicationServices
import os

/// Moves one status item next to another without moving the pointer.
///
/// The bar accepts a ⌘-mouseDown addressed to an item's window (the window-ID fields set on the
/// event, the location off screen) and a mouseUp addressed to the target window at the point the
/// item should land. No drag events are needed; the window server lifts the item on the down and
/// places it on the up. The pointer clamps to a screen corner while the item is lifted, so the
/// cursor is hidden for the duration and warped back afterwards. This is the technique Ice uses
/// and the only one that works on macOS 26 (hand-made drags are ignored).
///
/// Needs Accessibility trust, which is what lets the process post events to the session.
@MainActor
public enum ItemMover {
    public enum Side: Sendable, Equatable {
        case leftOf
        case rightOf
    }

    public struct Destination: Sendable, Equatable {
        public var side: Side
        public var target: CGWindowID

        public init(_ side: Side, _ target: CGWindowID) {
            self.side = side
            self.target = target
        }
    }

    public enum MoveError: Error, Equatable {
        case permissionMissing
        case notIdle([InputSafety.Blocker])
        case noEventSource
        case busy
        case windowMissing(CGWindowID)
        /// The item did not land where asked, after every attempt.
        case notVerified(itemFrame: CGRect, targetFrame: CGRect)
    }

    nonisolated static let attempts = 3
    /// How far from the target edge the moved item may land and still count.
    public nonisolated static let tolerance: CGFloat = 4
    /// Somewhere off every screen: the down event's location is irrelevant once the window
    /// fields are set, and this keeps it from hitting anything if they are ignored.
    nonisolated static let pickUpPoint = CGPoint(x: 20_000, y: 20_000)
    /// The private field the bar reads the target window from.
    nonisolated static let windowIDField = CGEventField(rawValue: 0x33)!
    nonisolated static let liftTimeout: Duration = .milliseconds(300)
    nonisolated static let settleTimeout: Duration = .milliseconds(800)

    /// True while a move is in flight, so click handlers can ignore the synthetic events.
    public private(set) static var isMoving = false
    private static var eventSerial: Int64 = 0
    private static let log = Logger(subsystem: "app.somabar", category: "ItemMover")

    /// Puts the item with `windowID` next to the destination's target, retrying a few times.
    /// The bar must be idle: no mouse button down, no typing, pointer off the bar.
    public static func move(_ windowID: CGWindowID, to destination: Destination) async throws {
        guard AXIsProcessTrusted() else { throw MoveError.permissionMissing }
        guard !isMoving else { throw MoveError.busy }
        let blockers = InputSafety.blockers()
        guard blockers.isEmpty else { throw MoveError.notIdle(blockers) }
        guard let source = makeSource() else { throw MoveError.noEventSource }

        isMoving = true
        let pointer = CGEvent(source: nil)?.location
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let pointer { CGWarpMouseCursorPosition(pointer) }
            CGDisplayShowCursor(CGMainDisplayID())
            isMoving = false
        }

        var lastError = MoveError.windowMissing(windowID)
        for attempt in 1...attempts {
            do {
                try await moveOnce(windowID, to: destination, source: source)
                log.debug("Moved window \(windowID) \(String(describing: destination.side), privacy: .public) \(destination.target) on attempt \(attempt)")
                return
            } catch let error as MoveError {
                lastError = error
                if case .windowMissing = error { throw error }
                log.debug("Move of window \(windowID) attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError
    }

    /// Clicks an item the way a person would, to open its menu when it has no Accessibility
    /// element to press. The pointer is left over the item, where the menu hangs from. Posted
    /// while `isMoving` holds so Somabar's own gesture handlers ignore the click.
    public static func click(_ windowID: CGWindowID, at point: CGPoint) async throws {
        guard AXIsProcessTrusted() else { throw MoveError.permissionMissing }
        guard !isMoving else { throw MoveError.busy }
        guard let source = makeSource() else { throw MoveError.noEventSource }
        isMoving = true
        defer { isMoving = false }
        CGWarpMouseCursorPosition(point)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = event(type, at: point, flags: [], windowID: windowID, source: source) else {
                throw MoveError.noEventSource
            }
            // AppKit ignores a synthetic click without a click count.
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cgSessionEventTap)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    // MARK: - Geometry, pure

    /// Where the mouseUp lands: the target's edge the item should touch, on its centre line.
    public nonisolated static func endPoint(for side: Side, target: CGRect) -> CGPoint {
        switch side {
        case .leftOf: CGPoint(x: target.minX, y: target.midY)
        case .rightOf: CGPoint(x: target.maxX, y: target.midY)
        }
    }

    /// True when the item sits against the requested edge of the target, in the same row.
    public nonisolated static func isVerified(item: CGRect, target: CGRect, side: Side, tolerance: CGFloat = tolerance) -> Bool {
        guard abs(item.midY - target.midY) <= max(item.height, target.height) else { return false }
        switch side {
        case .leftOf: return abs(item.maxX - target.minX) <= tolerance
        case .rightOf: return abs(item.minX - target.maxX) <= tolerance
        }
    }

    // MARK: - One attempt

    private static func moveOnce(_ windowID: CGWindowID, to destination: Destination, source: CGEventSource) async throws {
        let before = StatusWindows.all()
        guard let item = before.first(where: { $0.windowID == windowID }) else { throw MoveError.windowMissing(windowID) }
        guard let target = before.first(where: { $0.windowID == destination.target }) else {
            throw MoveError.windowMissing(destination.target)
        }
        if isVerified(item: item.bounds, target: target.bounds, side: destination.side) { return }

        guard let down = event(.leftMouseDown, at: pickUpPoint, flags: .maskCommand, windowID: windowID, source: source) else {
            throw MoveError.noEventSource
        }
        down.post(tap: .cgSessionEventTap)
        await waitForLift(of: windowID, from: item.bounds)

        // The bar re-lays out once the item is lifted; aim at where the target is now.
        let targetNow = StatusWindows.all().first { $0.windowID == destination.target }?.bounds ?? target.bounds
        let point = endPoint(for: destination.side, target: targetNow)
        guard let up = event(.leftMouseUp, at: point, flags: [], windowID: destination.target, source: source) else {
            throw MoveError.noEventSource
        }
        up.post(tap: .cgSessionEventTap)

        if let (itemNow, targetAfter) = await waitForSettle(item: windowID, target: destination.target, side: destination.side) {
            _ = (itemNow, targetAfter)
            return
        }

        let after = StatusWindows.all()
        let itemAfter = after.first { $0.windowID == windowID }?.bounds ?? item.bounds
        let targetLast = after.first { $0.windowID == destination.target }?.bounds ?? targetNow
        if isLifted(itemAfter, from: item.bounds) {
            // Still in the air: put it down where it came from rather than leave it held.
            let home = CGPoint(x: item.bounds.midX, y: item.bounds.midY)
            event(.leftMouseUp, at: home, flags: [], windowID: windowID, source: source)?.post(tap: .cgSessionEventTap)
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw MoveError.notVerified(itemFrame: itemAfter, targetFrame: targetLast)
    }

    /// Waits up to `liftTimeout` for the item's window to move, which is how the bar shows it
    /// has been picked up. Proceeds regardless: the up event must always follow the down.
    private static func waitForLift(of windowID: CGWindowID, from bounds: CGRect) async {
        let deadline = ContinuousClock.now + liftTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            if let now = StatusWindows.all().first(where: { $0.windowID == windowID }), now.bounds != bounds { return }
        }
    }

    /// Polls up to `settleTimeout` for the item to sit against the target.
    private static func waitForSettle(item: CGWindowID, target: CGWindowID, side: Side) async -> (CGRect, CGRect)? {
        let deadline = ContinuousClock.now + settleTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let windows = StatusWindows.all()
            guard let itemNow = windows.first(where: { $0.windowID == item }),
                  let targetNow = windows.first(where: { $0.windowID == target }) else { continue }
            if isVerified(item: itemNow.bounds, target: targetNow.bounds, side: side) {
                return (itemNow.bounds, targetNow.bounds)
            }
        }
        return nil
    }

    private nonisolated static func isLifted(_ bounds: CGRect, from original: CGRect) -> Bool {
        abs(bounds.minY - original.minY) > StatusWindows.maxHeight
    }

    // MARK: - Events

    private static func makeSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        let permitted: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0
        return source
    }

    private static func event(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags, windowID: CGWindowID, source: CGEventSource) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            return nil
        }
        eventSerial += 1
        event.flags = flags
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
        event.setIntegerValueField(.eventSourceUserData, value: eventSerial)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        event.setIntegerValueField(windowIDField, value: Int64(windowID))
        return event
    }
}
