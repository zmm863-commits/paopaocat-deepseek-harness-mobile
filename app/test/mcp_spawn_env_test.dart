import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 起 node 的三处，**启动方式必须一致**。
///
/// ## 由来（2026-10-31，0.82 的 P0）
///
/// 0.81 及以前，App 里有三个地方 spawn 那个 `libnode.so`：
///
/// | 位置 | 干什么 | 当时带父环境吗 |
/// |---|---|---|
/// | `bot_server.dart` | 起 DSH 主进程 | ✅ |
/// | `acp_client.dart` | 起 ACP 会话 | ✅ |
/// | **`local_mcp.dart`** | **探活 mcp-office** | ❌（只有白名单） |
///
/// 唯一不带父环境的那处，恰恰要拉起同一个 node。Android 上缺 `ANDROID_ROOT` /
/// `BOOTCLASSPATH` 这类系统变量时，node **静默退出**（`exit=0`、stderr 空）——
/// 于是探活永远失败、`mcpServers()` 不挂、Office 三个工具永远不出现。
///
/// 真机症状：`探活失败：node 提前退出 exit=0`，一个字报错都没有。
///
/// 讽刺的是那处代码上原本写着「刻意不加，探活必须与运行时一致」——
/// **方向对、结论反了**：运行时本来就是「白名单 + 父环境」，纯白名单的那一方才是不一致的。
///
/// 所以把「三处必须同构」钉成门禁：以后再有人给某处单独改启动参数，这里立刻红。
void main() {
  const files = <String>[
    'lib/local/bot_server.dart',
    'lib/local/acp_client.dart',
    'lib/local/local_mcp.dart',
  ];

  test('每一处 Process.start 都带 includeParentEnvironment: true', () {
    for (final f in files) {
      final src = File(f).readAsStringSync();
      final starts = RegExp(r'Process\.start\(').allMatches(src).toList();
      expect(starts, isNotEmpty, reason: '$f 里找不到 Process.start，测点失效');
      for (final m in starts) {
        final window = src.substring(
            m.start, (m.start + 600).clamp(0, src.length));
        expect(window.contains('includeParentEnvironment: true'), isTrue,
            reason: '$f 在 offset ${m.start} 的那处 Process.start 没带父环境 —— '
                '漏掉的那处会让 node 在 Android 上静默退出（exit=0、无 stderr）');
      }
    }
  });

  test('探活不再用“纯白名单”那句旧理由（防回退）', () {
    final src = File('lib/local/local_mcp.dart').readAsStringSync();
    expect(src.contains('includeParentEnvironment: true'), isTrue);
    // 旧注释里那句断言是错的，留着会误导下一个人再把它删掉
    expect(src.contains('特意不给父环境'), isFalse,
        reason: '那条“不给父环境才一致”的推理是错的（运行时本来就带父环境），别写回去');
  });
}
