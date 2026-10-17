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
  /// 保证 `model.overlay.yml` 存在 —— **哪怕用户一个模型都没配**。
  ///
  /// 为什么不能"没配就不写"：这个 overlay 不只描述模型，还带着**权限预设**
  /// （`permission.defaultPreset: danger-full-access`）。缺了它，会话会掉进
  /// 默认的 `workspace-write` + `approval: ask`，而 Android 上没有沙箱后端 →
  /// 每个工具调用都要用户点一次批准（用户原话：「一直出现 agent 请求执行操作」）。
  static Future<void> _ensureOverlay(DshRuntime runtime) async {
    if (runtime.hasModelConfig) return;
    try {
      // ⚠️ 必须用 writeMinimalOverlay 而不是 writeOverlayFromConfig：
      // 后者在"没有任何带模型的厂家"时**会主动拒绝写**（怕写坏 overlay），
      // 那正是"没配模型的用户根本没有 overlay"的原因。
      await runtime.writeMinimalOverlay();
      DiagnosticsLog.add('dsh-bot',
          'overlay 原本不存在 → 已写最小 overlay（关键是权限预设 danger-full-access）');
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '写最小 overlay 失败（会影响权限审批）：$e');
    }
  }

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
      // ⚠️ **--patch 必须留在 --no-open 之前**（0.77 测试包在真机上就栽在这里）：
      //    dsh 的 launcher 只认自己的参数，**一旦出现它不认识的 token，后面全部
      //    算作 profile 内部 app 的参数**。--no-open 正是那个 token —— 所以写反
      //    顺序时 `--patch` 会被 web app 当成未知选项，直接
      //    `error: unknown option '--patch'` 退出（退出码 1，界面报「Bot 服务
      //    没能起来」）。本机两种顺序都复现过，见 docs/BOT-TEST.md §3。
      if (runtime.hasModelConfig) ...['--patch', runtime.overlayPath],
      // 下面两个是 web app 的参数。
      // --no-open：手机上不能去拉系统浏览器；--port 0：让系统挑空闲端口。
      '--no-open',
      '--port', '0',
    ];

    onLog?.call('[dsh-bot] 启动：--profile $profileName --no-open --port 0');
    DiagnosticsLog.add('dsh-bot', '启动 web 服务：--profile $profileName');

    final env = <String, String>{
      ...runtime.environment,
      // Bot 团队要长期跑，别让 node 的默认堆把它顶掉。
      if (!runtime.environment.containsKey('NODE_OPTIONS'))
        'NODE_OPTIONS': '--max-old-space-size=1024',
    };

    // ⚠️⚠️ **确保 overlay 存在**（2026-10-17 真机铁证，用户报「一直出现 agent 请求执行操作」）。
    //
    // 用户那份会话产物里写着 `"sandboxMode": { "val": "workspace-write" }` ——
    // **不是** `danger-full-access`。原因是下面传 `--patch` 是有条件的：
    //     if (runtime.hasModelConfig) ...['--patch', runtime.overlayPath]
    // 而"用户还没配过模型"时 overlay 文件不存在 → **整个 patch 都没传** →
    // 连里面的**权限预设**（`defaultPreset: danger-full-access`，即 approval=never）
    // 一起丢 → DSH 退回默认的 `workspace-write` + `approval: ask`。
    // Android 上**没有 DSH 需要的沙箱后端**，于是每个工具调用都失败并弹出
    // 「请求执行操作」让用户批准（真机日志：`The sandbox backend isn't usable, so tools fail`
    // 紧跟 `权限请求`）。桌面版没这现象，因为它 profile 自带权限配置。
    //
    // 所以：起服务前**先写一份最小 overlay**（模型为空也没关系，权限预设是关键）。
    await _ensureOverlay(runtime);

    // ⚠️ 先把运行时要用的目录建好（2026-10-17 真机日志暴露的遗漏）：
    //   DSH 的 spill-local 插件会在 `<filesDir>/tmp` 下 `mkdtemp('dsh-spill-XXXXXX')`，
    //   目录不在就报 `ENOENT: mkdtemp .../files/tmp/dsh-spill-XXXXXX`
    //   → 表现为「1 entry did not activate」（不致命，但日志脏、运行环境也不完整）。
    //   ACP 那条路径一直有这个 mkdir（见 acp_client.dart），BotServer 当初漏了。
    for (final d in <String>['${runtime.filesDir}/tmp', runtime.nodeHome]) {
      final dir = Directory(d);
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }

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

  /// 调 Bot 的 HTTP API（`POST /api/bot`）。
  ///
  /// 为什么需要它：Bot 名册能直接从 `state.json` 读（那步不需要进程），但**改**东西
  /// 不行 —— 比如把群的「谁回答」从「只交给主持人」改成「全员都答」，得走 ds-bot
  /// 自己的 `update-room`。App 一旦直接去改 `state.json`，就等于两套写入方打架。
  ///
  /// 认证方式与浏览器一致：先带 `?token=` 访问一次拿 `Set-Cookie`，再带着它请求。
  /// （实测：不带 token 是 401，带 token 是 303 并下发 cookie。）
  Future<Map<String, dynamic>> callApi(
    String endpoint, [
    Map<String, dynamic>? payload,
  ]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      // ① token → cookie
      //
      // ⚠️ **必须关掉自动跟随重定向**（2026-10-17 真机日志 `FormatException` 的根因）：
      //    带 `?token=` 访问会返回 **303 + Set-Cookie**，而 `HttpClient.followRedirects`
      //    默认是 true —— 它会一路跟到最终页面，于是**这次响应的头就读不到了**，
      //    cookie 永远是 null → 后续 POST 全部 401 → 返回 HTML 而不是 JSON
      //    → `jsonDecode` 抛 `FormatException`（真机现象：拉模型清单失败、
      //    「新建 Bot」也建不成）。
      String? cookie;
      try {
        final getReq = await client.getUrl(Uri.parse(url));
        getReq.followRedirects = false; // ← 关键：停在 303 上拿到 Set-Cookie
        final res = await getReq.close();
        final sc = res.headers['set-cookie'];
        if (sc != null && sc.isNotEmpty) {
          cookie = sc.first.split(';').first;
          DiagnosticsLog.add('dsh-bot',
              'token→cookie 成功（HTTP ${res.statusCode}，cookie 名=${cookie.split('=').first}）');
        } else {
          DiagnosticsLog.add('dsh-bot',
              'token→cookie 未拿到 Set-Cookie（HTTP ${res.statusCode}）—— 后续请求会 401');
        }
        await res.drain<void>();
      } catch (e) {
        debugPrint('[dsh-bot] 取 cookie 失败（继续试直连）：$e');
      }

      // ② 调 API
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/bot'));
      req.followRedirects = false; // 别把 401 跟成一个 200 的 HTML 页面
      req.headers.contentType = ContentType.json;
      if (cookie != null) req.headers.set('Cookie', cookie);
      req.write(jsonEncode(<String, Object?>{
        'endpoint': endpoint,
        'payload': payload ?? const <String, Object?>{},
      }));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      final code = res.statusCode;

      // ⚠️ 401 时 `/api/bot` 返回的是**纯文本 `unauthorized`**，不是 JSON
      //（2026-10-17 实测）。原来这里直接 jsonDecode → 抛
      // `FormatException: Unexpected character (at character 1)`，
      // 真机日志里就是那条「拉模型清单失败」，把新建 Bot 也一起带崩了。
      // 现在的做法：先看状态码、再决定怎么解析，**任何情况下都不抛**。
      if (code != 200) {
        DiagnosticsLog.add(
            'dsh-bot', 'API $endpoint 返回 HTTP $code（cookie=${cookie == null ? '未拿到' : '已拿到'}）：${body.substring(0, body.length.clamp(0, 80))}');
        return <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{
            'code': 'http/$code',
            'message': code == 401
                ? '本地 Bot 服务拒绝了这次请求（未授权）。多半是 token→cookie 没建立起来，重新进一次 Bot 页通常就好。'
                : '本地 Bot 服务返回 HTTP $code：${body.substring(0, body.length.clamp(0, 120))}',
          },
        };
      }

      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return <String, dynamic>{'ok': false, 'error': '非预期响应（HTTP $code）：${body.substring(0, body.length.clamp(0, 120))}'};
    } finally {
      client.close(force: true);
    }
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
