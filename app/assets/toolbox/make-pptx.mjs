#!/usr/bin/env node
'use strict';
/**
 * make-pptx.mjs —— 用**纯 Node 内置模块**生成真正的 .pptx（OOXML）。
 *
 * 用法：
 *   node make-pptx.mjs <outline.json> <out.pptx>
 *   node make-pptx.mjs --help
 *
 * outline.json（字段缺省都有合理默认，"宽进"）：
 *   {
 *     "title": "封面标题",            // 缺省 "演示文稿"
 *     "subtitle": "副标题",           // 可选，无则不画副标题
 *     "author": "可选",               // 写进 docProps/core.xml
 *     "slides": [
 *       { "title": "小节标题",
 *         "bullets": ["要点1", "要点2"],   // 也可以是 [{"text":"要点","level":1}] 或单个字符串
 *         "notes": "演讲者备注（可选）" }
 *     ]
 *   }
 *
 * 为什么要自己写而不是用 npm 包 / 外部命令：
 *   Android 上没有 pandoc、没有 python、也不方便装 node_modules，App 只能是
 *   "随包带一个 .mjs，用随包的 node 跑"。所以压缩、加密哈希以外的所有东西
 *   （ZIP 容器、CRC32、OOXML 序列化）都得自己实现，而且必须完全离线。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * OOXML/OPC 的最低要求（少了哪一块会怎样）
 * ══════════════════════════════════════════════════════════════════════════
 * 一个 .pptx 本质是一个 ZIP，里面是一堆 XML 部件 + 关系（rels）图：
 *
 *   [Content_Types].xml
 *        **必须在包根目录**，声明每个部件的内容类型。缺了它或漏一个部件，
 *        PowerPoint 直接判定"文件已损坏"。
 *   _rels/.rels
 *        包级关系：指向 ppt/presentation.xml（officeDocument 类型）与
 *        docProps/core.xml。缺了它 PowerPoint 找不到主部件。
 *   ppt/presentation.xml
 *        主部件：幻灯片尺寸（本例 16:9 = 12192000 x 6858000 EMU）、幻灯片的
 *        顺序（p:sldIdLst）、引用的母版。
 *   ppt/slideMasters/slideMaster1.xml
 *        **必须有**。母版定义配色映射（clrMap）、版式清单（sldLayoutIdLst）、
 *        文字默认样式（txStyles）。缺了它 PowerPoint 无法解析任何一张幻灯片的
 *        继承链 → 报"需要修复"。
 *   ppt/slideLayouts/slideLayoutN.xml
 *        **每张 slide 都必须通过 rels 关到一个版式**。版式里放占位符的位置与
 *        字号，slide 上的占位符通过 `p:ph type/idx` 匹配它继承几何。
 *        缺了版式关联，PowerPoint 打开就报修复。
 *   ppt/slides/slideN.xml
 *        幻灯片本体（这里用占位符：type="title" / idx="1"），
 *        `<p:spPr/>` 故意留空 —— 位置尺寸继承自版式，和 python-pptx 产物一致。
 *   ppt/theme/theme1.xml
 *        **必须有**（母版必须 rel 到它）。themeElements 里的 clrScheme /
 *        fontScheme / fmtScheme 三个都是必需项；fmtScheme 的填充/线/效果/
 *        背景四个列表各要至少 3 项。中文字体就是在这里（ea typeface）生效的。
 *   ppt/notesSlides/notesSlideN.xml（可选）
 *        演讲者备注。一旦有 notesSlide，就还要有 ppt/notesMasters/notesMaster1.xml
 *        （notesSlide 必须 rel 到它），并且它自己 rel 到 theme。
 *
 * 本实现严格按上面的最小合法集生成，不做任何"想当然的省略"。
 */

