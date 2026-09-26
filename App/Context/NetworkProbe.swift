import Darwin
import Foundation
import SomabarCore
import SystemConfiguration

/// What the network conditions need beyond `NWPathMonitor`: which router the Mac is behind,
/// and whether a VPN tunnel is up.
///
/// The router is identified by its hardware address rather than the network name: home and
/// the office both have a "Wi-Fi", but no two routers share a MAC. The address comes from the
/// kernel's ARP table, the same place `arp -n` reads it.
enum NetworkProbe {
    /// The default IPv4 router's address, from the system configuration store.
    static func defaultRouterIPv4() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Somabar" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return value["Router"] as? String
    }

    /// "b0:39:56:0b:e1:e5" for the given IPv4 address, or nil when the ARP table has no entry for
    /// it yet. Right after joining a network the entry can take a moment to appear.
    static func hardwareAddress(ofIPv4 address: String) -> String? {
        var target = in_addr()
        guard inet_pton(AF_INET, address, &target) == 1 else { return nil }
        let wanted = withUnsafeBytes(of: target.s_addr) { Array($0) }
        guard let table = linkLayerRoutes() else { return nil }
        return hardwareAddress(in: table, forIPv4Bytes: wanted)
    }

    /// True when a tunnel interface is up with a real address. macOS keeps a few `utun`
    /// interfaces of its own that only carry link-local IPv6, so those do not count.
    static func hasActiveTunnel() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard TunnelInterfaces.isTunnel(name) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                return true
            case AF_INET6:
                let isLinkLocal = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
                }
                if !isLinkLocal { return true }
            default:
                continue
            }
        }
        return false
    }

    // MARK: - Routing table

    /// The IPv4 routes the link layer generated (`RTF_LLINFO`), which is the ARP table.
    private static func linkLayerRoutes() -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var needed = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &needed, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(needed))
    }

    /// Each record is an `rt_msghdr`, then the destination `sockaddr_in`, then a `sockaddr_dl`
    /// holding the interface name and the link address. Socket addresses are padded to 4 bytes.
    static func hardwareAddress(in table: [UInt8], forIPv4Bytes wanted: [UInt8]) -> String? {
        let headerSize = MemoryLayout<rt_msghdr>.size
        var offset = 0
        while offset + headerSize <= table.count {
            let messageLength = Int(table[offset]) | Int(table[offset + 1]) << 8
            guard messageLength >= headerSize, offset + messageLength <= table.count else { return nil }
            let end = offset + messageLength
            let destination = offset + headerSize
            if let address = socketAddress(in: table, at: destination, end: end), address.family == AF_INET, address.length >= 8,
               Array(table[(destination + 4)..<(destination + 8)]) == wanted {
                let link = destination + address.paddedLength
                if let linkAddress = socketAddress(in: table, at: link, end: end), linkAddress.family == AF_LINK, linkAddress.length >= 8 {
                    let nameLength = Int(table[link + 5])
                    let addressLength = Int(table[link + 6])
                    let start = link + 8 + nameLength
                    if addressLength == 6, start + 6 <= end {
                        return table[start..<(start + 6)].map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                }
            }
            offset = end
        }
        return nil
    }

    private struct SocketAddress {
        var length: Int
        var family: Int32
        /// The length rounded up to the 4-byte boundary the next address starts on.
        var paddedLength: Int { length > 0 ? (length + 3) & ~3 : 4 }
    }

    private static func socketAddress(in table: [UInt8], at cursor: Int, end: Int) -> SocketAddress? {
        guard cursor + 2 <= end else { return nil }
        let length = Int(table[cursor])
        guard cursor + length <= end else { return nil }
        return SocketAddress(length: length, family: Int32(table[cursor + 1]))
    }
}
