# Bot 页重做 · bot-rework 分支（基线 v0.78）· 2026-10-24

> 口径：用户 2026-10-24 定「基线从 `git switch -c bot-rework v0.78` 开始，不要在 0.79 树上继续叠；
> 0.79 线存档在 tag `wip-0.79-222`，只作参考」。本文记录第一轮。

## 0. 一句话

在 **v0.78（814 行、零外壳）** 上补一层 **CSS-only 移动布局**（新文件
`app/lib/ui/pages/bot_mobile_layout.dart`）+ 三个小 JS，把 Bot 页从「桌面网页塞进手机」
变成**一屏一页、手指能点、深浅两套主题都看得见**。真机（100.66.1.2:45603）CDP 实测通过。

## 1. 基线确认

| 项 | 值 |
|---|---|
| 分支 | `bot-rework`，从 `v0.78`（`7b61ffa` release 0.78/126）切出 |
| v0.78 的 Bot 页 | `bot_page.dart` 814 行：WebView + `_webPatchTemplate` 一段补丁（浮层宽度/设置对话框/藏 Harness 入口/文案/主题跟随）。**没有**移动布局层、没有外壳 |
| 0.79 参考 | `bot_mobile_layout.dart` 496 行（CSS-only）+ `bot_mobile_shell.dart` 988 行（外壳，已关）+ `bot_page.dart` 2417 行 |
| 基线门禁 | `flutter analyze --no-pub`：No issues found；全量测试 **1170 通过 / 3 跳过 / 0 失败** |

## 2. 这一轮改了什么

### 2.1 新增移动布局层（`bot_mobile_layout.dart`，只注入样式，不造元素）

| # | 规则 | 依据（实测） |
|---|---|---|
| ① | `html, body { overflow-x: clip }` | 宿主有个 374/747px 的空 Tab 容器，不夹住就左右晃 |
| ② | `frame` 三列 → `0px 1fr 0px` | 单栏 |
| ③ | `sidebarCol` 覆盖式、满屏 `100vw` | 名册就是一页；内容根带**内联 `width:280px`**，必须 `!important` 压 |
| ④ | `rightbarCol` 宽 0（**不能** `display:none`） | display:none 会让上游算不出"已关闭"，`centerCol` 的 margin-right 卡 320px |
| ⑤ | 隐藏「显示或隐藏右侧栏」 | 实测 28×28 与「更多操作」**完全重叠** |
| ⑥ | 所有图标按钮 ≥44×44 | 实测顶栏 32、输入区 40、设置导航 32 |
| ⑦ | 隐藏 `.bt-mic` / `.bt-voice` | 用户口径：取掉语音（单 Bot 与群聊共用 Composer） |
| ⑧ | 隐藏 `.bt-connect` / `.bt-account` | 手机上是死路（OAuth / 重复设置入口） |
| ⑨ | 隐藏名册右侧 `EIQnXa_backdrop`（67×737、35% 黑罩） | 它压住每行右端 43px，视觉上是一条黑带 |
| ⑩ | `.bt-pill { pointer-events:none }` | 点它弹一整屏空面板（用户 0.79 报过） |
| ⑪ | 消息工具栏改到气泡下方右对齐 | 原来 24×24、间距 2px，放大必出屏 |
| ⑫ | 设置层：导航项/关闭按钮 44；`.bt-set-copy` 76px；`.bt-swatches` 换行 | 实测「强调色」被挤成一字一行、颜色圆点溢出到屏外 |
| ⑬ | 设置层打开时藏宿主两个圆形浮层 | 实测它们压在设置层「通用」与「×」上 |

### 2.2 `bot_page.dart` 的改动

1. **布局层注入**：独立 `<style id="dsh-mobile-layout">`，用 `jsonEncode` 转成合法 JS 字符串字面量
   （CSS 里有换行/引号/反斜杠，模板字符串迟早被截断 —— 108 版整段失效的教训）。
   放在「已注入过就 return」守卫**之前**，React 重渲染补注入时才不会漏。
2. **令牌内联** `_varsJs()`：把 `--bt-*` 用 `style.setProperty(k, v, 'important')` 打到 `html` 与 `body`。
   原因：ds-bot 把主题变量写在 `documentElement.style` 上，样式表压不过内联。
3. **深色扫底** `_sweepJs()`：深色下把亮度 > 0.82 的容器压成 App 深色（切回浅色时清掉上一轮的内联底色）。
   页面加载后 1.6s / 3.6s 各补扫一次（SPA 后渲染的元素）。
4. **设置层标记** `_settingsFlagJs`：低频轮询维护 `body[data-dshm-settings]`，供 ⑬ 用。
5. **四步各自独立 try**：2026-10-23 的教训是四步串一个 try，补丁一抛异常整层都不注入。
6. **换肤监听**：`DshColors.skinRevision`（新增 `ValueNotifier`，`applySkin` 自增）+ Bot 页 `addListener`。
   原因：Bot 页常驻 `IndexedStack`，换肤时 build 不一定跑 → 网页停在旧主题（深色 App 配浅色网页）。
7. **点会话行自动收起名册**（补丁 JS 内）：名册是满屏的，不收起用户以为没点中。

### 2.3 颜色转换的真 bug（`_hex` 丢 alpha）

`_tokensCss` 原来 `c.toARGB32() & 0xFFFFFF` → **半透明白全部变纯白**。
App 的 surface / surfaceHigh / navBg 都是半透明：
浅色 `0xF0FFFFFF`、深色 `0x1FFFFFFF` → 深色皮肤下卡片/气泡被推成 `#ffffff`，
字又是浅色 → **白底浅字**。

