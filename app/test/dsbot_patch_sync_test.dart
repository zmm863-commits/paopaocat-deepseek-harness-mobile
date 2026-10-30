import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ds-bot 网页补丁的**两份实现必须同步**。
///
/// 历史：同一套锚点写在两个地方 ——
///   · `app/lib/local/bot_server.dart` 的 `_botWebTrims`（手机端，App 每次启动补）
///   · `install/patch-dsbot-web.mjs` 的 `EDITS`（本机网页版 + 运行时种子里手工补）
///
/// 它们共享同一个幂等标记 `/* dshm-web-trim:1,2,… *&#47;`。**一旦条数分叉**，
/// 手机上就会出现这种最难查的局面：标记说 1..9 已应用，而 Dart 那边有 10 条，
/// 第 10 条的原文却早被 mjs 换掉了 → `missed` 非空 → **整批放弃**，
/// 用户看到的是「补丁打了跟没打一样」，而且没有任何报错。
///
/// 所以把「条数一致」钉成门禁。新增一条时必须两边一起加。
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('Dart 的 _botWebTrims 与 mjs 的 EDITS 条数一致', () {
    final dart = read('lib/local/bot_server.dart');
    final start = dart.indexOf('static const List<List<String>> _botWebTrims');
    expect(start, greaterThan(0), reason: '找不到 _botWebTrims');
    final body = dart.substring(start, dart.indexOf('\n  ];', start));
    final dartCount = RegExp(r'<String>\[').allMatches(body).length;

    final mjs = read('../install/patch-dsbot-web.mjs');
    final es = mjs.indexOf('const EDITS = [');
    expect(es, greaterThan(0), reason: '找不到 EDITS');
    final mjsBody = mjs.substring(es, mjs.indexOf('\n]', es));
    // 每条以「  [」开头的三行三元组 —— 数一下「  [」的出现次数
    final mjsCount = RegExp(r'^  \[$', multiLine: true).allMatches(mjsBody).length;

    expect(dartCount, mjsCount,
        reason: '两边条数不一致（Dart=$dartCount, mjs=$mjsCount）—— '
            '分叉会让手机端整批放弃补丁，而且不报错');
  });

  test('第 10 条（App 的 ⋯ →「设置」靠它）两边都在', () {
    final dart = read('lib/local/bot_server.dart');
    final mjs = read('../install/patch-dsbot-web.mjs');
    // 用钩子名做锚点：它是这条补丁的独特产物，两边都必须出现
    expect(dart.contains('__dshmOpenBotSettings'), isTrue,
        reason: 'Dart 侧缺这条 —— 手机上点「设置」会退化成 DOM 兜底');
    expect(mjs.contains('__dshmOpenBotSettings'), isTrue, reason: 'mjs 侧缺这条');
  });

  test('Bot 页 ⋯ 菜单里有「设置」，且排在「重新启动」后面', () {
    final src = read('lib/ui/pages/bot_page.dart');
    final iRetry = src.indexOf("child: Text('重新启动')");
    final iSet = src.indexOf("child: Text('设置')");
    expect(iRetry, greaterThan(0), reason: '找不到「重新启动」菜单项');
    expect(iSet, greaterThan(iRetry),
        reason: '用户 2026-10-30 指定：设置必须在「重新启动」下面');
    expect(src.contains('_openBotSettings'), isTrue);
    expect(src.contains('runJavaScript'), isTrue,
        reason: '要靠 WebView 调网页里的 openSettings，不能自己造一个设置页');
  });
}
