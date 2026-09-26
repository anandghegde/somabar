import ApplicationServices
import AppKit
import CoreAudio
import NotchKit
import os

/// N3's controls, from public API only. There is no universal "mute this call" or "hang up":
///
/// - Mute is the default input device's own mute (CoreAudio `kAudioDevicePropertyMute`, input
///   scope), or its volume set to zero where the device has no mute. It silences the
///   microphone for every app. When the call ends Somabar puts back what it changed.
/// - Hang up presses the call app's own "Leave Meeting" (or similar) menu item through
///   Accessibility, which Somabar already has. The button only shows when such an item exists
///   and is enabled.
@MainActor
final class CallControls {
    private let log = Logger(subsystem: "app.somabar", category: "activities")

    /// What Somabar changed on which device, so the end of the call can undo it.
    private enum Change {
        case mute(AudioObjectID)
        case volume(AudioObjectID, Float32)
    }

    private var change: Change?
    private var isCallLive = false
    private var hangUpApp: String?
    private var hangUpItem: AXUIElement?
    private var lastMenuSearch: Double = -.infinity
    /// Menus are searched at most this often while a call has no hang-up item yet.
    private static let menuSearchInterval = 5.0

    // MARK: - Call lifecycle

    /// Call on every refresh. The end of a call undoes Somabar's mute.
    func update(isCallLive live: Bool, callApp: String?, now: Double) {
        if isCallLive, !live {
            restoreMicrophone()
            hangUpItem = nil
            hangUpApp = nil
            lastMenuSearch = -.infinity
        }
        isCallLive = live
        guard live else { return }
        if callApp != hangUpApp {
            hangUpApp = callApp
            hangUpItem = nil
            lastMenuSearch = -.infinity
        }
        if hangUpItem == nil, callApp != nil, now - lastMenuSearch >= Self.menuSearchInterval {
            lastMenuSearch = now
            hangUpItem = findHangUpItem()
        }
    }

    // MARK: - Microphone

    /// The default input's mute; nil when there is no input device or it can be neither muted
    /// nor turned down.
    var isMicrophoneMuted: Bool? {
        guard let device = Self.defaultInputDevice else { return nil }
        if let muted = Self.uint32(device, kAudioDevicePropertyMute) {
            return muted != 0
        }
        if let volume = Self.float(device, kAudioDevicePropertyVolumeScalar) {
            return volume <= 0.001
        }
        return nil
    }

    func toggleMicrophone() {
        guard let muted = isMicrophoneMuted else { return }
        setMicrophone(muted: !muted)
    }

    private func setMicrophone(muted: Bool) {
        guard let device = Self.defaultInputDevice else { return }
        if Self.isSettable(device, kAudioDevicePropertyMute) {
            if Self.setUInt32(device, kAudioDevicePropertyMute, muted ? 1 : 0) {
                change = muted ? .mute(device) : nil
                log.notice("Microphone \(muted ? "muted" : "unmuted", privacy: .public) from the notch")
            }
            return
        }
        guard Self.isSettable(device, kAudioDevicePropertyVolumeScalar) else { return }
        if muted {
            let before = Self.float(device, kAudioDevicePropertyVolumeScalar) ?? 1
            if Self.setFloat(device, kAudioDevicePropertyVolumeScalar, 0) {
                change = .volume(device, max(before, 0.05))
                log.notice("Microphone turned down from the notch")
            }
        } else {
            let restore: Float32 = if case .volume(device, let level) = change { level } else { 0.75 }
            if Self.setFloat(device, kAudioDevicePropertyVolumeScalar, restore) {
                change = nil
            }
        }
    }

    /// Puts back what Somabar changed, on the device it changed, if the person has not already.
    private func restoreMicrophone() {
        switch change {
        case .mute(let device):
            if Self.uint32(device, kAudioDevicePropertyMute) == 1 {
                _ = Self.setUInt32(device, kAudioDevicePropertyMute, 0)
            }
            log.notice("Call ended: microphone unmuted again")
        case .volume(let device, let level):
            if (Self.float(device, kAudioDevicePropertyVolumeScalar) ?? 1) <= 0.001 {
                _ = Self.setFloat(device, kAudioDevicePropertyVolumeScalar, level)
            }
            log.notice("Call ended: microphone level put back")
        case nil:
            break
        }
        change = nil
    }

    // MARK: - Hang up

    var canHangUp: Bool { hangUpItem != nil }

    /// Presses the menu item found for the call app, after checking it is still there.
    func hangUp() {
        guard let item = hangUpItem, Self.bool(item, kAXEnabledAttribute) != false else {
            hangUpItem = findHangUpItem()
            return
        }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        log.notice("Hang up pressed in \(self.hangUpApp ?? "?", privacy: .public): \(result == .success ? "done" : "failed", privacy: .public)")
        hangUpItem = nil
        lastMenuSearch = -.infinity
    }

    /// Walks the call app's menu bar, two levels deep, for an enabled item whose title leaves the
    /// call (`CallHangUp`).
    private func findHangUpItem() -> AXUIElement? {
        guard let bundleID = hangUpApp, AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let menuBar = Self.element(element, kAXMenuBarAttribute) else { return nil }
        var found: [(title: String, item: AXUIElement)] = []
        for barItem in Self.children(menuBar) {
            for menu in Self.children(barItem) {
                for item in Self.children(menu) {
                    guard let title = Self.string(item, kAXTitleAttribute),
                          CallHangUp.matchRank(title: title, bundleID: bundleID) != nil,
                          Self.bool(item, kAXEnabledAttribute) != false
                    else { continue }
                    found.append((title, item))
                }
            }
        }
        guard let best = CallHangUp.bestTitle(in: found.map(\.title), bundleID: bundleID) else { return nil }
        log.info("Hang up available in \(bundleID, privacy: .public): \(best, privacy: .public)")
        return found.first { $0.title == best }?.item
    }

    // MARK: - Accessibility helpers

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    // MARK: - CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static var defaultInputDevice: AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector, scope: kAudioDevicePropertyScopeInput)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func uint32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector, scope: kAudioDevicePropertyScopeInput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: UInt32) -> Bool {
        var address = address(selector, scope: kAudioDevicePropertyScopeInput)
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func float(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float32? {
        var address = address(selector, scope: kAudioDevicePropertyScopeInput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setFloat(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: Float32) -> Bool {
        var address = address(selector, scope: kAudioDevicePropertyScopeInput)
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}

// MARK: - The call row's controls

extension CallControls {
    /// Mute (when the input can be muted) and hang up (when the app's menu has it), plus the
    /// words for the row's detail.
    func rowControls(onChange: @escaping @MainActor () -> Void) -> (controls: [ActivityControl], muteText: String?) {
        var controls: [ActivityControl] = []
        let muted = isMicrophoneMuted
        if let muted {
            controls.append(ActivityControl(
                symbol: muted ? "mic.slash.fill" : "mic.fill",
                label: muted ? "Unmute microphone" : "Mute microphone"
            ) { [weak self] in
                self?.toggleMicrophone()
                onChange()
            })
        }
        if canHangUp {
            controls.append(ActivityControl(symbol: "phone.down.fill", label: "Hang up") { [weak self] in
                self?.hangUp()
                onChange()
            })
        }
        return (controls, muted == true ? "Microphone muted" : nil)
    }
}
