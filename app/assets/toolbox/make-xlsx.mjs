/**
 * make-xlsx.mjs —— 把 **CSV / JSON** 变成**真正的 `.xlsx`**（Excel / WPS / 表格 App 能直接打开）。
 *
 * ## 为什么要有它（用户 2026-10-12 的「全做」清单里 D 项）
 *
 * 手机上**没有 python / pandas / openpyxl**（见 AGENTS.md 的「本机可用的执行环境」）。
 * 于是内置技能里一直写着"**读不了 .xlsx**，请用户自己另存为 CSV"——
 * 那是**输入侧**的事（见 `read-xlsx.mjs`）。**输出侧**更常见：
 * 用户拿到一份 CSV/JSON 结果，想要的是能直接发给别人的 `.xlsx`。
 * 本脚本补的就是这一条。
 *
 * ## 它产出的是什么
 *
 * 一个符合 OOXML 规范的最小 xlsx：
 *   `[Content_Types].xml` / `_rels/.rels` / `xl/workbook.xml` /
 *   `xl/_rels/workbook.xml.rels` / `xl/styles.xml` / `xl/worksheets/sheet1.xml`
 *
 * ⚠️ 文本用 **inlineStr**（不写 sharedStrings）：少一个部件、少一类对不齐的索引 bug，
 *    而 Excel / WPS / Numbers / LibreOffice 都认。
 * ⚠️ **不做**公式、图表、条件格式、冻结窗格、多工作表（要就再加；现在不假装支持）。
 *    数字会写成**数字**（这样表格里能直接求和），其余一律当文本。
 *
 * ## 用法
 *
 *   node make-xlsx.mjs <输入.csv|json> <输出.xlsx> [选项]
 *
 *   --sheet <名字>      工作表名（默认 sheet1；Excel 不允许 [ ] : * ? / \ 与首尾引号）
 *   --delimiter <字符>  CSV 分隔符，默认 `,`（也常有人用 `;` 或制表符 —— 用 `\t` 表示）
 *   --no-header         第一行不是表头（默认当成表头，会加粗）
 *
 * 成功标记（Dart 侧按它认结果，**格式不要改**）：
 *   `[xlsx] ok rows=<数据行数> cols=<列数> bytes=<字节数> out=<绝对路径>`
 *
 * 退出码：0 成功；1 数据/写出失败；2 参数或环境错误。
 */

