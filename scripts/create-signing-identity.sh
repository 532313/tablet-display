#!/bin/zsh
set -euo pipefail

name="${TABLETDISPLAY_LOCAL_SIGN_NAME:-Tablet Display Local}"
keychain="${TABLETDISPLAY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
keychain_password="${TABLETDISPLAY_KEYCHAIN_PASSWORD:-}"
support="$HOME/Library/Application Support/TabletDisplay/signing"
p12pass="tabletdisplay-local"

if security find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -F "\"$name\"" >/dev/null; then
  print "签名身份已存在：$name"
  security find-identity -v -p codesigning "$keychain" | grep -F "\"$name\""
  exit 0
fi

if [[ ! -f "$keychain" ]]; then
  if [[ -z "$keychain_password" ]]; then
    print -u2 "钥匙串不存在：$keychain"
    print -u2 "如使用自定义钥匙串，请同时设置 TABLETDISPLAY_KEYCHAIN_PASSWORD。"
    exit 1
  fi
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
fi

if [[ -n "$keychain_password" ]]; then
  security unlock-keychain -p "$keychain_password" "$keychain" >/dev/null
fi

mkdir -p "$support"
chmod 700 "$support"
cat > "$support/openssl.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = ext
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
EOF

if [[ ! -f "$support/cert.pem" || ! -f "$support/key.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$support/key.pem" -out "$support/cert.pem" \
    -config "$support/openssl.cnf" >/dev/null 2>&1
fi
chmod 600 "$support/key.pem"

legacy=()
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
  # macOS Security.framework does not understand PBES2/AES by default.
  legacy=(-legacy)
else
  # LibreSSL has no -legacy flag; force 3DES instead of the RC2 cert default.
  legacy=(-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1)
fi
openssl pkcs12 -export "${legacy[@]}" -out "$support/identity.p12" \
  -inkey "$support/key.pem" -in "$support/cert.pem" \
  -name "$name" -passout "pass:$p12pass" >/dev/null 2>&1
chmod 600 "$support/identity.p12"

security import "$support/identity.p12" -k "$keychain" -P "$p12pass" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

if [[ -n "$keychain_password" ]]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$keychain_password" "$keychain" >/dev/null 2>&1 || true
fi

# This may ask for confirmation from Keychain Access. A trusted local
# certificate makes the identity usable without repeated keychain prompts.
security add-trusted-cert -r trustRoot -k "$keychain" "$support/cert.pem" >/dev/null 2>&1 || true

if ! security find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -F "\"$name\"" >/dev/null; then
  print -u2 "已导入证书，但 codesign 仍找不到身份。"
  print -u2 "请打开“钥匙串访问”，在“我的证书”中信任 “$name”，并确认钥匙串已解锁。"
  exit 1
fi

security find-identity -v -p codesigning "$keychain" | grep -F "\"$name\""
print "已创建稳定签名身份：$name"
print "证书材料：$support"
print "后续运行 scripts/build-app.sh / make app 会自动使用它。"
print "如果 codesign 首次询问钥匙串访问，请选择“始终允许”。"
