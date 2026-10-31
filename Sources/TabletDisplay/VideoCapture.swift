import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

struct EncodedFrame {
    let sequence: UInt64
    let data: Data
    let isKeyframe: Bool
}

final class VideoFrameStore {
    private let condition = NSCondition()
    private var frames: [EncodedFrame] = []
    private var sequence: UInt64 = 0
    private var keyframeRequested = false
    var onKeyframeNeeded: (() -> Void)?

    func append(_ data: Data, keyframe: Bool) {
        condition.lock()
        sequence &+= 1
        frames.append(EncodedFrame(sequence: sequence, data: data, isKeyframe: keyframe))
        if frames.count > 90 { frames.removeFirst(frames.count - 90) }
        if keyframe { keyframeRequested = false }
        condition.broadcast()
        condition.unlock()
    }

    /// Ask the encoder for an IDR without polling every frame. The flag is
    /// cleared when the keyframe actually arrives.
    func requestKeyframe() {
        condition.lock()
        let shouldRequest = !keyframeRequested
        keyframeRequested = true
        condition.unlock()
        if shouldRequest { onKeyframeNeeded?() }
    }

    func latestSequence() -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return sequence
    }

    func hasFrames() -> Bool { latestSequence() > 0 }

    func latestKeyframe() -> EncodedFrame? {
        condition.lock()
        defer { condition.unlock() }
        return frames.last(where: \.isKeyframe)
    }

    func next(after cursor: UInt64, keyframeOnly: Bool, timeout: TimeInterval = 0.5) -> EncodedFrame? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let missingHistory = frames.first.map { cursor + 1 < $0.sequence } ?? false
            let lagging = sequence > cursor && sequence - cursor > 15
            let candidate: EncodedFrame?
            if keyframeOnly || missingHistory || lagging {
                candidate = frames.last { $0.sequence > cursor && $0.isKeyframe }
            } else {
                candidate = frames.first { $0.sequence > cursor }
            }
            if let candidate { return candidate }
            if !condition.wait(until: deadline) { return nil }
        }
    }
}

enum CaptureError: LocalizedError {
    case displayUnavailable
    case encoder(OSStatus)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "虚拟显示器没有出现在 ScreenCaptureKit 中。请检查“屏幕录制”权限后重启程序。"
        case .encoder(let status):
            return "H.264 编码器启动失败（OSStatus \(status)）。"
        }
    }
}

/// A token invalidates any capture start that was suspended in an async call
/// when stop/restart changes the requested lifecycle.
struct CaptureGeneration {
    private(set) var value: UInt64 = 0
    private(set) var isStopped = false

    mutating func start() -> UInt64 {
        value &+= 1
        isStopped = false
        return value
    }

    mutating func stop() -> UInt64 {
        value &+= 1
        isStopped = true
        return value
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        value == candidate && !isStopped
    }
}

protocol FrameEncoding: AnyObject {
    func encode(_ image: CVImageBuffer, timestamp: CMTime)
    func stop()
}

/// Test-only entry point for simulating a capture startup failure. Production
/// never sets an error here.
enum CaptureFaultInjection {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var nextError: Error?

    static func inject(_ error: Error) {
        lock.lock()
        nextError = error
        lock.unlock()
    }

    static func take() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        let value = nextError
        nextError = nil
        return value
    }
}

final class H264Encoder: @unchecked Sendable, FrameEncoding {
    private var session: VTCompressionSession?
    private let frames: VideoFrameStore
    private let sessionLock = NSLock()
    private let statsLock = NSLock()
    private var forceKeyframe = false
    private var statsStart = Date()
    private var submitted = 0
    private var completed = 0
    private var dropped = 0

