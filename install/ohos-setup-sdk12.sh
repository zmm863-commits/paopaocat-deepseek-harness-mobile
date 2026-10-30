#!/usr/bin/env bash
# ohos-setup-sdk12.sh —— 把 OpenHarmony SDK（API 12）布置成 flutter 3.27 能识别的结构。
#
# 为什么需要这个脚本：flutter 3.27 对这个 SDK 目录结构有三种不同的校验，
# 而且互相冲突。实测出来的要求：
#
#   1. flutter doctor 用 locateHarmonySdk()  → 认 OhosSdk（OpenHarmony）
#      要求：<sdk>/<纯数字目录>/toolchains/hdc
#      坑：目录名必须是纯数字（isNumeric 用的是 double.tryParse），
#          所以 "12" 可以，"12.0.0" 不行（两个点解析失败）。
#
#   2. flutter build hap 用 globals.hmosSdk → 只认 HmosSdk（HarmonyOS）
#      要求：<sdk>/<目录>/sdk-pkg.json 里含 data.apiVersion
#      坑：OpenHarmony SDK 没这个文件，所以要自己造。造了之后 build 才不报
#          "No Hmos SDK found"。
#
#   3. hvigor 自己找组件：<sdk>/<platformVersion>/<component>
#      要求：platformVersion 目录（如 12 或 5.0.0）+ ets/js/native/toolchains/previewer
#      坑：hvigor 6.x 报 "SDK management mode has changed" 就是因为组件位置不对；
#          必须是 <sdk>/<platformVersion>/ 这一层。
#
# 结论：用「一个真实目录 + 一个纯数字软链」同时满足 1 和 3，再造 sdk-pkg.json 满足 2。
#
# 用法：bash install/ohos-setup-sdk12.sh <sdk.tar.gz> [目标目录]
#   例：bash install/ohos-setup-sdk12.sh /tmp/ohos-sdk-12.tar.gz /tmp/ohos-sdk-12
set -uo pipefail

TGZ="${1:?用法: ohos-setup-sdk12.sh <ohos-sdk.tar.gz> [目标目录]}"
DEST="${2:-/tmp/ohos-sdk-12}"
API="${OHOS_API:-12}"

info() { printf '\033[36m▸\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ -f "${TGZ}" ] || die "找不到 ${TGZ}"

# ── 解压外层 ──
# 外层结构因版本而异：API 26 的包有 ohos-sdk/ 外层，API 12 的直接是 linux/ + windows/
if [ ! -d "${DEST}/linux" ] && [ ! -d "${DEST}/ohos-sdk" ]; then
  info "解压外层 tar（约 2.5 GB，需要几分钟）"
  mkdir -p "${DEST}"
  tar -xzf "${TGZ}" -C "${DEST}" || die "外层解压失败"
fi
if [ -d "${DEST}/ohos-sdk" ]; then
  SRC="${DEST}/ohos-sdk"
elif [ -d "${DEST}/linux" ]; then
  SRC="${DEST}"
else
  die "解压后既没有 ohos-sdk/ 也没有 linux/，结构异常"
fi
[ -d "${SRC}/linux" ] || die "${SRC} 下没有 linux/ 目录"

# ── 找 platformVersion（从任一组件的 oh-uni-package.json 读）──
info "探测 platformVersion"
# ⚠️ API 12 的 oh-uni-package.json 没有 platformVersion 字段（只有 apiVersion + version），
#    而 API 26 有。所以按 platformVersion → apiVersion → version 的顺序回退。
#    目录名必须能被 double.tryParse 解析（flutter 的 isNumeric 校验），
#    所以 "12" 可以，"5.0.0.71" 不行。
PLATFORM=""
for z in "${SRC}"/linux/*.zip; do
  [ -f "$z" ] || continue
  PLATFORM=$(unzip -p "$z" '*/oh-uni-package.json' 2>/dev/null | head -20 \
             | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for k in ('platformVersion','apiVersion','version'):
        v=d.get(k)
        if v: print(v); break
except Exception: print('')" 2>/dev/null)
  [ -n "${PLATFORM}" ] && break
done
[ -n "${PLATFORM}" ] || die "无法从 SDK 包里读到版本号"
ok "platformVersion = ${PLATFORM}"

ROOT="${DEST}/sdk"
COMPONENTS="ets js native toolchains previewer"

# ── 解压组件到 <root>/<platformVersion>/<component> ──
info "解压组件到 ${ROOT}/${PLATFORM}/"
mkdir -p "${ROOT}/${PLATFORM}"
for c in ${COMPONENTS}; do
  z=$(ls "${SRC}"/linux/${c}-linux-x64-*.zip 2>/dev/null | head -1)
  if [ -n "${z}" ] && [ ! -d "${ROOT}/${PLATFORM}/${c}" ]; then
    info "  解压 $(basename "$z")"
    unzip -q -o "$z" -d "${ROOT}/${PLATFORM}/" || die "解压 ${c} 失败"
  fi
done

# ── 造 sdk-pkg.json（让 build hap 认它是 HarmonyOS SDK）──
for d in "${ROOT}/${PLATFORM}" "${ROOT}/${API}"; do
  cat > "${d}/sdk-pkg.json" <<EOF
{
  "meta": { "metaVersion": "3.0.2" },
  "data": {
    "apiVersion": "${API}",
    "displayName": "HarmonyOS SDK",
    "path": ".",
    "platformVersion": "${PLATFORM}",
    "releaseType": "Release",
    "version": "${PLATFORM}"
  }
}
EOF
done
ok "sdk-pkg.json 已写入"

# ── 纯数字软链（满足 flutter doctor 的 isNumeric 校验）──
if [ "${PLATFORM}" != "${API}" ]; then
  ln -sfn "${PLATFORM}" "${ROOT}/${API}"
  ok "软链 ${API} -> ${PLATFORM}"
fi

# ── 验证 ──
echo
info "验证结果"
[ -f "${ROOT}/${API}/toolchains/hdc" ] && ok "hdc 可达（${API}/toolchains/hdc）" || die "hdc 不在 ${API}/toolchains/"
[ -f "${ROOT}/${PLATFORM}/sdk-pkg.json" ] && ok "sdk-pkg.json 可达" || die "sdk-pkg.json 缺失"

echo
echo "设置环境变量（写进 shell 或直接 export）："
echo "  export DEVECO_SDK_HOME=${ROOT}"
echo "  export HOS_SDK_HOME=${ROOT}"
echo "  export OHOS_SDK_HOME=${ROOT}"
echo
echo "然后：flutter build hap --debug"
