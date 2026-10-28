import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../local/bot_server.dart';
import '../../local/dsh_runtime.dart';
import '../../local/diagnostics_log.dart';
import '../theme/dsh_tokens.dart';
import 'bot_mobile_layout.dart';

/// 「Bot 团队」页 —— 把**手机本机上**跑着的 dsh web（含 ds-bot）用 WebView 打开。
///
/// 体验目标（用户口径）：**和桌面版一样** —— 能看到各个 Bot 在聊天、在解决问题。
/// 所以这里刻意**不重写界面**：Bot 那套界面是插件 `ds-bot` 自带的浏览器前端
/// （826 条文案、群聊、@选人、记忆/密钥/用量/审批卡片、实时状态词），
/// 只有用同一套前端才可能"一样"。服务进程见 [BotServer]。
///
/// 两个刻意的取舍：
///  * **页面退出不停服务**：Bot 是要**常驻干活**的（用户在别处时它还在跑）。
///    要停就用右上角菜单里的「停止 Bot 服务」。
///  * 启动慢要**如实等**：首次要把 dsh 的插件树拉起来，实测 10~25 秒；
///    这段时间显示进度与最后一行日志，不做假动画。
class BotPage extends StatefulWidget {
  const BotPage({super.key, required this.runtime});

  /// 壳层在收到「返回」时会先问这里：**网页能不能自己退一层？**
  ///
  /// 为什么不用 PopScope（2026-10-19 真机日志坐实的坑）：`PopScope` 是**按路由**
  /// 注册的，而这个页面一直活在壳层的 PageView 里（保活）。于是用户在**别的页签**
  /// 上做边缘返回，Bot 页也会收到，并执行 `Navigator.pop()` —— 它弹的是**根路由**
  /// （这个页面不是 push 出来的），整个主界面被弹掉 → 一屏黑、进程随后重启。
  /// 现在统一由壳层裁决，这里只提供"吃掉这次返回"的能力。
  static Future<bool> Function()? consumeBack;

  final DshRuntime runtime;

  @override
  State<BotPage> createState() => _BotPageState();
}

enum _Phase { starting, ready, failed }

class _BotPageState extends State<BotPage> {
  _Phase _phase = _Phase.starting;

