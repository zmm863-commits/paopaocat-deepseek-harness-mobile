/**
 * test-mcp-office.mjs —— 用**官方 MCP 客户端**（SDK v2）连我们的 `mcp-office.mjs`，
 * 走一遍真实协议：initialize → tools/list → tools/call → 读回。
 *
 * ## 为什么必须用官方客户端验
 *
 * MCP 的 stdio 传输是"每行一条 JSON-RPC"，看着简单，但客户端会**严格校验**响应结构
 * （SDK v2 甚至按协议年代冻结了 wire schema）。手写服务端最容易错在：
 *   - `initialize` 回的 `protocolVersion` 不在客户端支持列表里；
 *   - `tools/call` 的结果形状不合规（`content` / `isError` / `structuredContent`）；
 *   - 通知（`notifications/initialized`）错误地回了包。
 * 这些光看代码看不出来，**必须让真客户端连一次**才算数。
 *
 * ## 跑法
 *
 *   node install/test-mcp-office.mjs
 *
 * 需要能找到 MCP SDK。默认去 DSH 的安装目录找（那里有 @modelcontextprotocol/client）：
 *   D:\Programs\PaopaocatDSH\app\node_modules
 * 也可以用环境变量指定：DSH_APP_HOME
 *
 * ⚠️ 离线可用：整个测试不联网、不调模型。
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
// ⚠️ 必须用 fileURLToPath：URL.pathname 对中文目录是**百分号编码**的，
// 直接用会得到 "D:%E6%96%B0..." 这种不存在的路径（本项目路径里全是中文）。
const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');
const SERVER = join(REPO, 'app', 'assets', 'toolbox', 'mcp-office.mjs');
const SDK_ROOTS = [
  process.env.DSH_APP_HOME ? join(process.env.DSH_APP_HOME, 'node_modules') : null,
  'D:/Programs/PaopaocatDSH/app/node_modules',
].filter(Boolean);

/** 找到 MCP SDK 的 ESM 入口（不用 require 条件，避免 CJS/ESM 互操作问题）。 */
function findSdk() {
  for (const root of SDK_ROOTS) {
    const base = join(root, '@modelcontextprotocol', 'client', 'dist');
    const index = join(base, 'index.mjs');
    const stdio = join(base, 'stdio.mjs');
    if (existsSync(index) && existsSync(stdio)) return { index, stdio };
  }
  throw new Error(
    `找不到 MCP 客户端 SDK。试过：\n  ${SDK_ROOTS.join('\n  ')}\n`
    + '可以用 DSH_APP_HOME 环境变量指到 DSH 的安装目录。',
  );
}

function ok(label) {
  process.stderr.write(`[test-mcp-office] ok  ${label}\n`);
}

function fail(message) {
  process.stderr.write(`[test-mcp-office] FAIL  ${message}\n`);
  process.exit(1);
}

