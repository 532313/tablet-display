<p align="center">
  <img src="Resources/AppIcon-1024.png" width="140" alt="Tablet Display 图标">
</p>

<h1 align="center">Tablet Display</h1>

<p align="center">把 Android 平板变成 Mac 的无线扩展屏。</p>

Tablet Display 在 Mac 上创建一块虚拟显示器，用 ScreenCaptureKit 采集、VideoToolbox 硬件编码 H.264，通过 Wi-Fi 传给平板；平板用 MediaCodec 硬解全屏显示，并把单点触摸回传成 Mac 鼠标操作。

当前版本 **0.2.0**，测试设备为华为 WGR-W09（Android 12，2560×1600，60Hz）。

## 功能

- 无线扩展屏：首次用 USB 切换无线 ADB，之后不需要数据线。
- 60fps：采集/编码/解码/呈现全链路约 58–60fps。
- 硬件编解码：VideoToolbox H.264 + MediaCodec 硬解。
- 单点触摸：按视频实际显示区域映射，支持黑边。
- 横屏锁定、断线重连、采集自动重启。
- token 鉴权 + 平板 IP 白名单。
- 菜单栏应用、自定义图标、桌面启动器。
- 版本化 `.app`、DMG 打包、notarize 脚本。

## 环境要求

- macOS 13 或更新版本（当前在 macOS 27 / Apple M5 验证）。
- Xcode Command Line Tools。
- Android SDK：API 34、Build Tools 36.0.0、Platform Tools。
- 平板开启 USB 调试；无线模式要求 Mac 与平板在同一局域网。
- 首次运行需要授予“屏幕录制”“辅助功能”“本地网络”。

## 安装

从 [dist](dist) 里的 DMG 安装，或自行构建：

```sh
make app        # 构建 Mac 应用和 Android APK
make dmg        # 生成 dist/Tablet Display-0.2.0.dmg
```

DMG 里把 **Tablet Display.app** 拖到“应用程序”。当前 DMG 使用 ad-hoc 签名，未公证；首次打开可能需要右键“打开”。

也可以直接安装到当前用户目录：

```sh
make install    # 安装到 ~/Applications，并生成桌面启动器
```

## 使用

### 第一次：USB 切换无线

1. 用 USB 线连接平板，打开 USB 调试。
2. 运行：

```sh
make wireless
```

脚本会读取平板 Wi-Fi 地址、执行 `adb tcpip 5555`、连接无线 ADB，并启动副屏。看到“已在 Android 设备 … 打开原生扩展屏”后即可拔线。

### 日常

- 双击 `~/Desktop/Tablet Display 启动器.app`，或从 `~/Applications` 打开 **Tablet Display**。
- 菜单栏出现 **Tablet Display** 图标，可打开状态页或退出。
- 终端启动：`./scripts/run-wireless.sh`；USB/ADB 隧道：`./scripts/run-wireless.sh --adb-tunnel`。

### 停止

菜单栏 → **退出**，或终端里 `Ctrl-C`。平板端会显示“连接中断，正在重试…”，按返回/home 退出即可。

### 分辨率与 UI 大小

- 核心应用默认读取 `wm size` 的 **Physical size**（当前 2560×1600）。
- 桌面启动器默认传 `--width 1470 --height 956`，让 UI 尺寸与 13 寸 MacBook 一致；平板放大显示，文字会略软。
- macOS 27 的 `CGVirtualDisplay` 实测不提供 2x/HiDPI 模式，无法同时做到原生像素和 Mac 尺寸 UI。
- 想要更清晰：把 `scripts/make-launcher.sh` 里的 `1470×956` 改成 `1920×1200` 或 `2560×1600`；也可以用 `--width/--height` 手动指定。

## 权限（重要）

macOS 的 ad-hoc 签名在每次重新构建后会变化，TCC 可能要求重新授权。

