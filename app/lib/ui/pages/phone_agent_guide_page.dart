import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';

/// 「后台操作」的图文使用说明（全屏看图）。
///
/// 图本身是一张竖版长图（`assets/images/phone_agent_guide.png`，1080×2390），
/// 由 `install/make-phone-agent-guide.sh` 用 HTML + 无头 Chrome 生成。
/// 内容分两段：第一次准备（开无线调试→拿配对码→回 App 配对）＋ 以后每次用
/// （进操作台→建虚拟屏→拉 App→销毁）。
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
