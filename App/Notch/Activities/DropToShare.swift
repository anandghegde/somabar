import AppKit
import os

/// N5: while a file is being dragged anywhere, the notch widens into a drop target; a file
/// released on it opens the share menu (AirDrop is one of its services). Nothing is kept.
///
/// A global monitor sees `leftMouseDragged`, which only fires while a button is held and
/// something is being dragged, so it costs nothing at idle. The first moments of each drag look
/// at the drag pasteboard for file URLs; once a file drag is seen, a mouse-up monitor and a
/// button check (the drag session can swallow the mouse-up) are installed until it ends.
@MainActor
final class DropToShareWatcher: NSObject {
    /// How long into a drag the pasteboard is looked at; a file drag writes it at the start.
    static let detectionSeconds = 0.6
    static let buttonCheckSeconds = 0.5
    static let dropGraceSeconds = 0.4

    /// Called when a file drag starts or ends.
    var onDragChanged: (@MainActor (Bool) -> Void)?

    private(set) var isFileDragInProgress = false
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var watchdog: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var gestureStartedAt: Double?
    private var checkedChangeCount: Int?
    private var panel: DropTargetPanel?
    private var sharingPicker: NSSharingServicePicker?
    private let log = Logger(subsystem: "app.somabar", category: "activities")

    /// The monitor blocks are plain and run on the main thread; they reach the watcher through
    /// this, as `NotchSurface` does.
    private static weak var shared: DropToShareWatcher?

    func start() {
        guard dragMonitor == nil else { return }
        Self.shared = self
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in
            MainActor.assumeIsolated { DropToShareWatcher.shared?.mouseDragged() }
        }
    }

    func stop() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
        }
        dragMonitor = nil
        endDrag()
        hideTask?.cancel()
        sharingPicker = nil
        hidePanel()
        if Self.shared === self {
            Self.shared = nil
        }
    }

    /// Where the drop target sits, in AppKit screen coordinates; nil hides it.
    var targetFrame: CGRect? {
        didSet {
            guard targetFrame != oldValue else { return }
            if let targetFrame, isFileDragInProgress {
                showPanel(at: targetFrame)
            } else if targetFrame == nil, sharingPicker == nil {
                hidePanel()
            }
        }
    }

    // MARK: - Detecting a file drag

    private func mouseDragged() {
        let now = ProcessInfo.processInfo.systemUptime
        if gestureStartedAt == nil {
            gestureStartedAt = now
            installUpMonitor()
        }
        guard !isFileDragInProgress, let started = gestureStartedAt, now - started <= Self.detectionSeconds else { return }
        let pasteboard = NSPasteboard(name: .drag)
        let changeCount = pasteboard.changeCount
        guard changeCount != checkedChangeCount else { return }
        checkedChangeCount = changeCount
        guard pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        isFileDragInProgress = true
        log.info("File drag started; the notch is a drop target")
        onDragChanged?(true)
        if let targetFrame {
            showPanel(at: targetFrame)
        }
    }

    /// Only during a drag: ends it on mouse-up, or when no button is held any more.
    private func installUpMonitor() {
        guard upMonitor == nil else { return }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            MainActor.assumeIsolated { DropToShareWatcher.shared?.gestureEnded() }
        }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.buttonCheckSeconds))
                guard !Task.isCancelled, let self else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.gestureEnded()
                    return
                }
            }
        }
    }

    private func gestureEnded() {
        endDrag()
    }

    private func endDrag() {
        if let upMonitor {
            NSEvent.removeMonitor(upMonitor)
        }
        upMonitor = nil
        watchdog?.cancel()
        watchdog = nil
        gestureStartedAt = nil
        guard isFileDragInProgress else { return }
        isFileDragInProgress = false
        onDragChanged?(false)
        // The mouse-up can arrive before the drop does; the panel stays a moment longer. A drop
        // that opened the share menu keeps it until the menu closes.
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.dropGraceSeconds))
            guard !Task.isCancelled, let self, !self.isFileDragInProgress, self.sharingPicker == nil else { return }
            self.hidePanel()
        }
    }

    // MARK: - The drop target

    private func showPanel(at frame: CGRect) {
        hideTask?.cancel()
        let panel = panel ?? DropTargetPanel { [weak self] urls in self?.dropped(urls) }
        self.panel = panel
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func dropped(_ urls: [URL]) {
        guard !urls.isEmpty, let view = panel?.contentView else { return }
        log.info("Dropped \(urls.count) file(s) on the notch; opening the share menu")
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        sharingPicker = picker
        endDrag()
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

extension DropToShareWatcher: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            sharingPicker = nil
            hidePanel()
        }
    }
}

/// A clear panel over the widened notch that takes file drops. Shown only during a file drag.
final class DropTargetPanel: NSPanel {
    init(onDrop: @escaping @MainActor ([URL]) -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the notch surface's panel, which lets clicks through.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = DropTargetView(onDrop: onDrop)
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Accepts file URLs; draws nothing, since the notch surface draws the target.
final class DropTargetView: NSView {
    private let onDrop: @MainActor ([URL]) -> Void

    init(onDrop: @escaping @MainActor ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Nearly clear, so the window server hit-tests the whole panel.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.01).setFill()
        dirtyRect.fill()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(in: sender).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !fileURLs(in: sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(in: sender)
        guard !urls.isEmpty else { return false }
        // After the drag session has finished, so the menu is not tied to it.
        Task { @MainActor [onDrop] in onDrop(urls) }
        return true
    }

    private func fileURLs(in info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
