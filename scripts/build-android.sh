#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
tools="$sdk/build-tools/36.0.0"
androidJar="$sdk/platforms/android-34/android.jar"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"

if [[ ! -x "$tools/aapt2" || ! -f "$androidJar" ]]; then
  print -u2 "缺少 Android SDK Build Tools 36 和 Android API 34 平台。"
  exit 1
fi

mkdir -p build/android/classes build/android/dex
javac -source 8 -target 8 -classpath "$androidJar" -d build/android/classes \
  Android/src/dev/local/tabletdisplay/MainActivity.java
classes=(build/android/classes/**/*.class(N))
"$tools/d8" --min-api 29 --lib "$androidJar" --output build/android/dex "$classes[@]"
"$tools/aapt2" link -o build/android/unsigned.apk -I "$androidJar" \
  --manifest Android/AndroidManifest.xml --min-sdk-version 29 --target-sdk-version 31
zip -q -j build/android/unsigned.apk build/android/dex/classes.dex
"$tools/zipalign" -f 4 build/android/unsigned.apk build/android/aligned.apk

# A debug key is fine for sideloading during development. Set the three
# TABLETDISPLAY_* variables to sign with a real release key instead; see
# scripts/create-release-key.sh.
if [[ -n "${TABLETDISPLAY_KEYSTORE:-}" ]]; then
  keystore="$TABLETDISPLAY_KEYSTORE"
  alias="${TABLETDISPLAY_KEY_ALIAS:?请设置 TABLETDISPLAY_KEY_ALIAS}"
  storepass="${TABLETDISPLAY_STORE_PASS:?请设置 TABLETDISPLAY_STORE_PASS}"
  keypass="${TABLETDISPLAY_KEY_PASS:-$storepass}"
else
  # Keep the debug signing identity outside the project so `make clean`
  # never breaks updates to an already installed APK.
  debug_dir="$HOME/Library/Application Support/TabletDisplay"
  keystore="${TABLETDISPLAY_DEBUG_KEYSTORE:-$debug_dir/debug.keystore}"
  alias=tabletdisplay
  storepass=android
  keypass=android
  mkdir -p "${keystore:h}"
  if [[ ! -f "$keystore" ]]; then
    keytool -genkeypair -keystore "$keystore" -alias "$alias" \
      -keyalg RSA -keysize 2048 -validity 3650 -storepass "$storepass" -keypass "$keypass" \
      -dname "CN=Tablet Display Debug" >/dev/null
  fi
fi
"$tools/apksigner" sign --ks "$keystore" --ks-key-alias "$alias" \
  --ks-pass "pass:$storepass" --key-pass "pass:$keypass" \
  --out build/TabletDisplay.apk build/android/aligned.apk
"$tools/apksigner" verify build/TabletDisplay.apk
print "已构建：$root/build/TabletDisplay.apk"
