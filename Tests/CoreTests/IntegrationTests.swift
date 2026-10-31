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
    let flag = try socket.readExactly(1)[0]
    let length = Int(uint32BE(try socket.readExactly(4)))
    let payload = try socket.readExactly(length)
    return (flag == 1, payload)
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
        try testInputAndDisconnectRelease()
        try testTouchDisabledGate()
        try testInputIdleAfterRequest()
        try testReconnect()
        try testRequestTimeout()
        print("集成测试通过：/video 帧格式与鉴权、/input 解析、触摸开关、断连释放、长连接超时隔离、重连、请求超时")
    } catch {
        preconditionFailure("集成测试失败：\(error)")
    }
}
