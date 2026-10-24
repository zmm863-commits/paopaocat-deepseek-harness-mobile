#!/usr/bin/env bash
# 把 android/vdshell 的 Java 源码编成可 app_process 直接跑的 vdshell.dex。
#
# 为什么要单独一个 dex：虚拟屏 + 定向注入必须跑在 **shell 身份（uid 2000）** 里才有权限，
# 而 App 自己的进程是普通沙箱。编成独立 dex 后，可以
#   adb shell → CLASSPATH=/data/local/tmp/vdshell.dex app_process / com.dshmobile.vdshell.ShellServer
# 起一个 shell 进程（免装 Shizuku 的那条路）。
#
# ⚠ 必须在 **ASCII 目录**里编：本机 JVM 的 sun.jnu.encoding 不是 UTF-8，
#   javac/d8 遇到 /root/办公 会报 "Malformed input or input contains unmappable characters"。
#   所以脚本把源码复制到 /tmp/vdshell-build 编完再 cp 回来（与打包走 /tmp/dsh-app 同一个原因）。
#
# 依赖：javac（JDK 17）、Android SDK 的 android.jar 与 d8。
# 产物：app/src/main/assets/vdshell.dex（随包分发；App 运行时会 cp 到 /data/local/tmp）。
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}"
WORK="${VDSHELL_WORK:-/tmp/vdshell-build}"

PLATFORM="$ANDROID_HOME/platforms/android-36/android.jar"
[ -f "$PLATFORM" ] || PLATFORM="$(ls -d "$ANDROID_HOME"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)"
[ -f "$PLATFORM" ] || { echo "找不到 android.jar（ANDROID_HOME=$ANDROID_HOME）" >&2; exit 1; }

D8="$ANDROID_HOME/build-tools/36.0.0/d8"
[ -x "$D8" ] || D8="$(ls "$ANDROID_HOME"/build-tools/*/d8 2>/dev/null | sort -V | tail -1)"
[ -x "$D8" ] || { echo "找不到 d8（build-tools）" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/classes" "$WORK/out"

echo "[vdshell] 复制源码到 ASCII 目录 $WORK"
(cd "$REPO/android/vdshell/src" && tar cf - .) | (cd "$WORK/src" && tar xf -)

echo "[vdshell] javac (android.jar = $PLATFORM)"
find "$WORK/src" -name '*.java' > "$WORK/sources.txt"
javac -source 8 -target 8 -nowarn -encoding UTF-8 \
  -classpath "$PLATFORM" \
  -d "$WORK/classes" \
  @"$WORK/sources.txt"

echo "[vdshell] d8"
"$D8" --min-api 24 --release --lib "$PLATFORM" \
  --output "$WORK/out" $(find "$WORK/classes" -name '*.class')

DEX="$WORK/out/classes.dex"
[ -f "$DEX" ] || { echo "d8 没产出 classes.dex" >&2; exit 1; }

ASSETS="$REPO/app/src/main/assets"
mkdir -p "$ASSETS"
cp "$DEX" "$ASSETS/vdshell.dex"

echo "[vdshell] 产物：$ASSETS/vdshell.dex ($(stat -c%s "$ASSETS/vdshell.dex") 字节)"
