#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/TabletDisplay.app"
binary="$app/Contents/MacOS/TabletDisplay"
out="${TMPDIR:-/tmp}/tabletdisplay-ui-snapshot.png"
out_en="${TMPDIR:-/tmp}/tabletdisplay-ui-snapshot-en.png"

if [[ ! -x "$binary" ]]; then
  print -u2 "缺少 $binary，请先运行 make app"
  exit 1
fi

check_snapshot() {
  local snap="$1"
  [[ -s "$snap" ]] || { print -u2 "UI snapshot 未生成：$snap"; exit 1; }
  local width height
  width="$(sips -g pixelWidth "$snap" | awk '/pixelWidth/ {print $2}')"
  height="$(sips -g pixelHeight "$snap" | awk '/pixelHeight/ {print $2}')"
  if [[ "$width" -lt 700 || "$height" -lt 500 ]]; then
    print -u2 "UI snapshot 尺寸异常：${width}x${height}"
    exit 1
  fi
  print "UI 快照通过：${width}x${height} → $snap"
}

rm -f "$out" "$out_en"
"$binary" --snapshot-ui "$out"
"$binary" --snapshot-ui "$out_en" -AppleLanguages '(en)'
check_snapshot "$out"
check_snapshot "$out_en"
