# Changelog

## Unreleased

- 触摸：黑边内松开也会发送 `up`；`/input` 断开时服务端自动释放鼠标；Android 视频重连改为 500ms 起、封顶 5s 的指数退避。
- 参数：`--width`、`--height`、`--port`、`--duration` 等非法/越界值现在直接报错，不再静默回退。
- HTTP：请求头和请求体读取增加 10 秒总超时；`/input` 连接不再被读超时误伤。
- 签名：新增 `scripts/create-signing-identity.sh` 和 `make signing`，构建自动使用稳定的本地签名身份；菜单栏增加权限设置和日志入口。
- 测试：新增 `/video` 帧格式与鉴权、`/input` 解析、断连释放、重连、请求超时的本机 socket 集成测试；新增 Android 纯 Java 协议/重连测试。
- CI：新增 GitHub Actions，macOS 构建 + 核心测试，Ubuntu 构建 APK + Android 协议测试。
- 安装：`make install` 覆盖旧版 App 并重建桌面启动器；启动器生成或签名校验失败会直接报错；修复 `pipefail` 下签名检测被 SIGPIPE 误判为 ad-hoc 的问题。
- 签名：稳定本地签名已实战验证，重建并覆盖安装后 TCC 授权保留。
- Android：新增自适应启动图标（渐变背景 + 平板/双窗口/光标/Wi-Fi 前景），`aapt2` 构建已接入资源编译。
- macOS：新增启动控制面板（SwiftUI），显示实时状态，支持分辨率/帧率/码率设置、保存并重启、启动时显示/关闭时退出开关、权限/日志/状态页/退出；桌面启动器读取保存设置。
- 网络恢复：控制面板显示本机/平板 IP，支持输入平板新 IP 重连（ADB 隧道）；启动时 ADB/分辨率失败会保留控制面板等待重连，不再直接退出。
- ADB 恢复：连接失败时自动重启 adb server 并重试，兼容 Android 11+ 无线调试的 mDNS endpoint。
- 延迟优化：手动重连优先直连；Android 获取 Wi-Fi 低延迟锁；H.264 改为长 GOP，并在新客户端/落后时按需强制关键帧，减少周期突发。
- UDP-RTP：直连时视频优先走 UDP 9138，H.264 FU-A 分片、RTP 时间戳/标记位、心跳与丢包 IDR 请求；UDP 失败自动回退 TCP。
- 控制面板改版：采用 macOS 系统设置式侧边栏与材质窗口，新增概览状态卡、指标卡、竖屏预览、分区设置和原生开关；保留全部连接、显示、权限和启动行为。
- 单实例：核心 App 使用 `flock`，第二次启动只激活已有控制面板，不再产生重复进程或端口冲突。
- 二维码配对：Mac 直连模式生成配对二维码，Android 注册 `tabletdisplay://pair` deep link，扫码后自动使用 host/端口/token 重连。
- 首次体验：概览新增三步欢迎卡，连接页新增 ADB/mDNS 附近设备扫描和权限入口。
- 可访问性：控制面板卡片、复制按钮、预览增加 VoiceOver 标签/组合。
- Android 前台服务：常驻通知、Wi-Fi 低延迟锁移入 Service，真机验证 `isForeground=true`。
- 本地化：Mac 控制面板、应用菜单、Dock/状态栏权限菜单增加英文资源；Android 状态与通知改用 `values/values-en` 资源。
- 公证流水线：新增 GitHub Actions `Notarized Release`，导入 Developer ID、hardened runtime 签名、notarytool 提交、staple 和 Gatekeeper 校验。
- 发布工程化：新增 `make release-check` 校验 arm64、签名和 DMG；新增 `make notarize` 入口。
- 真机视频/触摸/旋转 E2E：新增 `make test-device-video`，以固定 token 启动核心应用，验证平板 Video 日志、解码统计、触摸注入到虚拟屏，以及强制横屏/恢复后的原地方向切换。
- 权限故障测试：新增 `TABLETDISPLAY_FORCE_SCREEN_RECORDING_DENIED` 注入和 `make test-permission`，验证失败后控制面板保留。
- 真机 smoke test：新增 `make test-device`，验证 APK 安装、Activity 启动、前台服务和通知。
- UI 测试：新增 `make test-ui`/`--snapshot-ui` 控制面板快照 smoke test，并接入 CI。
- 可恢复启动：屏幕录制、采集或端口占用失败时保留控制面板，不再直接退出；用户修复权限/端口后可重新连接。
- 方向回执：`/orientation` 等待显示/采集切换结果，失败返回 409；Android `OrientationReporter` 自动重试。
- 网络恢复：后台每 5 秒检查 Mac 路由变化与 mDNS 平板地址，自动用新地址重启连接。
- macOS 应用菜单：增加关于、打开控制面板、服务、隐藏/显示、退出等标准菜单项。
- HiDPI：方向切换时保留 pixel/logical 双尺寸，避免 2560×1600 旋转后丢失 2x。
- 测试：新增 DisplayGeometry 几何测试和方向失败 409 回执测试。
- 平台范围：明确仅支持 Apple Silicon（arm64）；构建、安装和 CI 都会校验产物架构。
- Dock 集成：应用改为常规 `Foreground` 应用并保留菜单栏状态项；桌面启动器改用 LaunchServices 启动核心 bundle，Dock 显示 AppIcon，点击图标可重新打开控制面板。
- 移除平板音频：取消按屏幕拆分/平板播放功能，声音只从 Mac 默认输出；删除 UDP PCM、Core Audio tap 和 Android AudioTrack 链路。
- 重启/重连修复：不再在读取分辨率失败时过早重启 ADB server；重启改用 LaunchServices 并等待旧进程退出；ADB shell 持续未就绪时自动重启 server 并重连；重启丢失命令行参数时回退已保存的分辨率/帧率设置。
- 自动横竖屏：Android 在方向变化时通过 `/orientation` 上报，Mac 原地创建匹配方向的虚拟屏并替换采集/编码器；HTTP/UDP 视频用格式变更继续，应用、ADB 和触摸不重启。Android 接收端改为 `fullSensor`。
- 显示排列：虚拟屏每秒校验，始终保持在主屏右侧，系统重排后自动纠正。
- 触摸开关：控制面板新增“允许平板触摸”，关闭后 Mac 立即忽略 `/input`，拖动中关闭会补发 `up`；设置持久化。

## 0.2.0 — 2026-10-18

- 无线启动：自动优先无线 ADB、USB 一键切换到无线、记住地址。
- 视频呈现：Choreographer/vsync 节流，静止和动态画面稳定在约 58–60fps。
- 交互：平板锁定横屏，触摸按视频实际显示区域映射（支持黑边）。
- 稳定性：发送超时、TCP keepalive、平板断线重连、采集自动重启。
- 安全：每次运行生成一次性 token，`/video`、`/input` 需要 Bearer 鉴权。
- 桌面体验：菜单栏状态项、自定义图标、桌面启动器和单实例保护。
- 打包：版本化 Info.plist、release keystore 支持、DMG/notarize 脚本。
- `make apk` 单独构建平板接收端，`make install-tablet` 直接 `adb install -r` 到已连接平板。
- 分辨率：默认读取 `wm size` 的 Physical size；桌面启动器默认 1470×956（13 寸 MacBook UI 尺寸）。

## 0.1.0 — 2026-10-17

- 初始版本：CGVirtualDisplay + ScreenCaptureKit + VideoToolbox H.264，
  平板 MediaCodec 解码、单点触摸回传、USB/无线两种连接方式。