    init(width: Int, height: Int, bitrate: Int, fps: Int, frames: VideoFrameStore) throws {
        self.frames = frames
        var created: VTCompressionSession?
        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, flags, sampleBuffer in
                guard let refcon else { return }
                Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
                    .receive(status: status, flags: flags, sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw CaptureError.encoder(status) }
        session = created
        try property(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try property(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // Some hardware H.264 encoders do not expose MaxFrameDelayCount.
        try? property(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 1))
        try property(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        // Periodic IDRs are expensive bursts on Wi-Fi. Keep only a slow
        // safety net; new or lagging clients request an immediate IDR instead.
        try property(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: max(1, fps * 60)))
        try property(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        try property(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        let rateLimit = [NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray
        let rateStatus = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_DataRateLimits,
                                              value: rateLimit)
        if rateStatus != noErr {
            print("提示：硬件编码器不支持码率峰值限制（OSStatus \(rateStatus)）。")
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
        guard prepared == noErr else { throw CaptureError.encoder(prepared) }
        var hardwareValue: UnsafeMutableRawPointer?
        if VTSessionCopyProperty(created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 allocator: kCFAllocatorDefault, valueOut: &hardwareValue) == noErr,
           let hardwareValue {
            let hardwareUsed = Unmanaged<CFBoolean>.fromOpaque(hardwareValue).takeRetainedValue()
            print("VideoToolbox 硬件编码：\(CFBooleanGetValue(hardwareUsed) ? "是" : "否")")
        }
    }

    private func property(_ key: CFString, _ value: CFTypeRef) throws {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw CaptureError.encoder(status) }
    }

    func encode(_ image: CVImageBuffer, timestamp: CMTime) {
        sessionLock.lock()
        guard let session else {
            sessionLock.unlock()
            return
        }
        let frameProperties: CFDictionary?
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyframe = false
        } else {
            frameProperties = nil
        }
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image,
            presentationTimeStamp: timestamp,
            duration: .invalid, frameProperties: frameProperties,
            sourceFrameRefcon: nil, infoFlagsOut: &flags
        )
        sessionLock.unlock()
        if status != noErr { fputs("H.264 编码帧失败：\(status)\n", stderr) }
        statsLock.lock()
        submitted += 1
        if flags.contains(.frameDropped) { dropped += 1 }
        let elapsed = Date().timeIntervalSince(statsStart)
        if elapsed >= 5 {
            fputs(String(format: "编码统计：输入 %.1f fps，输出 %.1f fps，丢帧 %.1f fps\n",
                         Double(submitted) / elapsed, Double(completed) / elapsed,
                         Double(dropped) / elapsed), stderr)
            submitted = 0
            completed = 0
            dropped = 0
            statsStart = Date()
        }
        statsLock.unlock()
    }

    func requestKeyframe() {
        sessionLock.lock()
        forceKeyframe = true
        sessionLock.unlock()
    }

    /// Updates the target bitrate without restarting capture or the encoder.
    func updateBitrate(_ bitrate: Int) {
        guard bitrate > 0 else { return }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        let rateLimit = [NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: rateLimit)
    }

    func stop() {
        sessionLock.lock()
        let current = session
        session = nil
        sessionLock.unlock()
        guard let current else { return }
        VTCompressionSessionCompleteFrames(current, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(current)
    }

    private func receive(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        statsLock.lock()
        if flags.contains(.frameDropped) { dropped += 1 }
        if status == noErr && sampleBuffer != nil { completed += 1 }
        statsLock.unlock()
        guard status == noErr, let sampleBuffer else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
        var output = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: nil
                )
                if status == noErr, let pointer {
                    output.append(contentsOf: [0, 0, 0, 1])
                    output.append(pointer, count: size)
                }
            }
        }

        let total = CMBlockBufferGetDataLength(block)
        guard total > 4 else { return }
        var avcc = Data(count: total)
        let copyStatus = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: bytes.baseAddress!)
        }
        guard copyStatus == noErr else { return }
        avcc.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + 4 <= bytes.count {
                let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) |
                    (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
                offset += 4
                guard length > 0, offset + length <= bytes.count else { break }
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(bytes.baseAddress!.advanced(by: offset), count: length)
                offset += length
            }
        }
        if !output.isEmpty { frames.append(output, keyframe: isKeyframe) }
    }
}

