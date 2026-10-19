#!/usr/bin/env node
'use strict';
/**
 * pptx-design.mjs —— **PPT 的排版引擎**（纯计算，不碰文件系统）。
 *
 * 这是"用 node 重写那层能力"的落点：`make-pptx.mjs` 负责把它算出来的形状树
 * 组装成一个合法的 .pptx（ZIP + OOXML + rels），**排版本身全在这里**。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 为什么要有它（而不是"模板驱动"或"交给模型摆坐标"）
 * ══════════════════════════════════════════════════════════════════════════
 * 上一版 `make-pptx.mjs` 只会两种版式（封面 / 标题+项目符号），而且位置尺寸
 * 全靠**占位符继承**：模型给什么就画什么。结果是：
 *   * 内容一多就**溢出**（PPT 打开不重排，字压在版心外）；
 *   * 想画"卡片 / 时间线 / 对比 / 数据图"就得让模型自己算 EMU 坐标 ——
 *     它算不准，而且每次都不一样；
 *   * 完全没有设计：一套默认配色、一个字号。
 *
 * 所以这层能力拆成三件事，全部**可测、确定性**：
 *   1. **测量与自动缩排**：按字符宽度估算（CJK 1 em / 拉丁 ~0.53 em）算行数，
 *      逐档降字号直到放得下；实在放不下就**自动分页**（续页带"（续）"）。
 *      ⚠️ 估算**宁可高估行数**（字号偏小）也不让它溢出 —— 手机上生成的 PPT
 *      大多在手机/WPS 里看，溢出比字小难受得多。
 *   2. **一套版式库**：封面 / 章节页 / 目录 / 要点 / 卡片 / 时间线 / 两栏对比 /
 *      大数字 / 数据图（形状画的柱状、条形、堆叠）/ 引用 / 图片 / 结尾。
 *      模型只需要**选版式 + 给内容**，坐标由引擎算。
 *   3. **设计令牌**：主题（配色）、字号阶梯、间距栅格、页脚页码。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 产出的是**原生形状**（不是图片、不是 HTML 截图）
 * ══════════════════════════════════════════════════════════════════════════
 * 每张幻灯片里的色块、圆角卡片、圆点、连线、柱子、文字都是 PowerPoint 自己
 * 的对象：打开后能选中、改颜色、改文字、改大小。这也是"原生 PPT"与
 * "把网页截成图塞进去"的区别。
 *
 * ⚠️ 数据图是**用形状画的**（柱子/条形/堆叠条 + 数值标签），**不是** OOXML
 *    的图表对象（`c:chart`）—— 后者要另外一整套 chart XML + 内嵌 xlsx。
 *    取舍写在 `docs/CHANGES-2026-10-16.md`：形状图表能被任何人一眼看懂、能改，
 *    代价是"数据改了要重新生成"。
 */

// ─────────────────────────────────────────────────────────── 基本单位

/** 1 英寸 = 914400 EMU；1 pt = 12700 EMU */
export const EMU_PER_PT = 12700;

/** 16:9：12192000 x 6858000 EMU（13.333in x 7.5in） */
export const SLIDE_W = 12192000;
export const SLIDE_H = 6858000;

/** 版心与栅格（左右各留 838200 EMU ≈ 0.92in） */
export const GRID = Object.freeze({
  margin: 838200,
  contentW: SLIDE_W - 838200 * 2,
  titleY: 620000,
  titleH: 900000,
  bodyY: 1720000,
  footerY: 6180000,
  footerH: 340000,
  gap: 260000,
});

/** 版心底（正文可用高度的下界）：页脚之上留一点呼吸 */
const BODY_BOTTOM = GRID.footerY - 220000;
const BODY_H = BODY_BOTTOM - GRID.bodyY;

const pt = (v) => Math.round(v * EMU_PER_PT);

// ─────────────────────────────────────────────────────────── 主题（配色）

/**
 * 三档颜色：底（bg/面）、字（ink 标题 / body 正文 / muted 次要）、强调（accent）。
 * 全部用 `srgbClr` 写死 —— 不依赖 theme1 的配色映射，换主题不会串色。
 */
export const THEMES = Object.freeze({
  ink: {
    label: '墨蓝',
    bg: 'FFFFFF', surface: 'F2F5F9', line: 'DCE3EC',
    ink: '12233B', body: '33465F', muted: '7C8CA3',
    accent: '1F5FBD', accentDeep: '143F80', accentSoft: 'E3EDFB',
  },
  ocean: {
    label: '海蓝',
    bg: 'FFFFFF', surface: 'EEF6F7', line: 'D3E6E8',
    ink: '0E2F35', body: '2C545C', muted: '78949A',
    accent: '0E8A8F', accentDeep: '0A6165', accentSoft: 'DCF0F0',
  },
  forest: {
    label: '苔绿',
    bg: 'FFFFFF', surface: 'F1F6EE', line: 'DBE7D5',
    ink: '1B2E1C', body: '3B523C', muted: '83977F',
    accent: '3C7A3E', accentDeep: '2A592C', accentSoft: 'E4F0E2',
  },
  sunrise: {
    label: '暖橘',
    bg: 'FFFFFF', surface: 'FDF3EC', line: 'F2DDCE',
    ink: '3A2415', body: '5F4230', muted: 'A08472',
    accent: 'D2691E', accentDeep: '9E4C14', accentSoft: 'FBE7D6',
  },
  berry: {
    label: '莓紫',
    bg: 'FFFFFF', surface: 'F7F0F6', line: 'E8D8E5',
    ink: '2E1830', body: '53375A', muted: '9A829C',
    accent: '8E3B8E', accentDeep: '6A2A6A', accentSoft: 'F1E1F0',
  },
  mono: {
    label: '灰阶',
    bg: 'FFFFFF', surface: 'F4F5F6', line: 'DFE2E5',
    ink: '1C1F21', body: '3D4448', muted: '858C91',
    accent: '3D4448', accentDeep: '23282B', accentSoft: 'ECEEEF',
  },
});

const DEFAULT_THEME = 'ink';

/** 取主题：名字不认识就回默认（**宽进**，不让一个错别字把整份 PPT 打死）。 */
export function resolveTheme(name) {
  const key = String(name || '').trim().toLowerCase();
  if (THEMES[key]) return { ...THEMES[key], key };
  return { ...THEMES[DEFAULT_THEME], key: DEFAULT_THEME };
}

// ─────────────────────────────────────────────────────────── 文本测量

const CJK = [
  [0x1100, 0x115f], [0x2329, 0x232a], [0x2e80, 0xa4cf], [0xac00, 0xd7a3],
  [0xf900, 0xfaff], [0xfe30, 0xfe6f], [0xff00, 0xff60], [0xffe0, 0xffe6],
  [0x20000, 0x3fffd],
];

function isWide(code) {
  for (const [a, b] of CJK) if (code >= a && code <= b) return true;
  return false;
}

/**
 * 一个字符占几个"em"（1 em = 当前字号）。
 *
 * 这些系数是**经验值**，不是字体度量 —— 我们没有字体文件（离线、纯 node）。
 * 只要方向对就行：中文/全角标点按 1 em，拉丁小写数字约 0.53，大写约 0.62，
 * 空格 0.28。偏大一点点是我们想要的（宁可字号小，也别溢出）。
 */
export function charWidthEm(ch) {
  const code = ch.codePointAt(0);
  if (code === 0x20) return 0.28;
  if (code === 0x09) return 1.0;
  if (isWide(code)) return 1.0;
  if (ch >= 'A' && ch <= 'Z') return 0.62;
  if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) return 0.53;
  if ('.,:;!|\'`'.includes(ch)) return 0.28;
  if ('()[]{}<>'.includes(ch)) return 0.34;
  if ('-_/\\+='.includes(ch)) return 0.5;
  return 0.6;
}

/** 一段文字的总宽度（EMU）。`\n` 按最长的那一行算。 */
export function measureTextEmu(text, sizePt) {
  let widest = 0;
  for (const line of String(text == null ? '' : text).split('\n')) {
    let em = 0;
    for (const ch of line) em += charWidthEm(ch);
    if (em > widest) widest = em;
  }
  return Math.round(widest * sizePt * EMU_PER_PT);
}

/**
 * 一段文字**折行后有几行**（贪心，逐字符累加）。
 *
 * 拉丁文按空格断词（累加时把空格挂起，超宽时先丢空格再断）；CJK 逐字可断。
 * ⚠️ 这是估算：真实字体宽度会有出入（WPS/PowerPoint 各自的内置字体）。
 *    所以 `fitText()` 的用时**只往小里选字号**，行数估算宁可偏多。
 */
