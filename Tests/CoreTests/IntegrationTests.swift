import CoreMedia
import CoreVideo
import Foundation

private final class PointerRecorder {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var events: [PointerMessage] = []

    func append(_ event: PointerMessage) {
        lock.lock()
        events.append(event)
        lock.unlock()
        signal.signal()
    }

    func waitForCount(_ count: Int, timeout: TimeInterval = 3) -> [PointerMessage]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            let snapshot = events
            lock.unlock()
            if snapshot.count >= count { return snapshot }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = signal.wait(timeout: .now() + .milliseconds(max(1, Int(remaining * 1_000))))
        }
    }
}

private func request(_ path: String, token: String?) -> Data {
    var head = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n"
    if let token { head += "Authorization: Bearer \(token)\r\n" }
    head += "\r\n"
    return Data(head.utf8)
}

private func readVideoPacket(_ socket: TestSocket) throws -> (keyframe: Bool, data: Data) {
    let raw = try readRawVideoPacket(socket)
    return (raw.flag == 1, raw.data)
}

private func readRawVideoPacket(_ socket: TestSocket) throws -> (flag: UInt8, data: Data) {
    let flag = try socket.readExactly(1)[0]
    let length = Int(uint32BE(try socket.readExactly(4)))
    let payload = try socket.readExactly(length)
    return (flag, payload)
}

private func pointerPacket(_ phase: UInt8, x: Float, y: Float) -> Data {
    var packet = Data([phase])
    packet.append(floatBE(x))
    packet.append(floatBE(y))
    return packet
}

