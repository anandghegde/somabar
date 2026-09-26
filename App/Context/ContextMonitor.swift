import AppKit
import BarEngine
import IOKit.ps
import Network
import os
import SomabarCore

/// Keeps a `ContextSnapshot` current so triggers can be evaluated: power, network, displays,
/// microphone and camera use, running apps, the Focus and the clock.
///
/// Every source is a notification where macOS has one, and a slow poll catches the rest. Two
/// fields come from outside: screen sharing is read off the bar by the scan (`setScreenShared`),
/// and external conditions are switched by `somabar://set` (`setExternalConditions`).
///
/// Call `stop()` before letting go of the monitor: the power notification holds an unretained
/// pointer to it.
@MainActor
final class ContextMonitor: NSObject {
    static let pollSeconds: Double = 60
    /// How long after a network change the router's ARP entry is looked up again.
    static let routerRetrySeconds: Double = 3

    private(set) var snapshot = ContextSnapshot()
    /// Called on the main actor after the snapshot changed, with why.
    var onChange: (@MainActor (String) -> Void)?
    /// Called on every screen parameters change, whether or not the snapshot changed, for the
    /// display rules and the notch surface.
    var onDisplaysChanged: (@MainActor () -> Void)?
    /// Called after `onChange`, for the notch activities and the active-display rule.
    var onSnapshotChange: (@MainActor (String) -> Void)?
    /// True when a trigger depends on the time of day, so the snapshot is refreshed every minute.
    var wantsClock = false {
        didSet { if wantsClock != oldValue { updateClock() } }
    }

    private let log = Logger(subsystem: "app.somabar", category: "Triggers")
    private let media = MediaWatcher()
    private var pathMonitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var routerTask: Task<Void, Never>?
    /// Items whose icon changed within `IconChange.holdSeconds`, and the timer that ends it.
    private var iconHold = IconChangeHold()
    private var iconHoldTask: Task<Void, Never>?
    private var isStarted = false

    /// From the path monitor; the rest of the network state is read on each refresh.
    private var isWiFi = false
    private var isEthernet = false
    /// The last router seen, so a missing ARP entry does not make a known network unknown.
    private var lastRouter: (ip: String, address: String)?

    // MARK: - Lifecycle

