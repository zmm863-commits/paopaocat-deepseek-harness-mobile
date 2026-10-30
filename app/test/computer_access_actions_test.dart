import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/ui/widgets/computer_access_actions.dart';

/// 「移动桌面平台」那排操作按钮的排版门禁。
///
/// 由来（2026-10-30 真机反馈，用户原话）：
/// **「扫码打开右边还有个选项，在屏幕外边」** —— 原来这排是 `Row`，
/// 四个按钮在 360dp 宽上装不下，最后一个「重置口令」被裁到屏幕外。
/// `Row` 溢出不会报错给用户看，只会**静静被裁掉**，所以人根本不知道那里还有个功能。
///
/// 这条测试把「窄屏下最宽的那一排」钉住：一旦有人把 Wrap 改回 Row、或者又往里
/// 加第五个按钮，这里就会红。
void main() {
  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: ComputerAccessActions(
              busy: false,
              hasUrl: true,
              showRotate: true,
              onRefresh: () {},
              onCopy: () {},
              onQr: () {},
              onRotate: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('四颗按钮全部可见（一个都不许被挤出屏幕）', (tester) async {
    await pumpAt(tester, 320);

    expect(find.text('刷新网卡'), findsOneWidget);
    expect(find.text('复制网址'), findsOneWidget);
    expect(find.text('扫码打开'), findsOneWidget);
    expect(find.text('重置口令'), findsOneWidget);
  });

  testWidgets('320dp 窄屏下不溢出（原来这里会 RenderFlex overflow）', (tester) async {
    await pumpAt(tester, 320);
    // 溢出会被记为 FlutterError；没有异常就说明 Wrap 正常折行了
    expect(tester.takeException(), isNull);
  });

  testWidgets('240dp 极窄屏也不溢出（极端情况兜底）', (tester) async {
    await pumpAt(tester, 240);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没开开关时只显示「刷新网卡」一颗', (tester) async {
    await pumpAt(tester, 320);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: ComputerAccessActions(
            busy: false,
            hasUrl: false,
            showRotate: false,
            onRefresh: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('刷新网卡'), findsOneWidget);
    expect(find.text('复制网址'), findsNothing);
    expect(find.text('扫码打开'), findsNothing);
    expect(find.text('重置口令'), findsNothing);
  });

  testWidgets('busy 时全部按钮禁用（点不动，避免重复拨开关）', (tester) async {
    await pumpAt(tester, 320);
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: ComputerAccessActions(
            busy: true,
            hasUrl: true,
            showRotate: true,
            onRefresh: () => tapped++,
            onCopy: () => tapped++,
            onQr: () => tapped++,
            onRotate: () => tapped++,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('刷新网卡'));
    await tester.tap(find.text('复制网址'));
    await tester.tap(find.text('扫码打开'));
    await tester.tap(find.text('重置口令'));
    await tester.pump();

    expect(tapped, 0, reason: '忙碌时点了不该有反应');
  });
}
