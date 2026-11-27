#!/usr/bin/env node
/**
 * webview-compat-probe.mjs —— 验证 Bot 页注入的「老 WebView 兼容补丁」真的能补上。
 *
 * ## 为什么要这个探针
 *
 * 2026-11-18 真机报告（华为 ELS-AN00 / Android 12）：点 Bot 页 ⋮ →「添加工作区…」，
 * 「选择工作区目录」对话框**空的**，框里一行红字 `AbortSignal.any is not a function`。
 * 根因是网页 bundle 里的 `@deepseek-ai/dsh-api-gateway` 在"调用方带 signal"时用
 * `AbortSignal.any([...])`（Chromium 116 才有），而那台手机的 WebView 比它老。
 *
 * 修法是在 `onPageStarted` 注入 `_compatJs`（`app/lib/ui/pages/bot_page.dart`）。
 * 但那份补丁是 Dart 文件里的一段**原始字符串** —— 语法错、少个分号、把 `typeof`
 * 写成 `typeof(` 全都只会在真机上安静地失效，跟没写一样。所以在这里**把那段 JS
 * 抠出来、在 node 里按"老 WebView"跑一遍**：先删掉这些 API，再执行补丁，
 * 然后逐条真的调用一次（不是只看 typeof）。
 *
 * 跑法：`node probes/webview-compat-probe.mjs` —— 全绿即补丁可用，任何一条 FAIL 退出码 1。
 *
 * ⚠️ 这是**探针不是单测**：不进 `flutter test`，因为它需要 node 起一个真实 JS 引擎。
 */

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { randomFillSync } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const dartPath = join(here, '..', 'app', 'lib', 'ui', 'pages', 'bot_page.dart');
const marker = 'static const String _compatJs = r"""';

/** 从 Dart 源码里抠出 _compatJs 那段原始字符串。 */
function extractCompatJs() {
  const src = readFileSync(dartPath, 'utf8');
  const start = src.indexOf(marker);
  if (start < 0) throw new Error(`在 ${dartPath} 里找不到 _compatJs（改名了？探针要跟着改）`);
  const from = start + marker.length;
  const end = src.indexOf('""";', from);
  if (end < 0) throw new Error('_compatJs 的结尾 """ 没找到');
  return src.slice(from, end);
}

let failed = 0;
function check(label, ok, detail = '') {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` → ${detail}` : ''}`);
  if (!ok) failed += 1;
}

const js = extractCompatJs();

// ── 1) 在真 node 里跑（node 自带的那些 API 删掉，模拟老 WebView）
globalThis.window = globalThis;
delete AbortSignal.any;
delete AbortSignal.timeout;
delete Promise.withResolvers;
delete Object.hasOwn;
delete globalThis.structuredClone;
delete Array.prototype.findLast;
delete Array.prototype.findLastIndex;

const installed = eval(js);
check('补丁自报装了哪几个', typeof installed === 'string' && installed !== '无缺失', installed);

const ctrl = new AbortController();
const merged = AbortSignal.any([ctrl.signal, new AbortController().signal]);
check('AbortSignal.any 合并后初始未中止', merged.aborted === false);
ctrl.abort();
check('AbortSignal.any 随源 signal 中止', merged.aborted === true);

const dead = new AbortController();
dead.abort();
check('AbortSignal.any 传已中止的 signal', AbortSignal.any([dead.signal]).aborted === true);

const timeoutSignal = AbortSignal.timeout(30);
await new Promise((r) => setTimeout(r, 80));
check('AbortSignal.timeout 到点会中止', timeoutSignal.aborted === true);

const { promise, resolve } = Promise.withResolvers();
resolve(42);
check('Promise.withResolvers 可用', (await promise) === 42);

check('Object.hasOwn 可用', Object.hasOwn({ a: 1 }, 'a') === true);
check('Object.hasOwn 不误判原型链', Object.hasOwn({}, 'toString') === false);

const src = { x: 1, y: [2, 3] };
const copied = structuredClone(src);
check('structuredClone 深拷贝', JSON.stringify(copied) === '{"x":1,"y":[2,3]}' && copied.y !== src.y);

check('Array.findLast 可用', [1, 5, 2, 5].findLast((v) => v === 5) === 5);
check('Array.findLastIndex 可用', [1, 5, 2, 5].findLastIndex((v) => v === 5) === 3);

check('重复注入幂等（第二次应报「无缺失」）', eval(js) === '无缺失');

// ── 2) crypto.randomUUID：node 里删不掉，另开一个沙箱专门测这条分支
const sandbox = {
  console, setTimeout, clearTimeout, DOMException, Error, JSON, Math,
  AbortController, AbortSignal, Promise, Object, Array, Uint8Array,
};
sandbox.window = sandbox;
sandbox.crypto = { getRandomValues: (b) => randomFillSync(b) };
vm.createContext(sandbox);
vm.runInContext(js, sandbox);
const uuid = sandbox.crypto.randomUUID();
check(
  'crypto.randomUUID 格式正确',
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid),
  uuid,
);
const seen = new Set();
for (let i = 0; i < 500; i += 1) seen.add(sandbox.crypto.randomUUID());
check('crypto.randomUUID 500 次无重复', seen.size === 500);

console.log('');
if (failed > 0) {
  console.error(`${failed} 条没过 —— 补丁在真机上会安静地失效，先修 _compatJs。`);
  process.exit(1);
}
console.log('全部通过：这段补丁可以补上老 WebView 缺的 7 个 API。');
