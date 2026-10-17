# Tablet Display 开发记录

## 2026-10-18 加固：触摸、超时、签名、CI

- **触摸手势**：`MainActivity` 增加 `pointerDown` 状态；`down` 只在视频区域内被接受；`drag` 在黑边内保持最后有效坐标；`up/cancel` 无论是否滑出视频区域都会发送。服务端 `/input` 连接断开时，如果仍处于按下/拖动状态，会自动补发一次 `up`，覆盖平板切后台、断网等路径。
- **严格参数**：`Options`/`CLIError` 移到 `Sources/TabletDisplay/Options.swift`；`--width/--height/--port/--duration/--fps/--bitrate` 非法或越界直接抛出具体错误，`--direct-host` 必须是 IPv4，`--no-adb` 与 `--direct-host` 互斥。
- **HTTP 读超时**：请求头和请求体共用一个 10 秒 deadline，慢速/空连接会被关闭；请求读取完成后清除 `SO_RCVTIMEO`，避免影响长连接 `/input`。`HTTPServer` 新增 `boundPort` 和可注入的 `pointerHandler`，便于本机 socket 测试。
- **稳定签名**：新增 `scripts/create-signing-identity.sh`（`make signing`），生成并信任 `Tablet Display Local` 本地代码签名身份，材料放在 `~/Library/Application Support/TabletDisplay/signing`；`build-app.sh` 自动检测并使用，找不到时回退 ad-hoc 并打印提示。首次切换后仍需在 TCC 中重新添加一次核心应用。
- **权限引导**：菜单栏新增“权限设置”（屏幕录制/辅助功能/本地网络）和“打开日志”；屏幕录制缺失时弹窗可直接打开对应系统设置，辅助功能缺失时提示触摸暂不可用。
- **覆盖安装**：`install-app.sh` 现在覆盖 `~/Applications/Tablet Display.app` 并校验签名；`make-launcher.sh` 会删除旧桌面启动器后重新生成，校验可执行文件和签名，失败时不再被 `|| true` 静默吞掉。
- **Android 图标**：`Android/res` 新增矢量自适应图标（渐变背景 + 平板/窗口/光标/Wi-Fi 前景）；`build-android.sh` 先用 `aapt2 compile` 编译资源，再用 `-R` 链接进 APK。
- **控制面板**：新增 `ControlPanel.swift`（SwiftUI + `NSHostingController`），启动时显示；展示虚拟屏/传输/平板/视频服务状态。设置包括分辨率预设、帧率、码率、启动时显示、关闭窗口时退出；码率即时调用 `H264Encoder.updateBitrate`，其余写入 UserDefaults 并通过“保存并重启”应用到新进程。`make-launcher.sh` 生成的启动器会读取同一组 UserDefaults，因此下次双击也会沿用设置。关闭窗口默认仍驻留菜单栏，可从菜单重新打开。网络区域显示本机 IP/平板地址，支持手动输入平板新 IP 后连接并重启；启动时 ADB 或分辨率失败会保留控制面板，不再直接退出。
- **测试**：`make test-core` 现在包含本机 socket 集成测试：`/video` 帧格式与 401、`/input` 9 字节包解析、断连自动 `up`、重连从最新关键帧开始、空连接请求超时。`make test-android` 用纯 Java 测 `VideoProtocol` 和 `ReconnectPolicy`。新增 GitHub Actions 两个 job。
- **验证结果**：`make test` 通过；`./scripts/build-android.sh` 成功生成 APK；`swift build --disable-sandbox -c release` 成功。稳定签名 `Tablet Display Local` 已创建并信任；实测重建 + `make install` 覆盖安装后，屏幕录制/辅助功能授权保留，桌面启动器拉起 1470×956，平板稳定约 60fps。尚未做长时间稳定性/触摸逐点回归。
- **遗留**：Android `Surface` 销毁/重建仍未 join 旧视频线程，快速前后台切换仍有重复解码线程的竞态风险；`/health` 仍只判断“曾经有帧”；固定码率/无自适应未改。

