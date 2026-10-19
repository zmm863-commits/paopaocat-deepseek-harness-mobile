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

  /// 手机适配 CSS：把「桌面尺寸的浮层」压回手机视口内。
  ///
  /// 为什么需要（2026-10-19 用户报「点 + 只看到几个图标、看不到建群」）：
  /// Bot 页跑的是 ds-bot 的**桌面网页 UI**。最先撞上的就是它的右侧浮层 `.bt-pane`：
  /// 宽度是按「对话列右边 → 屏幕右边」算的（`usePaneLeft()` 取
  /// `[class*="_footArea"]` 父元素的 `getBoundingClientRect().right`，写进 inline
  /// `left`，而 CSS 里还有 `right:0`）。桌面上那个差有几百像素，手机上几乎为 0
  /// → 面板被挤到一百来像素，`.bt-option-label` 的文字被 `text-overflow:ellipsis`
  /// 吃干净，**只剩一排图标** —— 这正是用户看到的现象。
  ///
  /// 所以这一版不再用「宽泛选择器兜底」，而是按**真实类名**精确改宽度（仍然不碰
  /// ds-bot 源码，因为它随 runtime 分发、由 App 侧注入最省事）：
  ///   * `.bt-pane` → 右侧固定宽（手机上=满宽），把被算没的宽度还回来；
  ///   * `.bt-pane .bt-drop` → 跟着面板宽度走（它自己是 `width:min(550px,
  ///     calc(100% - 64px))`，面板窄时会被算成几十像素）；
  ///   * 选项文字不再省略号截断（宽度够了就让它正常排版）；
  ///   * 其余弹层/菜单统一加上限高度，超出可滚（不改上限，避免把原本 400px 的
  ///     菜单「放宽」到 85vh 反而顶出屏幕）。
  ///
  /// ⚠️ 这段必须是**合法 JS**。108 版在 `].join('` 后面写入了一个真换行（本意是
  /// `'\n'`）→ `node --check` 直接报 SyntaxError，整段没执行、一个 `<style>` 都没插
  /// 进去（表面看就是"改了没用"）。现在改用反引号模板字符串承载多行 CSS，Dart 原始
  /// 字符串里不需要任何 JS 转义，也就不会再犯。**改动后用 `node --check` 验一遍。**
  static const String _mobileFitCss = r"""
  (function () {
    if (document.getElementById('dsh-mobile-fit')) return;
    var st = document.createElement('style');
    st.id = 'dsh-mobile-fit';
    st.textContent = `
.bt-pane { left: auto !important; right: 0 !important; width: min(100vw, 440px) !important; max-width: 100vw !important; }
.bt-pane .bt-drop { left: 8px !important; width: calc(100% - 16px) !important; max-height: min(420px, 55vh) !important; }
[role="menu"], [role="listbox"], .bt-menu, .bt-drop { max-height: min(420px, 60vh) !important; overflow-y: auto !important; }
[role="dialog"] { max-width: 100vw !important; }
body { overscroll-behavior-y: contain; }
`;
    document.head.appendChild(st);
  })();
  """;

  /// 当前 WebView 里加载的地址（用于和服务最新地址比对）。
  String? _loadedUrl;

  /// 服务地址变了（通常是重启换了端口）→ 用新地址重新加载。
  void _onServerChanged() {
    final s = BotServer.live.value;
    if (!mounted || s == null) return;
    if (s.url == _loadedUrl) return;
    debugPrint('[dsh-bot] 服务地址变化 → 重新加载：${s.url}');
    _loadedUrl = s.url;
    _web?.loadRequest(Uri.parse(s.url));
  }
  WebViewController? _web;
  String? _error;
  String _lastLine = '';

  /// 一次性提示。WebView 回调里出错时**必须让用户看得见**：
  /// 否则表现就是"点了没反应"，连是不是我们的问题都分不出来。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
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
    super.dispose();
  }

  Future<void> _boot() async {
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

      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(DshColors.bg);

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
          // ── ③ 手机适配 CSS（2026-10-19 用户报「点 + 只看到几个图标、看不到建群」）──
          // 根因：那是**桌面尺寸**的弹窗/菜单，超出手机视口就被裁掉了。这里在页面
          // 加载完成后注入一段兜底样式：让弹层最高不超过 85vh、内部可滚动。
          onPageFinished: (_) async {
            try {
              await controller.runJavaScript(_mobileFitCss);
            } catch (e) {
              debugPrint('[dsh-bot] 注入适配 CSS 失败：$e');
            }
          },
          onWebResourceError: (WebResourceError e) {
            // 只报**主文档**失败：同目录资源拉不到也走这个回调，那不是"打不开"。
            if (e.isForMainFrame != true) return;
            debugPrint('[dsh-bot] 主文档加载失败：${e.errorCode} ${e.description}');
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
    return PopScope(
      // 手机上 WebView 里可能已经翻了好几层（Bot 列表 → 某个 Bot 的聊天 →
      // 群设置…）。返回键先让网页自己退，退到底了才离开这一页。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final web = _web;
        if (web != null && await web.canGoBack()) {
          await web.goBack();
          return;
        }
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
