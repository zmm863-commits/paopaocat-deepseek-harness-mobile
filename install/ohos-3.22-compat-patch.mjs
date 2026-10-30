#!/usr/bin/env node
/**
 * ohos-3.22-compat-patch.mjs —— 把 Flutter 3.47 的 API 调用改写成 3.22 可用的形式。
 *
 * 为什么需要它：`flutter analyze` 在 3.22 下报出的 139 个问题里，98 个集中在
 * Color 的两套 API 上（3.27 引入 withValues/toARGB32，取代旧的 withOpacity/value）。
 * 这些是**纯机械替换**，但必须实测验证替换后 analyze 归零，不能靠猜。
 *
 * 替换规则表（每条都对应 Flutter 官方 breaking change）：
 *
 *   Color.withValues(alpha: a)      → Color.withOpacity(a)
 *      3.27 起 withValues 取代 withOpacity。withValues 的 alpha 是 double 0..1，
 *      withOpacity 同样是 double 0..1 —— 语义一致，直接换。
 *      ⚠️ withValues 还支持 red/green/blue/width/height/colorSpace 等参数，
 *         本项目**只用到 alpha**，所以可以安全机械替换；脚本遇到非 alpha 形态会
 *         跳过并报告，不做猜测。
 *
 *   Color.toARGB32()               → Color.value
 *      3.27 起 toARGB32 取代 .value（同样是 int ARGB 打包值）。
 *
 *   Color.r/.g/.b/.a                → .red/.green/.blue/.alpha
 *      3.27 起分量访问器从单字母改为全名（单字母与旧的 Color.value 通道冲突）。
 *
 *   CardThemeData/TabBarThemeData/DialogThemeData → CardTheme/TabBarTheme/DialogTheme
 *      3.27 的 Material 主题重构：老类加 Data 后缀。3.22 只有老名字。
 *
 * ┌── 目标版本选择 ──────────────────────────────────────────────┐
 * │ --target 3.27  （推荐）只改 3 类 API，生产代码 6 处：            │
 * │      DropdownButtonFormField.initialValue → value              │
 * │      Color.toARGB32() → .value                                  │
 * │      Switch.activeThumbColor → activeColor                      │
 * │   因为 3.27 已经有 withValues / CardThemeData，那些不用动。       │
 * │                                                                 │
 * │ --target 3.22  （旧）需要额外改 withValues/toARGB32/主题类名      │
 * │   共 127 处。仅当必须用 3.22 分支时使用。                         │
 * └─────────────────────────────────────────────────────────────────┘
 *
 * 用法：
 *   node install/ohos-3.22-compat-patch.mjs --dir /path/to/app        # 就地改（先备份）
 *   node install/ohos-3.22-compat-patch.mjs --dir app --dry-run       # 只报告
 *   node install/ohos-3.22-compat-patch.mjs --dir app --no-backup     # 不备份
 *   node install/ohos-3.22-compat-patch.mjs --dir app --keep-theme    # 保留 3.47 的主题类名
 *
 * 双向兼容性（已实测）：
 *   除 CardThemeData/TabBarThemeData/DialogThemeData 三个改名外，本脚本的**全部**替换在
 *   Flutter 3.22 和 3.47 上都能编译（旧 API 在 3.47 只是标 @Deprecated，没删）。
 *   ⇒ 可以用 --keep-theme 先对主干预应用，Android 构建不受影响；等真降级时再补那 3 行。
 *
 * 退出码：0 = 全部改完（或 dry-run 报告完）；2 = 有无法机械处理的项
 */

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, copyFileSync, mkdirSync } from 'node:fs';
import { join, relative, extname, dirname } from 'node:path';

const args = process.argv.slice(2);
const dirIdx = args.indexOf('--dir');
if (dirIdx < 0) {
  console.error('用法：node ohos-3.22-compat-patch.mjs --dir <app 目录> [--dry-run] [--no-backup]');
  process.exit(2);
}
const ROOT = args[dirIdx + 1];
const DRY = args.includes('--dry-run');
// --keep-theme：跳过 CardThemeData/TabBarTheme/DialogTheme 改名。
// 这三处是 3.27 Material 主题重构，**只能单向**：3.47 要 CardThemeData，3.22 要 CardTheme，
// 同一份源码无法同时满足。其它所有替换都双向兼容，所以用这个开关可以只预应用"安全的那部分"。
const KEEP_THEME = args.includes('--keep-theme');
const targetIdx = args.indexOf('--target');
const TARGET = targetIdx >= 0 ? args[targetIdx + 1] : '3.22';
const BACKUP = !args.includes('--no-backup');