## 目标与当前状态

- 目标：把已通过 ADB 连接的 Android 平板作为 Mac 无线扩展屏，60fps、低延迟、清晰；Dock 留在主屏。
- 当前代码版本：0.2.0，APK `versionCode=2`。
- 当前正在运行：从桌面启动器 exec `~/Applications/Tablet Display.app`（PID 3704），无线 ADB `<tablet-ip>:5555`，局域网直连 `<mac-ip>:9137`，虚拟屏 1470×956（UI 匹配 MacBook）在位，平板接收端约 60fps。
- 平板：华为 WGR-W09，Android 12/API 31，2560×1600/60Hz，Wi-Fi `<tablet-ip>:5555`；Mac `<mac-ip>`，macOS 27.0.1，Apple M5。
- 主屏逻辑尺寸 1470×956（2x）；桌面启动器创建 1470×956 虚拟屏（UI 匹配），核心应用直接启动仍默认 2560×1600。

## 00:04 核心应用也换图标

- 给 `~/Applications/Tablet Display.app` 增加 `AppIcon.icns` 和 `CFBundleIconFile`，重新 ad-hoc 签名；`build-app.sh` 已同步，后续构建默认带图标。
- 重新签名再次清空 TCC；屏幕录制与辅助功能重新绑定核心应用后已验证：连续启动无弹窗，1470×956、60fps。
- 当前运行：PID 2510，启动器 exec 核心应用（1470×956）。

## 00:45 增加平板端独立构建/安装

- `make apk` 只构建 `build/TabletDisplay.apk`。
- `make install-tablet` 对已连接设备执行 `adb install -r`，不替换 Mac App，不触发 TCC 重新授权。
- Mac App 启动时仍会自动推送内置 APK；两个入口共用同一个 Android 调试签名 key。

## 00:40 清理目录与签名 key 外置

- Android 调试签名 key 从 `build/android/debug.keystore` 移到 `~/Library/Application Support/TabletDisplay/debug.keystore`，并用它重新构建 APK，确认证书 SHA-256 仍是 `f283a66e…`（与平板已安装版一致）。
- `build/`、`dist/`、`.build/` 全部清理；DMG 备份到 `~/Library/Application Support/TabletDisplay/Tablet Display-0.2.0.dmg`。
- 项目只保留源码、资源、脚本、文档、Makefile；`make app` 会按需重建。

## 00:20 已安装版本与最新构建同步

- 停掉旧实例，备份旧安装到 `build/TabletDisplay-installed-00-02.app`，用 `build/TabletDisplay.app` 替换 `~/Applications/Tablet Display.app`。
- 安装后的可执行文件 SHA-256 与 `build/TabletDisplay.app` 完全一致（`b7d23d8f…`），版本 0.2.0、图标一致。
- 替换后 TCC 再次失效；重新绑定屏幕录制和辅助功能到核心应用后，启动无弹窗。
- 当前运行：PID 3704，启动器传 1470×956，平板约 60fps；`dist/Tablet Display-0.2.0.dmg` 与当前构建同源。
- 旧安装备份保留在 `build/` 用于回滚，可随时删除。

## 00:15 项目结构整理

- 根目录只保留 README/LICENSE/CHANGELOG/Makefile/Package.swift/THIRD_PARTY 和 `Sources/Android/Tests/Resources/scripts/docs`。
- `run.sh`/`run-wireless.sh` 移入 `scripts/`；`DEVELOPMENT_NOTES.md` 移入 `docs/`；图标和 Info.plist 移入 `Resources/`；图标生成脚本改为 `scripts/generate-icon.py`，新增 `scripts/build-icon.sh`。
- 新增 `Makefile`：`make app/test/run/wireless/icon/dmg/release/install/clean`；`build/` 是开发产物，`dist/` 是 DMG 发布产物。
- `scripts/build-app.sh` 现在从 `Resources/Info.plist` 和 `Resources/AppIcon.icns` 组装 app，不再在脚本里内嵌 Info.plist。
- 桌面启动器和 `~/Applications` 已安装应用不受影响；TCC 未改动。