export function countLines(text, boxWidthEmu, sizePt) {
  const maxEm = Math.max(1, boxWidthEmu / (sizePt * EMU_PER_PT));
  let lines = 0;
  for (const para of String(text == null ? '' : text).split('\n')) {
    if (para === '') { lines += 1; continue; }
    let cur = 0;
    let n = 1;
    let pending = 0;
    for (const ch of para) {
      const w = charWidthEm(ch);
      if (ch === ' ') { pending += w; continue; }
      if (cur + pending + w > maxEm + 1e-9 && cur > 0) {
        n += 1;
        cur = w;
      } else {
        cur += pending + w;
      }
      pending = 0;
    }
    lines += n;
  }
  return lines;
}

/** 一段（含项目符号的）文字占多高：行数 × 行高 + 段间距。 */
function blockHeightEmu(text, boxWidthEmu, sizePt, opts = {}) {
  const lineFactor = opts.lineFactor == null ? 1.28 : opts.lineFactor;
  const gapPt = opts.gapPt == null ? 0.42 : opts.gapPt;
  const lines = countLines(text, boxWidthEmu, sizePt);
  return Math.round(lines * sizePt * lineFactor * EMU_PER_PT + sizePt * gapPt * EMU_PER_PT);
}

// ─────────────────────────────────────────────────────────── 自动缩排

/**
 * 要点页字号的**可读下限**（pt）。低于它就不缩了，改成拆续页 —— 见 make-pptx 的
 * `expandSlides()`：两者必须用同一个下限，否则"引擎认为放得下、拆分却没触发"，
 * 结果就是继续缩到看不清。
 */
export const BULLET_MIN_PT = 12;

/** 项目符号的缩进阶梯（EMU）：level 0/1/2 */
const BULLET_MARL = [GRID.gap, GRID.gap + 300000, GRID.gap + 600000];

function normalizedBullets(bullets) {
  const out = [];
  for (const b of Array.isArray(bullets) ? bullets : []) {
    if (b == null) continue;
    const obj = typeof b === 'object' ? b : { text: b };
    const text = String(obj.text == null ? obj.content : obj.text).trim();
    if (!text) continue;
    const level = Math.max(0, Math.min(2, Math.round(Number(obj.level) || 0)));
    out.push({ text, level });
  }
  return out;
}

/**
 * 把一组项目符号**塞进**给定的框，返回落定的字号。
 *
 * 字号阶梯（pt）：18 → 16 → 15 → 14 → 13 → 12 → 11 → 10.5 → 10 → 9.5。
 * 放不下就一路降；降到最小还放不下 → `ok:false`，调用方**分页**（见 splitBullets）。
 * 返回 { size, ok, height }。
 */
export function fitBullets(bullets, widthEmu, heightEmu, opts = {}) {
  const maxPt = opts.maxPt == null ? 18 : opts.maxPt;
  const minPt = opts.minPt == null ? 9.5 : opts.minPt;
  const list = normalizedBullets(bullets);
  let size = maxPt;
  let height = 0;
  for (; size >= minPt - 1e-9; size -= 0.5) {
    height = 0;
    for (const b of list) {
      const marL = BULLET_MARL[b.level];
      height += blockHeightEmu(b.text, Math.max(1, widthEmu - marL), size, opts);
    }
    if (height <= heightEmu) return { size: roundHalf(size), ok: true, height };
  }
  return { size: roundHalf(minPt), ok: false, height };
}

const roundHalf = (v) => Math.round(v * 2) / 2;

/**
 * 放不下就**分页**：按高度切成两半，返回 [第一页, 第二页…]。
 *
 * 每页都重新 `fitBullets`（第二页内容少，字号自然回到大的那档）——所以这里只
 * 负责"切"，不负责"多大"，避免出现"续页还是小字"。
 */
export function splitBullets(bullets, widthEmu, heightEmu, opts = {}) {
  const list = normalizedBullets(bullets);
  const minPt = opts.minPt == null ? 9.5 : opts.minPt;
  const pages = [];
  let rest = list;
  let guard = 0;
  while (rest.length > 0 && guard < 60) {
    guard += 1;
    const fit = fitBullets(rest, widthEmu, heightEmu, opts);
    if (fit.ok) { pages.push(rest); break; }

    // ① 先看"第一条自己"放不放得下。放不下 → 说明**这一条本身就超长**
    //    （模型把一整篇文章塞进一条要点是常见输入），必须把这条切开，
    //    否则后面每一页都会带着这个"装不下的东西"往下滚。
    const single = fitBullets([rest[0]], widthEmu, heightEmu, opts);
    if (!single.ok) {
      const marL = BULLET_MARL[rest[0].level];
      const availW = Math.max(1, widthEmu - marL);
      const maxLines = Math.max(1, Math.floor(heightEmu / (minPt * 1.32 * EMU_PER_PT)) - 1);
      const budgetEm = (availW / (minPt * EMU_PER_PT)) * maxLines * 0.92;
      const chars = [...rest[0].text];
      let acc = 0;
      let cut = chars.length;
      for (let i = 0; i < chars.length; i += 1) {
        acc += charWidthEm(chars[i]);
        if (acc > budgetEm) { cut = Math.max(1, i); break; }
      }
      const head = chars.slice(0, cut).join('');
      const tail = chars.slice(cut).join('');
      pages.push([{ text: head, level: rest[0].level }]);
      rest = [tail ? { text: tail, level: rest[0].level } : null, ...rest.slice(1)]
        .filter((b) => b && b.text);
      continue;
    }

    // ② 找"能放下的最大前缀"：从一半开始往两边找，找到就把剩下的留到下一页
    let take = Math.max(1, Math.ceil(rest.length / 2));
    for (let i = take; i >= 1; i -= 1) {
      const probe = fitBullets(rest.slice(0, i), widthEmu, heightEmu, opts);
      if (probe.ok) { take = i; break; }
      if (i === 1) take = 1;
    }
    pages.push(rest.slice(0, take));
    rest = rest.slice(take);
  }
  if (pages.length === 0) pages.push([]);
  return pages;
}

// ─────────────────────────────────────────────────────────── XML 片段

const XML_NONE = '';

