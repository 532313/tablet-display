import Darwin
import Foundation

/// Minimal UDP-RTP video transport. TCP `/video` remains the fallback; this
/// server only starts a sender after an authenticated HELLO from the tablet.
final class RTPVideoServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 9138
    private static let maxPayload = 1200

    private let frames: VideoFrameStore
    private let token: String
    private let width: Int
    private let height: Int
    private let fps: Int

    private let stateLock = NSLock()
    private var socketFD: Int32 = -1
    private var running = false
    private var peer: sockaddr_in?
    private var lastContact = Date.distantPast
    private var peerGeneration: UInt64 = 0
    private var cursor: UInt64 = 0
    private var needsKeyframe = true
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var receiveThread: Thread?
    private var sendThread: Thread?

    init(frames: VideoFrameStore, token: String, width: Int, height: Int, fps: Int) {
        self.frames = frames
        self.token = token
        self.width = width
        self.height = height
        self.fps = fps
    }

    func start(port: UInt16 = RTPVideoServer.defaultPort) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw RTPError.socket(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var receiveBuffer: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw RTPError.bind(code)
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        }
        let actualPort = UInt16(bigEndian: bound.sin_port)

        stateLock.lock()
        socketFD = fd
        running = true
        stateLock.unlock()

        let receive = Thread { [weak self] in self?.receiveLoop() }
        receive.name = "tablet-display-rtp-receive"
        let send = Thread { [weak self] in self?.sendLoop() }
        send.name = "tablet-display-rtp-send"
        stateLock.lock()
        receiveThread = receive
        sendThread = send
        stateLock.unlock()
        receive.start()
        send.start()
        AppLog.write("RTP 监听：0.0.0.0:\(actualPort)")
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
        sendThread?.cancel()
        receiveThread = nil
        sendThread = nil
    }

    // MARK: - Control plane

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 2048)
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
                let received = String(text.dropFirst("HELLO ".count))
                guard received == token else {
                    AppLog.write("RTP：拒绝令牌不匹配的客户端")
                    continue
                }
                acceptPeer(source)
            } else if text == "KEYFRAME" {
                guard isCurrentPeer(source) else { continue }
                frames.requestKeyframe()
            } else if text == "PING" {
                guard isCurrentPeer(source) else { continue }
                stateLock.lock()
                lastContact = Date()
                stateLock.unlock()
            }
        }
    }

    private func acceptPeer(_ source: sockaddr_in) {
        stateLock.lock()
        peer = source
        lastContact = Date()
        peerGeneration &+= 1
        cursor = frames.latestSequence()
        needsKeyframe = true
        stateLock.unlock()
        AppLog.write("RTP 客户端：\(peerDescription(source))")
        frames.requestKeyframe()
        sendMetadata(to: source)
    }

    private func sendMetadata(to source: sockaddr_in) {
        let text = "META \(width) \(height) \(fps)\n"
        send(Data(text.utf8), to: source)
    }

    private func isCurrentPeer(_ source: sockaddr_in) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let peer else { return false }
        return peer.sin_addr.s_addr == source.sin_addr.s_addr && peer.sin_port == source.sin_port
    }

    // MARK: - RTP sender

    private func sendLoop() {
        while isRunning {
            stateLock.lock()
            if self.peer != nil, Date().timeIntervalSince(lastContact) > 5 {
                AppLog.write("RTP：客户端心跳超时")
                self.peer = nil
            }
            let peer = self.peer
            let generation = peerGeneration
            let cursor = self.cursor
            let needsKeyframe = self.needsKeyframe
            stateLock.unlock()

            guard let peer else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            let frame = frames.next(after: cursor, keyframeOnly: needsKeyframe, timeout: 0.2)
            guard let frame else {
                frames.requestKeyframe()
                continue
            }
            sendFrame(frame, to: peer)
            stateLock.lock()
            if peerGeneration == generation {
                self.cursor = frame.sequence
                self.needsKeyframe = false
            }
            stateLock.unlock()
        }
    }

    private func sendFrame(_ frame: EncodedFrame, to peer: sockaddr_in) {
        let nals = Self.nalUnits(frame.data)
        guard !nals.isEmpty else { return }
        stateLock.lock()
        timestamp &+= UInt32(90000 / max(1, fps))
        let frameTimestamp = timestamp
        stateLock.unlock()

        for (index, nal) in nals.enumerated() {
            let lastNal = index == nals.count - 1
            if nal.count <= Self.maxPayload {
                sendRTP(payload: [UInt8](nal), marker: lastNal,
                        timestamp: frameTimestamp, to: peer)
                continue
            }

            let bytes = [UInt8](nal)
            let indicator = (bytes[0] & 0xE0) | 28
            let nalType = bytes[0] & 0x1F
            var offset = 1
            while offset < bytes.count {
                let end = min(offset + Self.maxPayload - 2, bytes.count)
                let start = offset == 1
                let final = end == bytes.count
                var payload = [UInt8]()
                payload.reserveCapacity(2 + end - offset)
                payload.append(indicator)
                payload.append((start ? 0x80 : 0) | (final ? 0x40 : 0) | nalType)
                payload.append(contentsOf: bytes[offset..<end])
                sendRTP(payload: payload, marker: lastNal && final,
                        timestamp: frameTimestamp, to: peer)
                offset = end
            }
        }
    }

    private func sendRTP(payload: [UInt8], marker: Bool, timestamp: UInt32,
                         to peer: sockaddr_in) {
        stateLock.lock()
        let sequence = self.sequence
        self.sequence &+= 1
        stateLock.unlock()

        var packet = Data(capacity: 12 + payload.count)
        packet.append(0x80)
        packet.append(96 | (marker ? 0x80 : 0))
        packet.append(UInt8(sequence >> 8))
        packet.append(UInt8(sequence & 0xFF))
        packet.append(UInt8((timestamp >> 24) & 0xFF))
        packet.append(UInt8((timestamp >> 16) & 0xFF))
        packet.append(UInt8((timestamp >> 8) & 0xFF))
        packet.append(UInt8(timestamp & 0xFF))
        packet.append(UInt8((ssrc >> 24) & 0xFF))
        packet.append(UInt8((ssrc >> 16) & 0xFF))
        packet.append(UInt8((ssrc >> 8) & 0xFF))
        packet.append(UInt8(ssrc & 0xFF))
        packet.append(contentsOf: payload)
        send(packet, to: peer)
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

    // MARK: - Helpers

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

    /// Split an Annex B access unit into NAL units. The encoder emits 4-byte
    /// start codes, but accept 3-byte codes as well.
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(payload: Int, code: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index + 4, index))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index + 3, index))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { return [] }
        var result: [Data] = []
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1].code : bytes.count
            guard end > start.payload else { continue }
            result.append(Data(bytes[start.payload..<end]))
        }
        return result
    }
}

enum RTPError: LocalizedError {
    case socket(Int32)
    case bind(Int32)

    var errorDescription: String? {
        switch self {
        case .socket(let code):
            return "无法创建 UDP socket（errno \(code)）"
        case .bind(let code):
            return "无法绑定 UDP 端口（errno \(code)）"
        }
    }
}
