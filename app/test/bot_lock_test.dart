import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/local/bot_server.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';

/// Bot 团队单实例锁的清理（2026-10-30 真机 bug）。
///
/// 真机现象（用户原话）：
/// 「`/data/user/0/com.dshmobile.dsh_mobile/files/dshhome/bot` 里的 Bot 团队已在
/// 另一个 dsh 中打开（Web or Desktop, **pid 6982** on localhost）。这个窗口只能查看，
/// 不能修改；关掉另一个后刷新。」
///
/// 读完 `ds-bot/src/host/home-lock.js` 才定下来：它同主机时用
/// `process.kill(pid, 0)` 判活 —— **活着的 pid 就当成"另一个 dsh"**。
/// 而 Android 会复用 pid，6982 早就不是我们的进程了，于是 Bot 页被永久判成只读，
/// 用户还找不到那个"另一个 dsh"（它根本不存在）。
///
/// 手机端只可能有一个 DSH（BotServer 单例 + 重启前必先 stop 旧进程），
/// 所以启动前清掉这个锁是安全的。
void main() {
  DshRuntime runtimeAt(String dir) => DshRuntime(<String, dynamic>{
        'filesDir': dir,
        'nodeHome': '$dir/dshhome',
        'nodeBinary': '/x/libnode.so',
        'nativeLibDir': '/x',
      });

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('botlock');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  File lockFile() => File('${tmp.path}/dshhome/bot/state.lock');

  void writeLock(Object? body) {
    final f = lockFile();
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body is String ? body : jsonEncode(body));
  }

  test('锁文件在 → 启动前被删掉（不然 Bot 页永远是只读）', () async {
    writeLock(<String, Object?>{
      'pid': 6982, // 真机上那个被复用的 pid
      'host': 'localhost',
      'token': 'deadbeef',
      'since': 1,
    });
    expect(lockFile().existsSync(), isTrue);

    await BotServer.clearStaleBotLock(runtimeAt(tmp.path));

    expect(lockFile().existsSync(), isFalse);
  });

  test('没有锁文件时什么都不做（也不抛）', () async {
    await expectLater(
      BotServer.clearStaleBotLock(runtimeAt(tmp.path)),
      completes,
    );
    expect(lockFile().existsSync(), isFalse);
  });

  test('锁文件是半截 JSON（写一半被 kill）也删掉', () async {
    writeLock('{"pid":6982,"host":"local');
    await BotServer.clearStaleBotLock(runtimeAt(tmp.path));
    expect(lockFile().existsSync(), isFalse);
  });

  test('连调两次都安全（幂等）', () async {
    writeLock(<String, Object?>{'pid': 1, 'host': 'localhost'});
    await BotServer.clearStaleBotLock(runtimeAt(tmp.path));
    await expectLater(
      BotServer.clearStaleBotLock(runtimeAt(tmp.path)),
      completes,
    );
    expect(lockFile().existsSync(), isFalse);
  });

  test('bot 目录本身不被动（那里面是团队的 state.json，不能连坐）', () async {
    writeLock(<String, Object?>{'pid': 3, 'host': 'localhost'});
    final state = File('${tmp.path}/dshhome/bot/state.json')
      ..writeAsStringSync('{"bots":[]}');

    await BotServer.clearStaleBotLock(runtimeAt(tmp.path));

    expect(lockFile().existsSync(), isFalse, reason: '锁要删');
    expect(state.existsSync(), isTrue, reason: '团队数据一个字节都不许动');
    expect(state.readAsStringSync(), '{"bots":[]}');
  });
}
