#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/TabletDisplay.app"
dist="$root/dist"

if [[ "${1:-}" != "--no-build" ]]; then
  "$root/scripts/build-app.sh"
fi
if [[ ! -d "$app" ]]; then
  print -u2 "缺少 $app，请先运行 make app"
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$dist/Tablet Display-$version.dmg"
mkdir -p "$dist"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/Tablet Display.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Tablet Display $version" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
print "已生成：$dmg"
