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
- **VideoToolbox**：H.264 High、实时模式、20Mbps 默认码率，关键帧间隔为 `fps / 2`。
- **HTTPServer**：`/video` 输出带长度前缀的 H.264 帧；`/input` 接收 9 字节触摸包；token + 平板 IP 白名单。直连 IP 由系统路由表和网卡实际子网掩码确定。
- **Android**：硬解到 `SurfaceView`，独立输出线程按 vsync 时间戳提交；触摸按实际视频区域归一化后回传。
- **启动器**：菜单栏应用（`LSUIElement`），提供状态、退出；桌面启动器负责传入 1470×956 的 UI 尺寸。

## 数据流

1. Mac 创建 1470×956 或 2560×1600 的虚拟屏。
2. ScreenCaptureKit 采集 `IOSurface`，VideoToolbox 编码成 Annex-B H.264。
3. `VideoFrameStore` 缓存最近 90 帧，关键帧接入、积压跳帧。
4. 平板通过 `/video` 拉流，MediaCodec 解码到 SurfaceView。
5. 触摸坐标归一化后通过 `/input` 发回，Mac 用 `CGEvent` 注入鼠标。

## 线程

- 采集队列：SCK sample handler + 60Hz 保活 timer；流、定时器和生命周期代次受状态锁保护，编码器会话在关闭时与提交中的帧同步。
- 编码回调：VideoToolbox 线程，写入加锁的帧队列。
- 网络：每个连接一个全局队列任务；发送超时 5s。
- 平板：视频接收线程 + 解码输出线程 + 输入发送线程。

## 分辨率和 HiDPI

- 核心应用默认使用平板 `wm size` 的 **Physical size**（当前 2560×1600）。
- 桌面启动器使用 1470×956，让 UI 尺寸与 13 寸 MacBook 一致；平板放大后文字略软。
- macOS 27 的 `CGVirtualDisplay` 实测不提供 2x 模式，因此无法同时做到“原生像素 + Mac 尺寸 UI”。

## 权限

- 屏幕录制：ScreenCaptureKit 必需。
- 辅助功能：`CGEvent` 触摸注入必需。
- 本地网络：无线 ADB / 局域网连接；应用包声明 `NSLocalNetworkUsageDescription`，首次连接时由系统显示用途说明。
- ad-hoc 签名在每次重新构建后会改变，TCC 可能需要重新绑定核心应用。稳定签名（Developer ID 或固定自签名）可以避免这个问题。

## 构建产物

- `build/TabletDisplay.app`：开发构建（含 APK 和图标）。
- `build/TabletDisplay.apk`：Android 接收端。
- `dist/Tablet Display-<version>.dmg`：发布镜像。
- `~/Library/Application Support/TabletDisplay/debug.keystore`：Android 调试签名 key，不在仓库内；`TABLETDISPLAY_DEBUG_KEYSTORE` 可覆盖。
