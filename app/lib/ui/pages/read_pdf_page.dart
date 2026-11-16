import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../theme/dsh_tokens.dart';

/// 读 PDF：把一份 PDF 读成**带结构的文字**，能复制出来喂给任何模型。
///
/// 2026-11-14：三梯队之三。
///
/// ## 为什么最后没用 PDFium 那套
///
/// 社区里成熟的 PDF 解析工具基本都靠 PDFium（Chrome 的 PDF 引擎）。但 PDFium 的
/// 预编译发布**没有 Android 版本** —— 只有 linux / mac / win / wasm，而且 linux-arm64
/// 那个链的是 glibc，Android 是 bionic，直接拿过来跑不起来。自己编 PDFium 要
/// depot_tools、几 GB 依赖、几个小时，为一个"读文字"的功能不值。
///
/// 换成 **pdf.js**（Mozilla，Apache-2.0，纯 JavaScript）之后：无原生依赖、
/// 不用交叉编译、跟着包里那个 node 直接跑，照样能给出「文本 + 坐标 + 宽高」。
/// 代价是没有 OCR（扫描件读不出来）和高质量渲染 —— 需要时再单独上。
///
/// ## 这个页面给谁用
///
/// 给用户自己**看一眼读出来的对不对**。会话里的模型也能直接调同一个脚本
/// （`node "$DSH_ANDROID_TOOLBOX/parse-pdf.mjs" 文件.pdf`），不必经过这个页面。
class ReadPdfPage extends StatefulWidget {
  const ReadPdfPage({super.key, required this.runtime});

  final DshRuntime runtime;

  @override
  State<ReadPdfPage> createState() => _ReadPdfPageState();
}

class _ReadPdfPageState extends State<ReadPdfPage> {
  String? _file;
  bool _busy = false;
  String? _text;
  String? _error;
  int _pages = 0;

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['pdf'],
    );
    final p = r?.files.single.path;
    if (p == null) return;
    setState(() {
      _file = p;
      _text = null;
      _error = null;
    });
    await _parse();
  }

  Future<void> _parse() async {
    final f = _file;
    if (f == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final node = widget.runtime.nodeBinary;
      final script = widget.runtime.parsePdfScriptPath;
      if (node.isEmpty) {
        throw '这个安装包里没有 node，读不了 PDF';
      }
      final res = await Process.run(
        node,
        <String>[script, f, '--format', 'md'],
        environment: <String, String>{
          // ⚠️ 这一条不能少：`libnode.so` 依赖同目录的 libc++_shared / libicu* 等，
          //    它们不在系统搜索路径里。漏了就报
          //    `library "libc++_shared.so" not found`（2026-11-16 同批修的）。
          'LD_LIBRARY_PATH': widget.runtime.nativeLibDir,
          // pdf.js 在 node 下会尝试 load 可选的 canvas，禁掉省得打一堆警告。
          'NODE_OPTIONS': '--no-warnings',
        },
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      );
      if (res.exitCode != 0) {
        final err = '${res.stderr}'.trim();
        throw err.isEmpty ? '解析失败（退出码 ${res.exitCode}）' : err;
      }
      final out = '${res.stdout}';
      // 从头部那行「共 N 页」里取页数（脚本的输出格式是固定的）
      final m = RegExp(r'共\s*(\d+)\s*页').firstMatch(out);
      if (!mounted) return;
      setState(() {
        _text = out;
        _pages = int.tryParse(m?.group(1) ?? '') ?? 0;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(
        backgroundColor: DshColors.bg,
        title: Text(context.tr('读 PDF')),
        actions: <Widget>[
          if (text != null)
            IconButton(
              tooltip: context.tr('复制全文'),
              icon: const Icon(Icons.copy_rounded, size: 20),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('已复制 {0} 个字符', ['${text.length}']))),
                );
              },
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pick,
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  label: Text(_file == null
                      ? context.tr('选择 PDF')
                      : _file!.split('/').last),
                ),
                if (_file != null && !_busy && _text != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      context.tr('共 {0} 页 · 读出来 {1} 个字符',
                          ['$_pages', '${_text!.length}']),
                      style: TextStyle(fontSize: 12, color: DshColors.textDim),
                    ),
                  ),
              ],
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: TextStyle(fontSize: 12, height: 1.5, color: DshColors.err)),
            ),
          if (text != null)
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                padding: const EdgeInsets.all(13),
                decoration: DshColors.panel(),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: TextStyle(
                        fontSize: 12.5, height: 1.6, color: DshColors.text),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
