import AppKit
import SwiftUI

enum ControlStatusLevel: Sendable {
    case starting
    case running
    case warning
    case error
    case stopped
}

struct ResolutionOption: Identifiable, Hashable {
    let id: String
    let title: String
    let width: Int
    let height: Int
}

@MainActor
final class ControlPanelModel: ObservableObject {
    @Published var status = "正在启动…"
    @Published var statusLevel: ControlStatusLevel = .starting
    @Published var display = "—"
    @Published var transport = "—"
    @Published var tablet = "—"
    @Published var server = "—"
    @Published var macAddress = "—"
    @Published var tabletAddressInput = ""

    @Published var resolutionID: String {
        didSet { saveResolution() }
    }
    @Published var fps: Int {
        didSet { UserDefaults.standard.set(fps, forKey: "TabletDisplayFPS") }
    }
    @Published var bitrate: Int {
        didSet {
            guard oldValue != bitrate else { return }
            AppLog.write("控制面板：码率设置为 \(bitrate) Mbps")
            UserDefaults.standard.set(bitrate, forKey: "TabletDisplayBitrateMbps")
            onBitrateChange?(bitrate)
        }
    }
    @Published var showWindowOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(showWindowOnLaunch, forKey: "TabletDisplayShowWindow")
        }
    }
    @Published var quitOnWindowClose: Bool {
        didSet {
            UserDefaults.standard.set(quitOnWindowClose, forKey: "TabletDisplayQuitOnWindowClose")
        }
    }

    let resolutionOptions: [ResolutionOption]
    let fpsOptions: [Int]
    let bitrateOptions: [Int]
    let version: String
    var port: UInt16

    var onBitrateChange: (@Sendable (Int) -> Void)?
    var onRestart: (() -> Void)?
    var onReconnect: ((String) -> Void)?
    var onQuit: (() -> Void)?
    var onOpenHealth: (() -> Void)?
    var onOpenLog: (() -> Void)?
    var onPermission: ((PermissionPane) -> Void)?

    init(port: UInt16) {
        let defaults = UserDefaults.standard

        let rawWidth = defaults.object(forKey: "TabletDisplayWidth") as? Int ?? 1470
        let rawHeight = defaults.object(forKey: "TabletDisplayHeight") as? Int ?? 956
        let width = (640...4096).contains(rawWidth) ? rawWidth : 1470
        let height = (480...4096).contains(rawHeight) ? rawHeight : 956

        var resolutions = [
            ResolutionOption(id: "macbook", title: "匹配 MacBook · 1470×956", width: 1470, height: 956),
            ResolutionOption(id: "wide", title: "1920×1200", width: 1920, height: 1200),
            ResolutionOption(id: "native", title: "平板原生 · 2560×1600", width: 2560, height: 1600),
            ResolutionOption(id: "compact", title: "1280×800", width: 1280, height: 800)
        ]
        if !resolutions.contains(where: { $0.width == width && $0.height == height }) {
            resolutions.append(ResolutionOption(id: "custom",
                                                title: "自定义 · \(width)×\(height)",
                                                width: width, height: height))
        }
        resolutionOptions = resolutions
        resolutionID = resolutions.first(where: { $0.width == width && $0.height == height })?.id ?? "macbook"

        let rawFPS = defaults.object(forKey: "TabletDisplayFPS") as? Int ?? 60
        let savedFPS = (15...60).contains(rawFPS) ? rawFPS : 60
        var fpsValues = [30, 60]
        if !fpsValues.contains(savedFPS) {
            fpsValues.append(savedFPS)
            fpsValues.sort()
        }
        fpsOptions = fpsValues
        fps = savedFPS

        let rawBitrate = defaults.object(forKey: "TabletDisplayBitrateMbps") as? Int ?? 20
        let savedBitrate = (5...50).contains(rawBitrate) ? rawBitrate : 20
        var bitrateValues = [5, 10, 15, 20, 25, 30, 40, 50]
        if !bitrateValues.contains(savedBitrate) {
            bitrateValues.append(savedBitrate)
            bitrateValues.sort()
        }
        bitrateOptions = bitrateValues
        bitrate = savedBitrate

        self.port = port
        showWindowOnLaunch = defaults.object(forKey: "TabletDisplayShowWindow") as? Bool ?? true
        quitOnWindowClose = defaults.object(forKey: "TabletDisplayQuitOnWindowClose") as? Bool ?? false
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }

    var width: Int {
        resolutionOptions.first(where: { $0.id == resolutionID })?.width ?? 1470
    }

    var height: Int {
        resolutionOptions.first(where: { $0.id == resolutionID })?.height ?? 956
    }

    var statusColor: Color {
        switch statusLevel {
        case .starting: return .yellow
        case .running: return .green
        case .warning: return .orange
        case .error: return .red
        case .stopped: return .secondary
        }
    }

    private func saveResolution() {
        guard let option = resolutionOptions.first(where: { $0.id == resolutionID }) else { return }
        UserDefaults.standard.set(option.width, forKey: "TabletDisplayWidth")
        UserDefaults.standard.set(option.height, forKey: "TabletDisplayHeight")
    }
}

