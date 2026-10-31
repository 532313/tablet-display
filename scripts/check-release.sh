#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/TabletDisplay.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
dmg="$root/dist/Tablet Display-${version}.dmg"
require_notarized=0
[[ "${1:-}" == "--require-notarized" ]] && require_notarized=1

[[ -d "$app" ]] || { print -u2 "缺少 $app"; exit 1; }
[[ -f "$dmg" ]] || { print -u2 "缺少 $dmg"; exit 1; }
archs="$(lipo -archs "$app/Contents/MacOS/TabletDisplay")"
[[ "$archs" == "arm64" ]] || { print -u2 "架构不是 arm64：$archs"; exit 1; }
codesign --verify --deep --strict "$app"
hdiutil verify "$dmg" >/dev/null
print "版本：$version"
print "架构：$archs"
print "App 签名：$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/Authority=/{print $2; exit}')"
print "DMG：$dmg"

if [[ "$require_notarized" == "1" ]]; then
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature -v "$dmg"
  print "公证校验通过"
else
  if spctl --assess --type open --context context:primary-signature "$dmg" >/dev/null 2>&1; then
    print "Gatekeeper：通过"
  else
    print "提示：当前 DMG 未通过 Gatekeeper（本地/adhoc 签名）；发布前请用 Developer ID 执行 make notarize。"
  fi
fi
