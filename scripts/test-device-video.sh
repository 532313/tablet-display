#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
app="$HOME/Applications/Tablet Display.app"
log="$HOME/Library/Logs/TabletDisplay.log"
adb_bin="${ADB:-$(command -v adb || true)}"
if [[ -z "$adb_bin" ]]; then
  adb_bin="$HOME/Library/Android/sdk/platform-tools/adb"
fi
if [[ ! -x "$adb_bin" ]]; then
  print -u2 "找不到 adb。"
  exit 1
fi

# ADB can block forever when the server is restarting or the tablet dropped
# off Wi-Fi. Every call in this test is bounded.
timeout_bin="$(command -v timeout || true)"
adb_cmd() {
  if [[ -n "$timeout_bin" ]]; then
    timeout 15 "$adb_bin" "$@"
  else
    "$adb_bin" "$@"
  fi
}
if [[ ! -d "$app" ]]; then
  print -u2 "缺少 $app，请先 make install。"
  exit 1
fi

# Prefer the saved wireless endpoint. `adb devices` can wait indefinitely
# while the adb server is restarting, so never make it the first operation.
serial="$(defaults read dev.local.tabletdisplay lastWirelessEndpoint 2>/dev/null || true)"
if [[ -z "$serial" ]]; then
  adb_cmd start-server >/dev/null 2>&1 || true
  serial="$(adb_cmd devices | awk 'NR > 1 && $2 == "device" {print $1; exit}')"
fi
[[ -n "$serial" ]] || { print -u2 "没有在线 Android 设备。"; exit 1; }
tablet_ip="${serial%%:*}"
interface="$(route -n get "$tablet_ip" 2>/dev/null | awk '/interface:/{print $2; exit}')"
mac_ip="$(ipconfig getifaddr "$interface" 2>/dev/null || true)"
[[ -n "$mac_ip" ]] || { print -u2 "无法获取 Mac 局域网 IP。"; exit 1; }
touch_original="$(defaults read dev.local.tabletdisplay TabletDisplayTouchEnabled 2>/dev/null || true)"
[[ -n "$touch_original" ]] || touch_original=1
case "$touch_original" in
  0|false|FALSE|no|NO) touch_restore=false ;;
  *) touch_restore=true ;;
esac

restore() {
  /usr/bin/pgrep -x TabletDisplay >/dev/null && kill $(/usr/bin/pgrep -x TabletDisplay) 2>/dev/null || true
  for _ in {1..30}; do /usr/bin/pgrep -x TabletDisplay >/dev/null || break; sleep 0.2; done
  adb_cmd -s "${serial:-}" shell wm user-rotation free >/dev/null 2>&1 || true
  adb_cmd -s "${serial:-}" shell wm fixed-to-user-rotation default >/dev/null 2>&1 || true
  defaults write dev.local.tabletdisplay TabletDisplayTouchEnabled -bool "$touch_restore" 2>/dev/null || true
  open "$HOME/Desktop/Tablet Display 启动器.app" >/dev/null 2>&1 || true
}
trap restore EXIT

# Stop the normal instance and start a deterministic E2E instance.
defaults write dev.local.tabletdisplay TabletDisplayTouchEnabled -bool true
if /usr/bin/pgrep -x TabletDisplay >/dev/null; then
  kill $(/usr/bin/pgrep -x TabletDisplay) 2>/dev/null || true
fi
for _ in {1..30}; do /usr/bin/pgrep -x TabletDisplay >/dev/null || break; sleep 0.2; done
adb_cmd start-server >/dev/null 2>&1 || true
for _ in {1..5}; do
  adb_cmd connect "$serial" >/dev/null 2>&1 || true
  if [[ "$(adb_cmd -s "$serial" get-state 2>/dev/null || true)" == "device" ]]; then
    break
  fi
  sleep 1
done
[[ "$(adb_cmd -s "$serial" get-state 2>/dev/null || true)" == "device" ]] || {
  print -u2 "ADB 设备未就绪：$serial"
  exit 1
}
open -n -a "$app" --args --serial "$serial" --direct-host "$mac_ip" \
  --token e2e-token --width 956 --height 1470 --fps 60 --bitrate 20 --no-hidpi

ready=0
for _ in {1..60}; do
  if [[ "$(curl -sS --max-time 1 http://127.0.0.1:9137/health 2>/dev/null || true)" == "ready" ]]; then
    ready=1
    break
  fi
  sleep 0.5
done
[[ "$ready" == "1" ]] || { print -u2 "Mac /health 未进入 ready"; exit 1; }

