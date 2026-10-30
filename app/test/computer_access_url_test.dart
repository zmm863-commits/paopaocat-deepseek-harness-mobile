import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/ui/widgets/computer_access_url.dart';

/// 「对外地址」的**唯一出处** + 一道源码门禁。
///
/// 由来（2026-10-30 真机，用户实测）：
/// 0.81 把 `_apply()`（拨开关那一刻）改成了用 App 的固定口令，但 `_load()`
/// （离开页面再进来 / App 重启后恢复显示）**没改**，那里还在用 DSH 的
/// launchToken。于是用户重进面板复制到的地址，电脑上打开就是
/// `dsh web authentication required; reopen the URL printed by dsh web.`
///
/// 两处各写一遍必然会再分叉 —— 所以收敛成 `publicDshUrl()`，并加门禁：
/// 面板里**不许再手拼** `_url`。
void main() {
  group('publicDshUrl', () {
    test('固定口令（32 位十六进制）原样拼进去', () {
      final url = publicDshUrl(
        host: '192.168.3.196',
        port: 36979,
        token: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
      );
      expect(url, 'http://192.168.3.196:36979/?token=a1b2c3d4e5f60718293a4b5c6d7e8f90');
    });

    test('地址里只带一个 token 参数（不重复、不拼接）', () {
      final url = publicDshUrl(
        host: '10.0.0.9',
        port: 38012,
        token: 'deadbeefdeadbeefdeadbeefdeadbeef',
      );
      expect(RegExp('token=').allMatches(url).length, 1);
      expect(url, isNot(contains('token=token=')));
      expect(url, isNot(contains('&&')));
    });

    test('token 为空时不给半截地址（宁可露出异常，也不要一个静默 401 的链接）', () {
      final url = publicDshUrl(host: '10.0.0.9', port: 38012, token: '  ');
      expect(url, 'http://10.0.0.9:38012/');
      expect(url, isNot(contains('token=')));
    });

    test('带前后空格的口令会被修掉（复制粘贴很容易带上）', () {
      final url = publicDshUrl(host: 'h', port: 1, token: ' deadbeef ');
      expect(url, 'http://h:1/?token=deadbeef');
    });
  });

  group('源码门禁：地址只能从 publicDshUrl 出', () {
    test('computer_access_panel.dart 里不许再手拼 `_url = \'http://…\'`', () {
      final src = File(
        'lib/ui/widgets/computer_access_panel.dart',
      ).readAsStringSync();

      // 手拼的两种历史写法都要挡：
      //   `_url = 'http://…'`  以及用 `queryParameters['token']` 自己算 token
      final handBuilt = RegExp(r"_url\s*=\s*'http://").hasMatch(src);
      expect(handBuilt, isFalse,
          reason: '对外地址必须由 publicDshUrl() 生成 —— 手拼正是 2026-10-30 那个 401 的来源');

      final manualToken = RegExp(
        r"_url\s*=[\s\S]{0,120}?queryParameters\['token'\]",
      ).hasMatch(src);
      expect(manualToken, isFalse,
          reason: 'URL 里的 token 必须是 BridgePrefs.token（固定口令），不是 DSH 的 launchToken');
    });

    test('面板确实调用了 publicDshUrl（至少两处：拨开时 + 恢复显示时）', () {
      final src = File(
        'lib/ui/widgets/computer_access_panel.dart',
      ).readAsStringSync();
      final calls = RegExp(r'publicDshUrl\(').allMatches(src).length;
      expect(calls, greaterThanOrEqualTo(2),
          reason: '_apply 与 _load 两条路径都要用它，少一处就会再分叉');
    });
  });
}
