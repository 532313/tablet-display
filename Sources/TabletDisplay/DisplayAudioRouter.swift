import AudioToolbox
import AVFoundation
import CoreGraphics
import Darwin
import Foundation

protocol DisplayAudioRouting: AnyObject {
    func start()
    func stop()
}

/// Routes audio at the process level: processes with a window centered on the
/// virtual display are tapped, muted from the normal output and sent to the
/// tablet. Processes whose windows stay on the Mac remain untouched.
@available(macOS 14.2, *)
final class DisplayAudioRouter: DisplayAudioRouting, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let sink: (Data) -> Void
    private let sinkReady: () -> Bool
    private let queue = DispatchQueue(label: "tablet-display.audio-router", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var running = false
    private var session: ProcessAudioTap?
    private var requestedProcesses: Set<AudioObjectID> = []
    private var retryAfter = Date.distantPast

    init(displayID: CGDirectDisplayID, sink: @escaping (Data) -> Void,
         sinkReady: @escaping () -> Bool) {
        self.displayID = displayID
        self.sink = sink
        self.sinkReady = sinkReady
    }

    func start() {
        queue.sync {
            guard !running else { return }
            running = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            session?.stop()
            session = nil
            requestedProcesses = []
        }
    }

    private func scan() {
        guard running else { return }
        guard sinkReady() else {
            if session != nil {
                session?.stop()
                session = nil
                requestedProcesses = []
                AppLog.write("音频路由：平板音频未连接，暂停 tap")
            }
            return
        }
        let pids = windowPIDsOnVirtualDisplay()
        var objects = Set<AudioObjectID>()
        for pid in pids {
            for processPID in processAndChildren(pid) {
                if let object = audioProcessID(for: processPID) {
                    objects.insert(object)
                }
            }
        }

        if objects == requestedProcesses, (session != nil || objects.isEmpty) { return }
        guard Date() >= retryAfter else { return }
        AppLog.write("音频路由扫描：窗口进程 \(pids.count) 个，音频对象 \(objects.count) 个")

        session?.stop()
        session = nil
        requestedProcesses = objects
        guard !objects.isEmpty else { return }

        guard #available(macOS 14.2, *) else { return }
        do {
            let tap = ProcessAudioTap(processIDs: Array(objects), sink: sink)
            try tap.start()
            session = tap
            AppLog.write("音频路由：tap \(objects.count) 个音频进程")
        } catch {
            retryAfter = Date().addingTimeInterval(5)
            AppLog.write("音频路由失败：\(error.localizedDescription)")
        }
    }

    private func windowPIDsOnVirtualDisplay() -> Set<pid_t> {
        let displayBounds = CGDisplayBounds(displayID)
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result = Set<pid_t>()
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let owner = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(owner.int32Value)
            guard pid != ownPID else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = bounds["X"]?.doubleValue,
                  let y = bounds["Y"]?.doubleValue,
                  let width = bounds["Width"]?.doubleValue,
                  let height = bounds["Height"]?.doubleValue else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if displayBounds.contains(center) {
                result.insert(pid)
            }
        }
        return result
    }

    private func processAndChildren(_ pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var pending: [pid_t] = [pid]
        for _ in 0..<4 {
            guard !pending.isEmpty else { break }
            var next: [pid_t] = []
            for parent in pending {
                if !result.contains(parent) { result.append(parent) }
                var children = [pid_t](repeating: 0, count: 256)
                let bytes = proc_listchildpids(parent, &children,
                                               Int32(children.count * MemoryLayout<pid_t>.size))
                guard bytes > 0 else { continue }
                // proc_listchildpids returns the number of PIDs written.
                let count = min(children.count, Int(bytes))
                for child in children.prefix(count) where child > 0 && !result.contains(child) {
                    next.append(child)
                }
            }
            pending = next
        }
        return result
    }

    private func audioProcessID(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
}

@available(macOS 14.2, *)
private final class ProcessAudioTap: @unchecked Sendable {
    private let processIDs: [AudioObjectID]
    private let sink: (Data) -> Void
    private let queue = DispatchQueue(label: "tablet-display.audio-tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 48_000,
                                             channels: 2,
                                             interleaved: true)
    private var converter: AVAudioConverter?

    init(processIDs: [AudioObjectID], sink: @escaping (Data) -> Void) {
        self.processIDs = processIDs
        self.sink = sink
    }

    func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "Tablet Display Audio"
        var createdTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &createdTap) == noErr else {
            throw AudioTapError.tap
        }
        tapID = createdTap

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription) == noErr,
              let format = AVAudioFormat(streamDescription: &streamDescription) else {
            stop()
            throw AudioTapError.format
        }
        inputFormat = format

        guard let outputUID = try defaultOutputUID() else {
            stop()
            throw AudioTapError.output
        }
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tablet Display Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary,
                                                 &createdAggregate) == noErr else {
            stop()
            throw AudioTapError.aggregate
        }
        aggregateID = createdAggregate
        setLowLatencyBuffer()

        var createdIOProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&createdIOProc, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            self?.receive(inputData)
        }
        guard status == noErr, let createdIOProc else {
            stop()
            throw AudioTapError.ioProc
        }
        ioProcID = createdIOProc
        guard AudioDeviceStart(aggregateID, createdIOProc) == noErr else {
            stop()
            throw AudioTapError.start
        }
        AppLog.write("音频 tap 已启动：\(Int(format.sampleRate))Hz \(format.channelCount)ch，进程 \(processIDs)")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                _ = AudioDeviceStop(aggregateID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

    private func setLowLatencyBuffer() {
        var frames: UInt32 = 256
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(aggregateID, &address, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &frames)
    }

    private func receive(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let inputFormat,
              let outputFormat,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                 bufferListNoCopy: inputData,
                                                 deallocator: nil) else { return }
        let bytesPerFrame = max(1, inputFormat.streamDescription.pointee.mBytesPerFrame)
        inputBuffer.frameLength = AVAudioFrameCount(
            inputData.pointee.mBuffers.mDataByteSize / bytesPerFrame
        )
        guard inputBuffer.frameLength > 0 else { return }

        if converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                  frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, outputBuffer.frameLength > 0 else {
            if let conversionError {
                AppLog.write("音频 tap 转换失败：\(conversionError.localizedDescription)")
            }
            return
        }
        let buffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else { return }
        sink(Data(bytes: bytes, count: Int(buffer.mDataByteSize)))
    }

    private func defaultOutputUID() throws -> String? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uid = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil,
                                         &uidSize, &uid) == noErr else { return nil }
        return uid as String
    }
}

private enum AudioTapError: LocalizedError {
    case tap
    case format
    case output
    case aggregate
    case ioProc
    case start

    var errorDescription: String? {
        switch self {
        case .tap: return "无法创建进程音频 tap（请检查系统音频录制权限）"
        case .format: return "无法读取音频 tap 格式"
        case .output: return "无法读取系统默认音频输出"
        case .aggregate: return "无法创建音频聚合设备"
        case .ioProc: return "无法创建音频 IOProc"
        case .start: return "无法启动音频聚合设备"
        }
    }
}
