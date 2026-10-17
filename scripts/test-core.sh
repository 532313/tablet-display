#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
mkdir -p .build/ModuleCache build
export CLANG_MODULE_CACHE_PATH="$root/.build/ModuleCache"
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  Sources/TabletDisplay/ADB.swift Sources/TabletDisplay/VideoCapture.swift \
  Tests/CoreTests/main.swift \
  -framework VideoToolbox -framework ScreenCaptureKit -framework CoreMedia \
  -o build/core-tests
build/core-tests
