/**
 * make-docx.mjs —— 把 **Markdown / 纯文本**变成**真正的 `.docx`**（Word / WPS 能直接打开）。
 *
 * ## 为什么要有它
 *
 * 手机上**没有 python / pandoc / libreoffice**（见 AGENTS.md 的「本机可用的执行环境」），
 * 于是内置技能里一直如实写着「要 `.docx` 成品做不到」—— 用户拿到 Markdown 还得自己转。
 * 而 docx 的本质就是 **ZIP + XML**，node 自带 `node:zlib`，所以这条路能自己走通。
 *
 * ## 支持的 Markdown 子集（**只支持这些，别的原样当段落**，不假装能渲染完整 MD）
 *
 *   * `#`~`######` 标题（按级别给字号与加粗）
 *   * 普通段落（空行分段）
 *   * `-` / `*` 无序列表、`1.` 有序列表（**用文字前缀 + 缩进**实现 —— 真项目符号要
 *     `numbering.xml`，那会让"最小可用"变成"一堆会错的引用"；这里如实如此）
 *   * `> ` 引用（斜体 + 缩进）
 *   * ``` 围栏代码块（等宽字体 + 底纹）
 *   * `| a | b |` 表格（**真表格**，表头加粗）
 *   * `---` 分隔线
 *   * 行内 `**粗**`、`*斜*`、`` `等宽` ``
 *
 * ## 用法
 *
 *   node make-docx.mjs <输入.md|txt> <输出.docx> [--title "文档标题"]
 *
 * 成功标记（Dart 侧按它认结果，**格式不要改**）：
 *   `[docx] ok paragraphs=<段落数> tables=<表格数> bytes=<字节数> out=<绝对路径>`
 *
 * 退出码：0 成功；1 转换/写出失败；2 参数或环境错误。
 */

