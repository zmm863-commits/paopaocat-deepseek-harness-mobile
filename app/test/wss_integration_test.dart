/// wss 集成测试：证明 App 的 TLS + 指纹 pin **真的工作**。
///
/// 前置：
///   1. 桥以 wss 模式运行在 127.0.0.1:8790（bridge/tls/bridge.pfx 存在）
///   2. 指纹文件 bridge/tls/fingerprint.txt 可读
///
/// 运行：flutter test test/wss_integration_test.dart
///
/// 这个测试的价值在于它验证的是**否定情形**：指纹不对时必须拒绝连接。
/// 只验证"正确指纹能连上"是不够的——那等于没验证 pin。
///
/// ⚠️ 2026-10-05：前置不满足时改为 **skip**（原来直接 fail）。
/// 原因：迁移到 Linux 后，原来写死的 Windows 绝对路径必然不存在，
/// 于是每次 `flutter test` 都会稳定报 2 条假失败，掩盖真正的回归。
/// 现在指纹文件按「环境变量 → 相对路径 → 原 Windows 路径」逐个探测，
/// 一个都找不到就显式 skip 并说明怎么补前置。
library;

import 'dart:io';

import 'package:dsh_mobile/protocol/bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';

const String kHost = '127.0.0.1';
const int kPort = 8790;

/// 指纹文件候选路径。
///
/// 测试运行于 ASCII 构建副本（如 /tmp/dsh-app），所以相对路径不一定命中；
/// 用环境变量 `DSH_BRIDGE_FINGERPRINT` 可以显式指定。
String? locateFingerprintFile() {
  final env = Platform.environment['DSH_BRIDGE_FINGERPRINT'];
  final candidates = <String>[
    if (env != null && env.isNotEmpty) env,
    'bridge/tls/fingerprint.txt',
    '../bridge/tls/fingerprint.txt',
    r'D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹\dsh-mobile\bridge\tls\fingerprint.txt',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

void main() {
  final fingerprintPath = locateFingerprintFile();

  /// 桥服务在不在线（2026-11-02 加）。
  ///
  /// 为什么要有这一步：这组测试要连**真的 wss 桥**（127.0.0.1:8790），
  /// 但本机常常只有证书、没有跑桥（桥是桌面版起的服务）。以前只看
  /// "指纹文件在不在"就决定跑不跑，于是证书在、服务没起 → 测试**必红**，
  /// 而红的原因跟被测代码毫无关系。
  ///
  /// 现在多问一句"端口通不通"：不通就跳过并说明，别把环境问题伪装成代码问题。
  bool bridgeOnline() {
    // 本机 127.0.0.1 不通时 connectSync 会立刻 ECONNREFUSED，不会挂住。
    RawSynchronousSocket? sock;
    try {
      sock = RawSynchronousSocket.connectSync(kHost, kPort);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        sock?.closeSync();
      } catch (_) {}
    }
  }

  final skipReason = fingerprintPath == null
      ? '未找到 bridge/tls/fingerprint.txt（先运行 install/gen-tls-cert.ps1 生成 TLS 证书；'
          '或用环境变量 DSH_BRIDGE_FINGERPRINT 指定绝对路径）'
      : (bridgeOnline()
          ? null
          : '桥服务没在本机运行（$kHost:$kPort 连不上）—— 这组测试要连真桥，'
              '先起桥再跑；纯代码改动不需要它');

  late String realFingerprint;

  setUpAll(() {
    if (fingerprintPath != null) {
      realFingerprint = File(fingerprintPath).readAsStringSync().trim();
    }
  });

  test('正确指纹可以连上 wss 桥', () async {
    expect(realFingerprint, isNotEmpty);
    final logs = <String>[];
    final client = BridgeClient(
      host: kHost,
      port: kPort,
      useTls: true,
      fingerprint: realFingerprint,
      onLog: logs.add,
    );
    try {
      await client.connect();
      expect(client.isConnected, isTrue, reason: '正确指纹应能连上，日志：$logs');
    } finally {
      await client.disconnect();
    }
  }, skip: skipReason);

  test('错误指纹必须被拒绝（pin 生效）', () async {
    // 一个格式合法但与桥不一致的指纹
    const wrong =
        'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';
    final logs = <String>[];
    final client = BridgeClient(
      host: kHost,
      port: kPort,
      useTls: true,
      fingerprint: wrong,
      onLog: logs.add,
    );
    try {
      await expectLater(
        client.connect(),
        throwsA(anything),
        reason: '指纹不匹配时必须拒绝连接，否则 pin 形同虚设；日志：$logs',
      );
      expect(client.isConnected, isFalse);
    } finally {
      await client.disconnect();
    }
  }, skip: skipReason);

  // 这一条不依赖桥，纯本地校验，任何环境都能跑。
  test('wss 模式下不提供指纹应直接抛错', () async {
    final client = BridgeClient(host: kHost, port: kPort, useTls: true);
    await expectLater(client.connect(), throwsA(isA<StateError>()));
  });
}
