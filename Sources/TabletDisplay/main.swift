import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import VirtualDisplayBridge

enum StartupError: LocalizedError {
    case adb(String)
    case tabletResolution

    var errorDescription: String? {
        switch self {
        case .adb(let message):
            return "无法连接平板：\(message)"
        case .tabletResolution:
            return "无法读取平板分辨率：请确认平板已连接，或输入平板 IP 后重连。"
        }
    }
}

final class TabletDisplayDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var controlPanel: ControlPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controlPanel = ControlPanelController()
        self.controlPanel = controlPanel
        let statusBar = StatusBarController(controlPanel: controlPanel)
        self.statusBar = statusBar
        controlPanel.showIfEnabled()
        Task.detached {
            do {
                try await TabletDisplayApp.run(statusBar: statusBar, controlPanel: controlPanel)
                await MainActor.run { NSApp.terminate(nil) }
            } catch let startupError as StartupError {
                AppLog.write("启动未完成：\(startupError.localizedDescription)")
                controlPanel.updateStatus("未连接 · 输入平板 IP 或插 USB 后重连", level: .warning)
                controlPanel.updateDisplay("—")
                controlPanel.updateTransport("—")
                controlPanel.updateServer("—")
                statusBar.update("等待手动连接")
                await MainActor.run { controlPanel.show() }
            } catch {
                controlPanel.updateStatus("启动失败", level: .error)
                AppLog.write("错误：\(error.localizedDescription)")
                if let cliError = error as? CLIError, case .screenRecording = cliError {
                    if isatty(STDIN_FILENO) == 0 {
                        statusBar.showPermissionPrompt(.screenRecording,
                                                       message: error.localizedDescription)
                    }
                } else if isatty(STDIN_FILENO) == 0 {
                    statusBar.showError(error.localizedDescription)
                }
                statusBar.update("启动失败")
                await MainActor.run { NSApp.terminate(nil) }
                Foundation.exit(1)
            }
        }
    }
}

