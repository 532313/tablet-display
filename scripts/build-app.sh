#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

if [[ "$(uname -m)" != "arm64" ]]; then
  print -u2 "Tablet Display 仅支持 Apple Silicon（arm64）；当前主机为 $(uname -m)。"
  exit 1
fi

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
for localization in "$root"/Resources/*.lproj(N); do
  cp -R "$localization" "$app/Contents/Resources/"
done

identity="${TABLETDISPLAY_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -F '"Tablet Display Local"' >/dev/null; then
  identity="Tablet Display Local"
fi
if [[ -n "$identity" && "$identity" != "-" ]]; then
  print "签名身份：$identity"
  codesign --force --sign "$identity" "$app"
else
  codesign --force --sign - "$app"
  print -u2 "提示：当前使用 ad-hoc 签名；重建后 macOS 可能要求重新授予屏幕录制/辅助功能权限。"
  print -u2 "      运行 ./scripts/create-signing-identity.sh 创建稳定本地签名后可避免反复授权。"
fi
archs="$(lipo -archs "$app/Contents/MacOS/TabletDisplay" 2>/dev/null || true)"
if [[ "$archs" != "arm64" ]]; then
  print -u2 "构建产物架构异常：期望 arm64，实际 '$archs'。"
  exit 1
fi
codesign --verify --deep --strict "$app"
print "架构校验：arm64（Apple Silicon only）"
touch "$root/build/.build-stamp"
print "已构建：$app"