## 23:59 UI 尺寸匹配 13 寸 MacBook

- 目标：平板 2560×1600 1x 时文字/UI 太小；希望和 13 寸 MacBook（主屏逻辑 1470×956）一致。
- 实测 macOS 27 的 `CGVirtualDisplay`：`settings.hiDPI=1/2`、mode 1280/2560、maxPixels 2560/5120 都不产生 2x 模式，所有模式 pixel=logical，因此无法做真正的 HiDPI 虚拟屏。
- 方案：桌面启动器直接 exec 核心应用并传 `--width 1470 --height 956 --no-hidpi`；平板把 1470×956 放大到 2560×1600，UI 尺寸与 MacBook 一致，文字略软。启动器已加 `pgrep` 单实例检查。
- 关键发现：macOS 27 上 `open --args ...` 不会把参数传给应用（用 `--help` 验证过）；launcher 改为 `exec "$core/Contents/MacOS/TabletDisplay" --width ...` 后参数生效，且屏幕录制 TCC 仍按核心应用生效。
- 当前运行：PID 2168，虚拟屏 1470×956，平板 60fps；无辅助功能弹窗。
- 核心应用直接启动仍默认 2560×1600 原生；桌面启动器是 UI 匹配入口。要用原生清晰画面，把 launcher 参数改成 `--width 2560 --height 1600`。

## 23:45 修复每次启动弹辅助功能授权

- 弹窗是 macOS 辅助功能（触摸回注）的 TCC 提示，不是屏幕录制。列表里 Tablet Display 开关虽为 ON，但绑定的是旧构建；替换 ad-hoc 构建后 `AXIsProcessTrusted()` 仍为 false，所以每次启动 `AXIsProcessTrustedWithOptions(prompt: true)` 都弹。
- 处理：`tccutil reset Accessibility dev.local.tabletdisplay`（及 launcher），删除旧条目；重新用 “+” 添加 **`~/Applications/Tablet Display.app`（核心应用）** 并打开，不要添加桌面启动器。
- 验证：连续两次启动均无弹窗；PID 1386，虚拟屏 2560×1600，平板 60fps。
- 以后每次替换 ad-hoc 构建，屏幕录制与辅助功能都可能需要按同样方式重新绑定核心应用。

## 23:37 默认输出改为平板硬件分辨率

- `ADB.parseScreenSize` 现在优先读 `wm size` 的 **Physical size**（2560×1600），其次 `dumpsys display` 的 `mBaseDisplayInfo real`，只有两者都没有时才用 `Override size`。这台平板曾出现 `Override size: 1600x2560`，旧逻辑在 DisplayInfo 失败时会误用它。
- ADB 模式下如果检测不到硬件分辨率，主程序直接报错要求 `--width/--height`，不再静默回退 1920×1200；`--no-adb` 调试路径仍可用 1920×1200。
- 创建虚拟屏后会读取 `CGDisplayCopyDisplayMode` 记录实际模式；当前日志确认“平板硬件分辨率：2560x1600 / 实际显示模式：2560x1600 / 虚拟显示器 2560x1600”。
- 注意：替换 ad-hoc 构建会让屏幕录制 TCC 失效。重新授权时必须把 **`~/Applications/Tablet Display.app`（核心应用）** 加进主“屏幕录制”列表，不能加桌面启动器；启动器已改名为 “Tablet Display 启动器”，避免选错。
- 当前运行：核心应用 PID 2662，虚拟屏 2560×1600，平板约 60fps。

## 23:28 自定义图标