    /// Fills the snapshot without calling `onChange`; read `snapshot` after this.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        media.onChange = { [weak self] in self?.refresh(reason: "media") }
        media.start()
        startPower()
        startNetwork()
        observeNotifications()
        startPoll()
        updateClock()
        snapshot = read()
        log.info("Context: \(self.snapshot.description, privacy: .public)")
        readFocusFilter()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        media.stop()
        pathMonitor?.cancel()
        pathMonitor = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            self.powerSource = nil
        }
        // swiftlint:disable:next notification_center_detachment
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pollTask?.cancel()
        clockTask?.cancel()
        routerTask?.cancel()
        iconHoldTask?.cancel()
    }

    /// Reads every source again and reports a change.
    func refresh(reason: String) {
        commit(read(), reason: reason)
    }

    // MARK: - Set from outside

    /// The scan saw, or no longer sees, the Screen Sharing item that macOS shows while the
    /// screen is being shared.
    func setScreenShared(_ shared: Bool) {
        guard shared != snapshot.isScreenShared else { return }
        var next = snapshot
        next.isScreenShared = shared
        commit(next, reason: shared ? "screen sharing started" : "screen sharing ended")
    }

    /// `somabar://set?docker=on&vpn=off`.
    func setExternalConditions(_ updates: [(name: String, isOn: Bool)]) {
        var next = snapshot
        for update in updates {
            if update.isOn {
                next.externalConditions.insert(update.name)
            } else {
                next.externalConditions.remove(update.name)
            }
        }
        commit(next, reason: "set " + updates.map { "\($0.name)=\($0.isOn ? "on" : "off")" }.joined(separator: " "))
    }

    /// The icon-change detector saw these items' icons change. They hold for
    /// `IconChange.holdSeconds`, together with any item that changed shortly before; another
    /// change restarts the hold, and its end is committed as "iconChangeEnded".
    func setChangedIcons(_ keys: Set<ItemKey>) {
        guard !keys.isEmpty else { return }
        let grew = iconHold.noteChange(keys, at: Date())
        armIconHold()
        // The same items again only restart the hold: the snapshot is unchanged, so there is
        // nothing new to evaluate.
        guard grew else { return }
        var next = snapshot
        next.changedIcons = iconHold.keys
        commit(next, reason: "iconChanged")
    }

    /// One-shot: ends the hold at `iconHold.until` through the normal commit, so a trigger's
    /// effect ends the way any condition's does.
    private func armIconHold() {
        iconHoldTask?.cancel()
        guard let until = iconHold.until else { return }
        iconHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.iconHold.expire(at: Date()) else { return }
            self.iconHoldTask = nil
            var next = self.snapshot
            next.changedIcons = []
            self.commit(next, reason: "iconChangeEnded")
        }
    }

    /// The Focus changed; nil when none is on (`SomabarFocusFilter`).
    func setFocus(_ name: String?) {
        var next = snapshot
        next.focus = name?.isEmpty == true ? nil : name
        commit(next, reason: "focus")
    }

    // MARK: - Reading

    private func read() -> ContextSnapshot {
        var next = snapshot
        let power = Self.readPower()
        next.powerSource = power.source
        next.batteryPercent = power.batteryPercent

        next.isWiFi = isWiFi
        next.isEthernet = isEthernet
        next.isVPN = NetworkProbe.hasActiveTunnel()
        next.routerAddress = readRouter(connected: isWiFi || isEthernet)

        let screens = NSScreen.screens
        next.displayCount = screens.count
        next.hasExternalDisplay = screens.contains { screen in
            ScreenGeometry.displayID(of: screen).map { CGDisplayIsBuiltin($0) == 0 } ?? true
        }
        next.widestDisplayPoints = Int(screens.map(\.frame.width).max() ?? 0)
        next.activeDisplayPoints = ActiveDisplay.widthPoints

        next.microphoneInUse = media.microphoneInUse
        next.cameraInUse = media.cameraInUse

        let workspace = NSWorkspace.shared
        next.runningApps = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        next.frontmostApp = workspace.frontmostApplication?.bundleIdentifier

        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        next.minuteOfDay = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        return next
    }

    private func commit(_ next: ContextSnapshot, reason: String) {
        guard next != snapshot else { return }
        snapshot = next
        log.info("Context changed (\(reason, privacy: .public)): \(next.description, privacy: .public)")
        onChange?(reason)
        onSnapshotChange?(reason)
    }

    // MARK: - Power

    private static func readPower() -> (source: PowerSource, batteryPercent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (.adapter, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let source: PowerSource = providing == kIOPSBatteryPowerValue ? .battery : .adapter
        var percent: Int?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for entry in sources {
            guard let description = IOPSGetPowerSourceDescription(info, entry)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            percent = min(100, current * 100 / maximum)
        }
        return (source, percent)
    }

    private func startPower() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<ContextMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh(reason: "power") }
        }, context)
        guard let source = source?.takeRetainedValue() else {
            log.error("Could not watch the power source")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    // MARK: - Network

    private func startNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let wifi = satisfied && path.usesInterfaceType(.wifi)
            let ethernet = satisfied && path.usesInterfaceType(.wiredEthernet)
            MainActor.assumeIsolated { self?.networkChanged(wifi: wifi, ethernet: ethernet) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func networkChanged(wifi: Bool, ethernet: Bool) {
        isWiFi = wifi
        isEthernet = ethernet
        guard isStarted else { return }
        refresh(reason: "network")
        routerTask?.cancel()
        guard wifi || ethernet, snapshot.routerAddress == nil else { return }
        // The router's ARP entry can take a moment after joining.
        routerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.routerRetrySeconds))
            guard !Task.isCancelled else { return }
            self?.refresh(reason: "router")
        }
    }

    private func readRouter(connected: Bool) -> String? {
        guard connected, let ip = NetworkProbe.defaultRouterIPv4() else {
            lastRouter = nil
            return nil
        }
        if let address = NetworkProbe.hardwareAddress(ofIPv4: ip) {
            lastRouter = (ip, address)
            return address
        }
        // Same router, entry expired: keep it. A different router is unknown until it answers.
        return lastRouter?.ip == ip ? lastRouter?.address : nil
    }

    // MARK: - Displays, apps and the Focus

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(somethingChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(focusChanged(_:)), name: SomabarFocusFilter.didChangeNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(self, selector: #selector(somethingChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func somethingChanged(_ notification: Notification) {
        refresh(reason: notification.name.rawValue.replacingOccurrences(of: "Notification", with: ""))
        if notification.name == NSApplication.didChangeScreenParametersNotification {
            onDisplaysChanged?()
        }
    }

    @objc private func focusChanged(_ notification: Notification) {
        setFocus(notification.userInfo?[SomabarFocusFilter.focusNameKey] as? String)
    }

    /// The Focus at launch, from the filter the system currently applies.
    private func readFocusFilter() {
        Task { @MainActor [weak self] in
            let filter = try? await SomabarFocusFilter.current
            self?.setFocus(filter?.focusName)
        }
    }

    // MARK: - Clock and poll

    private func updateClock() {
        clockTask?.cancel()
        clockTask = nil
        guard wantsClock, isStarted else { return }
        clockTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let seconds = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60) + 0.1
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self.refresh(reason: "minute")
            }
        }
    }

    private func startPoll() {
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
                guard !Task.isCancelled else { return }
                self.media.refresh()
                self.refresh(reason: "poll")
            }
        }
    }
}
