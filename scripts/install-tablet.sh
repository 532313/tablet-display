#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
fi

adb="${ADB:-}"
if [[ -z "$adb" ]]; then
  for candidate in "$(command -v adb 2>/dev/null || true)" \
                   "$HOME/Library/Android/sdk/platform-tools/adb" \
                   /opt/homebrew/bin/adb; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      adb="$candidate"
      break
    fi
  done
fi
if [[ ! -x "$adb" ]]; then
  print -u2 "找不到 adb；请安装 Android Platform Tools 或设置 ADB。"
  exit 1
fi

apk="$root/build/TabletDisplay.apk"
if [[ ! -f "$apk" ]]; then
  print -u2 "缺少 $apk，请先运行 make apk。"
  exit 1
fi

if (( dry_run )); then
  print "adb: $adb"
  print "apk: $apk"
  print "command: $adb <serial> install -r $apk"
  exit 0
fi

"$adb" start-server >/dev/null 2>&1 || true
serial="${ANDROID_SERIAL:-$("$adb" devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
if [[ -z "$serial" ]]; then
  print -u2 "没有已连接的平板。请先插 USB，或运行 ./scripts/connect-wireless.sh。"
  print -u2 "当前设备："
  "$adb" devices
  exit 1
fi

"$adb" -s "$serial" install -r "$apk"
print "已安装平板接收端：$serial"
print "启动：make wireless（或让 Mac App 自动打开）"
