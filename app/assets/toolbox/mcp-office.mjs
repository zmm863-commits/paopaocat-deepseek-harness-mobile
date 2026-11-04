/**
 * mcp-office.mjs —— **本地 MCP 服务**（stdio 传输），给 Agent 三个"动 Office 文件"的工具。
 *
 * ## 它是什么
 *
 * 一个**不依赖任何 npm 包**的 MCP 服务器：MCP 的 stdio 传输就是"每行一条 JSON-RPC"，
 * 所以用 node 内置模块就能实现（`node:fs` + `node:path`）。随包进 APK、跑在手机里的
 * node 上，**离线可用**。
 *
 * ## 为什么要有它（对标同类产品）
 *
 * 同类产品的本地文档引擎（183MB Rust）起了一个 MCP 服务，暴露 **302 个工具**
 * （doc 100 / sheet 105 / slide 97），云侧 Agent 通过 `tools/call` 直接改文档。
 * 我们没有那个引擎，但 OOXML 的本质就是 **ZIP + XML**，而 `office-zip.mjs` 已经是现成的
 * zip 读写库（见它的文件头）。所以先用**三个工具**把"能改文件"这条路打通。
 *
 * ## 传输与挂载（重要，别改错）
 *
 * DSH 运行时的 `dsh-acp` 负责解析 ACP 会话里的 `mcpServers`：
 *   * **不带 `type` 字段** → 按 **stdio** 处理：`command` 必须是**绝对路径**，
 *     可选 `args` / `env`；运行时自己 spawn 这个进程。
 *   * `type: "http"` → streamable-http，需要一个我们另外起的 HTTP 服务。
 *   * `failOnStartupError: true` → **起不来会连累整个会话**，所以这个脚本必须永远能起来。
 * 本脚本走 **stdio**：由运行时拉起，运行时负责关。
 *
 * ## 能力边界（写清楚，免得模型以为它能干更多）
 *
 *   * 只做**值**的读写：不写公式、不算公式、不改样式（写单元格时**保留原样式** `s=`）。
 *   * 写入的文本用 **inlineStr**（不碰 sharedStrings）—— 少一类索引对不齐的 bug。
 *   * 日期在 xlsx 里是序列号，**不换算**（与 `read-xlsx.mjs` 的口径一致）。
 *   * docx 只支持**追加段落**（正文末尾），不做样式、不做表格、不做修订。
 *   * **不解析文件锁**：被 Excel/WPS 打开着的文件，改完可能被对方覆盖。
 *   * 改文件前会先读一遍确认文件存在、能解析；读不了就**如实报错**，不猜。
 *
 * ## 用法（一般不由人直接调，是模型经 MCP 调用）
 *
 *   node mcp-office.mjs        # 走 stdin/stdout 的 MCP 服务
 *   node mcp-office.mjs --selftest   # 本机自检（不联网、不依赖模型）
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  colIndex,
  colName,
  xmlEscape,
  zipRead,
  zipWrite,
} from './office-zip.mjs';
import { parseSheet, sharedStrings } from './read-xlsx.mjs';

const SERVER_NAME = 'dsh-office';
const SERVER_VERSION = '1.0.0';

// ─────────────────────────────────────────────────────────── 工具清单

/** 三个工具的声明。description 是**给模型看的**，必须说清"能干什么/不能干什么"。 */
const TOOLS = [
  {
    name: 'office_read_cells',
    description:
      '读 .xlsx 里的单元格。参数：file（路径）、sheet（工作表名，可省略=第一个）、' +
      'range（如 "A1:C10"，可省略=整张表的前 200 个非空格）。' +
      '返回 JSON：{sheet, cells:[{ref,value}]}。只读值，不算公式、不换算日期。',
    inputSchema: {
      type: 'object',
      properties: {
        file: { type: 'string', description: '.xlsx 文件的路径' },
        sheet: { type: 'string', description: '工作表名（省略则第一个）' },
        range: { type: 'string', description: '区域，如 A1:C10（省略则整表）' },
      },
      required: ['file'],
    },
  },
  {
    name: 'office_write_cell',
    description:
      '写 .xlsx 的**一个**单元格。参数：file（路径）、cell（如 "B7"）、value（字符串或数字）、' +
      'sheet（可省略=第一个）。保留该格原有样式；目标不存在会按列序插入。' +
      '返回 JSON：{sheet, cell, previous, now}。不写公式、不算公式。',
    inputSchema: {
      type: 'object',
      properties: {
        file: { type: 'string', description: '.xlsx 文件的路径' },
        cell: { type: 'string', description: '单元格引用，如 B7' },
        value: { type: ['string', 'number', 'boolean'], description: '要写入的值' },
        sheet: { type: 'string', description: '工作表名（省略则第一个）' },
      },
      required: ['file', 'cell', 'value'],
    },
  },
  {
    name: 'office_append_paragraph',
    description:
      '往 .docx 正文**末尾追加一段**。参数：file（路径）、text（段落文字）、' +
      'heading（true 则用标题 1 样式）。返回 JSON：{paragraphs}。' +
      '只追加正文段落，不做表格/图片/样式/修订。',
    inputSchema: {
      type: 'object',
      properties: {
        file: { type: 'string', description: '.docx 文件的路径' },
        text: { type: 'string', description: '要追加的段落文字' },
        heading: { type: 'boolean', description: '是否为标题（默认否）' },
      },
      required: ['file', 'text'],
    },
  },
];

