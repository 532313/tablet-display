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

print("核心测试通过：尺寸解析、关键帧启动、顺序传输、积压丢帧与溢出恢复")
