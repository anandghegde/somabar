import CoreAudio
import Foundation
import os

/// N1's output picker: the audio devices that can play sound, and which is the default.
///
/// CoreAudio lists AirPlay speakers and connected Bluetooth headphones (AirPods) as devices
/// once macOS has them, so no private API is needed. The list is read once and then kept up to
/// date by CoreAudio listeners, only while Now Playing is on.
@MainActor
final class AudioOutputs {
    struct Device: Equatable, Identifiable {
        var id: AudioObjectID
        var name: String
        var transport: UInt32

        /// An SF Symbol for the kind of device.
        var symbol: String {
            switch transport {
            case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
            case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
            default: "hifispeaker"
            }
        }
    }

    /// Called after the list or the default changed.
    var onChange: (@MainActor () -> Void)?
    private(set) var devices: [Device] = []
    private(set) var defaultDevice: AudioObjectID?

    private var listener: AudioObjectPropertyListenerBlock?
    private let log = Logger(subsystem: "app.somabar", category: "activities")
    private static let watched = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        for selector in Self.watched {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        }
        listener = block
        reload()
    }

    func stop() {
        guard let listener else { return }
        for selector in Self.watched {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
        }
        self.listener = nil
        devices = []
        defaultDevice = nil
    }

    var defaultName: String? {
        devices.first { $0.id == defaultDevice }?.name
    }

    /// Makes `device` the default output for the whole Mac.
    func select(_ device: AudioObjectID) {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var value = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        if status != noErr {
            log.error("Could not switch the audio output (\(status))")
        }
    }

    // MARK: - Reading

    private func reload() {
        let next = Self.allDevices().filter { Self.hasOutput($0) && !Self.isHidden($0) }.map { id in
            Device(id: id, name: Self.name(of: id) ?? "Output \(id)", transport: Self.transport(of: id))
        }
        let nextDefault = Self.currentDefault()
        guard next != devices || nextDefault != defaultDevice else { return }
        devices = next
        defaultDevice = nextDefault
        onChange?()
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDevices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func currentDefault() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    /// A device with at least one output stream.
    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Aggregate and helper devices some apps create hide themselves.
    private static func isHidden(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyIsHidden, scope: kAudioObjectPropertyScopeGlobal)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func transport(of device: AudioObjectID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }
}
