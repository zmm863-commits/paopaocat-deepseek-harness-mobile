import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'android_toolbox.dart';
import 'dsh_runtime.dart';
import 'diagnostics_log.dart';

/// ACP（Agent Client Protocol）stdio 客户端。
///
/// 为什么需要它：App 目前走 `dsh --profile headless "<任务>"`，每次都是一次性进程，
/// 于是**每轮对话互相独立**。要拿到真正的多轮上下文，必须用长驻的
/// `dsh --profile acp` 加会话：一个连接里开一个 session，之后反复 prompt。
///
/// 协议（实测于 DSH 0.1.7-rc.2）：
///   - 换行分帧 JSON-RPC 2.0，一条消息一行；
///   - client→server 请求：initialize / session/new / session/prompt / session/close ...
///   - server→client 通知：session/update（含 agent_message_chunk、tool_call、usage_update 等）
///   - server→client 请求：session/request_permission（必须应答，否则会话卡住）
/// 服务端的请求 id 与客户端 id 空间独立，回复时要原样带回 `msg.id`。
class AcpClient {
  AcpClient({required this.process, this.onLog});

  final Process process;
  final void Function(String message)? onLog;

  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;
  bool _closed = false;

  /// 运行时**自己报出来**的当前模型 route（`provider/model`），没拿到就是 null。
  ///
  /// 来源：`session/new`、`session/resume`、`session/set_config_option` 的返回里
  /// 都带 `configOptions`（`[{id:'model', currentValue:'["provider","model"]', …}]`）。
  ///
  /// 为什么要有它：界面上显示的模型名来自本地 `ModelStore`，用户点一下**立刻就变**，
  /// 但它**不代表进程里真的切过去了**（DSH 的 `set_config_option` 只认进程启动时
  /// 注册过的模型，其余组合会失败）。判断"到底在跑哪个模型"只能看这里的值。
  String? liveModelRoute;

  /// 从 `configOptions` 里取出当前模型 route。取不到返回 null（**绝不猜**）。
  static String? modelRouteFromConfigOptions(Object? raw) {
    if (raw is! List) return null;
    for (final o in raw) {
      if (o is! Map || o['id'] != 'model') continue;
      final cur = o['currentValue'];
      if (cur is! String || cur.trim().isEmpty) return null;
      try {
        final v = jsonDecode(cur);
        if (v is List && v.length >= 2) return '${v[0]}/${v[1]}';
      } catch (_) {
        return null;
      }
      return null;
    }
    return null;
  }

  /// 服务端通知流（session/update 等），由上层解析。
  final StreamController<Map<String, dynamic>> _notifications =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get notifications => _notifications.stream;

  /// 权限请求流。上层必须对每个请求调用 [respondPermission]，
  /// 否则 DSH 侧会一直挂着（或等到超时）。
  final StreamController<AcpPermissionRequest> _permissions =
      StreamController<AcpPermissionRequest>.broadcast();

  Stream<AcpPermissionRequest> get permissionRequests => _permissions.stream;

  /// 最近一次从子进程收到**任何一行**的时刻（审计 P1-1）。
  ///
  /// 为什么用"收到行"而不是"收到有效协议消息"：我们只想知道"子进程还活着、
  /// 还在动"，不在乎它说了什么 —— 连解析失败的行也算活动。
  ///
  /// 为什么需要它：`request()` 原来的超时是**总时长**（5 分钟，从发出算到整轮
  /// 结束）。一个多轮工具调用、或端侧小模型慢慢吐字的正常回合很容易超过它，
  /// 一刀切会把好回合砍掉；而真正要治的是"卡死时的静默"。所以判据改成
  /// 「连续 N 秒一行输出都没有」——见 [request] 的 `idleTimeout`。
  DateTime _lastLineAt = DateTime.now();

  /// 已经**完全没有输出**多久了。UI 用它显示"还在等 N 秒"，超时用它判定。
  Duration get silenceFor => DateTime.now().difference(_lastLineAt);

