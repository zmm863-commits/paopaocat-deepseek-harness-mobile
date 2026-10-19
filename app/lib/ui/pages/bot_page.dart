import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../local/bot_server.dart';
import '../../local/dsh_runtime.dart';
import '../../local/diagnostics_log.dart';
import '../theme/dsh_tokens.dart';

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
  /// 2. **藏掉并拦住 DSH(Harness) 的设置入口**（用户要求：用户改到 DSH 设置会把 Bot 的
  ///    模型/插件配置搞乱）。ds-bot 里通往它的一共三处：设置抽屉的 `Harness 设置`、
  ///    模型菜单的 `模型和服务商…`、定时任务页的 `打开 Harness 设置`。
  ///    CSS 藏 + **捕获阶段吃掉点击**（双保险）。
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
  .bt-settings-nav { width: 100% !important; flex: none !important; flex-direction: row !important; overflow-x: auto !important; overflow-y: hidden !important; border-right: 0 !important; border-bottom: .5px solid var(--bt-line) !important; padding: 8px !important; gap: 6px !important; }
  .bt-settings-item { flex: none !important; white-space: nowrap !important; }
  .bt-settings-main { width: 100% !important; flex: 1 1 auto !important; min-height: 0 !important; height: auto !important; }
  .bt-settings-head { padding: 10px 56px 4px 16px !important; }
}
.bt-settings-item.bt-settings-shell { display: none !important; }
body { overscroll-behavior-y: contain; }
`;
      document.head.appendChild(st);
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

    // ── ④ 藏掉并拦住 DSH(Harness) 的设置入口 ──────────────────────────────
    var HARNESS = ['打开 Harness 设置', 'Open Harness settings', 'Harness 设置', 'Harness settings',
                   '模型和服务商', 'Models and providers'];
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
        post('已隐藏 DSH(Harness) 设置入口：' + (el.textContent || '').trim().slice(0, 24));
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
    var OFFICE_HINT = 'Bot 页面里看不了这种格式 —— 到 App 底部导航的「资料库」里打开这个文件。';
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

    // ── ⑥ 扫一遍 + 盯住 DOM（这些元素都是 SPA 按需渲染出来的）─────────────
    function sweep() { applyTheme(); hideHarness(); fixOfficeHint(); fixAutoHint(); }
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
      _webPatchTemplate.replaceFirst('__DSH_APP_DARK__', dark ? 'true' : 'false');

  /// **只**做一件事：把 App 的深浅色同步给网页（可反复调用；App 切皮肤时用）。
  ///
  /// 为什么不重跑整段：那段有 `window.__dshBotTrace` 守卫（监听器只装一次），
  /// 而这个动作要能随时执行 —— 深浅色是新加的、会变的东西。
  static String _themeJs({required bool dark}) => '''
  (function () {
    var dark = ${dark ? 'true' : 'false'};
    window.__dshAppDark = dark;
    try {
      document.documentElement.dataset.dsThemeSource = dark ? 'dark' : 'light';
      if (document.body) document.body.toggleAttribute('data-ds-dark-theme', dark);
    } catch (e) {}
  })();
  ''';

  /// 当前 WebView 里加载的地址（用于和服务最新地址比对）。
  String? _loadedUrl;

  /// 服务地址变了（通常是重启换了端口）→ 用新地址重新加载。
  void _onServerChanged() {
    final s = BotServer.live.value;
    if (!mounted || s == null) return;
    if (s.url == _loadedUrl) return;
    debugPrint('[dsh-bot] 服务地址变化 → 重新加载：${s.url}');
    // 只记"变了"，不记地址（地址里带 token）。
    DiagnosticsLog.add('dsh-bot', 'Bot 服务地址变化（服务重启/换端口）→ WebView 重新加载');
    _loadedUrl = s.url;
    _web?.loadRequest(Uri.parse(s.url));
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
    try {
      await web.runJavaScript(_themeJs(dark: dark));
      DiagnosticsLog.add('dsh-bot', 'App 主题变化 → 已把网页改成${dark ? '深色' : '浅色'}');
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '主题同步到网页失败（网页仍用旧的主题）：$e');
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
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
            return paths;
          } catch (e) {
            DiagnosticsLog.add('dsh-bot', '文件选择失败：$e');
            _toast('选文件失败：$e');
            return const <String>[];
          }
        });
      }
      await controller.setNavigationDelegate(
        NavigationDelegate(
          // ── ② 导航拦截（2026-10-19 用户报「Bot 里的文件无法直接预览」）──────
          // 本机 Bot 服务的 URL 一律放行；其余（网页里点了文件、点了外链）拦下来，
          // 不让 WebView 变成一个"打不开的下载页"。
          // 文件预览的诉求由**资料库**兜住（它本来就带预览，且 107 起已把 Bot 工作区并进来）。
          onNavigationRequest: (NavigationRequest req) {
            final base = server.url.split('?').first;
            if (req.url.startsWith(base) || req.url.startsWith('about:') ||
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
          },
          onWebResourceError: (WebResourceError e) {
            // 只报**主文档**失败：同目录资源拉不到也走这个回调，那不是"打不开"。
            if (e.isForMainFrame != true) return;
            debugPrint('[dsh-bot] 主文档加载失败：${e.errorCode} ${e.description}');
            DiagnosticsLog.add('dsh-bot',
                '主文档加载失败：错误码 ${e.errorCode} ${e.description}');
            if (!mounted) return;
            setState(() {
              _phase = _Phase.failed;
              _error = '页面加载失败：${e.description}（错误码 ${e.errorCode}）';
            });
          },
        ),
      );
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
    return PopScope(
      // 手机上 WebView 里可能已经翻了好几层（Bot 列表 → 某个 Bot 的聊天 →
      // 群设置…）。返回键先让网页自己退，退到底了才离开这一页。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final web = _web;
        if (web != null && await web.canGoBack()) {
          // 留痕：用户点返回键时是"网页退一层"还是"离开这一页"，看日志一眼就懂。
          DiagnosticsLog.add('dsh-bot', '按返回键 → 网页后退一层');
          await web.goBack();
          return;
        }
        DiagnosticsLog.add('dsh-bot', '按返回键 → 离开 Bot 页（已到网页最外层）');
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
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
      ),
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
