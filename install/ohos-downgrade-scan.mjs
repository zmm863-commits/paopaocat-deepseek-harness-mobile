#!/usr/bin/env node
/**
 * ohos-downgrade-scan.mjs —— Flutter 3.47 → 3.22(ohos) 降级影响扫描器。
 *
 * 为什么要有它：鸿蒙 Flutter 分支（openharmony-sig/flutter_flutter）最高只到
 * 3.22.1-ohos-0.1.0，本项目在 3.47.6 / Dart 3.13.5。凭记忆判断"哪些 API 会崩"
 * 不可靠，所以把判断依据固化成可复跑的扫描：每次升级/降级都跑一遍，看数字。
 *
 * 用法：
 *   node install/ohos-downgrade-scan.mjs                # 扫 app/ 目录
 *   node install/ohos-downgrade-scan.mjs --json         # 机器可读输出
 *   node install/ohos-downgrade-scan.mjs --dir app/lib  # 指定目录
 *
 * 退出码：0 = 无阻塞项；1 = 存在"必须重写"项（Process.start / MethodChannel / 无 ohos 实现的插件）
 *
 * 判定口径：
 *   [阻塞] 鸿蒙上没有等价实现，或必须换成完全不同的调用方式（改不改都得改）
 *   [移植] 有等价物，但要改代码（工作量可估）
 *   [零改] 直接可用
 *   [检查] 需要人工确认，脚本给不出确定结论
 */

import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const args = process.argv.slice(2);
const JSON_OUT = args.includes('--json');
const dirArg = args.indexOf('--dir');
const SCAN_DIR = dirArg >= 0 ? join(ROOT, args[dirArg + 1]) : join(ROOT, 'app');
const PUBSPEC = join(ROOT, 'app', 'pubspec.yaml');

/** 递归收集 .dart 文件（跳过 build/ 与 .dart_tool/）。 */
function walk(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    if (name === 'build' || name === '.dart_tool' || name.startsWith('.')) continue;
    const full = join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) walk(full, out);
    else if (extname(name) === '.dart') out.push(full);
  }
  return out;
}

/**
 * 已知插件在鸿蒙上的状态。
 * 来源：openharmony-sig/flutter_packages 的 br_*_ohos 分支 + 各上游仓库。
 * 这张表是本脚本唯一的"外部知识"，其余全部从代码里算出来。
 */
const PLUGIN_MATRIX = {
  'shared_preferences': { status: '零改', note: 'SIG 有 ohos 2.3.2，API 一致' },
  'webview_flutter': { status: '移植', note: 'SIG 分支基于 4.8.0；项目只用基础 API，需确认 setOnShowFileSelector' },
  'webview_flutter_android': { status: '移植', note: 'Android 专属包，鸿蒙要换成 platform channel 自实现' },
  'flutter_secure_storage': { status: '移植', note: '无官方 ohos 包，需自写（read/write/delete，约 80 行）' },
  'file_picker': { status: '移植', note: '无 ohos 版；改 file_selector_ohos 或自写' },
  'sherpa_onnx': { status: '移植', note: 'pub 无 ohos；upstream 有 harmony-os/SherpaOnnxTts HAR，需自桥接' },
  'web_socket_channel': { status: '零改', note: '纯 Dart' },
  'provider': { status: '零改', note: '纯 Dart' },
  'crypto': { status: '零改', note: '纯 Dart' },
  'cupertino_icons': { status: '零改', note: '纯资源' },
};

