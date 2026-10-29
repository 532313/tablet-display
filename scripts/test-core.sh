#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
mkdir -p .build/ModuleCache build
export CLANG_MODULE_CACHE_PATH="$root/.build/ModuleCache"
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  Sources/TabletDisplay/ADB.swift Sources/TabletDisplay/LocalNetwork.swift \
  Sources/TabletDisplay/Options.swift Sources/TabletDisplay/VideoCapture.swift \
  Sources/TabletDisplay/HTTPServer.swift \
  Sources/TabletDisplay/RTPVideoServer.swift Sources/TabletDisplay/Log.swift \
  Tests/CoreTests/*.swift \
  -framework VideoToolbox -framework ScreenCaptureKit -framework CoreMedia \
  -framework CoreGraphics \
  -o build/core-tests
build/core-tests
