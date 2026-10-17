#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
launcher="$root/build/TabletDisplayLauncher.app"

rm -rf "$launcher"
mkdir -p "$launcher/Contents/MacOS" "$launcher/Contents/Resources"
cp "$root/Resources/AppIcon.icns" "$launcher/Contents/Resources/AppIcon.icns"

cat > "$launcher/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>TabletDisplayLauncher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>dev.local.tabletdisplay.launcher</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Tablet Display 启动器</string>
  <key>CFBundleDisplayName</key><string>Tablet Display 启动器</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

cat > "$launcher/Contents/MacOS/TabletDisplayLauncher" <<'SH'
#!/bin/zsh
core="$HOME/Applications/Tablet Display.app"
if [[ ! -d "$core" ]]; then
  /usr/bin/osascript -e 'display alert "找不到 Tablet Display" message "请先在项目中运行 scripts/install-app.sh 安装核心应用。"'
  exit 1
fi
if /usr/bin/pgrep -f "$core/Contents/MacOS/TabletDisplay" >/dev/null; then
  exit 0
fi
exec "$core/Contents/MacOS/TabletDisplay" --width 1470 --height 956 --no-hidpi
SH
chmod +x "$launcher/Contents/MacOS/TabletDisplayLauncher"
codesign --force --sign - "$launcher" >/dev/null 2>&1 || true

dest="$HOME/Desktop/Tablet Display 启动器.app"
if [[ -L "$dest" ]]; then rm -f "$dest"; fi
if [[ -e "$dest" ]]; then
  print -u2 "$dest 已存在，未覆盖。"
  exit 1
fi
ditto "$launcher" "$dest"
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
touch "$dest"
print "已生成桌面启动器：$dest"
print "可以把它拖到 Dock；双击即可启动副屏。"
