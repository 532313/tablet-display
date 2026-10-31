# 架构说明

## 组件

```text
Mac                                   Android 平板
┌──────────────────────────┐          ┌──────────────────────────┐
│ TabletDisplay (Swift)    │          │ Tablet Display APK       │
│  ├─ VirtualDisplayBridge │          │  ├─ MediaCodec 硬解       │
│  ├─ ScreenCaptureKit     │  H.264   │  ├─ SurfaceView           │
│  ├─ VideoToolbox         │ ───────► │  └─ 触摸回传              │
│  ├─ HTTPServer           │  Wi-Fi   │                          │
│  └─ StatusBar / ADB      │ ◄─────── │                          │
└──────────────────────────┘  触摸     └──────────────────────────┘
```

- **VirtualDisplayBridge**：用 macOS 私有 `CGVirtualDisplay` 创建虚拟屏，选择模式并放到主屏右侧。
- **ScreenCaptureKit**：按 60Hz 采集虚拟屏；静止画面由定时器重复编码最后一帧，避免部分硬解在无新输入时延迟出帧。采集生命周期代次会使停止前挂起的异步启动失效；停止时先取消定时器并排空采集队列，再关闭编码器。
- **VideoToolbox**：H.264 High、实时模式、20Mbps 默认码率，关键帧间隔为 60 秒，客户端缺失关键帧时按需请求 IDR。
- **HTTPServer**：`/video` 输出带长度前缀的 H.264 帧；`/input` 接收 9 字节触摸包；token + 平板 IP 白名单。请求读取有 10 秒总超时；`/input` 断开时自动补发 `up`。直连 IP 由系统路由表和网卡实际子网掩码确定。
- **真机 smoke**：`scripts/test-device-smoke.sh` 通过 ADB 安装并检查前台服务/通知。
- **真机 E2E**：`scripts/test-device-video.sh` 用固定 token 验证视频解码、触摸注入和强制横屏/恢复；结束后恢复普通启动和用户设置。
- **Android Service**：`TabletDisplayService` 以前台服务持有 Wi-Fi 低延迟锁和常驻通知；Activity 负责 Surface/解码。
- **Android**：硬解到 `SurfaceView`，独立输出线程按 vsync 时间戳提交；触摸按实际视频区域归一化后回传，黑边内松开也会发送 `up`；视频断线按 500ms 起、封顶 5s 的指数退避重连。
- **单实例**：核心 App 使用 `~/Library/Application Support/TabletDisplay/instance.lock` 的 `flock`，第二实例只激活已有窗口。
- **网络恢复**：每 5 秒比较当前 Mac IP 与路由结果，并通过 mDNS 检查平板新地址；变化时带新地址重启连接。
- **可恢复启动**：屏幕录制、采集、端口占用失败会保留控制面板，允许修复后重试。
- **二维码配对**：控制面板用 CoreImage 生成 `tabletdisplay://pair` 二维码；Android Manifest 注册 VIEW deep link，Activity 解析 host/port/token/udpPort。
- **本地化**：Mac 使用 `Resources/en.lproj/Localizable.strings`（控制面板/菜单/权限）；Android 使用 `res/values-en/strings.xml`（状态/通知）。
- **首次引导/发现**：控制面板欢迎卡引导 USB/无线/权限；连接页通过 `ADB.listDevices` 与 `ADB.mdnsEndpoints` 扫描附近设备。
- **控制面板**：启动时显示 SwiftUI 窗口（`NSHostingController`），展示虚拟屏/传输/平板状态，支持分辨率/帧率/码率设置、保存并重启、启动显示/关闭退出开关、权限/日志/状态页/退出；网络区域可输入平板新 IP 重连（优先直连，失败回退 ADB 隧道）；启动 ADB/分辨率失败时保留面板等待重连。
- **公证**：`Notarized Release` workflow 从 secrets 导入 Developer ID P12，使用 hardened runtime 签名 DMG，notarytool 提交并 staple；需要 Apple Developer 凭据。
- **启动器**：常规 Dock 应用 + 菜单栏状态项，提供控制面板、状态和退出；桌面启动器通过 LaunchServices 启动核心 App 并传入 UI 尺寸。

## 数据流

1. Mac 创建 1470×956 或 2560×1600 的虚拟屏。
2. ScreenCaptureKit 采集 `IOSurface`，VideoToolbox 编码成 Annex-B H.264。
3. `VideoFrameStore` 缓存最近 90 帧，关键帧接入、积压跳帧。
4. 平板通过 `/video` 拉流，MediaCodec 解码到 SurfaceView。
5. 触摸坐标归一化后通过 `/input` 发回，Mac 用 `CGEvent` 注入鼠标。

## 线程

- 采集队列：SCK sample handler + 60Hz 保活 timer；流、定时器和生命周期代次受状态锁保护，编码器会话在关闭时与提交中的帧同步。
- 编码回调：VideoToolbox 线程，写入加锁的帧队列。
- 网络：每个连接一个全局队列任务；发送超时 5s。直连模式优先 UDP-RTP（9138），TCP `/video` 作为兜底。
- 平板：视频接收线程 + 解码输出线程 + 输入发送线程。

## 分辨率和 HiDPI

- 核心应用默认使用平板 `wm size` 的 **Physical size**（当前 2560×1600）。
- 桌面启动器使用 1470×956，让 UI 尺寸与 13 寸 MacBook 一致；平板放大后文字略软。
- macOS 27 的 `CGVirtualDisplay` 实测不提供 2x 模式，因此无法同时做到“原生像素 + Mac 尺寸 UI”。
- 当前产品范围：仅 Apple Silicon（arm64）；构建脚本和 CI 都拒绝非 arm64 产物。

## 权限

- 屏幕录制：ScreenCaptureKit 必需。
- 辅助功能：`CGEvent` 触摸注入必需。
- 本地网络：无线 ADB / 局域网连接；应用包声明 `NSLocalNetworkUsageDescription`，首次连接时由系统显示用途说明。
- ad-hoc 签名在每次重新构建后会改变，TCC 可能需要重新绑定核心应用。运行 `make signing` 创建固定的本地自签名身份，或使用 Developer ID/Apple Development 身份，可以避免这个问题。菜单栏提供“权限设置”和“打开日志”入口。

## 构建产物

- `build/TabletDisplay.app`：开发构建（含 APK 和图标）。
- `build/TabletDisplay.apk`：Android 接收端。
- `dist/Tablet Display-<version>.dmg`：发布镜像。
- `~/Library/Application Support/TabletDisplay/debug.keystore`：Android 调试签名 key，不在仓库内；`TABLETDISPLAY_DEBUG_KEYSTORE` 可覆盖。
