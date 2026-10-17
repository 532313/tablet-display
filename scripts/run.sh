#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
binary="$root/build/TabletDisplay.app/Contents/MacOS/TabletDisplay"
apk="$root/build/TabletDisplay.apk"
bundle_apk="$root/build/TabletDisplay.app/Contents/Resources/TabletDisplay.apk"
stamp="$root/build/.build-stamp"
needs_build=0

if [[ ! -x "$binary" || ! -f "$apk" || ! -f "$bundle_apk" || ! -f "$stamp" ]]; then
  needs_build=1
else
  for source in "$root/Package.swift" "$root/Sources" "$root/Android" \
                "$root/Resources" "$root/scripts/build-app.sh" "$root/scripts/build-android.sh"; do
    [[ -e "$source" ]] || continue
    if [[ -n "$(find "$source" -type f -newer "$stamp" -print -quit 2>/dev/null)" ]]; then
      needs_build=1
      break
    fi
  done
  if (( ! needs_build )) && [[ "$apk" -nt "$bundle_apk" ]]; then
    needs_build=1
  fi
fi

if (( needs_build )); then
  print "检测到源码或构建脚本更新，正在重新构建…"
  "$root/scripts/build-app.sh"
fi

exec "$binary" "$@"
