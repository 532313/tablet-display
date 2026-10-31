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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlPanel?.show()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: AppText.t("打开控制面板"), action: #selector(openControlPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: AppText.t("退出 Tablet Display"), action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc func openControlPanel() {
        controlPanel?.show()
    }

    @MainActor @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

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
                AppLog.write("启动错误：\(error.localizedDescription)")
                if StartupFailurePolicy.isRecoverable(error) {
                    // Keep the Dock/control panel alive so the user can grant
                    // permission or free the port and retry without relaunching.
                    controlPanel.updateStatus("启动未完成：\(error.localizedDescription)",
                                               level: .warning)
                    statusBar.update("等待重试")
                    if let cliError = error as? CLIError, case .screenRecording = cliError,
                       isatty(STDIN_FILENO) == 0 {
                        statusBar.showPermissionPrompt(.screenRecording,
                                                       message: error.localizedDescription)
                    } else if isatty(STDIN_FILENO) == 0 {
                        statusBar.showError(error.localizedDescription)
                    }
                    await MainActor.run { controlPanel.show() }
                    return
                }
                controlPanel.updateStatus("启动失败", level: .error)
                statusBar.update("启动失败")
                if isatty(STDIN_FILENO) == 0 {
                    statusBar.showError(error.localizedDescription)
                }
                await MainActor.run { NSApp.terminate(nil) }
                Foundation.exit(1)
            }
        }
    }
}

