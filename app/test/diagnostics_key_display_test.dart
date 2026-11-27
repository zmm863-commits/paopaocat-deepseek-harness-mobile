/// KEY 段的**展示文本**必须保留数字 —— 那是出事现场。
///
/// 事故来源（2026-11-27 真机报告 `dsh-report-20261127-112328.txt`）：
/// 用户那份配置里有一个名叫「7API」的厂家，`envNameFor()` 算出 `7API_API_KEY`，
/// 引擎的 `credentialRef()` 直接抛
///   `TypeError: credential ref "7API_API_KEY" must match /^[A-Za-z_][A-Za-z0-9_]*$/`
/// → 整条 `llm-pi-ai` 不激活 → 所有模型没有适配器 → `session/new: Internal error`。
///
/// 而报告 KEY 段当时把它显示成 `#API_API_KEY`、把正则显示成 `[A-Za-z#-#_]` ——
/// **数字被抹掉，结论就没了**，只能在 DETAIL 段里翻到原文。所以这里钉两件事：
///   ① 展示保留数字（`normalizeForDisplay`，只压空白、超长截断）；
///   ② 聚合仍然按「数字归一」分组（`HTTP 400` / `HTTP 401` 要并成一组），
///      但组里显示的是**第一次出现时的原文**。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/local/diagnostics_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<String> lines() => <String>[
        '11:21:32.019 [print:chat] [acp:stderr] dsh: warning: 1 entry did not activate',
        '11:21:32.020 [print:chat] [acp:stderr] llm-pi-ai: TypeError: credential ref '
            '"7API_API_KEY" must match /^[A-Za-z_][A-Za-z0-9_]*\$/',
        '11:22:59.139 [print:chat] [acp] session/new 失败，服务端完整返回：'
            '{"code":-32603,"message":"Internal error","data":{"details":'
            '"no adapter registered for provider \\"custom\\""}}',
      ];

  test('KEY 段保留数字：7API_API_KEY 不能显示成 #API_API_KEY', () {
    final events = DiagnosticsLog.keyEventsFrom(lines());
    final text = events.map((e) => e.msg).join('\n');
    expect(text, contains('7API_API_KEY'));
    expect(text, isNot(contains('#API_API_KEY')));
    expect(text, contains('no adapter registered for provider'), reason: '真正的线索不能丢');
    expect(text, contains('Internal error'));
  });

  test('正则里的字符类也要原样保留', () {
    final events = DiagnosticsLog.keyEventsFrom(lines());
    final text = events.map((e) => e.msg).join('\n');
    expect(text, contains('[A-Za-z0-9_]'));
    expect(text, isNot(contains('[A-Za-z#-#_]')));
  });

  test('聚合仍按数字归一：只有数字不同的两条并成一组（次数=2）', () {
    final events = DiagnosticsLog.keyEventsFrom(<String>[
      '10:00:00.000 [print:dsh-models] 连通性测试失败 HTTP 400 url=https://a.example.com/c',
      '10:00:05.000 [print:dsh-models] 连通性测试失败 HTTP 401 url=https://a.example.com/c',
    ]);
    expect(events, hasLength(1), reason: '只差状态码 → 应并成一条');
    expect(events.single.count, 2);
    expect(events.single.msg, contains('HTTP 400'),
        reason: '展示用第一次出现的原文，不该是 HTTP #');
  });

  test('超长正文会截断，但截断不影响可读的前缀', () {
    final long = 'x' * 400;
    final events = DiagnosticsLog.keyEventsFrom(<String>[
      '10:00:00.000 [print:chat] 加载失败：$long',
    ]);
    expect(events.single.msg.length, lessThanOrEqualTo(161));
    expect(events.single.msg, startsWith('加载失败：'));
    expect(events.single.msg, endsWith('…'));
  });
}
