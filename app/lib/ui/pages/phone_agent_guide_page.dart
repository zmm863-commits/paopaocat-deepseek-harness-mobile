import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';

/// 「后台操作」的图文使用说明（全屏看图）。
///
/// 图本身是一张竖版长图（`assets/images/phone_agent_guide.png`，1080×2559），
/// 由 HTML + 无头 Chrome 生成（内容源见 /tmp/guide2.html）。
/// 内容四段：第一次准备（免装 Shizuku 配对：mDNS 自动找端口 + 通知栏输码）
/// ＋ 后台操作你的 App ＋ 录规则（后台操作台/AI）＋ 定时任务。
///
/// 这里只负责「把图显示出来 + 能放大缩小」，图内容更新时**不用改代码**，
/// 换图文件即可。
class PhoneAgentGuidePage extends StatelessWidget {
  const PhoneAgentGuidePage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => const PhoneAgentGuidePage(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(
        backgroundColor: DshColors.bg,
        elevation: 0,
        title: Text(
          context.tr('使用说明'),
          style: TextStyle(color: DshColors.text, fontSize: 16),
        ),
        iconTheme: IconThemeData(color: DshColors.text),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 4,
          minScale: 0.6,
          child: SingleChildScrollView(
            child: Image.asset(
              'assets/images/phone_agent_guide.png',
              fit: BoxFit.fitWidth,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}
