import Darwin
import Foundation

struct TestSocketError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class TestSocket {
    private var fd: Int32

    init(port: UInt16, timeout: TimeInterval = 5) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TestSocketError(message: "socket() 失败: \(String(cString: strerror(errno)))")
        }
        var socketTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let code = errno
            close()
            throw TestSocketError(message: "connect() 失败: \(String(cString: strerror(code)))")
        }
    }

    deinit { close() }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    func send(_ data: Data) throws {
        guard fd >= 0 else { throw TestSocketError(message: "socket 已关闭") }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw TestSocketError(message: "send() 失败: \(String(cString: strerror(errno)))")
                }
                sent += count
            }
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        guard fd >= 0 else { throw TestSocketError(message: "socket 已关闭") }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: max(1, count))
        while result.count < count {
            let received = recv(fd, &buffer, count - result.count, 0)
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else {
                throw TestSocketError(message: "readExactly 失败: \(String(cString: strerror(errno)))")
            }
            result.append(contentsOf: buffer.prefix(received))
        }
        return result
    }

    func readUntil(_ delimiter: Data) throws -> Data {
        guard fd >= 0 else { throw TestSocketError(message: "socket 已关闭") }
        var result = Data()
        var byte: UInt8 = 0
        while result.count < 16_384 {
            let received = recv(fd, &byte, 1, 0)
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else {
                throw TestSocketError(message: "readUntil 失败: \(String(cString: strerror(errno)))")
            }
            result.append(byte)
            if result.count >= delimiter.count,
               result.suffix(delimiter.count).elementsEqual(delimiter) {
                return result
            }
        }
        throw TestSocketError(message: "响应头过大")
    }

    func waitForClose(timeout: TimeInterval = 2) -> Bool {
        guard fd >= 0 else { return true }
        var byte: UInt8 = 0
        let received = recv(fd, &byte, 1, 0)
        return received == 0
    }
}

func uint32BE(_ data: Data, offset: Int = 0) -> UInt32 {
    (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
        (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
}

func floatBE(_ value: Float) -> Data {
    var bits = value.bitPattern.bigEndian
    return Data(bytes: &bits, count: MemoryLayout<UInt32>.size)
}
