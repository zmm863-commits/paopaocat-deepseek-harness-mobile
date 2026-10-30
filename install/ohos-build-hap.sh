#!/usr/bin/env bash
# ohos-build-hap.sh —— 一键构建 + 签名出可安装的鸿蒙 HAP。
#
# 已实测跑通（2026-10-21）：产出 106 KB 已签名 HAP，verify-app 全绿。
#
# 前置：OpenHarmony SDK（含 ets/js/native/toolchains/previewer）+ JDK 17 + hvigor。
# 全部不需要华为账号，SDK 从 repo.huaweicloud.com 公开镜像取。
#
# 用法：
#   bash install/ohos-build-hap.sh                 # 构建 + 签名
#   bash install/ohos-build-hap.sh --build-only    # 只构建不签名
#
# 退出码：0 成功；非 0 见错误信息
set -uo pipefail

SDK_ROOT="${OHOS_SDK_ROOT:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJ_SRC="${REPO}/ohos"
OUT="${REPO}/release/harmony"
# ⚠️ hvigor 不接受中文路径（实测报 00306003 "Invalid project path"）。
#    本仓库路径含 "办公"，所以构建必须转到纯 ASCII 的临时目录进行，产物再拷回来。
BUILD_DIR="${OHOS_BUILD_DIR:-/tmp/dsh-ohos-build}"
SIGN_DIR="${SIGN_DIR:-/tmp/sign}"
LIB_VER="${OHOS_API_VERSION:-26.0.0}"
JAVA_HOME_DEFAULT=/usr/lib/jvm/java-17-openjdk-amd64