- 图标源：`Resources/AppIcon-1024.png` / `scripts/generate-icon.py`；`Resources/AppIcon.icns` 是构建产物。设计是深蓝圆角底 + 平板双窗口 + 光标 + 无线信号弧。
- `scripts/make-launcher.sh` 生成 `build/TabletDisplayLauncher.app`（独立 bundle id `dev.local.tabletdisplay.launcher`，LSUIElement），以 `exec` 方式启动核心应用并传入 `--width 1470 --height 956 --no-hidpi`；已安装到 `~/Desktop/Tablet Display 启动器.app`，避免和核心应用同名。
- 启动器不改动已授权的核心应用，因此不需要重新授权屏幕录制；桌面图标可以拖到 Dock。
- 核心应用 `~/Applications/Tablet Display.app` 也已加入同一图标（`Contents/Resources/AppIcon.icns` + `CFBundleIconFile=AppIcon`），并已重新 ad-hoc 签名；`build-app.sh` 以后会默认带图标。改图标会重置 TCC，屏幕录制和辅助功能已重新授权。
- 另：如果启动时发现虚拟屏是 1920×1200 而不是 2560×1600，通常是旧实例/残留虚拟屏未清；完全退出应用再通过桌面图标启动一次即可恢复，已验证。

## 23:22 修复：双击图标没反应

- 根因：`/Applications/Tablet Display.app` 有一份 18:22 的旧副本，和 `~/Applications/Tablet Display.app` 同 bundle id。LaunchServices 注册了三份（还有 DMG 卷路径），Finder/启动台双击时优先启动了旧副本；旧副本没有屏幕录制授权，也没有自动无线逻辑，所以看起来“没反应”。
- 处理：旧副本已移到废纸篓 `~/.Trash/Tablet Display (old 18-22).app`；注销了 `/Applications` 与 DMG 路径的 LS 记录，只保留 `~/Applications/Tablet Display.app`；在桌面创建了指向正确副本的快捷方式 `~/Desktop/Tablet Display.app`。
- 验证：通过桌面快捷方式启动成功，PID 1764，虚拟屏 2560×1600，平板 60fps。
- 后续：`scripts/install-app.sh` 会提示 `/Applications` 下的旧副本，并自动创建桌面快捷方式。

## 23:10 更新：免终端、免 ADB 线启动

- **双击应用启动**：`./scripts/install-app.sh` 安装到 `~/Applications/Tablet Display.app`；双击后自动寻找无线 ADB、自动选择局域网直连，不需要终端。
- **自动无线**：`ADB.connectPreferred` 优先无线传输；只有 USB 时自动执行 `adb tcpip 5555` + `adb connect`，并记住上次 endpoint；无设备时尝试上次地址。地址存 `UserDefaults` 的 `lastWirelessEndpoint`。
- **Finder 环境**：`ADB` 不再依赖 PATH，依次查找 `ADB` 环境变量、PATH、`~/Library/Android/sdk/platform-tools/adb`、`/opt/homebrew/bin/adb`、`/usr/local/bin/adb`。
- **自动直连**：只有“无 `--serial` 的 Dock 启动”才从无线 serial 推导平板 IP，并用 `getifaddrs` 选同网段 Mac IPv4 作为 `directHost`；显式 `--serial` 保持原有 ADB 隧道语义。
- **日志**：`~/Library/Logs/TabletDisplay.log`，记录 adb 设备、传输方式、虚拟屏、监听、错误。
- **权限**：首次启动请求本地网络、屏幕录制、辅助功能。macOS 27 的屏幕录制列表里，ad-hoc 应用可能先出现在底部 “System Audio Recording Only”；必须在主 “Screen & System Audio Recording” 列表用 **+** 添加应用并打开开关，否则 `CGPreflightScreenCaptureAccess()` 一直为 false。
- **重建注意**：ad-hoc 签名随构建变化，重新构建/重新安装后 macOS 可能要求重新授权屏幕录制；给最终安装副本授权后不要再重建。
- **放弃的路径**：`~/Applications/启动副屏.command`/Terminal 启动仍因屏幕录制 TCC 失败（Terminal 的授权没有传递到 app），已删除；不要再用 `.command` 作为主启动方式。
- **当前运行实例**：`~/Applications/Tablet Display.app`，日志确认 `直连 <mac-ip>`、虚拟屏 2560×1600、采集启动、平板接收端打开。