private struct ControlPanelView: View {
    @ObservedObject var model: ControlPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tablet Display")
                        .font(.system(size: 22, weight: .semibold))
                    Text("无线扩展屏控制面板")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("v\(model.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(model.statusColor)
                    .frame(width: 9, height: 9)
                Text(model.status)
                    .font(.headline)
                    .lineLimit(2)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    detailLabel("虚拟显示器")
                    valueText(model.display)
                }
                GridRow {
                    detailLabel("传输")
                    valueText(model.transport)
                }
                GridRow {
                    detailLabel("平板")
                    valueText(model.tablet)
                }
                GridRow {
                    detailLabel("视频服务")
                    valueText(model.server)
                }
            }

            Divider()

            Text("网络")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    detailLabel("本机 IP")
                    valueText(model.macAddress)
                }
                GridRow {
                    detailLabel("平板 IP")
                    HStack(spacing: 8) {
                        TextField("192.168.1.51 或 IP:5555", text: $model.tabletAddressInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 210)
                        Button("重新连接") { model.onReconnect?(model.tabletAddressInput) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("留空重连会自动扫描（需 USB）；填写新 IP 会走 ADB 隧道，Mac IP 变化不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("设置")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    detailLabel("分辨率")
                    Picker("", selection: $model.resolutionID) {
                        ForEach(model.resolutionOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 230)
                    Text("重启生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    detailLabel("帧率")
                    Picker("", selection: $model.fps) {
                        ForEach(model.fpsOptions, id: \.self) { value in
                            Text("\(value) fps").tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    Text("重启生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    detailLabel("码率")
                    Picker("", selection: $model.bitrate) {
                        ForEach(model.bitrateOptions, id: \.self) { value in
                            Text("\(value) Mbps").tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    Text("立即生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    detailLabel("")
                    Toggle("启动时显示此窗口", isOn: $model.showWindowOnLaunch)
                        .toggleStyle(.checkbox)
                }
                GridRow {
                    detailLabel("")
                    Toggle("关闭窗口时退出应用", isOn: $model.quitOnWindowClose)
                        .toggleStyle(.checkbox)
                }
            }

            HStack(spacing: 8) {
                Text("分辨率/帧率保存后需重启；码率立即生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存并重启") { model.onRestart?() }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                detailLabel("权限")
                Button("屏幕录制") { model.onPermission?(.screenRecording) }
                Button("辅助功能") { model.onPermission?(.accessibility) }
                Button("本地网络") { model.onPermission?(.localNetwork) }
            }
            .buttonStyle(.bordered)

            Divider()

            HStack(spacing: 8) {
                Button("打开状态页") { model.onOpenHealth?() }
                Button("打开日志") { model.onOpenLog?() }
                Spacer()
                Button("退出应用") { model.onQuit?() }
                    .tint(.red)
            }
            .buttonStyle(.bordered)

            Text("默认关闭窗口后应用仍在菜单栏运行；可在上方切换为直接退出。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 480, alignment: .leading)
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 90, alignment: .trailing)
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(text)
    }
}

@MainActor
final class ControlPanelController: NSObject, NSWindowDelegate {
    private let model: ControlPanelModel
    private let window: NSWindow

    init(port: UInt16 = 9137) {
        let model = ControlPanelModel(port: port)
        self.model = model
        let hosting = NSHostingController(rootView: ControlPanelView(model: model))
        self.window = NSWindow(contentViewController: hosting)
        super.init()

        window.title = "Tablet Display"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.setFrameAutosaveName("TabletDisplayControlPanelV2")
        window.setContentSize(NSSize(width: 480, height: 800))
        window.center()

        model.onRestart = { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        model.onReconnect = { [weak self] input in
            MainActor.assumeIsolated { self?.reconnect(input) }
        }
        model.onQuit = {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        model.onOpenHealth = { [weak self] in
            MainActor.assumeIsolated { self?.openHealth() }
        }
        model.onOpenLog = { [weak self] in
            MainActor.assumeIsolated { self?.openLog() }
        }
        model.onPermission = { [weak self] pane in
            MainActor.assumeIsolated { self?.openPermission(pane) }
        }
    }

    @MainActor
    func showIfEnabled() {
        if model.showWindowOnLaunch {
            show()
        }
    }

    @MainActor
    func show() {
        AppLog.write("控制面板：显示")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if model.quitOnWindowClose {
            NSApp.terminate(nil)
        }
    }

    nonisolated func updateStatus(_ text: String, level: ControlStatusLevel) {
        Task { @MainActor [weak self] in
            self?.model.status = text
            self?.model.statusLevel = level
        }
    }

    nonisolated func updateDisplay(_ text: String) {
        Task { @MainActor [weak self] in self?.model.display = text }
    }

    nonisolated func updateTransport(_ text: String) {
        Task { @MainActor [weak self] in self?.model.transport = text }
    }

    nonisolated func updateTablet(_ text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.model.tablet = text
            if self.model.tabletAddressInput.isEmpty {
                self.model.tabletAddressInput = text
            }
        }
    }

    nonisolated func updateMacAddress(_ text: String) {
        Task { @MainActor [weak self] in self?.model.macAddress = text }
    }

    nonisolated func updateServer(_ text: String) {
        Task { @MainActor [weak self] in self?.model.server = text }
    }

    nonisolated func setPort(_ port: UInt16) {
        Task { @MainActor [weak self] in self?.model.port = port }
    }

    nonisolated func setInitialBitrate(_ mbps: Int) {
        Task { @MainActor [weak self] in self?.model.bitrate = mbps }
    }

    nonisolated func setBitrateHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.model.onBitrateChange = handler
            handler(self.model.bitrate)
        }
    }

    @MainActor
    private func openHealth() {
        guard let url = URL(string: "http://127.0.0.1:\(model.port)/health") else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func openLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
    }

    @MainActor
    private func openPermission(_ pane: PermissionPane) {
        PermissionGuide.open(pane)
    }

    @MainActor
    private func reconnect(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            model.status = "正在重新连接…"
            model.statusLevel = .starting
            restart(forceAuto: true)
            return
        }

        let endpoint = value.contains(":") ? value : value + ":5555"
        guard ADB.isWireless(endpoint) else {
            model.status = "平板地址格式无效，请输入 IPv4 或 IP:端口"
            model.statusLevel = .error
            return
        }

        model.status = "正在连接 \(endpoint)…"
        model.statusLevel = .starting
        Task.detached { [weak self] in
            do {
                let connected = try ADB.connectSaved(endpoint)
                ADB.saveEndpoint(connected)
                await MainActor.run {
                    guard let self else { return }
                    self.model.tabletAddressInput = connected
                    self.restart(endpoint: connected)
                }
            } catch {
                await MainActor.run {
                    self?.model.status = "连接失败：\(error.localizedDescription)"
                    self?.model.statusLevel = .error
                }
            }
        }
    }

    @MainActor
    private func restart(endpoint: String? = nil, forceAuto: Bool = false) {
        guard let executable = Bundle.main.executableURL?.path else { return }

        model.status = "正在重启…"
        model.statusLevel = .starting

        var arguments: [String] = []
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        let displayValueOptions: Set<String> = ["--width", "--height", "--fps", "--bitrate"]
        let passthroughValueOptions: Set<String> = ["--port", "--serial", "--duration",
                                                    "--direct-host", "--token"]
        let resetTransport = endpoint != nil || forceAuto
        while let argument = iterator.next() {
            if displayValueOptions.contains(argument) {
                _ = iterator.next()
                continue
            }
            if resetTransport && (argument == "--serial" || argument == "--direct-host") {
                _ = iterator.next()
                continue
            }
            if resetTransport && argument == "--no-adb" {
                continue
            }
            if argument == "--hidpi" || argument == "--no-hidpi" {
                continue
            }
            arguments.append(argument)
            if passthroughValueOptions.contains(argument), let value = iterator.next() {
                arguments.append(value)
            }
        }
        if let endpoint {
            // An explicit endpoint without --direct-host forces the ADB
            // tunnel, so a changed Mac LAN address cannot break the session.
            arguments += ["--serial", endpoint]
        }
        arguments += [
            "--width", "\(model.width)",
            "--height", "\(model.height)",
            "--fps", "\(model.fps)",
            "--bitrate", "\(model.bitrate)",
            "--no-hidpi"
        ]

        let pid = ProcessInfo.processInfo.processIdentifier
        let command = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; " +
            "sleep 0.5; exec \(Self.shellQuote(executable)) " +
            arguments.map { Self.shellQuote($0) }.joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.write("重启失败：\(error.localizedDescription)")
            model.status = "重启失败：\(error.localizedDescription)"
            model.statusLevel = .error
            return
        }

        AppLog.write("控制面板：保存设置并重启")
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
