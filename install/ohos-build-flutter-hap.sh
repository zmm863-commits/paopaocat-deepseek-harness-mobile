#!/usr/bin/env bash
# ohos-build-flutter-hap.sh —— 从 Flutter 源码构建可安装的鸿蒙 HAP（已实测跑通）
#
# 2026-10-22 实测结果：dsh-mobile/app 在 Flutter 3.47.7-ohos 下
#   - flutter analyze: lib/ error = 0（生产代码一行未改）
#   - flutter build hap: 成功，135 MB
#   - 签名验证: Digest verify result: true / Verify success
#
# 关键版本组合（错一个都构建不出来，全部实测确定）：
#   Flutter  3.47.7-ohos  ← gitcode.com/openharmony-tpc/flutter_flutter, 分支 oh-3.47.7-preview
#   SDK      OpenHarmony API 26（repo.huaweicloud.com 公开镜像，无需账号）
#   hvigor   6.24.5（Command Line Tools 6.1.1 自带）
#   JDK      17
#
# 用法：
#   bash install/ohos-build-flutter-hap.sh <flutter源码目录> [输出目录]
#
# 前置：install/ohos-setup-sdk26.sh 已跑过（布置 SDK 布局）
set -uo pipefail

SRC="${1:?用法: ohos-build-flutter-hap.sh <flutter 源码目录> [输出目录]}"
OUT="${2:-$(cd "$(dirname "$0")/.." && pwd)/release/harmony}"
FLUTTER="${FLUTTER_OHOS_ROOT:-/tmp/fl347}"
SDK="${OHOS_SDK_26:-/tmp/sdk26}"
CLT="${CLT_HOME:-/tmp/clt/command-line-tools}"
JDK="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
SIGN_DIR="${SIGN_DIR:-/tmp/sign}"
BUNDLE="${OHOS_BUNDLE_NAME:-com.dshmobile.dsh_mobile}"
DEV_ID="${OHOS_DEVELOPER_ID:-2850086000500227999}"

