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

if [[ -d "/Applications/Tablet Display.app" ]]; then
  print -u2 "警告：/Applications 下还有旧副本，Finder 可能启动它而不是新副本，表现为双击没反应；建议移到废纸篓。"
fi
if [[ -x "$root/scripts/make-launcher.sh" ]]; then
  "$root/scripts/make-launcher.sh" || true
fi

print "已安装：$dest"
print "首次运行请在“屏幕录制”主列表中添加并勾选 ~/Applications/Tablet Display.app（不是桌面上的 Tablet Display 启动器）。"
print "重新构建/重新安装后，macOS 可能要求重新授权屏幕录制。"
if pgrep -f "Tablet Display.app/Contents/MacOS/TabletDisplay" >/dev/null; then
  print "当前已有副屏实例在运行；先退出它，再双击新图标。"
else
  open "$dest"
fi
