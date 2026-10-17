# Changelog

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
