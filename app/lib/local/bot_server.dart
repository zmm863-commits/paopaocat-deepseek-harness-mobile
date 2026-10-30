import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, visibleForTesting;

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
    this.listenHost,
  });

  /// node 子进程句柄。**鸿蒙上为 null** —— 那边 node 跑在宿主进程内
  /// （dlopen libnode.so + node::Start），没有独立进程可管理。
  final Process? process;

  /// 带 token 的地址：`http://127.0.0.1:<port>/?token=…`。WebView 打开它。
  ///
  /// 开了「电脑访问」之后，这里会是 `http://<网卡地址>:<port>/?token=…` ——
  /// **由 App 自己把 host 换掉**（见 [_withHost]），不是 DSH 打印的：
  /// 随包运行时 0.1.7-rc.2 没有 `--public-url`，它只会打印回环地址。
  /// 手机本机访问自己的对外地址同样可用，所以 WebView 不用为绑定地址单独区分。
  final String url;

  final int port;

  /// 这次服务绑定的对外地址；null = 只绑回环。
  final String? listenHost;

  static BotServer? _current;

  /// 当前期望的对外绑定地址（null = 只绑回环）。
  ///
  /// 存成静态而不是只放在实例上：`ensureStarted` 被多个页面调用，重启判定要看
  /// 「这次请求的 host」和「上次启动用的 host」是否一致，实例可能已经没了。
  static String? _listenHost;

  /// 「调用方没指定绑定地址」的哨兵值（区别于「明确要求退回回环」）。
  static const Object _keepListenHost = Object();

  /// 传给 DSH 的信任围栏白名单（authority 列表，`host:port` 形式）。
  ///
  /// 为什么必须有（2026-10-27 用户报「网页能打开，但会话/模型/插件全空」）：
  /// 浏览器是用 `192.168.1.100:38747` 访问的，而 DSH 认为自己绑在
  /// `127.0.0.1:44033` —— 于是**所有 `/api/*` 请求都被 browser-trust fence
  /// 以 403 拒掉**（真机实测：`/api/directoryPicker/list`、
  /// `/api/llm/listProviders` 全是 `HTTP 403`），表现为工作区选不出来、
  /// 模型列表加载失败、插件读不全。页面本身是静态资源，所以看着能打开。
  static List<String> _trusted = const <String>[];

  /// 列表内容比较（顺序无关；[ensureStarted] 用它决定要不要重启）。
  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

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

  /// 是否跑在鸿蒙（flutter_ohos）上。
  ///
  /// 2026-10-28 真机实测：flutter_ohos 的 Platform.operatingSystem 返回 'ohos'。
  /// 用它做**正判**（Android 返回 'android'，恒 false，行为完全不变）。
  static bool _hostedOnOhos() {
    try {
      return Platform.operatingSystem == 'ohos';
    } catch (_) {
      return false;
    }
  }

  /// 挑一个当前空闲的端口（bind 一下再释放）。失败就退回 0（让系统挑）。
  static Future<int> _pickPort() async {
    if (_pinnedPort != 0) return _pinnedPort;
    // ⚠️ 鸿蒙：`ServerSocket.bind` 在 flutter_ohos 上**会永久挂起**（不返回也不抛），
    //    实测卡死在这里 → 整个 Bot 启动流程走不下去。直接退回 0，让 node 自己挑。
    if (_hostedOnOhos()) return 0;
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

  /// 鸿蒙：写 CLI 入口 wrapper 到 `<runtime>/lib/dsh-cli-wrapper.mjs`。
  ///
  /// 为什么必须有（2026-10-29 真机+qemu 双重实证）：
  ///   嵌入 node（dlopen libnode.so + node::Start）时，`import.meta.main` 恒为
  ///   undefined（process.argv 被 musl loader 污染），bin.js 末尾的
  ///   `if (import.meta.main) await runCli()` 永不执行 → DSH 静默退出 rc=0。
  ///   绕法：wrapper 显式 `import { runCli } from './bin.js'; await runCli()`。
  static Future<String> ensureOhosCliWrapper(DshRuntime runtime) async {
    final wrapper = File('${runtime.runtimeRoot}/lib/dsh-cli-wrapper.mjs');
    const body = "// 鸿蒙嵌入 node 专用入口：import.meta.main 在嵌入场景恒 undefined。\n"
        "import { runCli } from './bin.js';\n"
        "await runCli();\n";
    if (!wrapper.existsSync() || wrapper.readAsStringSync() != body) {
      wrapper.writeAsStringSync(body);
      DiagnosticsLog.add('dsh-bot', '已写鸿蒙 CLI wrapper：${wrapper.path}');
    }
    return wrapper.path;
  }

  /// 鸿蒙 `--jitless` 运行时补丁（最关键的一块）。
  ///
  /// 背景链（真机 probeMemory 实测）：
  ///   1. 鸿蒙 W^X 策略拒绝 PROT_EXEC（mmap/mprotect 都返回 EINVAL）⇒ 必须 --jitless
  ///   2. --jitless 连带禁用 WebAssembly，而 node 内置 undici 的 llhttp 是 WASM
  ///   3. 两处触发点：
  ///      A. ESM 加载 node:http 时 syncExports 遍历导出 → 命中 WebSocket getter
  ///         → lazyUndici() → 加载内置 undici → 崩
  ///      B. globalThis.fetch 本身就是内置 undici 的 lazy getter，读它就加载
  ///   ⇒ 本 shim 在 CJS 阶段拆 A 的 getter、把 B 换成 node-fetch（纯 JS 走
  ///     node:http，零 undici 依赖；runtime 自带 3.3.2）。
  ///
  /// ⚠️ 覆盖 fetch 必须「直接赋值」，**不能用 Object.defineProperty** ——
  ///    后者会触发 realm 的 syncExports，反而把 fetch getter 求值掉（实测踩过）。
  static Future<String> ensureOhosJitlessShim(DshRuntime runtime) async {
    final shim = File('${runtime.runtimeRoot}/lib/jitless-shim.cjs');
    const body = "// 鸿蒙 --jitless 运行时补丁（--require 加载，必须最先）\n"
        "'use strict';\n"
        "const path = require('node:path');\n"
        "// A. 拆掉会拉 undici 的 lazy getter（保留 globalAgent/maxHeaderSize 等功能）\n"
        "const UNDICI_EXPORTS = ['WebSocket', 'CloseEvent', 'MessageEvent'];\n"
        "for (const name of ['node:http', 'node:https']) {\n"
        "  try {\n"
        "    const m = require(name);\n"
        "    for (const key of UNDICI_EXPORTS) {\n"
        "      const d = Object.getOwnPropertyDescriptor(m, key);\n"
        "      if (d && typeof d.get === 'function') {\n"
        "        Object.defineProperty(m, key, { value: undefined, writable: true, configurable: true });\n"
        "      }\n"
        "    }\n"
        "  } catch (e) { /* 模块不存在就跳过 */ }\n"
        "}\n"
        "// B. 用 node-fetch 接管 fetch（v3 是 ESM；node 22.12+/24 支持 CJS require(ESM)）\n"
        "try {\n"
        "  const nfPath = path.join(__dirname, '..', 'node_modules', 'node-fetch', 'src', 'index.js');\n"
        "  const nf = require(nfPath);\n"
        "  globalThis.fetch = nf.default ?? nf;\n"
        "  if (nf.Headers) globalThis.Headers = nf.Headers;\n"
        "  if (nf.Request) globalThis.Request = nf.Request;\n"
        "  if (nf.Response) globalThis.Response = nf.Response;\n"
        "  process.stderr.write('[jitless-shim] node-fetch 已接管 fetch，undici 不会被加载\\n');\n"
        "} catch (e) {\n"
        "  process.stderr.write('[jitless-shim] node-fetch 接管失败: ' + (e && e.message) + '\\n');\n"
        "}\n";
    if (!shim.existsSync() || shim.readAsStringSync() != body) {
      shim.writeAsStringSync(body);
      DiagnosticsLog.add('dsh-bot', '已写鸿蒙 jitless 补丁：${shim.path}');
    }
    return shim.path;
  }

  /// 清掉 Bot 团队的单实例锁（详见调用处的注释）。
  ///
  /// 只在**本机没有第二个 DSH** 时才安全 —— 手机端正是这种情况：BotServer 是单例，
  /// 每次重启都先 `stop()` 旧进程。所以这里无条件删；删不掉只记日志，绝不抛。
  @visibleForTesting
  static Future<void> clearStaleBotLock(DshRuntime runtime) async {
    try {
      final f = File('${runtime.nodeHome}/bot/state.lock');
      if (!f.existsSync()) return;
      String? holder;
      try {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map && raw['pid'] != null) {
          holder = 'pid=${raw['pid']} host=${raw['host'] ?? '?'}';
        }
      } catch (_) {
        // 解析不了（写一半）也照删：那种状态 ds-bot 自己会按 mtime 判，删了更干净。
      }
      f.deleteSync();
      DiagnosticsLog.add('dsh-bot',
          '已清掉 Bot 单实例锁${holder == null ? '' : '（原持有者 $holder）'}'
          ' —— 手机端只可能有一个 DSH，留着它会让人以为"另一个窗口开着"');
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '清 Bot 单实例锁失败（不影响其它功能）：$e');
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
      await ensureStarted(runtime: runtime, onLog: onLog, listenHost: _listenHost);
      DiagnosticsLog.add('dsh-bot', '模型配置已变更 → Bot 服务已重启（带上新的 overlay）');
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '模型配置变更后重启 Bot 服务失败：$e');
    }
  }

  /// 给随包运行时打一个 **Android 专用**的小补丁（幂等）。
  ///
  /// 为什么（2026-10-24 真机实测，用户报「添加文件点了没反应/上传失败」）：
  /// DSH 的附件存储 `dsh-attachment-local` 在第一次把 DSH_HOME 标记为 durable 时，
  /// 会从 home 一路 `fsync` 到文件系统根：
  ///   `ensureDurableHome()` → `ensureDurableDirectory(home, parse(home).root)`
  /// 其中 `syncDirectory(parent)` 要 `open('/data/user/0')` —— App 沙箱里这个目录
  /// 读不了，Node 直接抛：
  ///   `failed to store file upload: Error: EACCES: permission denied, open '/data/user/0'`
  /// 用户看到的就是「文件选进来了、一直显示上传失败」。
  ///
  /// 补丁只做一件事：把 `chmod` 与 `syncDirectory` 各包一层 catch。
  /// Android 沙箱内父目录不可 open 是正常情况，不该让整个上传失败。
  ///
  /// ⚠️ 这是**运行时文件**补丁（不是源码），所以：① 必须幂等（用 marker 判重）；
  /// ② 写临时文件再 rename，避免进程读到半截文件；③ 运行时版本一变要重新核对
  /// 替换字符串是否还在（找不到就只记日志，不静默）。
  static Future<void> _patchAttachmentDurability(DshRuntime runtime) async {
    try {
      final f = File('${runtime.runtimeRoot}/node_modules/'
          '@deepseek-ai/dsh-attachment-local/lib/index.js');
      if (!f.existsSync()) return;
      final src = await f.readAsString();
      const marker = '/* dshm-android-durable-patch */';
      if (src.contains(marker)) return;
      final out = src
          .replaceAll(
            'await chmod(target, 448);',
            'await chmod(target, 448).catch(() => {}); $marker',
          )
          .replaceAll(
            'await syncDirectory(parent);',
            'await syncDirectory(parent).catch(() => {});',
          );
      if (out == src) {
        DiagnosticsLog.add('dsh-bot', '附件存储补丁未命中（运行时版本可能变了），上传可能仍报 EACCES');
        return;
      }
      final tmp = File('${f.path}.dshm-tmp');
      await tmp.writeAsString(out, flush: true);
      await tmp.rename(f.path);
      DiagnosticsLog.add('dsh-bot', '已给运行时打附件存储补丁（Android 父目录不可 fsync）');
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '附件存储补丁失败（上传会继续报 EACCES）：$e');
    }
  }

  /// 与 `install/patch-dsbot-web.mjs` **一一对应**的 8 处裁剪（`[锚点, 替换]`）。
  ///
  /// 两个地方必须同步改：这里（已装机器自愈）与那个脚本（运行时种子）。
  /// 锚点任何一个没命中，[BotServer._patchBotWeb] 就整体放弃、只记日志 ——
  /// 半改最坏：菜单去了一半，用户看不出是"没生效"还是"改错了"。
  static const List<List<String>> _botWebTrims = <List<String>>[
    <String>[
      '    () => shadow("sidebar.footer.action", { id: "bot-connect", order: -100, inject: face }, ConnectPlugins),\n',
      '',
    ],
    <String>[
      '      [t("Automation tasks"), ClockIcon, () => actions.selectPanel("schedules")],\n',
      '',
    ],
    <String>[
      '    ],\n    [\n      [t("Switch to classic Agent mode"), SwitchIcon, () => actions.setSurface("agent")]\n    ]\n  ];',
      '    ]\n  ];',
    ],
    <String>[
      '      (0, import_react11.createElement)("button", { type: "button", role: "menuitem", onClick: schedule }, (0, import_react11.createElement)(ClockIcon), (0, import_react11.createElement)("span", { className: "bt-menu-label" }, t("Scheduled task")))\n',
      '',
    ],
    <String>[
      '["schedules", "Scheduled tasks"], ',
      '',
    ],
    <String>[
      '    (0, import_react30.createElement)(\n      SetSection,\n      { key: "mode", title: t("Mode") },\n      (0, import_react30.createElement)(\n        SetRow,\n        { label: t("Classic Agent mode") },\n        (0, import_react30.createElement)("button", { type: "button", className: "bt-soft bt-soft-sm", onClick: () => actions.setSurface("agent") }, t("Switch"))\n      )\n    )\n',
      '',
    ],
    <String>[
      '    (0, import_react19.createElement)(BotSchedules, { bot, roster, actions }),\n',
      '',
    ],
    <String>[
      '        (0, import_react33.createElement)(ScheduleSummary, { key: "routines", bot, actions })\n',
      '',
    ],
    <String>[
      '  "Could not reach DSH. Check that it is still running.": "连不上 DSH，请确认它还在运行。",',
      '  "Could not reach DSH. Check that it is still running.": "连不上泡泡猫 DSH，请确认它还在运行。",',
    ],
  ];

  /// 网页版 Bot 页的**产品化裁剪** —— 给 ds-bot 的 client 包打补丁（用户 2026-10-28 要求）：
  /// ① 去掉侧栏底部「连接插件」入口；② 左下角小金鱼菜单里去掉「定时任务」和
  /// 「切换经典 Agent 模式」；③ 对话框「+」菜单去掉「定时任务」；④ 设置里也去掉这两项。
  ///
  /// 为什么必须放在 **App 侧**（而不是只改运行时包里的种子）：[ensureProfile] 只在
  /// `profiles/bottest` **不存在**时才从种子复制 —— 覆盖安装的机器上那个目录早就在了，
  /// 种子里改得多干净都进不去。所以照 [_patchAttachmentDurability] 的老套路：
  /// 幂等 marker 判重、写临时文件再 rename、锚点找不到只记日志不硬改。
  ///
  /// 与 `install/patch-dsbot-web.mjs` **同一套锚点** —— 两个地方必须一起改，
  /// ds-bot 升版后锚点会失效，那时两边都要重新核对。
  static Future<void> _patchBotWeb(DshRuntime runtime) async {
    try {
      final f = File('${runtime.nodeHome}/profiles/$profileName/'
          'node_modules/ds-bot/client.js');
      if (!f.existsSync()) return;
      var src = await f.readAsString();
      const markPrefix = '/* dshm-web-trim:';
      const legacyMark =
          '/* dshm-web-trim: ds-bot 网页版裁剪（连接插件/定时任务/经典 Agent 模式） */';
      final applied = <int>{};
      String? strip;
      if (src.startsWith(legacyMark)) {
        // 第一版（1~8 条）的标记，迁移成带 id 的新标记。
        applied.addAll(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
        strip = legacyMark;
      } else {
        final at = src.indexOf(markPrefix);
        final end = at < 0 ? -1 : src.indexOf('*/', at);
        if (at >= 0 && end > at) {
          strip = src.substring(at, end + 2);
          for (final part in strip.substring(markPrefix.length, strip.length - 2).split(',')) {
            final id = int.tryParse(part.trim());
            if (id != null && id > 0) applied.add(id);
          }
        }
      }
      // 只补没应用过的条目 —— 加了新条目之后老文件也能增量补齐。
      final pending = <int>[
        for (var i = 0; i < _botWebTrims.length; i++)
          if (!applied.contains(i + 1)) i
      ];
      if (pending.isEmpty) return;
      final missed = <String>[];
      for (final i in pending) {
        if (!src.contains(_botWebTrims[i][0])) missed.add(_botWebTrims[i][0]);
      }
      if (missed.isNotEmpty) {
        // 版本变了 → 一条都不改（半改最坏：菜单去了一半，用户以为"没生效"）。
        DiagnosticsLog.add('dsh-bot',
            'Bot 网页裁剪有 ${missed.length} 处锚点没命中（ds-bot 版本可能变了），本次不改');
        return;
      }
      if (strip != null) {
        src = src.substring(strip.length).replaceFirst(RegExp(r'^\r?\n'), '');
      }
      for (final i in pending) {
        src = src.replaceAll(_botWebTrims[i][0], _botWebTrims[i][1]);
      }
      final ids = <int>{...applied, ...pending.map((i) => i + 1)}.toList()..sort();
      final tmp = File('${f.path}.dshm-tmp');
      await tmp.writeAsString('$markPrefix${ids.join(',')} */\n$src', flush: true);
      await tmp.rename(f.path);
      DiagnosticsLog.add('dsh-bot', '已给 ds-bot 打网页版裁剪补丁（补了 ${pending.length} 条，共 ${ids.length} 条）');
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', 'Bot 网页裁剪补丁失败（这几项还会显示）：$e');
    }
  }

  /// 起服务（已起着就直接复用）。
  ///
  /// [onLog] 收启动过程的原始行，供调用方显示"卡在哪一步"。
  ///
  /// [listenHost] 传一个本机网卡地址（`LanEndpoints` 里的 `address`）就绑到它、
  /// 并对该网络开放；**明确传 null** 表示退回只绑回环；**不传**表示沿用当前设置。
  /// **换地址必须重启进程** —— DSH 的 `--host` 是启动参数，改不了热绑定。
  ///
  /// 为什么用哨兵而不是 `String? listenHost = null`：Bot 页调用时不带这个参数，
  /// 如果默认值就是 null，那么用户刚在设置里开了「电脑访问」，一进 Bot 页就会被
  /// 静默重起回回环 —— 表现是「电脑突然连不上了，还不知道为什么」。
  static Future<BotServer> ensureStarted({
    required DshRuntime runtime,
    void Function(String line)? onLog,
    Object? listenHost = _keepListenHost,
    List<String> trustedAuthorities = const <String>[],
  }) async {
    final wanted = identical(listenHost, _keepListenHost)
        ? _listenHost
        : _normalizeHost(listenHost is String ? listenHost : null);
    final trusted = trustedAuthorities
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();
    final running = _current;
    if (running != null && running.alive) {
      if (running.listenHost == wanted && _sameList(_trusted, trusted)) {
        return running;
      }
      // 绑定地址或信任列表变了 → 只能重启（都是启动参数，热改不了）。
      DiagnosticsLog.add('dsh-bot',
          '启动参数变化（绑定 ${running.listenHost ?? '回环'} → ${wanted ?? '回环'}，'
          'trusted ${_trusted.length} → ${trusted.length} 条）→ 重启 web 服务');
      await running.stop();
    } else if (running != null) {
      await running.stop();
    }
    _listenHost = wanted;
    _trusted = trusted;

    // 运行时的 Android 兼容补丁：附件上传的 durable 提升会 fsync 到 /data/user/0
    // （App 沙箱内不可 open）→ 上传必失败。幂等，每次启动都过一遍。
    await _patchAttachmentDurability(runtime);

    // 端口必须在拼 args 之前定好（重启复用同一个，见 [_pinnedPort]）。
    await _pickPort();

    await ensureProfile(runtime);

    // profile 落好之后再裁剪网页版（已装机器上 profile 早就存在 → 必须在 ensureProfile 之后）。
    await _patchBotWeb(runtime);

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

    // Bot 单实例锁：**pid 复用的坑**（2026-10-30 真机）。
    //
    // ds-bot 用 `dshhome/bot/state.lock`（JSON: pid/host/token）做单写者互斥：
    // 同主机时它拿 `process.kill(pid, 0)` 判活，活着的就认为"另一个 dsh 正在用"，
    // 于是 Bot 页变成**只读**，顶部写「Bot 团队已在另一个 dsh 中打开（pid NNN）」
    // —— 用户真机报的就是这个（pid 6982 早已不是我们的进程，只是 Android 把
    // pid 复用了）。
    //
    // 手机上**只可能有一个 DSH**（BotServer 是单例，重启前必先把旧进程停掉），
    // 所以启动前把这个锁清掉是安全的；不清的话用户会遇到"只能看不能改"，
    // 而他根本找不到那个"另一个 dsh"。
    await clearStaleBotLock(runtime);

    // 鸿蒙：CLI 入口换成 wrapper（import.meta.main 坑），并准备好 --jitless 补丁。
    // 详见 [ensureOhosCliWrapper] / [ensureOhosJitlessShim] 的说明。
    var cliEntry = runtime.dshBin;
    String? jitlessShim;
    if (_hostedOnOhos()) {
      cliEntry = await ensureOhosCliWrapper(runtime);
      jitlessShim = await ensureOhosJitlessShim(runtime);
    }

    // 这次要绑哪个地址（null = 只绑回环）。读静态值而不是参数：降级重试时会把
    // `_listenHost` 清空，proc 起来之前这里必须拿到的是**最终**决定。
    final host = _listenHost;

    final args = <String>[
      // ⚠️ 必须在最前：见类注释「硬约束 1」。
      '--expose-internals',
      // ── 鸿蒙关键 flag（2026-10-29 真机+qemu 实证）─────────────────────
      // 鸿蒙 W^X 策略拒绝 PROT_EXEC（native 探针实测 mmap/mprotect 都返回 EINVAL）
      // ⇒ 必须 --jitless。它连带禁用 WebAssembly，所以还要配上面的 jitlessShim
      // 把 undici 的 WASM llhttp 彻底绕开。
      if (_hostedOnOhos()) '--jitless',
      // ⚠️ jitlessShim 必须排在 fsShim 之前：它要最早把 node:http 的 getter 拆掉。
      if (jitlessShim != null) ...['--require', jitlessShim],
      '--require', runtime.fsShim,
      // 执行环境 shim：Android 上没有 bash，而 DSH 的 bash 工具写死了 spawn('bash')。
      // Bot 要能干活（跑命令、写文件）就靠它。
      '--require', runtime.execShimPath,
      cliEntry,
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
      // ── 「电脑访问」：绑到某一张具体网卡 ────────────────────────────────
      //
      // 为什么必须给具体地址：`dsh --profile web --help` 明确写着 wildcard 地址
      // 会被拒绝，`--host` 只能是某个本地接口的 IPv4/IPv6 字面量。
      //
      // --trusted-host：浏览器的 `/api` 信任围栏（fence）要认这个 authority。
      //   少了它，电脑上首页能打开、接口全被拒 —— 表现为「界面空壳」。
      //
      // ⚠️⚠️ **绝对不要在这里加 `--public-url`**（2026-10-26 真机踩的坑）：
      //   随包运行时是 `dsh-web-app 0.1.7-rc.2`，它的选项白名单只有
      //   `--host` / `--port` / `--no-open` / `--trusted-host` 四个，
      //   `--public-url` 是 0.2.x 才加的。多传一个它不认识的选项 → 进程
      //   直接 `error: unknown option '--public-url'` 退出 → 表现就是
      //   「打开开关、服务起了一下、又退回 127.0.0.1」，而且界面上只有一句
      //   「不支持对外监听」，根本看不出是哪一个参数惹的祸。
      //   对外地址改为拿到 token 之后自己拼（见 [_withHost]）。
      //
      // ⚠️ 这些是 web app 的参数，必须留在 `--no-open` **之后**：`dsh` 的
      //    launcher 一旦遇到自己不认识的 token，后面全部当 profile 内部参数
      //   （踩过，见上面 --patch 那段 2026-10-19 的记录）。
      if (host != null) ...[
        '--host', host,
        '--trusted-host', '$host:$_pinnedPort',
      ],
      // 信任围栏白名单：浏览器从「网卡地址:转发端口」访问时，`/api/*` 的
      // Host 不是 DSH 自己（它绑回环），不加这几条 → 全部 403。
      // 0.1.7-rc.2 的 `--trusted-host <authority...>` 是可重复的。
      for (final a in _trusted) ...['--trusted-host', a],
    ];

    onLog?.call('[dsh-bot] 启动：--profile $profileName --no-open --port $_pinnedPort'
        '${host == null ? '' : ' --host $host'}');
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

    final urlCompleter = Completer<Uri>();
    final outTail = <String>[];
    final errTail = <String>[];
    var exited = false;
    Process? process;

    if (_hostedOnOhos()) {
      // ── 鸿蒙：**在宿主进程内**启动 node（见 DshHost.startNodeArgs 的说明）──
      // 没有子进程，所以没有 stdout stream / exitCode / kill —— 靠轮询落盘文件。
      final urlLog = File('${runtime.filesDir}/dsh-web-url.log');
      if (urlLog.existsSync()) {
        try {
          urlLog.deleteSync();
        } catch (_) {}
      }
      final started = await DshHost.startNodeArgs(
        args: args,
        env: env,
        stdoutPath: urlLog.path,
        tracePath: '${runtime.filesDir}/dsh-node-trace.log',
      );
      if (started['ok'] != true) {
        throw StateError(
            '宿主进程内启动 node 失败：${started['error'] ?? '未知原因'}');
      }
      DiagnosticsLog.add('dsh-bot',
          'node 已在宿主进程内启动（argc=${started['argc']}），轮询落盘日志抓就绪行');
      // 轮询：jitless 是解释器模式，冷启比 Android 慢不少，给足 150 秒。
      unawaited(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 150));
        var lastLen = 0;
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          if (!urlLog.existsSync()) continue;
          String txt;
          try {
            txt = urlLog.readAsStringSync();
          } catch (_) {
            continue;
          }
          if (txt.length == lastLen) continue;
          lastLen = txt.length;
          for (final line in txt.split('\n')) {
            final t = line.trim();
            if (t.isEmpty) continue;
            if (t.startsWith('[INFO:flutter') || t.startsWith('[INFO:')) continue;
            if (t.length > 400) continue;
            if (!outTail.contains(t)) {
              outTail.add(t);
              if (outTail.length > 40) outTail.removeAt(0);
              onLog?.call(t);
              DiagnosticsLog.add('dsh-bot:node', t);
            }
          }
          final m = RegExp(r'https?://\S+').firstMatch(txt);
          if (m != null && !urlCompleter.isCompleted) {
            final rawUrl = m.group(0)!.replaceAll(RegExp(r'[.,;)]+$'), '');
            urlCompleter.complete(Uri.parse(rawUrl));
            return;
          }
          // 崩溃现场：trace 里有 CRASH 就提前报错，别干等 150 秒
          final trace = File('${runtime.filesDir}/dsh-node-trace.log');
          if (trace.existsSync()) {
            try {
              final tt = trace.readAsStringSync();
              if (tt.contains('CRASH signal=')) {
                final line = tt
                    .split('\n')
                    .lastWhere((l) => l.contains('CRASH'), orElse: () => '');
                if (!urlCompleter.isCompleted) {
                  urlCompleter.completeError(StateError('node 崩溃：$line'));
                }
                return;
              }
            } catch (_) {}
          }
        }
        if (!urlCompleter.isCompleted) {
          urlCompleter.completeError(StateError(
              'node 150 秒内没有报告就绪地址：${_tail(errTail, outTail)}'));
        }
      }());
    } else {
      // ── Android / 桌面：仍是子进程 ──
      process = await Process.start(
        runtime.nodeBinary,
        args,
        environment: env,
        includeParentEnvironment: true,
        // ⚠️ 工作目录必须和 App 主界面**同一个**（2026-10-27 定位到的根因）：
        //    DSH 的会话是**按 cwd 分组**存在 `<DSH_HOME>/sessions/--<路径转义>--/` 下的。
        //    以前这里写死 nodeHome，于是 bottest 读写的是
        //    `sessions/--<dshhome>--`，而 App 对话写在 `sessions/--<workspace>--`
        //    —— 两套目录互不相干，所以浏览器里永远是「暂无会话」。
        workingDirectory: _sessionWorkingDir(runtime),
      );

      final proc = process;
      proc.stdout
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

      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.trim().isEmpty) return;
        errTail.add(line);
        if (errTail.length > 40) errTail.removeAt(0);
        onLog?.call(line);
        DiagnosticsLog.add('dsh-bot:err', line);
      }, onError: (Object e) => debugPrint('[dsh-bot] stderr 错误：$e'));

      unawaited(proc.exitCode.then((code) {
        exited = true;
        if (_current?.process == proc) {
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
    }

    // 首次启动要把 dsh 的插件树拉起来，冷启实测 10~25 秒；给足 90 秒，
    // 超时如实把两个流最后几行抛出去（用户才知道卡在哪）。
    late final Uri url;
    try {
      url = await urlCompleter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw StateError(
            'Bot 服务 90 秒内没有报告地址${exited ? '' : '（进程还在跑）'}：'
            '${_tail(errTail, outTail)}'),
      );
    } catch (e) {
      // 随包运行时可能比本地打包的那份老（手机上是用户装的那个 APK 自带的 zip），
      // 老版本 web app 不认 `--host` / `--public-url` / `--trusted-host` →
      // dsh 以 `error: unknown option '--host'` 直接退出（这正是 2026-10-19
      // `--patch` 顺序踩过的坑）。**不能把整个 Bot 页带崩**：退回只绑回环，
      // 本机照常用，只在日志里说清楚「电脑访问没开成」。
      final msg = '$e';
      if (host != null && msg.contains('unknown option')) {
        try {
          process?.kill(ProcessSignal.sigkill);
        } catch (_) {}
        _listenHost = null;
        DiagnosticsLog.add('dsh-bot',
            '运行时不吃 --host/--trusted-host（unknown option）→ 已退回只绑回环，电脑访问不可用：$msg');
        onLog?.call('[dsh-bot] 运行时太老，不支持对外监听 → 已退回本机模式');
        return ensureStarted(runtime: runtime, onLog: onLog, listenHost: null);
      }
      rethrow;
    }

    // 绑了网卡时，stdout 那行打印的仍然是 `127.0.0.1`（0.1.7-rc.2 没有
    // --public-url 能改它）→ 自己把 host 换掉，token 原样保留。
    // 不换的话交给用户的地址在电脑上指向**电脑自己**，永远打不开。
    final exposedUrl = host == null ? url : _withHost(url, host);

    final server = BotServer._(
      process: process,
      url: exposedUrl.toString(),
      port: url.port,
      listenHost: host,
    );
    _current = server;
    live.value = server;
    DiagnosticsLog.add('dsh-bot',
        'Bot 服务已就绪：端口 ${server.port}，绑定 ${host ?? '回环（仅本机）'}');
    return server;
  }

  /// 把「用户/界面传进来的 host」规整成绑定决定：空串、回环、`0.0.0.0` 一律当"不对外"。
  ///
  /// 为什么连 `0.0.0.0` 也要拦：DSH 的 `--host` **拒绝 wildcard**，传了会直接退出
  /// （`--help` 里写明「wildcard addresses are rejected」）。与其让它报错，不如老老实实
  /// 退回回环，界面再提示「请选择一张网卡」。
  static String? _normalizeHost(String? raw) {
    final h = (raw ?? '').trim();
    if (h.isEmpty) return null;
    if (h == '127.0.0.1' || h == 'localhost' || h == '::1') return null;
    if (h == '0.0.0.0' || h == '::' || h == '*') return null;
    return h;
  }

  /// 会话应该归属的工作目录 —— **必须和 App 主界面是同一个目录**。
  ///
  /// 为什么（2026-10-27 用户报「网页打得开，但看不到手机上的会话和模型」）：
  /// DSH 的会话是**按 cwd 分组**存在 `<DSH_HOME>/sessions/--<路径转义>--/` 里的。
  /// App 主界面（ACP）启动时的 cwd 是用户选中的工作区
  /// （默认 `${filesDir}/workspace`，自建的在 `${filesDir}/workspaces/<名字>`，
  /// 清单在 `${filesDir}/workspaces.json`）。而这里以前用的是 `nodeHome`，
  /// 于是 bottest 读写的是 `sessions/--<dshhome>--`，和主界面**不是同一棵目录树**
  /// —— 表现就是网页里永远「暂无会话」。
  ///
  /// 目录不存在时兜底建默认工作区（DSH 不接受一个不存在的 cwd）。
  static String _sessionWorkingDir(DshRuntime runtime) {
    final def = '${runtime.filesDir}/workspace';
    var path = def;
    try {
      final f = File('${runtime.filesDir}/workspaces.json');
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map) {
          final cur = raw['currentPath'];
          if (cur is String && cur.trim().isNotEmpty) path = cur.trim();
        }
      }
    } catch (e) {
      DiagnosticsLog.add('dsh-bot', '读 workspaces.json 失败（回退默认工作区）：$e');
    }
    try {
      final d = Directory(path);
      if (!d.existsSync()) d.createSync(recursive: true);
    } catch (_) {
      path = def;
    }
    DiagnosticsLog.add('dsh-bot', 'Bot 服务工作目录：$path（与主界面同源）');
    return path;
  }

  /// 把 DSH 打印的回环地址换成对外地址，token 原样保留。
  ///
  /// 为什么必须自己换（2026-10-26 真机）：随包运行时 `dsh-web-app 0.1.7-rc.2`
  /// **不认识 `--public-url`**（那是 0.2.x 的选项），所以即使成功绑了 `--host`，
  /// 它在 stdout 里打印的仍然是 `http://127.0.0.1:<port>/?token=…`。
  /// 把这个地址给用户 = 在电脑上打开电脑自己的回环，永远连不上。
  static Uri _withHost(Uri url, String host) {
    final token = url.queryParameters['token'];
    final q = (token == null || token.isEmpty) ? '' : '?token=$token';
    return Uri.parse('http://$host:${url.port}/$q');
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
    final proc = process;
    if (proc == null) {
      // 鸿蒙：node 在宿主进程内，**没法单独结束**（node::Start 每进程只能调一次，
      // 强行终止会带走整个 App）。这里只标记退出，真正重启只能靠重开 App。
      DiagnosticsLog.add('dsh-bot',
          '鸿蒙：node 在宿主进程内无法单独停止（已标记退出，重启需重开 App）');
      return;
    }
    try {
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      try {
        proc.kill(ProcessSignal.sigkill);
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
