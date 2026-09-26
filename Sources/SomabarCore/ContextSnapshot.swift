/// Everything triggers can react to, sampled at one moment. Sources fill it in; the evaluator
/// only reads it, so trigger logic is testable without a Mac around it.
public struct ContextSnapshot: Equatable, Sendable {
    public var powerSource: PowerSource = .adapter
    public var batteryPercent: Int?

    public var isEthernet = false
    public var isWiFi = false
    public var isVPN = false
    /// The hardware address of the current router, when connected.
    public var routerAddress: String?

    public var displayCount = 1
    public var hasExternalDisplay = false
    public var widestDisplayPoints = 0

    public var isScreenShared = false
    public var microphoneInUse = false
    public var cameraInUse = false

    public var runningApps: Set<String> = []
    public var frontmostApp: String?

    /// The current Focus name, from the Focus Filter.
    public var focus: String?
    public var minuteOfDay = 0

    public var changedIcons: Set<ItemKey> = []
    /// Conditions switched on from the CLI.
    public var externalConditions: Set<String> = []

    public init() {}
}

extension ContextSnapshot: CustomStringConvertible {
    /// One line for the log: "adapter, wifi, router b0:39:…, 2 displays (external), mic, 14:05".
    public var description: String {
        var parts: [String] = [powerSource == .battery ? "battery" : "adapter"]
        if let batteryPercent { parts.append("\(batteryPercent)%") }
        if isEthernet { parts.append("ethernet") }
        if isWiFi { parts.append("wifi") }
        if !isEthernet && !isWiFi { parts.append("offline") }
        if isVPN { parts.append("vpn") }
        if let routerAddress { parts.append("router \(routerAddress)") }
        parts.append("\(displayCount) display\(displayCount == 1 ? "" : "s")\(hasExternalDisplay ? " (external)" : "")")
        if isScreenShared { parts.append("screen shared") }
        if microphoneInUse { parts.append("mic") }
        if cameraInUse { parts.append("camera") }
        if let frontmostApp { parts.append("front \(frontmostApp)") }
        if let focus { parts.append("focus \(focus)") }
        parts.append(String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60))
        if !externalConditions.isEmpty { parts.append("external " + externalConditions.sorted().joined(separator: ",")) }
        return parts.joined(separator: ", ")
    }
}
