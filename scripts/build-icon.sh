#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
python3 "$root/scripts/generate-icon.py"

iconset="$root/Resources/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
src="$root/Resources/AppIcon-1024.png"
for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" \
            "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" \
            "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" \
            "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$src" --out "$iconset/$name" >/dev/null
done
iconutil -c icns "$iconset" -o "$root/Resources/AppIcon.icns"
rm -rf "$iconset"
print "已生成：$root/Resources/AppIcon.icns"
