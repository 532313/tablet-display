#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
endpoint="$("$root/scripts/connect-wireless.sh")"
if [[ "${1:-}" == "--adb-tunnel" ]]; then
  shift
  exec "$root/scripts/run.sh" --serial "$endpoint" "$@"
fi

tablet_ip="${endpoint%:*}"
interface="$(route -n get "$tablet_ip" | awk '/interface:/ {print $2; exit}')"
host_ip="$(ipconfig getifaddr "$interface")"
if [[ "$host_ip" != <->.<->.<->.<-> ]]; then
  print -u2 "无法取得 Mac 在平板局域网内的 IPv4 地址。"
  exit 1
fi
exec "$root/scripts/run.sh" --serial "$endpoint" --direct-host "$host_ip" "$@"