const stats = { withValues: 0, toARGB32: 0, components: 0, themeData: 0, namedParams: 0, files: 0 };
const skipped = [];

/** 递归收集 .dart 文件。 */
function walk(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    if (name === 'build' || name === '.dart_tool' || name.startsWith('.')) continue;
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (extname(name) === '.dart') out.push(full);
  }
  return out;
}

/**
 * withValues 的替换。
 * 只处理 `withValues(alpha: <表达式>)`，且表达式里不含嵌套括号歧义。
 * 遇到含其它参数的形态（red/green/blue/...）一律跳过并报告。
 */
/**
 * withValues 的替换。
 *
 * ⚠️ 关键事实（已对 3.47 与 3.22 的 sky_engine/painting.dart 逐行核对）：
 *
 * 3.47 的 Color：
 *   Color withValues({double? alpha, double? red, ...})   ← 方法，double 分量 0..1
 *   Color withOpacity(double opacity)                        ← 3.27 起 @Deprecated 但保留
 *
 * 3.22 的 Color：
 *   Color withOpacity(double opacity)                        ← 有，double 0..1
 *   Color withAlpha(int a)                                   ← 有，int 0..255
 *   int get value                                           ← ARGB 打包值
 *   int get red / green / blue / alpha                       ← 全名，**没有** .r/.g/.b/.a
 *
 * 语义等价关系：
 *   withValues(alpha: X)  ≡  withOpacity(X)      （都是 double 0..1，直接换）
 *   .withValues.withOpacity(X) ≡ .withOpacity(X)  （withValues 是方法引用/tear-off，
 *                                               去掉这一层即可）
 */
