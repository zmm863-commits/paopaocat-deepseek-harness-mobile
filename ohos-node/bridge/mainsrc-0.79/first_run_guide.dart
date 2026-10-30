import 'dart:io';

import 'package:flutter/material.dart';

import '../i18n/dsh_i18n.dart';
import 'theme/dsh_tokens.dart';

/// 首装引导：**只出现一次**的三条要点。
///
/// 为什么要有（2026-10-20，0.78）：App 的能力面很宽（做真文件、免费模型、Bot 团队），
/// 但首装进来只有一个空聊天框 —— 用户不知道该干什么。这里给三条最要紧的"能做什么"，
/// 点一下就开始用，不挡住任何东西。
///
/// 为什么不做多屏翻页：翻页会让新用户多点两下才进来；三条要点一屏能看完，成本最低。
class FirstRunGuideDialog extends StatelessWidget {
  const FirstRunGuideDialog({super.key});

  /// 标记文件：存在即表示"看过了"。
  ///
  /// 为什么用标记文件而不是写进 AppSettings：这里的语义是"这套引导（v1）看过没有"，
  /// 以后改版引导想再出一次，只要换个文件名即可，不必动设置的读写与迁移。
  static File _marker(String filesDir) =>
      File('$filesDir/.first-run-guide-v1');

  static bool seen(String filesDir) => _marker(filesDir).existsSync();

  /// 没看过就弹一次；**弹完立刻写标记**（用户中途杀掉也不会反复弹）。
  static Future<void> showOnceIfNeeded(
    BuildContext context, {
    required String filesDir,
  }) async {
    try {
      if (seen(filesDir)) return;
      await _marker(filesDir).parent.create(recursive: true);
      await _marker(filesDir).writeAsString('seen\n');
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (_) => const FirstRunGuideDialog(),
      );
    } catch (e) {
      debugPrint('[first-run] 引导没弹出来（不影响使用）：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // ⚠️ 每条都必须写成 `context.tr('…')` 且字面量在同一行 —— i18n 扫描器只认这种形状，
    //    写成 `final t = context.tr; t('…')` 会被**静默漏掉**（切外语就是中文，且不报警）。
    final rows = <(IconData, String)>[
      (Icons.auto_awesome_outlined, context.tr('一句话就能得到真实文件：PPT、文档、表格、图、视频。')),
      (Icons.lock_open_outlined, context.tr('不用填 Key 就能聊 —— 装完自带免费模型。')),
      (Icons.groups_outlined, context.tr('底部「Bot」是 Bot 团队：建 Bot、建群聊、派活、看它干活。')),
    ];
    return AlertDialog(
      backgroundColor: DshColors.surfaceHigh,
      title: Text(context.tr('欢迎使用泡泡猫的 DSH')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (icon, text) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(text,
                        style: TextStyle(
                            fontSize: 13.5, height: 1.55, color: DshColors.text)),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(context.tr('开始用')),
        ),
      ],
    );
  }
}
