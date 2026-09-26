import CoreAudio
import CoreMediaIO
import Foundation
import os

/// Whether any app is using a microphone or a camera, read from the same device properties
/// macOS uses for its orange and green dots. Reading them needs no permission and captures
/// nothing.
///
/// The microphone comes from CoreAudio's process list: any process that is running input.
/// The camera comes from CoreMediaIO: any camera device that is running somewhere.
@MainActor
final class MediaWatcher {
    private(set) var microphoneInUse = false
    private(set) var cameraInUse = false
    /// Called on the main actor when either state changed.
    var onChange: (@MainActor () -> Void)?

    private let log = Logger(subsystem: "app.somabar", category: "Triggers")
    private var audioListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var cameraListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        listenToAudio(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
        listenToCamera(CMIOObjectID(kCMIOObjectSystemObject), selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        refresh()
    }

    func stop() {
        for (object, block) in audioListeners {
            var address = Self.audioAddress(object == AudioObjectID(kAudioObjectSystemObject)
                                            ? kAudioHardwarePropertyProcessObjectList : kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        audioListeners = [:]
        for (object, block) in cameraListeners {
            var address = Self.cameraAddress(object == CMIOObjectID(kCMIOObjectSystemObject)
                                             ? kCMIOHardwarePropertyDevices : kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        cameraListeners = [:]
        isStarted = false
    }

    /// Reads both states again. Returns true when either changed.
    @discardableResult
    func refresh() -> Bool {
        let microphone = readMicrophone()
        let camera = readCamera()
        guard microphone != microphoneInUse || camera != cameraInUse else { return false }
        microphoneInUse = microphone
        cameraInUse = camera
        return true
    }

    private func changed(_ source: String) {
        guard refresh() else { return }
        log.info("Media changed (\(source, privacy: .public)): microphone \(self.microphoneInUse), camera \(self.cameraInUse)")
        onChange?()
    }

    // MARK: - Microphone (CoreAudio)

    private func readMicrophone() -> Bool {
        var anyInput = false
        for process in audioObjectList(kAudioHardwarePropertyProcessObjectList) {
            listenToAudio(process, selector: kAudioProcessPropertyIsRunningInput)
            if audioUInt32(process, selector: kAudioProcessPropertyIsRunningInput) == 1 {
                anyInput = true
            }
        }
        return anyInput
    }

    private static func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func audioObjectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = Self.audioAddress(selector)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private func audioUInt32(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = Self.audioAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func listenToAudio(_ object: AudioObjectID, selector: AudioObjectPropertySelector) {
        guard audioListeners[object] == nil else { return }
        var address = Self.audioAddress(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changed("audio") }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return }
        audioListeners[object] = block
    }

    // MARK: - Camera (CoreMediaIO)

    private func readCamera() -> Bool {
        var anyRunning = false
        for device in cameraDevices() {
            listenToCamera(device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            if cameraUInt32(device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)) == 1 {
                anyRunning = true
            }
        }
        return anyRunning
    }

    private static func cameraAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private func cameraDevices() -> [CMIOObjectID] {
        var address = Self.cameraAddress(kCMIOHardwarePropertyDevices)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return [] }
        return devices
    }

    private func cameraUInt32(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> UInt32? {
        var address = Self.cameraAddress(Int(selector))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr else { return nil }
        return value
    }

    private func listenToCamera(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) {
        guard cameraListeners[object] == nil else { return }
        var address = Self.cameraAddress(Int(selector))
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changed("camera") }
        }
        guard CMIOObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return }
        cameraListeners[object] = block
    }
}
