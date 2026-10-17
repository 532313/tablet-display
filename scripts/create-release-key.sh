#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
keystore="${1:-$root/build/android/tabletdisplay-release.keystore}"
alias=tabletdisplay
storepass="${TABLETDISPLAY_STORE_PASS:-}"
if [[ -z "$storepass" ]]; then
  # uuidgen is finite, so this does not trip pipefail with SIGPIPE.
  storepass="$(uuidgen | tr -d '-')"
fi
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"

if [[ -f "$keystore" ]]; then
  print -u2 "签名文件已存在，拒绝覆盖：$keystore"
  exit 1
fi

mkdir -p "${keystore:h}"
keytool -genkeypair -keystore "$keystore" -alias "$alias" \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$storepass" -keypass "$storepass" \
  -dname "CN=Tablet Display, O=Local" >/dev/null

cat <<INFO
已创建签名文件：$keystore
别名：$alias
密码：$storepass

请把密码单独保存好；丢失后无法覆盖安装已签名的应用。构建 release 包时执行：
  export TABLETDISPLAY_KEYSTORE="$keystore"
  export TABLETDISPLAY_KEY_ALIAS="$alias"
  export TABLETDISPLAY_STORE_PASS="$storepass"
  ./scripts/build-android.sh
INFO
