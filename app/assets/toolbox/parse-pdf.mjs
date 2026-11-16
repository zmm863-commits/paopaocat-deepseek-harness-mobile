#!/usr/bin/env node
'use strict';
/**
 * parse-pdf.mjs —— 把 PDF 读成**带坐标的结构化文本**（纯 JS，无原生依赖）。
 *
 * 用法：
 *   node parse-pdf.mjs <in.pdf>                    # 输出 Markdown（给模型看）
 *   node parse-pdf.mjs <in.pdf> --format json      # 输出 JSON（带每个文本块的坐标）
 *   node parse-pdf.mjs <in.pdf> --out out.md       # 写文件
 *   node parse-pdf.mjs <in.pdf> --pages 1-3        # 只解析指定页
 *   node parse-pdf.mjs --help
 *
 * ## 为什么不用 PDFium 那一套
 *
 * 社区的 PDF 解析工具（含 LiteParse）大多把活交给 **PDFium**（Chrome 的 PDF 引擎）。
 * 但 PDFium 的预编译发布里**没有 Android 版本**（只有 linux / mac / win / wasm），
 * 而且它的 linux-arm64 包链接的是 glibc，Android 用 bionic —— 直接拿过来跑不起来。
 * 要自己编 PDFium 得拉 depot_tools、几 GB 依赖、数小时，为一个"读文本"的功能不值得。
 *
 * 所以这里用 **pdf.js**（Mozilla，Apache-2.0，纯 JavaScript）。它本来就能给出：
 * 每页尺寸、每个文本块的**字符串 + 变换矩阵 + 宽高**。对"让模型读懂 PDF"这件事，
 * 这就是需要的全部 —— OCR 和高质量渲染是另一回事，真需要时再单独上。
 *
 * ## 输出为什么默认是 Markdown
 *
 * 给模型吃的东西越短越好。Markdown 里只留「按行合并后的文字」；
 * 坐标、字号那些只在 `--format json` 里给（做版面分析时才需要）。
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));

// pdf.js 在 node 里会抱怨缺 canvas / DOMMatrix（那些只影响**渲染**，我们只读文本），
// 还有字体表的小问题。这些都刷一堆 stderr 会吓到用户，只留真正的错误。
const _warn = console.warn;
console.warn = (...a) => {
  const s = a.map(String).join(' ');
  if (/Cannot load "@napi-rs\/canvas"/.test(s)) return;
  if (/Cannot polyfill `(DOMMatrix|Path2D)`/.test(s)) return;
  if (/TT: undefined function/.test(s)) return;
  if (/Indexing all PDF objects/.test(s)) return;
  _warn(...a);
};

function usage() {
  console.log(`parse-pdf.mjs —— PDF → 结构化文本（纯 JS）

用法：
  node parse-pdf.mjs <in.pdf> [--format md|json] [--out <file>] [--pages 1-3]

选项：
  --format md    默认。按行合并的文字，给模型读最省 token
  --format json  每个文本块的字符串 + 坐标 + 宽高（做版面分析用）
  --pages A-B    只解析指定页（从 1 开始；也可以写 2,4,6）
  --out <file>   写到文件，不打印到 stdout

退出码：0 成功；1 参数/读文件错误；2 解析失败。`);
}

function parseArgs(argv) {
  const a = { file: null, format: 'md', out: null, pages: null };
  for (let i = 2; i < argv.length; i++) {
    const v = argv[i];
    if (v === '--help' || v === '-h') { usage(); process.exit(0); }
    else if (v === '--format') a.format = argv[++i];
    else if (v === '--out') a.out = argv[++i];
    else if (v === '--pages') a.pages = argv[++i];
    else if (!a.file) a.file = v;
  }
  return a;
}

/** 解析 "1-3" / "2,4,6" / null（全部）成 1-based 页号数组。 */
function pageList(spec, total) {
  if (!spec) return Array.from({ length: total }, (_, i) => i + 1);
  const out = new Set();
  for (const part of spec.split(',')) {
    const m = part.trim().match(/^(\d+)\s*-\s*(\d+)$/);
    if (m) {
      const [a, b] = [Number(m[1]), Number(m[2])];
      for (let p = Math.min(a, b); p <= Math.max(a, b); p++) out.add(p);
    } else if (part.trim()) {
      out.add(Number(part.trim()));
    }
  }
  return [...out].filter((p) => p >= 1 && p <= total).sort((a, b) => a - b);
}

/**
 * 把一页的文本块按「行」聚起来。
 *
 * PDF 里的文本块是一个个独立的绘制指令，同一行的话会被切成好几块
 * （中英文混排时尤其碎，一次 Tj 一块）。直接拼接会变成 "Android上的真PPTX"，
 * 全糊在一起；按 y 坐标聚行、行内按 x 排序，才能还原原来的一行。
 *
 * 容差取块高的一半：同一行里不同字号的块也能落到一起。
 */
