import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'diagnostics_log.dart';
import 'dsh_runtime.dart';

/// Bot 团队的**本机 web 服务**：在手机里起一个 `dsh --profile bottest` 进程。
///
/// ## 为什么是「进程 + WebView」而不是原生页面
///
/// Bot 的界面不是我们写的，是第三方插件 `ds-bot` 自带的一套浏览器前端
/// （826 条文案、群聊、@选人、记忆/密钥/用量/审批卡片、实时状态词……）。
/// 用户的要求是「体验和桌面版一样」—— 那就只能用**同一套前端**（`dsh-web-frontend/dist`），
/// 用 Flutter 重写一遍不可能追平。所以这里的做法是：把 web 服务在本机跑起来，
/// 页面用 WebView 打开它。
///
/// ## 这个 profile 是什么
///
/// `bottest` = `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app` + `ds-bot`
/// —— 这是运行时压缩包里 `app/profiles-seed/bottest/` 那份种子（见
/// `install/build-runtime-with-bottest.sh`）。**比整份 web profile 轻得多**：
/// 本机实测最小组合常驻约 200MB，而全量 web profile（23 个 bundle）是 1.4GB 级。
///
/// ## 两个实测过的硬约束（改这里前先看）
///
/// 1. **`--expose-internals` 必须加**：`node-addon-require-builtin` 的 Android shim
///    要 `require('internal/modules/esm/loader')`，没有这个开关会直接
///    `Cannot find module 'internal/modules/esm/loader'` 起不来。
/// 2. **端口用 `--port 0` 让系统挑**：真实端口从进程 stdout 的
///    `dsh web: http://127.0.0.1:<port>/?token=<token>` 那一行解析出来。
///    那行里的 token 是**身份凭证** —— 不带它访问首页是 401，带上会 303 并下发 cookie。
class BotServer {
  BotServer._({
    required this.process,
    required this.url,
    required this.port,
  });

  final Process process;

  /// 带 token 的地址：`http://127.0.0.1:<port>/?token=…`。WebView 打开它。
  final String url;

  final int port;

  static BotServer? _current;

  /// 已经起着的那个（没有就是 null）。页面据此决定要不要等。
  static BotServer? get current => _current;

  static const String profileName = 'bottest';

  /// 从种子布置 profile 到 `$DSH_HOME/profiles/bottest`。
  ///
  /// 种子随运行时压缩包分发（`<filesDir>/dsh/profiles-seed/bottest`），里面已经带了
  /// `node_modules/ds-bot` —— **必须放在 profile 自己的 node_modules 下**：DSH 的插件名
  /// 解析锚定 profile 目录，放别处解析不到（本机实测踩过）。
  ///
  /// 只在缺失时布置：用户之后在手机上改了 Bot 团队，不该被下次启动覆盖掉。
  static Future<void> ensureProfile(DshRuntime runtime) async {
    final target = Directory('${runtime.nodeHome}/profiles/$profileName');
    final seed = Directory('${runtime.runtimeRoot}/profiles-seed/$profileName');
    if (File('${target.path}/package.json').existsSync()) return;
    if (!File('${seed.path}/package.json').existsSync()) {
      throw StateError(
          '运行时里没有 Bot 种子（${seed.path}）—— 这个 App 的运行环境不含 Bot 功能。');
    }
    debugPrint('[dsh-bot] 布置 profile：${seed.path} → ${target.path}');
    await _copyTree(seed, target);
    DiagnosticsLog.add('dsh-bot', '已布置 profile：${target.path}');
  }

