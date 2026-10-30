import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'android_toolbox.dart';
import 'diagnostics_log.dart';
import 'dsh_runtime.dart';

/// 会话里的**本地 MCP 服务器** —— 我们自己实现的那个（`toolbox/mcp-office.mjs`）。
///
/// ## 它解决什么
///
/// WorkBuddy 靠本地 183MB 的文档引擎起一个 MCP 服务，把「改文档」变成工具调用
/// （302 个工具）。我们没有那个引擎，但 OOXML 的本质是 ZIP + XML，
/// `toolbox/office-zip.mjs` 已经是现成的 zip 读写库 —— 于是先用三个工具
/// （读单元格 / 写单元格 / 追加段落）把这条路打通。
///
/// ## 挂载方式：stdio（不是 http）
///
/// DSH 运行时的 `dsh-acp` 用 `resolveMcpConfigs()` 解析会话里的 `mcpServers`：
///   * **不带 `type` 字段** → 按 **stdio** 处理，由运行时自己 spawn 这个进程；
///   * `type: 'http'` → streamable-http，要我们自己另外起一个 HTTP 服务。
///
/// 选 stdio 的理由：
///   * 生命周期由运行时管（会话结束就关），我们不用管端口、也不用管僵尸进程；
///   * `command` 用手机里**唯一可执行**的 node（`<nativeLibraryDir>/libnode.so`）——
///     App 数据目录里的文件在 Android 上**不允许被执行**（实测 EACCES），
///     所以 `command` 必须是 nativeLibraryDir 里的那个，脚本本身只是被 node **读**。
///
/// ## ⚠️ 三条不能写错的约束
///
/// 1. `command` 必须是**绝对路径**（`resolveMcpConfigs` 会直接拒掉相对的）。
/// 2. `env` 是**有序的 name/value 条目数组**，不是普通 map（`entriesToRecord()` 会拒重复键）。
/// 3. `failOnStartupError: true` —— **这个服务起不来会连累整个会话**。
///    所以挂之前必须确认：运行时就绪、脚本已落盘、`command` 真的能执行。
///
/// ## 安全边界：只给最小 env，**绝不带 API Key**
///
/// 运行时的 `environment` 里含 `DEEPSEEK_API_KEY` / `COM_API_KEY` / `AGNES_API_KEY` /
/// `ROTATE_API_KEY`（见 `dsh_runtime.dart`）。MCP 服务器是**模型可调用的工具面**，
/// 它的进程环境不该带用户凭据 —— 这与"审计 P0-2：Key 不进模型驱动的 shell"是同一条边界。
/// 所以这里用白名单重建 env，只保留跑 node 与读文件真正需要的那些。
class LocalMcp {
  LocalMcp._();

  /// 服务器名（会变成模型看到的工具命名空间前缀）。
  static const String serverName = 'dsh-office';

  /// 脚本在私有目录里的落盘位置（由 [AndroidToolbox.ensureInstalled] 复制过去）。
  static String scriptPath(String filesDir) => '$filesDir/toolbox/mcp-office.mjs';

  /// 探活结果缓存（进程内有效）：null = 还没探过，true/false = 结论。
  ///
  /// 为什么要缓存：`session/new` 每次（含 resume）都会问一遍，每次都 spawn 一个 node
  /// 去探活太贵；而这个服务能不能起来在一次 App 生命周期内基本不会变。
  static bool? _probeOk;

  /// 诊断探针是否已经跑过（每个进程只跑一次，别拖慢后面每次建会话）。
  static bool _diagnosed = false;