## 本轮（17:40–18:10）完成并验证的内容

1. **文档勘误**：`docs/DEVELOPMENT_NOTES.md` 里“静止时编码只有 3–4fps”在当前构建上无法复现。当前静止画面主机稳定 60fps，平板也稳定 60fps 输出；此前很可能是跑到了旧二进制/旧进程。
2. **`scripts/run.sh` 自动重建**：改为用 `build/.build-stamp` 比较源码时间。源码或构建脚本比 stamp 新时自动执行 `scripts/build-app.sh`；连续运行两次第二次不再重建。`build-app.sh` 成功后会 `touch build/.build-stamp`。
3. **呈现帧率**：Android 端用 Choreographer 的 vsync 时基给 `releaseOutputBuffer(index, targetNs)` 安排呈现时间，并 `Surface.setFrameRate(fps, FIXED_SOURCE)`；不再每个输出缓冲立即 `releaseOutputBuffer(index, true)`。实测：
   - 静止：约 58–60fps（127 帧样本，中位 16.52ms，绝大多数间隔 <20ms）。
   - 动态图案：约 58–59fps（122/126 间隔 <20ms）。
   - 优化前为约 53fps（126 帧/2.38s，10% 帧 33ms）。
4. **横屏与触摸映射**：Manifest 锁定 `sensorLandscape`；`MainActivity` 按视频实际显示区域（SCALE_TO_FIT 后的矩形，含黑边）归一化触摸，黑边触摸忽略。实测：
   - 2560×1600 全屏：中心触摸 (1280,800) → Mac 光标 (2750,800) = 虚拟屏 origin 1470 + 1280；四角/右下均 1:1。
   - 1920×1080（上下黑边）：中心 → (2430,540)；y=20 的黑边触摸被忽略；y=160 → Mac y=60，符合 `(160-80)/1440`。
5. **鉴权**：每次运行生成随机 token，通过 `am start --es token` 传给平板；`/video`、`/input`、`/pointer` 校验 `Authorization: Bearer`。实测无 token/错 token 返回 401，正确 token 返回 200。`/health` 保持无鉴权。
6. **心跳/超时/重连**：服务端客户端 socket 设 5s `SO_SNDTIMEO` + keepalive，`stop()` 会 shutdown 所有客户端；平板视频 socket 5s `SoTimeout`，超时/断开自动重连；采集 `didStopWithError` 后自动重启（1s 后首次，失败每 2s 重试）。
7. **菜单栏**：`StatusBar.swift`，NSApplicationDelegate 启动后创建状态项；菜单可打开 `/health`、退出。`--duration` 结束时自动退出。
8. **Ctrl-C/信号处理**：macOS 27 上 `DispatchSourceSignal` 在 `SIG_IGN` 下不会触发；改为 no-op handler + 全局队列后，实测 `kill -INT` 能收到信号、退出并移除虚拟屏、释放 9137。注意：用 shell 的 `&` 包住 `cd ... && ./run.sh` 时 `$!` 是子 shell，不是 app，测试信号要直接对 app PID 发送。
9. **打包**：APK `versionCode=2`/`versionName=0.2.0`；`build-android.sh` 支持 `TABLETDISPLAY_KEYSTORE` 等环境变量做 release 签名；新增 `scripts/create-release-key.sh`、`scripts/make-dmg.sh`、`scripts/notarize.sh`。
10. **README** 已更新为当前行为（含 60fps 保活、token、菜单栏、实测数据、发布步骤）。

## 关键实测（本轮）

主机日志：

```
编码统计：输入 60.0 fps，输出 60.0 fps，丢帧 0.0 fps
视频与触摸通过局域网直连：<mac-ip>:9137（令牌鉴权）
已在 Android 设备 <tablet-ip>:5555 打开原生扩展屏。
```

平板日志：

```
video stats recv=60.0fps output=60.0fps Mbps=13.0 inputWait=0.6ms/frame outputAge=22.4ms maxAge=71.8ms maxBuffered=22KB
video stats recv=60.1fps output=59.9fps Mbps=14.2 inputWait=0.6ms/frame outputAge=23.7ms maxAge=84.4ms maxBuffered=94KB
```

