import CoreGraphics
import Darwin
import Foundation

enum ServerError: LocalizedError {
    case listenFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .listenFailed(let code): return "无法监听本机端口：\(String(cString: strerror(code)))"
        }
    }
}

struct PointerMessage: Decodable {
    let x: Double
    let y: Double
    let phase: String
}

final class HTTPServer: @unchecked Sendable {
    typealias PointerHandler = (PointerMessage) -> Void

    private let frames: VideoFrameStore
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let fps: Int
    private let token: String
    private let directPeer: in_addr?
    private let requestTimeout: TimeInterval
    private let pointerHandler: PointerHandler?
    private var listener: Int32 = -1
    private var clients: Set<Int32> = []
    private let stateLock = NSLock()
    private let touchLock = NSLock()
    private var touchEnabled = true
    private var pointerIsDown = false
    private var pointerX = 0.5
    private var pointerY = 0.5
    private var isRunning = false
    private(set) var boundPort: UInt16 = 0

    init(frames: VideoFrameStore, displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int,
         token: String, directPeerIP: String? = nil, requestTimeout: TimeInterval = 10,
         pointerHandler: PointerHandler? = nil) {
        self.frames = frames
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        self.token = token
        self.requestTimeout = requestTimeout
        self.pointerHandler = pointerHandler
        if let directPeerIP {
            var address = in_addr()
            self.directPeer = directPeerIP.withCString {
                inet_pton(AF_INET, $0, &address) == 1 ? address : nil
            }
        } else {
            self.directPeer = nil
        }
    }

    func setTouchEnabled(_ enabled: Bool) {
        touchLock.lock()
        let release = !enabled && pointerIsDown
        let x = pointerX
        let y = pointerY
        if !enabled { pointerIsDown = false }
        touchEnabled = enabled
        touchLock.unlock()
        if release { inject(PointerMessage(x: x, y: y, phase: "up")) }
    }