function esc(value) {
  return String(value == null ? '' : value)
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/** 光栅图/矢量图都用形状画，图片走 make-pptx 的 media 通道（见 picXml）。 */
export function srgb(hex) {
  const v = String(hex || '000000').replace('#', '').toUpperCase();
  return v.length === 6 ? v : '000000';
}

function solidFillXml(hex, alpha) {
  const a = alpha == null ? '' : `<a:alpha val="${Math.round(alpha * 1000)}"/>`;
  return `<a:solidFill><a:srgbClr val="${srgb(hex)}">${a}</a:srgbClr></a:solidFill>`;
}

function lineXml(hex, widthPt, alpha) {
  if (!hex) return '<a:ln><a:noFill/></a:ln>';
  return `<a:ln w="${pt(widthPt == null ? 1 : widthPt)}" cap="flat" cmpd="sng" algn="ctr">`
    + solidFillXml(hex, alpha)
    + '<a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>';
}

const FONT_LATIN = 'Calibri';
const FONT_EA = '等线';

function typefacesXml() {
  return `<a:latin typeface="${FONT_LATIN}"/><a:ea typeface="${FONT_EA}"/>`
    + `<a:cs typeface="${FONT_LATIN}"/>`;
}

function rPrXml(o) {
  const attrs = [
    'lang="zh-CN"',
    'altLang="en-US"',
    `sz="${Math.round((o.size || 18) * 100)}"`,
    o.bold ? 'b="1"' : '',
    o.italic ? 'i="1"' : '',
    'dirty="0"',
  ].filter(Boolean).join(' ');
  return `<a:rPr ${attrs}>`
    + solidFillXml(o.color || '000000', o.alpha)
    + (o.spacing ? `<a:spc val="${Math.round(o.spacing * 100)}"/>` : '')
    + typefacesXml()
    + '</a:rPr>';
}

/**
 * 行内强调：`**粗体**`。
 *
 * 模型写幻灯片正文时天然爱用 Markdown 加粗（这是它们训练里的高频写法）。
 * 不处理的话，PPT 上就会**原样显示两个星号** —— 看起来像没写完的稿子。
 * 所以这里把 `**…**` 拆成若干 run，粗的那段单独加 `b="1"`。
 *
 * ⚠️ 只认 `**粗体**` 这一种（斜体/代码/链接不处理，星号会原样保留）：
 *    宁可少做一种，也不要把正常文字里的 `*` 吃掉。
 */
function inlineRuns(line, o) {
  const out = [];
  const re = /\*\*([^*]+)\*\*/g;
  let last = 0;
  let m;
  while ((m = re.exec(line))) {
    if (m.index > last) out.push({ text: line.slice(last, m.index), bold: false });
    out.push({ text: m[1], bold: true });
    last = m.index + m[0].length;
  }
  if (last < line.length) out.push({ text: line.slice(last), bold: false });
  return out.length > 0 ? out : [{ text: line, bold: false }];
}

/** 一段文字 → 一个或多个 `<a:r>`（`\n` 拆 `<a:br/>`，不丢字也不串行）。 */
function runsXml(text, o) {
  return String(text == null ? '' : text)
    .split('\n')
    .map((line) => inlineRuns(line, o)
      .map((seg) => `<a:r>${rPrXml({ ...o, bold: o.bold || seg.bold })}`
        + `<a:t xml:space="preserve">${esc(seg.text)}</a:t></a:r>`)
      .join(''))
    .join('<a:br/>');
}

function pPrXml(o) {
  const attrs = [
    o.marL ? `marL="${Math.round(o.marL)}"` : '',
    o.indent ? `indent="${Math.round(o.indent)}"` : '',
    o.align ? `algn="${o.align}"` : '',
  ].filter(Boolean).join(' ');
  let inner = '';
  if (o.lineFactor) inner += `<a:lnSpc><a:spcPct val="${Math.round(o.lineFactor * 100000)}"/></a:lnSpc>`;
  if (o.spaceBefore != null) inner += `<a:spcBef><a:spcPts val="${Math.round(o.spaceBefore * 100)}"/></a:spcBef>`;
  if (o.spaceAfter != null) inner += `<a:spcAft><a:spcPts val="${Math.round(o.spaceAfter * 100)}"/></a:spcAft>`;
  if (o.bullet === false) inner += '<a:buNone/>';
  else if (o.bulletChar) {
    inner += `<a:buClr>${solidFillXml(o.bulletColor || '000000')}</a:buClr>`;
    inner += `<a:buFont typeface="Arial"/><a:buChar char="${esc(o.bulletChar)}"/>`;
  }
  return inner || attrs ? `<a:pPr ${attrs}>${inner}</a:pPr>` : '';
}

/** 一个文本段。 */
export function para(text, o = {}) {
  return `<a:p>${pPrXml(o)}${runsXml(text, o)}</a:p>`;
}

function bodyPrXml(o = {}) {
  const attrs = [
    `wrap="${o.wrap || 'square'}"`,
    `lIns="${o.lIns == null ? 91440 : o.lIns}"`,
    `tIns="${o.tIns == null ? 45720 : o.tIns}"`,
    `rIns="${o.rIns == null ? 91440 : o.rIns}"`,
    `bIns="${o.bIns == null ? 45720 : o.bIns}"`,
    `anchor="${o.anchor || 't'}"`,
  ];
  if (o.vertical) attrs.push(`vert="${o.vertical}"`);
  attrs.push('rot="0"');
  // `<a:normAutofit/>`：让我们算完之后，PowerPoint 自己还能再缩一档兜底
  // （换了字体、或用户往里加字时，不至于压出版心）。
  const autofit = o.noAutofit ? '' : '<a:normAutofit/>';
  return `<a:bodyPr ${attrs.join(' ')}>${autofit}</a:bodyPr><a:lstStyle/>`;
}

function xfrmXml(x, y, cx, cy) {
  return `<a:xfrm><a:off x="${Math.round(x)}" y="${Math.round(y)}"/>`
    + `<a:ext cx="${Math.round(Math.max(1, cx))}" cy="${Math.round(Math.max(1, cy))}"/></a:xfrm>`;
}

function geomXml(geom, adj) {
  const preset = geom === 'rect' || !geom ? 'rect' : geom;
  const av = adj == null ? '' : `<a:avLst><a:gd name="adj" fmla="val ${Math.round(adj)}"/></a:avLst>`;
  return `<a:prstGeom prst="${preset}">${av || '<a:avLst/>'}</a:prstGeom>`;
}

/**
 * 一个形状（矩形/圆角矩形/椭圆/箭头…），可带文字。
 *
 * `text` 可以是字符串（单段）或 `[{ text, ...opts }]`（多段）。
 */
export function shape(o) {
  const id = o.id;
  // ⚠️ `text` 与 `paras` 是**两个东西**，别混：
  //    * `text`  = 原始文字（字符串 / 多段对象数组）→ 由这里 escape 后生成段落；
  //    * `paras` = **已经拼好的 `a:p` 串**（调用方自己调了 `para()`，比如要点块）。
  //    把拼好的 XML 塞进 `text` 会被再转义一遍 —— 界面上就会显示一坨 `<a:p>`。
  const hasBody = o.text != null || o.paras != null;
  const name = esc(o.name || (hasBody ? '文本框' : '形状'));
  const spPr = xfrmXml(o.x, o.y, o.cx, o.cy)
    + geomXml(o.geom || 'rect', o.adj)
    + (o.fill ? solidFillXml(o.fill, o.alpha) : '<a:noFill/>')
    + (o.line === null ? '<a:ln><a:noFill/></a:ln>' : lineXml(o.line, o.lineWidth, o.lineAlpha));
  const paras = o.paras != null
    ? String(o.paras)
    : (o.text == null
      ? ''
      : (Array.isArray(o.text) ? o.text : [o.text])
        .map((p) => (typeof p === 'string' ? para(p, o) : para(p.text, { ...o, ...p })))
        .join(''));
  const txBody = hasBody
    ? `<p:txBody>${bodyPrXml({ ...o, anchor: o.anchor || 't' })}${paras}</p:txBody>`
    : '';
  const cNvSpPr = hasBody ? '<p:cNvSpPr txBox="1"/>' : '<p:cNvSpPr/>';
  return '<p:sp><p:nvSpPr>'
    + `<p:cNvPr id="${id}" name="${name}"/>${cNvSpPr}<p:nvPr/>`
    + `</p:nvSpPr><p:spPr>${spPr}</p:spPr>${txBody}</p:sp>`;
}

/** 一条直线（连接符）—— 时间线、分隔线、图表基线都用它。 */
export function line(o) {
  const flipH = o.x2 < o.x1 ? ' flipH="1"' : '';
  const flipV = o.y2 < o.y1 ? ' flipV="1"' : '';
  const x = Math.min(o.x1, o.x2);
  const y = Math.min(o.y1, o.y2);
  const cx = Math.abs(o.x2 - o.x1) || 1;
  const cy = Math.abs(o.y2 - o.y1) || 1;
  return '<p:cxnSp><p:nvCxnSpPr>'
    + `<p:cNvPr id="${o.id}" name="${esc(o.name || '连线')}"/>`
    + '<p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>'
    + `<p:spPr><a:xfrm${flipH}${flipV}>`
    + `<a:off x="${Math.round(x)}" y="${Math.round(y)}"/>`
    + `<a:ext cx="${Math.round(cx)}" cy="${Math.round(cy)}"/></a:xfrm>`
    + geomXml('straightConnector1')
    + lineXml(o.color, o.width, o.alpha)
    + '</p:spPr></p:cxnSp>';
}

/** 一张图片（relId 由 make-pptx 侧登记后传进来）。 */
export function picXml(o) {
  return '<p:pic><p:nvPicPr>'
    + `<p:cNvPr id="${o.id}" name="${esc(o.name || '图片')}"/>`
    + '<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/>'
    + '</p:nvPicPr>'
    + `<p:blipFill><a:blip r:embed="${o.relId}"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>`
    + `<p:spPr>${xfrmXml(o.x, o.y, o.cx, o.cy)}${geomXml('rect')}<a:ln><a:noFill/></a:ln></p:spPr>`
    + '</p:pic>';
}

// ─────────────────────────────────────────────────────────── 版式

/**
 * 正文可用框（标题占多高、有没有眉题，都算进去）。
 *
 * 单独导出是有用的：`make-pptx.mjs` 要**在渲染之前**用它判断"这一页的要点放不下"
 * → 拆成续页，而不是等渲染时才发现溢出。
 */
export function bodyBox(slide = {}, opts = {}) {
  let y = GRID.titleY;
  if (opts.kicker != null ? opts.kicker : slide.kicker) y += 300000;
  const bodyY = Math.max(GRID.bodyY, y + GRID.titleH + 60000);
  return { y: bodyY, h: Math.max(400000, BODY_BOTTOM - bodyY) };
}

/**
 * 一页的"骨架"：页眉装饰 + 标题 + 可选副标题，返回 { shapes, bodyY, bodyH }。
 * 所有内容版式都从它起步 —— 这样"标题在哪儿、正文从哪开始"只有一处定义。
 */
function frame(ctx, opts = {}) {
  const { theme, slide } = ctx;
  const shapes = [];
  let id = 2;
  const nextId = () => id++;

  const kicker = opts.kicker == null ? slide.kicker : opts.kicker;
  let y = GRID.titleY;
  if (kicker) {
    shapes.push(shape({
      id: nextId(),
      name: '眉题',
      x: GRID.margin, y: y - 30000, cx: GRID.contentW, cy: 300000,
      paras: para(String(kicker).toUpperCase(), {
        size: 11, color: theme.accent, bold: true, spacing: 1.2, bullet: false,
      }),
      anchor: 'b',
    }));
    y += 300000;
  }
  // 标题左侧的强调竖条：整套设计的"签名"
  shapes.push(shape({
    id: nextId(), name: '标题条',
    x: GRID.margin, y: y + 120000, cx: 76000, cy: 460000,
    fill: theme.accent, line: null,
  }));
  shapes.push(shape({
    id: nextId(),
    name: '标题',
    x: GRID.margin + 200000, y, cx: GRID.contentW - 200000, cy: GRID.titleH,
    paras: para(slide.title, { size: opts.titlePt || 30, color: theme.ink, bold: true, bullet: false, lineFactor: 1.1 }),
    anchor: 't',
  }));
  const bodyY = bodyBox(slide, { kicker }).y;
  return { shapes, bodyY, bodyH: Math.max(400000, BODY_BOTTOM - bodyY), nextId };
}

/** 页脚：一处页码 + 一处自定义页脚文字（封面/结尾页不画）。 */
function footer(ctx, pageNo, total) {
  const { theme, deck } = ctx;
  const shapes = [];
  if (deck.footer) {
    shapes.push(shape({
      id: 900, name: '页脚',
      x: GRID.margin, y: GRID.footerY, cx: GRID.contentW - 700000, cy: GRID.footerH,
      paras: para(deck.footer, { size: 9, color: theme.muted, bullet: false }),
      anchor: 'ctr',
    }));
  }
  if (deck.pageNumbers !== false && pageNo != null) {
    shapes.push(shape({
      id: 901, name: '页码',
      x: SLIDE_W - GRID.margin - 600000, y: GRID.footerY, cx: 600000, cy: GRID.footerH,
      paras: para(`${pageNo} / ${total}`, { size: 9, color: theme.muted, bullet: false, align: 'r' }),
      anchor: 'ctr',
    }));
  }
  return shapes;
}

/** 抽出"内容行"：卡片 / 时间线 / 大数字 / 图表 都从这几个别名里取。 */
function itemsOf(slide, alias) {
  for (const key of alias) {
    const v = slide[key];
    if (Array.isArray(v) && v.length > 0) return v;
  }
  return [];
}

function itemFields(raw, i) {
  if (raw == null) return { title: '', text: '' };
  if (typeof raw !== 'object') return { title: String(raw), text: '' };
  const title = String(raw.title == null ? (raw.label == null ? (raw.name == null ? '' : raw.name) : raw.label) : raw.title);
  const text = String(raw.text == null ? (raw.desc == null ? (raw.body == null ? (raw.detail == null ? '' : raw.detail) : raw.body) : raw.desc) : raw.text);
  return { title: title || `第 ${i + 1} 项`, text };
}

const LAYOUTS = {
  // ── 封面 ─────────────────────────────────────────────────────────────
  cover(ctx) {
    const { theme, deck, slide } = ctx;
    const shapes = [];
    shapes.push(shape({ id: 2, name: '底', x: 0, y: 0, cx: SLIDE_W, cy: SLIDE_H, fill: theme.bg, line: null }));
    // 左侧色带 + 右下装饰块（都是可选中、可改色的原生形状）
    shapes.push(shape({ id: 3, name: '色带', x: 0, y: 0, cx: 300000, cy: SLIDE_H, fill: theme.accent, line: null }));
    shapes.push(shape({
      id: 4, name: '装饰块', x: SLIDE_W - 2100000, y: SLIDE_H - 900000,
      cx: 1500000, cy: 260000, fill: theme.accentSoft, line: null, adj: 50000, geom: 'roundRect',
    }));
    const x = GRID.margin + 300000;
    const w = GRID.contentW - 900000;
    // 标题/副标题都按自己的框**收缩**：模型给的标题可能很长（一句话摘要），
    // 40pt 摆不下时逐档降到 22pt，而不是压到副标题上去。
    const titlePt = fitSingle(slide.title, w, 1440000, 4, 22, 40);
    shapes.push(shape({
      id: 5, name: '主标题', x, y: 2180000, cx: w, cy: 1500000,
      paras: para(slide.title, { size: titlePt, color: theme.ink, bold: true, bullet: false, lineFactor: 1.12 }),
      anchor: 'b',
    }));
    if (slide.subtitle) {
      shapes.push(shape({
        id: 6, name: '副标题', x, y: 3740000, cx: w, cy: 900000,
        paras: para(slide.subtitle, {
          size: fitSingle(slide.subtitle, w, 860000, 3, 11),
          color: theme.body, bullet: false, lineFactor: 1.3,
        }),
      }));
    }
    shapes.push(shape({
      id: 7, name: '细线', x, y: 3620000, cx: 900000, cy: 42000,
      fill: theme.accent, line: null,
    }));
    const meta = [deck.author, slide.date || deck.date].filter(Boolean).join('　·　');
    if (meta) {
      shapes.push(shape({
        id: 8, name: '署名', x, y: 4900000, cx: w, cy: 400000,
        paras: para(meta, { size: 12, color: theme.muted, bullet: false }),
      }));
    }
    return shapes;
  },

  // ── 章节页 ───────────────────────────────────────────────────────────
  section(ctx) {
    const { theme, slide, pageNo } = ctx;
    const shapes = [];
    shapes.push(shape({ id: 2, name: '底', x: 0, y: 0, cx: SLIDE_W, cy: SLIDE_H, fill: theme.accentDeep, line: null }));
    shapes.push(shape({
      id: 3, name: '大号数字', x: GRID.margin, y: 1500000, cx: 2200000, cy: 1600000,
      paras: para(slide.number || `0${pageNo || 1}`, { size: 72, color: theme.accentSoft, bold: true, bullet: false }),
      anchor: 'b',
    }));
    shapes.push(shape({
      id: 4, name: '章节标题', x: GRID.margin, y: 3200000, cx: GRID.contentW, cy: 1200000,
      paras: para(slide.title, {
        size: fitSingle(slide.title, GRID.contentW, 1140000, 3, 20, 34),
        color: 'FFFFFF', bold: true, bullet: false, lineFactor: 1.15,
      }),
    }));
    if (slide.subtitle) {
      shapes.push(shape({
        id: 5, name: '章节说明', x: GRID.margin, y: 4300000, cx: GRID.contentW - 1000000, cy: 900000,
        paras: para(slide.subtitle, { size: 15, color: theme.accentSoft, bullet: false, lineFactor: 1.35 }),
      }));
    }
    return shapes;
  },

  // ── 目录 ─────────────────────────────────────────────────────────────
  toc(ctx) {
    const { theme, slide } = ctx;
    const list = itemsOf(slide, ['items', 'steps', 'toc']).map((it, i) => {
      const f = itemFields(it, i);
      return { title: f.title, text: f.text };
    });
    if (list.length === 0) return LAYOUTS.bullets(ctx);
    const { shapes, bodyY, bodyH, nextId } = frame(ctx, { titlePt: 28 });
    const cols = list.length > 6 ? 2 : 1;
    const per = Math.ceil(list.length / cols);
    const colW = (GRID.contentW - (cols - 1) * GRID.gap) / cols;
    const rowH = Math.min(760000, bodyH / per);
    list.forEach((it, i) => {
      const c = Math.floor(i / per);
      const r = i % per;
      const x = GRID.margin + c * (colW + GRID.gap);
      const y = bodyY + r * rowH;
      const size = Math.max(12, Math.min(17, Math.floor((rowH - 260000) / (EMU_PER_PT * 1.4))));
      shapes.push(shape({
        id: nextId(), name: `序号 ${i + 1}`,
        x, y: y + 40000, cx: 520000, cy: 520000,
        paras: para(String(i + 1).padStart(2, '0'), { size: size - 2, color: 'FFFFFF', bold: true, bullet: false, align: 'ctr' }),
        fill: theme.accent, line: null, anchor: 'ctr', geom: 'roundRect', adj: 30000,
      }));
      const entryBody = it.text
        ? {
            text: [
              { text: it.title, size, color: theme.ink, bullet: false, spaceAfter: 2 },
              { text: it.text, size: Math.max(10, size - 3), color: theme.muted, bullet: false },
            ],
          }
        : { paras: para(it.title, { size, color: theme.ink, bullet: false }) };
      shapes.push(shape({
        id: nextId(), name: `条目 ${i + 1}`,
        x: x + 640000, y, cx: colW - 640000, cy: rowH - 60000,
        ...entryBody,
        anchor: 'ctr',
      }));
    });
    return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
  },

  // ── 要点（默认） ─────────────────────────────────────────────────────
  bullets(ctx) {
    const { theme, slide } = ctx;
    const { shapes, bodyY, bodyH, nextId } = frame(ctx, { titlePt: 30 });
    const bullets = normalizedBullets(slide.bullets != null ? slide.bullets : slide.lines);
    if (bullets.length === 0) {
      // 只有标题的页也要像样：画一条提示线
      shapes.push(shape({
        id: nextId(), name: '空提示', x: GRID.margin, y: bodyY, cx: GRID.contentW, cy: 600000,
        paras: para(ctx.emptyHint, { size: 13, color: theme.muted, bullet: false }),
      }));
      return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
    }
    // ⚠️ 要点页的字号下限是 **12pt**（可读性下限），不是绝对下限 9.5：
    //    内容再多也不缩到看不清 —— 交给 `expandSlides()` 拆续页。
    //
    // 2026-10-20（用户「PPT 做出来非常普通、简陋」）：原来这一页就是**白底黑字一个文本框** ——
    // 而大多数页都会落到 bullets，于是整份看起来没设计。现在给正文一张**软卡片**
    // （surface 底 + 细描边 + 圆角）+ 左侧**强调细线**，文字往里收，与标题左侧那根
    // 强调条是同一套语言。版式逻辑、字体下限、自动拆页都不动。
    // 2~4 条**并列短句**（全是一级、每条 ≤ 34 个显示宽度）→ 直接排卡片墙。
    // 这类内容占真实使用的很大比例，排成卡片后整份看起来才不"简陋"。
    const allTop = bullets.every((b) => b.level === 0);
    const shortList = bullets.length >= 3 && bullets.length <= 6;
    const shortText = bullets.every((b) => displayLen(b.text) <= 34);
    if (allTop && shortList && shortText) {
      return [...shapes, ...bulletsAsCards(ctx, nextId, bullets, bodyY, bodyH),
        ...footer(ctx, ctx.pageNo, ctx.totalPages)];
    }
    const CARD_PAD = 300000;      // 卡片内边距（EMU，约 24pt）
    const GUTTER = 150000;        // 卡片内左侧留给强调线的位置
    const fit = fitBullets(bullets, GRID.contentW - CARD_PAD * 2 - GUTTER, bodyH - CARD_PAD * 2, {
      maxPt: slide.big ? 20 : 18,
      minPt: BULLET_MIN_PT,
    });
    shapes.push(shape({
      id: nextId(), name: '正文卡片',
      x: GRID.margin, y: bodyY, cx: GRID.contentW, cy: bodyH,
      fill: theme.surface, line: theme.line, lineWidth: 6350,
      geom: 'roundRect', adj: 12000,
    }));
    shapes.push(shape({
      id: nextId(), name: '强调线',
      x: GRID.margin + 140000, y: bodyY + CARD_PAD,
      cx: 60000, cy: Math.max(240000, bodyH - CARD_PAD * 2),
      fill: theme.accent, line: null, geom: 'roundRect', adj: 50000,
    }));
    shapes.push(bulletBlock(ctx, nextId, bullets, fit.size,
        bodyY + CARD_PAD, bodyH - CARD_PAD * 2, {
          x: GRID.margin + CARD_PAD + GUTTER,
          width: GRID.contentW - CARD_PAD * 2 - GUTTER,
        }));
    return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
  },

  // ── 卡片 ─────────────────────────────────────────────────────────────
  cards(ctx) {
    const { theme, slide } = ctx;
    const items = itemsOf(slide, ['items', 'cards', 'metrics']).map(itemFields);
    if (items.length === 0) return LAYOUTS.bullets(ctx);
    const { shapes, bodyY, bodyH, nextId } = frame(ctx);
    const n = Math.min(items.length, 8);
    const cols = n <= 2 ? n : (n <= 4 ? 2 : (n <= 6 ? 3 : 4));
    const rows = Math.ceil(n / cols);
    const cellW = (GRID.contentW - (cols - 1) * GRID.gap) / cols;
    const cellH = (bodyH - (rows - 1) * GRID.gap) / rows;
    items.slice(0, 8).forEach((it, i) => {
      const c = i % cols;
      const r = Math.floor(i / cols);
      const x = GRID.margin + c * (cellW + GRID.gap);
      const y = bodyY + r * (cellH + GRID.gap);
      shapes.push(shape({
        id: nextId(), name: `卡片底 ${i + 1}`,
        x, y, cx: cellW, cy: cellH, fill: theme.surface, line: theme.line, lineWidth: 0.75,
        geom: 'roundRect', adj: 8000,
      }));
      shapes.push(shape({
        id: nextId(), name: `卡片强调 ${i + 1}`,
        x: x + 20000, y: y + Math.min(360000, cellH * 0.18), cx: 62000, cy: 280000,
        fill: theme.accent, line: null,
      }));
      const pad = 320000;
      const textW = cellW - pad - 200000;
      const titleSize = fitSingle(it.title, textW, Math.min(18, cellH * 0.24 / EMU_PER_PT), 3, 13);
      const bodySize = fitSingle(it.text, textW, Math.max(200000, cellH * 0.55), 3, 10);
      const paras = [{ text: it.title, size: titleSize, color: theme.ink, bold: true, bullet: false, spaceAfter: 4 }];
      if (it.text) paras.push({ text: it.text, size: bodySize, color: theme.body, bullet: false, lineFactor: 1.3 });
      shapes.push(shape({
        id: nextId(), name: `卡片文字 ${i + 1}`,
        x: x + pad, y: y + 220000, cx: cellW - pad - 200000, cy: cellH - 400000,
        text: paras,
      }));
    });
    return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
  },

  // ── 时间线 ───────────────────────────────────────────────────────────
  timeline(ctx) {
    const { theme, slide } = ctx;
    const steps = itemsOf(slide, ['steps', 'items', 'timeline']).map(itemFields);
    if (steps.length === 0) return LAYOUTS.bullets(ctx);
    const { shapes, bodyY, bodyH, nextId } = frame(ctx);
    const n = Math.min(steps.length, 5);
    const use = steps.slice(0, n);
    const axisY = bodyY + Math.min(900000, bodyH * 0.34);
    const slot = GRID.contentW / n;
    const dotR = 150000;
    shapes.push(line({
      id: nextId(), name: '轴线',
      x1: GRID.margin + slot / 2, y1: axisY, x2: GRID.margin + GRID.contentW - slot / 2, y2: axisY,
      color: theme.line, width: 2,
    }));
    use.forEach((it, i) => {
      const cx = GRID.margin + slot * (i + 0.5);
      shapes.push(shape({
        id: nextId(), name: `节点 ${i + 1}`,
        x: cx - dotR, y: axisY - dotR, cx: dotR * 2, cy: dotR * 2,
        fill: theme.accent, line: 'FFFFFF', lineWidth: 1.5, geom: 'ellipse',
      }));
      const boxW = slot - 200000;
      shapes.push(shape({
        id: nextId(), name: `步骤说明 ${i + 1}`,
        x: cx - boxW / 2, y: axisY + dotR + 120000, cx: boxW,
        cy: Math.max(400000, BODY_BOTTOM - axisY - dotR - 160000),
        text: [
          { text: it.title, size: 15, color: theme.ink, bold: true, bullet: false, align: 'ctr', spaceAfter: 3 },
          ...(it.text ? [{ text: it.text, size: 11.5, color: theme.body, bullet: false, align: 'ctr', lineFactor: 1.3 }] : []),
        ],
      }));
      // 阶段名/日期（若给了）放在轴线上面
      const above = String(it.date == null ? (it.when == null ? '' : it.when) : it.date);
      if (above) {
        shapes.push(shape({
          id: nextId(), name: `阶段 ${i + 1}`,
          x: cx - boxW / 2, y: axisY - dotR - 120000 - 320000, cx: boxW, cy: 320000,
          paras: para(above, { size: 11, color: theme.accent, bold: true, bullet: false, align: 'ctr' }),
          anchor: 'b',
        }));
      }
    });
    return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
  },

  // ── 两栏对比 ─────────────────────────────────────────────────────────
  compare(ctx) {
    const { theme, slide } = ctx;
    const sides = [slide.left, slide.right].filter(Boolean);
    if (sides.length === 0) return LAYOUTS.bullets(ctx);
    const { shapes, bodyY, bodyH, nextId } = frame(ctx);
    const colW = (GRID.contentW - GRID.gap) / 2;
    sides.forEach((side, i) => {
      const x = GRID.margin + i * (colW + GRID.gap);
      const accent = i === 0 ? theme.accent : theme.accentDeep;
      shapes.push(shape({
        id: nextId(), name: `对比底 ${i + 1}`,
        x, y: bodyY, cx: colW, cy: bodyH,
        fill: i === 0 ? theme.accentSoft : theme.surface, line: theme.line, lineWidth: 0.75,
        geom: 'roundRect', adj: 6000,
      }));
      const head = String(typeof side === 'object' ? (side.title || side.label || '') : '');
      let innerY = bodyY;
      if (head) {
        shapes.push(shape({
          id: nextId(), name: `对比标题 ${i + 1}`,
          x: x + 260000, y: bodyY + 200000, cx: colW - 520000, cy: 520000,
          paras: para(head, { size: 18, color: accent, bold: true, bullet: false }),
          anchor: 'b',
        }));
        innerY = bodyY + 800000;
      }
      const list = normalizedBullets(side && typeof side === 'object' ? (side.bullets || side.items || side.lines) : []);
      const availH = bodyY + bodyH - innerY - 220000;
      if (list.length > 0) {
        const fit = fitBullets(list, colW - 520000, availH, { maxPt: 15, minPt: 9 });
        const pages = fit.ok ? [list] : splitBullets(list, colW - 520000, availH, { maxPt: 15, minPt: 9 });
        const shown = pages[0];
        const size2 = fitBullets(shown, colW - 520000, availH, { maxPt: 15, minPt: 9 }).size;
        shapes.push(bulletBlock(ctx, nextId, shown, size2, innerY, availH, {
          x, width: colW, padX: 260000, bulletColor: accent,
          overflowNote: pages.length > 1,
        }));
      } else if (typeof side === 'string') {
        shapes.push(shape({
          id: nextId(), name: `对比正文 ${i + 1}`,
          x: x + 260000, y: innerY, cx: colW - 520000, cy: availH,
          paras: para(side, { size: 13, color: theme.body, bullet: false, lineFactor: 1.35 }),
        }));
      }
    });
    return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
  },

  // ── 大数字 ───────────────────────────────────────────────────────────
  metrics(ctx) {
    const { theme, slide } = ctx;
    const raw = itemsOf(slide, ['metrics', 'items', 'stats']);
    if (raw.length === 0) return LAYOUTS.bullets(ctx);
    const items = raw.map((it, i) => {
      if (it && typeof it === 'object') {
        const value = String(it.value == null ? (it.number == null ? '' : it.number) : it.value);
        const label = String(it.label == null ? (it.title == null ? '' : it.title) : it.label);
        const note = String(it.note == null ? (it.text == null ? '' : it.text) : it.note);
        return { value, label, note };
      }
      return { value: String(it), label: '', note: '' };
    });
    const { shapes, bodyY, bodyH, nextId } = frame(ctx);
    const n = Math.min(items.length, 4);
    const slot = GRID.contentW / n;
    const valueSize = Math.max(26, Math.min(48, (slot - 200000) / (EMU_PER_PT * 3.4)));
    items.slice(0, n).forEach((it, i) => {
      const x = GRID.margin + slot * i;
      shapes.push(shape({
        id: nextId(), name: `数字 ${i + 1}`,
        x: x + 60000, y: bodyY + Math.max(0, bodyH * 0.16), cx: slot - 120000, cy: 1200000,
        paras: para(it.value, { size: valueSize, color: theme.accent, bold: true, bullet: false, align: 'ctr' }),
        anchor: 'b',
      }));
      shapes.push(shape({
        id: nextId(), name: `说明 ${i + 1}`,
        x: x + 60000, y: bodyY + Math.max(0, bodyH * 0.16) + 1260000, cx: slot - 120000, cy: 700000,
        text: [
          { text: it.label, size: 14, color: theme.ink, bold: true, bullet: false, align: 'ctr', spaceAfter: 3 },
          ...(it.note ? [{ text: it.note, size: 11, color: theme.muted, bullet: false, align: 'ctr', lineFactor: 1.3 }] : []),
        ],
      }));
      if (i > 0) {
        shapes.push(line({
          id: nextId(), name: `分隔 ${i}`,
          x1: x, y1: bodyY + 300000, x2: x, y2: bodyY + bodyH - 300000,
          color: theme.line, width: 1,
        }));
      }
    });
    return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
  },

  // ── 数据图（形状画的柱状 / 条形 / 堆叠条） ───────────────────────────
  chart(ctx) {
    const { theme, slide } = ctx;
    const spec = slide.chart && typeof slide.chart === 'object' ? slide.chart : {};
    const data = (Array.isArray(spec.data) ? spec.data : itemsOf(slide, ['data', 'items']))
      .map((d, i) => {
        const label = String((d && (d.label || d.name || d.title)) || `第 ${i + 1} 项`);
        const value = Number(d && (d.value != null ? d.value : d.number));
        return { label, value: Number.isFinite(value) ? value : 0 };
      });
    if (data.length === 0) return LAYOUTS.bullets(ctx);
    const { shapes, bodyY, bodyH, nextId } = frame(ctx);
    const kind = String(spec.kind || 'bar').toLowerCase();
    const unit = spec.unit ? String(spec.unit) : '';
    const maxVal = Math.max(...data.map((d) => d.value), 0.0001);
    const fmt = (v) => (Math.abs(v) >= 1000 ? String(Math.round(v)) : String(Math.round(v * 100) / 100));

    if (kind === 'hbar') {
      const rowH = Math.min(760000, (bodyH - 200000) / data.length);
      const labelW = Math.min(GRID.contentW * 0.3, 2600000);
      const barX = GRID.margin + labelW + 160000;
      const barW = GRID.margin + GRID.contentW - barX - 900000;
      data.forEach((d, i) => {
        const y = bodyY + i * rowH;
        shapes.push(shape({
          id: nextId(), name: `标签 ${i + 1}`,
          x: GRID.margin, y, cx: labelW, cy: rowH - 80000,
          paras: para(d.label, { size: 13, color: theme.ink, bullet: false }),
          anchor: 'ctr',
        }));
        const w = Math.max(40000, (d.value / maxVal) * barW);
        shapes.push(shape({
          id: nextId(), name: `条 ${i + 1}`,
          x: barX, y: y + rowH * 0.22, cx: barW, cy: rowH * 0.5,
          fill: theme.surface, line: null, geom: 'roundRect', adj: 30000,
        }));
        shapes.push(shape({
          id: nextId(), name: `条值 ${i + 1}`,
          x: barX, y: y + rowH * 0.22, cx: w, cy: rowH * 0.5,
          fill: theme.accent, line: null, geom: 'roundRect', adj: 30000,
        }));
        shapes.push(shape({
          id: nextId(), name: `数值 ${i + 1}`,
          x: barX + barW + 120000, y, cx: 780000, cy: rowH - 80000,
          paras: para(fmt(d.value) + unit, { size: 12.5, color: theme.accentDeep, bold: true, bullet: false }),
          anchor: 'ctr',
        }));
      });
      return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
    }

    if (kind === 'stacked') {
      const total = data.reduce((s, d) => s + Math.max(0, d.value), 0) || 1;
      const barY = bodyY + 400000;
      const barH = Math.min(900000, bodyH * 0.32);
      const palette = [theme.accent, theme.accentDeep, theme.accentSoft, theme.muted, theme.body, theme.surface];
      let x = GRID.margin;
      data.forEach((d, i) => {
        const w = ((Math.max(0, d.value) / total) * GRID.contentW);
        shapes.push(shape({
          id: nextId(), name: `段 ${i + 1}`,
          x, y: barY, cx: w, cy: barH, fill: palette[i % palette.length], line: 'FFFFFF', lineWidth: 1,
        }));
        if (w > 700000) {
          shapes.push(shape({
            id: nextId(), name: `段内数值 ${i + 1}`,
            x, y: barY, cx: w, cy: barH,
            paras: para(`${Math.round((d.value / total) * 100)}%`, {
              size: 13, color: i === 2 ? theme.ink : 'FFFFFF', bold: true, bullet: false, align: 'ctr',
            }),
            anchor: 'ctr',
          }));
        }
        x += w;
      });
      // 图例
      let lx = GRID.margin;
      const legendY = barY + barH + 300000;
      data.forEach((d, i) => {
        const textW = measureTextEmu(d.label, 11);
        shapes.push(shape({
          id: nextId(), name: `图例色 ${i + 1}`,
          x: lx, y: legendY + 60000, cx: 150000, cy: 150000,
          fill: palette[i % palette.length], line: null,
        }));
        shapes.push(shape({
          id: nextId(), name: `图例字 ${i + 1}`,
          x: lx + 220000, y: legendY, cx: textW + 300000, cy: 280000,
          paras: para(`${d.label} ${fmt(d.value)}${unit}`, { size: 11, color: theme.body, bullet: false }),
          anchor: 'ctr',
        }));
        lx += textW + 700000;
        if (lx > GRID.margin + GRID.contentW - 800000) lx = GRID.margin;
      });
      return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
    }

    // 默认：竖柱
    const axisY = bodyY + bodyH - 420000;
    const plotH = axisY - bodyY - 260000;
    const slot = GRID.contentW / data.length;
    const barW = Math.min(slot * 0.52, 900000);
    shapes.push(line({
      id: nextId(), name: '基线', x1: GRID.margin, y1: axisY, x2: GRID.margin + GRID.contentW, y2: axisY,
      color: theme.line, width: 1.5,
    }));
    data.forEach((d, i) => {
      const cx = GRID.margin + slot * (i + 0.5);
      const h = Math.max(30000, (Math.max(0, d.value) / maxVal) * plotH);
      shapes.push(shape({
        id: nextId(), name: `柱 ${i + 1}`,
        x: cx - barW / 2, y: axisY - h, cx: barW, cy: h,
        fill: theme.accent, line: null, geom: 'roundRect', adj: 12000,
      }));
      shapes.push(shape({
        id: nextId(), name: `柱值 ${i + 1}`,
        x: cx - barW / 2 - 120000, y: axisY - h - 340000, cx: barW + 240000, cy: 320000,
        paras: para(fmt(d.value) + unit, { size: 12, color: theme.accentDeep, bold: true, bullet: false, align: 'ctr' }),
        anchor: 'b',
      }));
      shapes.push(shape({
        id: nextId(), name: `柱标签 ${i + 1}`,
        x: cx - slot / 2 + 60000, y: axisY + 60000, cx: slot - 120000, cy: 360000,
        paras: para(d.label, { size: 11.5, color: theme.body, bullet: false, align: 'ctr' }),
      }));
    });
    return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
  },

  // ── 引用 ─────────────────────────────────────────────────────────────
  quote(ctx) {
    const { theme, slide } = ctx;
    const shapes = [];
    shapes.push(shape({ id: 2, name: '底', x: 0, y: 0, cx: SLIDE_W, cy: SLIDE_H, fill: theme.surface, line: null }));
    shapes.push(shape({
      id: 3, name: '引号', x: GRID.margin, y: 1400000, cx: 900000, cy: 900000,
      paras: para('“', { size: 96, color: theme.accentSoft, bold: true, bullet: false }),
    }));
    const text = String(slide.text || slide.quote || slide.title || '');
    const size = fitSingle(text, GRID.contentW - 1200000, 2400000, 6, 16, 24);
    shapes.push(shape({
      id: 4, name: '引文', x: GRID.margin + 400000, y: 2260000, cx: GRID.contentW - 1200000, cy: 2200000,
      paras: para(text, { size, color: theme.ink, bullet: false, lineFactor: 1.42 }),
    }));
    const cite = String(slide.cite || slide.author || slide.source || '');
    if (cite) {
      shapes.push(shape({
        id: 5, name: '出处', x: GRID.margin + 400000, y: 4600000, cx: GRID.contentW - 1200000, cy: 400000,
        paras: para(`—— ${cite}`, { size: 13, color: theme.muted, bullet: false }),
      }));
    }
    shapes.push(shape({
      id: 6, name: '竖线', x: GRID.margin + 200000, y: 2300000, cx: 60000, cy: 2100000,
      fill: theme.accent, line: null,
    }));
    return shapes;
  },

  // ── 图片 ─────────────────────────────────────────────────────────────
  image(ctx) {
    const { theme, slide } = ctx;
    const resolved = ctx.image && ctx.image.forSlide(slide);
    const { shapes, bodyY, bodyH, nextId } = frame(ctx, { titlePt: 28 });
    if (!resolved) {
      shapes.push(shape({
        id: nextId(), name: '缺图提示',
        x: GRID.margin, y: bodyY, cx: GRID.contentW, cy: bodyH,
        fill: theme.surface, line: theme.line, lineWidth: 0.75, geom: 'roundRect', adj: 6000,
        paras: para(ctx.imageMissingHint, { size: 13, color: theme.muted, bullet: false, align: 'ctr' }),
        anchor: 'ctr',
      }));
      return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
    }
    const captionH = slide.caption ? 420000 : 0;
    const boxH = bodyH - captionH;
    const side = String(slide.layout || '').toLowerCase();
    const textFirst = side === 'imageright' || side === 'image-right';
    const text = normalizedBullets(slide.bullets || slide.lines);
    const hasText = text.length > 0;
    const split = hasText ? Math.round(GRID.contentW * 0.54) : GRID.contentW;
    const imgBox = textFirst
      ? { x: GRID.margin + split + GRID.gap, y: bodyY, w: GRID.contentW - split - GRID.gap, h: boxH }
      : { x: GRID.margin, y: bodyY, w: split, h: boxH };
    const fitBox = contain(resolved.cx, resolved.cy, imgBox.w, imgBox.h);
    shapes.push(picXml({
      id: nextId(), name: '图片',
      relId: resolved.relId,
      x: imgBox.x + (imgBox.w - fitBox.cx) / 2,
      y: imgBox.y + (imgBox.h - fitBox.cy) / 2,
      cx: fitBox.cx, cy: fitBox.cy,
    }));
    if (hasText) {
      const textX = textFirst ? GRID.margin : GRID.margin + split + GRID.gap;
      const textW = GRID.contentW - split - GRID.gap;
      const fit = fitBullets(text, textW, boxH, { maxPt: 15, minPt: 9.5 });
      const pages = fit.ok ? [text] : splitBullets(text, textW, boxH, { maxPt: 15, minPt: 9.5 });
      const size = fitBullets(pages[0], textW, boxH, { maxPt: 15, minPt: 9.5 }).size;
      shapes.push(bulletBlock(ctx, nextId, pages[0], size, bodyY, boxH, {
        x: textX, width: textW, padX: 0, overflowNote: pages.length > 1,
      }));
    }
    if (slide.caption) {
      shapes.push(shape({
        id: nextId(), name: '图注',
        x: imgBox.x, y: bodyY + boxH, cx: imgBox.w, cy: captionH,
        paras: para(slide.caption, { size: 10.5, color: theme.muted, bullet: false, align: 'ctr' }),
        anchor: 'ctr',
      }));
    }
    return [...shapes, ...footer(ctx, ctx.pageNo, ctx.totalPages)];
  },

  // ── 结尾 ─────────────────────────────────────────────────────────────
  end(ctx) {
    const { theme, slide, deck } = ctx;
    const shapes = [];
    shapes.push(shape({ id: 2, name: '底', x: 0, y: 0, cx: SLIDE_W, cy: SLIDE_H, fill: theme.accentDeep, line: null }));
    shapes.push(shape({
      id: 3, name: '结语', x: GRID.margin, y: 2500000, cx: GRID.contentW, cy: 1200000,
      paras: para(slide.title, {
        size: fitSingle(slide.title, GRID.contentW, 1140000, 3, 22, 40),
        color: 'FFFFFF', bold: true, bullet: false, align: 'ctr',
      }),
      anchor: 'b',
    }));
    const sub = slide.subtitle || deck.author;
    if (sub) {
      shapes.push(shape({
        id: 4, name: '结语副标题', x: GRID.margin, y: 3860000, cx: GRID.contentW, cy: 600000,
        paras: para(sub, { size: 15, color: theme.accentSoft, bullet: false, align: 'ctr' }),
      }));
    }
    return shapes;
  },
};

/** 只放一段文字时的字号收敛（卡片/引用用）。 */
function fitSingle(text, widthEmu, maxHeightEmu, maxLines, minPt, startPt = 18) {
  const t = String(text == null ? '' : text);
  if (!t.trim()) return minPt;
  for (let size = startPt; size >= minPt; size -= 0.5) {
    const h = blockHeightEmu(t, widthEmu, size, { lineFactor: 1.3 });
    // ⚠️ 两个条件都要满足（`&&`，不是 `||`）：只看行数会漏掉"行数够但整体太高"，
    //    只看高度会漏掉"框很高但只许三行"的排版约定。本轮就是 `||` 放跑了一个
    //    50 字的封面标题（3 行 ≤ 4 行 → 于是 40pt 原样输出，压到了副标题上）。
    if (h <= maxHeightEmu && countLines(t, widthEmu, size) <= maxLines) return roundHalf(size);
  }
  return minPt;
}

/** 项目符号块（要点页与对比 / 图片页共用）。 */
/** 一串文字的"显示宽度"（中日韩算 2，其余算 1）—— 判断"够不够短"用。 */
function displayLen(text) {
  let n = 0;
  for (const ch of String(text == null ? '' : text).replace(/\*\*/g, '')) {
    n += ch.codePointAt(0) > 0x2e80 ? 2 : 1;
  }
  return n;
}

/**
 * 2~4 条**并列短句**排成卡片墙（2026-10-20，用户「PPT 太简陋」）。
 *
 * 为什么要有它：真实使用里最常见的一页就是「几条并列的事」，而模型通常写成
 * `bullets` —— 原来的 bullets 只是**一个文本框**，整页白底黑字，所以整份 PPT 显得简陋。
 * 这里在 bullets 内部把这类内容排成卡片（和 `cards` 版式同一套几何），
 * **不改版式契约**：模型仍只需写 `bullets: ['…','…']`。
 */
function bulletsAsCards(ctx, nextId, bullets, bodyY, bodyH) {
  const { theme } = ctx;
  const shapes = [];
  const n = bullets.length;
  const cols = n <= 3 ? n : (n <= 4 ? 2 : 3);
  const rows = Math.ceil(n / cols);
  const cellW = (GRID.contentW - (cols - 1) * GRID.gap) / cols;
  const cellH = (bodyH - (rows - 1) * GRID.gap) / rows;
  bullets.forEach((b, i) => {
    const c = i % cols;
    const r = Math.floor(i / cols);
    const x = GRID.margin + c * (cellW + GRID.gap);
    const y = bodyY + r * (cellH + GRID.gap);
    shapes.push(shape({
      id: nextId(), name: `并列卡片底 ${i + 1}`,
      x, y, cx: cellW, cy: cellH,
      fill: theme.surface, line: theme.line, lineWidth: 0.75,
      geom: 'roundRect', adj: 8000,
    }));
    shapes.push(shape({
      id: nextId(), name: `并列卡片强调 ${i + 1}`,
      x: x + 20000, y: y + Math.min(360000, cellH * 0.16), cx: 62000, cy: 260000,
      fill: theme.accent, line: null,
    }));
    const pad = 300000;
    shapes.push(shape({
      id: nextId(), name: `并列卡片文字 ${i + 1}`,
      x: x + pad + 90000, y: y + pad,
      cx: cellW - pad * 2 - 90000, cy: cellH - pad * 2,
      text: [{ text: b.text, size: n <= 3 ? 20 : 16, color: theme.ink, bold: true, bullet: false, lineFactor: 1.25 }],
      anchor: 'ctr',
    }));
  });
  return shapes;
}

function bulletBlock(ctx, nextId, bullets, size, y, height, o = {}) {
  const { theme } = ctx;
  const x = o.x == null ? GRID.margin : o.x;
  const width = o.width == null ? GRID.contentW : o.width;
  const padX = o.padX == null ? 0 : o.padX;
  const color = o.bulletColor || theme.accent;
  const chars = ['●', '–', '·'];
  const paras = bullets.map((b) => {
    const marL = BULLET_MARL[b.level];
    return para(b.text, {
      size: Math.max(9.5, size - b.level * 1.5),
      color: b.level === 0 ? theme.body : theme.muted,
      bullet: true,
      bulletChar: chars[b.level],
      bulletColor: color,
      marL,
      indent: -Math.max(120000, Math.min(240000, size * 0.6 * EMU_PER_PT)),
      lineFactor: 1.3,
      spaceBefore: 3,
      spaceAfter: 3,
    });
  }).join('');
  const note = o.overflowNote
    ? para(ctx.overflowHint, { size: 9.5, color: theme.muted, bullet: false, spaceBefore: 6 })
    : '';
  return shape({
    id: nextId(), name: '正文',
    x: x + padX, y, cx: width - padX * 2, cy: height,
    paras: paras + note,
  });
}

/** 图片按"完整放进框"等比缩放（contain）。 */
function contain(imgW, imgH, boxW, boxH) {
  const w = imgW > 0 ? imgW : 4;
  const h = imgH > 0 ? imgH : 3;
  const scale = Math.min(boxW / w, boxH / h);
  return { cx: Math.round(w * scale), cy: Math.round(h * scale) };
}

/** 版式别名（模型爱写哪个写哪个）。 */
const LAYOUT_ALIASES = Object.freeze({
  title: 'cover', 'title-slide': 'cover', opening: 'cover',
  divider: 'section', chapter: 'section',
  agenda: 'toc', outline: 'toc', contents: 'toc',
  bullet: 'bullets', content: 'bullets', list: 'bullets', text: 'bullets',
  card: 'cards', grid: 'cards', tiles: 'cards',
  steps: 'timeline', road: 'timeline', process: 'timeline',
  compare: 'compare', comparison: 'compare', versus: 'compare', two: 'compare',
  metrics: 'metrics', stats: 'metrics', numbers: 'metrics', kpi: 'metrics',
  chart: 'chart', bars: 'chart', data: 'chart', graph: 'chart',
  quote: 'quote', citation: 'quote',
  image: 'image', picture: 'image', photo: 'image',
  'image-right': 'image', imageright: 'image', 'image-left': 'image',
  closing: 'end', thanks: 'end', end: 'end', final: 'end',
});

/** 没写 layout 时按内容字段**猜**一个（猜不出来就是要点页）。 */
export function inferLayout(slide) {
  if (!slide || typeof slide !== 'object') return 'bullets';
  const raw = String(slide.layout == null ? '' : slide.layout).trim().toLowerCase();
  if (raw) {
    if (LAYOUTS[raw]) return raw;
    if (LAYOUT_ALIASES[raw]) return LAYOUT_ALIASES[raw];
  }
  if (Array.isArray(slide.chart) || (slide.chart && typeof slide.chart === 'object')) return 'chart';
  if (Array.isArray(slide.metrics) || Array.isArray(slide.stats) || Array.isArray(slide.numbers)) return 'metrics';
  if (Array.isArray(slide.steps) || Array.isArray(slide.timeline)) return 'timeline';
  if (slide.left || slide.right || Array.isArray(slide.columns)) return 'compare';
  if (slide.image || slide.picture || slide.photo) return 'image';
  if (slide.quote || slide.cite || slide.source) return 'quote';
  if (Array.isArray(slide.cards) || Array.isArray(slide.items) || Array.isArray(slide.tiles)) return 'cards';
  if (slide.number && !slide.bullets && !slide.lines && !slide.items) return 'section';
  return 'bullets';
}

export const LAYOUT_NAMES = Object.freeze([...Object.keys(LAYOUTS), ...Object.keys(LAYOUT_ALIASES)]);

/**
 * 生成一页幻灯片的形状树（`<p:spTree>` 的内容）。
 *
 * @param {object} ctx
 *   ctx.slide      归一化后的这一页
 *   ctx.theme      主题（resolveTheme 的结果）
 *   ctx.deck       整份 deck（拿 footer/author/pageNumbers）
 *   ctx.pageNo     页码（1 起；封面不画页脚）
 *   ctx.totalPages 总页数
 *   ctx.image      { forSlide(slide) → { relId, cx, cy } | null }
 *   ctx.emptyHint / ctx.overflowHint / ctx.imageMissingHint  三句本地化提示
 * @returns {string} `<p:grpSpPr>` 之后那一串形状 XML（调用方自己拼 grpSpPr）
 */
export function buildSlideShapes(ctx) {
  const layoutName = ctx.slide && ctx.slide.layout ? ctx.slide.layout : inferLayout(ctx.slide);
  const fn = LAYOUTS[layoutName] || LAYOUTS.bullets;
  const shapes = fn(ctx).filter(Boolean);
  return { layout: layoutName, shapes };
}

/** 一页该不该带页眉/页脚（封面、章节页、结尾页不画）。 */
export function layoutHasFooter(name) {
  return name === 'bullets' || name === 'cards' || name === 'timeline' ||
    name === 'compare' || name === 'metrics' || name === 'chart' ||
    name === 'toc' || name === 'image';
}
