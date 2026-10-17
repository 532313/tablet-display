import Darwin
import Foundation

enum LocalNetwork {
    /// Finds the local IPv4 address on the same subnet as `host` by walking the
    /// interface list. Unlike a UDP connect, this performs no network I/O, so
    /// it does not trigger the macOS Local Network privacy prompt.
    static func ipv4(towards host: String) -> String? {
        guard let target = bytes(of: host) else { return nil }
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else { return nil }
        defer { freeifaddrs(interfaceList) }

        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"),
                  !name.hasPrefix("llw"), !name.hasPrefix("bridge") else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &buffer, socklen_t(buffer.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: buffer)
            guard let candidate = bytes(of: value) else { continue }
            if candidate.0 == target.0, candidate.1 == target.1, candidate.2 == target.2 {
                return value
            }
            if name == "en0" { fallback = value }
        }
        return fallback
    }

    private static func bytes(of address: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var value = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &value) == 1 }) else { return nil }
        let number = UInt32(bigEndian: value.s_addr)
        return (UInt8((number >> 24) & 0xff), UInt8((number >> 16) & 0xff),
                UInt8((number >> 8) & 0xff), UInt8(number & 0xff))
    }
}
