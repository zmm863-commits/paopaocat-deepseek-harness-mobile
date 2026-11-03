import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'android_toolbox.dart';
import 'dsh_runtime.dart';
import 'diagnostics_log.dart';

/// 三条免 Key 上游的标识（本地代理靠**路径前缀**分流，见 `zen-proxy.mjs`）。
///
/// 为什么用枚举而不是两个 bool：三条通道时 `kilo: true, ovh: false` 这种写法
/// 读起来就是灾难，而且加第四条会更糟。枚举让"走哪条"只有一个地方说清。
enum ZenLane {
  /// OpenCode Zen（要伪装成官方 CLI，否则 403）。前缀空串 = `/v1/*`。
  zen(''),

  /// Kilo AI 公共网关（免 Key 免伪装）。前缀 `/kilo`。
  kilo('/kilo'),

  /// OVHcloud AI Endpoints（免 Key 免伪装）。前缀 `/ovh`。
  ovh('/ovh');

  const ZenLane(this.prefix);

  /// 路径前缀（`''` / `/kilo` / `/ovh`）—— 拼进 `…${prefix}/v1/models`。
  final String prefix;
}

/// 「社区免费通道」的本地代理 —— 把 DSH 的请求转发到 OpenCode Zen 的匿名免费通道。
///
/// ## ⚠️ 这是什么（不要在界面/文档里含糊过去）
///
/// 上游的免费层**只给自家 CLI 用**（非官方会话形状会被 403 拒掉），这个代理做的是
/// **把请求伪装成官方 CLI 的形状**去通过那道门禁。所以它是：
///   * **默认关闭**、必须用户**在设置里显式打开**的灰色能力；
///   * **不需要任何 Key** —— 上游那条通道本来就是匿名的，凭据是公开的字面量
///     `public`，由本代理自己带上（调用方给的那个占位 Authorization 会被覆盖）；
///   * **不做** IP 轮换、不做重试轰炸（那是真正的滥用放大器，本项目不实现）；
///   * **随时可能失效** —— 上游历史上已经收紧过两次，界面必须如实标注。
///
/// 实现照 `RotationProxy` 那一套（同一个理由：脚本在 toolbox 里，端口由系统挑、
/// 从就绪行回填）：`assets/toolbox/zen-proxy.mjs`。
class ZenProxy {
  ZenProxy._();

  /// 全局单例：同一时刻只该有一个代理。
  static final ZenProxy instance = ZenProxy._();

  Process? _proc;
  int? _port;

  int? get port => _port;
  bool get running => _proc != null && _port != null;

