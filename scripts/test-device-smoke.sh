#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
apk="$root/build/TabletDisplay.apk"
adb_bin="${ADB:-$(command -v adb || true)}"
if [[ -z "$adb_bin" ]]; then
  adb_bin="$HOME/Library/Android/sdk/platform-tools/adb"
fi
if [[ ! -x "$adb_bin" ]]; then
  print -u2 "找不到 adb。请安装 Android Platform Tools，或设置 ADB。"
  exit 1
fi
if [[ ! -f "$apk" ]]; then
  print -u2 "缺少 $apk，请先运行 make apk。"
  exit 1
fi

serial="${1:-$("$adb_bin" devices | awk 'NR > 1 && $2 == "device" {print $1; exit}')}"
if [[ -z "$serial" ]]; then
  print -u2 "没有在线的 Android 设备。请先连接并允许 USB 调试。"
  exit 1
fi
print "设备：$serial"

cleanup() {
  "$adb_bin" -s "$serial" shell am force-stop dev.local.tabletdisplay >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$adb_bin" -s "$serial" install -r "$apk" >/dev/null
"$adb_bin" -s "$serial" shell am force-stop dev.local.tabletdisplay >/dev/null 2>&1 || true
"$adb_bin" -s "$serial" shell am start -S -n dev.local.tabletdisplay/.MainActivity \
  --es host 127.0.0.1 --ei port 9137 --es token smoke-test --ei udpPort 9138 >/dev/null
sleep 3

pid="$("$adb_bin" -s "$serial" shell pidof dev.local.tabletdisplay 2>/dev/null || true)"
[[ -n "$pid" ]] || { print -u2 "Activity 启动后进程不存在"; exit 1; }

services=""
for _ in {1..5}; do
  services="$("$adb_bin" -s "$serial" shell dumpsys activity services dev.local.tabletdisplay 2>/dev/null || true)"
  if print -r -- "$services" | grep -q "isForeground=true" &&
     print -r -- "$services" | grep -q "foregroundNoti=Notification(channel=tablet-display"; then
    break
  fi
  sleep 1
done

print -r -- "$services" | grep -q "TabletDisplayService" || {
  print -u2 "前台服务没有启动"; exit 1
}
print -r -- "$services" | grep -q "isForeground=true" || {
  print -u2 "前台服务没有进入 foreground"; exit 1
}
print -r -- "$services" | grep -q "foregroundNoti=Notification(channel=tablet-display" || {
  print -u2 "前台通知/通知渠道没有附着到服务"; exit 1
}

print "真机 smoke test 通过：PID $pid，前台服务与通知正常"
