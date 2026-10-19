/// 发版口径的门禁：`kAppVersion` / changelog / pubspec 三者必须自洽。
///
/// 为什么值得单独一条测试：这三处的漂移**不会让任何东西坏掉** —— 编译过、测试过、
/// 包也能装，只是用户在「更新说明」里看到的是别的版本，或者新包 versionCode 没涨
/// 导致**装不上**（Android 只允许版本码更大的包覆盖安装，且报错很难懂）。
///
/// 真实发生过的事（2026-10-09 盘点）：`docs/需求台账.md` 停在 0.34、落后 22 版，
/// 而台账自己的规矩写着「必须与 changelog 对得上」。那类"记账坏了"的问题不会报错，
/// 只能靠门禁钉住 —— 台账本身跨仓库目录读不到，这里先钉住代码侧能自洽的三处。
library;

import 'dart:io';

import 'package:dsh_mobile/app_version.dart';
import 'package:dsh_mobile/data/changelog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('发版口径自洽（升版时必须三处同时改）', () {
    test('changelog 第一条就是 kAppVersion', () {
      expect(kChangelog, isNotEmpty);
      expect(kChangelog.first.version, kAppVersion,
          reason: 'kAppVersion 是 $kAppVersion，而更新说明第一条是 '
              '${kChangelog.first.version} —— 升版要两处一起改');
    });

    test('「当前版本」只能有一条，且就是第一条', () {
      final current = kChangelog.where((n) => n.status == '当前版本').toList();
      expect(current.length, 1,
          reason: '「当前版本」有 ${current.length} 条：'
              '${current.map((n) => n.version).join('、')} —— '
              '升版时别忘了把上一版改成「上一版（已交付）」');
      expect(current.single.version, kAppVersion);
    });

    test('版本号不重复（复制一条改一半最容易出这个错）', () {
      final seen = <String>{};
      for (final n in kChangelog) {
        expect(seen.add(n.version), isTrue, reason: '${n.version} 出现两次');
      }
    });

    test('kAppVersion 形如 0.NN（App 版本号一直是 0.x）', () {
      expect(RegExp(r'^0\.\d+$').hasMatch(kAppVersion), isTrue,
          reason: 'kAppVersion=$kAppVersion 不像这个项目的版本口径');
    });

    test('pubspec 的 version 与 kAppVersion 对齐，且 versionCode 跟着涨', () {
      final f = File('pubspec.yaml');
      expect(f.existsSync(), isTrue, reason: 'pubspec.yaml 不在当前目录');
      final line = f
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('version:'), orElse: () => '');
      expect(line, isNotEmpty, reason: 'pubspec.yaml 里没有 version: 行');

      // 期望形状：`version: 0.0.<minor>+<code>`。
      //   * 版本号那半必须等于 kAppVersion 的次版本号（0.77 → 0.0.77）；
      //   * build 号（= Android versionCode）**必须 ≥ 次版本号**，不是"必须相等"。
      //
      // 为什么是 ≥ 而不是 ==（2026-10-19 订正）：0.77 那一版发过好几个**预览包**，
      // 用的是递增的构建号 106 / 107 / 108（真机装的最后一个是 108）。Android 只允许
      // versionCode **更大**的包覆盖安装，而**卸载重装会连 App 私有目录一起删掉**
      // （模型配置、Bot 运行环境、会话全在里面）—— 所以正式 0.77 的 versionCode
      // 必须大于 108，绝不能为了对齐版本号退回 77。这里钉住真正的不变量：
      // 版本号对齐 + versionCode 不退（≥ 次版本号）。发布前请再核一眼它比上一个
      // 装出去的包大。
      final minor = int.parse(kAppVersion.split('.').last);
      final m = RegExp(r'^version:\s*0\.0\.(\d+)\+(\d+)$').firstMatch(line.trim());
      expect(m, isNotNull,
          reason: 'pubspec 写的是「${line.trim()}」，期望形状「version: 0.0.<次版本>+<构建号>」');
      expect(m!.group(1), minor.toString(),
          reason: 'pubspec 版本号是 0.0.${m.group(1)}，而 kAppVersion=$kAppVersion'
              ' → 版本号部分应该是 0.0.$minor');
      final code = int.parse(m.group(2)!);
      expect(code >= minor, isTrue,
          reason: 'pubspec 的 build 号是 $code，小于次版本号 $minor。'
              'versionCode 不涨的话，手机会拒绝覆盖安装');
    });
  });
}
