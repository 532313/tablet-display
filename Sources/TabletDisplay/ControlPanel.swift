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
    @Published var discoveredTablets: [String] = []
    @Published var scanningTablets = false
    @Published var pairingURL: String?
    @Published var pairingImage: NSImage?
    @Published var pairingHint = "直连模式下生成配对二维码"
    @Published var showWelcome: Bool {
        didSet {
            UserDefaults.standard.set(!showWelcome, forKey: "TabletDisplayWelcomeDismissed")
        }
    }

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
    @Published var touchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(touchEnabled, forKey: "TabletDisplayTouchEnabled")
            onTouchChange?(touchEnabled)
        }
    }

    @Published var resolutionOptions: [ResolutionOption]
    let fpsOptions: [Int]
    let bitrateOptions: [Int]
    let version: String
    var port: UInt16

    var onBitrateChange: (@Sendable (Int) -> Void)?
    var onRestart: (() -> Void)?
    var onTouchChange: (@Sendable (Bool) -> Void)?
    var onReconnect: ((String) -> Void)?
    var onScan: (() -> Void)?
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
            ResolutionOption(id: "macbook", title: "横屏 · 匹配 MacBook 1470×956", width: 1470, height: 956),
            ResolutionOption(id: "wide", title: "横屏 · 1920×1200", width: 1920, height: 1200),
            ResolutionOption(id: "native", title: "横屏 · 平板原生 2560×1600", width: 2560, height: 1600),
            ResolutionOption(id: "compact", title: "横屏 · 1280×800", width: 1280, height: 800),
            ResolutionOption(id: "macbook-portrait", title: "竖屏 · 匹配 MacBook 956×1470", width: 956, height: 1470),
            ResolutionOption(id: "wide-portrait", title: "竖屏 · 1200×1920", width: 1200, height: 1920),
            ResolutionOption(id: "native-portrait", title: "竖屏 · 平板原生 1600×2560", width: 1600, height: 2560),
            ResolutionOption(id: "compact-portrait", title: "竖屏 · 800×1280", width: 800, height: 1280)
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
        showWelcome = !defaults.bool(forKey: "TabletDisplayWelcomeDismissed")
        showWindowOnLaunch = defaults.object(forKey: "TabletDisplayShowWindow") as? Bool ?? true
        quitOnWindowClose = defaults.object(forKey: "TabletDisplayQuitOnWindowClose") as? Bool ?? false
        touchEnabled = defaults.object(forKey: "TabletDisplayTouchEnabled") as? Bool ?? true
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
        case .starting: return .blue
        case .running: return .green
        case .warning: return .orange
        case .error: return .red
        case .stopped: return .secondary
        }
    }

    func dismissWelcome() {
        showWelcome = false
    }

    func setPairing(host: String?, port: UInt16, token: String, udpPort: UInt16) {
        guard let host, !host.isEmpty,
              let url = PairingQRCode.url(host: host, port: port, token: token, udpPort: udpPort) else {
            pairingURL = nil
            pairingImage = nil
            pairingHint = "直连模式下生成配对二维码"
            return
        }
        pairingURL = url.absoluteString
        pairingImage = PairingQRCode.image(for: url.absoluteString)
        pairingHint = "用平板相机扫描二维码即可连接"
    }

    func applyLiveSize(width: Int, height: Int) {
        if let option = resolutionOptions.first(where: { $0.width == width && $0.height == height }) {
            resolutionID = option.id
        } else {
            let custom = ResolutionOption(id: "custom", title: "自定义 · \(width)×\(height)",
                                          width: width, height: height)
            resolutionOptions.removeAll { $0.id == "custom" }
            resolutionOptions.append(custom)
            resolutionID = custom.id
        }
    }

    private func saveResolution() {
        guard let option = resolutionOptions.first(where: { $0.id == resolutionID }) else { return }
        UserDefaults.standard.set(option.width, forKey: "TabletDisplayWidth")
        UserDefaults.standard.set(option.height, forKey: "TabletDisplayHeight")
    }
}