@main
struct TabletDisplayApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = TabletDisplayDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    static func run(statusBar: StatusBarController, controlPanel: ControlPanelController) async throws {
        var options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        let defaults = UserDefaults.standard
        if !options.widthExplicit,
           let saved = defaults.object(forKey: "TabletDisplayWidth") as? Int,
           (640...4096).contains(saved) {
            options.width = saved
            AppLog.write("使用保存的宽度：\(saved)")
        }
        if !options.heightExplicit,
           let saved = defaults.object(forKey: "TabletDisplayHeight") as? Int,
           (480...4096).contains(saved) {
            options.height = saved
            AppLog.write("使用保存的高度：\(saved)")
        }
        if !options.fpsExplicit,
           let saved = defaults.object(forKey: "TabletDisplayFPS") as? Int,
           (15...60).contains(saved) {
            options.fps = saved
            AppLog.write("使用保存的帧率：\(saved)")
        }
        if !options.audioExplicit,
           let saved = defaults.object(forKey: "TabletDisplayAudio") as? Bool {
            options.audio = saved
            AppLog.write("使用保存的音频设置：\(saved)")
        }
        if !options.bitrateExplicit,
           let saved = defaults.object(forKey: "TabletDisplayBitrateMbps") as? Int,
           (5...50).contains(saved) {
            options.bitrateMbps = saved
            AppLog.write("使用保存的码率：\(saved) Mbps")
        }
        controlPanel.setPort(options.port)
        controlPanel.setInitialBitrate(options.bitrateMbps)
        controlPanel.updateStatus("正在启动…", level: .starting)
        ADB.logger = { AppLog.write($0) }
        AppLog.write("启动：serial=\(options.serial ?? "auto")")
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            AppLog.write("PATH=\(path)")
        }
        if !CGPreflightScreenCaptureAccess() {
            AppLog.write("屏幕录制权限未授予，发起系统授权请求")
            if !CGRequestScreenCaptureAccess() {
                throw CLIError.screenRecording
            }
        }
        statusBar.setPort(options.port)
        statusBar.update("正在启动…")
        let adb: ADB?
        if options.noADB {
            adb = nil
        } else {
            do {
                adb = try ADB.connectPreferred(serial: options.serial)
            } catch {
                throw StartupError.adb(error.localizedDescription)
            }
        }
        if let adb {
            AppLog.write("ADB 设备：\(adb.serial)")
            controlPanel.updateTablet(adb.serial)
        }
        // A wireless ADB serial already contains the tablet IP. If no explicit
        // direct host was given, derive the Mac's LAN address and use the fast
        // direct path instead of the ADB tunnel.
        // Only infer direct mode for the cable-free/Dock launch path. Passing
        // --serial explicitly (e.g. run-wireless.sh --adb-tunnel) keeps the
        // requested ADB-tunnel behavior.
        if options.directHost == nil, options.serial == nil,
           let adb, let tabletIP = ADB.host(fromSerial: adb.serial),
           let localIP = LocalNetwork.ipv4(towards: tabletIP) {
            options.directHost = localIP
        }
        let transport = options.directHost.map { "直连 \($0):\(options.port)" } ?? "ADB 隧道"
        AppLog.write("传输方式：\(transport)")
        controlPanel.updateTransport(transport)
        if let directHost = options.directHost {
            controlPanel.updateMacAddress(directHost)
        } else if let tabletHost = adb.flatMap({ ADB.host(fromSerial: $0.serial) }),
                  let macIP = LocalNetwork.ipv4(towards: tabletHost) {
            controlPanel.updateMacAddress(macIP)
        }
        let peerIP = options.directHost.flatMap { _ in
            adb?.serial.split(separator: ":", maxSplits: 1).first.map(String.init)
        }
        if options.directHost != nil {
            var peerAddress = in_addr()
            guard let peerIP,
                  peerIP.withCString({ inet_pton(AF_INET, $0, &peerAddress) == 1 }) else {
                throw CLIError.invalid("局域网直连需要 --serial IP:端口 指定无线 ADB 设备")
            }
        }
        let dimensions = adb?.screenSize()
        if let dimensions {
            AppLog.write("平板硬件分辨率：\(dimensions.0)x\(dimensions.1)")
            print("检测到平板硬件分辨率：\(dimensions.0) × \(dimensions.1)")
        }
        let width: Int
        let height: Int
        if let dimensions {
            width = options.width ?? dimensions.0
            height = options.height ?? dimensions.1
        } else if options.noADB {
            width = options.width ?? 1920
            height = options.height ?? 1200
        } else {
            throw StartupError.tabletResolution
        }
        guard (640...4096).contains(width), (480...4096).contains(height) else {
            throw CLIError.invalid("设备分辨率超出支持范围，请用 --width 和 --height 指定分辨率")
        }

        // On a high-DPI panel, back the display at the native pixel size but
        // expose a 2x logical size so text/UI matches a 13-inch MacBook instead
        // of being rendered at 1x and looking tiny.
        let useHiDPI = options.hidpi ?? (width >= 2048 && height >= 1200)
        let logicalWidth = useHiDPI ? width / 2 : width
        let logicalHeight = useHiDPI ? height / 2 : height
        guard logicalWidth >= 320, logicalHeight >= 240 else {
            throw CLIError.invalid("HiDPI 逻辑分辨率过小，请用 --no-hidpi 或提高 --width/--height")
        }

        var displayID: UInt32 = 0
        guard let handle = VDCreate(UInt32(width), UInt32(height),
                                    UInt32(logicalWidth), UInt32(logicalHeight),
                                    &displayID) else {
            throw CLIError.virtualDisplay
        }
        defer { VDDestroy(handle) }
        if !VDSetNativeMode(displayID, UInt32(width), UInt32(height)) {
            print("提示：未能选择 \(width) × \(height) 原生显示模式，画面可能经过缩放。")
        }
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            AppLog.write("实际显示模式：\(mode.pixelWidth)x\(mode.pixelHeight)")
            if mode.pixelWidth != width || mode.pixelHeight != height {
                print("提示：实际显示模式 \(mode.pixelWidth) × \(mode.pixelHeight) 与请求 \(width) × \(height) 不一致。")
            }
        }
        if !VDPlaceRightOfMain(displayID) {
            print("提示：未能自动将平板放到主屏右侧，可在系统设置 → 显示器 → 排列中手动调整。")
        }
        print("已创建扩展显示器：\(width) × \(height)，\(options.fps) fps，\(options.bitrateMbps) Mbps，ID \(displayID)")
        AppLog.write("虚拟显示器：\(width)x\(height) id=\(displayID)")
        statusBar.update("副屏已创建 · \(width)×\(height)")
        controlPanel.updateDisplay("\(width) × \(height) @ \(options.fps)Hz")

        let frames = VideoFrameStore()
        let token = options.token ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = HTTPServer(frames: frames, displayID: displayID, width: width, height: height,
                                fps: options.fps, token: token, directPeerIP: peerIP)
        try server.start(port: options.port)
        defer { server.stop() }
        AppLog.write("HTTP 监听：\(options.port)")
        controlPanel.updateServer("127.0.0.1:\(options.port)")

        var udpPort: UInt16 = 0
        var rtpServer: RTPVideoServer?
        if options.directHost != nil {
            let rtp = RTPVideoServer(frames: frames, token: token,
                                     width: width, height: height, fps: options.fps)
            do {
                udpPort = try rtp.start()
                rtpServer = rtp
                AppLog.write("RTP 视频端口：\(udpPort)")
                controlPanel.updateTransport("\(transport) · UDP \(udpPort)")
            } catch {
                AppLog.write("UDP 不可用，回退 TCP：\(error.localizedDescription)")
            }
        }
        defer { rtpServer?.stop() }

        var audioPort: UInt16 = 0
        var audioServer: AudioStreamServer?
        var audioRouter: (any DisplayAudioRouting)?
        if options.audio, options.directHost != nil {
            if #available(macOS 14.2, *) {
                let audio = AudioStreamServer(token: token)
                do {
                    audioPort = try audio.start()
                    audioServer = audio
                    AppLog.write("音频 UDP 端口：\(audioPort)")
                    let router = DisplayAudioRouter(displayID: displayID,
                                                    sink: { pcm in audio.append(pcm) },
                                                    sinkReady: { audio.hasPeer() })
                    router.start()
                    audioRouter = router
                    AppLog.write("按窗口所在显示器拆分音频")
                } catch {
                    AppLog.write("音频不可用：\(error.localizedDescription)")
                }
            } else {
                AppLog.write("音频拆分需要 macOS 14.2 或更新版本")
            }
        } else if options.audio {
            AppLog.write("音频需要直连模式，当前不会传输声音")
        }
        defer {
            audioRouter?.stop()
            audioServer?.stop()
        }
        print("本机状态：http://127.0.0.1:\(options.port)/health")
        if let host = options.directHost {
            print("视频与触摸通过局域网直连：\(host):\(options.port)（令牌鉴权）")
        }

        let encoder = try H264Encoder(width: width, height: height,
                                      bitrate: options.bitrateMbps * 1_000_000,
                                      fps: options.fps, frames: frames)
        controlPanel.setBitrateHandler { [weak encoder] mbps in
            encoder?.updateBitrate(mbps * 1_000_000)
        }
        frames.onKeyframeNeeded = { [weak encoder] in
            encoder?.requestKeyframe()
        }
        let capture = DisplayCapture(encoder: encoder)
        try await capture.start(displayID: displayID, width: width, height: height, fps: options.fps)
        AppLog.write("采集已启动")
        controlPanel.updateStatus("采集运行中", level: .running)
        if let adb {
            if options.directHost == nil { try adb.forward(port: options.port) }
            defer { if options.directHost == nil { adb.removeForward(port: options.port) } }
            guard let apk = Bundle.main.resourceURL?.appendingPathComponent("TabletDisplay.apk"),
                  FileManager.default.fileExists(atPath: apk.path) else {
                throw CLIError.invalid("应用包中缺少 Android 接收端 APK，请重新运行 scripts/build-app.sh")
            }
            try adb.installReceiver(at: apk.path)
            try adb.openReceiver(host: options.directHost ?? "127.0.0.1", port: options.port,
                                 token: token, udpPort: udpPort, audioPort: audioPort)
            print("已在 Android 设备 \(adb.serial) 打开原生扩展屏。")
            statusBar.update("已连接 \(adb.serial)")
            controlPanel.updateStatus("已连接 \(adb.serial)", level: .running)
            AppLog.write("已打开平板接收端：\(adb.serial)")
            if !AXIsProcessTrusted() {
                let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(prompt)
                print("触摸控制尚未授权：请在系统设置 → 隐私与安全性 → 辅助功能中允许 Tablet Display。")
                AppLog.write("辅助功能权限未授予，触摸暂不可用")
                statusBar.update("触摸未授权 · 请允许辅助功能")
                controlPanel.updateStatus("触摸未授权 · 请允许辅助功能", level: .warning)
                if isatty(STDIN_FILENO) == 0 {
                    statusBar.showPermissionPrompt(
                        .accessibility,
                        message: "视频已开始传输，但触摸暂不可用。请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Tablet Display，然后重新启动应用。"
                    )
                }
            }
            await waitUntilStopped(duration: options.duration)
        } else {
            print("未使用 ADB；可用 /video 接口检查 H.264 视频流。")
            statusBar.update("采集运行中")
            controlPanel.updateStatus("采集运行中（未使用 ADB）", level: .running)
            await waitUntilStopped(duration: options.duration)
        }
        await capture.stop()
        statusBar.update("已停止")
        controlPanel.updateStatus("已停止", level: .stopped)
    }

    private static func waitUntilStopped(duration: Double?) async {
        if let duration {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return
        }
        // On macOS 27 a dispatch signal source does not fire while the signal
        // is set to SIG_IGN. Install a no-op handler to suppress the default
        // termination and let the source below receive the event.
        signal(SIGINT, { _ in })
        signal(SIGTERM, { _ in })
        fputs("等待停止信号（Ctrl-C）\n", stderr)
        let stop = DispatchSemaphore(value: 0)
        let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                fputs("收到停止信号 \(number)\n", stderr)
                stop.signal()
            }
            source.resume()
            return source
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                stop.wait()
                continuation.resume()
            }
        }
        sources.forEach { $0.cancel() }
    }
}