  /// 起服务（已起着就直接复用）。
  ///
  /// [onLog] 收启动过程的原始行，供调用方显示"卡在哪一步"。
  static Future<BotServer> ensureStarted({
    required DshRuntime runtime,
    void Function(String line)? onLog,
  }) async {
    final running = _current;
    if (running != null && running.alive) return running;
    if (running != null) await running.stop();

    await ensureProfile(runtime);

    final args = <String>[
      // ⚠️ 必须在最前：见类注释「硬约束 1」。
      '--expose-internals',
      '--require', runtime.fsShim,
      // 执行环境 shim：Android 上没有 bash，而 DSH 的 bash 工具写死了 spawn('bash')。
      // Bot 要能干活（跑命令、写文件）就靠它。
      '--require', runtime.execShimPath,
      runtime.dshBin,
      '--profile', profileName,
      // 下面两个是 web app 的参数（launcher 认不出的 token 起 inner arguments）。
      // --no-open：手机上不能去拉系统浏览器；--port 0：让系统挑空闲端口。
      '--no-open',
      '--port', '0',
      if (runtime.hasModelConfig) ...['--patch', runtime.overlayPath],
    ];

    onLog?.call('[dsh-bot] 启动：--profile $profileName --no-open --port 0');
    DiagnosticsLog.add('dsh-bot', '启动 web 服务：--profile $profileName');

    final env = <String, String>{
      ...runtime.environment,
      // Bot 团队要长期跑，别让 node 的默认堆把它顶掉。
      if (!runtime.environment.containsKey('NODE_OPTIONS'))
        'NODE_OPTIONS': '--max-old-space-size=1024',
    };

    final process = await Process.start(
      runtime.nodeBinary,
      args,
      environment: env,
      includeParentEnvironment: true,
      workingDirectory: runtime.nodeHome,
    );

    final urlCompleter = Completer<Uri>();
    final outTail = <String>[];
    final errTail = <String>[];
    var exited = false;

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      outTail.add(line);
      if (outTail.length > 40) outTail.removeAt(0);
      onLog?.call(line);
      // 就绪行：`dsh web: http://127.0.0.1:1234/?token=…`
      final m = RegExp(r'https?://\S+').firstMatch(line);
      if (m != null && !urlCompleter.isCompleted) {
        final raw = m.group(0)!.replaceAll(RegExp(r'[.,;)]+$'), '');
        urlCompleter.complete(Uri.parse(raw));
      }
    }, onError: (Object e) => debugPrint('[dsh-bot] stdout 错误：$e'));

    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      errTail.add(line);
      if (errTail.length > 40) errTail.removeAt(0);
      onLog?.call(line);
      DiagnosticsLog.add('dsh-bot:err', line);
    }, onError: (Object e) => debugPrint('[dsh-bot] stderr 错误：$e'));

    unawaited(process.exitCode.then((code) {
      exited = true;
      if (_current?.process == process) {
        _current!._exited = true;
        _current = null;
      }
      if (!urlCompleter.isCompleted) {
        urlCompleter.completeError(StateError(
            'Bot 服务启动失败（退出码 $code）：${_tail(errTail, outTail)}'));
      }
      DiagnosticsLog.add('dsh-bot', 'web 服务退出，码=$code');
    }));

    // 首次启动要把 dsh 的插件树拉起来，冷启实测 10~25 秒；给足 90 秒，
    // 超时如实把两个流最后几行抛出去（用户才知道卡在哪）。
    final url = await urlCompleter.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () => throw StateError(
          'Bot 服务 90 秒内没有报告地址${exited ? '' : '（进程还在跑）'}：'
          '${_tail(errTail, outTail)}'),
    );

    final server = BotServer._(
      process: process,
      url: url.toString(),
      port: url.port,
    );
    _current = server;
    DiagnosticsLog.add('dsh-bot', 'Bot 服务已就绪：端口 ${server.port}');
    return server;
  }

  bool _exited = false;

  /// 进程退出（或 [stop] 过）就是 false。
  bool get alive => !_exited;

  /// 停掉服务（页面要收掉、或用户手动停）。
  Future<void> stop() async {
    if (_current == this) _current = null;
    _exited = true;
    try {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  static String _tail(List<String> err, List<String> out) {
    final lines = <String>[...err, ...out].where((l) => l.trim().isNotEmpty);
    if (lines.isEmpty) return '（没有任何输出）';
    return lines.toList().reversed.take(4).toList().reversed.join(' / ');
  }

  /// 递归拷目录（种子里有 node_modules，必须连子目录一起搬）。
  static Future<void> _copyTree(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(followLinks: false)) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final target = '${to.path}/$name';
      if (entity is Directory) {
        await _copyTree(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
      }
    }
  }
}
