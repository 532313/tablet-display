import CoreGraphics
import Foundation
import VirtualDisplayBridge

/// Reconfigures the virtual display, capture and encoder in place so an
/// orientation change does not restart the app, ADB or touch.
@MainActor
final class LiveVideoController {
    private var displayID: CGDirectDisplayID
    private var displayHandleBits: UInt
    private let server: HTTPServer
    private let rtpServer: RTPVideoServer?
    private let controlPanel: ControlPanelController
    private let fps: Int
    private var bitrate: Int
    private var geometry: DisplayGeometry
    private var frames: VideoFrameStore
    private var encoder: H264Encoder
    private var capture: DisplayCapture
    private var switching = false
    private var placementTask: Task<Void, Never>?

    init(displayID: CGDirectDisplayID, displayHandleBits: UInt,
         geometry: DisplayGeometry, fps: Int, bitrate: Int,
         frames: VideoFrameStore, encoder: H264Encoder, capture: DisplayCapture,
         server: HTTPServer, rtpServer: RTPVideoServer?, controlPanel: ControlPanelController) {
        self.displayID = displayID
        self.displayHandleBits = displayHandleBits
        self.geometry = geometry
        self.fps = fps
        self.bitrate = bitrate
        self.frames = frames
        self.encoder = encoder
        self.capture = capture
        self.server = server
        self.rtpServer = rtpServer
        self.controlPanel = controlPanel
        frames.onKeyframeNeeded = { [weak encoder] in encoder?.requestKeyframe() }
        placementTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.ensurePlacedRight()
            }
        }
    }

    deinit { placementTask?.cancel() }

    private func ensurePlacedRight() {
        let main = CGMainDisplayID()
        guard main != displayID, main != 0 else { return }
        let mainBounds = CGDisplayBounds(main)
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let targetX = mainBounds.maxX
        let targetY = mainBounds.minY
        guard abs(bounds.minX - targetX) > 1 || abs(bounds.minY - targetY) > 1 else { return }
        if VDPlaceRightOfMain(displayID) {
            AppLog.write("显示排列：已把平板移到主屏右侧")
        }
    }

    func updateBitrate(mbps: Int) {
        bitrate = mbps * 1_000_000
        encoder.updateBitrate(bitrate)
    }

    @discardableResult
    func switchOrientation(portrait: Bool) async -> Bool {
        guard !switching else { return false }
        let target = geometry.oriented(portrait: portrait)
        guard target != geometry else { return true }

        switching = true
        defer { switching = false }
        let oldDisplayID = displayID
        let oldDisplayBits = displayHandleBits
        let oldGeometry = geometry
        var newDisplayID = displayID
        var newDisplayBits = displayHandleBits
        var createdDisplay = false

        if let handle = UnsafeMutableRawPointer(bitPattern: displayHandleBits),
           VDResize(handle, UInt32(target.pixelWidth), UInt32(target.pixelHeight),
                    UInt32(target.logicalWidth), UInt32(target.logicalHeight)) {
            _ = VDPlaceRightOfMain(displayID)
        } else {
            // CGVirtualDisplay does not expose a portrait mode for a display
            // created with a landscape aspect. Create the matching display and
            // switch capture/server references without restarting the app.
            var displayIDValue: UInt32 = 0
            guard let handle = VDCreate(UInt32(target.pixelWidth), UInt32(target.pixelHeight),
                                        UInt32(target.logicalWidth), UInt32(target.logicalHeight),
                                        &displayIDValue) else {
                AppLog.write("方向切换失败：无法创建 \(target.pixelWidth)x\(target.pixelHeight) 虚拟屏")
                return false
            }
            newDisplayID = displayIDValue
            newDisplayBits = UInt(bitPattern: handle)
            createdDisplay = true
            _ = VDSetNativeMode(newDisplayID, UInt32(target.pixelWidth), UInt32(target.pixelHeight))
            _ = VDPlaceRightOfMain(newDisplayID)
        }
        AppLog.write("原地切换显示：\(geometry.pixelWidth)x\(geometry.pixelHeight) -> \(target.pixelWidth)x\(target.pixelHeight)")

        let newFrames = VideoFrameStore()
        do {
            let newEncoder = try H264Encoder(width: target.pixelWidth, height: target.pixelHeight,
                                             bitrate: bitrate, fps: fps, frames: newFrames)
            newFrames.onKeyframeNeeded = { [weak newEncoder] in newEncoder?.requestKeyframe() }
            let newCapture = DisplayCapture(encoder: newEncoder)
            try await newCapture.start(displayID: newDisplayID, width: target.pixelWidth,
                                       height: target.pixelHeight, fps: fps)

            server.updateDisplayID(newDisplayID)
            server.updateVideo(frames: newFrames, width: target.pixelWidth,
                               height: target.pixelHeight, fps: fps)
            rtpServer?.updateVideo(frames: newFrames, width: target.pixelWidth,
                                   height: target.pixelHeight, fps: fps)
            controlPanel.applyLiveSize(width: target.pixelWidth, height: target.pixelHeight)
            controlPanel.updateDisplay("\(target.pixelWidth) × \(target.pixelHeight) @ \(fps)Hz")

            let oldCapture = capture
            let oldEncoder = encoder
            geometry = target
            displayID = newDisplayID
            displayHandleBits = newDisplayBits
            frames = newFrames
            encoder = newEncoder
            capture = newCapture
            await oldCapture.stop()
            oldEncoder.stop()
            if createdDisplay, let oldHandle = UnsafeMutableRawPointer(bitPattern: oldDisplayBits) {
                VDDestroy(oldHandle)
            }
            AppLog.write("原地切换完成，连接保持不变")
            return true
        } catch {
            AppLog.write("方向切换失败：\(error.localizedDescription)")
            if createdDisplay, let handle = UnsafeMutableRawPointer(bitPattern: newDisplayBits) {
                VDDestroy(handle)
            }
            geometry = oldGeometry
            displayID = oldDisplayID
            displayHandleBits = oldDisplayBits
            _ = VDPlaceRightOfMain(displayID)
            return false
        }
    }
}
