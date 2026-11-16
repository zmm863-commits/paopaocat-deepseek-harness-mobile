import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/studio_server.dart';
import '../theme/dsh_tokens.dart';

/// 「APP界面设计台」—— 泡泡猫设计工作站（基于 m3e-canvas，MIT）的手机版。
///
/// ## 它是什么
///
/// 一个**随包**的网页应用：在手机上画 Material 3 界面草图，再导出成给 AI 描述
/// 界面用的提示词。技术上是 **Next.js 静态导出的产物**（约 3 MB，随 APK 分发），
/// 由 [StudioServer] 在 **App 进程内**用 loopback HTTP 发出来，这个页面用 WebView
/// 打开它。**不联网、不需要容器、不依赖任何外部服务。**
///
/// ⚠️ 为什么是**全屏页**而不是塞进创作台的某个标签里：它自带画布 + 工具栏 +
/// 底部弹层，需要整屏和它自己的手势；塞进带底部导航的页面里，竖屏下根本不够用
/// （这是真机尺寸实测过的结论：390×844 下工具栏与弹层已经吃满）。
class StudioPage extends StatefulWidget {
  const StudioPage({super.key, required this.runtime});

  final DshRuntime runtime;

  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  StudioServer? _server;
  WebViewController? _web;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    // 页面走了就把 loopback 静态服务关掉（否则每进出一次就漏一个端口）。
    final s = _server;
    _server = null;
    if (s != null) unawaited(s.stop());
    super.dispose();
  }

  Future<void> _boot() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      // 2026-11-14（用户报「打开应该是手机界面设计工具啊」后改回）：
      //
      // 这里在 2026-10-27 的 8faaba4 里被换成了 `AgnesWeb`（**电脑端**那个
      // 网页插件「泡泡猫设计站」），理由是"静态托管点生成会 404"。
      // 但那两件事被混在一起了，它们是**不同的东西**：
      //
      //   · 「泡泡猫设计站 / 影视工具」= DSH 的**网页插件**，本来就该在电脑上跑
      //     （它自己的界面里就写着"完整功能请在电脑浏览器中使用"）；
      //   · 「APP界面设计台」= m3e-canvas（MIT）的**手机适配版**：左侧选部件、
      //     拖到画布上拼界面 → 生成给 AI 编程工具的提示词。**纯前端**，
      //     不需要任何后端引擎，静态托管就够。
      //
      // 把电脑端的东西塞进这个入口，结果是手机用户打开看到的是一套跑不完整的
      // 桌面界面。所以这里换回 `StudioServer` + `assets/studio/`。
      final s = await StudioServer.start(
        filesDir: widget.runtime.filesDir,
      );
      if (!mounted) {
        await s.stop();
        return;
      }
      _server = s;
      final c = WebViewController();
      // 它靠 JS 渲染画布，禁 JS 就是白屏。
      await c.setJavaScriptMode(JavaScriptMode.unrestricted);
      await c.setBackgroundColor(DshColors.bg);
      await c.setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (WebResourceError e) {
            // 只报**主文档**失败：同目录资源拉不到也走这个回调，那不是"打不开"。
            if (e.isForMainFrame != true) return;
            debugPrint('[dsh-studio] 主文档加载失败：${e.errorCode} ${e.description}');
            if (!mounted) return;
            setState(() {
              _error = context.tr('页面加载失败：{0}（错误码 {1}）',
                  [e.description, e.errorCode]);
            });
          },
        ),
      );
      await c.loadRequest(Uri.parse('http://127.0.0.1:${s.port}/'));
      if (!mounted) {
        await s.stop();
        return;
      }
      setState(() {
        _web = c;
        _loading = false;
      });
    } catch (e) {
      // 起不来就**如实说原因**（最常见的是"包里没有产物"，那要重新构建 App）。
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(
        // 用户 2026-10-29：左上角的返回箭头取消 —— 这个页面从「影视」里点进来，
        // 出去走底部导航就行，头顶再挂一个返回键既重复又占地方。
        automaticallyImplyLeading: false,
        title: Text(context.tr('APP界面设计台')),
        actions: <Widget>[
          if (_web != null)
            IconButton(
              tooltip: context.tr('重新加载'),
              onPressed: () => unawaited(_web!.reload()),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              context.tr('正在准备 APP界面设计台（首次会解包一次，之后直接打开）…'),
              style: TextStyle(color: DshColors.textDim, fontSize: 12.5),
            ),
          ],
        ),
      );
    }
    final err = _error;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(DshMetrics.pagePad),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, color: DshColors.err, size: 30),
              const SizedBox(height: 10),
              Text(
                context.tr('APP界面设计台打不开：{0}', [err]),
                textAlign: TextAlign.center,
                style: TextStyle(color: DshColors.text, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 6),
              Text(
                context.tr('如果提示"安装包里没有 assets/studio"，说明这一版没把APP界面设计台打进去，需要重新构建 App。'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () => unawaited(_boot()),
                child: Text(context.tr('重试')),
              ),
            ],
          ),
        ),
      );
    }
    return WebViewWidget(controller: _web!);
  }
}
