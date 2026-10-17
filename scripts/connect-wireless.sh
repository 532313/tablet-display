#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
state="$root/build/wireless-adb.txt"
requested="${1:-}"
if (( $# > 1 )); then
  print -u2 "用法: scripts/connect-wireless.sh [USB序列号|IP:端口]"
  exit 2
fi

# Prefer an already connected Wi-Fi transport, so a plugged-in USB cable
# does not make the main program choose the wrong ADB device.
connected=(${(f)"$(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')"})
if [[ "$requested" == <->.<->.<->.<->:<-> ]]; then
  endpoint="$requested"
elif [[ -z "$requested" ]]; then
  wireless=()
  usb=()
  for device in "${connected[@]}"; do
    if [[ "$device" == <->.<->.<->.<->:<-> ]]; then
      wireless+=("$device")
    else
      usb+=("$device")
    fi
  done
  if (( ${#wireless} == 1 )); then
    endpoint="$wireless[1]"
  elif (( ${#wireless} > 1 )); then
    print -u2 "检测到多台无线 ADB 设备，请先运行 scripts/connect-wireless.sh IP:端口。"
    exit 1
  elif (( ${#usb} == 1 )); then
    requested="$usb[1]"
  elif (( ${#usb} > 1 )); then
    print -u2 "检测到多台 USB 设备，请先运行 scripts/connect-wireless.sh USB序列号。"
    exit 1
  elif [[ -f "$state" ]]; then
    endpoint="$(<"$state")"
  else
    print -u2 "未找到 ADB 设备。首次运行请通过 USB 连接平板；之后可使用已保存的无线地址。"
    exit 1
  fi
fi

if [[ -z "${endpoint:-}" ]]; then
  ip="$(adb -s "$requested" shell ip -4 addr show wlan0 | awk '/inet / {split($2, parts, "/"); print parts[1]; exit}')"
  if [[ "$ip" != <->.<->.<->.<-> ]]; then
    print -u2 "无法读取平板 Wi-Fi 地址，请确认平板已连接 Wi-Fi。"
    exit 1
  fi
  endpoint="$ip:5555"
  print -u2 "正在将 $requested 切换为无线 ADB：$endpoint"
  adb -s "$requested" tcpip 5555 >&2
fi

for attempt in {1..10}; do
  if adb connect "$endpoint" >/dev/null 2>&1 &&
     [[ "$(adb -s "$endpoint" get-state 2>/dev/null)" == "device" ]]; then
    mkdir -p "$root/build"
    print -r -- "$endpoint" > "$state"
    print -u2 "无线 ADB 已连接：$endpoint"
    print -r -- "$endpoint"
    exit 0
  fi
  sleep 1
done
print -u2 "无法通过 Wi-Fi 连接 $endpoint。请确认 Mac 与平板在同一网络，并允许设备间通信。"
exit 1
