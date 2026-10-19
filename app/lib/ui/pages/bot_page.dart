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

  /// 手机适配 CSS：把「桌面尺寸的弹层」压进视口内并可滚动。
  ///
  /// 为什么需要（2026-10-19 用户报「点 + 只能看到几个图标，看不到建群」）：
  /// Bot 页跑的是 ds-bot 的**桌面网页 UI**，它的弹窗/菜单按桌面宽度排版，
  /// 在手机上超出视口就被裁掉了。这里用**宽泛选择器**兜底（不改 ds-bot 源码）：
  /// 常见弹层容器的最大高度限制到 85vh、溢出可滚动；并保证底部操作区可见。
  static const String _mobileFitCss = r"""
  (function () {
    if (document.getElementById('dsh-mobile-fit')) return;
    var st = document.createElement('style');
    st.id = 'dsh-mobile-fit';
    st.textContent = [
      '[role="dialog"], [role="menu"], [role="listbox"], [role="alertdialog"],',
      '[class*="dialog"], [class*="Dialog"], [class*="modal"], [class*="Modal"],',
      '[class*="popover"], [class*="Popover"], [class*="dropdown"], [class*="Dropdown"],',
      '[class*="menu"], [class*="Menu"], [class*="sheet"], [class*="Sheet"] {',
      '  max-height: 85vh !important;',
      '  max-width: 96vw !important;',
      '  overflow: auto !important;',
      '  -webkit-overflow-scrolling: touch !important;',
      '}',
      'body { overscroll-behavior-y: contain; }'
    ].join('
');
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
      // 网页里 `<input type=file>` 只会向**宿主**发起请求（onShowFileChooser）；
      // 宿主不接管就永远没反应。这里用 file_picker 弹出系统选择器，把用户选的
      // 真实路径回传，网页那边就能正常上传。
      if (controller.platform is AndroidWebViewController) {
        await (controller.platform as AndroidWebViewController)
            .setOnShowFileSelector((FileSelectorParams params) async {
          try {
            final r = await FilePicker.platform.pickFiles(
              allowMultiple: params.mode == FileSelectorMode.openMultiple,
            );
            if (r == null) return const <String>[];
            return <String>[
              for (final f in r.files)
                if (f.path != null && f.path!.isNotEmpty) f.path!,
            ];
          } catch (e) {
            debugPrint('[dsh-bot] 文件选择失败：$e');
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