SurfaceFlinger 采样命令（BLAST SurfaceView 层）：

```sh
adb -s <tablet-ip>:5555 shell "dumpsys SurfaceFlinger --latency 'SurfaceView[dev.local.tabletdisplay/dev.local.tabletdisplay.MainActivity](BLAST)#...'"
```

注意：`--latency` 前几行常为 0，且环形缓冲约 2 秒；计算时用最后 100 个时间戳的跨度，不要直接用整段首尾（偶发异常时间戳会把结果算成 0fps）。

## 代码位置

- `Sources/TabletDisplay/main.swift`：启动、菜单栏接线、token 生成、虚拟屏创建。
- `Sources/TabletDisplay/StatusBar.swift`：菜单栏。
- `Sources/TabletDisplay/VideoCapture.swift`：帧队列、硬编、ScreenCaptureKit、保活 timer、自动重启、`latestImage` 加锁。
- `Sources/TabletDisplay/HTTPServer.swift`：token、IP 白名单、发送超时、客户端跟踪、`/video` 新增 fps 头。
- `Sources/TabletDisplay/ADB.swift`：安装/启动（带 token）。
- `Android/src/dev/local/tabletdisplay/MainActivity.java`：硬解、vsync  pacing、横屏、触摸映射、超时重连、token。
- `scripts/build-app.sh`：构建 + `build/.build-stamp`。
- `scripts/build-android.sh`：debug/release 签名。
- `scripts/create-release-key.sh`、`scripts/make-dmg.sh`、`scripts/notarize.sh`。

## 未验证/已知限制

- **DMG 已验证**：`dist/Tablet Display-0.2.0.dmg` 已生成并挂载检查，包含 `Tablet Display.app` 和 `/Applications` 链接。macOS 27 会给出 `hdiutil create` 弃用警告，但可用；沙箱下需要完整磁盘访问。
- **公证未执行**：需要 Developer ID 证书和 notarytool 凭据，本项目没有。
- **release keystore 未实际生成**：只做了语法检查；`create-release-key.sh` 会生成 4096 位 RSA key。
- **发送超时/采集自动重启未做故障注入**：代码路径已在，但没有模拟拔网/SCStream 中断。
- **动态画面只测了测试图案**（`/tmp/tablet-pattern`，未入库）；未测真实桌面窗口/视频播放。
- 仍不支持声音、键盘、多点触控、滚轮/右键；单平板；无自适应码率。
- 静止时仍按 60fps 编码，流量约 4–15Mbps；这是为了绕开硬解无输入延迟出帧的权衡。
- `CGVirtualDisplay` 是私有 API，系统更新可能失效。

## 继续时的建议

1. 普通终端跑一次 `./scripts/make-dmg.sh`，确认 hdiutil 可创建；再按 README 做签名/公证（如有证书）。
2. 做 30 分钟稳定性测试：Wi-Fi 断开重连、Mac 睡眠唤醒、平板旋转/锁屏、SCStream 中断。
3. 若追求更低延迟：评估 `releaseOutputBuffer` 目标时间再提前 2–3ms 与码率/分辨率自适应；当前呈现已约 58–60fps。
4. 如需更强安全：把 token 从 intent 移到 ADB `adb shell` 环境变量/本地文件，或加 TLS。
5. `git add -A && git commit`；目前仓库仍没有任何提交，所有文件 untracked。

## 常用命令

```sh
./scripts/build-app.sh          # 构建 Mac + APK
./scripts/test-core.sh          # 核心测试
./scripts/install-app.sh        # 安装到 ~/Applications（之后双击启动）
./scripts/run-wireless.sh       # 终端方式启动（备用）
./scripts/run.sh --no-adb --duration 10 # 只测主机采集/HTTP
adb -s <tablet-ip>:5555 logcat -d -s TabletDisplay:W | tail
```