// ─────────────────────────────────────────────────────────── xlsx 读取

/** 取 xlsx 里的工作表清单：[{name, path}]（path 是 zip 内的条目名）。 */
function listSheets(zip) {
  const wb = zip.get('xl/workbook.xml');
  if (!wb) throw new Error('这个文件里没有 xl/workbook.xml —— 可能不是 .xlsx');
  const wbText = wb.toString('utf8');
  const rels = zip.get('xl/_rels/workbook.xml.rels');
  const relMap = new Map();
  if (rels) {
    const relText = rels.toString('utf8');
    for (const m of relText.matchAll(/<Relationship\b[^>]*\bId="([^"]+)"[^>]*\bTarget="([^"]+)"[^>]*>/g)) {
      relMap.set(m[1], m[2]);
    }
  }
  const sheets = [];
  const re = /<sheet\b[^>]*?>/g;
  let m;
  let index = 0;
  while ((m = re.exec(wbText)) !== null) {
    const tag = m[0];
    const name = xmlUnescapeLocal((/\bname="([^"]*)"/.exec(tag) || [])[1] || `sheet${index + 1}`);
    const rid = (/\br:id="([^"]+)"/.exec(tag) || [])[1];
    let target = rid ? relMap.get(rid) : null;
    if (!target) target = `worksheets/sheet${index + 1}.xml`;
    if (target.startsWith('/')) target = target.slice(1);
    else if (!target.startsWith('xl/')) target = `xl/${target}`;
    sheets.push({ name, path: target, index });
    index += 1;
  }
  if (sheets.length === 0) throw new Error('这个 xlsx 里没有工作表');
  return sheets;
}

