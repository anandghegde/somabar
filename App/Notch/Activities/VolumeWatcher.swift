import AppKit
import AudioToolbox
import CoreAudio
import NotchKit
import os

/// N7: the volume HUD. Opt-in (`ActivityKind.volumeHUD` is off by default).
///
/// Observing: CoreAudio property listeners on the default output device (its virtual main
/// volume and mute) and on the system's choice of default output device. Nothing is polled.
/// Every change calls `onChange` with the new level, and the notch pulses a slim bar.
///
/// Replacing the system HUD: while `interceptsKeys` is on and Accessibility is trusted, an event
/// tap takes the volume keys (system-defined events, subtype 8) before macOS does, sets the
/// volume itself through CoreAudio in sixteenths (sixty-fourths with ⌥⇧) and toggles mute, so
/// the system's overlay never appears. A key is passed through untouched when the output
/// device's volume cannot be set (the system then shows its own "not supported" overlay), with
/// ⌥ alone (which opens Sound settings), or when the tap cannot be created. If Somabar stalls,
/// macOS disables the tap and the keys go back to the system; quitting removes it.
@MainActor
final class VolumeWatcher {
    /// The level (0...1) and mute state after a change.
    var onChange: (@MainActor (_ level: Float, _ muted: Bool) -> Void)?
    /// Whether a pulse can be shown now; when not, the keys go to the system so its overlay shows.
    var canShow: @MainActor () -> Bool = { true }

    private var isStarted = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var last: (level: Float, muted: Bool)?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let log = Logger(subsystem: "app.somabar", category: "activities")

    /// The watcher the event tap's C callback reaches; the tap runs on the main run loop.
    fileprivate static weak var current: VolumeWatcher?

    // MARK: - Lifecycle

    /// Starts listening; with `interceptsKeys`, also takes the volume keys when it can.
    func start(interceptsKeys: Bool) {
        if !isStarted {
            isStarted = true
            Self.current = self
            listenForDefaultDevice()
            attach(to: Self.defaultOutputDevice())
        }
        if interceptsKeys {
            installTap()
        } else {
            removeTap()
        }
    }

    func stop() {
        removeTap()
        guard isStarted else { return }
        isStarted = false
        detachFromDevice()
        if let systemListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, systemListener)
        }
        systemListener = nil
        last = nil
        if Self.current === self {
            Self.current = nil
        }
    }

    /// Whether the keys are being taken from the system right now.
    var isInterceptingKeys: Bool { tap != nil }

    // MARK: - CoreAudio listeners

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static let volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return device
    }

    private func listenForDefaultDevice() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultDeviceChanged() }
        }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr else {
            log.error("Volume: cannot listen for the default output device")
            return
        }
        systemListener = block
    }

    /// A new output device: follow it quietly, the way the system does not show its HUD either.
    private func defaultDeviceChanged() {
        attach(to: Self.defaultOutputDevice())
    }

    private func attach(to newDevice: AudioObjectID) {
        guard newDevice != device else { return }
        detachFromDevice()
        device = newDevice
        guard newDevice != AudioObjectID(kAudioObjectUnknown) else { return }
        // The virtual main volume and mute, plus the first two channels' volume for devices
        // that only report changes there.
        var addresses = [Self.address(Self.volumeSelector), Self.address(kAudioDevicePropertyMute)]
        for channel: AudioObjectPropertyElement in [1, 2] {
            addresses.append(AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel))
        }
        for var address in addresses {
            guard AudioObjectHasProperty(newDevice, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.deviceChanged() }
            }
            if AudioObjectAddPropertyListenerBlock(newDevice, &address, DispatchQueue.main, block) == noErr {
                deviceListeners.append((address, block))
            }
        }
        last = read()
    }

    private func detachFromDevice() {
        for (address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
        deviceListeners = []
        device = AudioObjectID(kAudioObjectUnknown)
    }

    /// The volume or mute changed, by the keys, Control Centre or an app.
    private func deviceChanged() {
        guard let reading = read() else { return }
        if let last, abs(last.level - reading.level) < 0.001, last.muted == reading.muted { return }
        last = reading
        onChange?(reading.level, reading.muted)
    }

    // MARK: - Reading and setting

    private func read() -> (level: Float, muted: Bool)? {
        guard let level = readVolume() else { return nil }
        return (level, readMute() ?? false)
    }

    private func readVolume() -> Float? {
        var address = Self.address(Self.volumeSelector)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private func readMute() -> Bool? {
        var address = Self.address(kAudioDevicePropertyMute)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }

    private func isSettable(_ selector: AudioObjectPropertySelector) -> Bool {
        var address = Self.address(selector)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr
        else { return false }
        return settable.boolValue
    }

    @discardableResult
    private func setVolume(_ level: Float) -> Bool {
        var address = Self.address(Self.volumeSelector)
        var value = Float32(min(1, max(0, level)))
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    @discardableResult
    private func setMute(_ muted: Bool) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    // MARK: - The volume keys

    private func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            log.notice("Volume: Accessibility is off, so the system volume overlay stays; Somabar only follows changes")
            return
        }
        let mask = CGEventMask(1) << CGEventMask(NSEvent.EventType.systemDefined.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: volumeTapCallback, userInfo: nil)
        else {
            log.error("Volume: cannot create the event tap; the system volume overlay stays")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        log.notice("Volume: taking the volume keys")
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
        log.notice("Volume: gave the volume keys back to the system")
    }

    /// macOS turned the tap off (it took too long, or secure input): turn it back on.
    fileprivate func tapWasDisabled() {
        guard let tap else { return }
        log.notice("Volume: the event tap was disabled; enabling it again")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true when the event was a volume key Somabar handled, so it is consumed.
    fileprivate func handleKey(_ press: VolumeKeyPress, flags: CGEventFlags) -> Bool {
        guard canShow() else { return false }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)).intersection(.deviceIndependentFlagsMask)
        // ⌥ alone opens Sound settings: the system's job.
        if modifiers.contains(.option), !modifiers.contains(.shift) { return false }
        switch press.key {
        case .up, .down:
            guard isSettable(Self.volumeSelector), let current = readVolume() else { return false }
            guard press.isDown else { return true }
            let fine = modifiers.contains(.option) && modifiers.contains(.shift)
            let level = VolumeStep.next(from: current, up: press.key == .up, fine: fine)
            if readMute() == true, isSettable(kAudioDevicePropertyMute) {
                setMute(false)
            }
            setVolume(level)
        case .mute:
            guard isSettable(kAudioDevicePropertyMute) else { return false }
            guard press.isDown, !press.isRepeat else { return true }
            setMute(!(readMute() ?? false))
        }
        // Pulse now, so a press at 100 % or 0 % still shows; the listener then sees no change.
        if let reading = read() {
            last = reading
            onChange?(reading.level, reading.muted)
        }
        return true
    }
}

/// The event tap's callback: C, so it captures nothing and reaches the watcher through
/// `VolumeWatcher.current`. It runs on the main run loop.
private func volumeTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { VolumeWatcher.current?.tapWasDisabled() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue) else {
        return Unmanaged.passUnretained(event)
    }
    // Decoded here so only plain values cross into the main actor.
    guard let nsEvent = NSEvent(cgEvent: event), Int(nsEvent.subtype.rawValue) == VolumeKey.auxControlSubtype,
          let press = VolumeKey.decode(data1: nsEvent.data1)
    else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    let consumed = MainActor.assumeIsolated { VolumeWatcher.current?.handleKey(press, flags: flags) ?? false }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
