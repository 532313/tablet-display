import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import VirtualDisplayBridge

final class TabletDisplayDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusBar = StatusBarController()
        self.statusBar = statusBar
        Task.detached {
            do {
                try await TabletDisplayApp.run(statusBar: statusBar)
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
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

    static func run(statusBar: StatusBarController) async throws {
        var options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
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
        let adb = options.noADB ? nil : try ADB.connectPreferred(serial: options.serial)
        if let adb { AppLog.write("ADB 设备：\(adb.serial)") }
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
        AppLog.write("传输方式：\(options.directHost.map { "直连 \($0)" } ?? "ADB 隧道")")
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
            throw CLIError.invalid("无法检测平板硬件分辨率，请用 --width 和 --height 手动指定")
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

        let frames = VideoFrameStore()
        let token = options.token ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = HTTPServer(frames: frames, displayID: displayID, width: width, height: height,
                                fps: options.fps, token: token, directPeerIP: peerIP)
        try server.start(port: options.port)
        defer { server.stop() }
        AppLog.write("HTTP 监听：\(options.port)")
        print("本机状态：http://127.0.0.1:\(options.port)/health")
        if let host = options.directHost {
            print("视频与触摸通过局域网直连：\(host):\(options.port)（令牌鉴权）")
        }

        let encoder = try H264Encoder(width: width, height: height,
                                      bitrate: options.bitrateMbps * 1_000_000,
                                      fps: options.fps, frames: frames)
        let capture = DisplayCapture(encoder: encoder)
        try await capture.start(displayID: displayID, width: width, height: height, fps: options.fps)
        AppLog.write("采集已启动")
        if let adb {
            if options.directHost == nil { try adb.forward(port: options.port) }
            defer { if options.directHost == nil { adb.removeForward(port: options.port) } }
            guard let apk = Bundle.main.resourceURL?.appendingPathComponent("TabletDisplay.apk"),
                  FileManager.default.fileExists(atPath: apk.path) else {
                throw CLIError.invalid("应用包中缺少 Android 接收端 APK，请重新运行 scripts/build-app.sh")
            }
            try adb.installReceiver(at: apk.path)
            try adb.openReceiver(host: options.directHost ?? "127.0.0.1", port: options.port, token: token)
            print("已在 Android 设备 \(adb.serial) 打开原生扩展屏。")
            statusBar.update("已连接 \(adb.serial)")
            AppLog.write("已打开平板接收端：\(adb.serial)")
            if !AXIsProcessTrusted() {
                let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(prompt)
                print("触摸控制尚未授权：请在系统设置 → 隐私与安全性 → 辅助功能中允许 Tablet Display。")
                AppLog.write("辅助功能权限未授予，触摸暂不可用")
                statusBar.update("触摸未授权 · 请允许辅助功能")
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
            await waitUntilStopped(duration: options.duration)
        }
        await capture.stop()
        statusBar.update("已停止")
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
