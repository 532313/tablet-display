import Darwin
import Foundation

struct LocalNetworkInterfaceAddress: Equatable {
    let name: String
    let address: String
    let netmask: String
    let isUp: Bool
    let isLoopback: Bool
}

enum LocalNetwork {
    /// Uses the kernel route for the tablet when available. If route lookup is
    /// unavailable, chooses the matching subnet with the longest real netmask.
    /// Neither path sends a packet, so it does not trigger Local Network access.
    static func ipv4(towards host: String) -> String? {
        guard bytes(of: host) != nil else { return nil }
        return selectAddress(
            towards: host,
            routeInterface: routeInterface(towards: host),
            interfaces: interfaceAddresses()
        )
    }

    static func selectAddress(
        towards host: String,
        routeInterface: String?,
        interfaces: [LocalNetworkInterfaceAddress]
    ) -> String? {
        guard let target = bytes(of: host) else { return nil }
        let candidates = interfaces.compactMap { item -> (LocalNetworkInterfaceAddress, UInt32, Int)? in
            guard item.isUp, !item.isLoopback,
                  bytes(of: item.address) != nil,
                  let mask = bytes(of: item.netmask) else { return nil }
            let maskValue = number(mask)
            let prefixLength = maskValue.nonzeroBitCount
            guard prefixLength > 0 else { return nil }
            return (item, maskValue, prefixLength)
        }

        func belongsToSubnet(_ candidate: (LocalNetworkInterfaceAddress, UInt32, Int)) -> Bool {
            guard let address = bytes(of: candidate.0.address) else { return false }
            let addressValue = number(address)
            return (addressValue & candidate.1) == (number(target) & candidate.1)
        }

        if let routeInterface {
            let routed = candidates.filter { $0.0.name == routeInterface }
            if let connected = routed.filter(belongsToSubnet).max(by: { $0.2 < $1.2 }) {
                return connected.0.address
            }
            if let routedAddress = routed.max(by: { $0.2 < $1.2 }) {
                return routedAddress.0.address
            }
        }

        return candidates
            .filter(belongsToSubnet)
            .max(by: { $0.2 < $1.2 })?
            .0.address
    }

    static func parseRouteInterface(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "interface" else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private static func routeInterface(towards host: String) -> String? {
        let route = Process()
        route.executableURL = URL(fileURLWithPath: "/sbin/route")
        route.arguments = ["-n", "get", host]
        let output = Pipe()
        route.standardOutput = output
        route.standardError = FileHandle.nullDevice
        do {
            try route.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            route.waitUntilExit()
            guard route.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return parseRouteInterface(text)
        } catch {
            return nil
        }
    }

    private static func interfaceAddresses() -> [LocalNetworkInterfaceAddress] {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else { return [] }
        defer { freeifaddrs(interfaceList) }

        var result: [LocalNetworkInterfaceAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let next = current.pointee.ifa_next
            defer { pointer = next }

            let flags = Int32(current.pointee.ifa_flags)
            guard let address = current.pointee.ifa_addr,
                  let netmask = current.pointee.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET),
                  netmask.pointee.sa_family == UInt8(AF_INET),
                  let addressText = numericIPv4(address),
                  let netmaskText = numericIPv4(netmask) else { continue }

            result.append(LocalNetworkInterfaceAddress(
                name: String(cString: current.pointee.ifa_name),
                address: addressText,
                netmask: netmaskText,
                isUp: flags & IFF_UP != 0,
                isLoopback: flags & IFF_LOOPBACK != 0
            ))
        }
        return result
    }

    private static func numericIPv4(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                 &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        guard status == 0 else { return nil }
        let characters = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: characters, as: UTF8.self)
    }

    private static func bytes(of address: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var value = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &value) == 1 }) else { return nil }
        let number = UInt32(bigEndian: value.s_addr)
        return (UInt8((number >> 24) & 0xff), UInt8((number >> 16) & 0xff),
                UInt8((number >> 8) & 0xff), UInt8(number & 0xff))
    }

    private static func number(_ address: (UInt8, UInt8, UInt8, UInt8)) -> UInt32 {
        (UInt32(address.0) << 24) | (UInt32(address.1) << 16) |
            (UInt32(address.2) << 8) | UInt32(address.3)
    }
}
