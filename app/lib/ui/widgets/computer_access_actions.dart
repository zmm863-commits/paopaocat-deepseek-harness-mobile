import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';

/// 「移动桌面平台」面板底部那排操作按钮：刷新网卡 / 复制网址 / 扫码打开 / 重置口令。
///
/// ## 为什么单独抽出来（2026-10-30）
///
/// 这排原来是 `Row`，四个按钮在 360dp 宽的屏上装不下 —— 最后一个「重置口令」
/// 被挤到屏幕外（用户原话：「扫码打开右边还有个选项，在屏幕外边」）。
/// `Row` 溢出**不会换行**，只会被裁掉，所以用户连它叫什么都不知道。
///
/// 换成 `Wrap` 就没事了；但抽成独立 widget 是为了**能被测到** ——
/// 面板本身依赖运行时、端口转发、文件系统，很难在 widget test 里点亮它的
/// 「已开启」状态，而这一行的排版恰恰只在「已开启」时才会溢出。
class ComputerAccessActions extends StatelessWidget {
  const ComputerAccessActions({
    super.key,
    required this.busy,
    required this.hasUrl,
    required this.showRotate,
    this.onRefresh,
    this.onCopy,
    this.onQr,
    this.onRotate,
  });

  final bool busy;

  /// 有没有可复制的地址（没开开关时为 false，复制/扫码两颗会隐藏）。
  final bool hasUrl;

  /// 显示「重置口令」（开关打开时才有意义）。
  final bool showRotate;

  final VoidCallback? onRefresh;
  final VoidCallback? onCopy;
  final VoidCallback? onQr;
  final VoidCallback? onRotate;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, String label, VoidCallback? onTap,
        {String? notifierKey}) {
      return TextButton.icon(
        onPressed: busy && onTap != null ? null : onTap,
        icon: Icon(icon, size: 16),
        label: Text(context.tr(label), style: const TextStyle(fontSize: 12)),
      );
    }

    // ⚠️ 必须是 Wrap：满一行自动折到下一行。换成 Row 就会在窄屏上被裁掉一截。
    return Wrap(
      spacing: 4,
      runSpacing: -2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        btn(Icons.refresh, '刷新网卡', onRefresh),
        if (hasUrl) btn(Icons.copy_all_outlined, '复制网址', onCopy),
        if (hasUrl) btn(Icons.qr_code_2, '扫码打开', onQr),
        if (showRotate) btn(Icons.password_outlined, '重置口令', onRotate),
      ],
    );
  }
}
