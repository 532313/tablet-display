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

print("核心测试通过：尺寸解析、帧队列恢复、采集代次竞态、路由与子网选卡")