function patchWithValues(src, file) {
  let count = 0;
  const patches = [];

  // ── 形态 A：`.withValues.withOpacity(0.15)` ──
  // withValues 作为方法引用后链式调用。3.22 没有 withValues，去掉这一层。
  // ⚠️ end 语义：只吃掉 `.withValues.withOpacity` 这一段，**保留**后面的 `(`，
  //    替换文本 `.withOpacity` 不带括号。end = g.index + g[0].length - 1
  //    （g[0] 以 '(' 结尾，所以减 1 正好落在 '(' 之前）。
  const getterRe = /\.withValues\s*\.\s*withOpacity/g;
  let g;
  while ((g = getterRe.exec(src)) !== null) {
    patches.push({ start: g.index, end: g.index + g[0].length, replacement: '.withOpacity' });
    count++;
  }

  // ── 形态 B：`.withValues(alpha: 0.15)` ──
  const callRe = /\.withValues\s*\(/g;
  let m;
  while ((m = callRe.exec(src)) !== null) {
    // 跳过已被形态 A 覆盖的位置
    if (patches.some((p) => m.index >= p.start && m.index < p.end)) continue;
    const start = m.index + m[0].length - 1; // 指向 '('
    let depth = 0, i = start;
    for (; i < src.length; i++) {
      if (src[i] === '(') depth++;
      else if (src[i] === ')') { depth--; if (depth === 0) break; }
    }
    const args = src.slice(start + 1, i);
    // 只接受单一 alpha 命名参数（允许跨行，允许表达式里有括号/逗号，如 clamp(0.0, 0.95)）
    // 关键：不能用 [^,]+? 排除逗号——clamp(0.0, 0.95) 内部就有逗号。
    const alphaOnly = /^\s*alpha\s*:\s*([\s\S]+?)\s*$/.exec(args);
    if (alphaOnly && !/(^|,)\s*[a-zA-Z_]\w*\s*:/.test(alphaOnly[1])) {
      // 整段 `.withValues(alpha: X)` → `.withOpacity(X)`，包含右括号。
      patches.push({ start: m.index, end: i + 1, replacement: `.withOpacity(${alphaOnly[1].trim()})` });
      count++;
    } else {
      skipped.push({ file, reason: `withValues 参数不是纯 alpha: (${args.slice(0, 60)})` });
    }
  }

  // 从后往前替换，避免偏移失效
  patches.sort((a, b) => b.start - a.start);
  for (const p of patches) {
    src = src.slice(0, p.start) + p.replacement + src.slice(p.end);
  }
  stats.withValues += count;
  return src;
}

/** toARGB32() → .value */
function patchToARGB32(src) {
  const n = (src.match(/\.toARGB32\s*\(\s*\)/g) || []).length;
  stats.toARGB32 += n;
  return src.replace(/\.toARGB32\s*\(\s*\)/g, '.value');
}

/**
 * Color 分量访问器：3.47 的 .a/.r/.g/.b（double 0..1）→ 3.22 的 .alpha/.red/.green/.blue（int 0..255）
 *
 * ⚠️ 这不是简单改名——**单位不同**：
 *   3.47: c.r ∈ [0.0, 1.0]（double）
 *   3.22: c.red ∈ [0, 255]（int）
 *
 * 所以凡是 3.47 代码里带 `* 255` 的（把 0..1 还原成 0..255 再用），换算后必须
 * **去掉 `* 255`**；凡是拿它和 0..1 小数比较的（如 `expect(c.a, 1.0)`），
 * 换算后要改成 `c.alpha / 255.0`。
 *
 * 处理策略（保守）：
 *   1. `X.r * 255`  → `X.red`           （直接去掉缩放）
 *   2. `X.r`         → `X.red / 255.0`  （保持 0..1 语义，供小数比较用）
 *   3. `X.a`（独立）  → `X.alpha / 255.0`
 *
 * 判定 Color 上下文：变量名含 color/Color/palette/shade/tint/accent/fg/bg/ink，
 * 或前面是 `)`（链式）。同时排除 group 成员 `g.members` 等误伤。
 */
function patchComponents(src, file) {
  let count = 0;
  const patches = [];

  // 情形 1：`X.r * 255`（3.47 代码里把 0..1 还原成 0..255）→ `X.red`
  const scaledRe = /([A-Za-z_]\w*)\s*(?:\.([rgba])\b|\.(red|green|blue|alpha)\b)\s*\*\s*255\b/g;
  let s;
  while ((s = scaledRe.exec(src)) !== null) {
    const obj = s[1];
    const chan = s[2] || ({ red: 'r', green: 'g', blue: 'b', alpha: 'a' })[s[3]];
    // `X.r * 255` 这个形态本身极强：只有把 Color 的 0..1 分量还原成 0..255 才会这么写。
    // 所以这里**不再**要求 isColorContext —— 否则 `c.r * 255`（变量名只有一个字母）会漏掉。
    // 误伤风险极低：`g.members * 255` 这种写法现实中不存在。
    if (!chan) continue;
    const full = { r: 'red', g: 'green', b: 'blue', a: 'alpha' }[chan];
    // 3.22 的分量是 int，3.47 是 double。原代码 `X.r * 255` 的结果是 double（进了 ch(double)），
    // 换成 `X.red` 就退化成 int → 类型错误。补 toDouble() 保持一致。
    patches.push({ start: s.index, end: s.index + s[0].length, text: `${obj}.${full}.toDouble()` });
    count++;
  }

  // 情形 2/3：独立的 `X.r` / `X.a` → `X.red / 255.0` / `X.alpha / 255.0`
  // 先把情形 1 已覆盖的位置排除。
  const plainRe = /\.([rgba])\b/g;
  let m;
  while ((m = plainRe.exec(src)) !== null) {
    if (patches.some((p) => m.index >= p.start && m.index < p.end)) continue;
    const before = src.slice(Math.max(0, m.index - 60), m.index);
    const ident = /([A-Za-z_]\w*)\s*$/.exec(before);
    const obj = ident ? ident[1] : '';
    if (!obj || !isColorContext(obj)) continue;
    const full = { r: 'red', g: 'green', b: 'blue', a: 'alpha' }[m[1]];
    // 后面紧跟 `* 255` 的交给情形 1（这里跳过，避免重复处理）
    if (/^\s*\*\s*255\b/.test(src.slice(m.index + m[0].length))) continue;
    patches.push({ start: m.index, end: m.index + m[0].length,
      text: `.${full} / 255.0` });
    count++;
  }

  patches.sort((a, b) => b.start - a.start);
  for (let k = 0; k < patches.length; k++) {
    const p = patches[k];
    src = src.slice(0, p.start) + p.text + src.slice(p.end);
  }
  stats.components += count;
  return src;
}

/** 粗略判断标识符是否处于 Color 语境。 */
function isColorContext(name) {
  if (/^(g|m|e|p|s|r|key|item|node|entry|map|list|set|args|params)$/i.test(name)) return false;
  return /(colou?r|Color|palette|shade|tint|accent|fg|bg|ink|fill|surface|primary|secondary|text)/i.test(name);
}

/** Material 主题类改名 */
function patchThemeData(src) {
  let count = 0;
  for (const [from, to] of [
    ['CardThemeData', 'CardTheme'],
    ['TabBarThemeData', 'TabBarTheme'],
    ['DialogThemeData', 'DialogTheme'],
  ]) {
    const re = new RegExp(`\\b${from}\\b`, 'g');
    const n = (src.match(re) || []).length;
    if (n) { src = src.replace(re, to); count += n; }
  }
  stats.themeData += count;
  return src;
}

/**
 * 具名参数的版本差异。
 *
 *   PopScope.onPopInvokedWithResult(bool didPop, T? result)
 *     → 3.22 只有 onPopInvoked(bool didPop)，少一个 result 参数。
 *       改写时要把回调体从 (didPop, result) 改成 (didPop)。
 *       ⚠️ 只做**参数改名 + 删掉 result 形参**是机械的；若回调体里用了 result，
 *          必须人工改写。脚本检测到 result 被使用时跳过并报告。
 *
 *   TextField.initialValue
 *     → 3.22 没有这个参数，只有 controller。改写不是机械替换（需要构造
 *        TextEditingController），所以脚本**只报告不自动改**。
 *
 *   SliderThemeData.activeThumbColor
 *     → 3.22 没有这个参数；对应的旧参数是 thumbColor。
 *       语义上不完全等价（activeThumbColor 只在激活态生效），脚本只报告。
 */
function patchNamedParams(src, file) {
  // ── PopScope.onPopInvokedWithResult → onPopInvoked ──
  // 形如：onPopInvokedWithResult: (bool didPop, Object? result) { ... }
  //
  // ⚠️ 关键：不能只看**形参列表**里有没有 result —— 本项目形参写了
  //    `(bool didPop, Object? result)` 但函数体里根本没用 result，是可以安全删的。
  //    必须取出整个函数体来判断。
  const popRe = /onPopInvokedWithResult\s*:\s*(\([^)]*\)\s*\{[\s\S]*?\n\s*\})/g;
  let p;
  const popPatches = [];
  while ((p = popRe.exec(src)) !== null) {
    const whole = p[1];
    const sig = /^\s*(\([^)]*\))/.exec(whole);
    if (!sig) {
      skipped.push({ file, reason: 'onPopInvokedWithResult 回调不是函数字面量，需人工改写' });
      continue;
    }
    const params = sig[1].slice(1, -1).split(',').map((s) => s.trim()).filter(Boolean);
    const body = whole.slice(sig[0].length);
    if (/\bresult\b/.test(body)) {
      skipped.push({ file, reason: 'onPopInvokedWithResult 回调体用到 result，需人工改写' });
      continue;
    }
    if (params.length >= 2) {
      popPatches.push({ start: p.index, end: p.index + p[0].length,
        replacement: `onPopInvoked: (${params[0]})${body}` });
    }
  }
  popPatches.sort((a, b) => b.start - a.start);
  for (const pt of popPatches) {
    src = src.slice(0, pt.start) + pt.replacement + src.slice(pt.end);
    stats.namedParams++;
  }

  // ── Switch.activeThumbColor → Switch.activeColor ──
  // 3.47 把 Switch.activeColor 改名成 activeThumbColor（旧名标废弃），两者都是 Color?。
  // ⚠️ 不能换成 thumbColor：3.22/3.47 的 thumbColor 都是 WidgetStateProperty<Color?>?，
  //    类型不对（实测会报 argument_type_not_assignable）。
  // 只处理 Switch( 上下文里的，避免误伤其它组件同名参数。
  const swRe = /activeThumbColor\s*:/g;
  let sw;
  const swPatches = [];
  while ((sw = swRe.exec(src)) !== null) {
    const ctx = src.slice(Math.max(0, sw.index - 400), sw.index);
    if (/Switch\s*\(/.test(ctx)) {
      swPatches.push({ start: sw.index, end: sw.index + sw[0].length,
        replacement: 'activeColor:' });
    } else {
      skipped.push({ file, reason: 'activeThumbColor 不在 Switch 上下文，需人工确认' });
    }
  }
  swPatches.sort((a, b) => b.start - a.start);
  for (const pt of swPatches) {
    src = src.slice(0, pt.start) + pt.replacement + src.slice(pt.end);
    stats.namedParams++;
  }

  // ── DropdownButtonFormField.initialValue → value ──
  // 3.47 把 DropdownButtonFormField.value 改名为 initialValue（value 标废弃）；
  // 3.22 只有 value。纯机械替换。
  //
  // ⚠️ 注意：真正需要 TextEditingController 的是 TextField.initialValue，
  //    那是**另一个** API，本项目没用到，不要混为一谈。
  const ddRe = /initialValue\s*:/g;
  let dd;
  const ddPatches = [];
  while ((dd = ddRe.exec(src)) !== null) {
    const ctx = src.slice(Math.max(0, dd.index - 400), dd.index);
    if (/DropdownButtonFormField\s*[<(]/.test(ctx)) {
      ddPatches.push({ start: dd.index, end: dd.index + dd[0].length, replacement: 'value:' });
    } else if (/TextField\s*\(/.test(ctx)) {
      skipped.push({ file, reason: 'TextField.initialValue 在 3.22 不存在（需改 controller 构造）' });
    }
  }
  ddPatches.sort((a, b) => b.start - a.start);
  for (const pt of ddPatches) {
    src = src.slice(0, pt.start) + pt.replacement + src.slice(pt.end);
    stats.namedParams++;
  }

  return src;
}

const files = walk(ROOT);
for (const f of files) {
  const orig = readFileSync(f, 'utf8');
  let src = orig;
  if (TARGET === '3.27') {
    // 3.27 已内置 withValues / CardThemeData / 单字母分量，只需补三个"3.29+ 才有"的 API。
    src = patchToARGB32(src);
    src = patchNamedParams(src, relative(ROOT, f));
  } else {
    src = patchWithValues(src, relative(ROOT, f));
    src = patchToARGB32(src);
    src = patchComponents(src, relative(ROOT, f));
    if (!KEEP_THEME) src = patchThemeData(src);
    src = patchNamedParams(src, relative(ROOT, f));
  }
  if (src !== orig) {
    stats.files++;
    if (DRY) {
      console.log(`  [dry] ${relative(ROOT, f)}`);
    } else {
      if (BACKUP) {
        const bak = f + '.bak322';
        if (!existsSync(bak)) copyFileSync(f, bak);
      }
      writeFileSync(f, src, 'utf8');
      console.log(`  ✓ ${relative(ROOT, f)}`);
    }
  }
}

console.log(`\n═══ 替换统计（target ${TARGET}）═══`);
console.log(`  withValues(alpha:) → withOpacity   ${stats.withValues} 处`);
console.log(`  toARGB32()         → .value         ${stats.toARGB32} 处`);
console.log(`  Color 分量 .r/.g/.b/.a → 全名        ${stats.components} 处`);
console.log(`  ThemeData → Theme                   ${stats.themeData} 处`);
console.log(`  具名参数版本差异                    ${stats.namedParams} 处`);
console.log(`  涉及文件：${stats.files}`);
if (skipped.length) {
  console.log(`\n  ⚠ 需人工处理 ${skipped.length} 处：`);
  for (const s of skipped.slice(0, 20)) console.log(`    ${s.file}：${s.reason}`);
  process.exit(2);
}
console.log('\n  无需人工处理的项。');
