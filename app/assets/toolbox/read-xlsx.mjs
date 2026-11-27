/**
 * read-xlsx.mjs —— 读**真正的 `.xlsx`**，输出 CSV / JSON（这样后续全用 node 处理就行）。
 *
 * ## 为什么要有它
 *
 * 内置技能里一直如实写着「**读不了 .xlsx**，请把表另存为 CSV」—— 那条限制来自
 * **手机上没有 python / pandas / openpyxl**（见 AGENTS.md 的「本机可用的执行环境」）。
 * 但 xlsx 的本质就是 **ZIP + XML**，而 node 自带 `node:zlib`：
 * 解 zip、读 `xl/worksheets/sheetN.xml`，几十行就能做掉。所以这条限制可以撤了。
 *
 * ## 用法
 *
 *   node read-xlsx.mjs <输入.xlsx> [选项]
 *
 *   --format <csv|json>  输出格式，默认 csv
 *   --sheet <名字或序号> 读哪个工作表，默认第一个（序号从 1 起）
 *   --out <路径>         写到文件（默认打到 stdout）
 *   --list               只列出工作表（名字 + 序号），不导数据
 *
 * 成功标记：
 *   `[xlsx] ok sheet=<名字> rows=<行数> cols=<列数> out=<路径|->`
 *
 * ## 诚实边界（写清楚，别让下游以为它能干更多）
 *
 *   * **不解析公式**：单元格里存的是"上次算出来的值"（xlsx 就是这么存的），
 *     所以读出来是数字而不是 `=A1+B1`。这通常正是你要的。
 *   * **日期**：xlsx 把日期存成"从 1900-01-01 起的序列号 + 数字格式"。
 *     本脚本**不做序列号→日期的换算**（那要读 `numFmt`/样式表，容易错），
 *     所以日期会以**数字**出现 —— 需要日期请在输出里自行说明，或让用户另存 CSV。
 *   * 不读合并单元格（只有左上角那格有值）、不读图表/图片/批注。
 *   * 只读**值**，不读样式。
 */

import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { colIndex, xmlUnescape, zipRead } from './office-zip.mjs';

const HELP = `用法: node read-xlsx.mjs <输入.xlsx> [选项]

选项:
  --format <csv|json>  输出格式，默认 csv
  --sheet <名字或序号> 读哪个工作表，默认第一个（序号从 1 起）
  --out <路径>         写到文件（默认打到 stdout）
  --list               只列出工作表

读 .xlsx（ZIP + XML）并输出 CSV / JSON。不解析公式、日期会是序列号。
`;

function fail(message, code) {
  process.stderr.write(`错误：${message}\n`);
  process.exit(code === undefined ? 1 : code);
}

// ─────────────────────────────────────────────────────────── 解析

/** 从 workbook.xml 取工作表名（按顺序）。取不到就退回 sheet1..N。 */
export function sheetNames(zip) {
  const wb = zip.get('xl/workbook.xml');
  if (!wb) return [];
  const text = wb.toString('utf8');
  const names = [...text.matchAll(/<sheet\b[^>]*\bname="([^"]*)"/g)].map((m) => xmlUnescape(m[1]));
  return names;
}

/** 取 sharedStrings（文本都被放这里，单元格里只存索引）。 */
export function sharedStrings(zip) {
  const f = zip.get('xl/sharedStrings.xml');
  if (!f) return [];
  const text = f.toString('utf8');
  // 一个 <si> 是一个字符串，里面可能有多个 <t>（富文本分段）→ 拼起来
  return [...text.matchAll(/<si\b[^>]*>([\s\S]*?)<\/si>/g)].map((m) => {
    const inner = m[1];
    const ts = [...inner.matchAll(/<t\b[^>]*>([\s\S]*?)<\/t>/g)].map((t) => xmlUnescape(t[1]));
    return ts.join('');
  });
}

/** 解析一张工作表 → 二维数组（值可能是 string / number / bool）。 */
export function parseSheet(xml, strings) {
  const rows = [];
  const rowRe = /<row\b([^>]*)>([\s\S]*?)<\/row>/g;
  let rm;
  while ((rm = rowRe.exec(xml)) !== null) {
    const rowAttrs = rm[1];
    const rowInner = rm[2];
    // 行号（`r="7"`）：空行不会出现在 XML 里，所以要按行号补空，否则会错位
    const rNum = Number((/\br="(\d+)"/.exec(rowAttrs) || [])[1] || (rows.length + 1));
    const cells = [];
    const cellRe = /<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g;
    let cm;
    while ((cm = cellRe.exec(rowInner)) !== null) {
      const attrs = cm[1] || '';
      const inner = cm[2] || '';
      const ref = (/\br="([A-Z]+)\d+"/.exec(attrs) || [])[1];
      const type = (/\bt="([^"]+)"/.exec(attrs) || [])[1] || '';
      const col = ref ? colIndex(ref) : cells.length;

      let value = '';
      if (type === 'inlineStr') {
        const ts = [...inner.matchAll(/<t\b[^>]*>([\s\S]*?)<\/t>/g)].map((t) => xmlUnescape(t[1]));
        value = ts.join('');
      } else {
        const vm = /<v>([\s\S]*?)<\/v>/.exec(inner);
        const raw = vm ? xmlUnescape(vm[1]) : '';
        if (type === 's') {
          const i = Number(raw);
          value = strings[i] === undefined ? '' : strings[i];
        } else if (type === 'b') {
          value = raw === '1' ? true : false;
        } else if (type === 'str') {
          value = raw;
        } else if (raw === '') {
          value = '';
        } else {
          // 数字（含日期序列号 —— 见文件头说明：**不换算**）
          const n = Number(raw);
          value = Number.isFinite(n) ? n : raw;
        }
      }
      while (cells.length < col) cells.push('');
      cells[col] = value;
    }
    while (rows.length < rNum - 1) rows.push([]);
    rows[rNum - 1] = cells;
  }
  return rows;
}