async function main() {
  if (!existsSync(SERVER)) fail(`找不到服务端脚本：${SERVER}`);
  const sdk = findSdk();
  const clientMod = await import(pathToFileURL(sdk.index).href);
  const stdioMod = await import(pathToFileURL(sdk.stdio).href);
  const { Client } = clientMod;
  const { StdioClientTransport } = stdioMod;
  if (!Client || !StdioClientTransport) fail('SDK 里没找到 Client / StdioClientTransport');

  // ── 造两个夹具文件（xlsx / docx）
  const tmp = join(REPO, '.mcp-office-test');
  if (!existsSync(tmp)) mkdirSync(tmp, { recursive: true });
  const xlsx = join(tmp, 'case.xlsx');
  const docx = join(tmp, 'case.docx');
  const { zipWrite, zipRead } = await import(
    pathToFileURL(join(REPO, 'app', 'assets', 'toolbox', 'office-zip.mjs')).href
  );
  writeFileSync(xlsx, zipWrite(buildXlsxZip()));
  writeFileSync(docx, zipWrite(buildDocxZip()));

  // ── 连上
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [SERVER],
    env: { ...process.env, DSH_MCP_OFFICE: '1' },
    stderr: 'pipe',
  });
  const client = new Client({ name: 'dsh-mobile-test', version: '0.0.1' }, { capabilities: {} });
  try {
    await client.connect(transport);
    ok('connect（initialize 握手通过）');

    const listed = await client.listTools();
    const names = (listed.tools || []).map((t) => t.name).sort();
    const want = ['office_append_paragraph', 'office_read_cells', 'office_write_cell'];
    if (JSON.stringify(names) !== JSON.stringify(want)) {
      fail(`tools/list 不对：期望 ${want.join(',')}，实际 ${names.join(',')}`);
    }
    ok(`tools/list → ${names.join(', ')}`);

    // 写一个单元格
    const wrote = await client.callTool({
      name: 'office_write_cell',
      arguments: { file: xlsx, cell: 'B2', value: 7, sheet: '数据' },
    });
    if (wrote.isError) fail(`office_write_cell 报错了：${JSON.stringify(wrote.content)}`);
    ok('tools/call office_write_cell → B2=7');

    // 读回来
    const read = await client.callTool({
      name: 'office_read_cells',
      arguments: { file: xlsx, range: 'A1:C2' },
    });
    if (read.isError) fail(`office_read_cells 报错了：${JSON.stringify(read.content)}`);
    const payload = JSON.parse(read.content[0].text);
    const b2 = (payload.cells || []).find((c) => c.ref === 'B2');
    if (!b2 || b2.value !== 7) fail(`读回来不是 7：${JSON.stringify(payload)}`);
    ok('tools/call office_read_cells → 读回 B2=7（协议层往返通）');

    // 追加 docx 段落
    const appended = await client.callTool({
      name: 'office_append_paragraph',
      arguments: { file: docx, text: '协议层追加的段落' },
    });
    if (appended.isError) fail(`office_append_paragraph 报错了：${JSON.stringify(appended.content)}`);
    const docXml = zipRead(readFileSync(docx)).get('word/document.xml').toString('utf8');
    if (!docXml.includes('协议层追加的段落')) fail('docx 里没找到刚追加的段落');
    ok('tools/call office_append_paragraph → docx 里已落段');

    // 错误路径：文件不存在 —— 必须是 isError，而不是整个会话崩
    const bad = await client.callTool({
      name: 'office_read_cells',
      arguments: { file: join(tmp, 'nope.xlsx') },
    });
    if (!bad.isError) fail('文件不存在时应该 isError=true');
    ok('错误路径 → isError=true（会话没崩）');
  } finally {
    await client.close().catch(() => {});
  }
  process.stderr.write('[test-mcp-office] 全部通过\n');
  process.exit(0);
}

/** 一个最小 xlsx：一张工作表「数据」，A1=姓名 B1=数量 A2=甲 B2=3。 */
function buildXlsxZip() {
  const zip = new Map();
  zip.set('[Content_Types].xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    + '<Default Extension="xml" ContentType="application/xml"/>'
    + '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    + '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    + '</Types>');
  zip.set('_rels/.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    + '</Relationships>');
  zip.set('xl/workbook.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
    + 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    + '<sheets><sheet name="数据" sheetId="1" r:id="rId1"/></sheets></workbook>');
  zip.set('xl/_rels/workbook.xml.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
    + '</Relationships>');
  zip.set('xl/worksheets/sheet1.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
    + '<row r="1"><c r="A1" t="inlineStr"><is><t>姓名</t></is></c>'
    + '<c r="B1" t="inlineStr"><is><t>数量</t></is></c></row>'
    + '<row r="2"><c r="A2" t="inlineStr"><is><t>甲</t></is></c>'
    + '<c r="B2"><v>3</v></c></row>'
    + '</sheetData></worksheet>');
  return zip;
}

/** 一个最小 docx：正文一段「原文」。 */
function buildDocxZip() {
  const zip = new Map();
  zip.set('[Content_Types].xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    + '<Default Extension="xml" ContentType="application/xml"/>'
    + '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
    + '</Types>');
  zip.set('_rels/.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
    + '</Relationships>');
  zip.set('word/document.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    + '<w:body><w:p><w:r><w:t>原文</w:t></w:r></w:p></w:body></w:document>');
  return zip;
}

main().catch((error) => {
  fail(error && error.stack ? error.stack : String(error));
});
