/// 卡片协议化（E-4 / CHG-04）的回归测试。
///
/// ## 为什么这组测试重要
///
/// E-4 的验收标准只有一条：**新增一类卡片不改 Flutter 代码就能渲染**。
///
/// 怎么证明？拿一个**渲染器从来没听说过**的类型（`'form'`），
/// 只喂一份 JSON，看它是不是照样画出来。
/// 如果哪天有人给渲染器加上了 `if (type == 'tool')` 这种分支，
/// 这条测试会立刻红 —— 那正是我们要防的退化。
///
/// 所以这里固定了三条：
///   1. 渲染器**不认识类型**也照画（通用档）；
///   2. 协议层**容错**：字段缺了/类型不对就少画，**绝不编内容**；
///   3. 工具卡的**外观不回退**（标题/状态/命令/输出都还在）。
library;

import 'package:dsh_mobile/ui/cards/card_renderer.dart';
import 'package:dsh_mobile/ui/cards/card_schema.dart';
import 'package:dsh_mobile/ui/widgets/message_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpCard(
  WidgetTester tester,
  CardSpec spec, {
  ValueChanged<CardAction>? onAction,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: CardRenderer(spec: spec, onAction: onAction),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('协议层：容错解析', () {
    test('字段缺了 / 类型不对 → 少画，绝不编内容', () {
      final spec = CardSpec.fromJson(<String, dynamic>{
        'type': 'whatever',
        'fields': <dynamic>[
          <String, dynamic>{'label': '只有标签'},
          <String, dynamic>{'value': '只有内容'},
          '不是对象的元素',
        ],
        'statusTone': '不存在的色调',
        'actions': '不是数组',
      });

      expect(spec.type, 'whatever');
      expect(spec.fields.length, 2,
          reason: '不是对象的元素要跳过 —— 少一项好过崩一次');
      expect(spec.statusTone, CardStatusTone.neutral,
          reason: '不认识的色调回落成中性，不能瞎配一个');
      expect(spec.actions, isEmpty);
      expect(spec.title, isNull, reason: '没给标题就没有标题，不填占位文字');
    });

    test('空字符串算"没有这一项"（不画空框）', () {
      final spec = CardSpec.fromJson(<String, dynamic>{
        'type': 'x',
        'fields': <dynamic>[
          <String, dynamic>{'label': '   ', 'value': ''},
        ],
      });
      expect(spec.fields.single.isEmpty, isTrue);
    });

    test('没给 type → 当通用卡片（不报错）', () {
      final spec = CardSpec.fromJson(<String, dynamic>{});
      expect(spec.type, 'generic');
    });
  });

  group('渲染器：类型无关（E-4 的核心验收）', () {
    testWidgets('没见过的类型照样画出来 —— 不用改 Flutter 代码', (tester) async {
      // 'form' 这个类型渲染器**从来没听说过**（没登记在 _cardTypes 里）。
      final spec = CardSpec.fromJson(<String, dynamic>{
        'type': 'form',
        'title': '问卷',
        'status': '待填写',
        'fields': <dynamic>[
          <String, dynamic>{'label': '你最常用的模型', 'value': '本地模型'},
        ],
        'actions': <dynamic>[
          <String, dynamic>{'id': 'submit', 'label': '提交'},
        ],
      });

      await _pumpCard(tester, spec);

      expect(find.text('问卷'), findsOneWidget);
      expect(find.text('待填写'), findsOneWidget);
      expect(find.text('你最常用的模型'), findsOneWidget);
      expect(find.text('本地模型'), findsOneWidget);
      expect(find.text('提交'), findsOneWidget,
          reason: '动作也要能画出来（服务端下发的按钮）');
    });

    testWidgets('动作点了会把 id 回传出去', (tester) async {
      final tapped = <String>[];
      final spec = CardSpec.fromJson(<String, dynamic>{
        'type': 'form',
        'title': '问卷',
        'actions': <dynamic>[
          <String, dynamic>{'id': 'submit', 'label': '提交'},
        ],
      });

      await _pumpCard(tester, spec, onAction: (a) => tapped.add(a.id));
      await tester.tap(find.text('提交'));
      await tester.pump();

      expect(tapped, <String>['submit']);
    });

    testWidgets('展开区有内容才给箭头；没内容不给"点了没反应"的按钮',
        (tester) async {
      final spec = CardSpec.fromJson(<String, dynamic>{
        'type': 'form',
        'title': '问卷',
        'expandable': true,
        'expandedFields': <dynamic>[
          <String, dynamic>{'value': '   '},
        ],
      });
      await _pumpCard(tester, spec);

      expect(find.byIcon(Icons.expand_more), findsNothing,
          reason: '展开区是空的 → 不给箭头');
    });
  });

  group('工具卡：外观不回退', () {
    ChatMsg tool({
      String title = 'Read file',
      String? status = 'completed',
      String? command = 'cat a.txt',
      String? output = 'hello',
    }) =>
        ChatMsg(
          text: '',
          role: ChatRole.tool,
          toolTitle: title,
          toolStatus: status,
          toolCommand: command,
          toolOutput: output,
        );

    testWidgets('标题 / 状态在，命令与输出默认折叠', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(msg: tool())),
      ));
      await tester.pump();

      expect(find.text('Read file'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('cat a.txt'), findsNothing,
          reason: '命令与输出默认折叠');
      expect(find.text('hello'), findsNothing);
    });

    testWidgets('点标题 → 展开，命令与输出都出来', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(msg: tool())),
      ));
      await tester.pump();

      await tester.tap(find.text('Read file'));
      await tester.pumpAndSettle();

      expect(find.text('cat a.txt'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('规格里的状态与图标跟着状态走', (tester) async {
      // 规格是**数据** —— 状态色与图标都在数据里，渲染器只负责画。
      late CardSpec ok;
      late CardSpec failed;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          ok = toolCardSpec(tool(status: 'completed'), ctx);
          failed = toolCardSpec(tool(status: 'failed'), ctx);
          return const SizedBox.shrink();
        }),
      ));

      expect(ok.type, 'tool');
      expect(ok.statusTone, CardStatusTone.ok);
      expect(ok.icon, Icons.check_circle_outline);
      expect(failed.statusTone, CardStatusTone.err);
      expect(failed.icon, Icons.error_outline);
    });
  });
}