// ─────────────────────────────────────────────────────────── 输出

export function toCsv(rows) {
  return rows
    .map((r) => r.map((v) => {
      const s = v === undefined || v === null ? '' : String(v);
      return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    }).join(','))
    .join('\n');
}

export function toJson(rows) {
  if (rows.length === 0) return '[]';
  const header = rows[0].map((v) => (v === undefined || v === null ? '' : String(v)));
  const body = rows.slice(1).map((r) => {
    const o = {};
    header.forEach((h, i) => { o[h || `col${i + 1}`] = r[i] === undefined ? '' : r[i]; });
    return o;
  });
  return JSON.stringify(body, null, 2);
}

// ─────────────────────────────────────────────────────────── 命令行

function parseArgs(argv) {
  const out = { positional: [], format: 'csv', sheet: '', out: '', list: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--help' || a === '-h') { process.stdout.write(HELP); process.exit(0); }
    else if (a === '--format') out.format = String(argv[++i] || '').toLowerCase();
    else if (a === '--sheet') out.sheet = argv[++i] || '';
    else if (a === '--out') out.out = argv[++i] || '';
    else if (a === '--list') out.list = true;
    else if (a.startsWith('--')) fail(`不认识的选项：${a}`, 2);
    else out.positional.push(a);
  }
  return out;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.positional.length < 1) { process.stderr.write(HELP); process.exit(2); }
  const inPath = args.positional[0];
  if (!existsSync(inPath)) fail(`输入文件不存在：${inPath}`, 2);
  if (!['csv', 'json'].includes(args.format)) fail(`--format 只支持 csv / json`, 2);

  let zip;
  try {
    zip = zipRead(readFileSync(inPath));
  } catch (e) {
    fail(`这不是一个能读的 xlsx：${e.message}`, 1);
  }

  const names = sheetNames(zip);

  if (args.list) {
    const lines = (names.length ? names : ['sheet1'])
      .map((n, i) => `${i + 1}\t${n}`).join('\n');
    process.stdout.write(`${lines}\n`);
    process.stdout.write(`[xlsx] ok list=1 count=${names.length || 1} out=-\n`);
    return;
  }

  // 选工作表：给名字按名字找；给数字按序号（从 1 起）；都没给就第一张
  let index = 0;
  if (args.sheet) {
    const asNum = Number(args.sheet);
    if (Number.isInteger(asNum) && asNum >= 1) index = asNum - 1;
    else {
      const found = names.indexOf(args.sheet);
      if (found < 0) fail(`没有名为「${args.sheet}」的工作表（有：${names.join('、') || 'sheet1'}）`, 1);
      index = found;
    }
  }
  const file = `xl/worksheets/sheet${index + 1}.xml`;
  const sheetXml = zip.get(file);
  if (!sheetXml) {
    fail(`找不到 ${file}（这个 xlsx 的工作表结构不是标准形式）`, 1);
  }

  const rows = parseSheet(sheetXml.toString('utf8'), sharedStrings(zip));
  const cols = rows.reduce((m, r) => Math.max(m, r.length), 0);
  const text = args.format === 'json' ? toJson(rows) : toCsv(rows);
  const sheetLabel = names[index] || `sheet${index + 1}`;

  if (args.out) {
    const abs = resolve(args.out);
    try {
      if (!existsSync(dirname(abs))) mkdirSync(dirname(abs), { recursive: true });
      writeFileSync(abs, `${text}\n`);
    } catch (e) {
      fail(`写出失败：${e.message}`, 1);
    }
    process.stderr.write(
      `[xlsx] ok sheet=${sheetLabel} rows=${rows.length} cols=${cols} out=${abs}\n`,
    );
    return;
  }
  process.stdout.write(`${text}\n`);
  process.stderr.write(
    `[xlsx] ok sheet=${sheetLabel} rows=${rows.length} cols=${cols} out=-\n`,
  );
}

// 只有被**直接** `node <script>` 调用时才执行；被 import 时什么都不做（方便单测）。
//
// ⚠️ 2026-11-27：原来这里只有一句 URL 全等判断
//     `import.meta.url === pathToFileURL(resolve(argv[1])).href`
//   —— 只要 argv[1] 与真实路径有细微差别（realpath / 软链 / 前缀不同），就判成
//   "不是直接运行"，于是 main() 根本不执行、进程**静默退出 0、两路零输出**。
//   真机现场：`探活失败：node 提前退出 exit=0 | stderr=(空)`，烧掉十几轮排查。
//   现在按文件名兜底（make-pptx 在 10-20 就已经这么改了，另外四个没跟上）。
const isDirectRun = (() => {
  if (!process.argv[1]) return false;
  try {
    if (pathToFileURL(resolve(process.argv[1])).href === import.meta.url) return true;
    return basename(process.argv[1]) === basename(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();

if (isDirectRun) {
  main();
}
