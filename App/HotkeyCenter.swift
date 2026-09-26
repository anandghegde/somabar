import AppKit
import Carbon.HIToolbox
import os
import SomabarCore

/// "SMBR": marks Somabar's hot keys in Carbon's event stream.
private let hotkeySignature: OSType = 0x534D_4252

/// Global hot keys through Carbon's `RegisterEventHotKey`, which needs no permission and does
/// not see any other keystroke (M17).
@MainActor
final class HotkeyCenter {
    var onAction: (@MainActor (HotkeyAction) -> Void)?
    /// A per-item or per-group hot key (M11) fired.
    var onTarget: (@MainActor (HotKeyTarget) -> Void)?

    /// What a registration does when its keys are pressed.
    private enum Binding {
        case action(HotkeyAction)
        case target(HotKeyTarget)
    }

    private var handler: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, binding: Binding)] = [:]
    private var nextID: UInt32 = 1
    private let log = Logger(subsystem: "app.somabar", category: "Hotkeys")

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotkeyHandler, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        if status != noErr {
            log.error("Could not install the hot key handler (\(status))")
        }
    }

    /// Replaces every registration: the actions' hot keys and the per-item ones. Combos that
    /// cannot be registered are logged and skipped.
    func register(_ hotkeys: [Hotkey], items: [ItemHotKey] = []) {
        unregisterAll()
        for hotkey in hotkeys {
            guard let combo = hotkey.combo else { continue }
            register(combo, for: .action(hotkey.action), name: hotkey.action.displayName)
        }
        for hotkey in items {
            guard let combo = hotkey.combo else { continue }
            register(combo, for: .target(hotkey.target), name: Self.name(of: hotkey.target))
        }
    }

    private func register(_ combo: KeyCombo, for binding: Binding, name: String) {
        guard let keyCode = KeyCodes.virtualKey(for: combo.key) else {
            log.error("No key code for \(combo.display, privacy: .public); skipping \(name, privacy: .public)")
            return
        }
        let id = EventHotKeyID(signature: hotkeySignature, id: nextID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, KeyCodes.carbonModifiers(combo.modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("Could not register \(combo.display, privacy: .public) (\(status)); another app may own it")
            return
        }
        registrations[nextID] = (ref, binding)
        log.notice("Registered \(combo.display, privacy: .public) for \(name, privacy: .public)")
        nextID += 1
    }

    private static func name(of target: HotKeyTarget) -> String {
        switch target {
        case .item(let key): "open \(key.description)"
        case .group(let id): "open group \(id.uuidString)"
        }
    }

    func unregisterAll() {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        guard let registration = registrations[id] else { return }
        switch registration.binding {
        case .action(let action):
            log.notice("Hot key fired: \(action.displayName, privacy: .public)")
            onAction?(action)
        case .target(let target):
            log.notice("Hot key fired: \(Self.name(of: target), privacy: .public)")
            onTarget?(target)
        }
    }
}

private func hotkeyHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotkeySignature else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    // Carbon delivers application-target events on the main thread.
    MainActor.assumeIsolated {
        center.fire(id: hotKeyID.id)
    }
    return noErr
}

/// Virtual key codes for the ANSI layout, plus menu key equivalents for display.
enum KeyCodes {
    private static let virtualKeys: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28,
        ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "tab": 0x30,
        "space": 0x31, "`": 0x32, "delete": 0x33, "escape": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    ]

    static func virtualKey(for key: String) -> UInt32? {
        virtualKeys[key.lowercased()]
    }

    /// The reverse, for the Settings recorder: only keys Somabar can register come back.
    static func key(forVirtualKey code: UInt16) -> String? {
        virtualKeys.first { $0.value == UInt32(code) }?.key
    }

    static func carbonModifiers(_ modifiers: [Modifier]) -> UInt32 {
        modifiers.reduce(0) { mask, modifier in
            switch modifier {
            case .control: mask | UInt32(controlKey)
            case .option: mask | UInt32(optionKey)
            case .shift: mask | UInt32(shiftKey)
            case .command: mask | UInt32(cmdKey)
            }
        }
    }

    static func modifierFlags(_ modifiers: [Modifier]) -> NSEvent.ModifierFlags {
        modifiers.reduce([]) { flags, modifier in
            switch modifier {
            case .control: flags.union(.control)
            case .option: flags.union(.option)
            case .shift: flags.union(.shift)
            case .command: flags.union(.command)
            }
        }
    }

    /// The string `NSMenuItem.keyEquivalent` wants for a combo's key.
    static func menuKeyEquivalent(for key: String) -> String {
        func functionKey(_ code: Int) -> String {
            Unicode.Scalar(UInt16(code)).map { String(Character($0)) } ?? ""
        }
        switch key.lowercased() {
        case "up": return functionKey(NSUpArrowFunctionKey)
        case "down": return functionKey(NSDownArrowFunctionKey)
        case "left": return functionKey(NSLeftArrowFunctionKey)
        case "right": return functionKey(NSRightArrowFunctionKey)
        case "space": return " "
        case "return": return "\r"
        case "escape": return "\u{1B}"
        case "tab": return "\t"
        case "delete": return "\u{8}"
        default: return key.lowercased()
        }
    }
}
