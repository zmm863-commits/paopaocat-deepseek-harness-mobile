import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/configured_models.dart';
import '../state/provider_keys.dart';
import 'android_toolbox.dart';
import 'diagnostics_log.dart';
import 'dsh_runtime.dart';
import 'local_model_server.dart';
import 'rotate_log.dart';

/// 本地「模型轮换」代理（用户第 6 条反馈）：
/// 用户建一个组（例如 `cat`），组里放不同厂家的模型；DSH 调 `cat` 时，
/// 代理按顺序试，遇到 429/不可用就自动换下一个，直到全部试完。
///
/// ## 为什么要这么一个"本地代理"
///
/// DSH 只知道"某个 provider 的某个 model"，没有"模型组 + 故障转移"这个概念
/// （`@deepseek-ai/dsh-llm-retry` 只对**同一个** provider 做重试）。
/// 所以做法是：App 在本地起一个小 HTTP 服务，暴露 **OpenAI 兼容**的
/// `/v1/chat/completions`；overlay 里把 `rotate` 这个厂家指向
/// `http://127.0.0.1:<port>/v1`，模型名就是组名。
/// 于是"组"在 DSH 眼里就是一个普通模型，切换、显示都不用特殊照顾。
///
/// 真正的转发逻辑在 `assets/toolbox/rotate-proxy.mjs`（纯 node 内置模块）。
/// 这里负责：写配置、挑端口、起进程、等就绪、停止。
class RotationProxy {
  RotationProxy._();

  /// 全局单例：App 里同一时刻只该有一个轮换代理。
  static final RotationProxy instance = RotationProxy._();

  Process? _proc;
  int? _port;

  /// 上一次下发给代理的配置（含各厂家真实 Key，**只在内存里**）。
  /// 用来判断"配置有没有变" —— 代理只在启动时读一次配置，变了就得重启。
  String? _configJson;

  /// 不含凭据的状态文件（只放 lastGood）。stdin 模式下这是唯一落盘的东西。
  String? _statePath;

  /// 最近一次组装配置时，**因为没有可用成员而被剔掉**的组（含原因）。
  ///
  /// 存在的意义只有一个：让"池子不好使"这件事**可被解释**。用户看到的往往是
  /// 整个轮换组消失/连不上，而原因可能是组里唯一的那个免费模型已经被上游收回。
  List<String> _skippedGroups = const [];

  /// 给诊断日志/界面用：上次被剔掉的组（空 = 全部组都正常）。
  List<String> get skippedGroups => _skippedGroups;

  int? get port => _port;
  bool get running => _proc != null;

  /// 状态文件路径 —— 只有 `{'lastGood': {...}}`，**没有任何凭据**。
  String statePathFor(DshRuntime runtime) => '${runtime.toolboxDir}/rotate-state.json';

