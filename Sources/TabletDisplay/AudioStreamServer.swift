import Darwin
import Foundation

/// Low-latency PCM audio transport for the tablet speakers. Video stays on
/// RTP/TCP; audio has its own UDP port and a small fixed packet format.
final class AudioStreamServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 9139
    static let sampleRate = 48_000
    static let channels = 2
    private static let bytesPerSample = 2
    private static let framesPerPacket = 240 // 5 ms
    private static let packetBytes = framesPerPacket * channels * bytesPerSample

    private let token: String
    private let stateLock = NSLock()
    private var socketFD: Int32 = -1
    private var running = false
    private var peer: sockaddr_in?
    private var peerReady = false
    private var lastContact = Date.distantPast
    private var sequence: UInt32 = 0
    private var timestamp: UInt64 = 0
    private var receiveThread: Thread?

    init(token: String) {
        self.token = token
    }

    func start(port: UInt16 = AudioStreamServer.defaultPort) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw AudioError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var receiveBuffer: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw AudioError.bind(code)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        let actualPort = UInt16(bigEndian: bound.sin_port)

        stateLock.lock()
        socketFD = fd
        running = true
        stateLock.unlock()

        let thread = Thread { [weak self] in self?.receiveLoop() }
        thread.name = "tablet-display-audio-receive"
        stateLock.lock()
        receiveThread = thread
        stateLock.unlock()
        thread.start()
        AppLog.write("音频 UDP 监听：0.0.0.0:\(actualPort)")
        return actualPort
    }

    func stop() {
        stateLock.lock()
        running = false
        let fd = socketFD
        socketFD = -1
        peer = nil
        stateLock.unlock()
        if fd >= 0 { close(fd) }
        receiveThread?.cancel()
        receiveThread = nil
    }

    func hasPeer() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return peer != nil && peerReady && Date().timeIntervalSince(lastContact) <= 5
    }

    /// Called from the audio tap callback with interleaved
    /// 48kHz/stereo s16le PCM. Split into 5ms datagrams.
    func append(_ pcm: Data) {
        stateLock.lock()
        guard running, let peer, Date().timeIntervalSince(lastContact) <= 5 else {
            stateLock.unlock()
            return
        }
        var packetSequence = sequence
        var packetTimestamp = timestamp
        stateLock.unlock()

        var offset = 0
        while offset < pcm.count {
            let available = pcm.count - offset
            let length = min(Self.packetBytes, available) & ~3
            if length <= 0 { break }
            var packet = Data(capacity: 16 + length)
            packet.append(contentsOf: [0x54, 0x44, 0x41, 0x55]) // TDAU
            packet.append(UInt8((packetSequence >> 24) & 0xFF))
            packet.append(UInt8((packetSequence >> 16) & 0xFF))
            packet.append(UInt8((packetSequence >> 8) & 0xFF))
            packet.append(UInt8(packetSequence & 0xFF))
            for shift in stride(from: 56, through: 0, by: -8) {
                packet.append(UInt8((packetTimestamp >> UInt64(shift)) & 0xFF))
            }
            packet.append(pcm.subdata(in: offset..<(offset + length)))
            send(packet, to: peer)
            packetSequence &+= 1
            packetTimestamp &+= UInt64(length / (Self.channels * Self.bytesPerSample))
            offset += length
        }

        stateLock.lock()
        sequence = packetSequence
        timestamp = packetTimestamp
        stateLock.unlock()
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while isRunning {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return withUnsafeMutablePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(currentSocket, base, raw.count, 0, $0, &sourceLength)
                    }
                }
            }
            if count <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                break
            }
            let text = String(decoding: buffer[0..<Int(count)], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("HELLO ") {
                guard String(text.dropFirst("HELLO ".count)) == token else { continue }
                acceptPeer(source)
            } else if text == "PING" {
                stateLock.lock()
                if let peer,
                   peer.sin_addr.s_addr == source.sin_addr.s_addr,
                   peer.sin_port == source.sin_port {
                    lastContact = Date()
                }
                stateLock.unlock()
            } else if text == "READY" {
                stateLock.lock()
                if let peer,
                   peer.sin_addr.s_addr == source.sin_addr.s_addr,
                   peer.sin_port == source.sin_port {
                    peerReady = true
                    lastContact = Date()
                }
                stateLock.unlock()
            }
        }
    }

    private func acceptPeer(_ source: sockaddr_in) {
        stateLock.lock()
        peer = source
        peerReady = false
        lastContact = Date()
        stateLock.unlock()
        sendMetadata(to: source)
        AppLog.write("音频 UDP 客户端：\(peerDescription(source))")
    }

    private func sendMetadata(to source: sockaddr_in) {
        let text = "AMETA \(Self.sampleRate) \(Self.channels)\n"
        send(Data(text.utf8), to: source)
    }

    private func send(_ data: Data, to peer: sockaddr_in) {
        let fd = currentSocket
        guard fd >= 0 else { return }
        var address = peer
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, base, data.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private var currentSocket: Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return socketFD
    }

    private func peerDescription(_ peer: sockaddr_in) -> String {
        var address = peer.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return "\(String(cString: buffer)):\(UInt16(bigEndian: peer.sin_port))"
    }
}

enum AudioError: LocalizedError {
    case socket(Int32)
    case bind(Int32)

    var errorDescription: String? {
        switch self {
        case .socket(let code):
            return "无法创建音频 UDP socket（errno \(code)）"
        case .bind(let code):
            return "无法绑定音频 UDP 端口（errno \(code)）"
        }
    }
}
