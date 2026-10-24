/// Bot 页的**移动布局层** —— 只注入样式，不新增元素、不改 DOM 结构。
///
/// ## 为什么单独一层
///
/// Bot 页签里跑的是 ds-bot 的**桌面网页 UI**。它自带窄屏分支
/// （`narrow = viewport < 1024`、`narrowExpanded` 覆盖态、侧栏折叠 56px），
/// 但那套是「平板/窄窗口」思路，不是手机思路：
///
/// * 侧栏展开时**挤压**中间区（373px 屏上会话只剩 93px）；
/// * 顶栏图标 32~36px、右栏开关和「更多」**完全重叠**；
/// * 正文次级文字按桌面背景算对比度，浅色皮肤下是 1.9:1；
/// * 一批容器背景**硬编码浅色**，切深色后文字变浅、底色没变 → 看不见。
///
/// 所以这一层只做三件事：
/// 1. **一屏一页**：三列 grid → 单列；名册满屏（100vw）、会话区永远占满；
/// 2. **手指能点**：图标按钮 ≥44×44，去掉实测到的「图标压图标」；
/// 3. **两套主题都看得见**：浅色/深色分别钉死文字色与占位符，
///    骨架容器背景交给 App 注入的 `--bt-*`。
///
/// ## 踩过的坑（改之前先读）
///
/// * 只用 `!important` 压 CSS Modules 哈希类；选择器按**实测容器特征**写，
///   不靠"类名看起来对"（顶栏那两颗按钮不在 `<header>` 里，按 header 选不中）。
/// * 右栏**不能** `display:none`：上游靠它上报"已关闭"，藏掉后中心列的
///   `margin-right` 永久卡在 320px —— 用户看到的就是「会话被挤成一条、退不出来」。
/// * 名册内容根带着**内联** `width:280px`（桌面侧栏宽），只有样式表里的
///   `!important` 能压过；只给子节点设 100% 没用（那只是父级 280 的 100%）。
/// * 手机上导航是「一屏一页」：名册收起 = 整块移出左侧，不是缩成 56px 图标条。
library;