  /// 确保代理在跑（配置有变就重启），返回**它真正监听的端口**。
  ///
  /// 返回 null 表示"没有组"或"起不来"——调用方要如实处理：
  /// 起不来时**不要**把 overlay 指向一个不存在的本地服务。
  Future<int?> ensureRunning({
    required ConfiguredConfig cfg,
    required DshRuntime runtime,
  }) async {
    if (cfg.groups.isEmpty) {
      await stop();
      return null;
    }

    await AndroidToolbox.ensureInstalled(runtime.filesDir);
    if (!File(runtime.rotateProxyScriptPath).existsSync()) {
      debugPrint('[dsh-rotate] 代理脚本不存在：${runtime.rotateProxyScriptPath}');
      return null;
    }

    // ⚠️ 升级清理（审计 P0-2）：**旧版本**把含各厂家真实 Key 的配置写在这个文件名里，
    // 而它就在 `HOME` 下 —— 模型驱动的 shell 一条 `cat` 就能读走。
    // 新版本不再写它，但**已经装过老版本的手机会留着那份旧文件**：
    // 不删就等于"新洞堵了、旧洞还开着"。所以在确保代理运行时顺手删掉。
    final legacy = File('${runtime.toolboxDir}/rotate-config.json');
    try {
      if (legacy.existsSync()) {
        legacy.deleteSync();
        debugPrint('[dsh-rotate] 已删除旧版含 Key 的 rotate-config.json（P0-2 清理）');
        DiagnosticsLog.add('[dsh-rotate]', '已删除旧版含 Key 的 rotate-config.json');
      }
    } catch (e) {
      debugPrint('[dsh-rotate] 删除旧版配置失败（下次启动再试）：$e');
    }

    // 状态文件所在目录必须先存在，否则代理回写 lastGood 会失败（只影响"记住上次
    // 成功的成员"，不影响服务，但白丢一个优化）。
    try {
      final dir = Directory(runtime.toolboxDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (e) {
      debugPrint('[dsh-rotate] 建 toolbox 目录失败：$e');
    }

    final built = await _buildConfig(cfg: cfg, runtime: runtime);
    // 有组配置、但每一组都凑不出可用成员（模型被删 / 免费通道收回 / 本机服务
    // 没在跑）。**这时一个代理都不该起**：代理拿到空 groups 会直接拒绝退出，
    // 而调用方还会以为"轮换能用"。如实停掉、返回 null，并留下可解释的原因。
    if ((built['groups'] as Map).isEmpty) {
      debugPrint('[dsh-rotate] 所有轮换组都没有可用成员，代理不启动：'
          '${_skippedGroups.join('；')}');
      DiagnosticsLog.add(
          '[dsh-rotate]', '所有轮换组都没有可用成员，轮换不可用：${_skippedGroups.join('；')}');
      await stop();
      return null;
    }
    final configJson = jsonEncode(built);

    // 已经在跑且配置没变：直接复用（端口是系统挑的，不能自己猜）。
    if (_proc != null && _port != null && _configJson == configJson) {
      return _port;
    }
    // 配置变了 → **必须重启**。代理在启动时读一次配置，只重写文件它不会重读
    // （旧代码就是只重写文件、不重启，于是"改了池子成员但没生效"）。
    if (_proc != null) {
      debugPrint('[dsh-rotate] 组配置有变化，重启代理');
      await stop();
    }

    final port = await _start(runtime: runtime, configJson: configJson);
    if (port == null) return null;
    _port = port;
    _configJson = configJson;
    debugPrint('[dsh-rotate] 代理已就绪：127.0.0.1:$port（${cfg.groups.length} 个组，鉴权开）');
    return port;
  }

  /// 停掉代理（用户把组全删了、或 App 不再需要它）。
  Future<void> stop() async {
    final proc = _proc;
    _proc = null;
    _port = null;
    _configJson = null;
    if (proc == null) return;
    try {
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    debugPrint('[dsh-rotate] 代理已停止');
  }

  /// 组装下发给代理的配置。
  ///
  /// ⚠️ 这份对象**含各厂家真实 Key**，所以只允许经过 stdin 管道，
  /// **绝不写盘**（审计 P0-2）。磁盘上只留 [statePathFor] 那个只有 lastGood 的文件。
  Future<Map<String, dynamic>> _buildConfig({
    required ConfiguredConfig cfg,
    required DshRuntime runtime,
  }) async {
    final statePath = statePathFor(runtime);
    _statePath = statePath;
    return <String, dynamic>{
      'groups': await _buildGroups(cfg: cfg),
      // 令牌只经过管道 → 不进 argv（/proc/<pid>/cmdline 同 uid 可读），也不落盘。
      'token': DshRuntime.rotateToken,
      'lastGood': _readLastGood(statePath),
    };
  }

  /// 把 `lastGood`（"每组上次成功的成员下标"）从状态文件读回来。
  ///
  /// 为什么值得读：代理辛苦学到的"哪个成员能用"如果每次启动都清零，
  /// 下次请求又要从第一个（可能是坏的那个）重新试一遍，用户多等一轮失败。
  Map<String, dynamic> _readLastGood(String statePath) {
    try {
      final f = File(statePath);
      if (!f.existsSync()) return <String, dynamic>{};
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map && decoded['lastGood'] is Map) {
        final lg = Map<String, dynamic>.from(decoded['lastGood'] as Map);
        // 只认非负整数下标，别把坏数据喂给代理。
        return <String, dynamic>{
          for (final e in lg.entries)
            if (e.value is int && (e.value as int) >= 0) e.key: e.value,
        };
      }
    } catch (e) {
      debugPrint('[dsh-rotate] 读 lastGood 状态失败（忽略）：$e');
    }
    return <String, dynamic>{};
  }

  /// 组装 groups（成员列表）。
  Future<Map<String, dynamic>> _buildGroups({
    required ConfiguredConfig cfg,
  }) async {
    final groups = <String, dynamic>{};
    // 没有任何可用成员、被剔掉的组（及原因）。空组绝不能下发 —— 见下方注释。
    final skipped = <String>[];
    for (final g in cfg.groups) {
      final members = <Map<String, dynamic>>[];
      final missing = <String>[];
      for (final route in g.members) {
        // **本机模型（`local/<id>`）也能当池子成员**（用户 2026-10-07 要求）。
        // 它不在 models.json 里（是运行时才出现的虚拟厂家），所以不能走
        // `modelOfRoute`/`providerOf` 那套解析 —— 直接按"当前在跑的本机服务"给它端点。
        if (route.startsWith('${LocalModelSpec.providerId}/')) {
          final spec = LocalModelServer.instance.spec;
          if (spec == null) {
            // 本机服务没在跑：这条成员现在**转发不了**。
            // 不写一个假端点（那只会让用户在会话里收到一个看不懂的连接错误），
            // 而是跳过 + 留一条日志。
            debugPrint('[dsh-rotate] 池子 ${g.name} 里的本机成员 $route 暂时跳过'
                '（本机模型服务没在运行）');
            DiagnosticsLog.add(
                '[dsh-rotate]', '池子 ${g.name}：本机成员 $route 未加入（本机模型服务没在运行）');
            continue;
          }
          members.add(<String, dynamic>{
            'name': '${LocalModelSpec.providerId}/${spec.modelId}',
            'baseUrl': 'http://127.0.0.1:${spec.port}/v1',
            // 本机服务不校验 Key，但代理会带 Authorization 头 → 给个占位值。
            'apiKey': LocalModelSpec.apiKeyPlaceholder,
            'model': spec.modelId,
          });
          continue;
        }
        final m = cfg.modelOfRoute(route);
        if (m == null) {
          // 模型不在清单里了（被删 / 免费通道收回）→ 这个成员是"幽灵"。
          // 以前这里是**静默** continue，用户只会看到"池子不好使"却不知道为什么。
          missing.add('$route（模型已不在清单）');
          continue;
        }
        final prov = cfg.providerOf(m.provider);
        if (prov == null) {
          missing.add('$route（厂家已删除）');
          continue;
        }
        // Key 由 ProviderKeys（系统安全区）读出来，只进内存/管道。
        final key = await ProviderKeys.read(prov.id) ?? '';
        members.add(<String, dynamic>{
          'name': '${prov.id}/${m.id}',
          'baseUrl': prov.baseUrl,
          'apiKey': key,
          'model': m.id,
        });
      }
      // ⚠️ **空组绝不能下发给代理**（2026-10-31 用户报：
      //    「轮换池中间如果有无法使用的模型会造成整个轮换池无法使用」）。
      //    代理启动时校验配置，遇到 members 为空会拒绝**整份**配置并退出 →
      //    一个组没可用成员，其它组陪着一起挂。所以这里先把空组剔掉，
      //    只报一句日志；真的一个组都不剩，才由 ensureRunning 返回 null。
      if (members.isEmpty) {
        skipped.add(missing.isEmpty
            ? '${g.name}（组里没有成员）'
            : '${g.name}（${missing.join('、')}）');
        DiagnosticsLog.add('[dsh-rotate]',
            '池子 ${g.name} 没有任何可用成员，已跳过：${missing.join('、')}');
        continue;
      }
      if (missing.isNotEmpty) {
        DiagnosticsLog.add('[dsh-rotate]',
            '池子 ${g.name} 跳过了 ${missing.length} 个成员：${missing.join('、')}');
      }
      groups[g.name] = <String, dynamic>{'members': members};
    }
    _skippedGroups = skipped;
    return groups;
  }

  /// 起代理进程并等它就绪；成功返回**它真正监听的端口**，失败返回 null。
  ///
  /// 两个关键点（审计 P0-2 / P0-3）：
  ///   * 配置走 `--config-stdin`：含 Key，**不落盘**；
  ///   * `--port 0`：让系统挑空闲端口，**不再用固定的 39321~39330**
  ///     （固定端口 = 同机任何应用扫 10 个端口就能找到它）。
  ///     真实端口从代理的 stdout 就绪行里读回来，overlay 用这个值。
  Future<int?> _start({
    required DshRuntime runtime,
    required String configJson,
    bool withShims = true,
  }) async {
    Process? proc;
    final statePath = _statePath ?? statePathFor(runtime);
    try {
      proc = await runtime.spawn(<String>[
        runtime.rotateProxyScriptPath,
        '--config-stdin',
        '--state',
        statePath,
        '--port',
        '0',
        // 让代理把"这次用了哪个成员"写下来 —— 会话里要把它显示给用户
        // （用户要求：轮换池用时提醒用的是哪个模型）。路径与读的那边共用
        // RotateLog.defaultPath，不各写一份。
        '--log',
        RotateLog.defaultPath(runtime.nodeHome),
      ], withShims: withShims);
    } catch (e) {
      debugPrint('[dsh-rotate] 起代理进程失败（withShims=$withShims）：$e');
      return null;
    }

    // 把配置（含各厂家真实 Key + 令牌）通过管道交给代理，然后**必须关闭 stdin**
    // ——代理是同步读到 EOF 的。不 await flush：管道是 64KB，配置才几 KB；
    // 万一子进程提前死了，await 会一直挂着，反而掩盖问题。
    try {
      proc.stdin.write(configJson);
      unawaited(proc.stdin.close().catchError((Object _) {}));
    } catch (e) {
      debugPrint('[dsh-rotate] 写配置到代理 stdin 失败：$e');
    }

    // ⚠️ 把子进程输出**攒起来**再决定成败。
    //
    // 第一版直接 `await ready.future` 失败后 `cancel()` 订阅 —— 结果子进程写进管道
    // 的报错在"退出事件先到、订阅随后被取消"的竞态里被丢掉了，日志上只剩
    // "起不来"，真机排查时完全看不出原因（实测踩过：代理其实在设备上
    // 跑得起来，是 Dart 侧的判定/收纳出了问题）。
    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    final ready = Completer<int>();
    // 启动阶段：stderr 只攒着（失败时一次性打出来）；就绪之后实时打（见 _start 尾部）。
    var started = false;

    // 诊断日志：代理的输出**也**要进环形缓冲。
    // 代理的切换/失败原因全写在 stderr 上（"为什么切了/为什么崩了"全靠它），
    // 它是**独立进程**，App 崩溃后这些线索最容易丢 —— 所以启动阶段就开始 tee，
    // 而不是只在"失败时 debugPrint 一把"。
    final outTee = DiagnosticsLineTee('dsh-rotate:out');
    final errTee = DiagnosticsLineTee('dsh-rotate:err');

    final sub =
        proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(
      (chunk) {
        outBuf.write(chunk);
        outTee.feed(chunk);
        if (!ready.isCompleted) {
          // 端口是系统挑的，所以必须从这一行里读出来（不能拿 argv 里的 0）。
          final m = RegExp(r'listening on http://127\.0\.0\.1:(\d+)')
              .firstMatch(outBuf.toString());
          if (m != null) ready.complete(int.parse(m.group(1)!));
        }
      },
      onError: (_) {},
    );
    final errSub =
        proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(
      (chunk) {
        errBuf.write(chunk);
        errTee.feed(chunk);
        if (started) debugPrint('[dsh-rotate] ${chunk.trim()}');
      },
      onError: (_) {},
    );

    var exited = false;
    var exitCode = 0;
    // 进程自己退出（端口占用、脚本报错、崩了、没给令牌）→ 判定启动失败。
    unawaited(proc.exitCode.then((code) {
      exited = true;
      exitCode = code;
      outTee.finish();
      errTee.finish();
      if (!ready.isCompleted) ready.complete(-1);
      if (identical(_proc, proc)) {
        _proc = null;
        _port = null;
        debugPrint('[dsh-rotate] 代理进程退出，code=$code');
      }
    }));

    int port = -1;
    try {
      port = await ready.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      port = -1;
    }

    if (port <= 0) {
      // 给管道一点时间把最后几行吐干净（子进程已退出时这是必要的）。
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final errText = errBuf.toString().trim();
      final outText = outBuf.toString().trim();
      debugPrint(
        '[dsh-rotate] 代理启动失败（已退出=$exited, exit=$exitCode, '
        'withShims=$withShims）'
        '${outText.isEmpty ? '' : '；stdout: ${_head(outText)}'}'
        '${errText.isEmpty ? '；stderr 为空' : '；stderr: ${_head(errText)}'}',
      );
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
      outTee.finish();
      errTee.finish();
      await sub.cancel();
      await errSub.cancel();
      return null;
    }

    _proc = proc;
    // 就绪之后**继续保留 stderr 订阅**：代理的切换日志/异常都写在 stderr 上，
    // 真机排查"为什么切了/为什么崩了"全靠它（第一版在这里 cancel 了订阅，
    // 结果设备上代理以 code=1 退出时我们什么都看不到，白查半天）。
    // ⚠️ 不能 cancel 后再 listen 一次（单订阅流会抛 "already listened"），
    // 所以用 [started] 开关让**同一个订阅**切换行为。
    started = true;
    unawaited(sub.cancel());
    return port;
  }

  /// 日志里只留前若干字符，避免一屏刷满。
  static String _head(String s) =>
      s.length <= 400 ? s : '${s.substring(0, 400)}…（共 ${s.length} 字符）';

  /// 诊断用：**不含凭据**的状态文件位置（只放 lastGood）。
  ///
  /// 注意这里**没有**"配置文件路径"这个概念了 —— 配置走 stdin，不落盘（P0-2）。
  String? get statePath => _statePath;
}
