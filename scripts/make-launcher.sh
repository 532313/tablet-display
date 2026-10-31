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
domain="dev.local.tabletdisplay"
if [[ ! -d "$core" ]]; then
  /usr/bin/osascript -e 'display alert "找不到 Tablet Display" message "请先在项目中运行 scripts/install-app.sh 安装核心应用。"'
  exit 1
fi
if /usr/bin/pgrep -f "$core/Contents/MacOS/TabletDisplay" >/dev/null; then
  /usr/bin/open -a "$core"
  exit 0
fi
read_int() {
  local key="$1" fallback="$2" min="$3" max="$4"
  local value
  value=$(/usr/bin/defaults read "$domain" "$key" 2>/dev/null || true)
  if [[ "$value" == <-> ]] && (( value >= min && value <= max )); then
    print -r -- "$value"
  else
    print -r -- "$fallback"
  fi
}
width=$(read_int TabletDisplayWidth 1470 640 4096)
height=$(read_int TabletDisplayHeight 956 480 4096)
fps=$(read_int TabletDisplayFPS 60 15 60)
bitrate=$(read_int TabletDisplayBitrateMbps 20 5 50)
exec /usr/bin/open -n -a "$core" --args \
  --width "$width" --height "$height" --fps "$fps" --bitrate "$bitrate" --no-hidpi
SH
chmod +x "$launcher/Contents/MacOS/TabletDisplayLauncher"
codesign --force --sign - "$launcher" >/dev/null 2>&1 || true

dest="$HOME/Desktop/Tablet Display 启动器.app"
# The launcher is a generated artifact; replace an older copy so its script,
# icon and signing identity stay in sync with the current build.
if [[ -e "$dest" || -L "$dest" ]]; then
  rm -rf "$dest"
fi
ditto "$launcher" "$dest"
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
touch "$dest"

if [[ ! -x "$dest/Contents/MacOS/TabletDisplayLauncher" ]]; then
  print -u2 "启动器生成失败：$dest"
  exit 1
fi
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$dest"
print "已更新桌面启动器：$dest"
print "可以把它拖到 Dock；双击即可启动副屏。"
