import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/data/artifacts.dart';
import 'package:dsh_mobile/ui/widgets/message_stream.dart';

/// 思考**正在长**的时候不该折叠。
///
/// 起因（用户 2026-10-20）：「他的思考过程比我的要流畅」。
/// 一处具体原因就是：旧实现按**字符数**决定要不要折叠（>160 折成 4 行），
/// 而流式思考每长一点都可能跨过这个阈值 —— 于是用户会看到"字突然消失"的跳变。
/// 现在的规矩：这一轮还没结束、且它是最新一条 → 全文铺开；结束之后再收起来。
///
/// ⚠️ 这两条断言必须一起看：
///   1. streaming 时**没有**「展开」（因为它已经全展开了，给按钮等于骗人）；
///   2. 全文**看得见**（不能只判按钮，不然"折叠了但按钮也没画"的 bug 会漏）。
const String _longThought =
    'Let me think about this carefully. The user is asking whether the app can '
    'avoid showing English reasoning. First I should check what the runtime '
    'actually exposes, then look at how the message stream renders thought '
    'blocks, and finally decide whether hiding is needed at all.';

ChatMsg _thought(String text) => ChatMsg(text: text, role: ChatRole.thought);

/// 一段**已经结束**的思考：带真实的起止时刻。
///
/// 为什么测试要自己造时间戳：时长的来源是 ACP 通知到达的真实时刻
/// （见 chat_page 的 `_closeOpenThought`），单测里没有运行时，
/// 所以这里按同样的形状喂进去 —— 界面只认消息上的时间戳。
ChatMsg _thoughtDone(String text, {int seconds = 12}) {
  final m = ChatMsg(text: text, role: ChatRole.thought);
  m.startedAt = DateTime(2026, 10, 20, 10, 0, 0);
  m.endedAt = DateTime(2026, 10, 20, 10, 0, seconds);
  return m;
}

Future<void> _pump(
  WidgetTester tester,
  List<ChatMsg> msgs, {
  required bool running,
  String mode = 'collapsed',
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MessageStream(
        messages: msgs,
        artifacts: const <Artifact>[],
        running: running,
        controller: ScrollController(),
        onOpenArtifacts: () {},
        thinkingMode: mode,
      ),
    ),
  ));
  // running 为真时底部有一直转的进度圈，pumpAndSettle 永远settle不了。
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('流式中的思考不折叠（不要"字突然消失"）', () {
    testWidgets('running 且是最新一条 → 全文铺开，不给「展开」', (tester) async {
      await _pump(tester, <ChatMsg>[_thought(_longThought)], running: true);

      expect(find.text('展开'), findsNothing,
          reason: '正在长的时候全文已经铺开，再给「展开」等于给一个点了没反应的按钮');
      // 末尾那句只有全文渲染才看得到（折叠成 4 行时它已经在省略号后面了）。
      expect(find.textContaining('decide whether hiding is needed'), findsOneWidget,
          reason: '流式期间必须能看到最新长出来的内容');
    });

    testWidgets('这一轮结束（running=false）→ 收成折叠态', (tester) async {
      await _pump(tester, <ChatMsg>[_thought(_longThought)], running: false);

      expect(find.text('展开'), findsOneWidget,
          reason: '结束之后应该能收起来，否则一条长思考会把版面一直顶开');
    });
  });

  group('流式时底部渐隐（新字从雾里出来）', () {
    testWidgets('正在长 → 套一层 ShaderMask 渐隐', (tester) async {
      await _pump(tester, <ChatMsg>[_thought(_longThought)], running: true);

      expect(find.byType(ShaderMask), findsOneWidget,
          reason: '流式期间思考块底部要有渐隐遮罩（对标 WorkBuddy 的 bottom_fade）');
    });

    testWidgets('结束之后 → 不再渐隐（否则像缺字）', (tester) async {
      await _pump(tester, <ChatMsg>[_thoughtDone(_longThought)], running: false);

      expect(find.byType(ShaderMask), findsNothing,
          reason: '文字已经完整了，淡掉反而像丢字');
    });
  });

  group('结束后收成一行摘要（对标 tool_call_process_preview）', () {
    testWidgets('长思考 → 只占一行「思考了 12 秒」', (tester) async {
      await _pump(tester, <ChatMsg>[_thoughtDone(_longThought)], running: false);

      expect(find.text('思考了 12 秒'), findsOneWidget);
      // 正文不占版面了：末尾那句只有全文渲染才看得到。
      expect(find.textContaining('decide whether hiding is needed'), findsNothing,
          reason: '结束后版面只应留一行摘要');
      expect(find.text('展开'), findsOneWidget);
    });

    testWidgets('点「展开」→ 全文回来，还能「收起」', (tester) async {
      await _pump(tester, <ChatMsg>[_thoughtDone(_longThought)], running: false);

      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();

      expect(find.textContaining('decide whether hiding is needed'), findsOneWidget,
          reason: '点开必须还能看到全文');
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('没有时间戳 → 只写「思考」，不编时间', (tester) async {
      await _pump(tester, <ChatMsg>[_thought(_longThought)], running: false);

      expect(find.text('思考'), findsOneWidget);
      expect(find.textContaining('思考了'), findsNothing,
          reason: '拿不到真实时长就不能编一个"思考了 0 秒"出来');
    });

    testWidgets('短思考不受影响（还是显示全文）', (tester) async {
      await _pump(tester, <ChatMsg>[_thoughtDone('想了一下。', seconds: 3)],
          running: false);

      expect(find.text('想了一下。'), findsOneWidget);
      expect(find.text('思考了 3 秒'), findsNothing,
          reason: '短思考不值得折成一行 —— 折了反而只剩一个标签，正文没了');
    });
  });
}
