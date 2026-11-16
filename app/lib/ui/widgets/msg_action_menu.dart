import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/dsh_tokens.dart';
import '../../i18n/dsh_i18n.dart';

/// 消息长按菜单的一个条目。
class MsgAction {
  const MsgAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// 破坏性操作（删除类）用警示色。这里暂未用到，留着给「删除这条」。
  final bool destructive;
}

/// 弹出消息长按菜单（底部弹层）。
///
/// ## 为什么是底部弹层而不是 `PopupMenu`
///
/// 会话页是单手操作的主战场：气泡在屏幕中部，长按后手指**已经离顶部很远**，
/// 从锚点弹出的菜单要够到上/右上角；底部弹层落在拇指区，且与本 App 既有
/// 的「公告 / 附件 / 模型选择」弹层是同一套语言。
///
/// 底色用 `DshColors.surfaceStrong` —— **必须不透明**（用户 2026-10-12 反馈：
/// 「有些弹出的面板透明度太高，能背景的字体」）。`bottomSheetTheme` 里也钉了
/// 同一条，这里显式再传一次是因为弹层要在**打开的那一刻**读到当前皮肤色，
/// 而不能依赖主题里可能被覆盖的默认值。
///
/// 点任一项：先关弹层再执行回调 —— 顺序反了会把回调里的 SnackBar / 输入框
/// 焦点抢在弹层动画后面，看着像"点了没反应"。
Future<void> showMsgActionMenu(
  BuildContext context,
  List<MsgAction> actions,
) async {
  if (actions.isEmpty) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: DshColors.surfaceStrong,
    builder: (sheetCtx) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final a in actions)
            ListTile(
              leading: Icon(
                a.icon,
                size: 20,
                color: a.destructive ? DshColors.err : DshColors.textDim,
              ),
              title: Text(
                a.label,
                style: TextStyle(color: DshColors.text, fontSize: 14),
              ),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                a.onTap();
              },
            ),
          const SizedBox(height: 4),
        ],
      ),
    ),
  );
}

/// 复制一段文本并给一条 SnackBar 回执。
///
/// 为什么要有这个小工具：菜单里「复制」在用户气泡与 AI 回答上各接一次，
/// 提示文案与"先关菜单再复制"的顺序必须一致 —— 散在两处迟早会改一处漏一处。
Future<void> copyWithSnack(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(context.tr('已复制')),
      duration: const Duration(seconds: 1),
    ));
}