info() { printf '\033[36m▸\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ── 环境 ────────────────────────────────────────────────────────
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export PATH="${FLUTTER}/bin:${CLT}/bin:${JDK}/bin:/usr/local/bin:/usr/bin:/bin"
export DEVECO_SDK_HOME="${SDK}" HOS_SDK_HOME="${SDK}"
LIB="${SDK}/26/toolchains/lib"

# ⚠️ hvigor 与 hap-sign-tool 都不接受中文路径，构建必须在纯 ASCII 目录
WORK="${OHOS_BUILD_WORK:-/tmp/dsh-flutter-ohos}"
rm -rf "${WORK}"; mkdir -p "${WORK}"
info "同步源码到 ASCII 构建目录 ${WORK}"
cp -a "${SRC}/." "${WORK}/" || die "复制失败"
cd "${WORK}" || die "无法进入 ${WORK}"
rm -rf build .dart_tool pubspec.lock 2>/dev/null

# ── 依赖 ────────────────────────────────────────────────────────
info "解析依赖"
flutter pub get 2>&1 | tail -2 || die "pub get 失败"

info "静态检查（生产代码必须 0 error）"
flutter analyze --no-pub > /tmp/ohos-flutter-analyze.txt 2>&1 || true
LIB_ERR=$(grep -E 'error •' /tmp/ohos-flutter-analyze.txt | grep -c 'lib/' || true)
echo "  lib/ error = ${LIB_ERR}"
[ "${LIB_ERR:-0}" -eq 0 ] || { grep -E 'error •' /tmp/ohos-flutter-analyze.txt | grep 'lib/' | head -10; die "生产代码有 error，先修"; }
ok "生产代码零错误"

# ── 生成 ohos 工程 ──────────────────────────────────────────────
if [ ! -d ohos ]; then
  info "生成 ohos 工程"
  flutter create --platforms ohos --org com.dshmobile . 2>&1 | tail -2
fi

# ── 改配置（四改，缺一不可）────────────────────────────────────
info "调整鸿蒙工程配置"
python3 - "${BUNDLE}" <<'PY'
import re, sys
bang = sys.argv[1] if len(sys.argv) > 1 else ''

# 1) 根 build-profile
#    ⚠️ compileSdkVersion 和 compatibleSdkVersion 必须**分开**设：
#      compileSdkVersion 26  —— 编译时要用 26 的 API（flutter_ohos 用到 AutoFillType，
#                                API 24 及以下没有这个导出）
#      compatibleSdkVersion 12 —— 运行时最低要求，对齐 @ohos/flutter_ohos 自身声明的 12
#    若两者都写 26，产出的包 minAPIVersion=26，只有 HarmonyOS 7.0+ 能装，
#    而绝大多数机器还在 5.x/6.x —— 装不上。
p='ohos/build-profile.json5'; s=open(p).read()
s=re.sub(r'"compatibleSdkVersion":\s*(?:"[^"]*"|\d+)',
         '"compileSdkVersion": 26,\n        "compatibleSdkVersion": 12', s, count=1)
s=re.sub(r'"targetSdkVersion":\s*(?:"[^"]*"|\d+)', '"targetSdkVersion": 12', s)
s=s.replace('"runtimeOS": "HarmonyOS"', '"runtimeOS": "OpenHarmony"')
open(p,'w').write(s)

# 2) entry build-profile：runtimeOS 必须与 product 一致
p='ohos/entry/build-profile.json5'; s=open(p).read()
open(p,'w').write(s.replace('"runtimeOS": "HarmonyOS"', '"runtimeOS": "OpenHarmony"'))

# 3) module.json5：OpenHarmony SDK 26 没有 phone.json，手机用 default
p='ohos/entry/src/main/module.json5'; s=open(p).read()
s=re.sub(r'"deviceTypes"\s*:\s*\[[^\]]*\]',
         '"deviceTypes": [ "default", "tablet", "2in1" ]', s, flags=re.S)
open(p,'w').write(s)
print('  配置文件已改（compileSdkVersion / runtimeOS ×2 / deviceTypes）')
PY

# 4) local.properties：hvigor 6.x 要 sdk.dir
cat > ohos/local.properties <<EOF
flutter.sdk=${FLUTTER}
hwsdk.dir=${SDK}
sdk.dir=${SDK}
nodejs.dir=${CLT}/tool/node
EOF
ok "配置完成"

# ── 注入 node 运行时 ────────────────────────────────────────────
NODE_LIB="${REPO}/ohos-node/lib"
if [ -f "${NODE_LIB}/libnode.so" ]; then
  info "注入 libnode.so + libc++_shared.so"
  # ⚠️ HarmonyOS 的 native 库必须放 entry/libs/<abi>/，
  #    不是 entry/src/main/libs/（后者不会被打进 HAP）
  mkdir -p ohos/entry/libs/arm64-v8a
  cp -f "${NODE_LIB}/libnode.so"       ohos/entry/libs/arm64-v8a/
  cp -f "${NODE_LIB}/libc++_shared.so" ohos/entry/libs/arm64-v8a/
  ok "已放入 ohos/entry/libs/arm64-v8a/"
else
  info "跳过 libnode（${NODE_LIB}/libnode.so 不存在）"
fi

# DSH 的 node 应用代码（纯 JS，跨平台通用），放 rawfile 供运行时解压
RT_ZIP="${DSH_RUNTIME_ZIP:-/root/办公/dsh-runtime-bottest.zip}"
if [ -f "${RT_ZIP}" ]; then
  info "注入 dsh-runtime.zip（$(ls -lh "${RT_ZIP}" | awk '{print $5}')）"
  mkdir -p ohos/entry/src/main/resources/rawfile
  cp -f "${RT_ZIP}" ohos/entry/src/main/resources/rawfile/dsh-runtime.zip
  ok "已放入 rawfile/"
fi

# ── 构建 ────────────────────────────────────────────────────────
info "构建 HAP（约 30–60 秒）"
flutter build hap --debug 2>&1 | tail -6
UNSIGNED="ohos/entry/build/default/outputs/default/entry-default-unsigned.hap"
[ -f "${UNSIGNED}" ] || die "未产出 HAP"
ok "构建完成：$(ls -lh "${UNSIGNED}" | awk '{print $5}')"

# ── 签名 ────────────────────────────────────────────────────────
info "签名"
mkdir -p "${SIGN_DIR}" "${OUT}"
[ -f "${SIGN_DIR}/dsh.p12" ] || die "缺签名密钥，先跑一次 install/ohos-build-hap.sh 生成证书链"

# profile 有效期要覆盖当前时间（SDK 模板里的 validity 是 2021–2024，直接签会过期）
python3 - "${SIGN_DIR}" "${BUNDLE}" "${DEV_ID}" <<'PY'
import json, re, sys, time
sign_dir, bundle, dev_id = sys.argv[1], sys.argv[2], sys.argv[3]
cert = open(f'{sign_dir}/dsh-app.cer').read()
leaf = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', cert, re.S)[0] + '\n'
now = int(time.time())
json.dump({
    "version-name": "2.0.0", "version-code": 2,
    "uuid": "fe686e1b-3770-4824-a938-961b140a7c98",
    "validity": {"not-before": now-3600, "not-after": now+10*365*24*3600},
    "type": "debug",
    "bundle-info": {"developer-id": dev_id, "development-certificate": leaf,
                    "bundle-name": bundle, "apl": "normal", "app-feature": "hos_normal_app"},
    "acls": {"allowed-acls": [""]},
    "permissions": {"restricted-permissions": []},
    # device-ids 为空 = 不限设备
    "debug-info": {"device-ids": [], "device-id-type": "udid"},
    "issuer": "pki_internal",
}, open(f'{sign_dir}/profile-build.json','w'), ensure_ascii=False, indent=2)
PY

java -jar "${LIB}/hap-sign-tool.jar" sign-profile -mode localSign \
  -keyAlias "openharmony application profile debug" -keyPwd 123456 \
  -profileCertFile "${LIB}/OpenHarmonyProfileDebug.pem" \
  -inFile "${SIGN_DIR}/profile-build.json" -signAlg SHA256withECDSA \
  -keystoreFile "${LIB}/OpenHarmony.p12" -keystorePwd 123456 \
  -outFile "${SIGN_DIR}/build-profile.p7b" >/dev/null 2>&1 || die "签 profile 失败"

SIGNED_TMP="${WORK}/DSH-Mobile-harmony.hap"
java -jar "${LIB}/hap-sign-tool.jar" sign-app -mode localSign \
  -keyAlias "dsh-key" -keyPwd 123456 \
  -appCertFile "${SIGN_DIR}/dsh-app.cer" \
  -profileFile "${SIGN_DIR}/build-profile.p7b" \
  -inFile "${UNSIGNED}" -signAlg SHA256withECDSA \
  -keystoreFile "${SIGN_DIR}/dsh.p12" -keystorePwd 123456 \
  -outFile "${SIGNED_TMP}" -compatibleVersion 12 2>&1 | grep -q 'sign-app success' \
  || die "签 HAP 失败"
ok "签名完成"

# ── 验证 ────────────────────────────────────────────────────────
info "验证签名"
VERIFY=$(java -jar "${LIB}/hap-sign-tool.jar" verify-app -inFile "${SIGNED_TMP}" \
  -outCertChain "${SIGN_DIR}/vf-chain.cer" -outProfile "${SIGN_DIR}/vf.p7b" 2>&1)
echo "${VERIFY}" | grep -q 'Verify success' || { echo "${VERIFY}" | tail -6; die "签名验证失败"; }
ok "签名验证通过"

SIGNED="${OUT}/DSH-Mobile-harmony.hap"
cp "${SIGNED_TMP}" "${SIGNED}"
echo
ok "产物：${SIGNED}（$(ls -lh "${SIGNED}" | awk '{print $5}')）"
echo
echo "安装（设备开启开发者模式 + USB 调试）："
echo "  ${SDK}/26/toolchains/hdc install ${SIGNED}"
echo "  ${SDK}/26/toolchains/hdc shell aa start -a EntryAbility -b ${BUNDLE}"