/** 本地小工具：只解我们用到的几种实体（复用 office-zip 的 xmlUnescape）。 */
function xmlUnescapeLocal(s) {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/** 把 "A1:C10" 解析成 {c1,r1,c2,r2}（列是 0 基，列号转成 0 基）。 */
function parseRange(range) {
  const m = /^([A-Za-z]+)(\d+)(?::([A-Za-z]+)(\d+))?$/.exec(String(range).trim());
  if (!m) throw new Error(`range 写法不对：${range}（应该像 A1 或 A1:C10）`);
  const c1 = colIndex(m[1].toUpperCase());
  const r1 = Number(m[2]);
  const c2 = m[3] ? colIndex(m[3].toUpperCase()) : c1;
  const r2 = m[4] ? Number(m[4]) : r1;
  if (c1 > c2 || r1 > r2) throw new Error(`range 方向反了：${range}`);
  return { c1, r1, c2, r2 };
}

/** 读一段区域 → [{ref, value}]（空值也返回，方便模型看结构）。 */
function readCells(zip, sheetPath, rangeText) {
  const sheetXml = zip.get(sheetPath);
  if (!sheetXml) throw new Error(`工作表部件不在包里：${sheetPath}`);
  const rows = parseSheet(sheetXml.toString('utf8'), sharedStrings(zip));
  const range = rangeText ? parseRange(rangeText) : null;
  const out = [];
  const rMax = range ? range.r2 : rows.length;
  const cMax = range ? range.c2 : Math.max(0, ...rows.map((r) => r.length));
  for (let r = range ? range.r1 : 1; r <= rMax; r += 1) {
    const row = rows[r - 1] || [];
    for (let c = range ? range.c1 : 0; c <= cMax; c += 1) {
      const value = row[c];
      if (value === undefined || value === '') continue;
      out.push({ ref: `${colName(c)}${r}`, value });
      if (out.length >= 500) return out;
    }
  }
  return out;
}

// ─────────────────────────────────────────────────────────── xlsx 写入

/** 造一个 `<c>` 元素。文本用 inlineStr（不碰 sharedStrings）。 */
function cellXml(ref, value, styleAttr = '') {
  const style = styleAttr ? ` ${styleAttr}` : '';
  if (value === '' || value === null || value === undefined) {
    return `<c r="${ref}"${style}/>`;
  }
  if (typeof value === 'boolean') {
    return `<c r="${ref}"${style} t="b"><v>${value ? 1 : 0}</v></c>`;
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    return `<c r="${ref}"${style}><v>${value}</v></c>`;
  }
  return `<c r="${ref}"${style} t="inlineStr"><is><t xml:space="preserve">${xmlEscape(String(value))}</t></is></c>`;
}

/** 在一段 XML 里找 `<c ... r="B7" ...>`（自闭合或带内容），返回 {start,end,attrs,inner}。 */
function findCell(rowInner, ref) {
  const re = /<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g;
  let m;
  while ((m = re.exec(rowInner)) !== null) {
    const attrs = m[1] || '';
    const got = (/\br="([A-Za-z]+\d+)"/.exec(attrs) || [])[1];
    if (got && got.toUpperCase() === ref.toUpperCase()) {
      return { start: m.index, end: m.index + m[0].length, attrs, inner: m[2] || '' };
    }
  }
  return null;
}

/** 在一段行 XML 里找 `<row ... r="N" ...>`。 */
function findRow(sheetDataInner, rowNum) {
  const re = /<row\b([^>]*?)(?:\/>|>([\s\S]*?)<\/row>)/g;
  let m;
  while ((m = re.exec(sheetDataInner)) !== null) {
    const got = (/\br="(\d+)"/.exec(m[1] || '') || [])[1];
    if (got && Number(got) === rowNum) {
      return { start: m.index, end: m.index + m[0].length, attrs: m[1] || '', inner: m[2] || '' };
    }
  }
  return null;
}

/**
 * 在一张工作表里写入一个单元格。
 *
 * OOXML 的硬规矩（踩了就 Excel 报"文件已损坏"）：
 *   1. 同一行里的 `<c>` 必须**按列号升序**；
 *   2. `<row>` 必须**按行号升序**；
 *   3. 同一行的 `<c>` 的 `r` 属性必须写全（如 `B7`，不能只写 `B`）。
 */
function writeCell(sheetXml, ref, value) {
  const m = /^([A-Za-z]+)(\d+)$/.exec(String(ref).trim());
  if (!m) throw new Error(`cell 写法不对：${ref}（应该像 B7）`);
  const col = m[1].toUpperCase();
  const rowNum = Number(m[2]);
  const fullRef = `${col}${rowNum}`;

  const sdRe = /<sheetData\b[^>]*>([\s\S]*?)<\/sheetData>/;
  const sd = sdRe.exec(sheetXml);
  if (!sd) throw new Error('这个工作表里没有 <sheetData>，不是标准 xlsx');
  const sdInner = sd[1];

  const row = findRow(sdInner, rowNum);
  let nextInner;
  let previous = null;

  if (row) {
    // 行在：先看这一行有没有这个格子
    const cell = findCell(row.inner, fullRef);
    if (cell) {
      // 保留原样式（`s="3"` 之类）—— 用户排好的格式不能被我们抹掉
      const styleAttr = (/\bs="([^"]*)"/.exec(cell.attrs) || [])[0] || '';
      const oldVal = extractCellValue(cell.attrs, cell.inner);
      previous = oldVal;
      const replacement = cellXml(fullRef, value, styleAttr);
      nextInner = row.inner.slice(0, cell.start) + replacement + row.inner.slice(cell.end);
    } else {
      // 行在但格子不在：按列序插到正确位置
      const targetCol = colIndex(col);
      const cells = [...row.inner.matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)];
      let insertAt = row.inner.length;
      for (const c of cells) {
        const got = (/\br="([A-Za-z]+)\d+"/.exec(c[1] || '') || [])[1];
        if (got && colIndex(got.toUpperCase()) > targetCol) {
          insertAt = c.index;
          break;
        }
      }
      const addition = cellXml(fullRef, value);
      nextInner = row.inner.slice(0, insertAt) + addition + row.inner.slice(insertAt);
    }
    const newRow = `<row${row.attrs}>${nextInner}</row>`;
    return { xml: sheetXml.slice(0, sd.index) + sd[1].slice(0, row.start) + newRow + sd[1].slice(row.end) + sheetXml.slice(sd.index + sd[0].length), previous };
  }

  // 行不在：造一行，按行序插到正确位置
  const rows = [...sdInner.matchAll(/<row\b([^>]*?)(?:\/>|>([\s\S]*?)<\/row>)/g)];
  let insertAt = sdInner.length;
  for (const r of rows) {
    const got = (/\br="(\d+)"/.exec(r[1] || '') || [])[1];
    if (got && Number(got) > rowNum) {
      insertAt = r.index;
      break;
    }
  }
  const newRowXml = `<row r="${rowNum}">${cellXml(fullRef, value)}</row>`;
  const newSdInner = sdInner.slice(0, insertAt) + newRowXml + sdInner.slice(insertAt);
  return { xml: sheetXml.slice(0, sd.index) + newSdInner + sheetXml.slice(sd.index + sd[0].length), previous };
}