function groupIntoLines(items) {
  const rows = [];
  for (const it of items) {
    if (!it.str || !it.str.trim()) continue;
    const y = it.y;
    const tol = Math.max(3, it.h * 0.5);
    let row = rows.find((r) => Math.abs(r.y - y) <= tol);
    if (!row) { row = { y, items: [] }; rows.push(row); }
    row.items.push(it);
  }
  rows.sort((a, b) => b.y - a.y); // PDF 的 y 轴向上，所以降序才是从上到下
  for (const r of rows) r.items.sort((a, b) => a.x - b.x);
  return rows.map((r) => r.items);
}

/** 行内拼接：中文之间不加空格，西文之间加空格（否则会出现 "H e l l o"）。 */
function joinLine(items) {
  let s = '';
  let prevEnd = null;
  for (const it of items) {
    const t = it.str;
    if (!t) continue;
    const needSpace =
      prevEnd != null &&
      /[A-Za-z0-9,.;:!?)]$/.test(s) &&
      /^[A-Za-z0-9('"]/.test(t) &&
      it.x - prevEnd > 1.0;
    s += (needSpace ? ' ' : '') + t;
    prevEnd = it.x + it.w;
  }
  return s.trim();
}

async function main() {
  const args = parseArgs(process.argv);
  if (!args.file) { console.error('缺少输入文件。用 --help 看用法。'); process.exit(1); }

  let bytes;
  try {
    bytes = new Uint8Array(readFileSync(args.file));
  } catch (e) {
    console.error(`读不到文件：${args.file}（${e.message}）`);
    process.exit(1);
  }

  // pdf.js 的 legacy 构建：不依赖 DOM，能在 node 里跑。
  // 用动态 import 而不是静态，是为了让"包里没有 pdf.js"这种情况给出清楚的报错，
  // 而不是一上来就 ERR_MODULE_NOT_FOUND 糊一脸。
  let getDocument;
  try {
    const mod = await import(pathToFileURL(join(HERE, 'vendor/pdfjs/pdf.mjs')).href);
    getDocument = mod.getDocument;
  } catch (e) {
    console.error(`包里没有 pdf.js（vendor/pdfjs/pdf.mjs）：${e.message}`);
    process.exit(2);
  }

  let doc;
  try {
    doc = await getDocument({
      data: bytes,
      // node 里没有 canvas/DOM，关掉字体和渲染相关的取用（只读文本）
      useSystemFonts: false,
      disableFontFace: true,
      isEvalSupported: false,
      // worker 也不要用（node 下用假 worker 直接跑，避免多进程开销）
      useWorkerFetch: false,
    }).promise;
  } catch (e) {
    console.error(`PDF 打不开（可能是加密或损坏）：${e.message}`);
    process.exit(2);
  }

  const pages = pageList(args.pages, doc.numPages);
  const out = { file: args.file, pages: doc.numPages, parsed: [], };

  for (const p of pages) {
    const page = await doc.getPage(p);
    const vp = page.getViewport({ scale: 1 });
    const tc = await page.getTextContent();
    // transform = [a,b,c,d,e,f]；e/f 是文本原点的 x/y（PDF 坐标系，y 向上）
    const items = [];
    for (const it of tc.items) {
      const tr = it.transform;
      if (!tr) continue;
      items.push({
        str: it.str,
        x: Number(tr[4].toFixed(2)),
        y: Number(tr[5].toFixed(2)),
        w: Number((it.width ?? 0).toFixed(2)),
        h: Number((it.height ?? 0).toFixed(2)),
      });
    }
    out.parsed.push({
      page: p,
      width: Math.round(vp.width),
      height: Math.round(vp.height),
      lines: groupIntoLines(items).map(joinLine).filter((s) => s.length > 0),
      items: args.format === 'json' ? items : undefined,
    });
  }

  let text;
  if (args.format === 'json') {
    text = JSON.stringify(out, null, 2);
  } else {
    const buf = [];
    buf.push(`# ${args.file.split('/').pop()}`);
    buf.push('');
    buf.push(`共 ${out.pages} 页${pages.length !== out.pages ? `（本次解析 ${pages.length} 页）` : ''}`);
    for (const pg of out.parsed) {
      buf.push('');
      buf.push(`## 第 ${pg.page} 页（${pg.width}×${pg.height}）`);
      buf.push('');
      for (const line of pg.lines) buf.push(line);
    }
    text = buf.join('\n');
  }

  if (args.out) {
    writeFileSync(args.out, text, 'utf8');
    console.log(`已写出 ${args.out}（${text.length} 字符）`);
  } else {
    process.stdout.write(text + '\n');
  }
}

main().catch((e) => {
  console.error(`解析失败：${e?.stack || e}`);
  process.exit(2);
});
