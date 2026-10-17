/// 底部导航的**项数与顺序**测试。
///
/// 为什么值得单独钉住：`app_shell` 与 `chat_page` 里有**写死的下标**
/// （首页 → 设置、定时任务、资料库）。用户 2026-10-09 把「专家」从底部 Tab
/// 挪进设置页、2026-10-11 又插进「影视」，这些下标全都变过一次 ——
/// 这类改动最容易漏改一处，而漏改的表现是"点了没反应"或"跳错页"，
/// 很难从代码上肉眼看出来。
///
/// 所以这里除了钉住顺序，还钉住**每个写死下标的实际值**
/// （`设置 = 4`、`定时任务 = 3`），改动时必须两边一起改。
library;

import 'package:dsh_mobile/ui/widgets/bottom_nav.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('底部导航 6 项，顺序是 首页 / Bot / 创作台 / 资料库 / 定时任务 / 设置', () {
    final labels = DshBottomNav.items.map((i) => i.label).toList();
    // 2026-10-17 用户要求「bot 是放在底部导航栏，首页按钮的右边」→ 插在首页之后，
    // 于是它后面所有下标都 +1。
    expect(labels,
        <String>['首页', 'Bot', '创作台', '资料库', '定时任务', '设置']);
    // 「专家」不能再出现在底部（它现在是设置页里的入口）
    expect(labels.contains('专家'), isFalse);
  });

  test('「创作台」现在是第 2 个 Tab（原名「影视」，2026-10-12 改名）', () {
    final labels = DshBottomNav.items.map((i) => i.label).toList();
    final media = labels.indexOf('创作台');
    expect(media, 2, reason: '2026-10-17 Bot 插在首页右边后，它后移一位');
    expect(labels[media + 1], '资料库', reason: '后面的顺序不该被打乱');
  });

  test('⚠️ 写死的下标：设置 = 5、定时任务 = 4（`app_shell` / `chat_page` 里各有一处）', () {
    final labels = DshBottomNav.items.map((i) => i.label).toList();
    // app_shell: 首页「去配模型」按钮 = _goToTab(5)
    expect(labels.indexOf('设置'), 5,
        reason: 'app_shell 的 onOpenModelSettings: () => _goToTab(5) 依赖这个值');
    // chat_page: 附件菜单「定时任务」= pop({'tab': 4})
    expect(labels.indexOf('定时任务'), 4,
        reason: "chat_page 的 pop({'tab': 4}) 依赖这个值");
    // 创作台自己的「去设置」也走回调（壳层传 5），不写死
    expect(labels.indexOf('创作台'), 2);
    // Bot 就插在首页右边（用户 2026-10-17 的要求）
    expect(labels.indexOf('Bot'), 1);
  });
}