/** 取一个已存在单元格的值（用来回报"原来是多少"）。 */
function extractCellValue(attrs, inner) {
  const type = (/\bt="([^"]+)"/.exec(attrs) || [])[1] || '';
  if (type === 'inlineStr') {
    const ts = [...inner.matchAll(/<t\b[^>]*>([\s\S]*?)<\/t>/g)].map((t) => xmlUnescapeLocal(t[1]));
    return ts.join('');
  }
  const vm = /<v>([\s\S]*?)<\/v>/.exec(inner);
  const raw = vm ? xmlUnescapeLocal(vm[1]) : '';
  if (type === 's') return raw; // sharedStrings 索引：如实返回索引，不猜内容
  if (type === 'b') return raw === '1';
  if (raw === '') return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : raw;
}

// ─────────────────────────────────────────────────────────── docx 追加

/** 往 docx 正文末尾追加一个段落。 */
function appendParagraph(docXml, text, heading) {
  const body = /<w:body\b[^>]*>([\s\S]*?)<\/w:body>/.exec(docXml);
  if (!body) throw new Error('这个 docx 里没有 <w:body>，不是标准 docx');
  const style = heading ? '<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>' : '';
  const para = `<w:p>${style}<w:r><w:t xml:space="preserve">${xmlEscape(String(text))}</w:t></w:r></w:p>`;
  const inner = body[1];
  const count = (inner.match(/<w:p\b/g) || []).length;
  // 放在最后一个 <w:sectPr> 之前（那是节属性，必须留在最后）
  const sect = inner.lastIndexOf('<w:sectPr');
  const at = sect === -1 ? inner.length : sect;
  const newInner = inner.slice(0, at) + para + inner.slice(at);
  return { xml: docXml.slice(0, body.index) + newInner + docXml.slice(body.index + body[0].length), paragraphs: count + 1 };
}

