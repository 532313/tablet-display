#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
dest="$HOME/Applications/Tablet Display.app"

if [[ "${1:-}" == "--build" || ! -d "$root/build/TabletDisplay.app" ]]; then
  "$root/scripts/build-app.sh"
fi
mkdir -p "$HOME/Applications"
rm -rf "$dest"
ditto "$root/build/TabletDisplay.app" "$dest"
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
codesign --verify --deep --strict "$dest"
archs="$(lipo -archs "$dest/Contents/MacOS/TabletDisplay" 2>/dev/null || true)"
if [[ "$archs" != "arm64" ]]; then
  print -u2 "安装包架构异常：期望 arm64，实际 '$archs'。"
  exit 1
fi

if [[ -d "/Applications/Tablet Display.app" ]]; then
  print -u2 "警告：/Applications 下还有旧副本，Finder 可能启动它而不是新副本，表现为双击没反应；建议移到废纸篓。"
fi
if [[ -x "$root/scripts/make-launcher.sh" ]]; then
  "$root/scripts/make-launcher.sh"
fi

print "已安装：$dest"
print "首次运行请在“屏幕录制”主列表中添加并勾选 ~/Applications/Tablet Display.app（不是桌面上的 Tablet Display 启动器）。"
if codesign -dv --verbose=4 "$dest" 2>&1 | grep "Authority=" >/dev/null; then
  print "已安装稳定签名；重建后通常不需要重新授权。"
else
  print "当前使用 ad-hoc 签名；重建/重装后 macOS 可能要求重新授权。"
  print "建议运行 ./scripts/create-signing-identity.sh（或 make signing）一次。"
fi
if pgrep -f "Tablet Display.app/Contents/MacOS/TabletDisplay" >/dev/null; then
  print "当前已有副屏实例在运行；先退出它，再双击新图标。"
else
  open "$dest"
fi
