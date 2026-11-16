import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/studio_server.dart';
import '../theme/dsh_tokens.dart';

/// 白板页：思维导图 / 流程图 / 自由画（一体化无限画布）。
///
/// 2026-11-14：用户批准「三个梯队都做」的第一梯队。
///
/// ## 为什么不自己画
///
/// 自研无限画布要处理：手势与缩放的冲突、贝塞尔连线、节点吸附、文本编辑、
/// 导出 PNG/JSON —— 每一项都是硬骨头。而社区已有成熟的 Web 白板实现
/// （MIT 许可，可再分发），把它当作**本地静态产物**打进包，用 WebView 承载，
/// 是这里性价比最高的路线。这也是 App 已经用过两次的模式
/// （设计站 `assets/studio/`、影视工具面板）。
///
/// ## 为什么走 loopback HTTP 而不是 `file://`
///
/// 白板是 **SPA**：`index.html` 里引用 `/assets/*.js`（绝对路径）、且模块脚本带
/// `crossorigin`。`file://` 下绝对路径会解析到文件系统根目录（必然 404），
/// `crossorigin` 模块在 `file://` 下也被浏览器安全策略拦。起一个 loopback
/// 静态服务（复用 [StudioServer] 的解包 + 托管逻辑）就都没这问题。
///
/// ## 离线
///
/// 产物随包分发，**不发任何网络请求**。构建时已把原作者页面里的统计脚本
/// （umami）删掉了 —— 一个离线应用没有理由往外上报。
class DrawnixPage extends StatefulWidget {
  const DrawnixPage({super.key, required this.runtime});

  final DshRuntime runtime;

  @override
  State<DrawnixPage> createState() => _DrawnixPageState();
}

class _DrawnixPageState extends State<DrawnixPage> {
  WebViewController? _web;
  StudioServer? _server;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    // 页面走了就把 loopback 服务关掉（否则每次进出白板都漏一个端口）。
    final s = _server;
    _server = null;
    if (s != null) unawaited(s.stop());
    super.dispose();
  }

  Future<void> _boot() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final s = await StudioServer.start(
        filesDir: widget.runtime.filesDir,
        assetPrefix: 'assets/drawnix-site/',
        subdir: 'drawnix-site',
        markerName: '.drawnix-unpacked',
        logTag: 'drawnix',
      );
      _server = s;
      if (!mounted) {
        await s.stop();
        return;
      }
      final c = WebViewController()
        // 它是 JS 渲染的画布，禁 JS 就是白屏。
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        // 白板要写 localStorage 存草稿；不主动开 DOM 存储的话，刷新就没了。
        ..setBackgroundColor(DshColors.bg)
        ..setNavigationDelegate(NavigationDelegate(
          onWebResourceError: (WebResourceError e) {
            // 只报**主文档**失败：同目录资源拉不到也走这个回调，那不是"打不开"。
            if (e.isForMainFrame != true) return;
            debugPrint('[dsh-drawnix] 主文档加载失败：${e.errorCode} ${e.description}');
            if (!mounted) return;
            setState(() {
              _error = context.tr('页面加载失败：{0}（错误码 {1}）',
                  [e.description, e.errorCode]);
            });
          },
        ));
      await c.loadRequest(Uri.parse(s.url));
      if (!mounted) return;
      setState(() {
        _web = c;
        _loading = false;
      });
    } catch (e) {
      // 起不来就如实说原因（最常见是"包里没有产物"，那要重新构建 App）。
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(
        backgroundColor: DshColors.bg,
        title: Text(context.tr('白板')),
        actions: [
          if (web != null)
            IconButton(
              tooltip: context.tr('刷新'),
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: () => unawaited(_boot()),
            ),
        ],
      ),
      body: Stack(
        children: [
          if (web != null) WebViewWidget(controller: web),
          if (_loading)
            const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline_rounded,
                        size: 32, color: DshColors.err),
                    const SizedBox(height: 12),
                    Text(
                      context.tr('白板打不开：{0}', [_error!]),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: DshColors.textDim, height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => unawaited(_boot()),
                      child: Text(context.tr('重试')),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