private enum PanelSection: String, CaseIterable, Identifiable {
    case overview
    case display
    case connection
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .display: return "显示与交互"
        case .connection: return "连接"
        case .general: return "通用"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "平板扩展屏的实时状态"
        case .display: return "画面、方向与输入设置"
        case .connection: return "网络地址与设备连接"
        case .general: return "启动行为、权限与关于"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .display: return "display"
        case .connection: return "wifi"
        case .general: return "slider.horizontal.3"
        }
    }
}

private final class ControlPanelNavigation: ObservableObject {
    @Published var selection: PanelSection = .overview
}

private struct ControlPanelView: View {
    @ObservedObject var model: ControlPanelModel
    @ObservedObject var navigation: ControlPanelNavigation

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.45)
            detail
        }
        .frame(minWidth: 720, minHeight: 540)
        .background(WindowBackdrop())
        .animation(.easeOut(duration: 0.18), value: navigation.selection)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tablet Display")
                        .font(.system(size: 13, weight: .semibold))
                    Text(AppText.t("扩展屏控制"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 36)

            VStack(spacing: 3) {
                ForEach(PanelSection.allCases) { section in
                    SidebarButton(section: section, selected: navigation.selection == section) {
                        navigation.selection = section
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 28)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.statusColor)
                        .frame(width: 7, height: 7)
                    Text(AppText.status(statusTitle))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(model.statusColor)
                }
                Text(AppText.status(model.status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            HStack {
                Text("v\(model.version)")
                Spacer()
                Text(AppText.t("端口") + " " + String(model.port))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial)
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppText.t(navigation.selection.title))
                            .font(.system(size: 26, weight: .semibold))
                        Text(AppText.t(navigation.selection.subtitle))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(title: statusTitle, color: model.statusColor)
                }
                sectionContent
            }
            .padding(.horizontal, 28)
            .padding(.top, 38)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch navigation.selection {
        case .overview:
            overviewContent
        case .display:
            displayContent
        case .connection:
            connectionContent
        case .general:
            generalContent
        }
    }

    // MARK: - Overview

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.showWelcome {
                WelcomeCard {
                    model.onPermission?(.screenRecording)
                } dismiss: {
                    model.dismissWelcome()
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(model.statusColor.opacity(0.13))
                        Image(systemName: statusSymbol)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(model.statusColor)
                    }
                    .frame(width: 50, height: 50)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppText.status(statusTitle))
                            .font(.system(size: 19, weight: .semibold))
                        Text(AppText.status(model.status))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("当前画面")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(model.display)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }
                }

                Divider().opacity(0.6)

                HStack(spacing: 10) {
                    Button("重新连接") { model.onReconnect?("") }
                        .buttonStyle(.bordered)
                    Button("状态页") { model.onOpenHealth?() }
                        .buttonStyle(.bordered)
                    Button("查看日志") { model.onOpenLog?() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("保存并重启") { model.onRestart?() }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.regular)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                MetricCard(symbol: "display", title: "虚拟显示器", value: model.display, tint: .blue)
                MetricCard(symbol: "arrow.left.arrow.right", title: "传输", value: model.transport, tint: .teal)
                MetricCard(symbol: "ipad", title: "平板", value: model.tablet, tint: .indigo)
                MetricCard(symbol: "network", title: "视频服务", value: model.server, tint: .orange)
            }

            PanelCard(title: "连接概览", symbol: "point.3.connected.trianglepath.dotted") {
                InfoRow(label: "本机", value: model.macAddress, copyable: true)
                InfoRow(label: "平板", value: model.tablet, copyable: true)
                InfoRow(label: "传输", value: model.transport)
            }

            Text("方向自动跟随平板，原地切换；虚拟显示器始终保持在主屏右侧。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Display

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelCard(title: "画面", symbol: "display") {
                HStack(alignment: .center, spacing: 20) {
                    ScreenPreview(width: model.width, height: model.height)
                    VStack(spacing: 12) {
                        SettingRow(label: "分辨率", hint: "重启生效") {
                            Picker("", selection: $model.resolutionID) {
                                ForEach(model.resolutionOptions) { option in
                                    Text(AppText.t(option.title)).tag(option.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 216)
                        }
                        SettingRow(label: "帧率", hint: "重启生效") {
                            Picker("", selection: $model.fps) {
                                ForEach(model.fpsOptions, id: \.self) { value in
                                    Text("\(value) fps").tag(value)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 216)
                        }
                        SettingRow(label: "码率", hint: "立即生效") {
                            Picker("", selection: $model.bitrate) {
                                ForEach(model.bitrateOptions, id: \.self) { value in
                                    Text("\(value) Mbps").tag(value)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 216)
                        }
                    }
                }
            }

            PanelCard(title: "交互与行为", symbol: "hand.tap") {
                Toggle("允许平板触摸", isOn: $model.touchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("关闭后 Mac 会忽略平板触摸，正在拖动时会自动释放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider().opacity(0.5)
                Toggle("启动时显示此窗口", isOn: $model.showWindowOnLaunch)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("关闭窗口时退出应用", isOn: $model.quitOnWindowClose)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack(alignment: .center, spacing: 16) {
                Text("分辨率/帧率保存后需重启；码率和触摸开关立即生效。分辨率作为方向切换的尺寸基准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("保存并重启") { model.onRestart?() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    // MARK: - Connection

    private var connectionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelCard(title: "本机", symbol: "desktopcomputer") {
                InfoRow(label: "局域网 IP", value: model.macAddress, copyable: true)
                InfoRow(label: "视频服务", value: model.server, copyable: true)
                InfoRow(label: "当前传输", value: model.transport)
            }

            PanelCard(title: "平板", symbol: "ipad") {
                HStack(spacing: 10) {
                    TextField("192.168.1.51 或 IP:5555", text: $model.tabletAddressInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.onReconnect?(model.tabletAddressInput) }
                    Button("重新连接") { model.onReconnect?(model.tabletAddressInput) }
                        .buttonStyle(.borderedProminent)
                }
                Text("留空会自动扫描（需 USB）；填写新 IP 优先直连，无可用路由时走 ADB 隧道。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("自动扫描并重连") { model.onReconnect?("") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Text(model.tablet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            PanelCard(title: "附近设备", symbol: "dot.radiowaves.left.and.right") {
                HStack(spacing: 8) {
                    Text("通过 ADB/mDNS 发现已开启无线调试的平板")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.scanningTablets {
                        ProgressView().controlSize(.small)
                    }
                    Button("扫描") { model.onScan?() }
                        .buttonStyle(.bordered)
                }
                if model.discoveredTablets.isEmpty {
                    Text(model.scanningTablets ? "正在扫描…" : "未发现设备")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(model.discoveredTablets, id: \.self) { endpoint in
                            HStack(spacing: 8) {
                                Image(systemName: "ipad")
                                    .foregroundStyle(.secondary)
                                Text(endpoint)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                                Button("连接") { model.onReconnect?(endpoint) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            PanelCard(title: "二维码配对", symbol: "qrcode") {
                if let image = model.pairingImage, let url = model.pairingURL {
                    HStack(alignment: .top, spacing: 16) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 116, height: 116)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityLabel("平板配对二维码")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(AppText.t(model.pairingHint))
                                .font(.callout.weight(.medium))
                            Text("用平板相机或扫码器扫描后，Tablet Display 会自动填入 host、端口和 token。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(url)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                CopyButton(text: url)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Text(AppText.t(model.pairingHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("二维码只在局域网直连模式可用；ADB 隧道模式请使用 USB 或 ADB 连接。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            PanelCard(title: "权限", symbol: "lock.shield") {
                HStack(spacing: 8) {
                    PermissionButton(title: "屏幕录制", symbol: "rectangle.dashed.badge.record") {
                        model.onPermission?(.screenRecording)
                    }
                    PermissionButton(title: "辅助功能", symbol: "cursorarrow.motionlines") {
                        model.onPermission?(.accessibility)
                    }
                    PermissionButton(title: "本地网络", symbol: "network") {
                        model.onPermission?(.localNetwork)
                    }
                    Spacer()
                }
                Text("首次使用需要授予相应权限；修改后可能需要重新启动应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - General

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                AppMark(size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tablet Display")
                        .font(.system(size: 21, weight: .semibold))
                    Text("把平板变成 Mac 的无线扩展屏")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("版本 \(model.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )

            PanelCard(title: "启动与关闭", symbol: "power") {
                Toggle("启动时显示此窗口", isOn: $model.showWindowOnLaunch)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("关闭窗口时退出应用", isOn: $model.quitOnWindowClose)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("默认关闭窗口后仍在菜单栏运行，可从菜单栏重新打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PanelCard(title: "支持", symbol: "questionmark.circle") {
                HStack(spacing: 8) {
                    Button("打开状态页") { model.onOpenHealth?() }
                        .buttonStyle(.bordered)
                    Button("打开日志") { model.onOpenLog?() }
                        .buttonStyle(.bordered)
                    Link("项目主页", destination: URL(string: "https://github.com/532313/tablet-display")!)
                        .buttonStyle(.bordered)
                    Spacer()
                }
                Text(AppLog.fileURL.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack {
                Text("Tablet Display 仅建议在可信局域网使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出应用") { model.onQuit?() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
            .padding(.top, 2)
        }
    }

    private var statusTitle: String {
        switch model.statusLevel {
        case .starting: return "正在启动"
        case .running: return "运行中"
        case .warning: return "需要注意"
        case .error: return "出现错误"
        case .stopped: return "已停止"
        }
    }

    private var statusSymbol: String {
        switch model.statusLevel {
        case .starting: return "hourglass"
        case .running: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .stopped: return "pause.circle.fill"
        }
    }
}

private struct WelcomeCard: View {
    let openPermissions: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 Tablet Display")
                        .font(.system(size: 15, weight: .semibold))
                    Text("三步把平板变成 Mac 的第二块屏幕")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("不再显示", action: dismiss)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                WelcomeStep(number: "1", text: "USB 连接并开启调试")
                WelcomeStep(number: "2", text: "切换到无线 ADB")
                WelcomeStep(number: "3", text: "允许屏幕录制与辅助功能")
            }
            HStack(spacing: 8) {
                Button("打开权限设置", action: openPermissions)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text("首次连接后可在“连接”页扫描附近设备。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct WelcomeStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(number)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.accentColor.opacity(0.75)))
            Text(AppText.t(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WindowBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.accentColor.opacity(0.055), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

private struct AppMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.accentColor.opacity(0.24), radius: 10, y: 4)
        .accessibilityHidden(true)
    }
}

private struct SidebarButton: View {
    let section: PanelSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(AppText.t(section.title))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        selected ? Color.accentColor.opacity(0.15) : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(AppText.t(title))
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.1)))
        .overlay(Capsule().strokeBorder(color.opacity(0.18), lineWidth: 1))
    }
}

private struct PanelCard<Content: View>: View {
    let title: String?
    let symbol: String?
    private let content: Content

    init(title: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let title {
                HStack(spacing: 7) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(AppText.t(title))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.035), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
    }
}

private struct MetricCard: View {
    let symbol: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.12)))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(AppText.t(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var copyable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(AppText.t(label))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
            Spacer(minLength: 4)
            if copyable {
                CopyButton(text: value)
            }
        }
    }
}

private struct SettingRow<Content: View>: View {
    let label: String
    let hint: String
    private let content: Content

    init(label: String, hint: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(AppText.t(label))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            content
            Spacer(minLength: 0)
            Text(AppText.t(hint))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct ScreenPreview: View {
    let width: Int
    let height: Int

    private var ratio: CGFloat {
        guard height > 0 else { return 1.5 }
        return CGFloat(width) / CGFloat(height)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.72), Color.accentColor.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .aspectRatio(ratio, contentMode: .fit)
                    .padding(11)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                            .aspectRatio(ratio, contentMode: .fit)
                            .padding(11)
                    )
            }
            .frame(width: 120, height: 92)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            Text("\(width) × \(height)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("显示器预览 \(width) 乘 \(height)")
    }
}

private struct PermissionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .padding(.horizontal, 3)
        }
        .buttonStyle(.bordered)
    }
}

private struct CopyButton: View {
    let text: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("复制")
        .accessibilityLabel("复制")
    }
}

@MainActor
final class ControlPanelController: NSObject, NSWindowDelegate {
    private let model: ControlPanelModel
    private let navigation: ControlPanelNavigation
    private let window: NSWindow

    init(port: UInt16 = 9137) {
        let model = ControlPanelModel(port: port)
        let navigation = ControlPanelNavigation()
        self.model = model
        self.navigation = navigation
        let hosting = NSHostingController(rootView: ControlPanelView(model: model, navigation: navigation))
        self.window = NSWindow(contentViewController: hosting)
        super.init()

        window.title = "Tablet Display"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.delegate = self
        window.setFrameAutosaveName("TabletDisplayControlPanelV5")
        window.setContentSize(NSSize(width: 780, height: 640))
        window.minSize = NSSize(width: 720, height: 540)
        window.center()

        model.onRestart = { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        model.onReconnect = { [weak self] input in
            MainActor.assumeIsolated { self?.reconnect(input) }
        }
        model.onScan = { [weak self] in
            MainActor.assumeIsolated { self?.scanTablets() }
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

    nonisolated func updatePairing(host: String?, port: UInt16, token: String, udpPort: UInt16) {
        Task { @MainActor [weak self] in
            self?.model.setPairing(host: host, port: port, token: token, udpPort: udpPort)
        }
    }

    func applyLiveSize(width: Int, height: Int) {
        model.applyLiveSize(width: width, height: height)
    }

    @MainActor
    func restartForNetwork(serial: String?, directHost: String?) {
        AppLog.write("网络恢复：使用 \(serial ?? "自动") / \(directHost ?? "ADB 隧道") 重启")
        restart(endpoint: serial, directHost: directHost)
    }

    @MainActor
    func writeSnapshot(to url: URL) throws {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        guard let view = window.contentView else {
            throw NSError(domain: "TabletDisplay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "控制面板没有内容视图"])
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "TabletDisplay", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建位图"])
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "TabletDisplay", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG"])
        }
        try data.write(to: url)
    }

    @MainActor
    func showIfEnabled() {
        if model.showWindowOnLaunch {
            show()
        }
    }

    nonisolated func show() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            AppLog.write("控制面板：显示")
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
        }
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

    nonisolated func setTouchHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor [weak self] in self?.model.onTouchChange = handler }
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
    private func scanTablets() {
        guard !model.scanningTablets else { return }
        model.scanningTablets = true
        Task.detached { [weak self] in
            let devices = (try? ADB.listDevices())?.map(\.serial) ?? []
            let endpoints = ADB.mdnsEndpoints()
            await MainActor.run {
                guard let self else { return }
                self.model.discoveredTablets = Array(Set(devices + endpoints)).sorted()
                self.model.scanningTablets = false
            }
        }
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
                    let macIP = ADB.host(fromSerial: connected)
                        .flatMap { LocalNetwork.ipv4(towards: $0) }
                    self.restart(endpoint: connected, directHost: macIP)
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
    private func restart(endpoint: String? = nil, directHost: String? = nil,
                        forceAuto: Bool = false, width overrideWidth: Int? = nil,
                        height overrideHeight: Int? = nil) {
        let bundle = Bundle.main.bundleURL.path

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
            arguments += ["--serial", endpoint]
            if let directHost {
                // Prefer the lower-latency LAN path again after a manual
                // reconnect; fall back to the ADB tunnel when no route exists.
                arguments += ["--direct-host", directHost]
            }
        }
        arguments += [
            "--width", "\(overrideWidth ?? model.width)",
            "--height", "\(overrideHeight ?? model.height)",
            "--fps", "\(model.fps)",
            "--bitrate", "\(model.bitrate)",
            "--no-hidpi"
        ]

        let pid = ProcessInfo.processInfo.processIdentifier
        // Launch through LaunchServices instead of exec'ing the binary from the
        // dying app. This matches a normal Finder/launcher start and avoids the
        // short ADB transport race seen after an in-process restart.
        let command = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; " +
            "sleep 2.0; exec /usr/bin/open -n -a \(Self.shellQuote(bundle)) --args " +
            arguments.map { Self.shellQuote($0) }.joined(separator: " ")

        AppLog.write("重启命令：\(command)")

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