import { existsSync, readFileSync, statSync, writeFileSync, mkdirSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { xmlEscape, zipWrite } from './office-zip.mjs';

const HELP = `用法: node make-docx.mjs <输入.md|txt> <输出.docx> [--title "文档标题"]

把 Markdown（子集：标题/段落/列表/引用/代码块/表格/分隔线/行内粗斜等宽）写成真 .docx。

选项:
  --title <文本>   文档标题（写进 docProps，Word 的"属性"里能看到）
`;

function fail(message, code) {
  process.stderr.write(`错误：${message}\n`);
  process.exit(code === undefined ? 1 : code);
}

// ─────────────────────────────────────────────────────────── 行内解析

/**
 * 行内 Markdown → Word 的 run 序列。
 *
 * 只认三种：`**粗**`、`*斜*`、`` `等宽` ``。
 * ⚠️ 用**从左到右扫描**而不是若干条 replace：`replace` 会把刚生成的 XML 属性
 * 再匹配一遍（例如 `**a**b**c**` 的边界），扫描一遍就不会。
 */
export function inlineRuns(text) {
  const runs = [];
  let buf = '';
  let i = 0;
  const push = (t, props = '') => {
    if (t === '') return;
    runs.push(`<w:r>${props ? `<w:rPr>${props}</w:rPr>` : ''}<w:t xml:space="preserve">${xmlEscape(t)}</w:t></w:r>`);
  };
  while (i < text.length) {
    const two = text.slice(i, i + 2);
    if (two === '**') {
      const end = text.indexOf('**', i + 2);
      if (end > i + 2) { push(buf); buf = ''; push(text.slice(i + 2, end), '<w:b/>'); i = end + 2; continue; }
    }
    if (text[i] === '`') {
      const end = text.indexOf('`', i + 1);
      if (end > i + 1) {
        push(buf); buf = '';
        push(text.slice(i + 1, end),
          '<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="Consolas"/>');
        i = end + 1; continue;
      }
    }
    if (text[i] === '*') {
      const end = text.indexOf('*', i + 1);
      if (end > i + 1) { push(buf); buf = ''; push(text.slice(i + 1, end), '<w:i/>'); i = end + 1; continue; }
    }
    buf += text[i];
    i += 1;
  }
  push(buf);
  return runs.join('') || '<w:r><w:t xml:space="preserve"></w:t></w:r>';
}

// ─────────────────────────────────────────────────────────── 段落构造

const HEADING_SIZE = { 1: 40, 2: 32, 3: 28, 4: 26, 5: 24, 6: 24 }; // half-points（w:sz 要 ×2）

/**
 * 段落。
 *
 * @param {object} [o]
 * @param {number} [o.listLevel] 无序/有序列表层级（0 起）；给 `numId` 时必须给
 * @param {number} [o.numId] 1 = 项目符号、2 = 数字编号（见 NUMBERING_XML）
 */
function paragraph(runsXml, { style = '', bold = false, italic = false, indent = 0, spacingBefore = 0, spacingAfter = 120, mono = false, shade = '', numId = 0, listLevel = 0 } = {}) {
  const props = [];
  if (spacingBefore || spacingAfter) {
    props.push(`<w:spacing w:before="${spacingBefore}" w:after="${spacingAfter}"/>`);
  }
  if (style) props.push(`<w:pStyle w:val="${style}"/>`);
  if (numId) {
    // **真的 Word 列表**：编号/项目符号由 numbering.xml 定义，Word 自己渲染 ——
    // 所以在 Word 里插一条会自动重编号，而不是靠"文字前缀"假装。
    props.push(`<w:numPr><w:ilvl w:val="${listLevel}"/><w:numId w:val="${numId}"/></w:numPr>`);
    // 缩进这里**显式再写一遍**：编号定义里也有一份，但显式写出来有两个好处 ——
    // ① 读的人（含 read-docx.mjs）不用解析 numbering.xml 就知道缩进；
    // ② 某些编辑器对 numbering 的缩进继承不一致。hanging 让换行对齐到文字而不是符号。
    props.push(`<w:ind w:left="${720 * (listLevel + 1)}" w:hanging="360"/>`);
  } else if (indent) {
    props.push(`<w:ind w:left="${indent}"/>`);
  }
  if (shade) props.push(`<w:shd w:val="clear" w:color="auto" w:fill="${shade}"/>`);
  const rPr = [];
  if (bold) rPr.push('<w:b/>');
  if (italic) rPr.push('<w:i/>');
  if (mono) rPr.push('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="Consolas"/>');
  const pPr = props.length || rPr.length
    ? `<w:pPr>${props.join('')}${rPr.length ? `<w:rPr>${rPr.join('')}</w:rPr>` : ''}</w:pPr>`
    : '';
  return `<w:p>${pPr}${runsXml}</w:p>`;
}

/**
 * 标题 → **真的标题段落**（`w:pStyle = Heading1..6`）。
 *
 * 为什么不再"直接给每个 run 加粗 + 放大字号"：
 *   * **Word 的导航窗格 / 大纲视图 / 目录**认的是**样式**，不是字号 ——
 *     只加粗放大在 Word 里就是一个"看起来像标题的正文"，导航窗格是空的；
 *   * 也让 `read-docx.mjs` 能**无损读回层级**（否则只能靠"全部加粗 + 字号猜"）。
 *
 * 外观由 styles.xml 里的 Heading1..6 定义（加粗 + 字号 + 段距 + outlineLvl），
 * 所以这里**不给 run 加直接格式** —— 给了反而会让读回来变成 `# **标题**`。
 */
function heading(text, level) {
  return `<w:p><w:pPr><w:pStyle w:val="Heading${level}"/>`
    + `<w:spacing w:before="280" w:after="140"/></w:pPr>`
    + `<w:r><w:t xml:space="preserve">${xmlEscape(text)}</w:t></w:r></w:p>`;
}

/** 分隔线 → 一个**带下边框的空段落**（Word 里真正会画一条线）。 */
function horizontalRule() {
  return '<w:p><w:pPr><w:pBdr>'
    + '<w:bottom w:val="single" w:sz="6" w:space="1" w:color="999999"/>'
    + '</w:pBdr><w:spacing w:before="120" w:after="120"/></w:pPr></w:p>';
}

/** 表格 → 真 `<w:tbl>`（表头加粗；边框用单线）。 */
function table(rowsXml) {
  const border = '<w:tblBorders>'
    + ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']
      .map((s) => `<w:${s} w:val="single" w:sz="4" w:space="0" w:color="999999"/>`).join('')
    + '</w:tblBorders>';
  const body = rowsXml.map((cells, ri) => {
    const tcs = cells.map((c) => {
      const runs = inlineRuns(c);
      const p = ri === 0
        ? `<w:p><w:pPr><w:rPr><w:b/></w:rPr></w:pPr>${runs.replace('<w:r>', '<w:r><w:rPr><w:b/></w:rPr>')}</w:p>`
        : `<w:p>${runs}</w:p>`;
      return `<w:tc><w:tcPr><w:tcW w:w="2400" w:type="dxa"/></w:tcPr>${p}</w:tc>`;
    }).join('');
    return `<w:tr>${tcs}</w:tr>`;
  }).join('');
  return `<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>${border}</w:tblPr>${body}</w:tbl>`;
}

function splitRow(line) {
  let s = line.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|')) s = s.slice(0, -1);
  return s.split('|').map((c) => c.trim());
}

const isTableSeparator = (line) => /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(line) && line.includes('-');

/**
 * Markdown → `word/document.xml` 的 body 内容。
 *
 * 返回值里带 `paragraphs` / `tables` 计数，供成功标记使用。
 */
export function markdownToBody(src) {
  const lines = String(src).replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
  const out = [];
  let paragraphs = 0;
  let tables = 0;
  let inCode = false;
  const codeBuf = [];
  let para = [];

  const flushPara = () => {
    if (para.length === 0) return;
    out.push(paragraph(inlineRuns(para.join(' '))));
    paragraphs += 1;
    para = [];
  };
  const flushCode = () => {
    if (codeBuf.length === 0) return;
    // 整块代码：一段一行，等宽 + 浅灰底纹（不逐行加框，够用且不啰嗦）。
    // `CodeBlock` 样式让 read-docx.mjs 能**确定性地**认出"这是代码、不是正文"。
    for (const cl of codeBuf) {
      out.push(paragraph(
        `<w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="Consolas"/></w:rPr>`
        + `<w:t xml:space="preserve">${xmlEscape(cl === '' ? ' ' : cl)}</w:t></w:r>`,
        { style: 'CodeBlock', spacingBefore: 0, spacingAfter: 0, shade: 'F2F2F2' }));
      paragraphs += 1;
    }
    codeBuf.length = 0;
  };

  /** Markdown 的前导空格 → 列表层级（2 空格或 1 个 Tab 算一级，最多 9 级）。 */
  const listDepth = (raw) => {
    const lead = /^[ \t]*/.exec(raw)[0].replace(/\t/g, '  ').length;
    return Math.min(8, Math.floor(lead / 2));
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];

    // 围栏代码块
    if (/^\s*```/.test(line)) {
      if (inCode) { flushCode(); inCode = false; } else { flushPara(); inCode = true; }
      continue;
    }
    if (inCode) { codeBuf.push(line); continue; }

    // 表格：当前行是 | a | b |，下一行是分隔行
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      flushPara();
      const rows = [splitRow(line)];
      i += 2; // 跳过分隔行
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) { rows.push(splitRow(lines[i])); i += 1; }
      i -= 1;
      out.push(table(rows));
      tables += 1;
      continue;
    }

    // 标题
    const h = /^(#{1,6})\s+(.*)$/.exec(line);
    if (h) { flushPara(); out.push(heading(h[2].trim(), h[1].length)); paragraphs += 1; continue; }

    // 分隔线
    if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
      flushPara();
      out.push(horizontalRule());
      paragraphs += 1;
      continue;
    }

    // 无序列表 → 真项目符号（numId=1）
    const ul = /^(\s*)[-*+]\s+(.*)$/.exec(line);
    if (ul) {
      flushPara();
      out.push(paragraph(inlineRuns(ul[2]),
        { numId: 1, listLevel: listDepth(line), spacingAfter: 60 }));
      paragraphs += 1;
      continue;
    }

    // 有序列表 → 真数字编号（numId=2）。
    // ⚠️ 序号由 **Word 自己**按顺序渲染，所以 Markdown 里若从 `3.` 开始、
    //    或跳号写的，Word 里会是 1./2./3. —— 这一点要如实告诉用户。
    const ol = /^(\s*)(\d+)[.)]\s+(.*)$/.exec(line);
    if (ol) {
      flushPara();
      out.push(paragraph(inlineRuns(ol[3]),
        { numId: 2, listLevel: listDepth(line), spacingAfter: 60 }));
      paragraphs += 1;
      continue;
    }

    // 引用 → `Quote` 样式（斜体 + 缩进都在样式里，读回来就是 `>`）
    const bq = /^\s*>\s?(.*)$/.exec(line);
    if (bq) {
      flushPara();
      out.push(paragraph(inlineRuns(bq[1]), { style: 'Quote', spacingAfter: 80 }));
      paragraphs += 1;
      continue;
    }

    // 空行 → 段落边界
    if (line.trim() === '') { flushPara(); continue; }

    para.push(line.trim());
  }
  flushPara();
  flushCode();

  if (out.length === 0) out.push(paragraph(inlineRuns('')));
  return { body: out.join(''), paragraphs, tables };
}

// ─────────────────────────────────────────────────────────── 样式与编号

const W_NS = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

/**
 * `word/styles.xml`：标题 1–6 + Quote + CodeBlock。
 *
 * ⚠️ 标题必须在这里**定义成真正的标题样式**（`w:name` 叫 `heading N`、
 *    并且带 `w:outlineLvl`）—— Word 的**导航窗格 / 大纲视图 / 自动目录**
 *    认的是这个，不是"加粗 + 大字号"。`outlineLvl` 从 0 起（heading 1 → 0）。
 *
 * 为什么把外观全部放样式里、不给 run 加直接格式：这样 `read-docx.mjs` 读回来
 * 是干净的 `# 标题`，而不是 `# **标题**`（直接格式会被读成行内加粗）。
 */
const STYLES_XML = (() => {
  const headingStyle = (level) => {
    const sz = HEADING_SIZE[level] || 24;
    return `<w:style w:type="paragraph" w:styleId="Heading${level}">`
      + `<w:name w:val="heading ${level}"/>`
      + `<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>`
      + `<w:pPr><w:keepNext/><w:spacing w:before="280" w:after="140"/>`
      + `<w:outlineLvl w:val="${level - 1}"/></w:pPr>`
      + `<w:rPr><w:b/><w:sz w:val="${sz}"/><w:szCs w:val="${sz}"/></w:rPr>`
      + `</w:style>`;
  };
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
    + `<w:styles xmlns:w="${W_NS}">`
    + `<w:docDefaults><w:rPrDefault><w:rPr>`
    + `<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="SimSun"/>`
    + `<w:sz w:val="22"/><w:szCs w:val="22"/>`
    + `</w:rPr></w:rPrDefault><w:pPrDefault/></w:docDefaults>`
    + `<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>`
    + [1, 2, 3, 4, 5, 6].map(headingStyle).join('')
    // 引用：斜体 + 左缩进（`read-docx.mjs` 靠这个样式认出 `>`）
    + `<w:style w:type="paragraph" w:styleId="Quote">`
    + `<w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>`
    + `<w:pPr><w:ind w:left="720"/></w:pPr>`
    + `<w:rPr><w:i/><w:color w:val="555555"/></w:rPr>`
    + `</w:style>`
    // 代码块：等宽 + 浅灰底纹
    + `<w:style w:type="paragraph" w:styleId="CodeBlock">`
    + `<w:name w:val="Code Block"/><w:basedOn w:val="Normal"/>`
    + `<w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/>`
    + `<w:spacing w:before="0" w:after="0"/></w:pPr>`
    + `<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="Consolas"/>`
    + `<w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr>`
    + `</w:style>`
    + `</w:styles>`;
})();

/**
 * `word/numbering.xml`：两条编号定义 —— numId=1 项目符号、numId=2 数字编号，各 9 级。
 *
 * 项目符号用 Word 自己的写法（Symbol 字体的 `F0B7`，也就是那个实心圆点）；
 * 数字用 `%N.` 占位符（`%1` 是第 1 级，依此类推）。
 */
const NUMBERING_XML = (() => {
  const bulletLvls = Array.from({ length: 9 }, (_, i) =>
    `<w:lvl w:ilvl="${i}"><w:start w:val="1"/><w:numFmt w:val="bullet"/>`
    + `<w:lvlText w:val="\uF0B7"/><w:lvlJc w:val="left"/>`
    + `<w:pPr><w:ind w:left="${720 * (i + 1)}" w:hanging="360"/></w:pPr>`
    + `<w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:hint="default"/></w:rPr>`
    + `</w:lvl>`).join('');
  const decimalLvls = Array.from({ length: 9 }, (_, i) =>
    `<w:lvl w:ilvl="${i}"><w:start w:val="1"/><w:numFmt w:val="decimal"/>`
    + `<w:lvlText w:val="%${i + 1}."/><w:lvlJc w:val="left"/>`
    + `<w:pPr><w:ind w:left="${720 * (i + 1)}" w:hanging="360"/></w:pPr>`
    + `</w:lvl>`).join('');
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
    + `<w:numbering xmlns:w="${W_NS}">`
    + `<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>${bulletLvls}</w:abstractNum>`
    + `<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>${decimalLvls}</w:abstractNum>`
    + `<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>`
    + `<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>`
    + `</w:numbering>`;
})();

// ─────────────────────────────────────────────────────────── 组装 docx

export function buildDocx(markdown, { title = '' } = {}) {
  const { body, paragraphs, tables } = markdownToBody(markdown);
  const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z');

  const parts = [
    ['[Content_Types].xml',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">`
      + `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>`
      + `<Default Extension="xml" ContentType="application/xml"/>`
      + `<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>`
      + `<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>`
      + `<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>`
      + `<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>`
      + `</Types>`],
    ['_rels/.rels',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">`
      + `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>`
      + `<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>`
      + `</Relationships>`],
    // document.xml 与 styles/numbering 的关系。**缺这个文件 Word 仍能打开**
    // （靠约定路径），但补上才是完整包：numbering 必须能通过关系找到，
    // 否则一部分阅读器会忽略 `w:numPr`、列表退化成普通段落。
    ['word/_rels/document.xml.rels',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">`
      + `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>`
      + `<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>`
      + `</Relationships>`],
    ['docProps/core.xml',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" `
      + `xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" `
      + `xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">`
      + `<dc:title>${xmlEscape(title)}</dc:title>`
      + `<dc:creator>泡泡猫 DSH 手机版</dc:creator>`
      + `<dcterms:created xsi:type="dcterms:W3CDTF">${now}</dcterms:created>`
      + `</cp:coreProperties>`],
    ['word/styles.xml', STYLES_XML],
    ['word/numbering.xml', NUMBERING_XML],
    ['word/document.xml',
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n`
      + `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">`
      + `<w:body>${body}`
      // 页面设置（A4 大小，左右边距 1440 twips = 1 英寸）
      + `<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>`
      + `<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>`
      + `</w:body></w:document>`],
  ];
  return { buf: zipWrite(parts), paragraphs, tables };
}

// ─────────────────────────────────────────────────────────── 命令行

function parseArgs(argv) {
  const out = { positional: [], title: '' };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--help' || a === '-h') { process.stdout.write(HELP); process.exit(0); }
    else if (a === '--title') out.title = argv[++i] || '';
    else if (a.startsWith('--')) fail(`不认识的选项：${a}`, 2);
    else out.positional.push(a);
  }
  return out;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.positional.length < 2) { process.stderr.write(HELP); process.exit(2); }
  const [inPath, outPath] = args.positional;
  if (!existsSync(inPath)) fail(`输入文件不存在：${inPath}`, 2);

  const text = readFileSync(inPath, 'utf8');
  if (text.trim() === '') fail('输入文件是空的（没有可写进文档的内容）', 1);

  const title = args.title || (/(^|\n)#\s+(.+)/.exec(text) || [])[2] || '';
  let built;
  try {
    built = buildDocx(text, { title: title.trim() });
  } catch (e) {
    fail(`生成 docx 失败：${e.message}`, 1);
  }

  const abs = resolve(outPath);
  try {
    if (!existsSync(dirname(abs))) mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, built.buf);
  } catch (e) {
    fail(`写出失败：${e.message}`, 1);
  }
  const bytes = statSync(abs).size;
  process.stdout.write(
    `[docx] ok paragraphs=${built.paragraphs} tables=${built.tables} bytes=${bytes} out=${abs}\n`,
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