@main
struct TabletDisplayApp {
    @MainActor static func main() {
        if let snapshotURL = snapshotURL(from: CommandLine.arguments) {
            runSnapshot(to: snapshotURL)
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.local.tabletdisplay"
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != getpid() }) {
            AppLog.write("已有实例运行，激活 PID \(existing.processIdentifier)")
            activateExistingInstance()
            return
        }
        guard let instanceLock = SingleInstanceGuard.acquire() else {
            AppLog.write("已有实例持有运行锁，激活现有窗口")
            activateExistingInstance()
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = TabletDisplayDelegate()
        app.delegate = delegate
        installMainMenu(app: app, delegate: delegate)
        withExtendedLifetime(instanceLock) {
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }

    @MainActor private static func installMainMenu(app: NSApplication, delegate: TabletDisplayDelegate) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Tablet Display")

        let about = NSMenuItem(title: AppText.t("关于 Tablet Display"),
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = app
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let panel = NSMenuItem(title: AppText.t("打开控制面板"),
                               action: #selector(TabletDisplayDelegate.openControlPanel),
                               keyEquivalent: ",")
        panel.target = delegate
        appMenu.addItem(panel)
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: AppText.t("服务"), action: nil, keyEquivalent: "")
        let services = NSMenu(title: "服务")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(title: AppText.t("隐藏 Tablet Display"),
                              action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = app
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: AppText.t("隐藏其他"),
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = app
        appMenu.addItem(hideOthers)
        let showAll = NSMenuItem(title: AppText.t("全部显示"),
                                 action: #selector(NSApplication.unhideAllApplications(_:)),
                                 keyEquivalent: "")
        showAll.target = app
        appMenu.addItem(showAll)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(title: AppText.t("退出 Tablet Display"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        appMenu.addItem(quit)

        appItem.submenu = appMenu
        app.mainMenu = mainMenu
    }

    private static func snapshotURL(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--snapshot-ui"),
              index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    @MainActor private static func runSnapshot(to url: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = ControlPanelController()
        panel.show()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                try panel.writeSnapshot(to: url)
                print("UI snapshot: \(url.path)")
            } catch {
                fputs("UI snapshot failed: \(error.localizedDescription)\n", stderr)
            }
            NSApp.terminate(nil)
        }
        app.run()
    }

    @MainActor private static func activateExistingInstance() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", Bundle.main.bundlePath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
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
        if ProcessInfo.processInfo.environment["TABLETDISPLAY_FORCE_SCREEN_RECORDING_DENIED"] == "1" {
            AppLog.write("测试注入：屏幕录制权限被拒绝")
            throw CLIError.screenRecording
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
        let geometry = DisplayGeometry(pixelWidth: width, pixelHeight: height, useHiDPI: useHiDPI)
        guard geometry.logicalWidth >= 320, geometry.logicalHeight >= 240 else {
            throw CLIError.invalid("HiDPI 逻辑分辨率过小，请用 --no-hidpi 或提高 --width/--height")
        }

        var displayID: UInt32 = 0
        guard let handle = VDCreate(UInt32(geometry.pixelWidth), UInt32(geometry.pixelHeight),
                                    UInt32(geometry.logicalWidth), UInt32(geometry.logicalHeight),
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
        let touchEnabled = UserDefaults.standard.object(forKey: "TabletDisplayTouchEnabled") as? Bool ?? true
        server.setTouchEnabled(touchEnabled)
        controlPanel.setTouchHandler { [weak server] enabled in
            server?.setTouchEnabled(enabled)
        }
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
        controlPanel.updatePairing(host: options.directHost, port: options.port,
                                   token: token, udpPort: udpPort)

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
        controlPanel.updateStatus("采集运行中", level: .running)
        let displayHandleBits = UInt(bitPattern: handle)
        let live = await MainActor.run {
            LiveVideoController(displayID: displayID, displayHandleBits: displayHandleBits,
                                geometry: geometry,
                                fps: options.fps, bitrate: options.bitrateMbps * 1_000_000,
                                frames: frames, encoder: encoder, capture: capture,
                                server: server, rtpServer: rtpServer, controlPanel: controlPanel)
        }
        server.orientationHandler = { [weak live] portrait, completion in
            Task { @MainActor in
                let applied = await live?.switchOrientation(portrait: portrait) ?? false
                completion(applied)
            }
        }
        controlPanel.setBitrateHandler { [weak live] mbps in
            Task { @MainActor in live?.updateBitrate(mbps: mbps) }
        }
        let networkMonitor = startNetworkMonitor(adb: adb, directHost: options.directHost,
                                                  controlPanel: controlPanel)
        defer { networkMonitor.cancel() }
        if let adb {
            if options.directHost == nil { try adb.forward(port: options.port) }
            defer { if options.directHost == nil { adb.removeForward(port: options.port) } }
            guard let apk = Bundle.main.resourceURL?.appendingPathComponent("TabletDisplay.apk"),
                  FileManager.default.fileExists(atPath: apk.path) else {
                throw CLIError.invalid("应用包中缺少 Android 接收端 APK，请重新运行 scripts/build-app.sh")
            }
            try adb.installReceiver(at: apk.path)
            try adb.openReceiver(host: options.directHost ?? "127.0.0.1", port: options.port,
                                 token: token, udpPort: udpPort)
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

    private static func startNetworkMonitor(adb: ADB?, directHost: String?,
                                             controlPanel: ControlPanelController) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }

                // If the Mac changed networks, keep the tablet pointed at the
                // new LAN address. A short reconnect is preferable to asking
                // the user to edit the IP by hand.
                if let directHost, let adb,
                   let tabletIP = ADB.host(fromSerial: adb.serial),
                   let newHost = LocalNetwork.ipv4(towards: tabletIP),
                   newHost != directHost {
                    AppLog.write("网络恢复：Mac IP 变化 \(directHost) -> \(newHost)")
                    await MainActor.run {
                        controlPanel.restartForNetwork(serial: adb.serial, directHost: newHost)
                    }
                    return
                }

                // Android 11+ advertises the current wireless debugging
                // endpoint over mDNS. If the tablet moved to a new address,
                // reconnect and let the normal restart path reopen the app.
                guard let adb, ADB.isWireless(adb.serial),
                      let currentHost = ADB.host(fromSerial: adb.serial) else { continue }
                for endpoint in ADB.mdnsEndpoints()
                where ADB.host(fromSerial: endpoint) != currentHost {
                    guard let connected = try? ADB.connectSaved(endpoint) else { continue }
                    let newDirect = ADB.host(fromSerial: connected)
                        .flatMap { LocalNetwork.ipv4(towards: $0) }
                    AppLog.write("网络恢复：发现平板新地址 \(connected)")
                    await MainActor.run {
                        controlPanel.restartForNetwork(serial: connected, directHost: newDirect)
                    }
                    return
                }
            }
        }
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
