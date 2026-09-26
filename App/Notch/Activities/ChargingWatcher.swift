import Foundation
import IOKit.ps
import NotchKit
import os
import SomabarCore

/// N4: pulses the notch when the Mac is plugged in or unplugged.
///
/// Listens to the same IOKit power-source notification as `ContextMonitor`, with its own run-loop
/// source because it needs macOS's time estimates, which the trigger snapshot leaves out and
/// which change without the snapshot changing. Right after a plug-in macOS is often still
/// estimating the time to full; the pulse waits up to `estimateWaitSeconds` for it.
@MainActor
final class ChargingWatcher {
    static let estimateWaitSeconds = 4.0

    /// Called with the pulse text and its glyph.
    var onPulse: (@MainActor (String, String) -> Void)?

    private(set) var reading = PowerReading(source: .adapter)
    private var runLoopSource: CFRunLoopSource?
    /// The reading before a plug-in whose estimate is awaited.
    private var pendingFrom: PowerReading?
    private var pendingTask: Task<Void, Never>?
    private let log = Logger(subsystem: "app.somabar", category: "activities")

    /// Call `stop()` before letting go: the notification holds an unretained pointer to this.
    func start() {
        guard runLoopSource == nil else { return }
        reading = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let watcher = Unmanaged<ChargingWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.powerChanged() }
        }, context)
        guard let source = source?.takeRetainedValue() else {
            log.error("Could not watch the power source for the charging pulse")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        pendingTask?.cancel()
        pendingTask = nil
        pendingFrom = nil
    }

    private func powerChanged() {
        let old = reading
        let new = Self.read()
        reading = new
        if let from = pendingFrom {
            // Waiting for the estimate after a plug-in: pulse once it arrives, or if the plug
            // came out again in the meantime.
            if new.source != .adapter || !new.isAwaitingEstimate {
                pulse(from: from, to: new)
            }
            return
        }
        guard old.source != new.source else { return }
        if new.isAwaitingEstimate {
            pendingFrom = old
            pendingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.estimateWaitSeconds))
                guard !Task.isCancelled, let self, let from = self.pendingFrom else { return }
                self.pulse(from: from, to: self.reading)
            }
            return
        }
        pulse(from: old, to: new)
    }

    private func pulse(from old: PowerReading, to new: PowerReading) {
        pendingTask?.cancel()
        pendingTask = nil
        pendingFrom = nil
        guard let text = ActivityText.powerPulse(from: old, to: new) else { return }
        log.info("Power: \(text, privacy: .public)")
        onPulse?(text, new.source == .adapter ? "bolt.fill" : "battery.75percent")
    }

    // MARK: - Reading

    static func read() -> PowerReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerReading(source: .adapter) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var result = PowerReading(source: providing == kIOPSBatteryPowerValue ? .battery : .adapter)
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for entry in sources {
            guard let description = IOPSGetPowerSourceDescription(info, entry)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                result.percent = min(100, current * 100 / maximum)
            }
            // -1 while macOS is still estimating.
            if let minutes = description[kIOPSTimeToFullChargeKey] as? Int, minutes > 0 {
                result.minutesToFull = minutes
            }
            result.isCharged = description[kIOPSIsChargedKey] as? Bool ?? false
        }
        if result.source == .battery {
            let seconds = IOPSGetTimeRemainingEstimate()
            // kIOPSTimeRemainingUnknown is -1 and kIOPSTimeRemainingUnlimited is -2.
            if seconds > 0 {
                result.minutesToEmpty = Int(seconds / 60)
            }
        }
        return result
    }
}
