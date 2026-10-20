import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;

import '../data/atomic_file.dart';
import '../data/configured_models.dart';
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

  /// Bot 服务地址变化通知。
  ///
  /// 为什么需要（2026-10-18 真机 bug，而且是我自己上一版引入的）：
  /// 我给"模型变更"加了自动重启，而重启会**重新分配端口**（`--port 0`）。
  /// 但 Bot 页的 WebView 只在打开时 `loadRequest` 一次，之后永远指着旧端口 →
  /// 服务一重启，页面就打不开了（真机日志：46393 就绪 → 退出 → 34415 就绪，
  /// 而 WebView 仍连 46393）。
  /// 所以这里把「当前服务」本身做成可监听的值，页面订阅它、地址一变就重新加载。
  static final ValueNotifier<BotServer?> live =
      ValueNotifier<BotServer?>(null);

  /// 已经起着的那个（没有就是 null）。页面据此决定要不要等。
  static BotServer? get current => _current;

  /// 本次 App 生命周期内**固定使用**的端口；0 = 还没挑过。
  ///
  /// 为什么不用 `--port 0` 让系统挑：重启会换端口 → WebView 必须整页重载 →
  /// 用户正在操作的那一页（比如 Bot 设置）会被冲掉，看起来像"一直在重新连接"。
  /// 固定端口后，重启对页面来说是"服务抖动一下"，ds-bot 自己重连即可。
  ///
  /// 为什么是"挑一个空闲端口"而不是写死一个数：写死会跟系统/别的应用撞端口。
  /// 挑完就记住，重启复用；万一被占用（极少数），重启时再挑一次。
  static int _pinnedPort = 0;

  /// 挑一个当前空闲的端口（bind 一下再释放）。失败就退回 0（让系统挑）。
  static Future<int> _pickPort() async {
    if (_pinnedPort != 0) return _pinnedPort;
    for (var i = 0; i < 5; i++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final p = s.port;
        await s.close();
        _pinnedPort = p;
        return p;
      } catch (_) {
        // 重试几次；实在不行退回系统挑（0）
      }
    }
    return 0;
  }

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
      // ⚠️ 先看 App 的 models.json：**有模型就写完整 overlay，别只写权限段**。
      //
      // 2026-10-18 真机暴露：用户的 `models.json` 里有 3 个模型，但 overlay 不存在
      //（升级/清数据后 overlay 会丢，而 models.json 还在），于是一路走到下面的
      // "最小 overlay" 分支 → Bot 拿到的是**只有权限、没有 providers** 的配置 →
      // 它当然看不到任何模型。这里补上：有配置就照配置生成。
      final cfg = ConfiguredModels.readConfig(runtime.filesDir);
      if (cfg.models.isNotEmpty) {
        await runtime.writeOverlayFromConfig(
          config: cfg,
          activeRoute: cfg.selected ?? '',
        );
        DiagnosticsLog.add('dsh-bot',
            'overlay 原本不存在，但 models.json 有 ${cfg.models.length} 个模型 → 已按配置重建完整 overlay');
        return;
      }
      // 真的一个模型都没配 → 只写权限段（必须用 writeMinimalOverlay：
      // writeOverlayFromConfig 在"没有任何带模型的厂家"时会主动拒绝写）。
      await runtime.writeMinimalOverlay();
      DiagnosticsLog.add('dsh-bot',
          'overlay 原本不存在且没有模型 → 已写最小 overlay（关键作用：权限预设 danger-full-access）');
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '写 overlay 失败（会影响模型与权限审批）：$e');
    }
  }

  /// 完全权限 patch 的文件名（写在 `nodeHome` 下，和 overlay 并排）。
  static const String fullAccessPatchName = 'bot-full-access.patch.yml';

  /// **Bot 模式 = 完全权限**：单独一份 patch，起服务时**无条件**传给它。
  ///
  /// 用户 2026-10-19 明确要求「bot 模式记得开完全权限」。为什么不让
  /// `model.overlay.yml` 兼任（它里面本来也有这两段）：**那份 overlay 存不存在取决于
  /// 「用户配过模型没有 / 覆盖安装或清数据有没有丢」**，而权限一旦丢，Android 上没有
  /// DSH 需要的沙箱后端 → 每个工具调用都失败并弹「请求执行操作」要用户批准。
  /// 把权限拆成独立一份、无条件挂上去，这条"配置缺失 → 权限回退"的路就断了。
  ///
  /// 内容与 [DshRuntime.writeOverlayFromConfig] 里那两段一致：**两段都要给** ——
  /// 只设 `defaultPreset` 会撞上 DSH 的组合规则
  /// （`composed sandbox and approval defaults match no preset`）。
  static Future<String?> _ensureFullAccessPatch(DshRuntime runtime) async {
    const body = '# 由 App 生成：Bot 模式 = 完全权限（danger-full-access）。\n'
        '#\n'
        '# 为什么要独立一份：model.overlay.yml 可能因为「还没配模型 / 覆盖安装或清数据\n'
        '# 弄丢」而不存在，而权限预设一旦丢，Android 上没有 DSH 需要的沙箱后端 →\n'
        '# 每个工具调用都要用户点一次批准（真机原话「一直出现 agent 请求执行操作」）。\n'
        '# 所以这份由 BotServer 无条件 `--patch` 传给 Bot 服务。\n'
        '- id: sandbox-policy\n'
        '  name: "@deepseek-ai/dsh-sandbox-policy"\n'
        '  config:\n'
        '    mode: danger-full-access\n'
        '- id: permission\n'
        '  name: "@deepseek-ai/dsh-permission-presets"\n'
        '  config:\n'
        '    defaultPreset: danger-full-access\n';
    try {
      final dir = Directory(runtime.nodeHome);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('${dir.path}/$fullAccessPatchName');
      // 幂等：内容一致就不重写（不为每次进 Bot 页都动文件、也免了 mtime 噪音）。
      if (!f.existsSync() || f.readAsStringSync() != body) {
        writeStringAtomicSync(f, body);
        DiagnosticsLog.add('dsh-bot', '已写完全权限 patch：${f.path}');
      }
      return f.path;
    } catch (e) {
      // 写不出来也不拦启动：但必须留痕（否则"又要一直点批准"就成了谜）。
      DiagnosticsLog.add('dsh-bot', '写完全权限 patch 失败（Bot 可能每个调用都要批准）：$e');
      return null;
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

  /// 模型配置变了 → **如果 Bot 服务正在跑，就把它重起一次**，让它带上新的 overlay。
  ///
  /// 为什么必须这么做（2026-10-18 用户报「bot 没有读取出 app 的模型设置」）：
  /// ds-bot 的模型清单来自 `rt.cachedCatalog()` —— 也就是 **DSH 进程启动那一刻**
  /// 算出的模型目录；而 Bot 服务是**常驻单例进程**，启动之后就**再也不会重读** overlay。
  /// 于是用户在「设置 → 模型」里加/改的模型，Bot 那边永远看不到 ——
  /// 除非冷启动 App（下一次 ensureStarted 才会带上新 overlay）。
  ///
  /// 注意只在该服务**本来就在跑**时重起：没跑就别去惊动它（用户可能根本没用 Bot）。
  static Future<void> restartIfRunning({
    required DshRuntime runtime,
    void Function(String line)? onLog,
  }) async {
    final running = _current;
    if (running == null || !running.alive) return;
    try {
      await running.stop();
      await ensureStarted(runtime: runtime, onLog: onLog);
      DiagnosticsLog.add('dsh-bot', '模型配置已变更 → Bot 服务已重启（带上新的 overlay）');
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '模型配置变更后重启 Bot 服务失败：$e');
    }
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

    // 端口必须在拼 args 之前定好（重启复用同一个，见 [_pinnedPort]）。
    await _pickPort();

    await ensureProfile(runtime);

    // ⚠️⚠️ **必须在拼 args 之前**把 overlay 准备好（2026-10-19 修顺序 bug）。
    //
    // 为什么（2026-10-17 真机铁证，用户报「一直出现 agent 请求执行操作」）：
    // 用户那份会话产物里写着 `"sandboxMode": { "val": "workspace-write" }` —— **不是**
    // `danger-full-access`。因为传 `--patch` 是有条件的：
    //     if (runtime.hasModelConfig) ...['--patch', runtime.overlayPath]
    // 而 `hasModelConfig` 的定义就是**「overlay 文件是否存在」** → "用户还没配过模型 /
    // 刚覆盖安装或清过数据"时 overlay 不存在 → **整个 patch 都没传** → 连里面的
    // **权限预设**（`defaultPreset: danger-full-access`）一起丢 → DSH 退回默认的
    // `workspace-write` + `approval: ask`。Android 上**没有 DSH 需要的沙箱后端**，
    // 于是每个工具调用都失败并弹「请求执行操作」让用户批准（真机日志：
    // `The sandbox backend isn't usable, so tools fail` 紧跟 `权限请求`）。
    //
    // ⚠️ 原来这两行是在 args **之后**才跑的 —— 注释写得再对也没用：那一刻 overlay
    //    还没写出来，`hasModelConfig` 就是 false。顺序必须在这里。
    await _ensureOverlay(runtime);
    // 完全权限单独一份 patch、**永远传**（即使 overlay 因为任何原因仍不存在）。
    final fullAccessPatch = await _ensureFullAccessPatch(runtime);

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
      // ⚠️ 完全权限的 patch **永远传**，而且放在**最后**：`dsh` 的 launcher 是
      //    可重复收集、**按 argv 顺序叠加**（后者覆盖前者，见 dsh/lib/bin.js
      //    "Repeatable single-value collector"）→ 放最后 = 权限一定按我们的值生效。
      //    这样即使 overlay 缺失、或 overlay 是被老版本写的（里面没有权限段），
      //    Bot 也一定是完全权限（用户 2026-10-19 明确要求「bot模式记得开完全权限」）。
      if (fullAccessPatch != null) ...['--patch', fullAccessPatch],
      // 下面两个是 web app 的参数。
      // --no-open：手机上不能去拉系统浏览器；--port 0：让系统挑空闲端口。
      '--no-open',
      // ⚠️ 2026-10-20 真机：原来固定用 `--port 0`（系统挑）——于是**每次重启都换端口**：
      //   模型一切换 → 服务重启 → 端口 35575 → 43619 → WebView 整页重载
      //   → 用户正开着的 Bot 设置页被冲掉，页面上看到的就是「重新连接」。
      //   改成"这一次 App 生命周期内用同一个端口"：服务重启后端口不变，
      //   ds-bot 自己会重连，页面状态（打开的设置页、输入框里的字）都还在。
      '--port', '$_pinnedPort',
    ];

    onLog?.call('[dsh-bot] 启动：--profile $profileName --no-open --port 0');
    DiagnosticsLog.add('dsh-bot', '启动 web 服务：--profile $profileName');

    // 留痕：**这次到底挂了几份 patch**。排查「怎么又要我批准」时，这一行是第一现场
    //（"0 份 patch" 就等于 PermissionPreset 丢了）。
    final patchKinds = <String>[
      if (runtime.hasModelConfig) '模型 overlay',
      if (fullAccessPatch != null) '完全权限',
    ];
    DiagnosticsLog.add(
      'dsh-bot',
      'Bot 启动参数：profile=$profileName，patch ${patchKinds.length} 份'
      '${patchKinds.isEmpty ? '（一份都没有 —— 权限会回退成 ask！）' : '（${patchKinds.join(' + ')}）'}',
    );

    final env = <String, String>{
      ...runtime.environment,
      // Bot 团队要长期跑，别让 node 的默认堆把它顶掉。
      if (!runtime.environment.containsKey('NODE_OPTIONS'))
        'NODE_OPTIONS': '--max-old-space-size=1024',
      // ⚠️ **完全权限的第二道保险**（第一道是上面那份永远传的 patch）。
      //
      // 证据（本地 `dsh bottest --patch … --dump-config` 实测）：`dsh-base` 里
      // `@deepseek-ai/dsh-user-approval` 的 policy 是从这个环境变量算出来的 ——
      //     (process.env.DSH_PERMISSION_MODE ?? 'workspace-write')
      //        === 'danger-full-access' ? 'never' : 'ask'
      // 不设它时算出来是 **'ask'**（= 每个工具调用都弹「请求执行操作」）。
      // patch 里的 `defaultPreset: danger-full-access` 在运行时也会调
      // `setApprovalPolicy('never')`（preset 表里写着 "Full file access without
      // approval prompts"），两条路殊途同归；这里把它显式钉死，任何"预设没解析到"
      // 的边角情况也不会退回 ask（用户 2026-10-19：「bot 模式记得开完全权限」）。
      'DSH_PERMISSION_MODE': 'danger-full-access',
    };

    // （overlay 与完全权限 patch 都已在**拼 args 之前**准备好 —— 见上面那段说明。
    //  这里原来有一份重复的 `await _ensureOverlay(runtime);`，而且位置在 args 之后，
    //  正是"注释写对了、顺序却错了"的那个 bug，已清掉。）

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
        live.value = null;
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
    live.value = server;
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
    if (_current == this) {
      _current = null;
      live.value = null;
    }
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
