import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../local/apk_downloader.dart' show ApkDownloadProgress, ApkDownloadCancelToken;
import '../local/dsh_runtime.dart';
import '../local/runtime_bootstrap.dart';
// 只借 `formatBytes`（大小显示口径全项目统一，别在这页自己写一个）。
import '../local/update_checker.dart' show formatBytes;

import '../i18n/dsh_i18n.dart';
import 'theme/dsh_tokens.dart';

/// 首次使用的一步引导：**下载运行环境 → 解压**。
///
/// 存在的意义：解压前所有执行路径都不可用。与其让用户面对一堆技术按钮
/// （然后点下去得到一句 `Cannot find module`），不如只给一个按钮。
///
/// ⚠️ 0.75 起这一步**多了一个下载**：`dsh-runtime.zip` 不再随安装包
/// （APK 因此小了约 30 MB），改由这里现下（约 32 MB，可续传、有哈希校验）。
/// **老用户看不到这一页** —— 他们 `files/` 里早就有那个 zip 了（历次都是随包拷过去的），
/// 只有全新安装 / 清了应用数据才会走到这里。
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.runtime, required this.onReady});

  final DshRuntime runtime;

  /// 准备好了之后的回调（由外层切到对话界面）。
  final VoidCallback onReady;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  bool _busy = false;

  /// 这台机器上**是不是已经用过**（有会话 / 模型配置 / Bot / 工作区任一痕迹）。
  ///
  /// 为什么需要（2026-10-19 用户报「为什么更新安装，下载后变成重新安装了」）：
  /// 运行环境有内容版本（`.dsh-runtime-<版本>` 标记），**一升版本 `isRuntimeReady()`
  /// 就是 false** —— 于是**升级的用户也会走到这一页**。而这一页原来标题写着「首次使用」，
  /// 双击用户就以为被重装了。真相：用户数据一个字没动（会话/模型/Bot 都在 `files/dshhome`，
  /// 解包只写 `files/dsh`）。所以这里判一下，老用户改说「正在更新运行环境」并讲清不会清数据。
  bool _existing = false;
  bool _downloading = false;
  bool _unpacking = false;
  ApkDownloadProgress? _dl;
  ApkDownloadCancelToken? _cancel;
  int _done = 0;
  String _current = '';
  String? _error;

  /// 安装包里**自带**运行环境吗（完整包有、精简包没有）。
  ///
  /// 带就**不用联网**：`ensureRuntimeZip()` 会先把它取出来（2026-10-15 用户真机反馈：
  /// 完整包也被要求下 32 MB，而且更新源一超时就卡在这一页）。
  bool _bundled = false;

  /// 有会话 / 有 storages / 有 Bot 状态 / 有模型配置 / 有工作区 —— 任一命中就算用过。
  bool _looksUsed() {
    bool has(Directory d, String rel) =>
        FileSystemEntity.typeSync('${d.path}/$rel') != FileSystemEntityType.notFound;
    try {
      final home = Directory(widget.runtime.nodeHome);
      final files = Directory(widget.runtime.filesDir);
      return has(home, 'sessions') ||
          has(home, 'storages') ||
          has(home, 'bot/state.json') ||
          has(files, 'models.json') ||
          has(files, 'workspace');
    } catch (_) {
      return false;
    }
  }

  /// 清掉旧版本残留的 `.dsh-runtime-<旧版本>` 标记（多份残留只会让以后排查更糊涂）。
  void _dropStaleMarkers() {
    try {
      final dir = Directory(widget.runtime.filesDir);
      if (!dir.existsSync()) return;
      final keep = '.dsh-runtime-${widget.runtime.runtimeVersion}';
      for (final e in dir.listSync()) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.dsh-runtime-') && name != keep) {
          try { e.deleteSync(); } catch (_) {}
        }
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    // 先问一句"安装包里自带运行环境吗"：自带就把文案与进度都说成"取出"而不是"下载"。
    unawaited(DshHost.hasRuntimeAsset().then((v) {
      if (!mounted) return;
      setState(() => _bundled = v);
    }).catchError((Object _) => debugPrint('[dsh-setup] 查随包运行环境失败（按没有处理）')));
    // 判「老用户还是真首次」：任一路径有东西，就当老用户（宁可按老用户说，也不吓人）。
    _existing = _looksUsed();
    debugPrint('[dsh-setup] 走到准备页：${_existing ? '老用户（跨运行环境版本，数据都在）' : '首次安装'}');
    // 解压进度由原生回调（下载进度则是下面 ensureRuntimeZip 的 onProgress）。
    DshHost.bindProgress((done, current) {
      if (!mounted) return;
      setState(() {
        _done = done;
        _current = current;
      });
    });
  }

  Future<void> _prepare() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = 0;
      _dl = null;
      _unpacking = false;
    });

    // ① 先确保运行时包在本地（本地那份对就跳过，不对/没有才下载）。
    final token = ApkDownloadCancelToken();
    setState(() {
      _downloading = true;
      _cancel = token;
    });
    final r = await ensureRuntimeZip(
      filesDir: widget.runtime.filesDir,
      onProgress: (p) {
        if (!mounted) return;
        setState(() => _dl = p);
      },
      cancel: token,
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _cancel = null;
    });
    if (!r.ok) {
      final msg = r.errorZh;
      setState(() {
        _busy = false;
        // 取消不是错误（用户自己按的），别把它渲染成红色失败。
        _error = (msg == null || msg == '已取消')
            ? context.tr('已取消。你可以随时再点一次「开始准备」。')
            : msg;
      });
      return;
    }

    // ② 再解压（原生侧把 files/runtime.zip 解开到 files/dsh）。
    setState(() => _unpacking = true);
    try {
      final ok = await DshHost.unpackRuntime();
      if (!mounted) return;
      if (!ok) throw StateError(context.tr('宿主返回失败'));
      if (!widget.runtime.isUnpacked) {
        throw StateError(context.tr('解压完成但仍找不到运行时文件'));
      }
      _dropStaleMarkers();
      widget.onReady();
    } catch (e) {
      debugPrint('[dsh-setup] unpack failed: $e');
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _unpacking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dl = _dl;
    final frac = dl?.fraction;

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('泡泡猫的DSH'))),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const SizedBox(height: 20),
          Icon(Icons.download_for_offline_outlined,
              size: 46, color: scheme.primary),
          const SizedBox(height: 18),
          Text(
              _existing
                  ? context.tr('正在更新运行环境')
                  : context.tr('首次使用：准备运行环境'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          if (_existing) ...[
            Text(context.tr('你的会话、模型设置和 Bot 都还在本机 —— 这一步只是把新版的运行环境重新铺一遍，不会清数据。'),
                style: TextStyle(color: scheme.outline, height: 1.6, fontSize: 13)),
            const SizedBox(height: 8),
            Text(context.tr('新版换了运行环境的内容，所以要重新准备一次（约 32 MB，支持断点续传；解开约 26000 个文件，几十秒到一分多钟）。'),
                style: TextStyle(color: scheme.outline, height: 1.6, fontSize: 13)),
          ] else
            Text(
              _bundled
                  ? context.tr('运行环境**随这个安装包自带**（约 32 MB）—— **不需要联网**，'
                      '直接在本机解开（约 26000 个文件）。这一步只做一次，以后更新不用再下。')
                  : context.tr('运行环境（约 32 MB）不在这个安装包里 —— 那样每次更新都要重下它。'
                      '改成**第一次打开时下这一次**，支持断点续传；下完在本机解开（约 26000 个文件）。'
                      '这一步只做一次，以后更新不用再下。'),
              style: TextStyle(color: scheme.outline, height: 1.6, fontSize: 13),
            ),
          const SizedBox(height: 10),
          Text(
            context.tr('本机现有的运行环境包：{0}', [localZipLabel(widget.runtime.filesDir)]),
            style: TextStyle(color: scheme.outline, fontSize: 11.5),
          ),
          const SizedBox(height: 24),

          // ── 下载中：进度条 + 取消
          // ⚠️ 进度条**总是给 value**（拿不到进度就给 0）：不确定态是无限动画，
          //    点击遍历测试会一直等不到静止（本项目已经踩过一次）。
          if (_downloading) ...[
            LinearProgressIndicator(value: frac ?? 0, minHeight: 4),
            const SizedBox(height: 10),
            Text(
              dl == null
                  ? (_bundled
                      ? context.tr('正在从安装包里取出运行环境…')
                      : context.tr('正在连接…'))
                  : (frac == null
                      ? context.tr('已下载 {0}', [formatBytes(dl.received)])
                      : context.tr('{0} / {1} · {2}/秒', [
                          formatBytes(dl.received),
                          formatBytes(dl.total),
                          formatBytes(dl.bytesPerSecond.round()),
                        ])),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            OutlinedButton(
              onPressed: () => _cancel?.cancel(),
              child: Text(context.tr('取消下载')),
            ),
            const SizedBox(height: 20),
          ],

          // ── 解压中：已解出多少个文件
          if (_unpacking) ...[
            const LinearProgressIndicator(minHeight: 4),
            const SizedBox(height: 10),
            Text(context.tr('已解压 {0} 个文件', [_done]),
                style: const TextStyle(fontSize: 12)),
            Text(
              _current,
              style: TextStyle(
                  fontSize: 11, color: scheme.outline, fontFamily: 'monospace'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
          ],

          FilledButton.icon(
            onPressed: _busy ? null : _prepare,
            icon: const Icon(Icons.play_arrow),
            label: Text(_busy
                ? (_downloading
                    ? context.tr('正在下载运行环境…')
                    : context.tr('正在解压…'))
                : (_existing ? context.tr('开始更新') : context.tr('开始准备'))),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          ),

          if (_error != null) ...[
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
              ),
              child: SelectableText(
                context.tr('准备失败：{0}', [_error]),
                style: TextStyle(
                    color: scheme.onErrorContainer, fontSize: 12, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
