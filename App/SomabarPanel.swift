import AppKit

// MARK: - Shared panel

/// A borderless panel that takes the keyboard without activating Somabar, so the app the person
/// was using stays in front. The search palette and the Hidden items tray both use it.
final class SomabarPanel: NSPanel {
    /// ⎋, when no text field claims it first.
    var onCancel: (@MainActor () -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Rounded translucent backing with `content` pinned inside it.
    static func backing(for content: NSView, material: NSVisualEffectView.Material, cornerRadius: CGFloat) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }
}

/// Calls back on any click in another app, so a panel closes when the person clicks away. A
/// non-activating panel does not always lose key status when another app is clicked.
@MainActor
final class OutsideClickMonitor {
    private var monitor: Any?

    func start(_ onClick: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            MainActor.assumeIsolated { onClick() }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

/// App icons by bundle ID, falling back to the running process's icon for helpers without a bundle.
@MainActor
enum ItemIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String, pid: pid_t?) -> NSImage {
        if let cached = cache[bundleID] {
            return cached
        }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else if let pid, let running = NSRunningApplication(processIdentifier: pid)?.icon {
            icon = running
        } else {
            icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = icon
        return icon
    }
}