  /// 启动并完成 initialize 握手。返回 agent 公布的能力。
  ///
  /// ## 为什么要接 [DshRuntime] 而不是自己拼一份 env（**2026-10-04 修，别改回去**）
  ///
  /// 这里以前是"自己拼一份精简环境"，只放 LD_LIBRARY_PATH / DSH_HOME / HOME /
  /// PATH / TMPDIR + Key。后果是**会话里所有命令都不能跑**：
  ///
  ///   * `DSH_ANDROID_NODE_BIN` / `DSH_ANDROID_FS_SHIM` / `DSH_ANDROID_EXEC_SHIM` /
  ///     `DSH_ANDROID_TMPDIR` 一个都没有 → `android-exec-shim.cjs` 判定"缺配置"，
  ///     **完全不做改写**（它的设计是四个变量齐全才生效）；
  ///   * 也没挂 `--require android-exec-shim.cjs`。
  ///
  /// 于是模型一调 bash 就是用户真机截图里那句 `spawn bash ENOENT`
  /// （Android 上根本没有 bash），`node "$DSH_ANDROID_TOOLBOX/make-image.mjs"`
  /// 同样发不出去 —— **「画图不能用」的根因就在这里**。定时任务 / 轮换代理那条路
  /// （`DshRuntime.spawn`）一直是好的，所以现象是"只有对话里用不了"。
  ///
  /// 现在**整份 [DshRuntime.environment] 照搬**（含 DSH_ANDROID_* 四件套、
  /// `DSH_ANDROID_TOOLBOX`、`AGNES_*`），并挂上执行环境 shim ——
  /// "会话进程和别的进程环境不一致"这种错**从结构上**不再可能发生。
  ///
  /// ## [apiKeys]：每个厂家各自的环境变量
  ///
  /// overlay 里每家厂家写的是 `apiKeyEnv: <PROVIDER>_API_KEY`，而 DSH 的凭据
  /// **只在子进程环境变量里找**（见 `dsh-llm-pi-ai` 的报错原文：
  /// `its profile resolves COM_API_KEY, which is not set`）。
  ///
  /// 修之前这里只有一个 [apiKey]（历史遗留的"全局一把 Key"），于是会话进程只拿到
  /// `COM_API_KEY` / `DEEPSEEK_API_KEY` / `OPENAI_API_KEY` 这三个固定名字 ——
  /// **provider id 不是这三个的厂家（Agnes、MiMo、自定义厂家…）在会话里必然
  /// "没有凭据"**，而定时任务/轮换代理那条路（`DshRuntime.spawn`）是好的，
  /// 所以现象很迷惑：同一个 Key，headless 能跑、会话里报 no credential。
  ///
  /// 传进来的优先级：后面的 [apiKeys] **覆盖** [DshRuntime] 自带的那份（老键名只是兜底）。
  static Future<AcpClient> start({
    required DshRuntime runtime,
    required String workspace,
    String? overlayPath,
    Map<String, String> apiKeys = const <String, String>{},
    Map<String, String>? extraEnv,
    void Function(String message)? onLog,
  }) async {
    final filesDir = runtime.filesDir;
    final tmp = Directory('$filesDir/tmp');
    if (!tmp.existsSync()) tmp.createSync(recursive: true);
    final ws = Directory(workspace);
    if (!ws.existsSync()) ws.createSync(recursive: true);

    // ⚠️ 执行环境 shim / 工具箱脚本是**随包资源**，必须先落到私有目录。
    // 不然下面 `--require` 的路径不存在，node 会直接以
    // "Cannot find module '…/shims/android-exec-shim.cjs' (internal/preload)" 退出
    // —— 会话连起都起不来。
    await AndroidToolbox.ensureInstalled(filesDir);

    // ⚠️ ACP 的 profile 是 DSH 自带的模板建的，里面**没有** anysearch 插件；
    // 而咱们的补丁会 `- insert: web-search-anysearch` → 每次启动刷
    // `web-search-anysearch: failed to import`。启动前补一次（幂等）。
    try {
      await runtime.ensureProfileHasAnysearch('acp');
    } catch (_) {}

    final args = <String>[
      '--expose-internals',
      '--require', runtime.fsShim,
      // 执行环境 shim：Android 上没有 bash（`/system/bin/sh` 是 mksh），而 DSH 的
      // bash 工具写死了 `spawn('bash')`。挂上它，`bash -c CMD` 会被改写成
      // `/system/bin/sh -c "<prelude>; CMD"`，`node xxx.mjs` 也会换成随包的
      // libnode.so（含两个 shim）。**不挂就等于会话里没有任何可执行环境。**
      '--require', runtime.execShimPath,
      runtime.dshBin,
      '--profile', 'acp',
      if (overlayPath != null && File(overlayPath).existsSync()) ...[
        '--patch',
        overlayPath
      ],
      // 注意：overlay 缺失时这里就**不传 patch**，会话会掉进默认权限
      // （workspace-write + approval ask）→ Android 上每步都要用户批准。
      // 已在调用方（ChatPage/AppShell）保证 overlay 存在；见 BotServer._ensureOverlay
      // 的同名注释与 2026-10-17 的真机会话产物证据（sandboxMode=workspace-write）。
    ];

    final env = <String, String>{
      // 整份运行时环境：LD_LIBRARY_PATH / DSH_HOME / HOME / PATH / TMPDIR +
      // DSH_ANDROID_* 四件套 + DSH_ANDROID_TOOLBOX + AGNES_* + 运行时自带的那份 Key。
      ...runtime.environment,
      ...?extraEnv,
      // ⚠️ 必须放在最后：overlay 里 `apiKeyEnv` 点名的那些变量名以这里为准，
      // 同名的旧键名（COM_/DEEPSEEK_/OPENAI_）被每厂家 Key 覆盖 —— 这正是
      // "会话里用错 Key"的修复点。
      ...apiKeys,
    };

    onLog?.call(
        '[acp] spawn ${File(runtime.nodeBinary).uri.pathSegments.last} --profile acp'
        '（已挂执行环境 shim${apiKeys.isEmpty ? '' : '，注入 ${apiKeys.length} 个厂家环境变量'}）');
    // 2026-10-20：模型在 bash 里反复调我们自己的脚本、还先 `echo $DSH_ANDROID_TOOLBOX` 确认 ——
    // 说明它怀疑这个变量是空的。这里把「关键环境变量到底给没给」记下来（**只记有无，不记值**），
    // 下次遇到"脚本跑了但什么都没干"，第一眼就能排除这条。
    DiagnosticsLog.add('dsh-chat',
        '会话环境：TOOLBOX=${env.containsKey('DSH_ANDROID_TOOLBOX') ? '有' : '无'}'
        ' TMPDIR=${env.containsKey('DSH_ANDROID_TMPDIR') ? '有' : '无'}'
        ' LD_LIBRARY_PATH=${env.containsKey('LD_LIBRARY_PATH') ? '有' : '无'}'
        ' PATH=${env.containsKey('PATH') ? '有' : '无'}'
        ' 厂家变量=${apiKeys.length}');
    final process = await Process.start(
      runtime.nodeBinary,
      args,
      environment: env,
      includeParentEnvironment: true,
      workingDirectory: workspace,
    );
    final client = AcpClient(process: process, onLog: onLog);
    client._pump();
    await client._initialize();
    return client;
  }

