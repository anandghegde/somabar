import AppKit
import SomabarCore
import SwiftUI

enum KeyRecorderResult {
    case combo(KeyCombo)
    case cleared
    /// The key cannot be registered as a hot key; the reason is shown.
    case unsupported(String)
}

/// A button that records the next key combination pressed while it has focus.
struct KeyRecorder: NSViewRepresentable {
    var combo: KeyCombo?
    var onRecord: @MainActor (KeyRecorderResult) -> Void
    var onRecordingChanged: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> KeyRecorderButton {
        let button = KeyRecorderButton()
        button.onRecord = onRecord
        button.onRecordingChanged = onRecordingChanged
        button.combo = combo
        return button
    }

    func updateNSView(_ button: KeyRecorderButton, context: Context) {
        button.onRecord = onRecord
        button.onRecordingChanged = onRecordingChanged
        button.combo = combo
    }
}

/// Click to record; the next combo with ⌃, ⌥ or ⌘ is reported. Somabar's own hot keys are
/// unregistered while recording (`onRecordingChanged`), or Carbon would take the keystroke.
final class KeyRecorderButton: NSButton {
    var onRecord: (@MainActor (KeyRecorderResult) -> Void)?
    var onRecordingChanged: (@MainActor (Bool) -> Void)?
    var combo: KeyCombo? {
        didSet { updateTitle() }
    }

    private var resignKeyObserver: NSObjectProtocol?
    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            updateTitle()
            onRecordingChanged?(isRecording)
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not used")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { isRecording = false }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Recording also ends when the window stops being key: another app came forward or the
    /// window closed. The button keeps first responder then, and the hot keys would stay off
    /// until Settings came back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        guard let window else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
        isRecording = false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = Self.modifiers(from: flags)
        let key = KeyCodes.key(forVirtualKey: event.keyCode)
        if modifiers.isEmpty {
            switch key {
            case "delete": onRecord?(.cleared)
            case "escape": break
            default: NSSound.beep(); return
            }
            window?.makeFirstResponder(nil)
            return
        }
        guard let key else {
            onRecord?(.unsupported("Somabar can't use that key for a shortcut"))
            window?.makeFirstResponder(nil)
            return
        }
        guard modifiers.contains(where: { $0 != .shift }) else {
            onRecord?(.unsupported("Add ⌃, ⌥ or ⌘ to the shortcut"))
            window?.makeFirstResponder(nil)
            return
        }
        onRecord?(.combo(KeyCombo(key: key, modifiers: modifiers)))
        window?.makeFirstResponder(nil)
    }

    private func updateTitle() {
        title = isRecording ? "Type shortcut…" : (combo?.display ?? "Record Shortcut")
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> [Modifier] {
        var result: [Modifier] = []
        if flags.contains(.control) { result.append(.control) }
        if flags.contains(.option) { result.append(.option) }
        if flags.contains(.shift) { result.append(.shift) }
        if flags.contains(.command) { result.append(.command) }
        return result
    }
}
