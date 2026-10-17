#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

"$root/scripts/build-android.sh"

app="$root/build/TabletDisplay.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$root/.build/ModuleCache"

export CLANG_MODULE_CACHE_PATH="$root/.build/ModuleCache"
swift build --disable-sandbox -c release \
  -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH"

cp "$root/.build/release/TabletDisplay" "$app/Contents/MacOS/TabletDisplay"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/build/TabletDisplay.apk" "$app/Contents/Resources/TabletDisplay.apk"

codesign --force --sign - "$app"
touch "$root/build/.build-stamp"
print "已构建：$app"
