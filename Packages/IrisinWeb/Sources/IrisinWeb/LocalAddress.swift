import Darwin

/// The device's IPv4 addresses on its local network, for the QR code: Wi-Fi
/// and Ethernet (`en*`), not loopback, not cellular (`pdp_ip*`), private
/// ranges first.
public enum LocalAddress {
    public static func current() -> [String] {
        var found: [(name: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            found.append((name, String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        }
        return found.sorted { isPrivate($0.address) && !isPrivate($1.address) }.map(\.address)
    }

    static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16 ... 31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    }
}
