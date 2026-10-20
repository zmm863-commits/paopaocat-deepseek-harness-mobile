#!/usr/bin/env node
/**
 * 校验「注入到 Bot 网页的那段 JS」**能真的跑**（语法层面）。
 *
 * 为什么需要它（2026-10-20 两次事故）：
 *   1. 108 版：Dart 原始字符串里把 `\n` 写成真换行 → 整段语法错误、注入全灭（表面看"改了没用"）；
 *   2. 120 版：注释里写出了占位符名字，而替换用的是 replaceFirst → 命中的是**注释**，
 *      多行 CSS 被塞进 `//` 后面，后面几行变成裸代码 → 整段语法错误、**一条注入都不生效**
 *      （用户看到的就是「Bot 页面又回到过去了」）。
 *
 * 这类错 `flutter analyze` 抓不到、`flutter test` 也抓不到（它只是 Dart 里的一段字符串）。
 * 所以用一个 node 脚本：抽出模板 → 用真实形状的令牌填充 → 交给 node 的解析器过一遍。
 *
 * 用法：node install/check-bot-patch.mjs
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const src = readFileSync(resolve(root, 'app/lib/ui/pages/bot_page.dart'), 'utf8');

const m = src.match(/static const String _webPatchTemplate = r"""([\s\S]*?)""";/);
if (!m) {
  console.error('✗ 没找到 _webPatchTemplate');
  process.exit(1);
}
const tpl = m[1];

// 与 _tokensCss() 同形状的令牌（多行 + rgba，正是踩坑那种）
const tokens =
  'body{\n' +
  '    --bt-main: #101418;\n' +
  '    --bt-ink: #E8EDF2;\n' +
  '    --bt-hover: rgba(212, 232, 255, 0.08);\n' +
  '    }\n' +
  'body[data-ds-dark-theme]{\n' +
  '    --bt-main: #101418;\n' +
  '    }';

const js = tpl
  .replaceAll('__DSH_APP_DARK__', 'true')
  .replaceAll('__DSH_TOKENS_CSS__', tokens);

let fail = 0;
const bad = (msg) => { console.error('✗ ' + msg); fail++; };

// ① 占位符不许残留
const left = js.match(/__DSH_[A-Z_]+__/g);
if (left) bad(`还有未替换的占位符：${[...new Set(left)].join(', ')}`);

// ② 反引号必须成对（CSS 多行里出现反引号会截断模板）
const ticks = (tpl.match(/`/g) || []).length;
if (ticks % 2 !== 0) bad(`模板里的反引号数量是奇数（${ticks}）—— 模板字符串会被截断`);

// ③ 真正的判据：交给 node 解析器
try {
  new Function(js);
} catch (e) {
  bad(`语法错误：${e.name}: ${e.message}`);
  // 把出错位置附近的原文打出来，省得再猜
  const line = Number((e.stack.match(/:(\d+)\n/) || [])[1] || 0);
  if (line) {
    const lines = js.split('\n');
    console.error(`  第 ${line} 行：${(lines[line - 1] || '').slice(0, 120)}`);
  }
}

// ④ 关键注入步骤必须真的在代码里（防"注释里有、代码里没有"）
for (const must of ['dsh-mobile-fit', 'dsh-app-tokens', 'renamePlusMenu(', 'sweep();']) {
  if (!js.includes(must)) bad(`注入脚本里缺少关键片段：${must}`);
}

if (fail) {
  console.error(`\n共 ${fail} 个问题 —— 这段注入到了手机上会整体失效。`);
  process.exit(1);
}
console.log(`✅ 注入脚本可解析（${js.length} 字符，反引号 ${ticks} 个成对）`);
