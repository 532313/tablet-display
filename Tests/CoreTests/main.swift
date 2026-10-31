import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let display = "mBaseDisplayInfo=DisplayInfo{real 2560 x 1600, app 2560 x 1600, rotation 1}"
let wm = "Physical size: 2560x1600\nOverride size: 1600x2560"
let logical = ADB.parseScreenSize(displayInfo: display, wmOutput: wm)
check(logical?.0 == 2560 && logical?.1 == 1600, "当前逻辑尺寸优先于未旋转的 wm size")

let fallback = ADB.parseScreenSize(displayInfo: nil, wmOutput: "Physical size: 2560x1600\nOverride size: 1200x1920")
check(fallback?.0 == 2560 && fallback?.1 == 1600, "缺少 DisplayInfo 时仍使用 Physical 硬件尺寸")
let overrideOnly = ADB.parseScreenSize(displayInfo: nil, wmOutput: "Override size: 1200x1920")
check(overrideOnly?.0 == 1200 && overrideOnly?.1 == 1920, "只有 override 时作为最后兜底")
check(ADB.parseScreenSize(displayInfo: "bad", wmOutput: "bad") == nil, "无效尺寸不应被接受")

let frames = VideoFrameStore()
check(!frames.hasFrames(), "新队列不应有视频帧")
frames.append(Data([1]), keyframe: false)
frames.append(Data([2]), keyframe: true)
frames.append(Data([3]), keyframe: false)
check(frames.latestKeyframe()?.data == Data([2]), "新客户端需要最近的关键帧")
check(frames.next(after: 2, keyframeOnly: false)?.data == Data([3]), "后续帧须顺序送达")

let overflow = VideoFrameStore()
for number in 0..<100 { overflow.append(Data([UInt8(number)]), keyframe: number % 10 == 0) }
check(overflow.next(after: 1, keyframeOnly: false)?.data == Data([90]), "队列溢出后应跳到最近的关键帧")

let lagging = VideoFrameStore()
for number in 0..<32 { lagging.append(Data([UInt8(number)]), keyframe: number % 10 == 0) }
check(lagging.next(after: 1, keyframeOnly: false)?.data == Data([30]), "积压超过 15 帧时应追上最近的关键帧")

var captureGeneration = CaptureGeneration()
let firstCapture = captureGeneration.start()
check(captureGeneration.isCurrent(firstCapture), "新启动的采集代次应有效")
_ = captureGeneration.stop()
check(!captureGeneration.isCurrent(firstCapture), "停止应使挂起中的旧启动失效")
let secondCapture = captureGeneration.start()
check(captureGeneration.isCurrent(secondCapture) && !captureGeneration.isCurrent(firstCapture),
      "重新启动只应接受最新采集代次")

let parsed = try! Options.parse([
    "--width", "1920", "--height", "1200", "--fps", "60", "--bitrate", "20",
    "--port", "9137", "--serial", "192.168.1.2:5555", "--direct-host", "192.168.1.10",
    "--token", "abc", "--duration", "1.5", "--no-hidpi"
])
check(parsed.width == 1920 && parsed.height == 1200, "合法分辨率应被接受")
check(parsed.port == 9137 && parsed.fps == 60 && parsed.bitrateMbps == 20, "合法端口/帧率/码率应被接受")
check(parsed.directHost == "192.168.1.10" && parsed.serial == "192.168.1.2:5555", "直连地址与序列号应保留")
check(parsed.duration == 1.5 && parsed.hidpi == false, "运行时长与 HiDPI 开关应保留")
check(parsed.bitrateExplicit, "显式 --bitrate 应被记录")
let defaultOptions = try! Options.parse([])
check(!defaultOptions.bitrateExplicit, "未传 --bitrate 时不应标记为显式")

func rejects(_ args: [String], _ message: String) {
    do {
        _ = try Options.parse(args)
        preconditionFailure(message)
    } catch {
        // expected
    }
}
rejects(["--width", "abc"], "非法宽度必须报错")
rejects(["--height", "abc"], "非法高度必须报错")
rejects(["--duration", "abc"], "非法运行时长必须报错")
rejects(["--duration", "0"], "零运行时长必须报错")
rejects(["--port", "0"], "零端口必须报错")
rejects(["--port", "70000"], "超出范围的端口必须报错")
rejects(["--width", "100"], "过小的宽度必须报错")
rejects(["--height", "100"], "过小的高度必须报错")
rejects(["--fps", "10"], "过低的帧率必须报错")
rejects(["--bitrate", "100"], "过高的码率必须报错")
rejects(["--direct-host", "bad"], "非法直连地址必须报错")
rejects(["--no-adb", "--direct-host", "192.168.1.10"], "--no-adb 与直连不能同时使用")
rejects(["--token", ""], "空 token 必须报错")