  /// 确保代理在跑，返回它**真正监听的端口**（系统挑的，不能自己猜）。
  ///
  /// 返回 null 表示起不来 —— 调用方要如实处理：**不要**把 overlay 指向一个
  /// 不存在的本地服务（那会让"打开开关"变成"所有模型都连不上"）。
  Future<int?> ensureRunning({required DshRuntime runtime}) async {
    if (running) return _port;

    await AndroidToolbox.ensureInstalled(runtime.filesDir);
    final script = '${runtime.toolboxDir}/zen-proxy.mjs';
    if (!File(script).existsSync()) {
      debugPrint('[dsh-zen] 代理脚本不存在：$script');
      DiagnosticsLog.add('[dsh-zen]', '代理脚本不存在，无法启动');
      return null;
    }

    final stateDir = '${runtime.filesDir}/zen';
    try {
      Directory(stateDir).createSync(recursive: true);
    } catch (_) {}

    Process? proc;
    try {
      proc = await runtime.spawn(<String>[
        script,
        '--port', '0',
        '--state', stateDir,
        // 缓存几小时就够：模型上下架不频繁，而且失败时还有静态兜底名单。
        '--ttl-hours', '12',
      ]);
    } catch (e) {
      debugPrint('[dsh-zen] 起代理失败：$e');
      DiagnosticsLog.add('[dsh-zen]', '起代理失败：$e');
      return null;
    }

    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    final ready = Completer<int>();
    final outTee = DiagnosticsLineTee('dsh-zen:out');
    final errTee = DiagnosticsLineTee('dsh-zen:err');

    proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      outBuf.write(chunk);
      outTee.feed(chunk);
      if (!ready.isCompleted) {
        // ⚠️ 格式由 zen-proxy.mjs 约定：`listening on http://127.0.0.1:<port>`
        final m = RegExp(r'listening on http://127\.0\.0\.1:(\d+)')
            .firstMatch(outBuf.toString());
        if (m != null) ready.complete(int.parse(m.group(1)!));
      }
    }, onError: (_) {});
    proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      errBuf.write(chunk);
      errTee.feed(chunk);
    }, onError: (_) {});
    unawaited(proc.exitCode.then((code) {
      if (!ready.isCompleted) {
        ready.completeError(StateError(
            '代理提前退出（code=$code）。stdout=$outBuf stderr=$errBuf'));
      }
      _proc = null;
      _port = null;
    }));

    try {
      final port = await ready.future.timeout(const Duration(seconds: 15));
      _proc = proc;
      _port = port;
      DiagnosticsLog.add('[dsh-zen]', '代理已就绪：127.0.0.1:$port');
      return port;
    } catch (e) {
      debugPrint('[dsh-zen] 代理没起来：$e');
      DiagnosticsLog.add('[dsh-zen]', '代理没起来：$e');
      try {
        proc.kill();
      } catch (_) {}
      _proc = null;
      _port = null;
      return null;
    }
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    _port = null;
    if (p == null) return;
    try {
      p.kill();
    } catch (_) {}
  }

  /// 取免费模型列表（代理会只列免费的）。
  ///
  /// [lane] 决定走哪条上游：Zen（要伪装）/ Kilo / OVHcloud（两条公共网关，免 Key
  /// 免伪装）。三条共用一个本地端口，靠路径前缀分流（见 `zen-proxy.mjs`）。
  /// 各条互不牵连：一条挂了，另一条照常返回自己的列表。
  ///
  /// 失败返回空列表并打日志 —— **绝不编造模型名**（编了等于给用户一个选了就报错的模型）。
  Future<List<String>> fetchFreeModels(int port, {ZenLane lane = ZenLane.zen}) async {
    final path = '${lane.prefix}/v1/models';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port$path'))
          .timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[dsh-zen] 取模型列表 HTTP ${resp.statusCode}（${lane.name}）');
        return const <String>[];
      }
      final json = jsonDecode(body);
      final data = (json is Map) ? json['data'] : null;
      if (data is! List) return const <String>[];
      return <String>[
        for (final m in data)
          if (m is Map && m['id'] is String) m['id'] as String,
      ];
    } catch (e) {
      debugPrint('[dsh-zen] 取模型列表失败（${lane.name}）：$e');
      return const <String>[];
    } finally {
      client.close(force: true);
    }
  }

  /// 逐个测试一批模型此刻**真的能不能对话**，只返回能用的那些。
  ///
  /// ## 为什么要测
  ///
  /// 上游给的 `/models` 列表里常有**已经退役/被限流**的模型 —— 列表有它，
  /// 真发对话却报错。用户 2026-10-31 明确要求：「直列可以使用的模型，
  /// ping 不通不列，但要告诉用户测了多少个、多少个可用」。
  ///
  /// ## 怎么测
  ///
  /// 给每个模型发一句**最小对话**（`max_tokens: 1`），只看能不能拿到
  /// HTTP 2xx。用并发跑（一批 4 个）—— 逐个串行 20 个模型要几十秒，
  /// 用户等不起。
  ///
  /// [lane] 决定走哪条上游的路径前缀（与 [fetchFreeModels] 一致）。
  /// 返回 `(可用的模型, 测试总数)`。
  Future<({List<String> alive, int tested})> pingModels(
    int port,
    List<String> models, {
    ZenLane lane = ZenLane.zen,
  }) async {
    if (models.isEmpty) return (alive: const <String>[], tested: 0);
    final path = '${lane.prefix}/v1/chat/completions';
    final alive = <String>[];

    Future<bool> one(String model) async {
      // ⚠️ 超时收短（2026-11-03 真机反馈「初始化特别慢」）：
      // 免费端点正常情况下 1~2 秒就回；等 6+12 秒的只可能是已经挂掉的那批。
      // 48 个模型里但凡有十来个这种，原来的超时会让启动多等好几分钟。
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      try {
        final req = await client
            .postUrl(Uri.parse('http://127.0.0.1:$port$path'))
            .timeout(const Duration(seconds: 4));
        req.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        req.write(jsonEncode(<String, Object?>{
          'model': model,
          'messages': <Map<String, String>>[
            {'role': 'user', 'content': 'hi'},
          ],
          'max_tokens': 1,
          'stream': false,
        }));
        final resp = await req.close().timeout(const Duration(seconds: 8));
        // 只要 2xx —— 4xx/5xx 都算"这个模型此刻用不了"。
        return resp.statusCode >= 200 && resp.statusCode < 300;
      } catch (_) {
        return false;
      } finally {
        client.close(force: true);
      }
    }

    // 每批 12 个并发（原来是 4）。
    //
    // ⚠️ 为什么改（2026-11-03 真机反馈）：三条通道合并后要测的模型从 22 涨到 48，
    //    4 个一批 = 12 批，每批最坏 18 秒 → 启动能被拖到一分多钟。
    //    这些请求打在**本机代理**上、再由代理发往各上游，代理本身是异步的，
    //    12 个一批不会把上游惹毛（真正限流的是各家自己的配额）。
    const int batch = 12;
    for (var i = 0; i < models.length; i += batch) {
      final chunk = models.sublist(
          i, i + batch > models.length ? models.length : i + batch);
      final results = await Future.wait(chunk.map(one));
      for (var j = 0; j < chunk.length; j++) {
        if (results[j]) alive.add(chunk[j]);
      }
    }
    debugPrint('[dsh-zen] ping 了 ${models.length} 个模型，${alive.length} 个可用');
    return (alive: alive, tested: models.length);
  }

  /// 健康检查（界面用来显示"通道现在通不通、上次什么错"）。
  Future<({bool ok, int models, String? lastError})?> health(int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/healthz'))
          .timeout(const Duration(seconds: 8));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(body);
      if (json is! Map) return null;
      return (
        ok: json['ok'] == true,
        models: (json['models'] is int) ? json['models'] as int : 0,
        lastError: json['lastError'] is String ? json['lastError'] as String : null,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