  void _pump() {
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onLine, onError: (e) => onLog?.call('[acp] stdout error: $e'));

    // ACP 的进度/推理提示走 stderr，仅用于日志，不参与协议。
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isNotEmpty) onLog?.call('[acp:stderr] ${line.trim()}');
    }, onError: (_) {});

    process.exitCode.then((code) {
      onLog?.call('[acp] process exited with $code');
      _closed = true;
      for (final c in _pending.values) {
        if (!c.isCompleted) {
          c.completeError(StateError('ACP 进程已退出（code=$code）'));
        }
      }
      _pending.clear();
      if (!_notifications.isClosed) _notifications.close();
      if (!_permissions.isClosed) _permissions.close();
    });
  }

  void _onLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return;
    // 任何一行（包括下面解析失败的那种）都算"子进程还在动"。见 _lastLineAt 的说明。
    _lastLineAt = DateTime.now();

    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      onLog?.call(
          '[acp] 无法解析的行: ${text.length > 160 ? '${text.substring(0, 160)}…' : text}');
      return;
    }

    final id = msg['id'];
    final method = msg['method'];

    // 响应（有 id、无 method）
    if (id != null && method == null) {
      final key = id is int ? id : int.tryParse('$id');
      final completer = key == null ? null : _pending.remove(key);
      if (completer != null && !completer.isCompleted) {
        completer.complete(Map<String, dynamic>.from(msg));
      }
      return;
    }

    // 服务端 → 客户端 请求（有 id、有 method）
    if (id != null && method != null) {
      if (method == 'session/request_permission') {
        final params =
            Map<String, dynamic>.from(msg['params'] as Map? ?? const {});
        _permissions
            .add(AcpPermissionRequest(client: this, id: id, params: params));
      } else {
        // 未声明能力时 DSH 不会发这些；真收到就明确拒绝，避免把会话挂死
        _raw({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'unsupported: $method'}
        });
      }
      return;
    }

    // 通知（无 id、有 method）
    if (!_notifications.isClosed) {
      _notifications.add(Map<String, dynamic>.from(msg));
    }
  }

  void _raw(Map<String, dynamic> msg) {
    if (_closed) return;
    process.stdin.write('${jsonEncode(msg)}\n');
  }

  /// 发一个请求并等结果。
  ///
  /// [timeout] 是**总时长**上限（兜底，防止真的无限挂着）。
  /// [idleTimeout] 是**空闲**上限：只在"连续这段时间一行输出都没有"时才判超时。
  /// 长回合该用空闲超时而不是总时长 —— 见 [prompt] 的说明（审计 P1-1）。
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(minutes: 5),
    Duration? idleTimeout,
  }) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _lastLineAt = DateTime.now();
    _raw({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});

    // 空闲看门狗：每 5 秒看一眼"是不是已经 N 秒没人吭声了"。
    // 用轮询而不是"重置一个 timer"：`_onLine` 是热路径，不想在那里维护一堆 timer。
    Timer? watchdog;
    if (idleTimeout != null) {
      watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
        if (completer.isCompleted) return;
        if (silenceFor >= idleTimeout) {
          _pending.remove(id);
          watchdog?.cancel();
          completer.completeError(TimeoutException(
              '模型已经 ${idleTimeout.inSeconds} 秒没有任何输出'));
        }
      });
    }

    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      watchdog?.cancel();
      throw TimeoutException('ACP 请求超时：$method');
    }).whenComplete(() => watchdog?.cancel());
  }

  Future<void> _initialize() async {
    final res = await request('initialize', {
      'protocolVersion': 1,
      'clientCapabilities': {
        'fs': {'readTextFile': false, 'writeTextFile': false},
        'terminal': false,
      },
      'clientInfo': {'name': 'dsh-mobile', 'version': '0.1.0'},
    });

    final error = res['error'];
    if (error != null) {
      throw StateError('ACP initialize 失败：${(error as Map)['message']}');
    }
    final result = Map<String, dynamic>.from(res['result'] as Map? ?? const {});
    onLog
        ?.call('[acp] initialize ok, agent=${jsonEncode(result['agentInfo'])}');
  }

  /// 新建会话，返回 sessionId。
  /// [mcpServers] 是给这次会话挂的 MCP 服务器（见 `data/anysearch.dart`）。
  ///
  /// ACP 约束（`dsh-acp` 会逐条校验，写错整个请求被拒）：http 那种要
  /// `{name, type:'http', url, headers:[{name,value}]}`；stdio 那种要求
  /// `command` 是**绝对路径**。手机上一律走 http（不用起子进程）。
  Future<String> newSession(
    String cwd, {
    List<Map<String, dynamic>> mcpServers = const <Map<String, dynamic>>[],
  }) async {
    final res = await request('session/new', {
      'cwd': cwd,
      'mcpServers': mcpServers,
    });
    final error = res['error'];
    if (error != null) {
      // ⚠️ **把完整错误记进日志**（2026-10-17 用户连报两轮「会话没有建立起来」）。
      //
      // 为什么不能只取 message：DSH 对内部失败常常只回一句 `Internal error`，
      // 真正的线索在同一个 error 对象的 `data` / `code` 里 —— 只转述 message
      // 等于把唯一的证据扔掉，日志里就只剩那句废话，谁都没法定位。
      onLog?.call('[acp] session/new 失败，服务端完整返回：${jsonEncode(error)}');
      throw StateError('session/new 失败：${(error as Map)['message']}');
    }
    final result = Map<String, dynamic>.from(res['result'] as Map? ?? const {});
    final sessionId = result['sessionId'] as String?;
    if (sessionId == null) throw StateError('session/new 未返回 sessionId');
    // 新建会话的返回里带 `configOptions` —— 记下运行时**此刻真正在用**的模型。
    liveModelRoute =
        modelRouteFromConfigOptions(result['configOptions']) ?? liveModelRoute;
    onLog?.call('[acp] session created: $sessionId model=$liveModelRoute');
    return sessionId;
  }

  /// 列出**已持久化且当前不活跃**的会话（ACP `session/list`，DSH 0.1.7-rc.2 起）。
  ///
  /// 返回 `sessionId` / `cwd` / **`createdAt`**。DSH 的 `session/list`
  /// **不返回标题**（所以界面不能给这些会话编标题），但**返回创建时间** ——
  /// 见 `dsh-acp/lib/index.js` 的 `listSessions`：它逐条给 `createdAt`
  /// 并**按 createdAt 倒序**排。我们之前解析时把时间丢掉了，
  /// 结果界面上没法回答用户的「这些会话是什么时候的」。
  ///
  /// 实测（设备上跑 install/android-acp-list-resume.mjs 验证过）：
  ///   * 不带 `cwd` → 返回所有 cwd 下的可恢复根会话，最新在前；
  ///   * 带 `cwd` → 只返回该目录的会话（DSH 侧按物理目录同一性比较）；
  ///   * 分页靠 `nextCursor`，这里最多翻 [maxPages] 页，避免一次拉爆。
  Future<List<({String sessionId, String cwd, DateTime? createdAt})>>
      listSessions({
    String? cwd,
    int maxPages = 4,
  }) async {
    final out = <({String sessionId, String cwd, DateTime? createdAt})>[];
    String? cursor;
    for (var page = 0; page < maxPages; page++) {
      final res = await request('session/list', {
        if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
        if (cursor != null) 'cursor': cursor,
      });
      final error = res['error'];
      if (error != null) {
        throw StateError('session/list 失败：${(error as Map)['message']}');
      }
      final result =
          Map<String, dynamic>.from(res['result'] as Map? ?? const {});
      final sessions = result['sessions'];
      if (sessions is! List) break;
      for (final item in sessions) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final id = m['sessionId'] as String?;
        if (id == null || id.isEmpty) continue;
        out.add((
          sessionId: id,
          cwd: m['cwd'] as String? ?? '',
          createdAt: parseSessionCreatedAt(m['createdAt']),
        ));
      }
      cursor = result['nextCursor'] as String?;
      if (cursor == null) break;
    }
    return out;
  }

  /// 解析 `session/list` 的 `createdAt`。
  ///
  /// DSH 侧是**数字**（epoch；它自己的游标编解码也用这个数字，见
  /// `dsh-acp/lib/index.js` 的 cursor 部分）。这里秒级/毫秒级都容忍，
  /// 认不出来就返回 **null** —— 界面据此"不显示时间"，绝不编一个时间出来。
  static DateTime? parseSessionCreatedAt(Object? raw) {
    int? n;
    if (raw is int) {
      n = raw;
    } else if (raw is num) {
      n = raw.toInt();
    } else if (raw is String) {
      n = int.tryParse(raw);
    }
    if (n == null || n <= 0) return null;
    // 10 位是秒、13 位是毫秒；按量级归一。
    final ms = n < 100000000000 ? n * 1000 : n;
    try {
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// 恢复一个已持久化的会话（ACP `session/resume`）。
  ///
  /// 两个必须在界面上讲清楚的协议事实（都在设备上实测过）：
  ///   1. DSH 会校验 [cwd] 与持久化时的 cwd **一致**，不一致直接报
  ///      `session cwd does not match`；
  ///   2. 恢复**不回放历史消息**（协议原文：its log is restored without
  ///      replaying old updates）—— 所以恢复后界面是空的，但模型的上下文还在
  ///      （实测：恢复后问它之前说过的口令，答对了）。
  Future<void> resumeSession(
    String sessionId,
    String cwd, {
    List<Map<String, dynamic>> mcpServers = const <Map<String, dynamic>>[],
  }) async {
    final res = await request('session/resume', {
      'sessionId': sessionId,
      'cwd': cwd,
      'mcpServers': mcpServers,
    });
    final error = res['error'];
    if (error != null) {
      throw StateError('session/resume 失败：${(error as Map)['message']}');
    }
    final result = Map<String, dynamic>.from(res['result'] as Map? ?? const {});
    liveModelRoute =
        modelRouteFromConfigOptions(result['configOptions']) ?? liveModelRoute;
    onLog?.call('[acp] session resumed: $sessionId model=$liveModelRoute');
  }

  /// 发送一轮提示词；返回 stopReason。
  /// 一整轮的"完全没输出"上限（审计 P1-1）。
  ///
  /// ⚠️ 为什么是**空闲**而不是总时长：旧代码 `request()` 的默认超时是**总时长**
  /// 5 分钟，而 `chat_page` 那轮又不在 noRetry 名单里 → 超时会**自动重试一次**
  /// → 界面最长静默 **10 分钟**，只有一个转圈。
  ///
  /// 但直接把总时长砍到 60~90 秒（审计的原始建议）会**砍掉正常回合**：
  /// 多轮工具调用、或端侧小模型先做一长段 prefill（这段时间一个 token 都不吐），
  /// 都能轻松超过 90 秒。所以判据换成"连续多久一行输出都没有"——
  /// 卡死会被抓到，算得慢不会被误杀。
  ///
  /// 180 秒的取值理由：端侧模型对 4096 上下文做 prefill 时确实可能几十秒到
  /// 一分多钟完全不吐字（真机未测，这是保守取值）。**这个数需要真机实测后调**。
  static const Duration promptIdleTimeout = Duration(seconds: 180);

  /// 一轮的**总**上限（兜底）。比旧值（5 分钟）放大：总时长不该是掐死长回合的东西，
  /// 它的职责只是"防止真的无限挂着"。
  static const Duration promptHardTimeout = Duration(minutes: 30);

  Future<String?> prompt(String sessionId, String text) async {
    final res = await request(
      'session/prompt',
      {
        'sessionId': sessionId,
        'prompt': [
          {'type': 'text', 'text': text},
        ],
      },
      timeout: promptHardTimeout,
      idleTimeout: promptIdleTimeout,
    );
    final error = res['error'];
    if (error != null) {
      throw StateError('session/prompt 失败：${(error as Map)['message']}');
    }
    final result = Map<String, dynamic>.from(res['result'] as Map? ?? const {});
    return result['stopReason'] as String?;
  }

  /// 会话内改一个**配置项**（标准 ACP `session/set_config_option`）。
  ///
  /// 为什么要它：用户实测反馈「会话页面切换模型就会重建会话」—— 因为原来的落地
  /// 方式是"改 overlay + 重启子进程"。而 DSH 的 ACP 本来支持会话级配置项：
  ///   配置项 id = `model`，值 = `["provider","model"]` 的 JSON 串
  ///   （见 `@deepseek-ai/dsh-acp` 的 `MODEL_CONFIG_ID` / `modelValue()`，
  ///    以及协议常量 `session/set_config_option`）。
  /// 这样切模型只改当前 agent 的选择，**历史消息与工具状态全都留着**。
  ///
  /// 失败会抛 [StateError]（调用方应退回"重建会话"的老路子，并如实告知）。
  ///
  /// 返回值是运行时**回给我们的完整配置项状态**（`result.configOptions`）——
  /// 见 [setSessionModel]：那里拿它当"到底切没切过去"的唯一判据。
  Future<List<dynamic>> setConfigOption(
    String sessionId,
    String configId,
    Object value,
  ) async {
    final res = await request('session/set_config_option', <String, dynamic>{
      'sessionId': sessionId,
      'configId': configId,
      'value': value,
    });
    final error = res['error'];
    if (error != null) {
      throw StateError('session/set_config_option 失败：'
          '${error is Map ? error['message'] : error}');
    }
    final result = res['result'];
    final raw = result is Map ? result['configOptions'] : null;
    final opts = raw is List ? raw : const <dynamic>[];
    // 顺手记下运行时报的当前模型（这就是"真的切过去了没有"的判据来源）。
    final route = modelRouteFromConfigOptions(opts);
    if (route != null) liveModelRoute = route;
    return opts;
  }

  /// ACP 里"模型"这个配置项的值就是 `["provider","model"]` 的 JSON 串
  /// （见 `@deepseek-ai/dsh-acp` 的 `modelValue()`），本地比对照样用它。
  static String modelOptionValue(String provider, String model) =>
      jsonEncode(<String>[provider, model]);

  /// 会话内切模型（`configId = 'model'`），并**用运行时自己返回的状态校验**。
  ///
  /// 为什么必须校验（用户实测第 2 条「选一次不行，要选第二次」的兜底）：
  /// `session/set_config_option` **返回成功 ≠ 选中的就是这个模型** —— 它只认
  /// **进程启动时已注册**的模型，别的组合会报 `unknown model option: [...]`。
  /// 而界面上显示的模型名来自本地 store，点一下就变了，于是会出现
  /// "界面说切了、进程里其实没切"。
  ///
  /// 所以这里把运行时回的 `currentValue` 当**唯一判据**：对不上就返回 false，
  /// 让上层走"重建会话"那条一定会生效的路，而不是留一个假成功。
  Future<bool> setSessionModel(
    String sessionId, {
    required String provider,
    required String model,
  }) async {
    final want = modelOptionValue(provider, model);
    final options = await setConfigOption(sessionId, 'model', want);
    for (final o in options) {
      if (o is Map && o['id'] == 'model') {
        final cur = '${o['currentValue']}';
        if (cur == want) return true;
        onLog?.call('[acp] 会话内切模型未生效：运行时报 currentValue=$cur，期望=$want');
        return false;
      }
    }
    onLog?.call('[acp] 切换响应里没有 model 配置项，按"未生效"处理');
    return false;
  }

  Future<void> cancel(String sessionId) async {
    _raw({
      'jsonrpc': '2.0',
      'method': 'session/cancel',
      'params': {'sessionId': sessionId},
    });
  }

  void respondPermission(dynamic requestId, {String? optionId}) {
    if (optionId == null) {
      _raw({
        'jsonrpc': '2.0',
        'id': requestId,
        'result': {
          'outcome': {'outcome': 'cancelled'},
        },
      });
    } else {
      _raw({
        'jsonrpc': '2.0',
        'id': requestId,
        'result': {
          'outcome': {'outcome': 'selected', 'optionId': optionId},
        },
      });
    }
  }

  Future<void> close() async {
    try {
      await process.stdin.close();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 300));
    process.kill();
    _closed = true;
  }
}