修法：`_hex` 保留 alpha（输出 `rgba(...)`）；表面色用 `_solid()` 先 `alphaBlend` 到页面底再转实色。

## 3. 真机实测（构建 `0.0.78+223`，view 373×737，dpr 3.28）

| 项 | 改前（v0.78 纯网页） | 改后 |
|---|---|---|
| 视口 vs 页面宽 | 内容宽 374/747，可左右晃 | `scrollWidth = 373` = 视口 |
| 名册内容根 | 内联 `width:280px`（列表行 256） | `rootW=374`，行 `338×54` |
| 名册右侧遮挡 | `EIQnXa_backdrop` 67×737 黑罩，压住行右端 43px | `display:none`（0×0） |
| 鲸鱼 / 连接插件 | 44×44 / 289×44 可见 | 都 `display:none` |
| 可点元素 <44 | 顶栏 32、输入 40、设置导航 32 | 会话页 3 个全 44；设置导航 44×44；关闭按钮 44×44 |
| 图标重叠 | 「显示或隐藏右侧栏」压「更多操作」28×28 | 0 处（该按钮已移除） |
| 浅色文字 | 占位符 1.9:1；contenteditable 拿到深色值 | 输入框 `rgb(15,17,21)`；占位符 `rgb(97,102,107)`；hint `rgb(86,106,141)` |
| 深色文字 | 容器背景硬编码浅色 → 浅底浅字 | 全屏 111 个背景元素，**亮度 >0.82 的 0 个**；输入框 `rgb(249,250,251)`；占位符 `rgb(154,160,166)` |
| 深色气泡 | `.bt-bubble` 内联 `background:#fff` + 浅色字 | `rgb(39,44,48)` + `rgb(232,238,252)`（内联被扫底压掉） |
| 设置层 | 导航/关闭 32；被宿主两个浮层压住；「强调色」竖排；圆点溢出 | 44/44；浮层 `display:none`；标签横排；圆点两行不溢出 |
| 主题切换 | 网页常驻旧主题 | `data-ds-dark-theme` 随 App 变，**不重载页面**；切回浅色自动还原 |

产物：`dist/paopaocat-preview-0.78-20261024-botrework1-full-arm64-v8a.apk`（103.9MB，versionCode 223）。

## 4. 踩坑记录（这一轮花时间最多的三个）

### 4.1 `overflow-x: hidden` 在 body 上会把消息整片裁掉

- 症状：气泡背景画出来了（像素 `rgb(250,252,254)`），**文字一个字都不画**；DOM 全正常
  （rect 在视口内、hit-test 命中、color 是深色、无 clip/transform）。
- 二分定位：删掉 `html, body { overflow-x: hidden }` 就恢复。
- 根因：`overflow-x: hidden` + `overflow-y: visible` 时，`visible` 会被计算成 `auto`
  → **body 变成滚动容器**，高度锁在视口 737；而消息滚动容器从 y=-194 开始、高 831
  → 内容被 body 裁掉。`clip` 也会创建裁剪，同样不行。
- 结论：横向夹住只在 `html` 上做，别动 body。最终保留 `html { overflow-x: clip }`。

### 4.2 `[class*="panel"]` 命中宿主的全屏透明面板层

- 症状：同上（气泡在、文字没了），但这次是背景接管规则的锅。
- 二分定位：删 `[class*="card"], [class*="bubble"], [class*="panel"]` 那条就恢复。
- 根因：宿主有 `P3OORG_panel` / `P3OORG_panelBody`（**374×737 全屏透明**），
  被加上不透明 `background-color` 后**盖住整个消息区**。
- 结论：背景接管只写 ds-bot 自己的具体类（`bt-bubble` / `bt-card` / `bt-pane`），
  绝不写 `panel` / `card` 这种宽泛片段。

### 4.3 侧栏 z-index 900 会盖住设置层（z=60）

- 症状：点「+ → 设置」后屏幕上还是名册。
- 根因：ds-bot 设置层 z-index 只有 60；侧栏写 900 直接压死。
- 修法：侧栏 z-index 降到 **55**；并加 `body[data-dshm-settings]` 时侧栏 `display:none` 双保险。

## 5. 还没做的（下一轮候选）

1. **右上角滚动重叠**：会话滚到顶部时，上一条「我的消息」气泡会从顶栏图标下面透出来
   （截图「你好 +」）。已给 `header` 加 `background-color: var(--bt-main)`，但截图看仍未遮住
   —— 需要再确认 header 的背景是否被上游覆盖，或改用滚动容器顶部 padding。
2. **「模式」栏**：已用 JS 按标题文案隐藏（用户 0.79 明确要求取消）；换语言时匹配 `Mode`。
3. **+ 菜单**：仍是「添加文件 / 引用对话 / 设置」。要不要像 0.79 那样只留「添加文件 + 增加 Bot」、
   把设置挪到顶栏齿轮——**这一条要 App 层加顶栏，属于结构改动**，等用户拍板。
4. **长按菜单 / 新建 Bot / @ 选人**：网页内部交互，本轮没动。
5. **状态栏图标**：切深色后状态栏时间仍是深色（App 层 `SystemUiOverlayStyle` 没跟着换），
   不在 Bot 网页范围，单独记。
6. `WebView.setWebContentsDebuggingEnabled(true)` 目前是**无条件开启**（为真机 CDP），
   **发版前必须改成 `if (BuildConfig.DEBUG)`**（见 `docs/接续台账.md` §6）。