import { existsSync, readFileSync, statSync, writeFileSync, mkdirSync } from 'node:fs';
import { basename, dirname, extname, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';

import {
  buildSlideShapes,
  bodyBox,
  fitBullets,
  inferLayout,
  resolveTheme,
  splitBullets,
  GRID,
  BULLET_MIN_PT,
  LAYOUT_NAMES,
} from './pptx-design.mjs';

// ─────────────────────────────────────────────────────────── 常量

const XML_DECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';

/** 16:9：12192000 x 6858000 EMU（1 英寸 = 914400 EMU，即 13.333in x 7.5in） */
const SLIDE_W = 12192000;
const SLIDE_H = 6858000;

/** 版心：左右各留 838200 EMU（0.9167 in），够放 16:9 的标题与正文 */
const MARGIN_X = 838200;
const CONTENT_W = SLIDE_W - MARGIN_X * 2;
const TITLE_Y = 457200;
const TITLE_H = 1143000;
const BODY_Y = 1600200;
const BODY_H = 4525963;

/** 中英文字体：Calibri 是 OOXML 的通用西文字体，等线是 Windows/WPS 自带的中文黑体 */
const FONT_LATIN = 'Calibri';
const FONT_EA = '等线';

const NS_A = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const NS_P = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const NS_R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const NS_CT = 'http://schemas.openxmlformats.org/package/2006/content-types';
const NS_REL = 'http://schemas.openxmlformats.org/package/2006/relationships';

const RT = {
  officeDocument: NS_R + '/officeDocument',
  coreProps: 'http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties',
  slideMaster: NS_R + '/slideMaster',
  slideLayout: NS_R + '/slideLayout',
  slide: NS_R + '/slide',
  theme: NS_R + '/theme',
  notesMaster: NS_R + '/notesMaster',
  notesSlide: NS_R + '/notesSlide',
  image: NS_R + '/image',
};

const CT = {
  presentation: 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml',
  slideMaster: 'application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml',
  slideLayout: 'application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml',
  slide: 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml',
  theme: 'application/vnd.openxmlformats-officedocument.theme+xml',
  notesMaster: 'application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml',
  notesSlide: 'application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml',
  coreProps: 'application/vnd.openxmlformats-package.core-properties+xml',
};

/** 版式数量：1=标题（封面）· 2=标题和内容 · 3=**空白**（设计版式用它，形状自带坐标） */
const LAYOUT_COUNT = 3;
/** 设计版式的幻灯片一律挂在"空白"版式上（见 buildParts） */
const BLANK_LAYOUT_INDEX = 3;

const HELP = `make-pptx.mjs —— 纯 Node 内置模块生成真正的 .pptx（离线可用，无 npm 依赖）

用法:
  node make-pptx.mjs <outline.json> <out.pptx>
  node make-pptx.mjs --help

一句话：**你只写内容 + 选版式，排版（坐标、字号、分页）由引擎算**。

整份（都可以不写）:
  {
    "title": "封面标题",             // 缺省 "演示文稿"
    "subtitle": "副标题",
    "author": "作者",
    "date": "2026-10-16",
    "theme": "ink",                 // ink|ocean|forest|sunrise|berry|mono
    "footer": "页脚文字（可选）",
    "pageNumbers": true,            // 缺省 true
    "transition": "fade",           // fade|push|wipe|cover|zoom（缺省：不加转场）
    "hints": { "empty": "…", "overflow": "…", "imageMissing": "…" },
    "slides": [ … ]
  }

一页（layout 不写就按内容字段猜）:
  { "layout": "cover",   "title": "标题", "subtitle": "副标题" }
  { "layout": "section", "number": "01", "title": "第一章", "subtitle": "这章讲什么" }
  { "layout": "toc",     "title": "目录", "items": ["第一部分", "第二部分"] }
  { "layout": "bullets", "title": "要点", "bullets": ["…", {"text":"子项","level":1}] }
  { "layout": "cards",   "title": "三件事", "items": [{"title":"…","text":"…"}] }
  { "layout": "timeline","title": "节奏", "steps": [{"title":"…","text":"…","date":"Q1"}] }
  { "layout": "compare", "title": "对比", "left": {"title":"A","bullets":[…]},
                                            "right": {"title":"B","bullets":[…]} }
  { "layout": "metrics", "title": "数字", "metrics": [{"value":"92%","label":"…","note":"…"}] }
  { "layout": "chart",   "title": "增长", "chart": {"kind":"bar|hbar|stacked","unit":"万",
                                                    "data":[{"label":"Q1","value":12}]} }
  { "layout": "quote",   "text": "…", "cite": "出处" }
  { "layout": "image",   "title": "…", "image": "pic.png", "caption": "…", "bullets":[…] }
  { "layout": "end",     "title": "谢谢" }

自动做的事:
  * 字号按内容**逐档收缩**（18→9.5pt），放不下时**要点页自动拆续页**（带"（续）"）；
  * 卡片/时间线/对比会按条数自动分栏、按格子高度收缩；
  * 图片按原比例等比放进框（不拉伸），找不到图就画占位并给警告；
  * 页脚/页码只画在内容页上（封面、章节页、引用页、结尾页不画）。

退出码: 0 成功；1 生成失败（文件不存在 / JSON 不合法 / 写不进去）；2 参数用法错误。
`;

// ─────────────────────────────────────────────────────────── 小工具

function fail(message) {
  process.stderr.write('错误：' + message + '\n');
  process.exit(1);
}

function usageFail(message) {
  process.stderr.write('错误：' + message + '\n\n' + HELP);
  process.exit(2);
}

/** XML 文本转义 + 丢掉 XML 1.0 不允许的控制字符（模型给的字里偶尔会有） */
function esc(value) {
  return String(value == null ? '' : value)
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/** 关系文件（.rels） */
function relsXml(items) {
  const body = items
    .map((it) => `<Relationship Id="${it.id}" Type="${it.type}" Target="${esc(it.target)}"/>`)
    .join('');
  return `${XML_DECL}<Relationships xmlns="${NS_REL}">${body}</Relationships>`;
}

// ─────────────────────────────────────────────────────────── 文本/段落

/** 字体三件套：西文 + 东亚 + 复杂文种，中文能不能正常显示就看 ea */
function typefaces() {
  return `<a:latin typeface="${FONT_LATIN}"/><a:ea typeface="${FONT_EA}"/><a:cs typeface="${FONT_LATIN}"/>`;
}

/** 一个文本段（换行拆成 <a:br/>，保证不丢字也不串行） */
function runsXml(text, opts) {
  const o = opts || {};
  const rPr =
    `<a:rPr lang="zh-CN" altLang="en-US"${o.size ? ` sz="${o.size}"` : ''}${o.bold ? ' b="1"' : ''} dirty="0">` +
    `<a:solidFill><a:schemeClr val="${o.color || 'tx1'}"/></a:solidFill>` +
    typefaces() +
    '</a:rPr>';
  return String(text == null ? '' : text)
    .split('\n')
    .map((line) => `<a:r>${rPr}<a:t>${esc(line)}</a:t></a:r>`)
    .join('<a:br/>');
}

/** 无项目符号的段落（标题、副标题、备注） */
function plainPara(text, opts) {
  return `<a:p>${runsXml(text, opts)}</a:p>`;
}

/** 带项目符号的段落，level 0/1/2 依次缩进 */
/** 空段落（占位符里必须至少有一个 a:p） */
function emptyPara() {
  return '<a:p><a:endParaRPr lang="zh-CN" dirty="0"/></a:p>';
}

function txBodyXml(paras, bodyPr) {
  const attrs = bodyPr === undefined
    ? ' wrap="square" lIns="91440" tIns="45720" rIns="91440" bIns="45720" anchor="t"'
    : bodyPr;
  return `<p:txBody><a:bodyPr${attrs}/><a:lstStyle/>${paras.join('')}</p:txBody>`;
}

/** 非占位符的普通文本框（封面用的自由度更大的那种，这里也走占位符，见下） */
function spXml(id, name, phXml, xfrmXml, txBody) {
  return (
    '<p:sp>' +
    '<p:nvSpPr>' +
    `<p:cNvPr id="${id}" name="${esc(name)}"/>` +
    '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>' +
    `<p:nvPr>${phXml}</p:nvPr>` +
    '</p:nvSpPr>' +
    `<p:spPr>${xfrmXml}</p:spPr>` +
    txBody +
    '</p:sp>'
  );
}

/** 只有占位符、没有 txBody 的形状（备注页里的"幻灯片图像"之类） */
function spNoTextXml(id, name, phXml, xfrmXml) {
  return (
    '<p:sp>' +
    '<p:nvSpPr>' +
    `<p:cNvPr id="${id}" name="${esc(name)}"/>` +
    '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>' +
    `<p:nvPr>${phXml}</p:nvPr>` +
    '</p:nvSpPr>' +
    `<p:spPr>${xfrmXml}</p:spPr>` +
    '</p:sp>'
  );
}

function xfrmXml(x, y, cx, cy) {
  return `<a:xfrm><a:off x="${x}" y="${y}"/><a:ext cx="${cx}" cy="${cy}"/></a:xfrm>`;
}

const GROUP_SHAPE =
  '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>' +
  '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>' +
  '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';

/** clrMap：12 个属性一个都不能少（母版/备注母版都要） */
const CLR_MAP =
  '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" ' +
  'accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>';

// ─────────────────────────────────────────────────────────── 固定部件

function contentTypesXml(slideCount, hasNotes, mediaExts, layoutCount) {
  const overrides = [
    ['/ppt/presentation.xml', CT.presentation],
    ['/ppt/slideMasters/slideMaster1.xml', CT.slideMaster],
  ];
  for (let i = 1; i <= layoutCount; i += 1) {
    overrides.push([`/ppt/slideLayouts/slideLayout${i}.xml`, CT.slideLayout]);
  }
  overrides.push(['/ppt/theme/theme1.xml', CT.theme], ['/docProps/core.xml', CT.coreProps]);
  for (let i = 1; i <= slideCount; i += 1) overrides.push([`/ppt/slides/slide${i}.xml`, CT.slide]);
  if (hasNotes && hasNotes.size > 0) {
    overrides.push(['/ppt/notesMasters/notesMaster1.xml', CT.notesMaster]);
    for (let i = 1; i <= slideCount; i += 1) {
      // 只有真的有备注的页才注册（buildParts 里也只为这些页生成 notesSlide）
      if (hasNotes.has(i)) overrides.push([`/ppt/notesSlides/notesSlide${i}.xml`, CT.notesSlide]);
    }
  }
  const defaults = [
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Default Extension="xml" ContentType="application/xml"/>',
  ];
  // 图片：**每种扩展名一条 Default**（漏了 PowerPoint 会说"文件已损坏"）
  for (const [ext, ct] of mediaExts) {
    defaults.push(`<Default Extension="${ext}" ContentType="${ct}"/>`);
  }
  const body = defaults.join('')
    + overrides.map(([part, ct]) => `<Override PartName="${part}" ContentType="${ct}"/>`).join('');
  return `${XML_DECL}<Types xmlns="${NS_CT}">${body}</Types>`;
}

function rootRelsXml() {
  return relsXml([
    { id: 'rId1', type: RT.officeDocument, target: 'ppt/presentation.xml' },
    { id: 'rId2', type: RT.coreProps, target: 'docProps/core.xml' },
  ]);
}

function coreXml(meta) {
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  const author = meta.author || 'DSH toolbox';
  return (
    XML_DECL +
    '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"' +
    ' xmlns:dc="http://purl.org/dc/elements/1.1/"' +
    ' xmlns:dcterms="http://purl.org/dc/terms/"' +
    ' xmlns:dcmitype="http://purl.org/dc/dcmitype/"' +
    ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
    `<dc:title>${esc(meta.title)}</dc:title>` +
    '<dc:subject/>' +
    `<dc:creator>${esc(author)}</dc:creator>` +
    '<cp:keywords/>' +
    `<dc:description>${esc(meta.subtitle || '')}</dc:description>` +
    `<cp:lastModifiedBy>${esc(author)}</cp:lastModifiedBy>` +
    '<cp:revision>1</cp:revision>' +
    `<dcterms:created xsi:type="dcterms:W3CDTF">${now}</dcterms:created>` +
    `<dcterms:modified xsi:type="dcterms:W3CDTF">${now}</dcterms:modified>` +
    '<cp:category/><cp:contentStatus/>' +
    '</cp:coreProperties>'
  );
}

function presentationXml(slideCount, hasNotes) {
  // rId1 = 母版；rId2 = theme；rId3..N+2 = 幻灯片；最后 = notesMaster
  const slideIds = [];
  for (let i = 1; i <= slideCount; i += 1) {
    slideIds.push(`<p:sldId id="${255 + i}" r:id="rId${2 + i}"/>`);
  }
  return (
    XML_DECL +
    `<p:presentation xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}" saveSubsetFonts="1">` +
    '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>' +
    `<p:sldIdLst>${slideIds.join('')}</p:sldIdLst>` +
    `<p:sldSz cx="${SLIDE_W}" cy="${SLIDE_H}"/>` +
    '<p:notesSz cx="6858000" cy="9144000"/>' +
    '<p:defaultTextStyle>' +
    '<a:defPPr><a:defRPr lang="zh-CN" dirty="0"/></a:defPPr>' +
    '<a:lvl1pPr marL="0" algn="l" defTabSz="457200" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr>' +
    '</p:defaultTextStyle>' +
    '</p:presentation>'
  );
}

function presentationRelsXml(slideCount, hasNotes) {
  const items = [
    { id: 'rId1', type: RT.slideMaster, target: 'slideMasters/slideMaster1.xml' },
    { id: 'rId2', type: RT.theme, target: 'theme/theme1.xml' },
  ];
  for (let i = 1; i <= slideCount; i += 1) {
    items.push({ id: `rId${2 + i}`, type: RT.slide, target: `slides/slide${i}.xml` });
  }
  if (hasNotes.size > 0) {
    items.push({ id: `rId${3 + slideCount}`, type: RT.notesMaster, target: 'notesMasters/notesMaster1.xml' });
  }
  return relsXml(items);
}

function slideMasterXml() {
  const title = spXml(
    2,
    '标题占位符 1',
    '<p:ph type="title"/>',
    xfrmXml(MARGIN_X, TITLE_Y, CONTENT_W, TITLE_H),
    txBodyXml([plainPara('单击此处编辑母版标题样式', { size: 3600 })]),
  );
  const body = spXml(
    3,
    '正文占位符 2',
    '<p:ph type="body" idx="1"/>',
    xfrmXml(MARGIN_X, BODY_Y, CONTENT_W, BODY_H),
    txBodyXml([plainPara('单击此处编辑母版文本样式', { size: 1800 })]),
  );
  const layoutIds = LAYOUT_COUNT === 0 ? 2 : LAYOUT_COUNT;
  const layoutRefs = [];
  for (let i = 1; i <= layoutIds; i += 1) {
    layoutRefs.push(`<p:sldLayoutId id="${2147483648 + i}" r:id="rId${i}"/>`);
  }
  return (
    XML_DECL +
    `<p:sldMaster xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}">` +
    '<p:cSld>' +
    '<p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>' +
    `<p:spTree>${GROUP_SHAPE}${title}${body}</p:spTree>` +
    '</p:cSld>' +
    CLR_MAP +
    `<p:sldLayoutIdLst>${layoutRefs.join('')}</p:sldLayoutIdLst>` +
    '<p:txStyles>' +
    '<p:titleStyle>' +
    '<a:lvl1pPr algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="3600" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr>' +
    '</p:titleStyle>' +
    '<p:bodyStyle>' +
    '<a:lvl1pPr marL="342900" indent="-342900" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr>' +
    '<a:lvl2pPr marL="685800" indent="-342900" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1600" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl2pPr>' +
    '</p:bodyStyle>' +
    '<p:otherStyle><a:defPPr><a:defRPr lang="zh-CN" dirty="0"/></a:defPPr>' +
    '<a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr></p:otherStyle>' +
    '</p:txStyles>' +
    '</p:sldMaster>'
  );
}

function slideMasterRelsXml() {
  const items = [];
  for (let i = 1; i <= LAYOUT_COUNT; i += 1) {
    items.push({ id: `rId${i}`, type: RT.slideLayout, target: `../slideLayouts/slideLayout${i}.xml` });
  }
  items.push({ id: `rId${LAYOUT_COUNT + 1}`, type: RT.theme, target: '../theme/theme1.xml' });
  return relsXml(items);
}

/** 版式 1：标题幻灯片（ctrTitle + subTitle） */
function slideLayout1Xml() {
  const title = spXml(
    2,
    '标题 1',
    '<p:ph type="ctrTitle"/>',
    xfrmXml(MARGIN_X, 2130425, CONTENT_W, 1524000),
    txBodyXml([emptyPara()], ' wrap="square" anchor="ctr"'),
  );
  const subtitle = spXml(
    3,
    '副标题 2',
    '<p:ph type="subTitle" idx="1"/>',
    xfrmXml(MARGIN_X + 457200, 3810000, CONTENT_W - 914400, 1470025),
    txBodyXml([emptyPara()], ' wrap="square" anchor="t"'),
  );
  return (
    XML_DECL +
    `<p:sldLayout xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}" type="title" preserve="1">` +
    `<p:cSld name="标题幻灯片"><p:spTree>${GROUP_SHAPE}${title}${subtitle}</p:spTree></p:cSld>` +
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
    '</p:sldLayout>'
  );
}

/** 版式 2：标题和内容（title + 正文占位符 idx=1） */
function slideLayout2Xml() {
  const title = spXml(
    2,
    '标题 1',
    '<p:ph type="title"/>',
    xfrmXml(MARGIN_X, TITLE_Y, CONTENT_W, TITLE_H),
    txBodyXml([emptyPara()]),
  );
  const body = spXml(
    3,
    '正文占位符 2',
    '<p:ph idx="1"/>',
    xfrmXml(MARGIN_X, BODY_Y, CONTENT_W, BODY_H),
    txBodyXml([
      '<a:p><a:pPr marL="342900" indent="-342900"><a:buFont typeface="Arial"/><a:buChar char="•"/></a:pPr>' +
        '<a:endParaRPr lang="zh-CN" dirty="0"/></a:p>',
    ]),
  );
  return (
    XML_DECL +
    `<p:sldLayout xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}" type="obj" preserve="1">` +
    `<p:cSld name="标题和内容"><p:spTree>${GROUP_SHAPE}${title}${body}</p:spTree></p:cSld>` +
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
    '</p:sldLayout>'
  );
}

function slideLayoutRelsXml() {
  return relsXml([{ id: 'rId1', type: RT.slideMaster, target: '../slideMasters/slideMaster1.xml' }]);
}

/**
 * 版式 3：**空白**。
 *
 * 设计版式（`pptx-design.mjs` 那一套）的幻灯片**不使用占位符**：每个色块/文字框
 * 都带自己的 `a:xfrm` 坐标。挂在空白版式上，PPT 里不会出现"没填的占位符提示"。
 * （保留上面两个版式是为了向后兼容：老文件/老调用方仍能用占位符那条路。）
 */
function slideLayout3Xml() {
  return (
    XML_DECL +
    `<p:sldLayout xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}" type="blank" preserve="1">` +
    `<p:cSld name="空白"><p:spTree>${GROUP_SHAPE}</p:spTree></p:cSld>` +
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
    '</p:sldLayout>'
  );
}

/**
 * 主题。三个必需块：clrScheme / fontScheme / fmtScheme。
 * fmtScheme 的四类列表（filling/line/effect/background）各至少 3 项，
 * 少一项 PowerPoint 就判定主题非法。
 * 中文靠 fontScheme 的 `<a:ea typeface="等线"/>` + `<a:font script="Hans"/>`。
 */
function themeXml() {
  const solid = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>';
  const grad1 =
    '<a:gradFill rotWithShape="1"><a:gsLst>' +
    '<a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="50000"/><a:satMod val="300000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="35000"><a:schemeClr val="phClr"><a:tint val="37000"/><a:satMod val="300000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="100000"><a:schemeClr val="phClr"><a:tint val="15000"/><a:satMod val="350000"/></a:schemeClr></a:gs>' +
    '</a:gsLst><a:lin ang="16200000" scaled="1"/></a:gradFill>';
  const grad2 =
    '<a:gradFill rotWithShape="1"><a:gsLst>' +
    '<a:gs pos="0"><a:schemeClr val="phClr"><a:shade val="51000"/><a:satMod val="130000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="80000"><a:schemeClr val="phClr"><a:shade val="93000"/><a:satMod val="130000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="94000"/><a:satMod val="135000"/></a:schemeClr></a:gs>' +
    '</a:gsLst><a:lin ang="16200000" scaled="0"/></a:gradFill>';
  const grad3 =
    '<a:gradFill rotWithShape="1"><a:gsLst>' +
    '<a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="40000"/><a:satMod val="350000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="40000"><a:schemeClr val="phClr"><a:tint val="45000"/><a:shade val="99000"/><a:satMod val="350000"/></a:schemeClr></a:gs>' +
    '<a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="20000"/><a:satMod val="255000"/></a:schemeClr></a:gs>' +
    '</a:gsLst><a:path path="circle"><a:fillToRect l="50000" t="-80000" r="50000" b="180000"/></a:path></a:gradFill>';
  const line = (w) =>
    `<a:ln w="${w}" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>` +
    '<a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>';
  return (
    XML_DECL +
    `<a:theme xmlns:a="${NS_A}" name="DSH 主题">` +
    '<a:themeElements>' +
    '<a:clrScheme name="Office">' +
    '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>' +
    '<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>' +
    '<a:dk2><a:srgbClr val="1F497D"/></a:dk2>' +
    '<a:lt2><a:srgbClr val="EEECE1"/></a:lt2>' +
    '<a:accent1><a:srgbClr val="4F81BD"/></a:accent1>' +
    '<a:accent2><a:srgbClr val="C0504D"/></a:accent2>' +
    '<a:accent3><a:srgbClr val="9BBB59"/></a:accent3>' +
    '<a:accent4><a:srgbClr val="8064A2"/></a:accent4>' +
    '<a:accent5><a:srgbClr val="4BACC6"/></a:accent5>' +
    '<a:accent6><a:srgbClr val="F79646"/></a:accent6>' +
    '<a:hlink><a:srgbClr val="0000FF"/></a:hlink>' +
    '<a:folHlink><a:srgbClr val="800080"/></a:folHlink>' +
    '</a:clrScheme>' +
    '<a:fontScheme name="Office">' +
    `<a:majorFont><a:latin typeface="${FONT_LATIN}"/><a:ea typeface="${FONT_EA}"/><a:cs typeface=""/>` +
    `<a:font script="Hans" typeface="${FONT_EA}"/><a:font script="Hant" typeface="新細明體"/>` +
    '<a:font script="Jpan" typeface="ＭＳ Ｐゴシック"/><a:font script="Hang" typeface="맑은 고딕"/></a:majorFont>' +
    `<a:minorFont><a:latin typeface="${FONT_LATIN}"/><a:ea typeface="${FONT_EA}"/><a:cs typeface=""/>` +
    `<a:font script="Hans" typeface="${FONT_EA}"/><a:font script="Hant" typeface="新細明體"/>` +
    '<a:font script="Jpan" typeface="ＭＳ Ｐゴシック"/><a:font script="Hang" typeface="맑은 고딕"/></a:minorFont>' +
    '</a:fontScheme>' +
    '<a:fmtScheme name="Office">' +
    `<a:fillStyleLst>${solid}${grad1}${grad2}</a:fillStyleLst>` +
    `<a:lnStyleLst>${line(9525)}${line(25400)}${line(38100)}</a:lnStyleLst>` +
    '<a:effectStyleLst>' +
    '<a:effectStyle><a:effectLst/></a:effectStyle>' +
    '<a:effectStyle><a:effectLst/></a:effectStyle>' +
    '<a:effectStyle><a:effectLst><a:outerShdw blurRad="57150" dist="19050" dir="5400000" rotWithShape="0">' +
    '<a:srgbClr val="000000"><a:alpha val="63000"/></a:srgbClr></a:outerShdw></a:effectLst></a:effectStyle>' +
    '</a:effectStyleLst>' +
    '<a:bgFillStyleLst>' +
    solid +
    '<a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/><a:satMod val="170000"/></a:schemeClr></a:solidFill>' +
    grad3 +
    '</a:bgFillStyleLst>' +
    '</a:fmtScheme>' +
    '</a:themeElements>' +
    '<a:objectDefaults/><a:extraClrSchemeLst/>' +
    '</a:theme>'
  );
}

/** 备注母版：notesSlide 必须 rel 到它，它自己 rel 到 theme（可共用 theme1） */
function notesMasterXml() {
  const sp = (id, name, ph, xfrm, tx) =>
    tx === undefined ? spNoTextXml(id, name, ph, xfrm) : spXml(id, name, ph, xfrm, tx);
  const shapes = [
    sp(2, '幻灯片图像占位符 1', '<p:ph type="sldImg" idx="2"/>', xfrmXml(1143000, 685800, 4572000, 3429000)),
    sp(
      3,
      '备注占位符 2',
      '<p:ph type="body" sz="quarter" idx="3"/>',
      xfrmXml(685800, 4343400, 5486400, 4114800),
      txBodyXml([plainPara('', { size: 1200 })]),
    ),
    sp(4, '页码占位符 3', '<p:ph type="sldNum" sz="quarter" idx="5"/>', xfrmXml(3884613, 8685213, 2971800, 457200)),
  ];
  return (
    XML_DECL +
    `<p:notesMaster xmlns:a="${NS_A}" xmlns:r="${NS_R}" xmlns:p="${NS_P}">` +
    '<p:cSld>' +
    '<p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>' +
    `<p:spTree>${GROUP_SHAPE}${shapes.join('')}</p:spTree>` +
    '</p:cSld>' +
    CLR_MAP +
    '<p:notesStyle>' +
    '<a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">' +
    '<a:defRPr sz="1200" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>' +
    typefaces() +
    '</a:defRPr></a:lvl1pPr>' +
    '</p:notesStyle>' +
    '</p:notesMaster>'
  );
}

function notesMasterRelsXml() {
  return relsXml([{ id: 'rId1', type: RT.theme, target: '../theme/theme1.xml' }]);
}

/** 备注页：正文占位符 idx=3（python-pptx / PowerPoint 都按这个找备注正文） */
function notesSlideXml(notesText) {
  const sldImg = spNoTextXml(2, '幻灯片图像占位符 1', '<p:ph type="sldImg" idx="2"/>', '');
  const bodyText = String(notesText || '')
    .split('\n')
    .map((line) => plainPara(line, { size: 1200 }))
    .join('');
  const body = spXml(
    3,
    '备注占位符 2',
    '<p:ph type="body" idx="3" sz="quarter"/>',
    '',
    txBodyXml([bodyText || emptyPara()]),
  );
  const sldNum = spNoTextXml(4, '页码占位符 3', '<p:ph type="sldNum" idx="5" sz="quarter"/>', '');
  return (
    XML_DECL +
    `<p:notes xmlns:a="${NS_A}" xmlns:p="${NS_P}" xmlns:r="${NS_R}">` +
    `<p:cSld><p:spTree>${GROUP_SHAPE}${sldImg}${body}${sldNum}</p:spTree></p:cSld>` +
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
    '</p:notes>'
  );
}

function notesSlideRelsXml(slideIndex) {
  return relsXml([
    { id: 'rId1', type: RT.notesMaster, target: '../notesMasters/notesMaster1.xml' },
    { id: 'rId2', type: RT.slide, target: `../slides/slide${slideIndex}.xml` },
  ]);
}

// ─────────────────────────────────────────────────────────── 设计版式幻灯片

/** 转场（可选）。少写一个属性不会被拒，写错了才会 —— 所以只认这张表里的名字。 */
const TRANSITIONS = Object.freeze({
  fade: '<p:fade/>',
  push: '<p:push dir="l"/>',
  wipe: '<p:wipe dir="l"/>',
  cover: '<p:cover dir="l"/>',
  zoom: '<p:zoom dir="in"/>',
});

function transitionXml(name) {
  const key = String(name || '').trim().toLowerCase();
  if (!TRANSITIONS[key]) return '';
  return `<p:transition spd="med" advClick="1">${TRANSITIONS[key]}</p:transition>`;
}

/**
 * 幻灯片 XML。形状树由 `pptx-design.mjs` 算好（自带 `a:xfrm` 坐标），
 * 这里只负责套外壳 + 挂"空白"版式 +（可选）转场。
 *
 * ⚠️ 不用占位符：设计版式的每一页都要能独立摆位置 —— 也正是"自动排版"的前提。
 */
function slideXmlDesigned(shapes, transition) {
  return (
    XML_DECL +
    `<p:sld xmlns:a="${NS_A}" xmlns:p="${NS_P}" xmlns:r="${NS_R}">` +
    `<p:cSld><p:spTree>${GROUP_SHAPE}${shapes.join('')}</p:spTree></p:cSld>` +
    '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>' +
    transitionXml(transition) +
    '</p:sld>'
  );
}

/**
 * 幻灯片的关系：`rId1` 固定是版式，图片依次挂上，备注最后。
 * ⚠️ 图片的 id 必须与生成 `a:blip r:embed` 时用的一致 —— 所以两边都走
 *    `imageRelsOf(slide)` 的同一个顺序（见 buildParts）。
 */
function slideRelsXml({ layoutIndex, notesIndex, images }) {
  const items = [{
    id: 'rId1',
    type: RT.slideLayout,
    target: `../slideLayouts/slideLayout${layoutIndex}.xml`,
  }];
  let n = 1;
  for (const img of images) {
    n += 1;
    items.push({
      id: `rId${n}`,
      type: RT.image,
      target: `../media/${img.partName.split('/').pop()}`,
    });
  }
  if (notesIndex) {
    n += 1;
    items.push({ id: `rId${n}`, type: RT.notesSlide, target: `../notesSlides/notesSlide${notesIndex}.xml` });
  }
  return relsXml(items);
}

// ─────────────────────────────────────────────────────────── 图片

/** 图片类型 → OPC 内容类型（只认这几种；别的如实警告后当作没有）。 */
const IMAGE_TYPES = Object.freeze({
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  bmp: 'image/bmp',
});

/** 单张图片上限：太大就别塞进 PPT 了（手机上内存/包体都吃不住）。 */
const MAX_IMAGE_BYTES = 16 * 1024 * 1024;

/** 读图片像素尺寸（只解析头，不解码）—— 用来等比缩放，不拉伸变形。 */
function imageSizeOf(buf, ext) {
  try {
    if (ext === 'png' && buf.length > 24) {
      return { cx: buf.readUInt32BE(16), cy: buf.readUInt32BE(20) };
    }
    if (ext === 'gif' && buf.length > 10) {
      return { cx: buf.readUInt16LE(6), cy: buf.readUInt16LE(8) };
    }
    if (ext === 'bmp' && buf.length > 26) {
      return { cx: Math.abs(buf.readInt32LE(18)), cy: Math.abs(buf.readInt32LE(22)) };
    }
    if (ext === 'jpg' || ext === 'jpeg') {
      let i = 2;
      while (i + 9 < buf.length) {
        if (buf[i] !== 0xff) { i += 1; continue; }
        const marker = buf[i + 1];
        const len = buf.readUInt16BE(i + 2);
        // SOF0..SOF3 / SOF5..SOF7 / SOF9..SOF11 / SOF13..SOF15 里都带尺寸
        if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
          return { cy: buf.readUInt16BE(i + 5), cx: buf.readUInt16BE(i + 7) };
        }
        i += 2 + len;
      }
    }
  } catch {
    /* 头读不出来就当没有尺寸，调用方按 4:3 兜底 */
  }
  return null;
}

/** 幻灯片里要用的图片路径（几个别名都认）。 */
function imagePathOf(slide) {
  const v = slide && (slide.image || slide.picture || slide.photo);
  return typeof v === 'string' ? v.trim() : '';
}

// ─────────────────────────────────────────────────────────── ZIP 写入器

/** CRC-32（IEEE 802.3，多项式 0xEDB88320 反射），自己实现，不引三方库 */
const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i += 1) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