import { existsSync, readFileSync, statSync, writeFileSync, mkdirSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { xmlEscape, zipWrite } from './office-zip.mjs';

const HELP = `用法: node make-xlsx.mjs <输入.csv|json> <输出.xlsx> [选项]

选项:
  --sheet <名字>      工作表名（默认 sheet1）
  --delimiter <字符>  CSV 分隔符，默认 ","（制表符写 \\t）
  --no-header         第一行不是表头

把 CSV 或 JSON（对象数组，或二维数组）写成真正的 .xlsx。
`;

function fail(message, code) {
  process.stderr.write(`错误：${message}\n`);
  process.exit(code === undefined ? 1 : code);
}

// ─────────────────────────────────────────────────────────── CSV 解析

/**
 * 极简但正确的 CSV 解析（RFC 4180）：
 *   * 双引号包裹的字段里可以有分隔符与换行；
 *   * 字段里的 `""` 表示一个字面双引号；
 *   * 去掉 `\r`（Windows 换行）。
 */
export function parseCsv(text, delimiter = ',') {
  const rows = [];
  let row = [];
  let field = '';
  let inQuotes = false;
  const src = String(text).replace(/\r\n/g, '\n').replace(/\r/g, '\n');

  for (let i = 0; i < src.length; i += 1) {
    const ch = src[i];
    if (inQuotes) {
      if (ch === '"') {
        if (src[i + 1] === '"') { field += '"'; i += 1; } else { inQuotes = false; }
      } else {
        field += ch;
      }
      continue;
    }
    if (ch === '"') { inQuotes = true; continue; }
    if (ch === delimiter) { row.push(field); field = ''; continue; }
    if (ch === '\n') { row.push(field); rows.push(row); row = []; field = ''; continue; }
    field += ch;
  }
  if (field.length > 0 || row.length > 0) { row.push(field); rows.push(row); }
  // 丢掉纯空尾行（最后那个换行会造出一行 [""]）
  return rows.filter((r) => !(r.length === 1 && r[0] === ''));
}

/** JSON → 二维表。支持「对象数组」（表头取第一个对象的键）与「二维数组」。 */
export function tableFromJson(text) {
  let data;
  try {
    data = JSON.parse(text);
  } catch (e) {
    fail(`JSON 解析失败：${e.message}`, 2);
  }
  if (Array.isArray(data) && data.length > 0 && !Array.isArray(data[0]) && typeof data[0] === 'object') {
    const cols = [];
    for (const o of data) {
      for (const k of Object.keys(o)) if (!cols.includes(k)) cols.push(k);
    }
    return [cols, ...data.map((o) => cols.map((c) => (o[c] === undefined || o[c] === null ? '' : o[c])))];
  }
  if (Array.isArray(data) && (data.length === 0 || Array.isArray(data[0]))) {
    return data.map((r) => [...r]);
  }
  fail('JSON 必须是「对象数组」或「二维数组」', 1);
  return [];
}

// ─────────────────────────────────────────────────────────── 单元格

/** 这一格该写成数字还是文本？—— 只有"纯数字"才写成数字（否则表格里不能求和）。 */
function isNumeric(v) {
  if (typeof v === 'number') return Number.isFinite(v);
  if (typeof v !== 'string') return false;
  const s = v.trim();
  if (s === '') return false;
  // 允许 123 / -1.5 / 1e3；**不**允许 00123（前导零多半是编号/电话/邮编，必须留成文本）
  if (/^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$/.test(s)) return true;
  return false;
}

function cellXml(ref, value, styleIndex) {
  const style = styleIndex ? ` s="${styleIndex}"` : '';
  if (value === undefined || value === null || value === '') {
    return `<c r="${ref}"${style}/>`;
  }
  if (isNumeric(value)) {
    return `<c r="${ref}"${style}><v>${String(value).trim()}</v></c>`;
  }
  return `<c r="${ref}"${style} t="inlineStr"><is><t xml:space="preserve">${xmlEscape(value)}</t></is></c>`;
}

/** 工作表名合法化：Excel 的硬限制（不是我们挑的）。 */
export function safeSheetName(name) {
  let s = String(name || 'sheet1').replace(/[\[\]:*?/\\]/g, '_');
  if (s.length > 31) s = s.slice(0, 31);
  if (/^'.*'$/.test(s)) s = s.slice(1, -1);
  return s || 'sheet1';
}

// ─────────────────────────────────────────────────────────── 组装

export function buildXlsx(table, { sheetName = 'sheet1', header = true } = {}) {
  const rows = table.length > 0 ? table : [['']];
  const width = Math.max(...rows.map((r) => r.length), 1);
  const sheet = safeSheetName(sheetName);

  const sheetRows = rows.map((r, ri) => {
    const cells = [];
    for (let ci = 0; ci < width; ci += 1) {
      const ref = `${colNameLocal(ci)}${ri + 1}`;
      // 表头加粗（styles.xml 里 s="1"）
      const style = header && ri === 0 ? 1 : 0;
      cells.push(cellXml(ref, r[ci] === undefined ? '' : r[ci], style));
    }
    return `<row r="${ri + 1}">${cells.join('')}</row>`;
  }).join('');

  const parts = [
    ['[Content_Types].xml',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">`
      + `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>`
      + `<Default Extension="xml" ContentType="application/xml"/>`
      + `<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>`
      + `<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`
      + `<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>`
      + `</Types>`],
    ['_rels/.rels',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">`
      + `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>`
      + `</Relationships>`],
    ['xl/workbook.xml',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" `
      + `xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">`
      + `<sheets><sheet name="${xmlEscape(sheet)}" sheetId="1" r:id="rId1"/></sheets>`
      + `</workbook>`],
    ['xl/_rels/workbook.xml.rels',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">`
      + `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>`
      + `<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>`
      + `</Relationships>`],
    ['xl/styles.xml',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">`
      + `<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>`
      + `<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>`
      + `<fills count="1"><fill><patternFill patternType="none"/></fill></fills>`
      + `<borders count="1"><border/></borders>`
      + `<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>`
      + `<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>`
      + `<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>`
      + `</styleSheet>`],
    ['xl/worksheets/sheet1.xml',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">`
      // 冻结首行（表头常在滚动时丢失 —— 这是最小的可用体贴）
      + (header ? '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>' : '')
      + `<sheetData>${sheetRows}</sheetData>`
      + `</worksheet>`],
  ];
  return { buf: zipWrite(parts), rows: rows.length, cols: width, sheet };
}

/** 本地用（避免与导出的 colName 重名困扰）：列号 → 列名。 */
function colNameLocal(index) {
  let n = index + 1;
  let s = '';
  while (n > 0) {
    const r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

// ─────────────────────────────────────────────────────────── 命令行

function parseArgs(argv) {
  const out = { positional: [], sheet: 'sheet1', delimiter: ',', header: true };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--help' || a === '-h') { process.stdout.write(HELP); process.exit(0); }
    else if (a === '--sheet') out.sheet = argv[++i];
    else if (a === '--delimiter') {
      const d = argv[++i];
      out.delimiter = d === '\\t' ? '\t' : d;
    } else if (a === '--no-header') out.header = false;
    else if (a.startsWith('--')) fail(`不认识的选项：${a}`, 2);
    else out.positional.push(a);
  }
  return out;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.positional.length < 2) {
    process.stderr.write(HELP);
    process.exit(2);
  }
  const [inPath, outPath] = args.positional;
  if (!existsSync(inPath)) fail(`输入文件不存在：${inPath}`, 2);
  if (!args.delimiter || args.delimiter.length !== 1) fail('--delimiter 只能是单个字符', 2);

  const text = readFileSync(inPath, 'utf8');
  const isJson = /\.json$/i.test(inPath);
  let table;
  if (isJson) {
    table = tableFromJson(text);
  } else {
    table = parseCsv(text, args.delimiter);
  }
  if (table.length === 0) fail('输入里没有数据行', 1);

  const { buf, rows, cols, sheet } = buildXlsx(table, {
    sheetName: args.sheet,
    header: args.header,
  });

  const abs = resolve(outPath);
  try {
    if (!existsSync(dirname(abs))) mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, buf);
  } catch (e) {
    fail(`写出失败：${e.message}`, 1);
  }
  const bytes = statSync(abs).size;
  process.stdout.write(
    `[xlsx] ok rows=${rows} cols=${cols} sheet=${sheet} bytes=${bytes} out=${abs}\n`,
  );
}

// 只有被直接 `node make-xlsx.mjs` 调用时才跑（被 import 时不自动执行，方便测试）
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
