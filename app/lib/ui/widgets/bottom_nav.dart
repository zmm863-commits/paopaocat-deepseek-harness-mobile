import 'package:flutter/material.dart';

import '../theme/dsh_tokens.dart';

import '../../i18n/dsh_i18n.dart';

/// 底部 5 项导航（设计稿每页都有）。
///
/// 设计稿几何：导航文字基线 y≈2589（屏高 98%），5 项 x 依次约
/// 85 / 327 / 556 / 783 / 1058 —— 也就是横向五等分居中。所以这里直接用
/// 等分 Row，不写死坐标，任何屏宽都能对上。
///
/// 顺序：首页 / 专家 / 资料库 / 定时任务 / 设置
/// （第一项叫「首页」而不是「任务」：它是品牌首页，不是任务清单 ——
///  任务/会话清单在右上角的「工作区」入口里。
///  最后一项原为「项目空间」，用户要求改为「设置」。）
class DshBottomNav extends StatelessWidget {
  const DshBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  static List<({IconData icon, IconData activeIcon, String label})> get items =>
      [
        (
          icon: Icons.chat_bubble_outline,
          activeIcon: Icons.chat_bubble,
          label: tr('首页')
        ),
        // 当前六项：0 首页 / **1 Bot** / 2 创作台 / 3 资料库 / 4 定时任务 / 5 设置。
        // ⚠️ 2026-10-17 用户要求「bot 是放在底部导航栏，首页按钮的右边」——
        //    这一项是**插在首页之后**的，所以它后面所有下标都 +1 了
        //    （`app_shell` 的 `_goToTab(4)→(5)`、`_pageTicks` 全体后移、
        //      `chat_page` 的 `{'tab': 3}→4`、以及 `nav_items_test` 的断言）。
        (
          icon: Icons.smart_toy_outlined,
          activeIcon: Icons.smart_toy,
          label: tr('Bot')
        ),
        // 原五项（历史）：0 首页 / 1 创作台 / 2 资料库 / 3 定时任务 / 4 设置。
        // ⚠️ 任何写死下标的地方都要跟着改。2026-10-11 插「影视」（后改名「创作台」）时
        //    踩过一次：`app_shell` 里写死的「下标 4 = 设置」和 `chat_page`
        //    附件菜单里的 `{'tab': 3}`（定时任务）都一起改了，漏一个就是"点进去跑错页"。
        // ⚠️ 历史：下标 1 曾经是「本地大模型」（2026-10-09 加，2026-10-12 **撤下** ——
        //    用户原话「本地大模型这一块不是太成熟，把这个功能删掉先」+「知识库也一并清理掉」）。
        //    做法是**撤入口、留代码**（用户选的可逆方案）：`local_model_home_page` /
        //    `ondevice_models_page` / `local_chat_page` / `kb_page` 都还在原位，
        //    但现在**没有任何入口**能到达它们（设置页里也没有）。想恢复就把这一项加回来，
        //    并把其余下标一起后移。
        // 「创作台」＝ 泡泡猫影视工具的手机版（2026-10-11 要求加，2026-10-12 改名并
        //    拆成"入口页 + 详情页"）。入口在设置里也有一份，但这里是主入口。
        (
          icon: Icons.movie_outlined,
          activeIcon: Icons.movie,
          label: tr('创作台')
        ),
        (
          icon: Icons.folder_outlined,
          activeIcon: Icons.folder,
          label: tr('资料库')
        ),
        (
          icon: Icons.schedule_outlined,
          activeIcon: Icons.schedule,
          label: tr('定时任务')
        ),
        (
          icon: Icons.settings_outlined,
          activeIcon: Icons.settings,
          label: tr('设置')
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DshColors.navBg,
        border: Border(top: BorderSide(color: DshColors.divider, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          // 设计稿导航标签带 y=2567~2610（屏高 97.2%~98.9%），
          // 所以高度按屏高比例算（见 DshMetrics.navContentHeight 的注释）。
          height:
              DshMetrics.navContentHeight(MediaQuery.sizeOf(context).height),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavCell(
                    icon: items[i].icon,
                    activeIcon: items[i].activeIcon,
                    label: items[i].label,
                    active: i == currentIndex,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavCell extends StatelessWidget {
  const _NavCell({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? DshColors.accent : DshColors.textDim;
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            // 当前项指示：一条**青→紫渐变**短条（网站那种渐变强调）。
            // 用 Stack 而不是往 Column 里塞一行，避免在按屏高算出来的
            // 导航高度里挤出溢出。
            if (active)
              Container(
                margin: const EdgeInsets.only(top: 3),
                width: 26,
                height: 3,
                decoration: BoxDecoration(
                  gradient: DshColors.grad,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(2)),
                  boxShadow: DshColors.accentShadow,
                ),
              ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(active ? activeIcon : icon, size: 21, color: color),
                const SizedBox(height: 3),
                // ⚠️ 标签要**按格宽自动缩**，不能溢出、也不能截成省略号。
                //
                // 为什么（用户 2026-10-11 实测）：「本地大模型」这一项有 5 个字，
                // 而导航现在有 **6 项** —— 320~360dp 的窄屏上每格只有 ~55dp，
                // 5 个字（约 55~60dp）正好顶出去（用户原话：「本地大模型也存在
                // 界面挤出去的情况」）。标签是导航**唯一**的标识，截了就没法认，
                // 所以这里用 FittedBox 让它缩字而不是溢出。
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: color,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