/// 服务端发来的权限请求。必须应答，否则会话会卡住。
///
/// ## 为什么要暴露 `toolCall` 里的详情
///
/// 原来界面只拿 `toolCallId` 去查工具卡，查不到就只剩一句「这是一次需要你
/// 确认的操作：」—— **没有工具名、没有参数**，用户根本没法判断该不该点允许。
/// 实测做发布截图时又撞上这个（HANDOFF §11.6 记的就是它）。
///
/// 协议形态（Zed ACP `session/request_permission`）：
/// ```
/// toolCall: { toolCallId, title, kind, status, content: [...], rawInput: {...} }
/// ```
/// 不同工具带的字段不完全一样，所以下面每个 getter 都可能是 null，
/// 界面必须能优雅退化成"如实说没取到详情"。
class AcpPermissionRequest {
  AcpPermissionRequest(
      {required this.client, required this.id, required this.params});

  final AcpClient client;
  final dynamic id;
  final Map<String, dynamic> params;

  Map<String, dynamic>? get toolCall {
    final t = params['toolCall'];
    return t is Map ? Map<String, dynamic>.from(t) : null;
  }

  String? get toolCallId {
    final v = toolCall?['toolCallId'] ?? params['toolCallId'];
    return (v is String && v.trim().isNotEmpty) ? v.trim() : null;
  }

