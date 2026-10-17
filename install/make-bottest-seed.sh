#!/usr/bin/env bash
# 造「bottest profile 种子」目录 —— 手机上的 Bot 页面靠它把 dsh web + ds-bot 跑起来。
#
# 为什么要有这个脚本：种子最初是一次性手工拼出来的（直接 cp + 手写三个文件），
# 而它**不在 git 里**（是 /tmp 下的构建输入）。一旦 /tmp 被清掉，就再也没法复现
# 那份运行时包。所以把「种子由什么组成」固化成脚本，见 README 式的注释如下。
#
# 种子内容（四样东西）：
#   ① `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app` —— DSH web 本体（来自运行时，
#      不用拷，只用写进 bundles）；
#   ② `ds-bot` —— Bot 团队插件（第三方，Fei2411/DeepSeek-Bot，Apache-2.0）；
#      **必须放在 profile 自己的 node_modules 下**：DSH 的插件名解析锚定 profile 目录；
#   ③ `dsh-client-ui-mobile` —— 窄屏布局增强（悬浮导航 + 窄屏 CSS）；
#   ④ `dsh-client-ui-paopaocat` —— 泡泡猫玻璃主题（用户自研，MIT）。
#      没它的话 WebView 里就是「另一个网页」的观感，与 App 风格完全不搭
#      （用户真机原话：「像是强行塞了一个页面」）。
#
# 用法：install/make-bottest-seed.sh [插件来源目录] [输出目录]
#   默认 来源 = /dsh/profiles/web/node_modules（本机在用的 web profile，插件都在那儿）
#   默认 输出 = /tmp/seed-bottest
set -euo pipefail

SRC="${1:-/dsh/profiles/web/node_modules}"
OUT="${2:-/tmp/seed-bottest}"

# 直属于 profile/node_modules 的插件（裸包名 + 第三方）
PLUGINS=(ds-bot dsh-client-ui-mobile dsh-client-ui-paopaocat)

# 带 @deepseek-ai scope 的插件：**也必须放 profile 自己的 node_modules**。
# ⚠️ 这是本机实测出来的关键区别：profile 的 `package.json` 里 bundles 能按**主包**解析
#    （所以 `@deepseek-ai/dsh-base`/`dsh-web-app` 不用拷），但 `cordis.patch.yml` 里
#    `- insert:` 的插件是按 **profile 目录**解析的 —— 包不在 profile/node_modules 下
#    就会 `failed to import`（`web-search-anysearch` 就是这么栽的）。
#    包名 → 要拷的目录（来自运行时主包 node_modules）
SCOPED=(dsh-web-search-anysearch)

for p in "${PLUGINS[@]}"; do
  [ -d "$SRC/$p" ] || { echo "✗ 找不到插件：$SRC/$p" >&2; exit 1; }
done
# scoped 的那些来源是「运行时主包」（由第三个参数指定），默认取本机 runtime 解压目录
RUNTIME_SRC="${3:-/tmp/vr2/dsh/node_modules/@deepseek-ai}"
for p in "${SCOPED[@]}"; do
  [ -d "$RUNTIME_SRC/$p" ] || { echo "⚠️ 找不到 $RUNTIME_SRC/$p（跳过）" >&2; }
done

echo "== 清空并重建 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/node_modules"

for p in "${PLUGINS[@]}"; do
  # ⚠️ 必须先删目标目录：`cp -a src dst` 在 dst 已存在时会在里面套一层同名子目录
  #（见记忆里的「手工替换插件」坑），这里 rm -rf 已保证干净，再拷。
  cp -a "$SRC/$p" "$OUT/node_modules/$p"
  echo "   + $p（$(du -sh "$OUT/node_modules/$p" | cut -f1)）"
done

mkdir -p "$OUT/node_modules/@deepseek-ai"
for p in "${SCOPED[@]}"; do
  [ -d "$RUNTIME_SRC/$p" ] || continue
  cp -a "$RUNTIME_SRC/$p" "$OUT/node_modules/@deepseek-ai/$p"
  echo "   + @deepseek-ai/$p（$(du -sh "$OUT/node_modules/@deepseek-ai/$p" | cut -f1)）"
done

cat > "$OUT/package.json" <<'JSON'
{
  "name": "dsh-profile-bottest",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
        "dsh-client-ui-mobile",
        "dsh-client-ui-paopaocat"
      ]
    }
  }
}
JSON

cat > "$OUT/cordis.yml" <<'YAML'
# dsh profile root — an empty entry list. The tree is composed as patches:
# each bundle in package.json's dsh.profile.bundles, then cordis.patch.yml, then any
# --patch overlays. Edit cordis.patch.yml, not this file.
[]
YAML

cat > "$OUT/cordis.patch.yml" <<'YAML'
# bottest：web 模板 + ds-bot（Bot 团队）+ 窄屏/主题 —— 手机上 Bot 页面的最小组合。
- id: typert-gateway
  config:
    websocketHeartbeatIntervalMs: 30000
- insert:
    - id: bot
      name: ds-bot
    - id: web-search-auto
      name: ds-bot/web-search
YAML

echo "== 自检"
for f in package.json cordis.yml cordis.patch.yml; do
  [ -f "$OUT/$f" ] || { echo "✗ 缺 $OUT/$f" >&2; exit 1; }
done
for p in "${PLUGINS[@]}"; do
  [ -f "$OUT/node_modules/$p/package.json" ] || { echo "✗ 缺 $p/package.json" >&2; exit 1; }
done
[ -f "$OUT/node_modules/ds-bot/client.js" ] || { echo "✗ ds-bot 缺 client.js" >&2; exit 1; }
for p in "${SCOPED[@]}"; do
  [ -d "$RUNTIME_SRC/$p" ] && { [ -f "$OUT/node_modules/@deepseek-ai/$p/package.json" ] || { echo "✗ 缺 @deepseek-ai/$p" >&2; exit 1; }; }
done
echo "✓ 种子就绪：$OUT（$(du -sh "$OUT" | cut -f1)）"
echo "  接下来：install/build-runtime-with-bottest.sh"
