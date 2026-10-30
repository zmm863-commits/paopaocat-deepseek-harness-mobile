import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';

import '../../i18n/dsh_i18n.dart';

/// 「用手机把它打开」对话框：**一个二维码 + 一串能手打的地址**。
///
/// ## 为什么两个都要（2026-10-30 想清楚才做）
///
/// 「手机当主机、电脑当屏幕」这个用法里，痛点其实是**在电脑上把那串地址敲进去**。
/// 二维码只解决了一半场景：笔记本有摄像头、且装了能扫出网址的工具才行；台式机
/// 根本没有摄像头。所以这里**同时**给出大字号的分段地址，让人照着念/照着打也
/// 很快 —— 不写「扫一下就行」这种半真半假的承诺。
///
/// 地址里带访问口令（`?token=`），所以文案必须提醒**别发给别人**。
class ComputerAccessQrDialog extends StatefulWidget {
  const ComputerAccessQrDialog({super.key, required this.entries});

  /// 标题 → 地址。第一项默认选中（调用方放「DSH 网页」）。
  final Map<String, String> entries;

  @override
  State<ComputerAccessQrDialog> createState() => _ComputerAccessQrDialogState();
}

class _ComputerAccessQrDialogState extends State<ComputerAccessQrDialog> {
  late String _key = widget.entries.keys.first;

  String get _url => widget.entries[_key] ?? '';

  /// 把 `http://192.168.3.7:38901/?token=…` 拆成「能一眼念出来」的两段：
  /// 主机:端口 与 口令。口令太长，单独一行小字号，别让它把屏幕撑破。
  (String host, String token) get _parts {
    final uri = Uri.tryParse(_url);
    if (uri == null) return (_url, '');
    final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    return (host, uri.queryParameters['token'] ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (host, token) = _parts;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.qr_code_2, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(context.tr('在电脑上打开'),
                style: const TextStyle(fontSize: 16)),
          ),
        ],
      ),
      // ⚠️ 必须可滚动：两个地址时内容比一屏高，小屏 / 横屏会撑出黄黑条
      //    （2026-10-30 测试里直接抓到 RenderFlex overflowed by 21 pixels）。
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.entries.length > 1) ...[
                Wrap(
                  spacing: 6,
                  children: [
                    for (final k in widget.entries.keys)
                      ChoiceChip(
                        label: Text(k, style: const TextStyle(fontSize: 11.5)),
                        selected: _key == k,
                        onSelected: (_) => setState(() => _key = k),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: QrImageView(
                    data: _url,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                    // 不画空隙：口令一长（60+ 字符）码点会变密，留白反而更难扫。
                    gapless: false,
                    errorStateBuilder: (_, __) => SizedBox(
                      width: 200,
                      height: 200,
                      child: Center(
                        child: Text(
                          context.tr('二维码生成失败，直接照下面手打'),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: scheme.error),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                context.tr('电脑有扫码工具就扫这个码；没有的话照着下面手打：'),
                style:
                    TextStyle(fontSize: 11, color: scheme.outline, height: 1.5),
              ),
              const SizedBox(height: 6),
              SelectableText(
                host,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  fontFamily: 'monospace',
                ),
              ),
              if (token.isNotEmpty) ...[
                const SizedBox(height: 4),
                SelectableText(
                  '/?token=$token',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    color: scheme.outline,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                context.tr('这个地址带身份凭证（token），别发给别人。'),
                style: TextStyle(
                    fontSize: 10.5, color: scheme.outline, height: 1.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _url));
            if (!context.mounted) return;
            Navigator.of(context).pop();
          },
          icon: const Icon(Icons.copy_all_outlined, size: 16),
          label:
              Text(context.tr('复制这个地址'), style: const TextStyle(fontSize: 12)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('关闭'), style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}
