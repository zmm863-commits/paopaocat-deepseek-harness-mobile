import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/agnes_web.dart';
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
    // 页面走了要不要停后端，取决于「电脑访问」是否还在用它
    // （开着的话电脑那边连着，停掉就是 502）。
    unawaited(AgnesWeb.releaseIfUnused());
    super.dispose();
  }

  Future<void> _boot() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      // ⚠️ 2026-10-27：设计站不是纯静态站 —— 它的 15 个引擎都走
      //    `/agnes-studio/api/*`。原来这里只起一个静态托管（StudioServer），
      //    结果是「界面能开、点生成就 404」。现在改起完整后端（AgnesWeb），
      //    和「电脑访问」共用同一个实例：资料存手机、模型用手机配置。
      final s = await AgnesWeb.ensureStarted(widget.runtime);
      if (!mounted) {
        await AgnesWeb.releaseIfUnused();
        return;
      }
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
        await AgnesWeb.releaseIfUnused();
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
