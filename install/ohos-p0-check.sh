#!/usr/bin/env bash
# ohos-p0-check.sh —— HarmonyOS 适配 P0 环境自检与准备。
#
# 设计原则：只做"能验证的事"，每一步都给出可判定的输出，不猜。
# 幂等：重复运行不会重复解压/重复下载。
#
# 用法：
#   bash install/ohos-p0-check.sh              # 自检
#   bash install/ohos-p0-check.sh --unpack     # 顺带解压 SDK
#
# 退出码：0 = 全部就绪；1 = 有缺项（逐条列出）
set -uo pipefail

WORK="${OHOS_WORK:-/tmp}"
SDK_TGZ="${WORK}/ohos-sdk.tar.gz"
SDK_DIR="${WORK}/ohos-sdk"
FLUTTER322="${WORK}/flutter-ohos"
MISSING=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; MISSING=$((MISSING+1)); }
info() { printf '  · %s\n' "$1"; }

echo "═════ HarmonyOS P0 环境自检 ═════"
echo "工作目录：${WORK}"
echo

# ── 1. OHOS SDK ────────────────────────────────────────────────
echo "【1】OpenHarmony SDK（提供 hdc + llvm 交叉工具链）"
if [ -f "${SDK_TGZ}" ]; then
  SIZE=$(stat -c %s "${SDK_TGZ}" 2>/dev/null || stat -f %z "${SDK_TGZ}")
  # 官方 7.0-Release 的完整大小，用于判断是否下完
  EXPECT=3384355680
  if [ "${SIZE}" -ge "${EXPECT}" ]; then
    ok "ohos-sdk.tar.gz 完整（$(numfmt --to=iec "${SIZE}" 2>/dev/null || echo "${SIZE}B")）"
  else
    bad "ohos-sdk.tar.gz 未下完（${SIZE}/${EXPECT}，$(awk "BEGIN{printf \"%.1f\", ${SIZE}/${EXPECT}*100}")%）"
  fi
else
  bad "缺 ${SDK_TGZ}"
  info "下载：curl -L -o ${SDK_TGZ} https://repo.huaweicloud.com/openharmony/os/7.0-Release/ohos-sdk-windows_linux-public.tar.gz"
fi

# 解压后的关键二进制
HDC=$(find "${SDK_DIR}" -name hdc -type f 2>/dev/null | head -1)
CLANG=$(find "${SDK_DIR}" -name 'aarch64-unknown-linux-ohos-clang' -type f 2>/dev/null | head -1)
if [ -n "${HDC}" ]; then ok "hdc: ${HDC}"; else bad "hdc 未找到（SDK 未解压？）"; fi
if [ -n "${CLANG}" ]; then
  ok "交叉编译器: ${CLANG}"
  if "${CLANG}" --version 2>/dev/null | head -1 | grep -qi clang; then
    ok "  可执行（$( "${CLANG}" --version 2>/dev/null | head -1 )）"
  else
    bad "  存在但无法执行（可能缺宿主依赖）"
  fi
else
  bad "aarch64-unknown-linux-ohos-clang 未找到"
fi

# ── 2. Flutter 3.22(ohos) ──────────────────────────────────────
echo
echo "【2】Flutter 3.22.1-ohos（P0 的 dart analyze 需要它）"
if [ -d "${FLUTTER322}/packages/flutter" ]; then
  BRANCH=$(git -C "${FLUTTER322}" rev-parse --abbrev-ref HEAD 2>/dev/null)
  ok "源码存在，分支：${BRANCH:-未知}"
  if [ -d "${FLUTTER322}/packages/flutter_tools" ]; then
    ok "flutter_tools 存在"
  else
    bad "缺 flutter_tools（sparse-checkout 未关闭）"
    info "修复：cd ${FLUTTER322} && git sparse-checkout disable"
  fi
  if [ -x "${FLUTTER322}/bin/cache/dart-sdk/bin/dart" ]; then
    ok "内置 Dart: $( "${FLUTTER322}/bin/cache/dart-sdk/bin/dart" --version 2>&1 | head -1 )"
  else
    bad "Dart SDK 未就绪（首次运行 flutter 会下载）"
    info "修复：${FLUTTER322}/bin/flutter --version"
  fi
else
  bad "缺 ${FLUTTER322}"
  info "克隆：git clone --depth 1 -b 3.22.1-ohos-0.1.0 https://gitee.com/openharmony-sig/flutter_flutter.git ${FLUTTER322}"
fi

# ── 3. 构建工具 ────────────────────────────────────────────────
echo
echo "【3】构建工具"
if [ -d "${WORK}/ohos-tools/node_modules/@ohos/hvigor" ]; then
  VER=$(node -p "require('${WORK}/ohos-tools/node_modules/@ohos/hvigor/package.json').version" 2>/dev/null)
  ok "hvigor ${VER}"
else
  bad "hvigor 未安装"
  info "安装：cd ${WORK}/ohos-tools && npm install --registry=https://repo.harmonyos.com/npm/ @ohos/hvigor @ohos/hvigor-ohos-plugin"
fi
if command -v ohpm >/dev/null 2>&1; then ok "ohpm: $(command -v ohpm)"; else info "ohpm 未装（只影响 HAR 依赖，不阻塞 dart analyze）"; fi

# ── 4. 设备 ────────────────────────────────────────────────────
echo
echo "【4】鸿蒙设备（P3 才必需，P0/P1 不需要）"
if [ -n "${HDC}" ]; then
  TARGETS=$( "${HDC}" list targets 2>/dev/null | grep -v '^\s*$' | grep -v 'Empty' || true )
  if [ -n "${TARGETS}" ]; then
    ok "已连接："
    echo "${TARGETS}" | sed 's/^/      /'
  else
    info "无设备（正常，P0 不需要）"
    info "接入方式：USB 直连，或 hdc tconn <ip>:<port>（设备需开开发者模式）"
  fi
fi

# ── 5. 结论 ────────────────────────────────────────────────────
echo
echo "═════ 结论 ═════"
if [ "${MISSING}" -eq 0 ]; then
  echo "  全部就绪，可以开始 P0。"
  echo "  下一步：\$FLUTTER322/bin/flutter analyze --no-pub"
  exit 0
else
  echo "  有 ${MISSING} 项缺失（上面标 ✗）。"
  echo "  注意：设备缺失不影响 P0 的 dart analyze。"
  exit 1
fi