let interfaces = [
    LocalNetworkInterfaceAddress(name: "en0", address: "192.168.50.99", netmask: "255.255.255.0",
                                 isUp: true, isLoopback: false),
    LocalNetworkInterfaceAddress(name: "en1", address: "192.168.50.1", netmask: "255.255.255.248",
                                 isUp: true, isLoopback: false),
    LocalNetworkInterfaceAddress(name: "lo0", address: "192.168.50.2", netmask: "255.255.255.0",
                                 isUp: true, isLoopback: true),
    LocalNetworkInterfaceAddress(name: "en2", address: "192.168.50.3", netmask: "255.255.255.0",
                                 isUp: false, isLoopback: false)
]
check(LocalNetwork.selectAddress(towards: "192.168.50.6", routeInterface: nil,
                                 interfaces: interfaces) == "192.168.50.1",
      "网卡选择应使用真实掩码并优先最长匹配前缀")
let overlappingInterfaces = [
    LocalNetworkInterfaceAddress(name: "en0", address: "10.0.0.2", netmask: "255.255.255.0",
                                 isUp: true, isLoopback: false),
    LocalNetworkInterfaceAddress(name: "en1", address: "10.0.0.3", netmask: "255.255.255.0",
                                 isUp: true, isLoopback: false)
]
check(LocalNetwork.selectAddress(towards: "10.0.0.9", routeInterface: "en1",
                                 interfaces: overlappingInterfaces) == "10.0.0.3",
      "有重叠网段时应优先使用系统路由指定的网卡")
check(LocalNetwork.parseRouteInterface("route to: 192.168.1.2\ninterface: en7\n") == "en7",
      "应解析 route 查询结果中的接口")
check(LocalNetwork.selectAddress(towards: "bad", routeInterface: nil,
                                 interfaces: interfaces) == nil,
      "无效目标地址不能匹配任意网卡")

let mdns = """
List of discovered mdns services
adb-abc _adb-tls-connect._tcp 192.168.1.51:37123
printer _ipp._tcp 192.168.1.20:631
"""
check(ADB.parseMDNSServices(mdns) == ["192.168.1.51:37123"],
      "应只提取 adb 的 mDNS 无线调试地址")
check(ADB.isWireless("192.168.1.51:37123"), "mDNS 返回的地址应被识别为无线 ADB")

let annexB = Data([0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F,
                   0, 0, 1, 0x68, 0xCE, 0x3C, 0x80,
                   0, 0, 0, 1, 0x65, 0x88, 0x84])
let nals = RTPVideoServer.nalUnits(annexB)
check(nals.count == 3, "应拆分出 SPS/PPS/IDR 三个 NAL")
check(nals[0].first == 0x67 && nals[1].first == 0x68 && nals[2].first == 0x65,
      "应同时支持 4 字节和 3 字节 Annex-B 起始码")


let hiDPI = DisplayGeometry(pixelWidth: 2560, pixelHeight: 1600, useHiDPI: true)
check(hiDPI.isHiDPI && hiDPI.logicalWidth == 1280 && hiDPI.logicalHeight == 800,
      "HiDPI 初始逻辑尺寸应为像素的一半")
let hiDPIPortrait = hiDPI.oriented(portrait: true)
check(hiDPIPortrait.pixelWidth == 1600 && hiDPIPortrait.pixelHeight == 2560,
      "HiDPI 竖屏应交换像素尺寸")
check(hiDPIPortrait.logicalWidth == 800 && hiDPIPortrait.logicalHeight == 1280,
      "HiDPI 竖屏应保留 2x 逻辑尺寸")
let nonHiDPI = DisplayGeometry(pixelWidth: 1470, pixelHeight: 956, useHiDPI: false)
check(nonHiDPI.oriented(portrait: true).pixelWidth == 956 &&
      nonHiDPI.oriented(portrait: true).logicalWidth == 956,
      "非 HiDPI 方向切换应保持逻辑等于像素")
check(hiDPI.oriented(portrait: true).oriented(portrait: false) == hiDPI,
      "横竖屏往返应恢复原始几何")


check(StartupFailurePolicy.isRecoverable(CLIError.screenRecording), "屏幕录制权限错误应可恢复")
check(StartupFailurePolicy.isRecoverable(CLIError.virtualDisplay), "虚拟屏创建错误应可恢复")
check(StartupFailurePolicy.isRecoverable(CaptureError.encoder(-1)), "编码器错误应可恢复")
check(StartupFailurePolicy.isRecoverable(ServerError.listenFailed(48)), "端口占用应可恢复")
check(!StartupFailurePolicy.isRecoverable(CLIError.invalid("bad")), "非法 CLI 参数不应保留后台实例")
check(!StartupFailurePolicy.isRecoverable(NSError(domain: "test", code: 1)), "未知错误不应伪装成可恢复")


let pairing = PairingQRCode.url(host: "192.168.1.54", port: 9137,
                                token: "abc", udpPort: 9138)
check(pairing?.scheme == "tabletdisplay" && pairing?.host == "pair",
      "配对 URL 应使用 tabletdisplay://pair")
check(pairing?.query?.contains("host=192.168.1.54") == true &&
      pairing?.query?.contains("token=abc") == true &&
      pairing?.query?.contains("udpPort=9138") == true,
      "配对 URL 应携带 host/token/UDP 端口")
check(pairing.flatMap { PairingQRCode.image(for: $0.absoluteString) } != nil,
      "配对 URL 应能生成二维码图片")

runIntegrationTests()
print("核心测试通过：尺寸解析、帧队列恢复、采集代次竞态、路由与子网选卡、严格参数解析、mDNS 地址解析、RTP NAL 拆分")