/** Dart 3.4（Flutter 3.22 内置）之后才有的语言特性。命中即降级后编译失败。 */
const DART_NEW_SYNTAX = [
  { name: '数字分隔符 1_000_000', re: /(?<![\w'"`.\/])[0-9]+_[0-9]{3}/g, since: 'Dart 3.6' },
  { name: 'null-aware 集合元素 [?x / ?{k: v}', re: /\[\s*\?[a-zA-Z_$]|\{\s*\?[a-zA-Z_$]/g, since: 'Dart 3.8' },
  { name: 'dot shorthands（省略类型 .value）', re: /[(,=\[]\s*\.[a-zA-Z_][a-zA-Z0-9_]*(?=\s*[,)\];])/g, since: 'Dart 3.10' },
];

/** 必须从"子进程模型"改写为"进程内模型"的调用点。 */
const SUBPROCESS_PATTERNS = [
  { name: 'Process.start', re: /\bProcess\.start\s*\(/g },
  { name: 'Process.run', re: /\bProcess\.run\s*\(/g },
  { name: 'Process.runSync', re: /\bProcess\.runSync\s*\(/g },
  { name: 'Process.killPid', re: /\bProcess\.killPid\s*\(/g },
];

/** 平台通道：Kotlin 侧在鸿蒙上要整体换成 ArkTS。 */
const CHANNEL_PATTERNS = [
  { name: 'MethodChannel', re: /\bMethodChannel\s*\(/g },
  { name: 'EventChannel', re: /\bEventChannel\s*\(/g },
  { name: 'BasicMessageChannel', re: /\bBasicMessageChannel\s*\(/g },
  { name: 'AndroidOptions/Android 专属参数', re: /\bAndroidOptions\b|\bandroidOptions\b/g },
];

/**
 * 把字符串字面量与注释替换成等长空白，保留换行与偏移。
 *
 * 为什么必须做：语法扫描若在字符串/注释里命中（例如中文文案里的 `（.pptx）` 会被
 * dot-shorthand 规则当成语法），结论就会假阳性。等长替换保证行号仍然正确。
 * 这不是完整 lexer —— 不处理嵌套的 `$"..."` 插值内部，但足以覆盖本项目。
 */
function blankOutStringsAndComments(src) {
  const out = [...src];
  const blank = (i) => { if (out[i] !== '\n') out[i] = '\u0001'; };
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    const next = src[i + 1];
    // 行注释
    if (c === '/' && next === '/') {
      while (i < n && src[i] !== '\n') { blank(i); i++; }
      continue;
    }
    // 块注释
    if (c === '/' && next === '*') {
      blank(i); blank(i + 1); i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) { blank(i); i++; }
      blank(i); if (i + 1 < n) blank(i + 1);
      i += 2;
      continue;
    }
    // 单/双引号字符串（含三引号）
    if (c === "'" || c === '"') {
      const triple = src.slice(i, i + 3) === c.repeat(3);
      const q = triple ? c.repeat(3) : c;
      let j = i;
      for (let k = 0; k < q.length; k++) blank(j++);
      while (j < n) {
        if (!triple && src[j] === '\\') { blank(j); blank(j + 1); j += 2; continue; }
        if (src.startsWith(q, j)) {
          for (let k = 0; k < q.length; k++) blank(j++);
          break;
        }
        blank(j++);
      }
      i = j;
      continue;
    }
    i++;
  }
  return out.join('');
}

function scanFile(file, src, rules) {
  const code = blankOutStringsAndComments(src);
  const hits = [];
  for (const rule of rules) {
    rule.re.lastIndex = 0;
    let m;
    while ((m = rule.re.exec(code)) !== null) {
      const line = code.slice(0, m.index).split('\n').length;
      hits.push({ rule: rule.name, since: rule.since, line, text: m[0].trim().slice(0, 80) });
      if (hits.length > 500) break; // 防御：异常文件不至于卡死
    }
  }
  return hits;
}

// ─────────────────────────────────────────────────────────────────────────────
// --framework 模式：用真实的 3.22 framework 源码，逐个核对项目用到的 Flutter 符号。
//
// 为什么单独一个模式：语言层扫完是 0 处，但那只能证明"语法没超纲"；真正决定
// 编译能不能过的是 **framework API 是否存在**。凭记忆判断哪些 widget 是 3.22 之后
// 新增的不可靠，所以直接拿 3.22 的 lib/ 源码当真相源。
//
// 用法：
//   node install/ohos-downgrade-scan.mjs --framework /tmp/flutter-ohos/packages/flutter/lib
//   可选 --dart-sdk <path>（默认 /opt/flutter/bin/cache/dart-sdk/lib）
// ─────────────────────────────────────────────────────────────────────────────
const fwIdx = args.indexOf('--framework');
if (fwIdx >= 0) {
  const fwDir = args[fwIdx + 1];
  const sdkIdx = args.indexOf('--dart-sdk');
  const dartSdkDir = sdkIdx >= 0 ? args[sdkIdx + 1] : '/opt/flutter/bin/cache/dart-sdk/lib';
  const DEF_RE = /^(?:abstract\s+|sealed\s+|final\s+|base\s+|interface\s+|mixin\s+)*(?:class|mixin|enum|typedef|extension\s+type|extension)\s+([A-Za-z_][A-Za-z0-9_]*)/gm;

  const collectDefs = (dir) => {
    const set = new Set();
    for (const f of walk(dir)) {
      const src = readFileSync(f, 'utf8');
      DEF_RE.lastIndex = 0;
      let m;
      while ((m = DEF_RE.exec(src))) set.add(m[1]);
    }
    return set;
  };

  const fwDefs = collectDefs(fwDir);
  const coreDefs = existsSync(dartSdkDir) ? collectDefs(dartSdkDir) : new Set();

  // dart:ui 是 engine 提供的（Color/FontWeight/Offset/VoidCallback 都在这里），
  // 不在 framework 的 lib/ 内。3.22 的 dart:ui 随 engine 产物发布、源码不在此分支，
  // 所以默认借用本机 sky_engine —— 这些基础绘图/回调类型跨版本稳定，不影响判定。
  const uiIdx = args.indexOf('--dart-ui');
  const dartUiDir = uiIdx >= 0 ? args[uiIdx + 1] : '/opt/flutter/bin/cache/pkg/sky_engine/lib/ui';
  if (existsSync(dartUiDir)) for (const d of collectDefs(dartUiDir)) coreDefs.add(d);

  // 项目自定义类（含 app/ 全部，避免把自家类当成缺失的框架符号）
  const ownDefs = new Set();
  for (const f of walk(join(ROOT, 'app'))) {
    const src = readFileSync(f, 'utf8');
    DEF_RE.lastIndex = 0;
    let m;
    while ((m = DEF_RE.exec(src))) ownDefs.add(m[1]);
  }

  // 插件导出的符号（这些缺失属插件问题，不算 framework 缺口）
  const pluginSyms = new Set();
  for (const f of walk(join(ROOT, 'app', 'lib'))) {
    const src = readFileSync(f, 'utf8');
    if (!/^import 'package:(?!flutter\/)/m.test(src)) continue;
  }

  const TOKEN_RE = /\b([A-Z][A-Za-z0-9_]{2,})\b/g;
  const usedByFile = new Map();
  for (const f of walk(join(ROOT, 'app', 'lib'))) {
    const raw = readFileSync(f, 'utf8');
    if (!raw.includes("package:flutter/")) continue; // 只关心 import 了 flutter 的文件
    const code = blankOutStringsAndComments(raw);
    TOKEN_RE.lastIndex = 0;
    let m;
    while ((m = TOKEN_RE.exec(code))) {
      const sym = m[1];
      if (!usedByFile.has(sym)) usedByFile.set(sym, new Set());
      usedByFile.get(sym).add(relative(ROOT, f));
    }
  }

  const missing = [];
  let known = 0;
  for (const [sym, files] of usedByFile) {
    if (ownDefs.has(sym) || fwDefs.has(sym) || coreDefs.has(sym)) { known++; continue; }
    missing.push({ sym, count: files.size, sample: [...files].slice(0, 3) });
  }
  missing.sort((a, b) => b.count - a.count);

  console.log('═══ Framework 符号兼容性（对照真实的 3.22 源码）═══\n');
  console.log(`3.22 framework 定义符号：${fwDefs.size}`);
  console.log(`Dart 核心库 + dart:ui 定义符号：${coreDefs.size}`);
  console.log(`项目自定义符号：${ownDefs.size}`);
  console.log(`项目在 flutter 文件里用到的符号：${usedByFile.size}`);
  console.log(`  ├ 能在 3.22 / Dart 核心 / 项目自身找到：${known}`);
  console.log(`  └ 找不到（需人工确认来源）：${missing.length}\n`);
  if (missing.length) {
    console.log('── 待确认符号（前 40，按出现文件数排序）──');
    for (const it of missing.slice(0, 40)) {
      console.log(`   ${it.sym.padEnd(30)} ${String(it.count).padStart(3)} 文件  e.g. ${it.sample[0]}`);
    }
    console.log('\n   注意：这些大多来自插件（如 WebViewController）或 Dart 内置类型别名，');
    console.log('   不等于"3.22 缺这个 Flutter API"。要区分请人工看一眼样本文件。');
  }
  process.exit(0);
}

// ── 主流程 ────────────────────────────────────────────────────────────────

const dartFiles = walk(SCAN_DIR);
const report = { scanned: SCAN_DIR, files: dartFiles.length, lines: 0, syntax: [], subprocess: [], channels: [], plugins: [], blockers: 0 };

for (const f of dartFiles) {
  const src = readFileSync(f, 'utf8');
  report.lines += src.split('\n').length;
  const rel = relative(ROOT, f);

  const syntax = scanFile(f, src, DART_NEW_SYNTAX);
  const sub = scanFile(f, src, SUBPROCESS_PATTERNS);
  const ch = scanFile(f, src, CHANNEL_PATTERNS);

  for (const h of syntax) report.syntax.push({ file: rel, ...h });
  for (const h of sub) report.subprocess.push({ file: rel, ...h });
  for (const h of ch) report.channels.push({ file: rel, ...h });
}

// 插件面
if (existsSync(PUBSPEC)) {
  const pub = readFileSync(PUBSPEC, 'utf8');
  const depBlock = (pub.match(/^dependencies:\n([\s\S]*?)^\S/m) || [, ''])[1];
  for (const line of depBlock.split('\n')) {
    const m = line.match(/^\s{2}([a-z0-9_]+):/);
    if (!m) continue;
    const name = m[1];
    if (name === 'flutter' || name === 'sdk') continue;
    const known = PLUGIN_MATRIX[name];
    report.plugins.push({ name, ...(known ?? { status: '检查', note: '未在已知矩阵中，需确认是否有 ohos 实现' }) });
  }
}

report.blockers =
  report.subprocess.length +
  report.channels.length +
  report.plugins.filter((p) => p.status === '阻塞').length +
  report.syntax.length;

if (JSON_OUT) {
  console.log(JSON.stringify(report, null, 2));
} else {
  const pad = (s, n) => String(s).padEnd(n);
  console.log('═══ Flutter 3.47 → 3.22(ohos) 降级影响扫描 ═══\n');
  console.log(`扫描目录：${relative(ROOT, report.scanned) || '.'}`);
  console.log(`Dart 文件：${report.files} 个，共 ${report.lines} 行\n`);

  const section = (title, items, render) => {
    console.log(`── ${title}（${items.length}）──`);
    if (!items.length) { console.log('   无\n'); return; }
    for (const it of items) console.log('   ' + render(it));
    console.log();
  };

  section('Dart 新语法（3.4 不支持 = 编译失败）', report.syntax,
    (h) => `${h.file}:${h.line}  ${h.rule} · ${h.since}  →  ${h.text}`);

  section('子进程调用（鸿蒙手机禁 exec，必须改为进程内）', report.subprocess,
    (h) => `${h.file}:${h.line}  ${h.rule}`);

  section('平台通道（Kotlin 侧要整体换 ArkTS）', report.channels,
    (h) => `${h.file}:${h.line}  ${h.rule}`);

  console.log(`── 插件矩阵（${report.plugins.length}）──`);
  for (const p of report.plugins) console.log(`   ${pad(p.name, 28)} [${p.status}] ${p.note}`);
  console.log();

  const isProd = (f) => f.file.startsWith('app/lib/');
  const split = (arr) => ({ prod: arr.filter(isProd).length, test: arr.length - arr.filter(isProd).length });
  const sp = split(report.subprocess);
  const ch = split(report.channels);

  console.log('═══ 生产代码 vs 测试代码 ═══');
  console.log(`   Process.*  生产 ${sp.prod} 处 / 测试 ${sp.test} 处`);
  console.log(`   平台通道    生产 ${ch.prod} 处 / 测试 ${ch.test} 处`);
  console.log('   （测试代码在鸿蒙上不需要真跑，只需保证不参与构建）\n');

  console.log('═══ 结论 ═══');
  const counts = report.plugins.reduce((a, p) => ((a[p.status] = (a[p.status] || 0) + 1), a), {});
  console.log(`   语法风险：${report.syntax.length} 处 ${report.syntax.length === 0 ? '（语言层无阻塞）' : '← 需要改'}`);
  console.log(`   必须改写的子进程调用：${report.subprocess.length} 处`);
  console.log(`   必须改写的平台通道：${report.channels.length} 处`);
  console.log(`   插件：` + Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(' / '));
  console.log(`\n   阻塞项合计：${report.blockers}`);
}

process.exit(report.blockers > 0 ? 1 : 0);