// ─────────────────────────────────────────────────────────── 文件层

function loadZip(file) {
  const abs = resolve(file);
  if (!existsSync(abs)) throw new Error(`文件不存在：${abs}`);
  const buf = readFileSync(abs);
  if (buf.length < 4 || buf[0] !== 0x50 || buf[1] !== 0x4b) {
    throw new Error(`不是 zip 文件（xlsx/docx 的本质是 zip）：${abs}`);
  }
  return { abs, zip: zipRead(buf) };
}

function saveZip(abs, zip) {
  writeFileSync(abs, zipWrite(zip));
}

/** 选工作表：给了名字就找同名，没给就用第一个。 */
function pickSheet(sheets, sheetName) {
  if (!sheetName) return sheets[0];
  const hit = sheets.find((s) => s.name === sheetName);
  if (!hit) {
    throw new Error(`没有叫「${sheetName}」的工作表；现有的是：${sheets.map((s) => s.name).join('、')}`);
  }
  return hit;
}

// ─────────────────────────────────────────────────────────── 工具实现

const HANDLERS = {
  office_read_cells(args) {
    const { abs, zip } = loadZip(args.file);
    const sheets = listSheets(zip);
    const sheet = pickSheet(sheets, args.sheet);
    const cells = readCells(zip, sheet.path, args.range);
    return { file: abs, sheet: sheet.name, count: cells.length, cells };
  },

  office_write_cell(args) {
    const { abs, zip } = loadZip(args.file);
    const sheets = listSheets(zip);
    const sheet = pickSheet(sheets, args.sheet);
    const part = zip.get(sheet.path);
    if (!part) throw new Error(`工作表部件不在包里：${sheet.path}`);
    const result = writeCell(part.toString('utf8'), args.cell, args.value);
    zip.set(sheet.path, Buffer.from(result.xml, 'utf8'));
    saveZip(abs, zip);
    return {
      file: abs,
      sheet: sheet.name,
      cell: String(args.cell).toUpperCase(),
      previous: result.previous,
      now: args.value,
    };
  },

  office_append_paragraph(args) {
    const { abs, zip } = loadZip(args.file);
    const part = zip.get('word/document.xml');
    if (!part) throw new Error('这个文件里没有 word/document.xml —— 可能不是 .docx');
    const result = appendParagraph(part.toString('utf8'), args.text, args.heading === true);
    zip.set('word/document.xml', Buffer.from(result.xml, 'utf8'));
    saveZip(abs, zip);
    return { file: abs, paragraphs: result.paragraphs, appended: String(args.text) };
  },
};

// ─────────────────────────────────────────────────────────── MCP 协议

/** 工具执行失败时**不要抛 JSON-RPC 错误**，按 MCP 规范在结果里标 isError。 */
function callTool(name, args) {
  const handler = HANDLERS[name];
  if (!handler) return { isError: true, text: `没有这个工具：${name}` };
  try {
    const data = handler(args || {});
    return { isError: false, text: JSON.stringify(data, null, 2) };
  } catch (error) {
    return { isError: true, text: `${name} 失败：${error && error.message ? error.message : String(error)}` };
  }
}

function handleMessage(message) {
  const { id, method, params } = message;
  // 通知（没有 id）不需要回包
  const isNotification = id === undefined || id === null;

  if (method === 'initialize') {
    // 回显客户端要的协议版本：客户端会校验我们回的是它支持的版本
    const version = (params && params.protocolVersion) || '2025-06-18';
    return {
      protocolVersion: version,
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
    };
  }
  if (method === 'ping') return {};
  if (method === 'tools/list') return { tools: TOOLS };
  if (method === 'tools/call') {
    const name = (params && params.name) || '';
    const args = (params && params.arguments) || {};
    const r = callTool(name, args);
    return { content: [{ type: 'text', text: r.text }], isError: r.isError };
  }
  if (isNotification) return null;
  throw new Error(`不支持的方法：${method}`);
}

