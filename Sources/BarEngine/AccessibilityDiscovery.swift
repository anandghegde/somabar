import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization

/// A status item as its app describes it through Accessibility.
public struct AXItem: Sendable {
    public var title: String
    /// Global coordinates, origin top-left.
    public var frame: CGRect
    public var handle: AXHandle

    public init(title: String, frame: CGRect, handle: AXHandle) {
        self.title = title
        self.frame = frame
        self.handle = handle
    }
}

/// Reads status items through each app's `AXExtrasMenuBar`. Needs Accessibility trust.
public enum AccessibilityDiscovery {
    /// Apps that do not answer quickly are skipped rather than stalling the scan.
    public static let messagingTimeoutSeconds: Float = 0.25

    /// Status items for every process given, keyed by pid. Processes without any are left out.
    /// Apps are asked in parallel, so a bar-wide scan costs about one slow app's timeout rather
    /// than the sum. Safe to call off the main thread.
    public static func items(forPIDs pids: [pid_t]) -> [pid_t: [AXItem]] {
        let result = Mutex<[pid_t: [AXItem]]>([:])
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            let pid = pids[index]
            let items = items(forPID: pid)
            guard !items.isEmpty else { return }
            result.withLock { $0[pid] = items }
        }
        return result.withLock { $0 }
    }

    /// The status items one app exposes, left to right. Empty when the app has none, does not
    /// support Accessibility, or Somabar is not trusted. Items with no size are not in the bar
    /// (Control Center lists its collapsed modules this way) and are left out.
    public static func items(forPID pid: pid_t) -> [AXItem] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeoutSeconds)
        guard let menuBar = element(kAXExtrasMenuBarAttribute, of: app),
              let children = elements(kAXChildrenAttribute, of: menuBar) else { return [] }
        return children.compactMap { child -> AXItem? in
            guard let frame = frame(of: child), frame.width > 0, frame.height > 0 else { return nil }
            let title = string(kAXTitleAttribute, of: child)
                ?? string(kAXDescriptionAttribute, of: child)
                ?? string(kAXIdentifierAttribute, of: child)
                ?? ""
            return AXItem(title: title.trimmingCharacters(in: .whitespacesAndNewlines), frame: frame, handle: AXHandle(child))
        }
        .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The element's frame in global top-left coordinates.
    public static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = value(kAXPositionAttribute, of: element),
              let sizeRef = value(kAXSizeAttribute, of: element),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeDowncast(positionRef, to: AXValue.self)
        let sizeValue = unsafeDowncast(sizeRef, to: AXValue.self)
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// The right edge of an app's menu titles (Apple menu through Help) in global top-left
    /// coordinates, so a hit test knows where the empty bar starts. Nil without trust or when
    /// the app has no menu bar.
    public static func appMenusMaxX(forPID pid: pid_t) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeoutSeconds)
        guard let menuBar = element(kAXMenuBarAttribute, of: app),
              let titles = elements(kAXChildrenAttribute, of: menuBar) else { return nil }
        return titles.compactMap(frame(of:)).filter { $0.width > 0 }.map(\.maxX).max()
    }

    // MARK: - Attribute helpers

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let ref = value(attribute, of: element), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(ref, to: AXUIElement.self)
    }

    private static func elements(_ attribute: String, of element: AXUIElement) -> [AXUIElement]? {
        guard let ref = value(attribute, of: element), let array = ref as? [AnyObject] else { return nil }
        return array.compactMap { object in
            CFGetTypeID(object) == AXUIElementGetTypeID() ? unsafeDowncast(object, to: AXUIElement.self) : nil
        }
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        guard let ref = value(attribute, of: element), let string = ref as? String, !string.isEmpty else { return nil }
        return string
    }
}
