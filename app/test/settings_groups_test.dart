/// 设置页**归纳结构**的回归测试（用户 2026-10-15 第 3 条）。
///
/// 用户那次的原话是三件事，这里逐条钉住：
///   1. 「设置页面项目比较多，太长了，是不是归纳一下」→ 15 个平铺板块收成 4 组，
///      默认收起时**一屏只看得到组名**（组里的东西根本没构建）；
///   2. 「把检查更新并到关于里，**放到更新说明的上边**」→ 位置断言（用 y 坐标比）；
///   3. 「zen 这个设置……作为一个彩蛋吧」→ 默认不出现，解锁后才出现。
///
/// ⚠️ 为什么用"位置"而不是"存在"来断言第 2 条：只断言"两句话都在这一页"是抓不到
/// 顺序写反的 —— 而那正是用户抱怨的形态（要滑来滑去）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/data/easter_egg.dart';
import 'package:dsh_mobile/i18n/app_language.dart';
import 'package:dsh_mobile/i18n/dsh_i18n.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/ui/pages/settings_tab.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late DshRuntime runtime;

  setUp(() async {
    DshColors.applySkin(DshPalettes.dark);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EasterEggStore.instance.resetForTest();
    tmp = Directory.systemTemp.createTempSync('dsh-settings-');
    runtime = DshRuntime(<String, dynamic>{
      'nodeBinary': '${tmp.path}/libnode.so',
      'nativeLibDir': tmp.path,
      'filesDir': tmp.path,
      'dshBin': '${tmp.path}/dsh/lib/bin.js',
      'nodeHome': '${tmp.path}/dshhome',
      'fsShim': '${tmp.path}/shims/android-fs-shim.cjs',
    });
    Directory('${tmp.path}/dshhome').createSync(recursive: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DshHost.channel, (MethodCall call) async {
      switch (call.method) {
        case 'permissionStatus':
          return <String, String>{
            'microphone': 'granted',
            'location': 'denied',
            'photos': 'permanently-denied',
            'notifications': 'granted',
          };
        case 'speechSupport':
          return <String, Object>{
            'sdkInt': 34,
            'recognitionAvailable': true,
            'onDeviceAvailable': true,
            'intentHandlers': 3,
            'language': 'zh-CN',
          };
        default:
          return null;
      }
    });
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(DshI18n(
      language: AppLanguage.zh,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildDshTheme(),
        home: Scaffold(
          backgroundColor: DshColors.bg,
          body: SettingsTab(
            runtime: runtime,
            appSettings: AppSettings(),
            onModelChanged: () async {},
          ),
        ),
      ),
    ));
    // 刻意不用 pumpAndSettle：这棵树里有循环动画，实测会等到超时。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('收成 4 组：默认收起时组里的板块根本没构建', (tester) async {
    await pumpSettings(tester);

    for (final t in <String>['模型', 'AI 能力', '外观与语言', '应用']) {
      expect(find.text(t), findsOneWidget, reason: '少了「$t」这一组');
    }
    // 组里的板块默认不构建 —— 这就是"一屏能看全"的机制。
    expect(find.text('云端大模型'), findsNothing,
        reason: '没展开「模型」组就把里面的板块全铺开了 —— 又变回一长条了');
    expect(find.text('图像 / 视频模型'), findsNothing);

    // 展开「模型」组，里面的板块才出现。
    await tester.tap(find.text('模型'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('云端大模型'), findsOneWidget);
    expect(find.text('图像 / 视频模型'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('「检查更新」在「关于」里，而且排在「更新说明」上面', (tester) async {
    await pumpSettings(tester);

    // 「关于」常驻展开：这两条不点任何东西就该在屏幕上。
    expect(find.text('检查更新'), findsWidgets,
        reason: '「检查更新」没并进「关于」（它应该在关于卡里）');
    expect(find.text('更新说明'), findsOneWidget);

    final updY = tester.getTopLeft(find.text('检查更新').first).dy;
    final notesY = tester.getTopLeft(find.text('更新说明')).dy;
    expect(updY, lessThan(notesY),
        reason: '用户要求「检查更新」在「更新说明」的上边 —— 现在顺序反了');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Zen 是彩蛋：默认不出现，连点猫解锁后才出现在「模型」组里', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('模型'));
    await tester.pump(const Duration(milliseconds: 300));

    // 2026-11-02：这条通道的对外名字已从「实验通道 · OpenCode Zen（第三方通道）」
    // 改成「免Key通道」（用户 2026-11-03 又要求精简，原名太长；用户要求 —— 会话选择器里 zen 与 polli 两条都叫
    // "免费模型"时分不清）。所以断言跟着改名走，不再找旧文案。
    expect(find.textContaining('免Key通道'), findsNothing,
        reason: '彩蛋没藏住 —— 设置页默认就能看到那条第三方通道');

    await EasterEggStore.instance.unlockZen();
    await tester.pump();

    expect(find.textContaining('免Key通道'), findsOneWidget,
        reason: '解锁彩蛋之后那条第三方通道还是没有出现');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