private func testVideoFrames() throws {
    let store = VideoFrameStore()
    let keyframe = Data([0, 0, 0, 1, 0x65, 0x11, 0x22])
    let delta = Data([0, 0, 0, 1, 0x41, 0x33])
    store.append(keyframe, keyframe: true)
    store.append(delta, keyframe: false)

    let server = HTTPServer(frames: store, displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token")
    try server.start(port: 0)
    defer { server.stop() }

    let unauthorized = try TestSocket(port: server.boundPort)
    defer { unauthorized.close() }
    try unauthorized.send(request("/video", token: nil))
    let rejected = try unauthorized.readUntil(Data("\r\n\r\n".utf8))
    check(String(decoding: rejected, as: UTF8.self).contains("401 Unauthorized"),
          "无 token 的 /video 必须返回 401")

    let socket = try TestSocket(port: server.boundPort)
    defer { socket.close() }
    try socket.send(request("/video", token: "test-token"))
    let header = try socket.readUntil(Data("\r\n\r\n".utf8))
    check(String(decoding: header, as: UTF8.self).contains("200 OK"),
          "/video 应返回 200")

    let dimensions = try socket.readExactly(12)
    check(uint32BE(dimensions, offset: 0) == 640, "视频宽度头应正确")
    check(uint32BE(dimensions, offset: 4) == 480, "视频高度头应正确")
    check(uint32BE(dimensions, offset: 8) == 60, "视频帧率头应正确")

    let first = try readVideoPacket(socket)
    check(first.keyframe, "第一帧应为关键帧")
    check(first.data == keyframe, "关键帧数据应完整")
    let second = try readVideoPacket(socket)
    check(!second.keyframe, "第二帧应为非关键帧")
    check(second.data == delta, "非关键帧数据应完整")
}

private func testInputAndDisconnectRelease() throws {
    let recorder = PointerRecorder()
    let store = VideoFrameStore()
    let server = HTTPServer(frames: store, displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token",
                            pointerHandler: { recorder.append($0) })
    try server.start(port: 0)
    defer { server.stop() }

    let socket = try TestSocket(port: server.boundPort)
    defer { socket.close() }
    try socket.send(request("/input", token: "test-token"))
    let header = try socket.readUntil(Data("\r\n\r\n".utf8))
    check(String(decoding: header, as: UTF8.self).contains("200 OK"), "/input 应返回 200")

    try socket.send(pointerPacket(1, x: 0.25, y: 0.75))
    guard let events = recorder.waitForCount(1) else {
        preconditionFailure("未收到 down 事件")
    }
    check(events[0].phase == "down", "第一个事件应为 down")
    check(abs(events[0].x - 0.25) < 0.001 && abs(events[0].y - 0.75) < 0.001,
          "down 坐标应正确解析")

    try socket.send(pointerPacket(2, x: 0.5, y: 0.5))
    guard let dragged = recorder.waitForCount(2) else {
        preconditionFailure("未收到 drag 事件")
    }
    check(dragged[1].phase == "drag", "第二个事件应为 drag")

    try socket.send(pointerPacket(3, x: 0.5, y: 0.5))
    guard let released = recorder.waitForCount(3) else {
        preconditionFailure("未收到 up 事件")
    }
    check(released[2].phase == "up", "第三个事件应为 up")

    // A client that disconnects mid-drag must still release the mouse.
    let dropping = try TestSocket(port: server.boundPort)
    try dropping.send(request("/input", token: "test-token"))
    _ = try dropping.readUntil(Data("\r\n\r\n".utf8))
    try dropping.send(pointerPacket(1, x: 0.4, y: 0.6))
    guard recorder.waitForCount(4) != nil else {
        preconditionFailure("未收到第二个连接的 down 事件")
    }
    dropping.close()
    guard let afterDrop = recorder.waitForCount(5) else {
        preconditionFailure("连接断开后未自动发送 up")
    }
    check(afterDrop[4].phase == "up", "断连释放事件应为 up")
}

private final class OrientationRecorder {
    private let lock = NSLock()
    private var value: Bool?
    func append(_ portrait: Bool) {
        lock.lock()
        value = portrait
        lock.unlock()
    }
    func current() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func testOrientationReport() throws {
    let recorder = OrientationRecorder()
    let server = HTTPServer(frames: VideoFrameStore(), displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token",
                            orientationHandler: { portrait, completion in
                                recorder.append(portrait)
                                completion(true)
                            })
    try server.start(port: 0)
    defer { server.stop() }

    let socket = try TestSocket(port: server.boundPort)
    defer { socket.close() }
    let body = Data("{\"portrait\":true}".utf8)
    var request = "POST /orientation HTTP/1.1\r\nHost: localhost\r\n"
    request += "Authorization: Bearer test-token\r\n"
    request += "Content-Type: application/json\r\n"
    request += "Content-Length: \(body.count)\r\n\r\n"
    try socket.send(Data(request.utf8) + body)
    let response = try socket.readUntil(Data("\r\n\r\n".utf8))
    check(String(decoding: response, as: UTF8.self).contains("204 No Content"),
          "/orientation 应返回 204")
    check(recorder.current() == true, "应回调平板竖屏方向")
}

private func testOrientationFailureResponse() throws {
    let server = HTTPServer(frames: VideoFrameStore(), displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token",
                            orientationHandler: { _, completion in completion(false) })
    try server.start(port: 0)
    defer { server.stop() }

    let socket = try TestSocket(port: server.boundPort)
    defer { socket.close() }
    let body = Data("{\"portrait\":true}".utf8)
    var request = "POST /orientation HTTP/1.1\r\nHost: localhost\r\n"
    request += "Authorization: Bearer test-token\r\n"
    request += "Content-Type: application/json\r\n"
    request += "Content-Length: \(body.count)\r\n\r\n"
    try socket.send(Data(request.utf8) + body)
    let response = try socket.readUntil(Data("\r\n\r\n".utf8))
    check(String(decoding: response, as: UTF8.self).contains("409 Conflict"),
          "方向切换失败应返回 409 以便平板重试")
}

private func testRTPMetadataUpdate() throws {
    let firstFrames = VideoFrameStore()
    firstFrames.append(Data([0, 0, 0, 1, 0x65, 0x01]), keyframe: true)
    let server = RTPVideoServer(frames: firstFrames, token: "udp-token",
                                width: 640, height: 480, fps: 60)
    let port = try server.start(port: 0)
    defer { server.stop() }

    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw TestSocketError(message: "UDP socket() 失败") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
               socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    func send(_ text: String) throws {
        let data = Data(text.utf8)
        let sent = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, base, data.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent != data.count { throw TestSocketError(message: "UDP send() 失败") }
    }

    func receiveText() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<12 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw TestSocketError(message: "UDP recv() 失败: \(String(cString: strerror(errno)))")
            }
            if buffer[0] & 0x80 != 0 { continue } // RTP data packet
            return String(decoding: buffer[0..<Int(count)], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw TestSocketError(message: "未收到 META")
    }

    try send("HELLO udp-token\n")
    let initial = try receiveText()
    check(initial == "META 640 480 60", "UDP 初次握手应返回 META")

    let secondFrames = VideoFrameStore()
    secondFrames.append(Data([0, 0, 0, 1, 0x65, 0x02]), keyframe: true)
    server.updateVideo(frames: secondFrames, width: 800, height: 600, fps: 60)
    let changed = try receiveText()
    check(changed == "META 800 600 60", "UDP 分辨率切换应发送新 META")
}

private final class FakeFrameEncoder: FrameEncoding {
    func encode(_ image: CVImageBuffer, timestamp: CMTime) {}
    func stop() {}
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?
    func set(_ error: Error?) {
        lock.lock()
        value = error
        lock.unlock()
    }
    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func testCaptureFailureInjection() throws {
    let capture = DisplayCapture(encoder: FakeFrameEncoder())
    CaptureFaultInjection.inject(CaptureError.displayUnavailable)
    let box = ErrorBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            try await capture.start(displayID: 0, width: 640, height: 480, fps: 60)
            box.set(nil)
        } catch {
            box.set(error)
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 3) == .success,
          let error = box.get() else {
        preconditionFailure("注入的采集失败没有被抛出")
    }
    check(StartupFailurePolicy.isRecoverable(error),
          "采集启动失败应被启动策略识别为可恢复")
}

private func testPortConflict() throws {
    let first = HTTPServer(frames: VideoFrameStore(), displayID: 0, width: 640, height: 480,
                           fps: 60, token: "test-token")
    try first.start(port: 0)
    defer { first.stop() }
    let second = HTTPServer(frames: VideoFrameStore(), displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token")
    do {
        try second.start(port: first.boundPort)
        second.stop()
        preconditionFailure("同一端口不应允许第二个服务启动")
    } catch {
        // Expected.
    }
}

private func testVideoFormatChange() throws {
    let firstFrames = VideoFrameStore()
    firstFrames.append(Data([0, 0, 0, 1, 0x65, 0x11]), keyframe: true)
    let server = HTTPServer(frames: firstFrames, displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token")
    try server.start(port: 0)
    defer { server.stop() }

    let socket = try TestSocket(port: server.boundPort)
    defer { socket.close() }
    try socket.send(request("/video", token: "test-token"))
    _ = try socket.readUntil(Data("\r\n\r\n".utf8))
    _ = try socket.readExactly(12) // initial width/height/fps
    _ = try readVideoPacket(socket) // initial IDR

    let secondFrames = VideoFrameStore()
    secondFrames.append(Data([0, 0, 0, 1, 0x65, 0x22]), keyframe: true)
    server.updateVideo(frames: secondFrames, width: 800, height: 600, fps: 60)

    var format: Data?
    for _ in 0..<8 {
        let packet = try readRawVideoPacket(socket)
        if packet.flag == 2 {
            format = packet.data
            break
        }
    }
    guard let format, format.count == 12 else {
        preconditionFailure("切换分辨率时应收到 TCP 格式变更帧")
    }
    check(uint32BE(format, offset: 0) == 800 && uint32BE(format, offset: 4) == 600,
          "TCP 格式变更帧应携带新宽高")
    check(uint32BE(format, offset: 8) == 60, "TCP 格式变更帧应携带帧率")
}

private func testTouchDisabledGate() throws {
    let recorder = PointerRecorder()
    let server = HTTPServer(frames: VideoFrameStore(), displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token",
                            pointerHandler: { recorder.append($0) })
    try server.start(port: 0)
    defer { server.stop() }

    let socket = try TestSocket(port: server.boundPort)
    defer { socket.close() }
    try socket.send(request("/input", token: "test-token"))
    _ = try socket.readUntil(Data("\r\n\r\n".utf8))

    try socket.send(pointerPacket(1, x: 0.25, y: 0.75))
    _ = recorder.waitForCount(1)

    server.setTouchEnabled(false)
    guard let released = recorder.waitForCount(2) else {
        preconditionFailure("禁用触摸时应补发 up")
    }
    check(released[1].phase == "up", "禁用触摸应释放按下的鼠标")

    try socket.send(pointerPacket(2, x: 0.5, y: 0.5))
    check(recorder.waitForCount(3, timeout: 0.3) == nil, "禁用触摸后应忽略拖动")

    server.setTouchEnabled(true)
    try socket.send(pointerPacket(1, x: 0.4, y: 0.6))
    guard let resumed = recorder.waitForCount(3) else {
        preconditionFailure("重新启用触摸后应恢复事件")
    }
    check(resumed[2].phase == "down", "重新启用后应收到新的 down")
}

private func testInputIdleAfterRequest() throws {
    let recorder = PointerRecorder()
    let store = VideoFrameStore()
    let server = HTTPServer(frames: store, displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token", requestTimeout: 0.2,
                            pointerHandler: { recorder.append($0) })
    try server.start(port: 0)
    defer { server.stop() }

    let socket = try TestSocket(port: server.boundPort)
    defer { socket.close() }
    try socket.send(request("/input", token: "test-token"))
    _ = try socket.readUntil(Data("\r\n\r\n".utf8))
    // The request read timeout must be cleared for the long-lived input
    // stream; otherwise this idle period would close the connection.
    Thread.sleep(forTimeInterval: 0.5)
    try socket.send(pointerPacket(1, x: 0.3, y: 0.7))
    guard let events = recorder.waitForCount(1) else {
        preconditionFailure("请求超时被错误地应用到 /input 长连接")
    }
    check(events[0].phase == "down", "超时清理后仍应收到 down 事件")
}

private func testReconnect() throws {
    let store = VideoFrameStore()
    let firstKeyframe = Data([0, 0, 0, 1, 0x65, 0xAA])
    store.append(firstKeyframe, keyframe: true)

    let server = HTTPServer(frames: store, displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token")
    try server.start(port: 0)
    defer { server.stop() }

    let first = try TestSocket(port: server.boundPort)
    try first.send(request("/video", token: "test-token"))
    _ = try first.readUntil(Data("\r\n\r\n".utf8))
    _ = try first.readExactly(12)
    let firstPacket = try readVideoPacket(first)
    check(firstPacket.data == firstKeyframe, "首次连接应收到关键帧")
    first.close()

    let secondKeyframe = Data([0, 0, 0, 1, 0x65, 0xBB])
    store.append(secondKeyframe, keyframe: true)

    let second = try TestSocket(port: server.boundPort)
    defer { second.close() }
    try second.send(request("/video", token: "test-token"))
    _ = try second.readUntil(Data("\r\n\r\n".utf8))
    _ = try second.readExactly(12)
    let secondPacket = try readVideoPacket(second)
    check(secondPacket.keyframe && secondPacket.data == secondKeyframe,
          "重连后应从最新关键帧开始")
}

private func testRequestTimeout() throws {
    let store = VideoFrameStore()
    let server = HTTPServer(frames: store, displayID: 0, width: 640, height: 480,
                            fps: 60, token: "test-token", requestTimeout: 0.2)
    try server.start(port: 0)
    defer { server.stop() }

    let silent = try TestSocket(port: server.boundPort)
    defer { silent.close() }
    check(silent.waitForClose(timeout: 3), "未发送请求的连接应在超时后被服务端关闭")
}

func runIntegrationTests() {
    do {
        try testVideoFrames()
        try testPortConflict()
        try testCaptureFailureInjection()
        try testVideoFormatChange()
        try testRTPMetadataUpdate()
        try testInputAndDisconnectRelease()
        try testTouchDisabledGate()
        try testOrientationReport()
        try testOrientationFailureResponse()
        try testInputIdleAfterRequest()
        try testReconnect()
        try testRequestTimeout()
        print("集成测试通过：/video 帧格式/切换、UDP META 切换、端口占用、采集故障注入、/input 解析、触摸开关、方向回执、断连释放、长连接超时隔离、重连、请求超时")
    } catch {
        preconditionFailure("集成测试失败：\(error)")
    }
}