final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct Config {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let fps: Int
    }

    private let encoder: any FrameEncoding
    private let queue = DispatchQueue(label: "tablet-display.capture", qos: .userInitiated)
    private let imageLock = NSLock()
    private var latestImage: CVImageBuffer?
    private let stateLock = NSLock()
    private var config: Config?
    private var timer: DispatchSourceTimer?
    private var stream: SCStream?
    private var generation = CaptureGeneration()
    private var restartingGeneration: UInt64?

    init(encoder: any FrameEncoding) { self.encoder = encoder }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func withImage<T>(_ body: () -> T) -> T {
        imageLock.lock()
        defer { imageLock.unlock() }
        return body()
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        if let injected = CaptureFaultInjection.take() {
            throw injected
        }
        let captureGeneration = withState { () -> UInt64 in
            config = Config(displayID: displayID, width: width, height: height, fps: fps)
            restartingGeneration = nil
            return generation.start()
        }
        _ = try await startStream(generation: captureGeneration)
    }

    private func startStream(generation captureGeneration: UInt64) async throws -> Bool {
        let snapshot = withState { (config, generation.isCurrent(captureGeneration)) }
        guard let current = snapshot.0, snapshot.1 else { return false }

        var target: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard isCurrent(captureGeneration) else { return false }
            target = content.displays.first(where: { $0.displayID == current.displayID })
            if target != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
            guard isCurrent(captureGeneration) else { return false }
        }
        guard let target else { throw CaptureError.displayUnavailable }

        let previous = withState { () -> (SCStream?, DispatchSourceTimer?)? in
            guard generation.isCurrent(captureGeneration) else { return nil }
            let old = (stream, timer)
            stream = nil
            timer = nil
            return old
        }
        guard let previous else { return false }
        previous.1?.cancel()
        if let old = previous.0 { try? await old.stopCapture() }
        // The timer and any already queued ScreenCaptureKit callbacks share
        // this queue. Drain them before clearing the image or changing streams.
        queue.sync {}
        withImage { latestImage = nil }
        guard isCurrent(captureGeneration) else { return false }

        let filter = SCContentFilter(display: target, excludingApplications: [], exceptingWindows: [])
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = current.width
        streamConfig.height = current.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(current.fps))
        streamConfig.queueDepth = 5
        streamConfig.showsCursor = true
        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await newStream.startCapture()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / current.fps),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let image = self.withImage({ self.latestImage }) else { return }
            self.encoder.encode(image, timestamp: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        let installed = withState { () -> Bool in
            guard generation.isCurrent(captureGeneration) else { return false }
            stream = newStream
            self.timer = timer
            timer.resume()
            return true
        }
        guard installed else {
            // A dispatch source must be resumed before it can be canceled.
            timer.resume()
            timer.cancel()
            try? await newStream.stopCapture()
            return false
        }
        return true
    }

    func stop() async {
        let previous = withState { () -> (SCStream?, DispatchSourceTimer?) in
            _ = generation.stop()
            restartingGeneration = nil
            let value = (stream, timer)
            stream = nil
            timer = nil
            return value
        }
        previous.1?.cancel()
        if let currentStream = previous.0 { try? await currentStream.stopCapture() }
        queue.sync {}
        withImage { latestImage = nil }
        encoder.stop()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue),
              status == .complete || status == .idle else { return }
        // Idle status frames often have no pixel buffer. Keep the last complete
        // image so the 60 Hz keepalive timer still has something to encode.
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        withImage { latestImage = image }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("画面采集停止：\(error.localizedDescription)\n", stderr)
        scheduleRestart(for: stream)
    }

    private func scheduleRestart(for stoppedStream: SCStream) {
        let restartGeneration = withState { () -> UInt64? in
            guard !generation.isStopped, stream === stoppedStream else { return nil }
            let current = generation.value
            guard restartingGeneration != current else { return nil }
            restartingGeneration = current
            return current
        }
        guard let restartGeneration else { return }

        Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while self.isCurrent(restartGeneration) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.isCurrent(restartGeneration) else { break }
                attempt += 1
                do {
                    let didStart = try await self.startStream(generation: restartGeneration)
                    guard didStart else { break }
                    let recovered = self.withState {
                        self.generation.isCurrent(restartGeneration) && self.stream != nil
                    }
                    if recovered {
                        fputs("画面采集已自动恢复\n", stderr)
                    }
                    break
                } catch {
                    guard self.isCurrent(restartGeneration) else { break }
                    fputs("画面采集恢复失败（第 \(attempt) 次）：\(error.localizedDescription)\n", stderr)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            self.withState {
                if self.restartingGeneration == restartGeneration {
                    self.restartingGeneration = nil
                }
            }
        }
    }

    private func isCurrent(_ captureGeneration: UInt64) -> Bool {
        withState { generation.isCurrent(captureGeneration) }
    }
}