- **屏幕录制**：主“屏幕与系统音频录制”列表里添加并勾选 `~/Applications/Tablet Display.app`（核心应用）。
- **辅助功能**：同样添加核心应用；如果开关是开的但仍每次弹窗，删除旧条目再重新添加。
- **本地网络**：首次连接时允许。
- 不要把桌面上的 **Tablet Display 启动器** 加进这两个列表——它只负责启动核心应用，不参与采集。

## 参数

```sh
./scripts/run.sh --fps 60
./scripts/run.sh --bitrate 30
./scripts/run.sh --width 1920 --height 1200
./scripts/run.sh --serial 设备序列号
./scripts/run.sh --token 固定令牌
./scripts/run.sh --hidpi / --no-hidpi
./scripts/run.sh --no-adb --duration 10
./scripts/run-wireless.sh --adb-tunnel
```

| 参数 | 说明 |
| --- | --- |
| `--width` / `--height` | 像素分辨率，默认平板硬件分辨率 |
| `--fps` | 15–60，默认 60 |
| `--bitrate` | 5–50 Mbps，默认 20 |
| `--serial` | 多设备时指定平板 |
| `--direct-host` | 局域网直连的 Mac IP（脚本自动传入） |
| `--token` | 固定鉴权 token |
| `--hidpi` / `--no-hidpi` | 强制/禁用 2x 逻辑尺寸（当前虚拟屏驱动不提供 2x 模式） |
| `--adb-tunnel` | 改用 `adb reverse`，视频走 ADB |
| `--duration` | 运行指定秒数后退出（调试） |

## 开发

```sh
make app        # 构建 Mac app + APK
make test       # 核心测试
make run        # 本机运行构建产物
make icon       # 从 Resources/AppIcon-1024.png 重新生成 icns
make clean      # 删除编译缓存和构建产物（保留签名 keystore）
```

项目结构：

```text
.
├── Sources/            # macOS Swift 源码
│   ├── TabletDisplay/
│   └── VirtualDisplayBridge/
├── Android/            # 平板接收端
├── Tests/              # 核心测试
├── Resources/          # Info.plist、图标
├── scripts/            # 构建、运行、打包、安装
├── docs/               # 架构、协议、开发记录
├── build/              # 开发构建产物（忽略）
└── dist/               # 发布 DMG（忽略）
```

进一步阅读：

- [架构说明](docs/ARCHITECTURE.md)
- [传输协议](docs/PROTOCOL.md)
- [开发记录与排障](docs/DEVELOPMENT_NOTES.md)
- [第三方声明](THIRD_PARTY.md)

## 发布

```sh
make release    # 构建 app + dist/Tablet Display-0.2.0.dmg
```

正式签名/公证：

```sh
./scripts/create-release-key.sh      # Android release keystore
export TABLETDISPLAY_KEYSTORE=...
export TABLETDISPLAY_KEY_ALIAS=tabletdisplay
export TABLETDISPLAY_STORE_PASS=...

xcrun notarytool store-credentials TabletDisplay \
  --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
export TABLETDISPLAY_SIGN_IDENTITY='Developer ID Application: ...'
export TABLETDISPLAY_NOTARY_PROFILE=TabletDisplay
./scripts/notarize.sh
```

## 安全

- 视频/触摸是明文 HTTP + token，只建议在可信局域网使用。
- `adb tcpip 5555` 会让调试端口保持开启；不用时可执行 `adb usb`。
- token 通过 ADB intent 传递，本机 `adb`/`dumpsys` 可见，不是强隔离凭据。

## 限制

- 依赖 macOS 私有 `CGVirtualDisplay`，系统更新可能失效。
- 不支持声音、键盘、多点触控、滚轮/右键、剪贴板。
- 单平板；无自适应码率、无 HDR/色彩管理。
- 平板重启后无线 ADB 可能关闭，需要插一次 USB。

## 许可

项目代码使用 [MIT License](LICENSE)。`CGVirtualDisplay` 接口声明参考 DeskPad，见 [THIRD_PARTY.md](THIRD_PARTY.md)。