/// 移动端布局样式。只在窄屏（≤720px CSS px）生效，桌面/平板不受影响。
const String botMobileLayoutCss = r'''
/* ═══════════════════════════════════════════════════════════════════
   Bot 页 · 手机布局层
   原则：一屏一页、手指能点、两套主题都看得见。
   只调样式，不造元素、不改 DOM 结构。
   ═══════════════════════════════════════════════════════════════════ */

@media (max-width: 720px) {

  /* ── ① 横向不溢出 ───────────────────────────────────────────────
     宿主有一个比视口更宽的空容器（实测 374/747px），不夹住就会左右晃。 */
  html, body {
    overflow-x: hidden !important;
    max-width: 100vw !important;
  }

  /* ── ② 三列 → 单列 ──────────────────────────────────────────────
     上游窄屏把侧栏折成 56px 图标条，手机上连这条都嫌宽：
     会话区吃满整宽，侧栏改成覆盖式（见 ③）。 */
  [class*="frame"] {
    grid-template-columns: 0px minmax(0, 1fr) 0px !important;
  }

  /* ── ③ 名册：满屏一页 + 整块滑出 ────────────────────────────────
     用户口径：「名册就是全屏一页，没有侧滑抽屉」。
     收起形态沿用上游自己的 `data-sidebar-collapsed`（不加状态）。 */
  [class*="sidebarCol"] {
    position: fixed !important;
    left: 0 !important;
    top: 0 !important;
    bottom: 0 !important;
    width: 100vw !important;
    max-width: 100vw !important;
    overflow: hidden !important;
    /* ⚠️ 不能给太高：实测 ds-bot 自己的设置层 z-index=60，侧栏写 900 会把
       设置层整个盖住（点「+ → 设置」后屏幕上仍是名册）。55 < 60 让它归位。 */
    z-index: 55 !important;
    border-radius: 0 !important;
    box-shadow: none !important;
    transition: transform .22s cubic-bezier(.2, .7, .3, 1) !important;
    will-change: transform;
  }
  [data-sidebar-collapsed] [class*="sidebarCol"] {
    transform: translateX(-102%) !important;
    pointer-events: none !important;
  }
  /* 名册内容根带着内联 width:280px（桌面侧栏宽）—— 压回满屏，
     否则列表行只有 256px、右边一大片空（实测过两次）。 */
  [class*="sidebarCol"] [class*="root"],
  [class*="sidebarCol"] [class*="regionArea"] {
    width: 100% !important;
    max-width: 100% !important;
    min-width: 0 !important;
  }
  /* 名册顶栏那颗「收起侧边栏」在满屏形态下没有意义；
     三颗 `.bt-round` 一起收掉后品牌会被 flex-end 推到右边 → 改回左对齐。 */
  .bt-side-top .bt-round { display: none !important; }
  .bt-side-top { justify-content: flex-start !important; }

  /* 名册展开时右侧那条 35% 黑罩（`button.EIQnXa_backdrop`，fixed left=306 宽 67）
     既是视觉上的一条黑带，又压住每一行的右端 43px（行宽 338）。满屏名册用不到它
     —— 点行就进会话，没有"右侧内容"需要点空白收起。设置层打开时不动（它有自己的遮罩）。 */
  body:not([data-sidebar-collapsed]) :not([data-dshm-settings]) [class*="backdrop"] {
    display: none !important;
  }
  /* 设置层打开时名册整个让位：设置层 z-index=60，和侧栏只差 5，
     不同机型/版本上容易叠；而且用户在设置里时不该再看到名册。 */
  body[data-dshm-settings] [class*="sidebarCol"] {
    display: none !important;
  }

  /* 手机上是死路的两处入口（用户 0.79 就要求去掉）：
     * `.bt-connect`（连接插件）：外部连接器要另走 OAuth 授权，手机上点进去只能看到
       "去网页版配置"，没有可完成的操作；
     * `.bt-account`（鲸鱼账户）：菜单里的「Bot 设置」与「+ → 设置」重复，其余是死路。
     藏掉后设置入口仍在（+ 菜单），不会出现"设置进不去"的死局。 */
  .bt-connect-wrap,
  .bt-connect,
  .bt-account { display: none !important; }
  /* 底部因此空出一行，把高度收掉（不然留一条突兀的空白） */
  [class*="footArea"] { min-height: 0 !important; }

  /* ── ④ 右栏：不占位，但**不能** display:none（见文件头注释）────────
     上游按右栏宽度在运行时往动态样式表里插
     `.pI_x6G_centerCol{margin-right:320px!important}`，
     同特异性压不过 → 拿 frame 当祖先提高特异性压回去。 */
  [class*="rightbarCol"] {
    width: 0 !important;
    min-width: 0 !important;
    display: block !important;
  }
  [class*="frame"] [class*="centerCol"] {
    margin-right: 0 !important;
    min-width: 0 !important;
  }
  /* 右栏面板里那几颗按钮是手机上唯一的出口（新标签页/分栏/退出全屏/
     收起右侧边栏，实测 28×28）→ 44。 */
  [class*="rightbarCol"] button {
    min-width: 44px !important;
    min-height: 44px !important;
  }

  /* ── ⑤ 顶栏：去重叠、给足触控 ────────────────────────────────────
     实测「显示或隐藏右侧栏」(x=334, 28×28) 与「更多操作」完全重合；
     手机上右栏本来就用不到，这个开关没有意义 → 拿掉。 */
  [aria-label="显示或隐藏右侧栏"],
  [title="显示或隐藏右侧栏"] {
    display: none !important;
  }
  /* 顶栏那两颗按钮**不在 <header> 里**（祖先链是
     BUTTON.EIQnXa_toggle → DIV.EIQnXa_layer → DIV.pI_x6G_overlayLayer），
     所以按 header 选不中，得按容器特征选。 */
  header button,
  header [role="button"],
  [role="banner"] button,
  [class*="_toggle"],
  [class*="overlayLayer"] button,
  [class*="sidebarCol"] button {
    min-width: 44px !important;
    min-height: 44px !important;
  }
  header {
    min-height: 52px !important;
    padding-right: 8px !important;
    gap: 4px !important;
    /* 顶栏原本是透明底：消息滚到顶上时，气泡会从「☰ / 名字 / +」底下透出来，
       看起来像图标压图标（截图里「你好」和「+」叠在一起就是它）。 */
    background-color: var(--bt-main, transparent) !important;
    z-index: 10 !important;
  }
  /* ── ⑤-b 顶部两枚圆形浮层的图标色 ────────────────────────────────
     用户 2026-10-24：「顶部左右有两个按钮，几乎看不见，只有深色主题才能看见」。
     它们就是宿主那两个圆钮（打开导航 / 更多操作，z=90/220）：图标是固定浅色，
     落在浅色页面上就消失了。按两套主题钉死；svg 用 currentColor 兜一层。 */
  body:not([data-ds-dark-theme]) [class*="overlayLayer"] button,
  body:not([data-ds-dark-theme]) [class*="overlayLayer"] svg,
  body:not([data-ds-dark-theme]) [class*="toggle"] {
    color: #0f1115 !important;
  }
  body[data-ds-dark-theme] [class*="overlayLayer"] button,
  body[data-ds-dark-theme] [class*="overlayLayer"] svg,
  body[data-ds-dark-theme] [class*="toggle"] {
    color: #f9fafb !important;
  }
  /* 圆钮底：浅色下给一点可见的浅灰，别让图标浮在纯白上 */
  body:not([data-ds-dark-theme]) [class*="overlayLayer"] button,
  body:not([data-ds-dark-theme]) [class*="toggle"] {
    background-color: rgba(12, 26, 51, 0.06) !important;
  }
  body[data-ds-dark-theme] [class*="overlayLayer"] button,
  body[data-ds-dark-theme] [class*="toggle"] {
    background-color: rgba(255, 255, 255, 0.10) !important;
  }

  /* 会话标题做成胶囊，窄屏上会和右侧按钮挤 → 允许省略、限定宽度 */
  header [aria-label="查看对话详情"] {
    max-width: calc(100vw - 132px) !important;
    overflow: hidden !important;
    text-overflow: ellipsis !important;
    white-space: nowrap !important;
  }
  /* 用户口径：「顶部那个名字点了会弹一整屏空面板，取消」——
     不拦点击，只让它不接收事件（穿透）。 */
  .bt-pill { pointer-events: none !important; }

  /* ── ⑥ 输入区：触控 + 不压字 + 取掉语音 ──────────────────────────
     底部「添加/听写/开始语音对话」实测互相压 17~28px。
     另外语音两颗（.bt-mic 听写 / .bt-voice 语音对话）是用户明确要取掉的，
     单 Bot 与群聊共用同一个 Composer，一条规则两种会话都生效。 */
  [class*="composer"] button,
  [data-composer-card] button,
  form button[aria-label] {
    min-width: 44px !important;
    min-height: 44px !important;
    flex: 0 0 auto !important;
  }
  .bt-mic,
  .bt-voice { display: none !important; }

  /* 输入框上方/下方那几块统计（轮次/tokens/上下文）在 373 宽下互相压 22~34px */
  [class*="usage"], [class*="Usage"], [class*="stat"], [class*="Stat"],
  [class*="dock"] {
    flex-wrap: wrap !important;
    gap: 4px 10px !important;
    min-width: 0 !important;
  }
  [class*="usage"] > *, [class*="Usage"] > *,
  [class*="stat"] > *, [class*="Stat"] > *,
  [class*="dock"] > * {
    flex: 0 1 auto !important;
    min-width: 0 !important;
  }

  /* ── ⑦ 消息级工具栏：24×24 / 间距 2px → 手指点得准 ─────────────
     原设计绝对定位在气泡**右侧**，373 屏上气泡右边只剩 108px，
     直接放大必然出屏（实测溢出 24px）。改成「消息下方、右对齐到气泡右边」，
     行宽最多 178px < 气泡宽 223px，垂直间距实测 ≥60px，压不到别的消息。 */
  .bt-tools {
    left: auto !important;
    right: 0 !important;
    top: 100% !important;
    bottom: auto !important;
    transform: none !important;
    gap: 6px !important;
    z-index: 5 !important;
    margin-top: 2px !important;
  }
  .bt-tool {
    min-width: 40px !important;
    min-height: 40px !important;
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
  }

  /* 菜单项统一到 44 高（顶栏菜单本来就是 44，消息级/输入区菜单漏了） */
  .bt-menu button,
  [role="menu"] button,
  [role="menuitem"] {
    min-height: 44px !important;
    display: flex !important;
    align-items: center !important;
  }

  /* ── ⑧ ds-bot 自己的 Bot 详情抽屉：三颗圆钮 36 → 44 ─────────────
     手机上进抽屉后唯一能退出的是「关闭详情」，必须好点。 */
  [class*="bt-drawer-top"] button.bt-round {
    min-width: 44px !important;
    min-height: 44px !important;
  }
}

/* 设置层：导航项与关闭按钮实测 65×32 / 32×32，手指点不准 → 抬到 44。
   导航本来就是两行 flex-wrap（v0.78 已改），抬高度只会多占一点纵向空间。 */
@media (max-width: 720px) {
  .bt-settings-nav .bt-settings-item {
    min-height: 44px !important;
    padding-top: 6px !important;
    padding-bottom: 6px !important;
  }
  .bt-settings-close {
    min-width: 44px !important;
    min-height: 44px !important;
  }
  /* 设置行左侧的标签列会被右侧颜色网格挤成一字一行
     （实测「强调色」容器 .bt-set-copy 只剩 34px 宽 → 强/调/色 竖排）。 */
  .bt-set-row { gap: 12px !important; }
  .bt-set-copy {
    flex: 0 0 auto !important;
    min-width: 76px !important;
    max-width: 44% !important;
  }
  /* 强调色那排 9 个圆点在 373 宽下会横向溢出（实测 .bt-set-control 从 x=181
     排到 427，超出面板右边界 345 → 最后一个颜色被切掉）。允许换行。 */
  .bt-set-control {
    flex: 1 1 auto !important;
    min-width: 0 !important;
  }
  .bt-swatches {
    flex-wrap: wrap !important;
    row-gap: 6px !important;
    max-width: 100% !important;
  }
}

/* ═══════════════════════════════════════════════════════════════════
   ⑨ 可读性：两套主题分别钉死
   ═══════════════════════════════════════════════════════════════════
   实测过的根因（不是"猜对比度"）：
   * 浅色皮肤下输入框 contenteditable 的 color = rgb(242,242,242) ——
     拿到的是深色主题值，浅底浅字；
   * 占位符是**独立 div**（[class*=placeholder]），`::placeholder` 管不到它；
   * ds-bot 的输入框空态颜色 rgb(173,178,184) on rgb(238,243,251) = 1.9:1。
   所以这里不依赖可能取反的 `--dsw-alias-*`，直接按主题写死。 */

/* 正文可编辑区 / 输入框 */
body:not([data-ds-dark-theme]) [contenteditable="true"],
body:not([data-ds-dark-theme]) textarea,
body:not([data-ds-dark-theme]) input[type="text"],
body:not([data-ds-dark-theme]) input:not([type]) {
  color: #0f1115 !important;
  caret-color: #0f1115 !important;
}
body[data-ds-dark-theme] [contenteditable="true"],
body[data-ds-dark-theme] textarea,
body[data-ds-dark-theme] input[type="text"],
body[data-ds-dark-theme] input:not([type]) {
  color: #f9fafb !important;
  caret-color: #f9fafb !important;
}

/* 占位符（独立 div 与原生 placeholder 两种形态都覆盖） */
body:not([data-ds-dark-theme]) [class*="placeholder"] {
  color: #61666b !important;
  opacity: 1 !important;
}
body[data-ds-dark-theme] [class*="placeholder"] {
  color: #9aa0a6 !important;
  opacity: 1 !important;
}
body:not([data-ds-dark-theme]) textarea::placeholder,
body:not([data-ds-dark-theme]) input::placeholder {
  color: #61666b !important;
  opacity: 1 !important;
}
body[data-ds-dark-theme] textarea::placeholder,
body[data-ds-dark-theme] input::placeholder {
  color: #9aa0a6 !important;
  opacity: 1 !important;
}

/* 输入框下方 dock 区的统计文字：又是拿到深色 alias 的一处 */
body:not([data-ds-dark-theme]) [class*="dock"] span,
body:not([data-ds-dark-theme]) [class*="dock"] * {
  color: #3c4149 !important;
}
body[data-ds-dark-theme] [class*="dock"] span,
body[data-ds-dark-theme] [class*="dock"] * {
  color: #d5d8dc !important;
}

/* 设置层里的说明文字：ds-bot 写死 rgba(242,242,242,.74)（深色值），
   浅色页面上等于白纸白字。取 App 注入的次要文字色，两套主题自动跟着变。 */
.bt-set-hint { color: var(--bt-ink-2) !important; }

/* ═══════════════════════════════════════════════════════════════════
   ⑩ 背景：骨架交给 App 的主题变量
   ═══════════════════════════════════════════════════════════════════
   实测（切深色后）：文字已经变浅（对），但 O_Ebla_root / EvIC1a_column /
   EvIC1a_frame 这些骨架容器背景**硬编码 rgb(244,245,247)** —— 浅底浅字。
   只接管骨架层，卡片/气泡保持自己的层次。 */
body {
  background-color: var(--bt-main, #eef3fb) !important;
}
[class*="_frame"],
[class*="_root"],
[class*="_column"],
[class*="_body"],
[class*="_content"] {
  background-color: var(--bt-main, inherit) !important;
}
/* ⚠️ 只认 ds-bot 自己的具体类，**不要**写 `[class*="card"]` / `[class*="panel"]`：
   宿主有一层全屏透明面板 `P3OORG_panel / P3OORG_panelBody`（374×737），
   被 `[class*="panel"]` 命中后加上不透明背景 → 整个消息区被盖住，
   症状是「气泡背景在、文字一个字都看不见」（实测定位：二分删到这一条就恢复）。
   同理不要写成 `[class*="_bubble"]`：ds-bot 用 `bt-` 前缀，旧规则从来没生效过。 */
[class*="bt-bubble"], [class*="bt-card"], [class*="bt-pane"] {
  background-color: var(--bt-card, var(--bt-main, inherit)) !important;
}
[class*="sidebarCol"] {
  background-color: var(--bt-sidebar, var(--bt-main, inherit)) !important;
}

/* ═══════════════════════════════════════════════════════════════════
   ⑪ 去掉"看起来能点、点了没反应"的按钮语义
   ═══════════════════════════════════════════════════════════════════
   底部三块统计（22 轮 55 步 / 1.9M tok / 上下文已用 5%）都是 <button>，
   点下去任何状态都不变 —— 按钮形态是在骗人。去语义、恢复成纯文字。 */
@media (max-width: 720px) {
  [class*="dock"] button,
  [class*="usage"] button,
  [class*="stat"] button {
    pointer-events: none !important;
    cursor: default !important;
    background: transparent !important;
    border: 0 !important;
    box-shadow: none !important;
    padding: 0 2px !important;
    min-width: 0 !important;
    min-height: 0 !important;
    opacity: 1 !important;
  }
}

/* ═══════════════════════════════════════════════════════════════════
   ⑫ 设置层打开时，藏掉宿主那两个圆形浮层
   ═══════════════════════════════════════════════════════════════════
   打开导航（z=90）与更多操作（z=220）正好压在设置层左上「通用」和
   右上「×」上面。body 标记由注入脚本维护（见 bot_page.dart）。 */
body[data-dshm-settings] [class*="EIQnXa_layer"],
body[data-dshm-settings] [class*="CzK_aW_layer"] {
  display: none !important;
}

/* 齿轮借「+」菜单那一项进设置时，先把菜单藏起来，别闪一下 */
body[data-dshm-mute-menu] .bt-plus-menu { visibility: hidden !important; }
''';
