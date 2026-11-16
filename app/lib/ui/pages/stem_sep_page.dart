import 'dart:async';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/stem_separator.dart';
import '../theme/dsh_tokens.dart';

/// 人声 / 伴奏分离页（本地跑，不联网）。
///
/// 2026-11-14：三梯队之二。用户选的选型标准是「体积可控」——
/// 用 52.8MB 的 MDX-Net（KARA_2）而不是 316MB 的 htdemucs。
///
/// ## 交互上的两个决定
///
/// 1. **不卡界面**：分离是几十秒到几分钟的同步 FFI 调用，整段推进独立 isolate，
///    主 isolate 只刷进度条。所以用户可以在等的时候退出去干别的再回来。
/// 2. **进度说实话**：一开始就说「本地运算，可能要几分钟」，不假装很快。
///    跑完把实际耗时和「音频实时倍速」一起显示出来 —— 这个数字比进度条诚实。
class StemSepPage extends StatefulWidget {
  const StemSepPage({super.key, required this.runtime});

  final DshRuntime runtime;

  @override
  State<StemSepPage> createState() => _StemSepPageState();
}

class _StemSepPageState extends State<StemSepPage> {
  String? _input;
  bool _running = false;
  double _progress = 0;
  String _stage = '';
  String? _error;
  StemResult? _result;

  late final StemSeparator _sep = StemSeparator(widget.runtime);

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus'],
    );
    final p = r?.files.single.path;
    if (p == null) return;
    setState(() {
      _input = p;
      _result = null;
      _error = null;
      _progress = 0;
      _stage = '';
    });
  }

  Future<void> _run() async {
    final input = _input;
    if (input == null || _running) return;
    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _progress = 0;
      _stage = context.tr('准备模型');
    });

    final sw = Stopwatch()..start();
    try {
      // 模型解包在主 isolate 做（读 assets 是 IO，很快；解一次约 50MB）。
      final modelPath = await _sep.ensureModel();
      if (!mounted) return;
      setState(() => _progress = 0.05);

      final workDir = '${widget.runtime.filesDir}/stems';
      final task = StemTask(
        input: input,
        modelPath: modelPath,
        ffmpeg: widget.runtime.ffmpegBinary,
        workDir: workDir,
        ldLibPath: widget.runtime.nativeLibDir,
        // 推理引擎的绝对路径（见 StemTask.ortDylib 的说明：手机上必须是绝对路径）
        ortDylib: widget.runtime.nativeLibDir.isEmpty
            ? 'libonnxruntime.so'
            : '${widget.runtime.nativeLibDir}/libonnxruntime.so',
      );

      // 进度用 ReceivePort 回传：['分数', '阶段'] 或 ['ok', 人声, 伴奏, 秒] 或 ['err', 原因]
      final rp = ReceivePort();
      final done = Completer<StemResult>();
      rp.listen((msg) {
        if (msg is! List) return;
        final head = msg.first;
        if (head == 'ok') {
          final dur = (msg[3] as num).toDouble();
          sw.stop();
          if (!done.isCompleted) {
            done.complete(StemResult(
              vocalsPath: msg[1] as String,
              instrumentalPath: msg[2] as String,
              elapsed: sw.elapsed,
              durationSeconds: dur,
            ));
          }
          rp.close();
        } else if (head == 'err') {
          if (!done.isCompleted) {
            done.completeError(StemException(msg[1] as String));
          }
          rp.close();
        } else if (head is num) {
          if (mounted) {
            setState(() {
              _progress = head.toDouble().clamp(0.0, 1.0);
              _stage = '${msg[1]}';
            });
          }
        }
      });

      await Isolate.spawn(
        (List<Object> args) {
          stemWorker(args[0] as StemTask, args[1] as SendPort);
        },
        <Object>[task, rp.sendPort],
        debugName: 'stem-separate',
      );

      final result = await done.future;
      if (!mounted) return;
      setState(() {
        _running = false;
        _progress = 1;
        _result = result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$e';
        _stage = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final input = _input;
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(
        backgroundColor: DshColors.bg,
        title: Text(context.tr('人声分离')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // ── 说明 ────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(13),
            decoration: DshColors.panel(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(context.tr('把一首歌拆成「人声」和「伴奏」两轨'),
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: DshColors.text)),
                const SizedBox(height: 6),
                Text(
                  context.tr(
                      '全部在手机上算，不上传、不联网。一首 3 分钟的歌大约要几分钟，慢是正常的。'),
                  style: TextStyle(
                      fontSize: 12, height: 1.5, color: DshColors.textDim),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ── 选文件 ──────────────────────────────────────────────
          OutlinedButton.icon(
            onPressed: _running ? null : _pick,
            icon: const Icon(Icons.audio_file_outlined, size: 18),
            label: Text(input == null
                ? context.tr('选择音频文件')
                : input.split('/').last),
          ),

          // ── 开始 ────────────────────────────────────────────────
          if (input != null) ...<Widget>[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: const Icon(Icons.call_split_rounded, size: 18),
              label: Text(_running
                  ? context.tr('分离中…')
                  : context.tr('开始分离')),
            ),
          ],

          // ── 进度 ────────────────────────────────────────────────
          if (_running) ...<Widget>[
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
              child: LinearProgressIndicator(
                value: _progress <= 0 || _progress >= 1 ? null : _progress,
                minHeight: 6,
                backgroundColor: DshColors.fieldFill,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _stage.isEmpty ? context.tr('运算中…') : _stage,
              style: TextStyle(fontSize: 12, color: DshColors.textDim),
            ),
            const SizedBox(height: 6),
            Text(
              context.tr('可以退出去做别的，回来它还在这儿跑。'),
              style: TextStyle(
                  fontSize: 11, height: 1.5, color: DshColors.textFaint),
            ),
          ],

          // ── 错误 ────────────────────────────────────────────────
          if (_error != null) ...<Widget>[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: DshColors.err.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
                border: Border.all(color: DshColors.err.withValues(alpha: 0.3)),
              ),
              child: Text(_error!,
                  style: TextStyle(
                      fontSize: 12, height: 1.5, color: DshColors.err)),
            ),
          ],

          // ── 结果 ────────────────────────────────────────────────
          if (_result != null) ...<Widget>[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: DshColors.panel(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(context.tr('分离完成'),
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: DshColors.text)),
                  const SizedBox(height: 8),
                  _row(context.tr('音频时长'),
                      '${_result!.durationSeconds.toStringAsFixed(1)} s'),
                  _row(context.tr('实际耗时'),
                      '${_result!.elapsed.inSeconds} s'),
                  _row(
                      context.tr('速度'),
                      '${_result!.speedFactor.toStringAsFixed(2)}× 实时'),
                  const SizedBox(height: 10),
                  _fileRow(context.tr('人声'), _result!.vocalsPath),
                  _fileRow(context.tr('伴奏'), _result!.instrumentalPath),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 76,
                child: Text(k,
                    style: TextStyle(fontSize: 12, color: DshColors.textDim))),
            Expanded(
                child: Text(v,
                    style: TextStyle(fontSize: 12, color: DshColors.text))),
          ],
        ),
      );

  Widget _fileRow(String k, String path) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
                width: 76,
                child: Text(k,
                    style: TextStyle(fontSize: 12, color: DshColors.textDim))),
            Expanded(
              child: SelectableText(
                path.split('/').last,
                style: TextStyle(
                    fontSize: 11.5, height: 1.4, color: DshColors.accent),
              ),
            ),
          ],
        ),
      );
}