video=""
for _ in {1..30}; do
  video="$(adb_cmd -s "$serial" logcat -d 2>/dev/null | grep -E 'TabletDisplay: Video (UDP )?[0-9]+x[0-9]+' | tail -1 || true)"
  [[ -n "$video" ]] && break
  sleep 0.5
done
[[ -n "$video" ]] || { print -u2 "平板没有收到视频格式"; exit 1; }
print "视频连接：$video"

# Wait for decoder stats, which proves the datapath is not just handshaking.
stats=""
for _ in {1..20}; do
  stats="$(adb_cmd -s "$serial" logcat -d 2>/dev/null | grep 'video stats recv=' | tail -1 || true)"
  [[ -n "$stats" ]] && break
  sleep 0.5
done
[[ -n "$stats" ]] || { print -u2 "没有收到解码统计"; exit 1; }
print "解码统计：$stats"

# Touch path: tap the center of the tablet and verify the injected cursor is
# inside the virtual display, not somewhere on the Mac desktop.
python3 "$root/scripts/display-bounds.py" > /tmp/tabletdisplay-bounds.json
virtual="$(python3 - <<'PY'
import json
with open('/tmp/tabletdisplay-bounds.json') as f:
    data = json.load(f)
for d in data['displays']:
    if not d['main'] and d['width'] > 100 and d['height'] > 100:
        print(f"{d['x']} {d['y']} {d['width']} {d['height']}")
        break
PY
)"
[[ -n "$virtual" ]] || { print -u2 "没有找到虚拟显示器"; exit 1; }
read -r vx vy vw vh <<< "$virtual"
inside="no"
for attempt in 1 2 3; do
  adb_cmd -s "$serial" shell input tap 800 1280 >/dev/null 2>&1 || true
  sleep 1
  python3 "$root/scripts/display-bounds.py" > /tmp/tabletdisplay-bounds.json
  inside="$(python3 - <<'PY'
import json
with open('/tmp/tabletdisplay-bounds.json') as f:
    data = json.load(f)
x, y = data['mouse']['x'], data['mouse']['y']
for d in data['displays']:
    if not d['main'] and d['width'] > 100 and d['height'] > 100:
        print('yes' if d['x'] <= x <= d['x'] + d['width'] and
              d['y'] <= y <= d['y'] + d['height'] else 'no')
        break
PY
)"
  if [[ "$inside" == "yes" ]]; then break; fi
  print -u2 "触摸尝试 $attempt 未进入虚拟显示器"
  sleep 1
done
if [[ "$inside" != "yes" ]]; then
  print -u2 "鼠标坐标：$(cat /tmp/tabletdisplay-bounds.json)"
  print -u2 "平板焦点：$(adb_cmd -s "$serial" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true)"
  exit 1
fi
print "触摸注入：鼠标已进入虚拟显示器"

# Rotation path: force landscape, verify a live switch, then restore free
# rotation and verify the reverse switch.
switch_count="$(grep -c "原地切换显示" "$log" 2>/dev/null || true)"
adb_cmd -s "$serial" shell wm fixed-to-user-rotation enabled >/dev/null 2>&1 || true
adb_cmd -s "$serial" shell wm user-rotation lock 0 >/dev/null 2>&1 || true
rotated=0
for _ in {1..20}; do
  count="$(grep -c "原地切换显示" "$log" 2>/dev/null || true)"
  if [[ "$count" -gt "$switch_count" ]]; then rotated=1; break; fi
  sleep 0.5
done
[[ "$rotated" == "1" ]] || { print -u2 "强制横屏没有触发展示切换"; exit 1; }
[[ "$(curl -sS --max-time 1 http://127.0.0.1:9137/health 2>/dev/null || true)" == "ready" ]] || {
  print -u2 "旋转后 /health 不是 ready"; exit 1
}
print "旋转切换：已切到横屏，连接保持"

switch_count="$(grep -c "原地切换显示" "$log" 2>/dev/null || true)"
adb_cmd -s "$serial" shell wm user-rotation free >/dev/null 2>&1 || true
adb_cmd -s "$serial" shell wm fixed-to-user-rotation default >/dev/null 2>&1 || true
restored=0
for _ in {1..20}; do
  count="$(grep -c "原地切换显示" "$log" 2>/dev/null || true)"
  if [[ "$count" -gt "$switch_count" ]]; then restored=1; break; fi
  sleep 0.5
done
[[ "$restored" == "1" ]] || { print -u2 "恢复自由旋转后没有切回原方向"; exit 1; }
[[ "$(curl -sS --max-time 1 http://127.0.0.1:9137/health 2>/dev/null || true)" == "ready" ]] || {
  print -u2 "恢复旋转后 /health 不是 ready"; exit 1
}
print "旋转恢复：已切回原方向，连接保持"

print "真机视频/触摸/旋转 E2E 通过"
