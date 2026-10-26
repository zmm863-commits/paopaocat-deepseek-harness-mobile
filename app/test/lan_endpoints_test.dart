import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/local/lan_endpoints.dart';

/// 「电脑访问」的地址发现层：只验证**不误报**和**不崩**。
///
/// 真机上真正的判定（这台电脑连不连得上）只能插线验证，这里能守住的底线是：
/// 绝不把回环 / 链路本地 / 蜂窝数据当成「电脑能连的地址」返回 —— 否则用户会选到
/// 一个看着有地址、电脑永远打不开的接口，然后以为是 App 坏了。
void main() {
  test('列出的地址都不是回环、不是链路本地', () async {
    final eps = await LanEndpoints.list();
    for (final e in eps) {
      expect(e.address, isNotEmpty);
      expect(e.address.startsWith('127.'), isFalse,
          reason: '回环地址不该出现在对外候选里：${e.display}');
      expect(e.address, isNot('0.0.0.0'));
      expect(e.address.startsWith('169.254.'), isFalse,
          reason: '链路本地地址电脑连不上：${e.display}');
      expect(e.kind, anyOf('usb', 'wifi', 'other'));
      expect(e.interfaceName, isNotEmpty);
    }
  });

  test('不抛异常，结果类型稳定', () async {
    final eps = await LanEndpoints.list();
    expect(eps, isA<List<LanEndpoint>>());
    // 顺序约定：USB 共享优先（这个功能的目标场景就是一根线接陌生电脑）。
    const rank = {'usb': 0, 'wifi': 1, 'other': 2};
    for (var i = 1; i < eps.length; i++) {
      expect(rank[eps[i - 1].kind]! <= rank[eps[i].kind]!, isTrue,
          reason: '排序应满足 usb → wifi → other，实际：${eps.map((e) => e.display)}');
    }
  });

  test('preferred 与 list 的第一个一致', () async {
    final all = await LanEndpoints.list();
    final one = await LanEndpoints.preferred();
    if (all.isEmpty) {
      expect(one, isNull);
    } else {
      expect(one?.address, all.first.address);
      expect(one?.kind, all.first.kind);
    }
  });

  test('display 里带上网卡名（真机对不上时要靠它认人）', () async {
    final eps = await LanEndpoints.list();
    for (final e in eps) {
      expect(e.display, contains(e.address));
      expect(e.display, contains(e.interfaceName));
    }
  });

  test('本机能枚举出至少一个非回环地址（跑测试的机器不是孤岛）', () async {
    // 这条是环境自检：如果 CI/容器里一条网卡都没有，说明测试环境本身不对，
    // 而不是实现有问题 —— 让它显式失败，别静默通过。
    final eps = await LanEndpoints.list();
    expect(eps.isNotEmpty, isTrue,
        reason: '本机枚举不到任何非回环 IPv4，检查测试环境网络');
    expect(Platform.isAndroid || Platform.isLinux || Platform.isMacOS ||
        Platform.isWindows, isTrue);
  });
}