/** DOS 时间戳（ZIP 用，1980 年起算） */
function dosDateTime(date) {
  const year = Math.min(2107, Math.max(1980, date.getFullYear()));
  return {
    date: ((year - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate(),
    time: (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2),
  };
}

/**
 * 最小 ZIP 写入器：local file header + data，收尾写 central directory + EOCD。
 * 只支持 deflate(8) 与 store(0)，不加密、不 zip64（pptx 不会到 4GB）。
 */
class ZipWriter {
  constructor() {
    this.entries = [];
    this.chunks = [];
    this.offset = 0;
  }

  /** 追加一个文件；名字用 UTF-8（这里全是 ASCII），内容 UTF-8 文本或 Buffer */
  add(name, content) {
    const raw = Buffer.isBuffer(content) ? content : Buffer.from(String(content), 'utf8');
    const deflated = deflateRawSync(raw, { level: 9 });
    const useDeflate = deflated.length < raw.length;
    const data = useDeflate ? deflated : raw;
    const method = useDeflate ? 8 : 0;
    const nameBuf = Buffer.from(name, 'utf8');
    const { date, time } = dosDateTime(new Date());

    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0); // local file header 签名
    header.writeUInt16LE(20, 4); // 需要的解压版本 2.0
    header.writeUInt16LE(0, 6); // 通用标志位（文件名按 ASCII/UTF-8 一致，无需 bit11）
    header.writeUInt16LE(method, 8);
    header.writeUInt16LE(time, 10);
    header.writeUInt16LE(date, 12);
    header.writeUInt32LE(crc32(raw), 14);
    header.writeUInt32LE(data.length, 18); // 压缩后大小
    header.writeUInt32LE(raw.length, 22); // 原始大小
    header.writeUInt16LE(nameBuf.length, 26);
    header.writeUInt16LE(0, 28); // extra field 长度

    const localOffset = this.offset;
    this.chunks.push(header, nameBuf, data);
    this.offset += header.length + nameBuf.length + data.length;
    this.entries.push({
      name: nameBuf,
      method,
      crc: crc32(raw),
      compSize: data.length,
      rawSize: raw.length,
      time,
      date,
      localOffset,
    });
    return this;
  }

  finish() {
    const cdStart = this.offset;
    const cdChunks = [];
    let cdSize = 0;
    for (const e of this.entries) {
      const h = Buffer.alloc(46);
      h.writeUInt32LE(0x02014b50, 0); // central directory header 签名
      h.writeUInt16LE(20, 4); // 创建版本
      h.writeUInt16LE(20, 6); // 需要的解压版本
      h.writeUInt16LE(0, 8); // 标志位
      h.writeUInt16LE(e.method, 10);
      h.writeUInt16LE(e.time, 12);
      h.writeUInt16LE(e.date, 14);
      h.writeUInt32LE(e.crc, 16);
      h.writeUInt32LE(e.compSize, 20);
      h.writeUInt32LE(e.rawSize, 24);
      h.writeUInt16LE(e.name.length, 28);
      h.writeUInt16LE(0, 30); // extra
      h.writeUInt16LE(0, 32); // comment
      h.writeUInt16LE(0, 34); // 起始磁盘号
      h.writeUInt16LE(0, 36); // 内部属性
      h.writeUInt32LE(0, 38); // 外部属性
      h.writeUInt32LE(e.localOffset, 42);
      cdChunks.push(h, e.name);
      cdSize += h.length + e.name.length;
    }
    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(0x06054b50, 0); // EOCD 签名
    eocd.writeUInt16LE(0, 4);
    eocd.writeUInt16LE(0, 6);
    eocd.writeUInt16LE(this.entries.length, 8);
    eocd.writeUInt16LE(this.entries.length, 10);
    eocd.writeUInt32LE(cdSize, 12);
    eocd.writeUInt32LE(cdStart, 16);
    eocd.writeUInt16LE(0, 20); // 注释长度
    return Buffer.concat([...this.chunks, ...cdChunks, eocd]);
  }
}

// ─────────────────────────────────────────────────────────── 组装 pptx

/**
 * 把 outline.json 抹平成内部结构（**宽进**：类型不对就取默认 + 一句警告，绝不抛）。
 *
 * 兼容两种写法：
 *   v1（老）：`{ title, subtitle, author, slides:[{ title, bullets, notes }] }`
 *   v2（本轮）：多出设计字段 ——
 *     * 整份：`theme`（配色名）、`footer`、`pageNumbers`、`transition`、
 *       `date`、`suffix`（续页后缀）、`hints`（三句提示的自定义文案）
 *     * 每页：`layout`（版式名，见 LAYOUT_NAMES）+ 该版式要的内容字段
 * 两种可以混用：**没写 layout 的页按内容字段自动猜版式**（inferLayout）。
 */
function normalizeOutline(raw) {
  const obj = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const warn = [];
  const str = (v) => (typeof v === 'string' ? v : v == null ? '' : String(v));

  let slides = obj.slides;
  if (slides === undefined || slides === null) slides = [];
  if (!Array.isArray(slides)) {
    warn.push('slides 不是数组，已按空处理');
    slides = [];
  }

  /** 每一页：只做**类型收口**，内容字段原样透传（版式自己知道要什么）。 */
  const normalizeSlide = (s, index) => {
    const o = s && typeof s === 'object' && !Array.isArray(s) ? s : {};
    let bullets = o.bullets !== undefined ? o.bullets : o.content;
    if (bullets === undefined || bullets === null) bullets = [];
    if (typeof bullets === 'string') bullets = bullets.split('\n');
    if (!Array.isArray(bullets)) {
      warn.push(`第 ${index + 1} 页的 bullets 不是数组/字符串，已忽略`);
      bullets = [];
    }
    const normBullets = [];
    for (const b of bullets) {
      if (b === null || b === undefined) continue;
      if (typeof b === 'object') {
        const text = str(b.text !== undefined ? b.text : b.content).trim();
        if (!text) continue;
        normBullets.push({ text, level: Number.isFinite(Number(b.level)) ? Number(b.level) : 0 });
      } else {
        const text = str(b).trim();
        if (!text) continue;
        normBullets.push({ text, level: 0 });
      }
    }
    const out = {
      title: str(o.title).trim() || `第 ${index + 1} 节`,
      subtitle: str(o.subtitle).trim(),
      kicker: str(o.kicker !== undefined ? o.kicker : o.eyebrow).trim(),
      layout: str(o.layout).trim().toLowerCase(),
      bullets: normBullets,
      notes: str(o.notes).trim(),
    };
    // 透传版式要用的字段（没写就是没写 —— 版式内部会退化到"要点页"）
    const passthrough = [
      'items', 'cards', 'tiles', 'steps', 'timeline', 'metrics', 'stats', 'numbers',
      'data', 'left', 'right', 'quote', 'cite', 'source', 'caption', 'image',
      'picture', 'photo', 'number', 'date', 'when', 'text',
    ];
    for (const key of passthrough) {
      if (o[key] !== undefined) out[key] = o[key];
    }
    if (o.chart !== undefined) out.chart = o.chart;
    return out;
  };

  const normSlides = slides.map(normalizeSlide);

  const hints = (obj.hints && typeof obj.hints === 'object') ? obj.hints : {};
  return {
    title: str(obj.title).trim() || '演示文稿',
    subtitle: str(obj.subtitle).trim(),
    author: str(obj.author).trim(),
    date: str(obj.date).trim(),
    footer: str(obj.footer).trim(),
    theme: str(obj.theme).trim(),
    transition: str(obj.transition).trim(),
    pageNumbers: obj.pageNumbers !== false,
    suffix: str(obj.suffix).trim(),
    hints: {
      empty: str(hints.empty).trim() || '（这一页没有正文）',
      overflow: str(hints.overflow).trim() || '（本页内容较多，剩下的在下一页）',
      imageMissing: str(hints.imageMissing).trim() || '（图片没找到，已在原位留空）',
    },
    slides: normSlides,
    warn,
  };
}

/**
 * 一页要点放不下就**拆成续页**（在渲染之前做，页码/页脚才对得上）。
 *
 * ⚠️ 只在"要点类"版式上拆（卡片/时间线自己会缩字号，拆页反而看不懂）。
 */
function expandSlides(slides, outline) {
  const out = [];
  const suffix = outline.suffix || '（续）';
  for (const s of slides) {
    if (s.bullets.length > 0) {
      const layout = inferLayout(s);
      if (layout === 'bullets' || layout === 'toc') {
        const box = bodyBox(s);
        const fit = fitBullets(s.bullets, GRID.contentW, box.h, { minPt: BULLET_MIN_PT });
        if (!fit.ok) {
          const pages = splitBullets(s.bullets, GRID.contentW, box.h, { minPt: BULLET_MIN_PT });
          pages.forEach((page, i) => {
            out.push(i === 0
              ? { ...s, bullets: page }
              : { ...s, title: `${s.title}${suffix}`, bullets: page, notes: '' });
          });
          continue;
        }
      }
    }
    out.push(s);
  }
  return out;
}

/** 生成所有部件（路径 → 内容），路径用 `/`，符合 OPC 包内命名 */
function buildParts(outline) {
  const parts = new Map();
  const theme = resolveTheme(outline.theme);
  const slides = expandSlides(outline.slides, outline);
  // 第 1 页是封面；后面每页对应 slides 的一项
  const total = 1 + slides.length;

  const notesByIndex = new Map(); // slideIndex → 备注文本
  for (let i = 2; i <= total; i += 1) {
    if (slides[i - 2].notes) notesByIndex.set(i, slides[i - 2].notes);
  }

  // 图片登记表：**同一张图只存一份**（按内容哈希去重），内容类型按扩展名收集
  const media = new Map(); // sha1 → { partName, bytes, ext, ct, cx, cy }
  const mediaExts = new Map(); // ext → content type

  /** 把图片读进来登记；拿不到就返回 null（调用方画"缺图占位"）。 */
  const registerImage = (rawPath, warn) => {
    const path = resolve(rawPath);
    const ext = extname(path).slice(1).toLowerCase();
    if (!IMAGE_TYPES[ext]) {
      warn.push(`图片格式不支持（只认 png/jpg/jpeg/gif/bmp）：${rawPath}`);
      return null;
    }
    if (!existsSync(path)) {
      warn.push(`找不到图片：${rawPath}`);
      return null;
    }
    let bytes;
    try {
      const st = statSync(path);
      if (st.size > MAX_IMAGE_BYTES) {
        warn.push(`图片太大（>${Math.round(MAX_IMAGE_BYTES / 1048576)}MB），已跳过：${rawPath}`);
        return null;
      }
      bytes = readFileSync(path);
    } catch (e) {
      warn.push(`读不了图片（${rawPath}）：${e.message}`);
      return null;
    }
    const sha = createHash('sha1').update(bytes).digest('hex');
    if (media.has(sha)) return media.get(sha);
    const dim = imageSizeOf(bytes, ext) || { cx: 0, cy: 0 };
    const entry = {
      partName: `ppt/media/image${media.size + 1}.${ext}`,
      bytes,
      ext,
      ct: IMAGE_TYPES[ext],
      cx: dim.cx,
      cy: dim.cy,
    };
    media.set(sha, entry);
    mediaExts.set(ext, IMAGE_TYPES[ext]);
    return entry;
  };

  parts.set('_rels/.rels', rootRelsXml());
  parts.set('docProps/core.xml', coreXml(outline));
  parts.set('ppt/presentation.xml', presentationXml(total, notesByIndex));
  parts.set('ppt/_rels/presentation.xml.rels', presentationRelsXml(total, notesByIndex));
  parts.set('ppt/slideMasters/slideMaster1.xml', slideMasterXml());
  parts.set('ppt/slideMasters/_rels/slideMaster1.xml.rels', slideMasterRelsXml());
  parts.set('ppt/slideLayouts/slideLayout1.xml', slideLayout1Xml());
  parts.set('ppt/slideLayouts/slideLayout2.xml', slideLayout2Xml());
  parts.set('ppt/slideLayouts/slideLayout3.xml', slideLayout3Xml());
  for (let i = 1; i <= LAYOUT_COUNT; i += 1) {
    parts.set(`ppt/slideLayouts/_rels/slideLayout${i}.xml.rels`, slideLayoutRelsXml());
  }
  parts.set('ppt/theme/theme1.xml', themeXml());

  const usedLayouts = [];
  for (let i = 1; i <= total; i += 1) {
    const isCover = i === 1;
    const slide = isCover
      ? { title: outline.title, subtitle: outline.subtitle, layout: 'cover', date: outline.date }
      : slides[i - 2];

    // ① 先定这一页要挂哪些图片（relId 必须先算好，才能写进 a:blip r:embed）
    const imageRels = [];
    const forSlide = () => {
      const rawPath = imagePathOf(slide);
      if (!rawPath) return null;
      const entry = registerImage(rawPath, outline.warn);
      if (!entry) return null;
      imageRels.push(entry);
      return {
        relId: `rId${1 + imageRels.length}`,
        cx: entry.cx,
        cy: entry.cy,
      };
    };

    // ② 排版（形状树全在这里算出来）
    const built = buildSlideShapes({
      slide,
      theme,
      deck: outline,
      pageNo: i,
      totalPages: total,
      emptyHint: outline.hints.empty,
      overflowHint: outline.hints.overflow,
      imageMissingHint: outline.hints.imageMissing,
      image: { forSlide },
    });
    usedLayouts.push(built.layout);

    parts.set(`ppt/slides/slide${i}.xml`, slideXmlDesigned(built.shapes, outline.transition));
    parts.set(
      `ppt/slides/_rels/slide${i}.xml.rels`,
      slideRelsXml({
        layoutIndex: BLANK_LAYOUT_INDEX,
        notesIndex: notesByIndex.get(i) ? i : null,
        images: imageRels,
      }),
    );
  }

  for (const entry of media.values()) parts.set(entry.partName, entry.bytes);

  // ⚠️ [Content_Types].xml 必须**最后**写：它要知道用到了哪些图片扩展名
  parts.set('[Content_Types].xml', contentTypesXml(total, notesByIndex, mediaExts, LAYOUT_COUNT));

  if (notesByIndex.size > 0) {
    parts.set('ppt/notesMasters/notesMaster1.xml', notesMasterXml());
    parts.set('ppt/notesMasters/_rels/notesMaster1.xml.rels', notesMasterRelsXml());
    for (const [i, text] of notesByIndex) {
      parts.set(`ppt/notesSlides/notesSlide${i}.xml`, notesSlideXml(text));
      parts.set(`ppt/notesSlides/_rels/notesSlide${i}.xml.rels`, notesSlideRelsXml(i));
    }
  }

  return { parts, slides: total, layouts: usedLayouts, media: media.size };
}

// ─────────────────────────────────────────────────────────── 入口

function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0 || argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(HELP);
    process.exit(argv.length === 0 ? 2 : 0);
  }
  if (argv.length < 2) usageFail('需要两个参数：<outline.json> <out.pptx>');

  const outlinePath = resolve(argv[0]);
  const outPath = resolve(argv[1]);

  if (!existsSync(outlinePath)) fail(`找不到大纲文件：${outlinePath}`);

  let rawText;
  try {
    rawText = readFileSync(outlinePath, 'utf8');
  } catch (e) {
    fail(`读不了大纲文件（${outlinePath}）：${e.message}`);
  }
  // 去掉 BOM，不然 JSON.parse 会报 "Unexpected token"
  if (rawText.charCodeAt(0) === 0xfeff) rawText = rawText.slice(1);

  let parsed;
  try {
    parsed = JSON.parse(rawText);
  } catch (e) {
    fail(`大纲文件不是合法 JSON（${outlinePath}）：${e.message}`);
  }

  const outline = normalizeOutline(parsed);
  for (const w of outline.warn) process.stderr.write('[make-pptx] 警告：' + w + '\n');

  const built = buildParts(outline);

  const zip = new ZipWriter();
  // [Content_Types].xml 放第一个条目：符合惯例，也方便任何工具第一时间读到
  const names = [...built.parts.keys()].sort(
    (a, b) => (a === '[Content_Types].xml' ? -1 : b === '[Content_Types].xml' ? 1 : a.localeCompare(b)),
  );
  for (const name of names) zip.add(name, built.parts.get(name));
  const buf = zip.finish();

  try {
    const dir = dirname(outPath);
    if (dir && !existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(outPath, buf);
  } catch (e) {
    fail(`写不了输出文件（${outPath}）：${e.message}`);
  }

  const notesCount = outline.slides.filter((s) => s.notes).length;
  // 机器可读的一行，Dart 侧可以按 [make-pptx] 前缀解析。
  // ⚠️ `slides` 是**真实页数**（含自动拆出来的续页），不是 outline 里写了几个 slide
  //    —— 调用方要报"生成了 N 页"时用这个数才对。
  process.stdout.write(
    `[make-pptx] ok slides=${built.slides} notes=${notesCount} media=${built.media}`
    + ` parts=${built.parts.size} bytes=${buf.length} out=${outPath}\n`,
  );
  if (process.env.MAKE_PPTX_DEBUG_LAYOUTS === '1') {
    process.stderr.write(`[make-pptx] 版式：${built.layouts.join(' → ')}\n`);
  }
}