  /// 手机适配 CSS + 网页侧修正（整段注入到 Bot 页的 WebView 里）。
  ///
  /// 为什么需要（2026-10-19 用户报「点 + 只看到几个图标、看不到建群」）：
  /// Bot 页跑的是 ds-bot 的**桌面网页 UI**。最先撞上的是它的右侧浮层 `.bt-pane`：
  /// 宽度按「对话列右边 → 屏幕右边」算（`usePaneLeft()` 取
  /// `[class*="_footArea"]` 父元素的 `getBoundingClientRect().right`，写进 inline
  /// `left`，而 CSS 里还有 `right:0`）—— 桌面上那个差有几百像素，手机上几乎为 0
  /// → 面板被挤到一百来像素，选项文字被 `text-overflow:ellipsis` 吃干净，**只剩图标**。
  ///
  /// 之后陆续加的四件事，走同一条路（不改 ds-bot 源码 —— 它随 runtime 分发，App 侧注入最省事）：
  ///
  /// 1. **设置对话框在窄屏改成上下排布**：`.bt-settings-main` 的宽度是**硬编码**
  ///    `calc(var(--bt-set-w) - 198px)`（桌面布局是「198px 页面列表 + 右侧页面」）→
  ///    手机上 342-198 = **144px**，页面被挤爆、标题与右上角关闭按钮叠在一起。
  ///    用户原话：「点 + → 定时任务，弹出的 bot 设置页面几乎无法使用」「顶部按钮重叠」。
  ///    第二版按用户要求再改：九栏**全部摊成两行**（不要横滑那条杠）；并且给右上角那个
  ///    `position:absolute;top:12px;right:12px` 的关闭按钮**留出 52px** —— 竖排之后它
  ///    正好压在导航行右端，这就是「顶部按钮重叠」的真身。
  /// 1b. **「+」菜单那条「定时任务」改名「设置」，并落到设置页的「通用」**（用户 2026-10-19）：
  ///    它的 onClick 固定调 `openSettings('schedules')`、是 React 内部绑的，外面改不了 ——
  ///    所以「改文案 + 拿掉设置页里的『定时任务』一栏 + 万一落到那页就自动点『通用』」三招。
  /// 2. **藏掉并拦住通往 DSH(Harness) 界面的入口**（用户要求：用户改到 DSH 设置会把
  ///    Bot 的模型/插件配置搞乱）。ds-bot 里通往它的显式入口有三处：设置抽屉的
  ///    `Harness 设置`、模型菜单的 `模型和服务商…`、定时任务页的 `打开 Harness 设置`；
  ///    还有一条**后门** —— 账号菜单的 `切换经典 Agent 模式`（`setSurface("agent")`），
  ///    ds-bot 注释原话是 shell 的设置启动器「comes back in Agent mode」。四条全堵：
  ///    CSS 藏 + JS 按文案藏（含英文，界面语言不是中文也拦得住）+ **捕获阶段吃掉点击**
  ///    （`stopPropagation` 之后 React 挂在根节点上的 onClick 收不到，别的路径也走不通）。
  /// 3. **两处文案改成实话**：`Office 预览不可用。…启用文档预览服务。`（DSH 的文件预览
  ///    插件报的）→ 指向 **资料库**（用户要求「产物到资料库查看」）；定时任务页那句
  ///    「去 Harness 设置的插件页启用」→ 说明手机版没开那个插件（按钮被我们藏了，
  ///    留着就是死路）。
  /// 4. **主题跟随 App**：网页的主题偏好存在宿主设置里、默认 `system`（跟手机系统），
  ///    不是跟 App。这里把 `body[data-ds-dark-theme]` 按 App 深浅**钉住**；App 切皮肤时
  ///    由 [_themeJs] 立刻重钉，runtime 若重新 publish 则由 observer 再钉回来。
  ///
  /// ⚠️ 这段必须是**合法 JS**。108 版在 `].join('` 后面写入了一个真换行（本意 `'\n'`）→
  /// `node --check` 直接报 SyntaxError，整段没执行、一个 `<style>` 都没插进去（表面看就是
  /// "改了没用"）。现在多行 CSS 用反引号模板字符串承载，Dart 原始字符串里不需要任何 JS
  /// 转义，这类错从此犯不出来。**改动后仍要用 `node --check` 验一遍。**
  ///
  /// `__DSH_APP_DARK__` 是占位符，由 [_webPatchJs] 替换成 `true`/`false`（App 当前是不是
  /// 深色）—— 用占位符替换而不是 Dart 插值，是为了让这段保持 `const` 原始字符串。
  /// 取一个 URL 的 `scheme://host:port`（取不到就返回空串）。
  ///
  /// 为什么需要：Bot 服务的 **token 每次重启都会变**，但页面来自同一个源。
  /// 判"是不是我们自己的页面"只能比 origin，不能比完整 URL ——
  /// 比完整 URL 会把"同机不同 token"也拦掉（2026-10-20 真机 bug）。
  static String _originOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return '';
    return '${u.scheme}://${u.host}:${u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80)}';
  }

  static const String _webPatchTemplate = r"""
  (function () {
    var APP_DARK = __DSH_APP_DARK__;

    // ── ① 手机适配 CSS ────────────────────────────────────────────────────
    if (!document.getElementById('dsh-mobile-fit')) {
      var st = document.createElement('style');
      st.id = 'dsh-mobile-fit';
      st.textContent = `
.bt-pane { left: auto !important; right: 0 !important; width: min(100vw, 440px) !important; max-width: 100vw !important; }
.bt-pane .bt-drop { left: 8px !important; width: calc(100% - 16px) !important; max-height: min(420px, 55vh) !important; }
[role="menu"], [role="listbox"], .bt-menu, .bt-drop { max-height: min(420px, 60vh) !important; overflow-y: auto !important; }
[role="dialog"] { max-width: 100vw !important; }
@media (max-width: 720px) {
  .bt-settings { flex-direction: column !important; --bt-set-w: calc(100vw - 16px) !important; --bt-set-h: min(calc(100vh - 24px), 780px) !important; }
  /* 九个栏目**全部摊成两行**（用户 2026-10-19：不要顶部那条滑动杠、不要横滑）。
     右上角要留出 52px 给关闭按钮 —— 它是 position:absolute;top:12px;right:12px，
     竖排之后正好压在导航行右端（用户报的"按钮重叠"就是它）。 */
  .bt-settings-nav { width: 100% !important; flex: none !important; flex-direction: row !important; flex-wrap: wrap !important; overflow: visible !important; height: auto !important; border-right: 0 !important; border-bottom: .5px solid var(--bt-line) !important; padding: 10px 52px 10px 10px !important; gap: 6px !important; align-items: center !important; }
  .bt-settings-item { flex: none !important; white-space: nowrap !important; }
  /* 滑块在换行布局里会飘到错的位置 → 藏掉；选中态改用 item 自己的底色
     （ds-bot 在 data-glide 时把 item 底色设成透明、靠滑块表示，这里补回来）。 */
  .bt-settings-nav > .bt-thumb { display: none !important; }
  .bt-settings-nav[data-glide] .bt-settings-item[aria-current="page"] { background: var(--bt-active) !important; color: var(--bt-ink) !important; }
  /* 2026-10-20：上下排布后 height:auto 让正文区**没了滚动容器** —— 设置页内容一长就滑不动。
     这里把 main 自己变成可滚动区（并允许内部块收缩），竖滑交还给浏览器。 */
  .bt-settings-main { width: 100% !important; flex: 1 1 auto !important; min-height: 0 !important; height: auto !important; overflow-y: auto !important; overscroll-behavior-y: contain !important; -webkit-overflow-scrolling: touch !important; }
  .bt-settings-main > * { flex-shrink: 0 !important; }
  .bt-settings-head { padding: 10px 56px 4px 16px !important; }
  /* 2026-10-20（0.78）：再收一批**写死桌面尺寸**的地方 —— 都是窄屏会溢出/被裁的。
     用量页的月历是最明显的：.bt-us-month 252px 宽 + .bt-us-days 7×36px 固定格子。 */
  .bt-us-month { width: 100% !important; max-width: 100% !important; }
  .bt-us-days { grid-template-columns: repeat(7, minmax(0, 1fr)) !important; }
  .bt-settings-usage { left: 0 !important; width: 100% !important; }
  /* 新建 Bot 的卡片（.bt-create-card 有 max-width:400px，窄屏再收一点） */
  .bt-create-card { max-width: 100% !important; }
  /* 任务行里两段固定宽（160 / 110）在窄屏会顶出去 → 允许换行 */
  .bt-task-bot { max-width: 100% !important; min-width: 0 !important; }
  .bt-task-time { min-width: 0 !important; }
  /* 账号菜单 / 记忆菜单这类弹层：别比屏幕还宽 */
  .bt-account-menu, .bt-mem-menu, .bt-us-month { max-width: calc(100vw - 24px) !important; }
}
.bt-settings-item.bt-settings-shell { display: none !important; }
body { overscroll-behavior-y: contain; }
`;
      document.head.appendChild(st);
    }

    // ── ①-b 设计令牌：把 App 的配色桥接给网页（2026-10-20，用户「Bot 和 App 风格非常不搭」）
    //
    // 做法：ds-bot 的调色板是 body{--bt-…} 与 body[data-ds-dark-theme]{--bt-…} 两组 CSS 变量，
    // 这里用【同选择器】再写一遍（本 style 在后面 → 后者生效），值全部来自 Flutter 侧的
    // DshColors（单一真源）。深色两份都写：因为 body[data-ds-dark-theme] 比 body 特异度高，
    // 只覆盖前者的话深色下仍是 ds-bot 自己的值。
    // ⚠️ 本段在 CSS 模板字符串**之外**；它自己那对反引号承载令牌样式。
    //    往这段注释里写反引号仍会截断模板（108 版的教训）—— 一律用「」代替。
    // ⚠️⚠️ 注释里**也绝不能写出占位符的名字**（2026-10-20 踩过）：替换用的是 replaceFirst，
    //    它命中的是注释里那一个 → 多行 CSS 被塞进 // 注释，后面几行变成裸代码 →
    //    整段注入脚本语法错误 → **一条注入都不生效**（+ 菜单改名、设置页排版、文案、配色全没了）。
    if (!document.getElementById('dsh-app-tokens')) {
      var tk = document.createElement('style');
      tk.id = 'dsh-app-tokens';
      tk.textContent = `__DSH_TOKENS_CSS__`;
      document.head.appendChild(tk);
    }

    // ── ①-c 移动布局层（CSS-only，源码见 bot_mobile_layout.dart）────────────
    // 只调布局与可读性：一屏一页 / 手指能点 / 两套主题都看得见。
    // 独立 style 标签，且必须放在下面「已注入过就 return」的守卫**之前** ——
    // 否则页面被 React 重渲染后补注入时，这一段会被跳过。
    if (!document.getElementById('dsh-mobile-layout')) {
      var ly = document.createElement('style');
      ly.id = 'dsh-mobile-layout';
      ly.textContent = __DSH_MOBILE_LAYOUT__;
      document.head.appendChild(ly);
    }


    // ── ② 网页侧留痕 ─────────────────────────────────────────────────────
    // 为什么必须在网页里做：App 看不见网页内部的点击。"点了 + 没反应"到底卡在
    // ①点击没发生 ②点击发生了但输入卡片里没有 file input ③点击到了宿主但选文件失败
    // —— 只有网页侧自报才能区分。只回报**事实**（点了什么、尺寸多少），不猜、不改行为。
    if (window.__dshBotTrace) {
      if (window.__dshThemePin) window.__dshThemePin();
      return;
    }
    window.__dshBotTrace = true;

    function post(s) {
      try { if (window.dshBotLog) window.dshBotLog.postMessage(String(s).slice(0, 300)); } catch (e) {}
    }
    function size(el) {
      if (!el) return '无';
      var r = el.getBoundingClientRect();
      return Math.round(r.width) + 'x' + Math.round(r.height);
    }
    function probe(why) {
      var card = document.querySelector('[data-composer-card]');
      var inCard = card ? card.querySelector('input[type=file]') : null;
      post('量尺寸[' + why + '] 发给浮层=' + size(document.querySelector('.bt-pane')) +
           ' 选项列表=' + size(document.querySelector('.bt-drop')) +
           ' 设置对话框=' + size(document.querySelector('.bt-settings')) +
           ' 设置页正文=' + size(document.querySelector('.bt-settings-main')) +
           ' 输入卡片=' + (card ? '有' : '无') +
           ' 卡片内文件输入=' + (inCard ? '有' : '无'));
    }
    window.addEventListener('error', function (e) {
      post('网页报错：' + (e && e.message) + '（' + (e && e.filename) + ':' + (e && e.lineno) + '）');
    }, true);
    document.addEventListener('change', function (e) {
      var t = e.target;
      if (t && t.type === 'file') post('文件输入框已选中 ' + (t.files ? t.files.length : 0) + ' 个文件');
    }, true);
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (!t || !t.closest) return;
      if (t.type === 'file') { post('网页点了文件输入框'); return; }
      var el = t.closest('.bt-plus');
      if (el) { post('点「+」（输入框左边那个）'); setTimeout(function () { probe('点+ 之后'); }, 260); return; }
      el = t.closest('.bt-plus-menu button, .bt-menu button, [role="menuitem"]');
      if (el) {
        post('点菜单项：' + (el.textContent || '').trim());
        setTimeout(function () { probe('点菜单项之后'); }, 260);
        return;
      }
      el = t.closest('.bt-pane, .bt-settings-layer');
      if (el) { post('点浮层/设置层内'); setTimeout(function () { probe('点浮层之后'); }, 260); return; }
    }, true);

    // ── ③ 主题跟随 App ───────────────────────────────────────────────────
    function applyTheme() {
      var dark = (typeof window.__dshAppDark === 'boolean') ? window.__dshAppDark : APP_DARK;
      try {
        document.documentElement.dataset.dsThemeSource = dark ? 'dark' : 'light';
        if (document.body && document.body.hasAttribute('data-ds-dark-theme') !== dark) {
          document.body.toggleAttribute('data-ds-dark-theme', dark);
          post('主题已按 App 设为' + (dark ? '深色' : '浅色'));
        }
      } catch (e) {}
    }
    window.__dshAppDark = APP_DARK;
    window.__dshThemePin = applyTheme;

    // ── ④ 藏掉并拦住通往 DSH(Harness) 的入口 ──────────────────────────────
    // 三处显式入口 + **一条通往后门的**：账号菜单里的「切换经典 Agent 模式」
    //（actions.setSurface("agent")）。ds-bot 自己的注释写着 shell 的设置启动器
    // 「comes back in Agent mode」—— 切过去 DSH 的设置入口就又冒出来了，所以这条
    // 也必须堵（用户的要求是"不要把 DSH 设置开放给用户"）。
    var HARNESS = ['打开 Harness 设置', 'Open Harness settings', 'Harness 设置', 'Harness settings',
                   '模型和服务商', 'Models and providers',
                   '切换经典 Agent 模式', 'Switch to classic Agent mode'];
    function harnessEntry(el) {
      if (!el) return false;
      var s = (el.textContent || '').trim();
      if (!s || s.length > 80) return false;
      for (var i = 0; i < HARNESS.length; i++) { if (s.indexOf(HARNESS[i]) >= 0) return true; }
      return false;
    }
    function hideHarness() {
      var els = document.querySelectorAll('button,[role="menuitem"],a');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (el.getAttribute && el.getAttribute('data-dsh-hidden') === '1') continue;
        if (!harnessEntry(el)) continue;
        el.style.display = 'none';
        try { el.setAttribute('data-dsh-hidden', '1'); } catch (e) {}
        // 它要是这一组里最后留下的那个（「切换经典 Agent 模式」独占一组），把组前的
        // 分隔线也收掉，免得菜单底部剩一条光秃秃的横线。
        try {
          var prev = el.previousElementSibling;
          if (prev && (prev.className || '').indexOf('bt-menu-sep') >= 0) {
            var lonely = true;
            var sib = el.nextElementSibling;
            while (sib && (sib.className || '').indexOf('bt-menu-sep') < 0) {
              if (sib.tagName === 'BUTTON' && sib.style.display !== 'none') { lonely = false; break; }
              sib = sib.nextElementSibling;
            }
            if (lonely) prev.style.display = 'none';
          }
        } catch (e) {}
        post('已隐藏通往 DSH 的入口：' + (el.textContent || '').trim().slice(0, 24));
      }
    }
    // 双保险：即使还有别的路径（菜单/键盘快捷键），点了也不放行 —— 捕获阶段先吃掉
    // 事件，React 挂在根节点上的 onClick 就收不到它。
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (!t || !t.closest) return;
      if (!harnessEntry(t.closest('button,[role="menuitem"],a'))) return;
      e.preventDefault();
      e.stopPropagation();
      post('已拦截 DSH(Harness) 设置入口的点击');
    }, true);

    // ── ⑤ 两处文案改成实话 ───────────────────────────────────────────────
    var OFFICE_MARK = 'Office 预览不可用';
    var OFFICE_HINT = '请到资料库查看文件';
    function fixOfficeHint() {
      var els = document.querySelectorAll('span,p,div');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (el.children.length !== 0) continue;
        var t = el.textContent || '';
        if (t.indexOf(OFFICE_MARK) < 0 || t.indexOf('资料库') >= 0) continue;
        el.textContent = OFFICE_HINT;
        post('已把「Office 预览不可用」改写成指向资料库');
      }
    }
    var AUTO_MARK = 'Harness 设置的插件页';
    var AUTO_HINT = '手机版没有开 DSH 的「自动化任务」插件，Bot 的定时任务暂时用不了。';
    function fixAutoHint() {
      var els = document.querySelectorAll('span,p,div');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (el.children.length !== 0) continue;
        var t = el.textContent || '';
        if (t.indexOf(AUTO_MARK) < 0 || t.indexOf('手机版没有开') >= 0) continue;
        el.textContent = AUTO_HINT;
        post('已改写「定时任务」页里指向 Harness 设置的那句');
      }
      var titles = document.querySelectorAll('.bt-task-off-title');
      for (var j = 0; j < titles.length; j++) {
        if ((titles[j].textContent || '').indexOf('在 DSH 里打开') >= 0) {
          titles[j].textContent = 'Bot 的定时任务暂时用不了';
        }
      }
    }

    // ── ⑥ 「+」菜单那条改名为「设置」，并落到设置页的「通用」（用户 2026-10-19）──
    // ds-bot 里这条菜单项固定调 openSettings('schedules') —— 它的 onClick 是 React
    // 绑在内部组件上的，从外面改不了。所以分三步：
    //   ① 把菜单文案「定时任务」改成「设置」；
    //   ② 设置页里**拿掉「定时任务」这一栏**（手机版没开 DSH 的自动化插件，那页是死路）；
    //   ③ 万一还是落到了定时任务页（比如这次的入口），自动点一下「通用」。
    function renamePlusMenu() {
      var labels = document.querySelectorAll('.bt-plus-menu .bt-menu-label, .bt-menu .bt-menu-label');
      for (var i = 0; i < labels.length; i++) {
        var t = (labels[i].textContent || '').trim();
        if (t === '定时任务' || t === 'Scheduled task') {
          labels[i].textContent = '设置';
          post('「+」菜单里的「定时任务」已改名为「设置」');
        }
      }
    }
    function schedulesLabel(el) {
      var t = (el.textContent || '').trim();
      return t.indexOf('定时任务') >= 0 || t.indexOf('Scheduled tasks') >= 0;
    }
    function dropSchedulesTab() {
      var items = document.querySelectorAll('.bt-settings-nav .bt-settings-item');
      for (var i = 0; i < items.length; i++) {
        if (!schedulesLabel(items[i])) continue;
        if (items[i].style.display === 'none') continue;
        items[i].style.display = 'none';
        post('设置页里已拿掉「定时任务」这一栏');
      }
    }
    function redirectSchedules() {
      var layer2 = document.querySelector('.bt-settings-layer');
      if (!layer2) { window.__dshSchedDone = false; return; }
      if (window.__dshSchedDone) return;
      var items = document.querySelectorAll('.bt-settings-nav .bt-settings-item');
      var general = null, onSchedules = false;
      for (var i = 0; i < items.length; i++) {
        var t = (items[i].textContent || '').trim();
        if (t.indexOf('通用') >= 0 || t === 'General') general = items[i];
        if (schedulesLabel(items[i]) && items[i].getAttribute('aria-current') === 'page') onSchedules = true;
      }
      if (onSchedules && general) {
        window.__dshSchedDone = true;   // 一次只切一次（关掉对话框时复位），别反复点
        general.click();
        post('从「+ → 设置」进来时已自动落到「通用」页');
      }
    }

    // ── ⑤-b 「添加文件」兜底 + 探针（2026-10-24 用户报「点了没反应」）──────────
    // ds-bot 的实现是一路可选链：
    //   button.closest("[data-composer-card]")?.querySelector("input[type=file]")?.click()
    // 任一环找不到就**静默什么都不做** —— 用户看到的就是"没反应"。
    //
    // ⚠️ 兜底必须在**同步**路径里做：file input 的 click() 需要用户手势（user
    // activation），放到 setTimeout 里浏览器会直接忽略（不弹选择器、也不报错）。
    // 所以这里在 capture 阶段先判断「React 那条路会不会断」：
    //   · + 按钮在 [data-composer-card] 内 → 交给 React（它会点卡片里的 input）
    //   · 不在卡片内（closest 返回 null，React 必失败）→ 立刻自己点全页那个 input
    // 另外给 input 的 click 打标记，用来在诊断日志里区分
    // 「点了但宿主没收到」和「压根没点」。
    var dshmFileClickAt = 0;
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (t && t.tagName === 'INPUT' && String(t.type).toLowerCase() === 'file') {
        dshmFileClickAt = Date.now();
        post('文件输入框被点击（React 或兜底），随后应看到宿主「网页请求选择文件」日志');
      }
    }, true);
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (!t || !t.closest) return;
      var item = t.closest('.bt-plus-menu button, [role="menuitem"]');
      if (!item) return;
      var label = (item.textContent || '').trim();
      if (label.indexOf('添加文件') < 0 && label.indexOf('Add files') < 0) return;
      var plus = document.querySelector('.bt-plus');
      var inCard = !!(plus && plus.closest('[data-composer-card]'));
      var cardInput = document.querySelector('[data-composer-card] input[type=file]');
      var anyInput = document.querySelector('input[type=file]');
      if (inCard) {
        post('「添加文件」：按钮在卡片内，交给页面自己点（卡片内文件输入=' +
             (cardInput ? '有' : '无') + '）');
        return;
      }
      // React 的 closest 一定是 null —— 同步兜底（仍有用户手势）
      if (anyInput) {
        post('「添加文件」兜底：按钮不在卡片内，改点全页 input[type=file]');
        anyInput.click();
      } else {
        post('「添加文件」失败：全页没有 input[type=file]（卡片=' +
             (document.querySelector('[data-composer-card]') ? '有' : '无') + '）');
      }
    }, true);

    // ── ⑥-b 点会话行后自动收起名册（一屏一页）────────────────────────────
    // 名册是满屏一页：点一条会话如果不把名册收起来，用户仍停在名册，
    // 会以为"没点中"（0.79 审计第 6 条同款）；而且会话里的设置层(z=60)
    // 会被侧栏压住看不见。收起动作交给页面自己的「关闭导航」
    // （display:none 的元素 click() 照样派发事件，0.79 已实测）。
    document.addEventListener('click', function (e) {
      var t = e.target;
      if (!t || !t.closest) return;
      if (!t.closest('.bt-row')) return;
      setTimeout(function () {
        try {
          var close = document.querySelector('[aria-label="关闭导航"]');
          if (close) close.click();
        } catch (err) {}
      }, 280);
    }, true);

    // ── ⑦ 扫一遍 + 盯住 DOM（这些元素都是 SPA 按需渲染出来的）─────────────
    // ── 用户 2026-10-24：「取消通用设置里『切换 agent 模式』那一栏」──────────
    // ds-bot 的「模式」分区只有「经典 Agent 模式 / 切换」一条，切过去是把界面
    // 换回经典 Agent —— 手机上属于会掉出 Bot 界面的死路，直接整栏收掉。
    function hideModeSection() {
      var secs = document.querySelectorAll('.bt-set-section');
      for (var i = 0; i < secs.length; i++) {
        var h = secs[i].querySelector('h3') || secs[i].querySelector('[class*="title"]');
        var t = h ? (h.textContent || '').trim() : '';
        if (t !== '模式' && t !== 'Mode') continue;
        if (secs[i].style.display === 'none') continue;
        secs[i].style.display = 'none';
        post('已隐藏设置页的「模式」一栏（切换经典 Agent 是死路）');
      }
    }

    function sweep() {
      applyTheme();
      hideHarness();
      hideModeSection();
      fixOfficeHint();
      fixAutoHint();
      renamePlusMenu();
      dropSchedulesTab();
      redirectSchedules();
    }
    sweep();
    setTimeout(sweep, 900);
    setTimeout(sweep, 2600);
    setTimeout(function () { probe('页面加载后 1.2s'); }, 1200);
    setTimeout(function () { probe('页面加载后 4s'); }, 4000);
    try {
      var obs = new MutationObserver(function () {
        if (window.__dshSweepT) return;
        window.__dshSweepT = setTimeout(function () { window.__dshSweepT = null; sweep(); }, 180);
      });
      if (document.body) {
        obs.observe(document.body, {
          childList: true, subtree: true,
          attributes: true, attributeFilter: ['data-ds-dark-theme']
        });
      }
    } catch (e) {}
  })();
  """;

  /// 按 App 当前深浅色生成要注入的整段 JS。
  static String _webPatchJs({required bool dark}) =>
      _fill(_webPatchTemplate, dark: dark);

  /// 把占位符填进去，并**校验没有残留**。
  ///
  /// 为什么用 replaceAll 而不是 replaceFirst：2026-10-20 的坑 —— 注释里写了占位符的名字，
  /// `replaceFirst` 命中注释而不是代码，多行 CSS 被塞进 `//` 后面 → 整段脚本语法错误、
  /// 一条注入都不生效。`replaceAll` + 残留断言让这种"写错位置"当场暴露，而不是静默失效。
  ///
  /// 移动布局层用 [jsonEncode] 转成**合法的 JS 字符串字面量**：那段 CSS 里有换行、
  /// 单引号与反斜杠，塞进模板字符串迟早被某个字符截断（108 版就是这么整段失效的）。
  static String _fill(String template, {required bool dark}) {
    final js = template
        .replaceAll('__DSH_APP_DARK__', dark ? 'true' : 'false')
        .replaceAll('__DSH_TOKENS_CSS__', _tokensCss())
        .replaceAll('__DSH_MOBILE_LAYOUT__', jsonEncode(botMobileLayoutCss));
    if (js.contains('__DSH_')) {
      // 真出现了说明模板里还有第三个没被替换的占位符（或名字拼错）。
      DiagnosticsLog.add('dsh-bot', '注入脚本里有未替换的占位符 → 这段注入可能整体失效');
      debugPrint('[dsh-bot] ⚠️ 未替换的占位符残留');
    }
    return js;
  }

  /// 把 App 的设计令牌编译成 CSS（**单一真源是 `DshColors`**）。
  ///
  /// 只桥接**颜色**这一层：它决定了两个界面"像不像一家人"的 80%。
  /// 圆角/字号这层故意先不动 —— ds-bot 的圆角散落在几十个类里，逐个覆盖的收益远小于风险。
  static String _tokensCss() {
    final body = _tokens().entries.map((e) => '    ${e.key}: ${e.value};').join('\n');
    return 'body{\n$body}\nbody[data-ds-dark-theme]{\n$body}';
  }

  /// 令牌表（CSS 变量名 → 值）。样式表与内联注入共用这一份，避免两处走样。
  static Map<String, String> _tokens() => <String, String>{
        '--bt-main': _hex(DshColors.bg),
        '--bt-sidebar': _solid(DshColors.navBg),
        '--bt-card': _solid(DshColors.surface),
        '--bt-bubble': _solid(DshColors.surfaceHigh),
        '--bt-ink': _hex(DshColors.text),
        '--bt-ink-2': _hex(DshColors.textDim),
        '--bt-ink-3': _hex(DshColors.textFaint),
        '--bt-line': _hex(DshColors.line),
        '--bt-line-2': _hex(DshColors.line2),
        '--bt-line-weak': _hex(DshColors.line),
        '--bt-hover': _rgba(DshColors.accent, 0.08),
        '--bt-active': _rgba(DshColors.accent, 0.14),
        '--bt-tag-bg': _rgba(DshColors.accent, 0.10),
        '--bt-tag-ink': _hex(DshColors.textDim),
        '--bt-accent': _hex(DshColors.accent),
        '--bt-user': _hex(DshColors.accent),
        '--bt-user-ink': _hex(DshColors.onAccent),
      };

  /// 颜色 → CSS 值。**必须保留 alpha**：App 的 surface / navBg / surfaceHigh
  /// 是半透明白，`& 0xFFFFFF` 会把它变成纯白 —— 深色皮肤下卡片与消息气泡
  /// 就是「白底配浅色字」（实测：切深色后 `.bt-bubble` 仍是 rgb(255,255,255)）。
  static String _hex(Color c) {
    final v = c.toARGB32();
    final a = (v >> 24) & 0xFF;
    final r = (v >> 16) & 0xFF;
    final g = (v >> 8) & 0xFF;
    final b = v & 0xFF;
    if (a == 0xFF) {
      return '#${r.toRadixString(16).padLeft(2, '0')}'
          '${g.toRadixString(16).padLeft(2, '0')}'
          '${b.toRadixString(16).padLeft(2, '0')}';
    }
    return 'rgba($r, $g, $b, ${(a / 255).toStringAsFixed(3)})';
  }

  /// 半透明表面色**合成到页面底**之后的不透明值。
  /// 直接给网页一个半透明背景，在 ds-bot 那层层叠叠的容器上会透出白色底；
  /// 合成成实色更可控，也正好和 App 里的观感一致。
  static String _solid(Color c) => _hex(Color.alphaBlend(c, DshColors.bg));

  static String _rgba(Color c, double a) {
    final v = c.toARGB32();
    return 'rgba(${(v >> 16) & 0xFF}, ${(v >> 8) & 0xFF}, ${v & 0xFF}, $a)';
  }

  /// 把令牌**内联**打到 html 与 body 上（`important`）。
  ///
  /// 为什么样式表还不够：ds-bot 把主题变量写在 `documentElement.style` 上，
  /// 内联优先于任何样式表 —— 只写 `body{--bt-…}` 时网页仍用自己的配色
  /// （实测浅色下「我的消息」气泡是纯黑 `#070707`、字还看不见）。
  static String _varsJs() {
    return '''
  (function () {
    var V = ${jsonEncode(_tokens())};
    var roots = [document.documentElement, document.body];
    for (var i = 0; i < roots.length; i++) {
      var r = roots[i];
      if (!r) continue;
      for (var k in V) {
        try { r.style.setProperty(k, V[k], 'important'); } catch (e) {}
      }
    }
  })();
  ''';
  }

  /// 切深色时把**浅色硬编码**的容器压深；切回浅色时清掉上一轮的内联底色。
  ///
  /// 实测：ds-bot 一批容器的 background 写死 `rgb(244,245,247)`，切深色后
  /// 文字变浅、底色没变 → 浅底浅字（用户报的「切换以后文字看不见」）。
  /// 只处理「亮度 > 0.82」的容器；有灰度的卡片/气泡不动，保留层次。
  static String _sweepJs({required bool dark}) => '''
  (function () {
    var dark = ${dark ? 'true' : 'false'};
    var BG = ${jsonEncode(_hex(DshColors.bg))};
    var CARD = ${jsonEncode(_solid(DshColors.surface))};
    var els = document.querySelectorAll('body *');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (!el || el.nodeType !== 1 || el === document.body) continue;
      try {
        if (!dark) {
          if (el.getAttribute('data-dshm-swept') === '1') {
            el.style.removeProperty('background-color');
            el.removeAttribute('data-dshm-swept');
          }
          continue;
        }
        var cls = typeof el.className === 'string' ? el.className : '';
        var c = getComputedStyle(el).backgroundColor;
        if (!c || c === 'transparent' || c.indexOf('rgba(0, 0, 0, 0)') === 0) continue;
        var m = c.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);
        if (!m) continue;
        var lum = (0.2126 * +m[1] + 0.7152 * +m[2] + 0.0722 * +m[3]) / 255;
        if (lum <= 0.82) continue;
        var isCard = /card|bubble|panel|item|row|menu|dialog|toast/i.test(cls);
        el.style.setProperty('background-color', isCard ? CARD : BG, 'important');
        el.setAttribute('data-dshm-swept', '1');
      } catch (e) {}
    }
  })();
  ''';

  /// 让**文件上传走主线程 fetch**，而不是 DSH 默认的 Blob Worker。
  ///
  /// 为什么（2026-10-24 真机实测）：上传实现在 `@deepseek-ai/dsh-client-file-upload`，
  /// 默认 transport 是 `new Worker(URL.createObjectURL(blob))` —— 在 Android WebView
  /// 里这条链不稳定（调用方看到的就是「附件进来了、但一直上传失败」，而且 Network
  /// 里一个上传请求都没有）。DSH 自己在服务构造时留了官方 hook：
  ///     const hook = globalThis.__DSH_FILE_UPLOAD__;
  ///     this.transport = hook === void 0 ? workerTransport() : customTransport(hook.fetch);
  /// 所以只要在页面 **boot 之前** 把这个 hook 装上，上传就变成普通 fetch。
  ///
  /// ⚠️ 时机是关键：服务是在 Cordis boot 时构造的，onPageFinished 再注入已经晚了
  /// （transport 已经选成 worker）。必须在 `onPageStarted` 里塞。
  static const String _uploadHookJs = r"""
  (function () {
    if (window.__DSH_FILE_UPLOAD__) return;
    window.__DSH_FILE_UPLOAD__ = {
      fetch: function (input, init) { return fetch(input, init); }
    };
  })();
  """;

  /// 设置层出现时给 body 打标记 —— 布局层用它藏掉宿主那两个圆形浮层
  /// （实现在 bot_mobile_layout.dart 的 ⑫）。低频轮询即可，不做 MutationObserver。
  static const String _settingsFlagJs = r'''
  (function () {
    if (window.__dshmSettingsFlag) return;
    window.__dshmSettingsFlag = true;
    function sync() {
      try {
        var open = !!document.querySelector('.bt-settings-layer');
        if (open) document.body.setAttribute('data-dshm-settings', '');
        else document.body.removeAttribute('data-dshm-settings');
      } catch (e) {}
    }
    sync();
    window.__dshmSettingsTimer = setInterval(sync, 600);
  })();
  ''';

  /// **只**做一件事：把 App 的深浅色同步给网页（可反复调用；App 切皮肤时用）。
  ///
  /// 为什么不重跑整段：那段有 `window.__dshBotTrace` 守卫（监听器只装一次），
  /// 而这个动作要能随时执行 —— 深浅色是新加的、会变的东西。
  static String _themeJs({required bool dark}) => '''
  (function () {
    var dark = ${dark ? 'true' : 'false'};
    window.__dshAppDark = dark;
    // 令牌跟着重刷：换皮肤/深浅色时，网页的配色要立刻跟上
    try {
      var tk = document.getElementById('dsh-app-tokens');
      if (tk) { tk.textContent = `__DSH_TOKENS_CSS__`; }
    } catch (e) {}
    try {
      document.documentElement.dataset.dsThemeSource = dark ? 'dark' : 'light';
      if (document.body) document.body.toggleAttribute('data-ds-dark-theme', dark);
    } catch (e) {}
  })();
  '''.replaceAll('__DSH_TOKENS_CSS__', _tokensCss());

  /// 当前 WebView 里加载的地址（用于和服务最新地址比对）。
  String? _loadedUrl;

  /// 431 自动重试只做一次（避免服务真没起时无限重载）。
  bool _retriedAfter431 = false;

  /// 清掉 WebView 的 cookie（见调用处的 431 说明）。
  ///
  /// 只影响本 App 这一个 WebView —— 里面除了 Bot 页没有别的东西。
  /// 失败也不拦启动：大不了继续撞 431，日志里留痕。
  Future<void> _clearWebCookies(String why) async {
    try {
      await WebViewCookieManager().clearCookies();
      DiagnosticsLog.add('dsh-bot', '已清 WebView cookie（$why）');
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '清 WebView cookie 失败（$why）：$e');
    }
  }

  /// 服务地址变了（通常是重启换了端口）→ 用新地址重新加载。
  void _onServerChanged() {
    final s = BotServer.live.value;
    if (!mounted || s == null) return;
    if (s.url == _loadedUrl) return;
    debugPrint('[dsh-bot] 服务地址变化 → 重新加载：${s.url}');
    // 只记"变了"，不记地址（地址里带 token）。
    DiagnosticsLog.add('dsh-bot', 'Bot 服务地址变化（服务重启/换端口）→ WebView 重新加载');
    _loadedUrl = s.url;
    unawaited(_clearWebCookies('服务地址变化').then((_) {
      _web?.loadRequest(Uri.parse(s.url));
    }));
  }
  WebViewController? _web;
  String? _error;
  String _lastLine = '';

  /// 上一次注入给网页的深浅色（App 切皮肤时用来判断要不要重钉主题）。
  bool? _appliedDark;

  /// 一次性提示。WebView 回调里出错时**必须让用户看得见**：
  /// 否则表现就是"点了没反应"，连是不是我们的问题都分不出来。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  /// App 的深浅色变了 → 立刻把网页也改过来（不重载页面）。
  ///
  /// 为什么不重跑整段补丁：那段有 `window.__dshBotTrace` 守卫（监听器只装一次），
  /// 主题是"会变"的东西，得能单独、反复地推过去。
  Future<void> _pushThemeToWeb() async {
    final web = _web;
    if (web == null) return;
    final dark = !DshColors.isLight;
    // 三步各自独立：_themeJs 失败不能让变量与扫底也一起丢（2026-10-23 的教训）。
    try {
      await web.runJavaScript(_themeJs(dark: dark));
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '主题同步到网页失败（网页仍用旧的主题）：$e');
    }
    try {
      await web.runJavaScript(_varsJs());
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '令牌内联失败（网页可能仍用 ds-bot 自己的配色）：$e');
    }
    try {
      await web.runJavaScript(_sweepJs(dark: dark));
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '深色扫底失败：$e');
    }
    DiagnosticsLog.add('dsh-bot', 'App 主题变化 → 已把网页改成${dark ? '深色' : '浅色'}');
  }

  /// 网页能退一层就退，并告诉壳层"这次返回我吃掉了"；否则交回壳层。
  Future<bool> _consumeBack() async {
    final web = _web;
    if (web == null) return false;
    try {
      if (await web.canGoBack()) {
        DiagnosticsLog.add('dsh-bot', '返回：网页后退一层');
        await web.goBack();
        return true;
      }
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '返回：网页后退失败（交回壳层）：$e');
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    BotPage.consumeBack = _consumeBack;
    // 换肤（含深浅色）是"会变"的东西：Bot 页常驻 IndexedStack，换肤时 build
    // 不一定跑（0.79 实测），所以单独监听，把主题立刻推给网页。
    DshColors.skinRevision.addListener(_onSkinChanged);
    unawaited(_boot());
  }

  /// App 换肤 → 把网页的深浅色、令牌与深色扫底一起重推。
  void _onSkinChanged() {
    if (!mounted) return;
    _appliedDark = !DshColors.isLight;
    unawaited(_pushThemeToWeb());
  }

  @override
  void dispose() {
    if (BotPage.consumeBack == _consumeBack) BotPage.consumeBack = null;
    DshColors.skinRevision.removeListener(_onSkinChanged);
    BotServer.live.removeListener(_onServerChanged);
    // ⚠️ 刻意**不**停 [BotServer]：Bot 团队要接着在后台干活。
    DiagnosticsLog.add('dsh-bot', '离开 Bot 页（服务继续在后台跑，会话不受影响）');
    super.dispose();
  }

  Future<void> _boot() async {
    DiagnosticsLog.add('dsh-bot', '打开 Bot 页：准备服务与本机 web 界面');
    if (mounted) {
      setState(() {
        _phase = _Phase.starting;
        _error = null;
        _lastLine = '';
      });
    }
    try {
      final server = await BotServer.ensureStarted(
        runtime: widget.runtime,
        onLog: (line) {
          if (!mounted) return;
          setState(() => _lastLine = line);
        },
      );
      if (!mounted) return;
      // ⚠️ 地址里带 token（能力令牌），**不许写进日志** —— 这里只记"已就绪"。
      DiagnosticsLog.add('dsh-bot', 'Bot 服务已就绪，开始加载本机 web 界面');

      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(DshColors.bg);
      // ── ⓪ 网页侧留痕的回传通道 ────────────────────────────────────────────
      // 注入的脚本把"点了什么 / 量到什么尺寸 / 网页报了什么错"发回这里 → 进诊断日志。
      // 这是 App 唯一能看见「网页内部发生了什么」的眼睛（用户要求"操作都加日志痕迹"）。
      await controller.addJavaScriptChannel(
        'dshBotLog',
        onMessageReceived: (JavaScriptMessage m) =>
            DiagnosticsLog.add('dsh-bot:web', m.message),
      );

      // ── ① 文件选择（2026-10-19 用户报「Bot 页添加文件无法添加」）──────────────
      // 链路（已按源码逐环核对）：输入框左边那个「+」是 ds-bot 的 `ComposerPlus`
      // （菜单三项：添加文件 / 引用对话 / 定时任务），点「添加文件」它执行的是
      //   button.closest("[data-composer-card]").querySelector("input[type=file]").click()
      // 也就是替用户去点 DSH 输入卡片里那个隐藏的 `<input type=file>`；浏览器随即把
      // 「选文件」交给宿主（`onShowFileChooser`）。宿主不接管就永远没反应 —— 接的就是这段。
      //
      // ⚠️ 这里**必须留痕**：进诊断日志（用户会把报告发回来）＋ 失败时给界面提示。
      // 108 版只写了 `debugPrint`，于是"点了没反应"时既查不到、也看不见，只能靠猜：
      //   * 日志里出现「网页请求选择文件」= 点击真的到宿主了，问题在选完之后的环节；
      //   * 日志里什么都没有 = 那一层 `.click()` 压根没发生（属于网页侧）。
      if (controller.platform is AndroidWebViewController) {
        await (controller.platform as AndroidWebViewController)
            .setOnShowFileSelector((FileSelectorParams params) async {
          DiagnosticsLog.add('dsh-bot', '网页请求选择文件（模式 ${params.mode.name}）');
          try {
            final r = await FilePicker.platform.pickFiles(
              allowMultiple: params.mode == FileSelectorMode.openMultiple,
            );
            final paths = <String>[
              for (final f in r?.files ?? const <PlatformFile>[])
                if (f.path != null && f.path!.isNotEmpty) f.path!,
            ];
            DiagnosticsLog.add(
              'dsh-bot',
              r == null ? '文件选择被取消' : '已选择 ${paths.length} 个文件',
            );
            // ⚠️ 必须转成 content:// 再交回去（2026-10-24 真机实测的根因）：
            //    webview_flutter_android 的收尾是 `Uri.parse(返回值)`。直接给绝对路径
            //    （/storage/emulated/0/Download/x.txt）得到的是**没有 scheme** 的 Uri，
            //    WebView 读不到 → input.files 为空 → 页面 onChange 不触发 →
            //    用户看到「选完文件回来了，输入框里什么都没有」。
            //    原生侧会把文件复制进 filesDir/attachments（FileProvider 白名单内）再转。
            final uris = <String>[];
            for (final p in paths) {
              try {
                final u = await DshHost.channel
                    .invokeMethod<String>('fileUriForWeb', {'path': p});
                if (u != null && u.isNotEmpty) uris.add(u);
              } catch (e) {
                DiagnosticsLog.add('dsh-bot', '把文件交给网页失败（原路径不回退）：$e');
              }
            }
            DiagnosticsLog.add(
              'dsh-bot',
              '交给网页的地址：${uris.length} 个 content://（原路径 ${paths.length} 个）',
            );
            if (uris.isEmpty && paths.isNotEmpty) {
              DiagnosticsLog.add('dsh-bot', '全部转 content:// 失败，退回原路径（网页很可能读不到）');
              return paths;
            }
            return uris;
          } catch (e) {
            DiagnosticsLog.add('dsh-bot', '文件选择失败：$e');
            _toast('选文件失败：$e');
            return const <String>[];
          }
        });
      }
      await controller.setNavigationDelegate(
        NavigationDelegate(
          // ── ① 页面刚起步：抢在 Cordis boot 前装上传 hook（见 _uploadHookJs）──
          onPageStarted: (_) async {
            try {
              await controller.runJavaScript(_uploadHookJs);
              DiagnosticsLog.add('dsh-bot', '页面开始加载：已装上传 hook（走主线程 fetch）');
            } catch (e) {
              // 早期注入失败不致命：末尾的 onPageFinished 会再补一次（虽然那次已偏晚，
              // 但至少留给下一次 reload）。
              DiagnosticsLog.add('dsh-bot', '早期装上传 hook 失败：$e');
            }
          },
          // ── ② 导航拦截（2026-10-19 用户报「Bot 里的文件无法直接预览」）──────
          // 本机 Bot 服务的 URL 一律放行；其余（网页里点了文件、点了外链）拦下来，
          // 不让 WebView 变成一个"打不开的下载页"。
          // 文件预览的诉求由**资料库**兜住（它本来就带预览，且 107 起已把 Bot 工作区并进来）。
          onNavigationRequest: (NavigationRequest req) {
            // ⚠️ 2026-10-20 真机 bug：这里原来用的是**闭包里捕获的** `server.url`。
            //    Bot 服务重启换端口后，闭包还指着旧端口 → 新地址（同机、但端口不同）
            //    被当成"外部链接"拦掉（日志原文：`拦截外部导航：http://127.0.0.1:43619/`），
            //    页面于是停在一个打不开的状态，用户看到的就是「重新连接」。
            //    现在每次都读**当前**服务地址；只比 scheme+host+port（token 每次重启都会变）。
            final live = BotServer.live.value?.url ?? server.url;
            final base = _originOf(live);
            final sameOrigin = base.isNotEmpty && _originOf(req.url) == base;
            if (sameOrigin || req.url.startsWith('about:') ||
                req.url.startsWith('data:') || req.url.startsWith('blob:')) {
              return NavigationDecision.navigate;
            }
            debugPrint('[dsh-bot] 拦截外部导航（不在 App 内打开）：${req.url}');
            DiagnosticsLog.add('dsh-bot', '拦截外部导航：${req.url}');
            return NavigationDecision.prevent;
          },
          // ── ③ 整段网页补丁：手机适配 CSS + 留痕 + 主题跟随 + 三处文案/入口修正 ──
          // 详见 [_webPatchTemplate] 的类注释。页面每次加载都会重跑（守卫保证监听器
          // 只装一次）；主题按 App 当前深浅生成。
          onPageFinished: (_) async {
            final dark = !DshColors.isLight;
            _appliedDark = dark;
            // 每一步独立 try：2026-10-23 的教训是四步串一个 try —— 补丁那步一抛异常，
            // 布局 CSS / 主题变量 / 扫底整层都不注入，症状是"配色变了、排版没变"。
            try {
              await controller.runJavaScript(_webPatchJs(dark: dark));
              DiagnosticsLog.add('dsh-bot',
                  '页面加载完成：已注入网页补丁（App 当前${dark ? '深色' : '浅色'}）');
            } catch (e) {
              // ⚠️ 这条以前只写 debugPrint —— 108 版整段 JS 语法错、一个 <style> 都没插
              //    进去，日志里却什么都看不见，于是"改了没用"查了很久。必须留痕。
              DiagnosticsLog.add('dsh-bot',
                  '注入网页补丁失败（浮层宽度/主题/文案修正都不会生效）：$e');
            }
            try {
              await controller.runJavaScript(_varsJs());
            } catch (e) {
              DiagnosticsLog.add('dsh-bot', '令牌内联失败（网页可能仍用 ds-bot 自己的配色）：$e');
            }
            try {
              await controller.runJavaScript(_sweepJs(dark: dark));
            } catch (e) {
              DiagnosticsLog.add('dsh-bot', '深色扫底失败：$e');
            }
            try {
              await controller.runJavaScript(_settingsFlagJs);
            } catch (e) {
              DiagnosticsLog.add('dsh-bot', '设置层标记注入失败：$e');
            }
            // 上传 hook 兜底：早注入若被页面清掉，这里补一次（对**下一次**加载才生效，
            // 所以只记日志，不假装能救当前这次）。
            try {
              await controller.runJavaScript(_uploadHookJs);
              final hasHook = await controller.runJavaScriptReturningResult(
                  "typeof window.__DSH_FILE_UPLOAD__ === 'object' ? '1' : '0'");
              DiagnosticsLog.add('dsh-bot', '上传 hook 状态：${hasHook.toString().contains('1') ? '已装' : '缺失'}');
            } catch (e) {
              // 自检失败不影响页面：只是少一条诊断日志。
            }

            // DOM 自检：布局层是否真的插进去了。只留痕、不无限补注入 ——
            // 错误页（chrome-error）同样能跑 JS，靠"注入成功"判断页面正常会误判。
            try {
              final ok = await controller.runJavaScriptReturningResult(
                  "document.getElementById('dsh-mobile-layout') ? '1' : '0'");
              if (!ok.toString().contains('1')) {
                DiagnosticsLog.add('dsh-bot', '自检：移动布局层不在 DOM 里（下次加载会重新注入）');
              }
            } catch (e) {
              // 自检本身失败不影响页面：只是少一条诊断日志。
            }
            // 深色下 SPA 还要渲染约 2 秒：延迟再扫两次，把后出现的浅色容器也压深。
            if (dark) {
              for (final ms in const [1600, 3600]) {
                Future<void>.delayed(Duration(milliseconds: ms), () async {
                  if (!mounted || _web != controller) return;
                  try {
                    await controller.runJavaScript(_sweepJs(dark: true));
                  } catch (e) {
                    // 扫底是增强项：失败只是个别浅色块没压深，不影响可用性。
                  }
                });
              }
            }
          },
          onWebResourceError: (WebResourceError e) {
            // 只报**主文档**失败：同目录资源拉不到也走这个回调，那不是"打不开"。
            if (e.isForMainFrame != true) return;
            debugPrint('[dsh-bot] 主文档加载失败：${e.errorCode} ${e.description}');
            DiagnosticsLog.add('dsh-bot',
                '主文档加载失败：错误码 ${e.errorCode} ${e.description}');
            // 431（请求头太大，历史 cookie 攒爆了）→ 清 cookie 再重试一次。
            // 只自动重试一次：真连不上（服务没起）时不能让用户看它无限转圈。
            final headersTooLarge =
                e.description.contains('ERR_HTTP_RESPONSE_CODE_FAILURE');
            if (headersTooLarge && !_retriedAfter431) {
              _retriedAfter431 = true;
              DiagnosticsLog.add('dsh-bot',
                  '主文档加载失败疑似 431（历史 cookie 太多）→ 清 cookie 后自动重试一次');
              unawaited(() async {
                await _clearWebCookies('431 重试');
                final live = BotServer.live.value?.url ?? _loadedUrl;
                if (!mounted || live == null) return;
                await _web?.loadRequest(Uri.parse(live));
              }());
              return;
            }
            if (!mounted) return;
            setState(() {
              _phase = _Phase.failed;
              _error = '页面加载失败：${e.description}（错误码 ${e.errorCode}）';
            });
          },
        ),
      );
      // ⚠️ **先清掉 WebView 里的旧 cookie**（2026-10-28 真机 431 的根因）：
      //     服务每次重启端口都会变，而 cookie 名是按 authority（host:port）派生的 →
      //     反复安装/重启会攒下一堆 `dsh-auth-*`。真机实测 **69 个、Cookie 头 15.7 KB**，
      //     超过 Node 默认的 16 KB 请求头上限 → 服务直接回 **431**，
      //     WebView 就显示 `net::ERR_HTTP_RESPONSE_CODE_FAILURE`（看着像认证坏了，其实是头太大）。
      //     这个 WebView 只服务 Bot 页，清空是安全的；带 token 打开会当场再发一个新 cookie。
      await _clearWebCookies('首次加载');
      await controller.loadRequest(Uri.parse(server.url));
      _loadedUrl = server.url;
      if (!mounted) return;
      setState(() {
        _web = controller;
        _phase = _Phase.ready;
      });
      // ⚠️ 订阅「服务地址变化」：模型配置变更会让 Bot 服务重启、**端口随之改变**
      //（`--port 0` 每次重新分配），而 WebView 只加载一次 —— 不跟着换就会白屏/打不开。
      BotServer.live.removeListener(_onServerChanged);
      BotServer.live.addListener(_onServerChanged);
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '启动失败：$e');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '$e';
      });
    }
  }

  Future<void> _stopService() async {
    final server = BotServer.current;
    if (server == null) return;
    DiagnosticsLog.add('dsh-bot', '用户手动停止 Bot 服务');
    await server.stop();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.starting;
      _web = null;
      _lastLine = '';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Bot 服务已停止。重新打开这一页就会再起来。')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // App 切了深浅色（设置 → 外观）→ 把网页也推过去，不必重载这一页。
    final dark = !DshColors.isLight;
    if (_appliedDark != null && _appliedDark != dark) {
      _appliedDark = dark;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => unawaited(_pushThemeToWeb()));
    }
    // ⚠️ 这里**不要**再包 PopScope：见 [BotPage.consumeBack] 的注释（会弹掉根路由 → 黑屏）。
    return Scaffold(
        backgroundColor: DshColors.bg,
        appBar: AppBar(
          backgroundColor: DshColors.navBg,
          foregroundColor: DshColors.text,
          title: const Text('Bot 团队'),
          actions: [
            if (_phase == _Phase.ready)
              IconButton(
                tooltip: '重新加载',
                icon: const Icon(Icons.refresh),
                onPressed: () => _web?.reload(),
              ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (v) {
                if (v == 'stop') unawaited(_stopService());
                if (v == 'retry') unawaited(_boot());
              },
              itemBuilder: (context) => [
                if (_phase == _Phase.ready)
                  const PopupMenuItem(value: 'stop', child: Text('停止 Bot 服务')),
                const PopupMenuItem(value: 'retry', child: Text('重新启动')),
              ],
            ),
          ],
        ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.ready:
        final web = _web!;
        return WebViewWidget(controller: web);
      case _Phase.starting:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                const Text('正在启动 Bot 团队服务…',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text(
                  '首次启动要把 Bot 的运行环境拉起来，大约 10~25 秒。\n'
                  '（服务跑在本机，不用联网）',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: DshColors.textDim),
                ),
                if (_lastLine.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    _lastLine,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: DshColors.textDim, fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
        );
      case _Phase.failed:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 44, color: DshColors.err),
                const SizedBox(height: 14),
                const Text('Bot 服务没能起来',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                // 如实说原因，不吞错。
                Text(
                  _error ?? '（没有更多信息）',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: DshColors.textDim),
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: () => unawaited(_boot()), child: const Text('重试')),
              ],
            ),
          ),
        );
    }
  }
}
