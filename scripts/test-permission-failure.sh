#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
binary="$root/build/TabletDisplay.app/Contents/MacOS/TabletDisplay"
logfile="$HOME/Library/Logs/TabletDisplay.log"

if [[ ! -x "$binary" ]]; then
  print -u2 "缺少 $binary，请先运行 make app"
  exit 1
fi
if /usr/bin/pgrep -x TabletDisplay >/dev/null; then
  print -u2 "测试前请先退出正在运行的 Tablet Display。"
  exit 1
fi

rm -f /tmp/tabletdisplay-permission-test.log
marker="$(date '+%Y-%m-%d %H:%M:%S')"
TABLETDISPLAY_FORCE_SCREEN_RECORDING_DENIED=1 \
  "$binary" >/tmp/tabletdisplay-permission-test.log 2>&1 &
pid=$!
cleanup() {
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 2
kill -0 "$pid" || {
  print -u2 "权限失败后应用不应退出"
  exit 1
}
sleep 1
grep -q "测试注入：屏幕录制权限被拒绝" "$logfile" || {
  print -u2 "没有记录注入的权限错误"
  exit 1
}
grep -q "启动错误" "$logfile" || {
  print -u2 "没有记录可恢复启动失败"
  exit 1
}
print "权限失败 smoke test 通过：进程保持运行，控制面板保留"