  /// **挂之前先探活**：真的 spawn 一次 `libnode.so mcp-office.mjs`，发 MCP 的
  /// `initialize` + `tools/list`，5 秒内拿到带 `"tools"` 的回包才算能用。
  ///
  /// 为什么必须探（2026-10-20 真机 P0）：运行时对 MCP 是 `failOnStartupError: true` ——
  /// 服务器起不来会**连累整个 `session/new`**，日志原文
  /// `mcp-client(dsh-office): initial connection or tool synchronization failed`
  /// → 一条消息都发不出去。可选能力不该有这种破坏力，所以宁可少三个工具也不挂坏的。
  ///
  /// 失败时把 stderr 写进诊断日志（设备上我们看不到 MCP 进程的报错，这是唯一出口）。
  static Future<bool> probe({required DshRuntime runtime}) async {
    final cached = _probeOk;
    if (cached != null) return cached;
    final servers = mcpServers(runtime: runtime);
    if (servers.isEmpty) return _probeOk = false;
    final cfg = servers.first;
    final command = cfg['command'] as String;
    final args = (cfg['args'] as List<Object?>).cast<String>();
    final env = <String, String>{
      for (final e in (cfg['env'] as List<Object?>))
        (e as Map)['name'] as String: e['value'] as String,
    };

    Process? proc;
    final sw = Stopwatch()..start();
    try {
      // ⚠️ 必须跟 `acp_client` 那次 spawn **一模一样**（2026-10-20 真机第二次教训）：
      //    ACP 用的是 `includeParentEnvironment: true` + 一个可写的 workingDirectory，
      //    而第一版探活只给了白名单 env、也没设 cwd → 真机上「6s 内 tools/list 没应答」。
      //    node 在 Android 上起来需要父进程里的一些东西（库路径、系统变量），
      //    白名单只够"给 MCP 用"，不够"把 node 拉起来"。
      // ⚠️ 这里**刻意不加** `includeParentEnvironment`：探活必须与运行时真正用的
      //    环境（白名单）**完全一致**，否则"探活通过"就是自欺 —— 运行时那边照样挂。
      //    缺的系统变量应该补进 [_envEntries] 的白名单里（见那里）。
      proc = await Process.start(
        command,
        args,
        environment: env,
        workingDirectory: runtime.filesDir,
      );
      final stderrBuf = StringBuffer();
      // 进程提前退出（ENOENT/EACCES/import 失败）要能立刻知道，别干等超时。
      final exited = Completer<int>();
      proc.exitCode.then((c) {
        if (!exited.isCompleted) exited.complete(c);
      });
      proc.stderr.transform(utf8.decoder).listen((chunk) {
        // 只留前 800 字符：够看 Node 的报错头（ERR_MODULE_NOT_FOUND / EACCES 之类），
        // 又不至于让日志文件被刷爆。
        if (stderrBuf.length < 800) stderrBuf.write(chunk);
      });
      proc.stdin.write('{"jsonrpc":"2.0","id":1,"method":"initialize",'
          '"params":{"protocolVersion":"2024-11-05","capabilities":{},'
          '"clientInfo":{"name":"dsh-app","version":"0.80"}}}\n'
          '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
          '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n');
      await proc.stdin.flush();

      // ⚠️ 必须按 **id=2（tools/list）** 判，不能只看有没有 "tools" 字样：
      //    `initialize` 的回包里就带 `"capabilities":{"tools":{}}` —— 用它判会让
      //    「工具同步失败」被误判成通过（真机 2026-10-20 的失败恰恰发生在同步阶段）。
      final completer = Completer<bool>();
      final sub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (completer.isCompleted) return;
        try {
          final msg = jsonDecode(line);
          if (msg is! Map) return;
          if (msg['id'] != 2) return; // 只认 tools/list 的应答
          if (msg['error'] != null) {
            DiagnosticsLog.add('dsh-mcp', '探活失败（tools/list 报错）：$line');
            completer.complete(false);
            return;
          }
          final result = msg['result'];
          final tools = result is Map ? result['tools'] : null;
          if (tools is List) {
            DiagnosticsLog.add('dsh-mcp', '探活通过：$serverName 可用（${tools.length} 个工具，${sw.elapsedMilliseconds}ms）');
            completer.complete(true);
          } else {
            DiagnosticsLog.add('dsh-mcp', '探活失败（tools/list 没有 tools 数组）：$line');
            completer.complete(false);
          }
        } catch (_) {
          // 非 JSON 行（比如 node 的警告打到 stdout）→ 记下来，继续等
          if (stderrBuf.length < 800) stderrBuf.write('[stdout] $line; ');
        }
      });
      // 谁先来算谁：正常应答 / 进程提前退出 / 超时。
      final ok = await Future.any<bool>(<Future<bool>>[
        completer.future,
        exited.future.then((code) async {
          // ⚠️ 进程退出**不等于**它的 stderr 已经收完（2026-10-30 真机教训）：
          //    日志里只留下 `node 提前退出 exit=0`，stderr 一个字符都没有 ——
          //    而 exit=0 本身很反常（找不到脚本该是 1、dlopen 失败该是别的），
          //    于是"没线索"变成了"查不动"。这里多等 300ms 让管道里的尾巴吐完，
          //    并把 spawn 现场（命令/脚本是否落盘）一并写进日志，下次一次问清楚。
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (!completer.isCompleted) {
            DiagnosticsLog.add('dsh-mcp',
                '探活失败：node 提前退出 exit=$code'
                ' | 脚本=${_scriptFacts(scriptPath(runtime.filesDir))}'
                ' | 命令=$command'
                ' | cwd=${runtime.filesDir}'
                '${stderrBuf.isEmpty ? ' | stderr=(空)' : ' | stderr=${stderrBuf.toString().trim()}'}');
            completer.complete(false);
          }
          return false;
        }),
      ]).timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          // ⚠️ 超时也要带 stderr —— 第一版这里漏了，结果真机上什么都看不到。
          DiagnosticsLog.add('dsh-mcp',
              '探活超时（12s 内 tools/list 没应答，已用 ${sw.elapsedMilliseconds}ms）'
              '${stderrBuf.isEmpty ? '' : ' | stderr=${stderrBuf.toString().trim()}'}');
          return false;
        },
      );
      await sub.cancel();
      _probeOk = ok;
      if (!ok && !_diagnosed) {
        _diagnosed = true;
        unawaited(diagnose(runtime: runtime));
      }
      return ok;
    } on TimeoutException {
      // 超时往往意味着进程起来了但卡住（例如 import 挂在一个不存在的模块上不会卡，
      // 但等 stdin 的阻塞、或 node 起不来等 dlopen 失败会）。stderr 是第一手线索。
      DiagnosticsLog.add('dsh-mcp', '探活超时（5s 内没回包）→ 本次不挂 MCP，会话照开');
      _probeOk = false;
      return false;
    } catch (e) {
      DiagnosticsLog.add('dsh-mcp', '探活抛错 → 本次不挂 MCP，会话照开：$e');
      _probeOk = false;
      return false;
    } finally {
      try {
        proc?.kill();
      } catch (_) {}
    }
  }

  /// **诊断用**：主探活失败时，再用「带父环境」的方式跑一次，**只记结果、绝不用于挂载**。
  ///
  /// 为什么要它：主探活与运行时用同一份白名单 env（这样结论才可信），
  /// 但一旦失败，我们就分不清是"缺环境变量"还是"脚本/权限问题"。
  /// 这个诊断跑一次、把两种结论都写进日志，下次就能直接对着日志改，不用再猜一轮。
  static Future<void> diagnose({required DshRuntime runtime}) async {
    try {
      final servers = mcpServers(runtime: runtime);
      if (servers.isEmpty) return;
      final cfg = servers.first;
      final env = <String, String>{
        for (final e in (cfg['env'] as List<Object?>))
          (e as Map)['name'] as String: e['value'] as String,
      };
      final proc = await Process.start(
        cfg['command'] as String,
        (cfg['args'] as List<Object?>).cast<String>(),
        environment: env,
        includeParentEnvironment: true, // ← 只在诊断里开
        workingDirectory: runtime.filesDir,
      );
      final err = StringBuffer();
      proc.stderr.transform(utf8.decoder).listen((c) {
        if (err.length < 600) err.write(c);
      });
      proc.stdin.write('{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n');
      await proc.stdin.flush();
      var got = false;
      final sub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) {
        if (l.contains('"result"')) got = true;
      });
      await Future<void>.delayed(const Duration(seconds: 6));
      await sub.cancel();
      try {
        proc.kill();
      } catch (_) {}
      // 等进程退出的 stderr 尾巴，再下结论
      await Future<void>.delayed(const Duration(milliseconds: 300));
      DiagnosticsLog.add('dsh-mcp',
          got
              ? '诊断：带父环境能起来 → 说明缺的是环境变量（白名单还要补）'
              : '诊断：带父环境也起不来 → 不是环境问题'
                  ' | 脚本=${_scriptFacts(scriptPath(runtime.filesDir))}'
                  '${err.isEmpty ? ' | stderr=(空)' : ' | stderr=${err.toString().trim()}'}');
    } catch (e) {
      DiagnosticsLog.add('dsh-mcp', '诊断探针本身失败：$e');
    }
  }

  /// 探活失败时用的一句话现场：脚本到底在不在、多大。
  ///
  /// 为什么非要它：Android 上「脚本没落盘」和「脚本在但 node 起不来」的
  /// 表现完全不同（一个该 exit=1，一个可能 exit=0 什么都不说），
  /// 而这两种情况**只能靠现场判断**，猜不出来。
  static String _scriptFacts(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return '不存在($path)';
      return '${f.lengthSync()}B';
    } catch (e) {
      return '读不到($e)';
    }
  }

  /// 把探活结论作废（例如运行环境刚被换过）。
  static void invalidateProbe() => _probeOk = null;

  /// 给 ACP `session/new` / `session/resume` 用的 `mcpServers` 条目（stdio）。
  ///
  /// 返回空列表表示**这次不挂**（运行时没就绪 / 脚本没落盘）—— 此时会话照常开，
  /// 只是模型没有这三个工具。**绝不能因为挂不上就让会话开不起来。**
  static List<Map<String, dynamic>> mcpServers({required DshRuntime runtime}) {
    final node = runtime.nodeBinary;
    final script = scriptPath(runtime.filesDir);
    if (node.isEmpty || script.isEmpty) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      {
        'name': serverName,
        // 绝对路径：<nativeLibraryDir>/libnode.so（Android 上唯一能执行的东西）
        'command': node,
        // ⚠️⚠️ 必须带上与 ACP 完全相同的那组启动旗标（2026-10-30 补）。
        //
        // 这条是"为什么 ACP 能跑、MCP 不能"的最大嫌疑：同一个 libnode.so，
        // ACP 是带 `--expose-internals --require <fs shim> --require <exec shim>`
        // 起的（见 DshRuntime 类注释里那四条硬约束：Android 缺原生 addon，
        // 必须靠 expose-internals 顶上；SELinux 禁 link()、没有 bash，靠两个 shim 补），
        // 而 MCP 这边**只传了脚本路径**，等于裸跑 node。
        //
        // shim 只在文件真的落盘时才挂（桌面 / 还没解包时不硬塞，免得把探活弄崩）。
        'args': <String>[
          '--expose-internals',
          if (File(runtime.fsShim).existsSync()) ...<String>['--require', runtime.fsShim],
          if (File(runtime.execShimPath).existsSync())
            ...<String>['--require', runtime.execShimPath],
          script,
        ],
        // 白名单环境：**不含任何 API Key**（理由见类注释）
        'env': _envEntries(runtime),
      },
    ];
  }

  /// 最小 env（有序条目）。键名沿用 `DshRuntime.environment` 的那一套，
  /// 但**只取与"跑 node + 读写文件"有关的那几项**。
  static List<Map<String, String>> _envEntries(DshRuntime runtime) {
    // ⚠️ 写法注意：列表元素直接用 `{...}` 字面量（靠列表的类型实参推断成 Map）。
    // 写成 `<Map<String,String>>{...}` 会被解析成**集合**字面量，
    // 写成 `Map<String,String>{...}` 又会被报 "A map literal can't be prefixed by 'Map'"。
    final entries = <Map<String, String>>[
      {'name': 'LD_LIBRARY_PATH', 'value': runtime.nativeLibDir},
      {'name': 'HOME', 'value': runtime.filesDir},
      {'name': 'PATH', 'value': '/system/bin:/system/xbin'},
      {'name': 'TMPDIR', 'value': '${runtime.filesDir}/tmp'},
      {'name': 'DSH_HOME', 'value': runtime.nodeHome},
      {'name': 'DSH_ANDROID_NODE_BIN', 'value': runtime.nodeBinary},
      {'name': 'DSH_ANDROID_TOOLBOX', 'value': runtime.toolboxDir},
      {'name': 'DSH_ANDROID_TMPDIR', 'value': '${runtime.filesDir}/tmp'},
    ];

    // 2026-10-20 真机第二次教训：只给上面那 7 项时，探活「12s 内 tools/list 没应答」。
    // node 在 Android 上要起来，除了 LD_LIBRARY_PATH 还需要几个**系统级**变量
    // （Android 运行时会注入它们，但白名单把这层抹掉了）。
    // 这里从 App 自己的环境里**按名字**挑一批安全的补进去 ——
    // 规则写死：只认白名单里的名字，绝不带任何 `*_API_KEY` / `*_TOKEN` / `*_SECRET`。
    const safeNames = <String>{
      'ANDROID_ROOT', 'ANDROID_DATA', 'ANDROID_STORAGE', 'ANDROID_ASSETS',
      'ANDROID_ART_ROOT', 'ANDROID_I18N_ROOT', 'ANDROID_TZDATA_ROOT',
      'BOOTCLASSPATH', 'SYSTEMSERVERCLASSPATH',
      'LANG', 'LC_ALL', 'TZ',
    };
    final have = entries.map((e) => e['name']).toSet();
    for (final name in safeNames) {
      if (have.contains(name)) continue;
      final v = Platform.environment[name];
      if (v == null || v.isEmpty) continue;
      entries.add({'name': name, 'value': v});
    }
    return entries;
  }
}
