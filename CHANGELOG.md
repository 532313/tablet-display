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
