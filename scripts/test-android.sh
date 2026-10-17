#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"

if [[ ! -x "$JAVA_HOME/bin/javac" ]]; then
  print -u2 "找不到 javac。请安装 JDK 或设置 JAVA_HOME。"
  exit 1
fi

out="$root/build/android/test-classes"
rm -rf "$out"
mkdir -p "$out"
javac -source 8 -target 8 -Xlint:-options -d "$out" \
  Android/src/dev/local/tabletdisplay/VideoProtocol.java \
  Android/src/dev/local/tabletdisplay/ReconnectPolicy.java \
  Android/test/dev/local/tabletdisplay/ProtocolTest.java
java -cp "$out" dev.local.tabletdisplay.ProtocolTest
