import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/ui/widgets/computer_access_selfcheck.dart';

/// 「连不上？点这里自检」的判定逻辑。
///
/// 起因（2026-10-31）：三天里三个用户报"连不上"，但真因分属完全不同的层 ——
///
/// | 用户看到的 | 真实故障层 |
/// |---|---|
/// | `INET_E_RESSOURCE_NOT_FOUND` | 浏览器没把地址当网址（**根本没连到手机**） |
/// | `ERR_CONNECTION_REFUSED` | 端口没人听（App 被冻结 / 转发器没起来） |
/// | `dsh web authentication required` | 连上了，口令不对 |
///
/// 三者解法完全不同，用户只会说"连不上"。这个自检把判定做成纯函数，
/// 于是这几种组合可以在这里钉死 —— 真机上没法稳定复现。
void main() {
  SelfCheckReport eval({
    bool forwardRunning = true,
    int? forwardPort = 36979,
    bool serverRunning = true,
    int? serverPort = 46063,
    String? host = '192.168.3.196',
    String token = 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
    bool tcpOk = true,
    int? tokenStatus = 303,
    Object? tcpError,
  }) =>
      evaluateSelfCheck(
        forwardRunning: forwardRunning,
        forwardPort: forwardPort,
        serverRunning: serverRunning,
        serverPort: serverPort,
        host: host,
        token: token,
        tcpOk: tcpOk,
        tokenStatus: tokenStatus,
        tcpError: tcpError,
      );

  group('全绿', () {
    test('303 = 一切正常，并给出可复制的完整地址', () {
      final r = eval();
      expect(r.hasFailure, isFalse);
      expect(r.url, 'http://192.168.3.196:36979/?token=a1b2c3d4e5f60718293a4b5c6d7e8f90');
    });

    test('200 算通过但带 warn（能连，只是没走"口令换 cookie"）', () {
      final r = eval(tokenStatus: 200);
      expect(r.hasFailure, isFalse, reason: '200 不该判成故障');
      expect(r.items.any((i) => i.warn), isTrue, reason: '要留一条"值得看一眼"');
    });
  });

  group('逐层故障', () {
    test('开关没开 → 立刻收手，不再往下探', () {
      final r = eval(forwardRunning: false, forwardPort: null);
      expect(r.hasFailure, isTrue);
      expect(r.items.length, 1, reason: '开关没开时探端口/回环没有意义');
      expect(r.tips.first, contains('开关'));
    });

    test('转发器没起来 → 指出"没有端口"', () {
      final r = eval(forwardPort: null);
      expect(r.hasFailure, isTrue);
      expect(r.items.any((i) => i.label == '监听端口' && !i.ok), isTrue);
      expect(r.tips.any((t) => t.contains('关掉再打开')), isTrue);
    });

    test('DSH 服务没跑 → 说明"转发器会空转"', () {
      final r = eval(serverRunning: false, serverPort: null);
      expect(r.items.any((i) => i.label.contains('DSH') && !i.ok), isTrue);
      expect(r.tips.any((t) => t.contains('发一条消息')), isTrue);
    });

    test('本地回环连不上 → 直接判"转发器进程死了"', () {
      final r = eval(tcpOk: false, tokenStatus: null, tcpError: 'Connection refused');
      expect(r.hasFailure, isTrue);
      expect(r.items.any((i) => i.label == '本地回环' && !i.ok), isTrue);
      expect(r.tips.any((t) => t.contains('转发器进程')), isTrue);
    });

    test('401 → 明确说"口令不对"，并给出重置的动作', () {
      final r = eval(tokenStatus: 401);
      expect(r.hasFailure, isTrue);
      expect(r.items.any((i) => i.label == '带口令访问' && !i.ok), isTrue);
      expect(r.tips.any((t) => t.contains('重置口令')), isTrue);
    });

    test('请求没回音（null）→ 提示"可能还在启动"', () {
      final r = eval(tokenStatus: null);
      expect(r.hasFailure, isTrue);
      expect(r.tips.any((t) => t.contains('等 10 秒')), isTrue);
    });
  });

  group('给用户的提醒', () {
    test('全绿时才会给出电脑侧三步（否则说了也没用）', () {
      final ok = eval();
      expect(ok.tips.any((t) => t.contains('ping')), isTrue);
      expect(ok.tips.any((t) => t.contains('http://')), isTrue);
      expect(ok.tips.any((t) => t.contains('粘贴')), isTrue);

      final bad = eval(tokenStatus: 401);
      expect(bad.tips.any((t) => t.contains('ping')), isFalse,
          reason: '手机这一侧都没通，教他排查电脑只会浪费时间');
    });

    test('地址里的 token 原样带出（错一个字符就变成"找不到主机"）', () {
      final r = eval(token: 'deadbeefdeadbeefdeadbeefdeadbeef');
      expect(r.url, contains('token=deadbeefdeadbeefdeadbeefdeadbeef'));
      expect(RegExp('token=').allMatches(r.url!).length, 1);
    });
  });
}