    func start(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.listenFailed(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: directPeer == nil ? in_addr_t(0x7f000001).bigEndian : 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw ServerError.listenFailed(code)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        }
        let actualPort = named == 0 ? UInt16(bigEndian: boundAddress.sin_port) : port

        stateLock.lock()
        listener = fd
        boundPort = actualPort
        isRunning = true
        stateLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while running() {
                var peer = sockaddr_in()
                var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(fd, $0, &peerLength)
                    }
                }
                if client < 0 { break }
                if !running() {
                    close(client)
                    break
                }
                if let directPeer,
                   peer.sin_addr.s_addr != directPeer.s_addr,
                   peer.sin_addr.s_addr != in_addr_t(0x7f000001).bigEndian {
                    close(client)
                    continue
                }
                stateLock.lock()
                clients.insert(client)
                stateLock.unlock()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    handle(client)
                }
            }
        }
    }

    func stop() {
        stateLock.lock()
        isRunning = false
        let fd = listener
        listener = -1
        let active = clients
        clients.removeAll()
        stateLock.unlock()
        // Wake blocked send/recv calls; handle() still owns and closes each fd.
        for client in active { shutdown(client, SHUT_RDWR) }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    private func running() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    private func handle(_ fd: Int32) {
        defer {
            stateLock.lock()
            clients.remove(fd)
            stateLock.unlock()
            close(fd)
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout.size(ofValue: noDelay)))
        var keepAlive: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, socklen_t(MemoryLayout.size(ofValue: keepAlive)))
        // Detect a tablet that vanished without a FIN, so an idle /input
        // connection can still be released and a thread cannot leak forever.
        var keepIdle: Int32 = 5
        var keepInterval: Int32 = 5
        var keepCount: Int32 = 3
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, socklen_t(MemoryLayout.size(ofValue: keepIdle)))
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &keepInterval, socklen_t(MemoryLayout.size(ofValue: keepInterval)))
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &keepCount, socklen_t(MemoryLayout.size(ofValue: keepCount)))
        // A tablet that disappears without closing its socket must not pin a
        // server thread forever inside send().
        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        guard let request = readRequest(fd) else { return }
        // /input keeps this socket open and can be idle for a long time.
        setReceiveTimeout(fd, seconds: 0)
        let firstLine = request.header.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")

        if ["/video", "/input", "/pointer"].contains(path), !isAuthorized(request.header) {
            _ = sendResponse(fd, status: "401 Unauthorized", type: "text/plain", body: Data("unauthorized".utf8))
            return
        }

        switch (method, path) {
        case ("GET", "/"):
            let message = "Tablet Display 正在运行。请在平板使用 Tablet Display 应用。"
            _ = sendResponse(fd, status: "200 OK", type: "text/plain; charset=utf-8", body: Data(message.utf8))
        case ("GET", "/health"):
            let text = frames.hasFrames() ? "ready" : "waiting-for-frame"
            _ = sendResponse(fd, status: "200 OK", type: "text/plain", body: Data(text.utf8))
        case ("GET", "/video"):
            streamVideo(fd)
        case ("GET", "/input"):
            streamInput(fd)
        case ("POST", "/pointer"):
            guard request.header.lowercased().contains("content-type: application/json"),
                  let event = try? JSONDecoder().decode(PointerMessage.self, from: request.body),
                  event.x.isFinite, event.y.isFinite,
                  (0...1).contains(event.x), (0...1).contains(event.y),
                  ["down", "move", "drag", "up"].contains(event.phase) else {
                _ = sendResponse(fd, status: "400 Bad Request", type: "text/plain", body: Data("invalid pointer".utf8))
                return
            }
            inject(event)
            _ = sendResponse(fd, status: "204 No Content", type: "text/plain", body: Data())
        default:
            _ = sendResponse(fd, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
        }
    }

    private func readRequest(_ fd: Int32) -> (header: String, body: Data)? {
        let deadline = DispatchTime.now() + .milliseconds(max(1, Int(requestTimeout * 1_000)))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        while data.count <= 16_384 {
            guard setReceiveTimeout(fd, until: deadline) else { return nil }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            guard let range = data.range(of: separator) else { continue }
            let header = String(decoding: data[..<range.lowerBound], as: UTF8.self)
            let contentLength = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            guard contentLength >= 0 && contentLength <= 1024 else { return nil }
            var body = Data(data[range.upperBound...])
            while body.count < contentLength {
                guard setReceiveTimeout(fd, until: deadline) else { return nil }
                let more = recv(fd, &buffer, min(buffer.count, contentLength - body.count), 0)
                if more < 0 && errno == EINTR { continue }
                guard more > 0 else { return nil }
                body.append(contentsOf: buffer.prefix(more))
            }
            return (header, body.prefix(contentLength))
        }
        return nil
    }

    /// Applies the remaining request deadline to the next recv call. Returning
    /// false means the deadline has passed before any data arrived.
    private func setReceiveTimeout(_ fd: Int32, until deadline: DispatchTime) -> Bool {
        let now = DispatchTime.now()
        guard deadline > now else { return false }
        let remaining = deadline.uptimeNanoseconds - now.uptimeNanoseconds
        var timeout = timeval(tv_sec: Int(remaining / 1_000_000_000),
                              tv_usec: Int32((remaining % 1_000_000_000) / 1_000))
        if timeout.tv_sec == 0 && timeout.tv_usec == 0 { timeout.tv_usec = 1_000 }
        return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                          socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    /// A zero timeout disables the receive timeout, which is used for the
    /// long-lived /input stream after the request header has been read.
    private func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
    }

    private func isAuthorized(_ header: String) -> Bool {
        guard !token.isEmpty else { return true }
        let expected = "authorization: bearer \(token)".lowercased()
        for line in header.split(separator: "\r\n") {
            if String(line).trimmingCharacters(in: .whitespaces).lowercased() == expected {
                return true
            }
        }
        return false
    }

    private func sendResponse(_ fd: Int32, status: String, type: String, body: Data) -> Bool {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return sendAll(fd, Data(header.utf8)) && sendAll(fd, body)
    }

    private func streamVideo(_ fd: Int32) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        guard sendAll(fd, Data(header.utf8)) else { return }
        var widthBE = UInt32(width).bigEndian
        var heightBE = UInt32(height).bigEndian
        var fpsBE = UInt32(fps).bigEndian
        guard withUnsafeBytes(of: &widthBE, { sendAll(fd, Data($0)) }),
              withUnsafeBytes(of: &heightBE, { sendAll(fd, Data($0)) }),
              withUnsafeBytes(of: &fpsBE, { sendAll(fd, Data($0)) }) else { return }

        var cursor: UInt64 = 0
        var needsKeyframe = true
        if let first = frames.latestKeyframe() {
            guard sendVideoFrame(fd, first) else { return }
            cursor = first.sequence
            needsKeyframe = false
        } else {
            cursor = frames.latestSequence()
            frames.requestKeyframe()
        }
        while running() {
            if let frame = frames.next(after: cursor, keyframeOnly: needsKeyframe,
                                      timeout: needsKeyframe ? 0.1 : 0.5) {
                guard sendVideoFrame(fd, frame) else { return }
                cursor = frame.sequence
                needsKeyframe = false
            } else {
                // The store has no usable IDR (client just connected or
                // lagged past the GOP). Ask VideoToolbox for one immediately;
                // the store deduplicates requests until it arrives.
                frames.requestKeyframe()
            }
        }
    }

    private func sendVideoFrame(_ fd: Int32, _ frame: EncodedFrame) -> Bool {
        var sizeBE = UInt32(frame.data.count).bigEndian
        var packet = Data([frame.isKeyframe ? 1 : 0])
        withUnsafeBytes(of: &sizeBE) { packet.append(contentsOf: $0) }
        return sendAll(fd, packet) && sendAll(fd, frame.data)
    }

    private func streamInput(_ fd: Int32) {
        guard sendAll(fd, Data("HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\n".utf8)) else { return }
        // If the tablet disappears, the app goes to the background, or touch is
        // disabled while dragging, release the mouse instead of leaving the Mac
        // stuck in a mouse-down state.
        defer { releasePointerIfDown() }
        while running() {
            guard let packet = receiveExactly(fd, count: 9) else { return }
            let xBits = packet[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let yBits = packet[5..<9].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let phase: String
            switch packet[0] {
            case 0: phase = "move"
            case 1: phase = "down"
            case 2: phase = "drag"
            case 3: phase = "up"
            default: continue
            }
            let x = Double(Float(bitPattern: xBits))
            let y = Double(Float(bitPattern: yBits))
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { continue }
            guard updatePointer(phase: phase, x: x, y: y) else { continue }
            inject(PointerMessage(x: x, y: y, phase: phase))
        }
    }

    private func updatePointer(phase: String, x: Double, y: Double) -> Bool {
        touchLock.lock()
        defer { touchLock.unlock() }
        guard touchEnabled else {
            pointerIsDown = false
            return false
        }
        switch phase {
        case "down", "drag":
            pointerIsDown = true
            pointerX = x
            pointerY = y
        case "move":
            pointerX = x
            pointerY = y
        case "up":
            pointerIsDown = false
        default:
            break
        }
        return true
    }

    private func releasePointerIfDown() {
        touchLock.lock()
        guard pointerIsDown else {
            touchLock.unlock()
            return
        }
        pointerIsDown = false
        let x = pointerX
        let y = pointerY
        touchLock.unlock()
        inject(PointerMessage(x: x, y: y, phase: "up"))
    }

    private func receiveExactly(_ fd: Int32, count: Int) -> [UInt8]? {
        var result = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = result.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { return nil }
            offset += received
        }
        return result
    }

    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private func inject(_ event: PointerMessage) {
        if let pointerHandler {
            pointerHandler(event)
            return
        }
        let bounds = CGDisplayBounds(displayID)
        let point = CGPoint(x: bounds.minX + event.x * bounds.width,
                            y: bounds.minY + event.y * bounds.height)
        let type: CGEventType
        switch event.phase {
        case "down": type = .leftMouseDown
        case "up": type = .leftMouseUp
        case "drag": type = .leftMouseDragged
        default: type = .mouseMoved
        }
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