  /// 人读的标题，如「Read file」「Run command」
  String? get toolTitle {
    final v = toolCall?['title'];
    return (v is String && v.trim().isNotEmpty) ? v.trim() : null;
  }

  /// 操作类别：read / edit / delete / move / search / execute / think / fetch / other
  String? get toolKind {
    final v = toolCall?['kind'];
    return (v is String && v.trim().isNotEmpty) ? v.trim() : null;
  }

  Object? get rawInput => toolCall?['rawInput'];

  /// 从 `content` 里抽第一段文本。ACP 常见形态：
  /// `[{type:'content', content:{type:'text', text:'…'}}]`（也可能直接是 text 块）。
  String? get firstContentText {
    final list = toolCall?['content'];
    if (list is! List) return null;
    for (final item in list) {
      if (item is! Map) continue;
      final inner = item['content'];
      if (inner is Map) {
        final t = inner['text'];
        if (t is String && t.trim().isNotEmpty) return t.trim();
      }
      final t = item['text'];
      if (t is String && t.trim().isNotEmpty) return t.trim();
    }
    return null;
  }

  /// 给用户看的「这一步要做什么」。
  ///
  /// 优先级：**标题 → 内容首段 → rawInput 紧凑 JSON**。
  /// 全都取不到时返回 null（界面如实说"没取到详情"，而不是给个空白框）。
  String? get actionSummary {
    final title = toolTitle;
    if (title != null) return title;
    final text = firstContentText;
    if (text != null) return text;
    final preview = rawInputPreview;
    return preview.isEmpty ? null : preview;
  }

  /// `rawInput` 的紧凑一行 JSON（超长截断），给「技术细节」与兜底摘要用。
  String get rawInputPreview {
    final raw = rawInput;
    if (raw == null) return '';
    try {
      final text = jsonEncode(raw);
      return text.length > 800 ? '${text.substring(0, 800)}…' : text;
    } catch (_) {
      final text = raw.toString();
      return text.length > 800 ? '${text.substring(0, 800)}…' : text;
    }
  }

  List<Map<String, dynamic>> get options =>
      (params['options'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  /// 允许一次 / 拒绝（DSH 只提供 allow_once 与 reject_once）。
  void allowOnce() => client.respondPermission(id, optionId: 'allow-once');
  void reject() => client.respondPermission(id, optionId: 'reject-once');
}