// 只有被直接 `node make-pptx.mjs` 调用时才执行；被 import 时不自动跑（方便单测）
const isDirectRun = (() => {
  if (!process.argv[1]) return false;
  try {
    if (pathToFileURL(resolve(process.argv[1])).href === import.meta.url) return true;
    // ⚠️ 2026-10-20：真机上出现过「命令跑了、什么都没输出」。这里比 URL 相等太脆 ——
    //    只要 argv[1] 与真实文件路径有细微差别（realpath / 软链 / 不同前缀的同一个文件），
    //    就判成"不是直接运行"，于是 `main()` 根本不执行、进程静默退出（exit 0）。
    //    模型只能去翻脚本源码找原因（真机日志里为这一条烧了 12 条 bash）。
    //    现在补一条**按文件名判定**的兜底：文件名对得上就当直接运行。
    return basename(process.argv[1]) === basename(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();

if (isDirectRun) {
  main();
} else if (process.argv.length > 2) {
  // 兜底也判不出来、但明显带着参数被调用 → **必须大声报错**，
  // 绝不能像以前那样静默退出 0（静默 = 让模型去读 50KB 源码，最费 token 的行为）。
  console.error(
    '[make-pptx] 错误：没能识别为直接运行（argv[1]=' + String(process.argv[1]) + '）。' +
    '请用 `node "$DSH_ANDROID_TOOLBOX/make-pptx.mjs" outline.json out.pptx` 调用。'
  );
  process.exit(2);
}

export { buildParts, normalizeOutline, ZipWriter, crc32, main, LAYOUT_NAMES };
