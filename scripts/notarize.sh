#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/TabletDisplay.app"

# 需要 Apple Developer ID Application 证书，以及已保存的 notarytool 凭据：
#   xcrun notarytool store-credentials TabletDisplay \
#     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
: "${TABLETDISPLAY_SIGN_IDENTITY:?请设置 TABLETDISPLAY_SIGN_IDENTITY（Developer ID Application 证书名）}"
: "${TABLETDISPLAY_NOTARY_PROFILE:?请设置 TABLETDISPLAY_NOTARY_PROFILE（notarytool keychain profile）}"

"$root/scripts/make-dmg.sh"
codesign --force --deep --options runtime --timestamp \
  --sign "$TABLETDISPLAY_SIGN_IDENTITY" "$app"
# Re-create the image so it contains the Developer ID signed app.
"$root/scripts/make-dmg.sh" --no-build

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$root/dist/Tablet Display-$version.dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$TABLETDISPLAY_NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
print "已公证并装订：$dmg"
