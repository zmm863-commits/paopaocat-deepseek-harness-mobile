import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:dsh_mobile/ui/widgets/computer_access_qr.dart';

/// 「在电脑上打开」对话框：二维码 + 能手打的大字地址。
///
/// 三条要钉住的东西：
/// * 地址必须**原样**给出来（带 token），不能只给主机名 —— 否则用户照着敲必然 401；
/// * 口令要单独一行、别和主机名连成一串（一长串会挤出屏幕，人也没法念）；
/// * 文案**不许**承诺「扫一下就行」：台式机没有摄像头，这是真实场景。
void main() {
  Future<void> pump(WidgetTester tester, Map<String, String> entries) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ComputerAccessQrDialog(entries: entries),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('一个地址：出二维码 + 主机端口大字 + 口令单独一行', (tester) async {
    const url = 'http://192.168.3.7:38901/?token=4f2b9c1e8a7d6b5c4a3f2e1d0c9b8a7f';
    await pump(tester, <String, String>{'DSH 网页': url});

    // 二维码真的画出来了（不是错误占位）
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('二维码生成失败，直接照下面手打'), findsNothing);

    // 主机:端口 是大字、可选中；口令单独一段
    expect(find.text('192.168.3.7:38901'), findsOneWidget);
    expect(
      find.textContaining('/?token=4f2b9c1e8a7d6b5c4a3f2e1d0c9b8a7f'),
      findsOneWidget,
    );

    // 不许写「扫一下就行」这种半真半假的话
    expect(find.textContaining('没有的话照着下面手打'), findsOneWidget);
    // 必须提醒这串东西是凭证
    expect(find.textContaining('别发给别人'), findsOneWidget);
  });

  testWidgets('两个地址：给切换芯片，默认第一个（DSH 网页）', (tester) async {
    await pump(tester, <String, String>{
      'DSH 网页': 'http://192.168.3.7:38901/?token=aaa',
      '设计站': 'http://192.168.3.7:38902/?token=bbb',
    });

    expect(find.text('DSH 网页'), findsOneWidget);
    expect(find.text('设计站'), findsOneWidget);
    // 默认展示第一个
    expect(find.text('192.168.3.7:38901'), findsOneWidget);
    expect(find.text('192.168.3.7:38902'), findsNothing);

    await tester.tap(find.text('设计站'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('192.168.3.7:38902'), findsOneWidget);
    expect(find.text('192.168.3.7:38901'), findsNothing);
  });

  testWidgets('「复制这个地址」把完整 URL（含 token）放进剪贴板并关掉对话框', (tester) async {
    const url = 'http://10.0.0.9:38012/?token=deadbeef';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await pump(tester, <String, String>{'DSH 网页': url});
    await tester.tap(find.text('复制这个地址'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(copied, url);
    expect(find.byType(ComputerAccessQrDialog), findsNothing);
  });

  testWidgets('没有端口时也不崩（只显示主机名）', (tester) async {
    await pump(tester, <String, String>{'DSH 网页': 'http://myphone.local/?token=x'});
    expect(tester.takeException(), isNull);
    expect(find.text('myphone.local'), findsOneWidget);
  });
}