/** 主循环：stdin 按行读，一行一条 JSON-RPC。 */
function serveStdio() {
  let buffer = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, index).replace(/\r$/, '');
      buffer = buffer.slice(index + 1);
      if (!line.trim()) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch (error) {
        write({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
        continue;
      }
      try {
        const result = handleMessage(message);
        if (result !== null && message.id !== undefined && message.id !== null) {
          write({ jsonrpc: '2.0', id: message.id, result });
        }
      } catch (error) {
        if (message.id !== undefined && message.id !== null) {
          write({
            jsonrpc: '2.0',
            id: message.id,
            error: { code: -32601, message: error && error.message ? error.message : String(error) },
          });
        }
      }
    }
  });
  process.stdin.on('end', () => process.exit(0));
}

function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

// ─────────────────────────────────────────────────────────── 自检

/**
 * 自检：不依赖 MCP 客户端，直接调工具函数，验证"写进去 → 读回来"是通的。
 * （与 MCP 协议层无关，但能证明 OOXML 那半边没写错。）
 */
function selftest() {
  const tmp = resolve('.mcp-office-selftest');
  if (!existsSync(tmp)) mkdirSync(tmp, { recursive: true });
  const xlsx = `${tmp}/selftest.xlsx`;
  const docx = `${tmp}/selftest.docx`;

  // 造一个最小 xlsx（自己拼 ZIP，验证写入路径）
  const sheetRows = '<row r="1"><c r="A1" t="inlineStr"><is><t>姓名</t></is></c>'
    + '<c r="B1" t="inlineStr"><is><t>数量</t></is></c></row>'
    + '<row r="2"><c r="A2" t="inlineStr"><is><t>甲</t></is></c>'
    + '<c r="B2"><v>3</v></c></row>';
  const xlsxZip = new Map();
  xlsxZip.set('[Content_Types].xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    + '<Default Extension="xml" ContentType="application/xml"/>'
    + '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    + '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    + '</Types>');
  xlsxZip.set('_rels/.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    + '</Relationships>');
  xlsxZip.set('xl/workbook.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
    + 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    + '<sheets><sheet name="数据" sheetId="1" r:id="rId1"/></sheets></workbook>');
  xlsxZip.set('xl/_rels/workbook.xml.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
    + '</Relationships>');
  xlsxZip.set('xl/worksheets/sheet1.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    + `<sheetData>${sheetRows}</sheetData></worksheet>`);
  writeFileSync(xlsx, zipWrite(xlsxZip));

  const w = HANDLERS.office_write_cell({ file: xlsx, cell: 'C2', value: 42, sheet: '数据' });
  const r = HANDLERS.office_read_cells({ file: xlsx, range: 'A1:C2' });
  const got = r.cells.find((c) => c.ref === 'C2');
  if (!got || got.value !== 42) {
    throw new Error(`自检失败：C2 写进去读回来是 ${JSON.stringify(got)}（期望 42）`);
  }

  // docx
  const docxZip = new Map();
  docxZip.set('[Content_Types].xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    + '<Default Extension="xml" ContentType="application/xml"/>'
    + '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
    + '</Types>');
  docxZip.set('_rels/.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
    + '</Relationships>');
  docxZip.set('word/document.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    + '<w:body><w:p><w:r><w:t>原文</w:t></w:r></w:p></w:body></w:document>');
  writeFileSync(docx, zipWrite(docxZip));
  HANDLERS.office_append_paragraph({ file: docx, text: '追加的一段' });
  const docAfter = HANDLERS.office_read_cells; // 只是占位，避免未使用告警
  void docAfter;
  const zip2 = zipRead(readFileSync(docx));
  const xml = zip2.get('word/document.xml').toString('utf8');
  if (!xml.includes('追加的一段')) throw new Error('自检失败：docx 段落没追加进去');

  process.stderr.write(`[mcp-office] selftest ok  wrote=${w.cell} read=${got.value}\n`);
  process.exit(0);
}

const isDirectRun = process.argv[1]
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (process.argv.includes('--selftest')) {
  selftest();
} else if (isDirectRun) {
  serveStdio();
} else {
  // 被 import 进来时：什么都不做（保持"库"的行为）
}