info() { printf '\033[36m▸\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ── 定位 SDK ───────────────────────────────────────────────────
if [ -z "${SDK_ROOT}" ]; then
  for c in /tmp/ohos-sdk/extracted "${HOME}/ohos-sdk" /opt/ohos-sdk; do
    [ -d "$c/${LIB_VER}/toolchains" ] && SDK_ROOT="$c" && break
  done
fi
[ -n "${SDK_ROOT}" ] || die "找不到 OpenHarmony SDK（需含 ${LIB_VER}/toolchains）。用 OHOS_SDK_ROOT 指定。"
LIB="${SDK_ROOT}/${LIB_VER}/toolchains/lib"
TOOL_JAR="${LIB}/hap-sign-tool.jar"
[ -f "${TOOL_JAR}" ] || die "缺 hap-sign-tool.jar：${TOOL_JAR}"

export DEVECO_SDK_HOME="${SDK_ROOT}"
export JAVA_HOME="${JAVA_HOME:-${JAVA_HOME_DEFAULT}}"
export PATH="${JAVA_HOME}/bin:${SDK_ROOT}/${LIB_VER}/toolchains:${PATH}"
command -v java >/dev/null || die "缺 java（apt-get install openjdk-17-jdk-headless）"

# ── 构建 ──────────────────────────────────────────────────────
info "SDK: ${SDK_ROOT}  (API ${LIB_VER})"
info "源工程: ${PROJ_SRC}"
info "构建目录: ${BUILD_DIR}（ASCII，绕开中文路径限制）"
[ -d "${PROJ_SRC}" ] || die "工程目录不存在：${PROJ_SRC}"

# 同步到 ASCII 构建目录（保留 node_modules 复用，避免每次重装）
mkdir -p "${BUILD_DIR}"
for item in AppScope entry build-profile.json5 hvigorfile.ts oh-package.json5 hvigor local.properties; do
  if [ -e "${PROJ_SRC}/${item}" ]; then
    rm -rf "${BUILD_DIR:?}/${item}"
    cp -a "${PROJ_SRC}/${item}" "${BUILD_DIR}/${item}"
  fi
done
if [ ! -d "${BUILD_DIR}/node_modules/@ohos/hvigor" ] && [ -d "${PROJ_SRC}/node_modules/@ohos/hvigor" ]; then
  cp -a "${PROJ_SRC}/node_modules" "${BUILD_DIR}/node_modules"
fi
PROJ="${BUILD_DIR}"
cd "${PROJ}" || die "无法进入构建目录：${PROJ}"

HVIGOR="node node_modules/@ohos/hvigor/bin/hvigor.js"
[ -d node_modules/@ohos/hvigor ] || die "缺 hvigor 依赖。先执行：cd ${PROJ} && npm install --registry=https://repo.harmonyos.com/npm/ @ohos/hvigor @ohos/hvigor-ohos-plugin"

info "构建中……"
${HVIGOR} assembleHap --mode module -p product=default -p buildMode=debug --no-daemon 2>&1 \
  | grep -E 'ERROR|BUILD|Finished :entry:assembleHap' | tail -6
UNSIGNED="entry/build/default/outputs/default/entry-default-unsigned.hap"
[ -f "${UNSIGNED}" ] || die "构建未产出 HAP"
ok "构建完成：$(ls -lh "${UNSIGNED}" | awk '{print $5}')"

[ "${1:-}" = "--build-only" ] && { info "跳过签名"; exit 0; }

# ── 签名 ──────────────────────────────────────────────────────
mkdir -p "${SIGN_DIR}" "${OUT}"
BUNDLE="${OHOS_BUNDLE_NAME:-com.dshmobile.harmony}"

if [ ! -f "${SIGN_DIR}/dsh.p12" ]; then
  info "首次运行：生成应用密钥对与证书链"
  # CA 证书链：根（自签）→ 中间 → 叶子
  keytool -exportcert -alias "rootcacert" -keystore "${LIB}/OpenHarmony.p12" \
    -storetype PKCS12 -storepass 123456 -rfc -file "${SIGN_DIR}/root-ca.cer" >/dev/null 2>&1 \
    || die "导出根 CA 失败"
  keytool -exportcert -alias "cacert" -keystore "${LIB}/OpenHarmony.p12" \
    -storetype PKCS12 -storepass 123456 -rfc -file "${SIGN_DIR}/sub-ca.cer" >/dev/null 2>&1 \
    || die "导出中间 CA 失败"

  java -jar "${TOOL_JAR}" generate-keypair -keyAlias "dsh-key" -keyPwd 123456 \
    -keyAlg ECC -keySize NIST-P-256 \
    -keystoreFile "${SIGN_DIR}/dsh.p12" -keystorePwd 123456 >/dev/null 2>&1 \
    || die "生成密钥对失败"

  # ⚠️ 必须用真正的根 CA（rootcacert）；用 cacert 当根会得到重复的两级，
  #    后续 sign-app 报 "verify certificate chain failed! Signature does not match."
  java -jar "${TOOL_JAR}" generate-app-cert \
    -keyAlias "dsh-key" -keyPwd 123456 \
    -subject "C=CN,O=DSH,OU=DSH Mobile,CN=DSH Mobile Debug" \
    -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
    -issuerKeyAlias "openharmony application ca" -issuerKeyPwd 123456 \
    -keystoreFile "${SIGN_DIR}/dsh.p12" -keystorePwd 123456 \
    -issuerKeystoreFile "${LIB}/OpenHarmony.p12" -issuerKeystorePwd 123456 \
    -signAlg SHA256withECDSA -outForm certChain \
    -rootCaCertFile "${SIGN_DIR}/root-ca.cer" -subCaCertFile "${SIGN_DIR}/sub-ca.cer" \
    -outFile "${SIGN_DIR}/dsh-app.cer" >/dev/null 2>&1 \
    || die "生成应用证书失败"
  ok "证书链已生成"
fi

# profile：有效期从 SDK 模板的 2024-01 改成"现在起 10 年"，否则签名后装不上
python3 - "$SIGN_DIR" "$BUNDLE" <<'PY'
import json, re, sys, time
sign_dir, bundle = sys.argv[1], sys.argv[2]
cert = open(f'{sign_dir}/dsh-app.cer').read()
leaf = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', cert, re.S)[0] + '\n'
now = int(time.time())
profile = {
    "version-name": "2.0.0", "version-code": 2,
    "uuid": "fe686e1b-3770-4824-a938-961b140a7c98",
    "validity": {"not-before": now - 3600, "not-after": now + 10*365*24*3600},
    "type": "debug",
    "bundle-info": {"developer-id": "OpenHarmony", "development-certificate": leaf,
                    "bundle-name": bundle, "apl": "normal", "app-feature": "hos_normal_app"},
    "acls": {"allowed-acls": [""]},
    "permissions": {"restricted-permissions": []},
    # device-ids 为空 = 不限设备。非空则只有白名单里的 UDID 能装。
    "debug-info": {"device-ids": [], "device-id-type": "udid"},
    "issuer": "pki_internal",
}
open(f'{sign_dir}/profile.json', 'w').write(json.dumps(profile, ensure_ascii=False, indent=2))
PY

java -jar "${TOOL_JAR}" sign-profile -mode localSign \
  -keyAlias "openharmony application profile debug" -keyPwd 123456 \
  -profileCertFile "${LIB}/OpenHarmonyProfileDebug.pem" \
  -inFile "${SIGN_DIR}/profile.json" -signAlg SHA256withECDSA \
  -keystoreFile "${LIB}/OpenHarmony.p12" -keystorePwd 123456 \
  -outFile "${SIGN_DIR}/dsh-profile.p7b" >/dev/null 2>&1 \
  || die "签 profile 失败"
ok "profile 已签名"

# ⚠️ hap-sign-tool 同样不接受中文路径，先签到 ASCII 位置，成功后再拷进仓库
SIGNED_TMP="${BUILD_DIR}/DSH-Mobile-signed.hap"
SIGNED="${OUT}/DSH-Mobile-signed.hap"
java -jar "${TOOL_JAR}" sign-app -mode localSign \
  -keyAlias "dsh-key" -keyPwd 123456 \
  -appCertFile "${SIGN_DIR}/dsh-app.cer" \
  -profileFile "${SIGN_DIR}/dsh-profile.p7b" \
  -inFile "${UNSIGNED}" -signAlg SHA256withECDSA \
  -keystoreFile "${SIGN_DIR}/dsh.p12" -keystorePwd 123456 \
  -outFile "${SIGNED_TMP}" -compatibleVersion "${LIB_VER%%.*}" 2>&1 | grep -E 'sign-app success' >/dev/null \
  || die "签 HAP 失败"
mkdir -p "${OUT}" && cp "${SIGNED_TMP}" "${SIGNED}"

# ── 验证 ──────────────────────────────────────────────────────
info "验证签名……"
VERIFY=$(java -jar "${TOOL_JAR}" verify-app -inFile "${SIGNED_TMP}" \
  -outCertChain "${SIGN_DIR}/verify-chain.cer" -outProfile "${SIGN_DIR}/verify-profile.p7b" 2>&1)
if echo "${VERIFY}" | grep -q 'Verify success'; then
  ok "签名验证通过"
else
  echo "${VERIFY}" | tail -5
  die "签名验证失败"
fi

echo
ok "产物：${SIGNED}（$(ls -lh "${SIGNED}" | awk '{print $5}')）"
echo
echo "安装（设备已开开发者模式 + USB 调试）："
echo "  ${SDK_ROOT}/${LIB_VER}/toolchains/hdc install ${SIGNED}"
echo "  ${SDK_ROOT}/${LIB_VER}/toolchains/hdc shell aa start -a EntryAbility -b ${BUNDLE}"
