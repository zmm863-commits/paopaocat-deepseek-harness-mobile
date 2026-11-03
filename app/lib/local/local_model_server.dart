import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;

import '../i18n/dsh_i18n.dart' show tr;
import 'diagnostics_log.dart';
import 'local_model_spec.dart';
import 'model_crash_store.dart';
import 'loose_chat_templates.dart';
import 'dsh_runtime.dart';
import 'model_manifest.dart';

// 让调用方从这一个文件就能拿到 LocalModelSpec（少一个 import 要记）。
export 'local_model_spec.dart';

/// 推理后端。**同一个 APK 里两个都有**（llama.cpp 编了 Vulkan 也会保留 CPU 后端），
/// 靠 `-ngl`（offload 到 GPU 的层数）切换：0 = 纯 CPU，99 = 尽量都上 GPU。
///
/// 为什么要在 App 里可切：P1 要回答的正是"Vulkan 到底快多少"，
/// 而这个问题**只有用户那台手机上的实测数字**能回答 —— 所以把切换和测速都做进 App，
/// 用户点两下就得到对比表，不用我们猜。
enum LocalModelBackend {
  cpu,
  vulkan;

  /// 界面上的名字。**必须走 `tr`**：这是给用户看的字（拿不到 context，用全局 tr）。
  String get label => switch (this) {
        // 名字直接说"差在哪"，不再用 Vulkan 这种术语开头 ——
        // 用户真机反馈：他以为"仅 CPU = 普通手机、GPU = 旗舰手机"。
        LocalModelBackend.cpu => tr('CPU（慢一点）'),
        LocalModelBackend.vulkan => tr('GPU（通常快很多・推荐）'),
      };

  /// 按钮上的**短名**：两颗按钮要能并排一行。
  ///
  /// 为什么单独一个（而不是直接用 [label]）：完整名字是"GPU（通常快很多・推荐）"
  /// 这么长，两颗并排必然各占一行 —— 用户反馈的"排版太乱"里就有这一块。
  /// 完整说明改放在按钮**下方一行**（见页面），一眼能看全。
  String get shortLabel => switch (this) {
        LocalModelBackend.cpu => 'CPU',
        LocalModelBackend.vulkan => 'GPU',
      };

  /// 传给 llama-server 的 `-ngl` 值（offload 到 GPU 的层数）。
  ///
  /// 只有 CPU 是纯 CPU（0），其余档都按"尽量上 GPU"传（99）。
  String get ngl => this == LocalModelBackend.cpu ? '0' : '99';

  /// LiteRT-LM 那条引擎用的后端名（`cpu` / `gpu`）。
  ///
  /// 两个引擎的后端**不是一回事**：llama.cpp 只有 CPU/Vulkan，LiteRT-LM 有
  /// CPU/GPU。所以这里是显式映射，不做隐式假设。
  String get liteRtName => switch (this) {
        LocalModelBackend.cpu => 'cpu',
        LocalModelBackend.vulkan => 'gpu',
      };
}

/// 一次测速结果（数值直接来自 llama-server 的 `timings`，不是我算的）。
class LocalBenchResult {
  const LocalBenchResult({
    required this.backend,
    required this.tokensPerSecond,
    required this.promptMs,
    required this.predictedTokens,
    this.promptPerSecond = 0,
    this.approx = false,
  });

  final LocalModelBackend backend;

  /// 生成速度（tok/s）——**这是判断"能不能用"的核心数字**。
  final double tokensPerSecond;

  /// 处理提示词耗时（≈首字延迟，毫秒）。
  final double promptMs;

  final int predictedTokens;
  final double promptPerSecond;

  /// 这个数字是不是**估的**。
  ///
  /// llama-server 自己报的 `timings` 有真实 token 计数（`approx=false`）；
  /// 而 LiteRT-LM 是进程内 API，只给回调、不给 token 计数，所以那边是按回调
  /// 次数估的（`approx=true`）。界面上必须区分，否则用户会拿一个估算值去和
  /// 精确值比。
  final bool approx;

  @override
  String toString() =>
      '${backend.label}: ${tokensPerSecond.toStringAsFixed(1)} tok/s'
      '（首字 ${promptMs.toStringAsFixed(0)}ms / $predictedTokens tokens'
      '${approx ? ' · 估' : ''}）';
}

/// 手机本地的大模型服务（llama.cpp 的 `llama-server`）。
///
/// ## 为什么长这样（和 `RotationProxy` 是同一套）
///
/// 我们**不自己实现转发**：`llama-server` 本身就提供 OpenAI 兼容的
/// `/v1/chat/completions` 与 `GET /health`。App 要做的只有四件事 ——
/// 挑端口、起进程、等它就绪、把 overlay 里某个 provider 指过去。
/// 这与 `rotation_proxy.dart` 的形状完全一致（那个是指向 `rotate-proxy.mjs`），
/// 所以照抄它，而不是新发明一套。
///
/// ## 三条纪律
///
/// 1. **起不来就返回 null**，绝不把 overlay 指向一个不存在的服务 ——
///    否则 DSH 每次请求都撞连接被拒，用户看到的是"对话突然坏了"。
/// 2. **可执行文件必须在 nativeLibraryDir**。Android 只允许从那里执行原生程序
///    （项目为 `libnode.so` 已经踩过这条：见 build.gradle.kts 的 useLegacyPackaging 注释）。
/// 3. **模型换了就重启**：同一个端口上不允许悄悄换成另一个模型 ——
///    用户看到的模型名与实际跑的不是一个，是最难查的那类 bug。
class LocalModelServer {
  LocalModelServer._();

  static final LocalModelServer instance = LocalModelServer._();

  /// overlay 里注册的 provider id（`local`）。
  static const String providerId = LocalModelSpec.providerId;

  /// 端口段起点（避开轮换代理的 39321 段）。
  static const int basePort = 39341;

  /// 可执行文件名（jniLibs 里必须叫 `lib*.so` 才会被打包）。
  static const String executableName = 'libllamaserver.so';

  Process? _proc;
  int? _port;
  LocalModelBackend? _backend;
  List<String>? _devices;

  /// 这次"设备列表"是不是**真跑过探测**得到的（即使结果是空）。
  ///
  /// 为什么要单独记：引擎目录还没就绪时探测会直接返回空，那种"空"不能当作
  /// "引擎没编 Vulkan"的证据 —— 否则界面会误报（真机 2026-10-08 就踩到）。
  bool _vkProbeRan = false;
  LocalModelSpec? _spec;
  String? _modelPath;
  int? _exitCode;

  /// 上一次启动失败 / 引擎非正常退出的原因（**人话**）。
  ///
  /// 为什么要有它（用户 2026-10-11 反馈「点选本地大模型目前显示本地服务没起来」）：
  /// 界面上原来只说「本地服务没起来（详见运行日志）」—— 用户只能看到"没起来"，
  /// 还得自己去翻运行日志。真正的原因（引擎文件缺失 / 模型文件缺失 / 引擎一启动就
  /// 退出及退出码 / 10 个端口都占着）这里都记着，界面直接显示出来。
  String? _lastError;

  /// 上一次失败的原因（null = 没失败过，或已成功启动）。见 [_lastError]。
  String? get lastError => _lastError;

  /// 上一次启动是不是「引擎自己很快就退出了」（区别于「端口没起来」）。
  /// 前者换端口没用，只会在日志里把同一个错误重放 10 遍。
  bool _exitedEarly = false;

  /// 带优化开关试过了吗（避免在同一端口上无限重试）。
  bool _tunedTried = false;

  /// 当前这次跑的是"带性能开关"还是"兼容参数"（给界面显示用）。
  bool _tunedActive = true;

  /// 服务在不在跑。
  ///
  /// ⚠️ **必须把 LiteRT-LM 那条路算进来**（真机 2026-10-09 发现）：LiteRT-LM 是
  /// **进程内**的（走原生通道，没有子进程），只看 `_proc` 会在它明明在跑时返回
  /// false —— 后果是服务区那颗状态点一直是灰的、"服务运行中"的说明不出现、
  /// 推理后端与上下文两颗按钮本该置灰却可以点。
  bool get running => _proc != null;

  int? get port => _port;

  /// 服务**实际在跑**的后端（没在跑就是 null）。
  ///
  /// 为什么必须暴露：模型页要如实显示"现在用的哪个后端 + 多大上下文" ——
  /// 崩过自动降级、或用户这次选的和跑的不一样时，只显示用户的选择就是在骗人。
  /// 上下文从 [spec] 上取（`spec.contextSize`）。
  LocalModelBackend? get backend => _backend;

  /// 当前规格；没在跑就是 null。overlay 生成**必须**用它，
  /// 不要自己拼一个 "localhost:某端口"。
  LocalModelSpec? get spec => _spec;

  String get executablePath => '$_nativeLibDir/$executableName';

  /// 每种引擎**真正需要**的那个 `.so`（判存在用）。
  ///
  /// ⚠️⚠️ **这个函数是 2026-10-12 加的，它修的是"本地大模型完全用不了"的根因。**
  ///
  /// 之前这里**没有**这个函数：`executablePath` 直接拼常量 `executableName`
  /// （= `libllamaserver.so`），而调用方拿它去 `existsSync()` 判断"引擎在不在"——
  /// **连 `litert-lm` 的模型也被拿去检查 llama.cpp 的 `.so`**。
  /// 而 llama.cpp 自 0.47 起就有意不随包 → 这个文件**永远不存在**
  /// → **每一个模型都在那行返回 null**，`litert-lm` 那条分支根本走不到。
  ///
  /// 用户 2026-10-12 的真机日志把这件事钉死了（00:04:55 起 7 次，一字不改）：
  /// ```
  /// 引擎不存在：…/lib/arm64/libllamaserver.so（模型要的是 litert-lm）
  /// ```
  /// 括号里那句「模型要的是 litert-lm」就是它自己打印的 —— **当场自证**：
  /// 拿 A 引擎的文件去判 B 引擎的模型。
  ///
  /// 返回 null = 这个引擎没有"独立的可执行文件"可判，交给原生侧自己报错。
  /// 只认 **MNN**（2026-11-03 用户口径：「调用本地大模型只认 mnn 引擎」）。
  ///
  /// 另外两个引擎的下线理由（都是实测跑不动，不是不想支持）：
  ///   * `llama.cpp` —— 骁龙 8 Elite / Armv9.2 上长请求必 SIGSEGV，且 0.47 起不随包；
  ///   * `litert-lm` —— 同样不在包里，界面上只会报"引擎不存在"。
  ///
  /// 返回 null = 「这版没有这个引擎」，UI 据此显示"缺引擎"。
  static String? engineLibName(String engine) => switch (engine) {
        'mnn' => 'libmnn_mini_server.so',
        _ => null,
      };

  /// 本版包里有没有这个引擎（判据与「本地大模型」页的 `_engineBundled` 同一套）。
  bool hasEngine(String engine) {
    final lib = engineLibName(engine);
    if (lib == null) return false;
    if (_nativeLibDir.isEmpty) return false;
    return File('$_nativeLibDir/$lib').existsSync();
  }

  String _nativeLibDir = '';
  static const String _logTag = '[dsh-localmodel]';

  /// 确保服务在跑（模型相同则复用；不同则重启）。
  ///
  /// 返回**它真正监听的端口**；null 表示起不来（或环境不满足），
  /// 调用方必须如实处理，不要写 overlay。
  Future<int?> ensureRunning({
    required DshRuntime runtime,
    required OnDeviceModel model,
    required String modelPath,
    // ⚠️ **默认 16384，不是 2048**。
    //
    // 2048 是个坑：DSH 每轮请求都要带上系统提示 + 技能清单 + 运行时上下文，
    // 实测光这些就 **约 7000 tokens** —— 于是每一句话都被引擎拒绝：
    //   `request (6959 tokens) exceeds the available context size (2048 tokens)`
    // 用户看到的是"本地模型每次都失败"。真机日志（2026-10-07）就是这么暴露的。
    // 16384 在这类机型上余量充足（实测 17 tok/s），页面里还可以再调。
    int contextSize = 16384,

    /// 默认 CPU —— 理由见 ondevice_models_page.dart 里那段注释（真机 GPU 段错误）。
    LocalModelBackend backend = LocalModelBackend.cpu,
  }) async {
    _nativeLibDir = runtime.nativeLibDir;
    // 引擎目录（重）就绪了 → 作废上一次的探测结果。
    // 首次打开页面时目录常常还没落盘，那时探到的"空"不可信（见 listDevices 注释）；
    // 这里一作废，下一次问"有没有 Vulkan"就会拿着**正确的目录**重探。
    _devices = null;
    _vkProbeRan = false;
    if (_nativeLibDir.isEmpty) {
      _lastError = '拿不到原生库目录（nativeLibDir 为空）—— 安装不完整，重装一次试试';
      debugPrint('$_logTag 拿不到 nativeLibDir，无法启动');
      return null;
    }
    _readyOnce = false;
    _contextNote = '';

    // ── 上下文：先按**模型文件物理能装的**收敛，后面所有分支都用这个数 ────────
    //
    // 真机 2026-10-09 抓到（诊断报告 16:32:35）：`Gemma3-1B-IT_..._ekv4096.litertlm`
    // 的 KV 只有 4096 格，而这里一律按用户档位（默认 16384）启动、overlay 也这么
    // 声明 → 两轮就把缓存吃到 3920/4096，第三轮报
    //   `Status Code: 9 · Prefill input length exceeds available state entries
    //    (remaining capacity: 176)`
    // 整轮失败。原因见 OnDeviceModel.kvTokens 的注释。
    //
    // ⚠️ 收敛后的数**必须一处改、处处用**：引擎的 `maxNumTokens` 与 overlay 的
    //    `contextWindow`（走 `_spec.contextSize`）**要一模一样** —— 两边不一致就会
    //    掉进它的镜像坑：overlay 写小了，DSH 把 maxTokens clamp 成 1 → 空回复。
    //    所以这里直接改 `contextSize` 本身，后面 litert-lm / llama.cpp 两条路自然一致。
    if (model.kvTokens > 0 && model.kvTokens < contextSize) {
      // ⚠️ 措辞不能写"已按它启动"：这一行在**引擎检查之前**，那时还没启动。
      //    真机日志里就出现过「已按它启动」和「引擎不存在」并排打印，
      //    看起来像"起来了又没起来"（用户 2026-10-12 的日志 0033/0034 行）。
      //    这里只陈述"收敛了上下文"，启动结果由后面如实说。
      _contextNote = tr(
          '这个模型文件只带 {0} 格缓存，上下文已收敛到 {0} 格（你设的是 {1}）—— '
          '它的上下文上限就是那么多，装不下更长的对话',
          <String>['${model.kvTokens}', '$contextSize']);
      DiagnosticsLog.add(_logTag, _contextNote);
    }
    contextSize = effectiveLocalContext(
      requested: contextSize,
      modelKvTokens: model.kvTokens,
    );

    // ── 崩溃记录（跨重启）─────────────────────────────────────────────
    final modelsDir = runtime.nodeHome.isEmpty
        ? '${runtime.filesDir}/models'
        : '${runtime.nodeHome}/models';
    _crashes ??= ModelCrashStore(dir: modelsDir);

    // ── 崩溃记忆：这个模型在这个后端崩过 → **自动换另一个后端** ──────────────
    //
    // 依据是真机日志（2026-10-07）：用户发第一句真话 → 12 秒后 code=-11
    // （段错误）→ 服务当场死掉，而 overlay 还指着它 → 之后每次都是
    // `Connection error`。用户不该自己当侦探去猜"是不是后端的问题"，
    // 所以这里自动降级 —— **优先保证能用，速度排第二**。
    var useBackend = backend;
    _downgradeNote = '';
    final crashCount = await _crashes!.countFor(model.id, backend.name);
    if (crashCount > 0) {
      useBackend = backend == LocalModelBackend.vulkan
          ? LocalModelBackend.cpu
          : LocalModelBackend.vulkan;
      _downgradeNote = tr('{0} 崩过 {1} 次，已自动改用 {2}（优先保证能用）',
          [backend.label, '$crashCount', useBackend.label]);
      DiagnosticsLog.add(_logTag,
          '崩溃记忆：${model.id} 在 ${backend.label} 上崩过 $crashCount 次 → 本次改用 ${useBackend.label}');
    }

    // 已就绪且模型/后端都没变：直接复用（不要每次对话都重启，加载一次要几十秒）。
    if (_proc != null && _port != null && _spec != null) {
      if (_modelPath == modelPath && _backend == useBackend) return _port;
      debugPrint('$_logTag 模型或后端变了（${_spec!.modelId} / $_backend → '
          '${model.id} / $useBackend），重启本地服务');
      await stop();
    }

    // ── 引擎文件检查：**必须按模型自己的引擎去查** ─────────────────────────
    //
    // ⚠️⚠️ **这一行曾经是"本地大模型完全用不了"的真正根因**（2026-10-12 修）。
    //    以前写的是 `File(executablePath).existsSync()`，而 `executablePath`
    //    永远是 `libllamaserver.so` —— **不看引擎**。llama.cpp 自 0.47 起不随包，
    //    于是这个判断对**任何**模型都是 false，连 `.litertlm` 也在这一行被挡掉，
    //    下面那条 litert-lm 分支**永远走不到**。真机日志（00:04:55 起 7 次）：
    //      `引擎不存在：…/libllamaserver.so（模型要的是 litert-lm）`
    //    —— 括号里那句就是它自己打印的，等于当场自证"拿 A 的文件判 B 的模型"。
    //
    //    现在的口径：**先看这个模型要的是哪个引擎、包里有没有那个引擎**。
    final engineLib = engineLibName(model.engine);
    if (engineLib == null) {
      _lastError = '这个模型要的是 ${model.engine} 引擎，而本版包里没有它 —— 手机版跑不了它。'
          '请改用 Gemma 4 这类 .litertlm 模型（「本地大模型」页可下载），'
          '这个模型可以在同一页删掉。';
      debugPrint('$_logTag 引擎不认识：${model.engine}（模型 ${model.id}）');
      DiagnosticsLog.add(_logTag, '引擎不认识：${model.engine}（模型 ${model.id}）');
      return null;
    }
    final exe = File('$_nativeLibDir/$engineLib');
    if (!exe.existsSync()) {
      // 两种完全不同的原因，说错一句用户就会白忙（2026-10-11 的教训：那时候
      // 提示他"重装一次"，而重装一百次也没用）：
      //   · litert-lm 的 .so 不在 → 真的是安装不完整；
      //   · llama.cpp 的 .so 不在 → 这个引擎**故意下线了**，重装也不会有。
      _lastError = model.engine == 'litert-lm'
          ? '引擎文件不在：${exe.path}（App 安装不完整，重装一次）'
          : '这个模型要的是 ${model.engine} 引擎，而它从 0.47 起就不随包了'
              '（在骁龙 8 Elite 这类机型上处理长请求必然崩溃）—— 手机版跑不了它。'
              '请改用 Gemma 4 这类 .litertlm 模型（「本地大模型」页可下载），'
              '这个旧模型可以在同一页删掉。';
      debugPrint('$_logTag 引擎不存在：${exe.path}（模型要的是 ${model.engine}）');
      DiagnosticsLog.add(_logTag, '引擎不存在：${exe.path}（模型要的是 ${model.engine}）');
      return null;
    }
    if (!File(modelPath).existsSync()) {
      _lastError = '模型文件不在：$modelPath（可能被清理工具删了，重新下载这个模型）';
      debugPrint('$_logTag 模型文件不存在：$modelPath');
      DiagnosticsLog.add(_logTag, '模型文件不存在：$modelPath');
      return null;
    }

    // ── litert-lm 那一类模型（Gemma 4 的 `.litertlm`）─────────────────────
    //
    // 它**没有像 llama-server 那样的独立进程**：官方 AAR 给的是进程内 API
    // （Engine / Conversation），所以 Kotlin 侧（`LiteRtLmBridge.kt`）自己起了一个
    // 极小的本机 HTTP 服务，把它包成 OpenAI 兼容接口。
    //
    // 这里只要"通过原生通道让它启动、拿到端口"，**下面那整套（overlay 注册 /
    // 模型选择器 / 会话指纹 / 用量统计）一行都不用改** —— 对 DSH 来说它就是
    // 一台"跑在 127.0.0.1:某端口"的本机服务。
    // 只认 MNN（2026-11-03）。以前这里分两条路（litert-lm 进程内 / llama 子进程），
    // 现在收成一条：**能起的只有 MNN**。清单里若混着别的引擎，当场拒绝并说明，
    // 而不是让它去起一个注定失败的进程。
    if (model.engine != 'mnn') {
      _lastError = tr('这版只支持 MNN 引擎（这个模型要的是 {0}）—— '
          '回「本地大模型」页换一个带 MNN 标记的模型', [model.engine]);
      debugPrint('$_logTag 拒绝非 MNN 引擎：${model.engine}');
      DiagnosticsLog.add(_logTag, '拒绝非 MNN 引擎：${model.engine}');
      return null;
    }

    // Gemma 家族的模型**自带模板太严**（只认"首条 system + 之后严格交替"），
    // 而 DSH 每轮会把多条 system 段各自 push 成一条 system 消息 → 真机上发什么都
    // 400（`Conversation roles must alternate ...`）。这里给它换兼容模板。
    // 根因与实测矩阵见 `loose_chat_templates.dart` 的文件头（不是猜的，是复现出来的）。
    final chatTemplate = needsLooseChatTemplate(
      family: model.family,
      fileName: model.fileName,
    )
        ? kLooseGemmaTemplate
        : null;
    if (chatTemplate != null) {
      DiagnosticsLog.add(_logTag, '使用 Gemma 兼容对话模板（该模型自带模板与多条 system 不兼容）');
    }

    // 先带性能开关试；起不来就退回兼容参数（见下面的注释）。
    var tuned = true;
    _tunedTried = false;

    for (var p = basePort; p < basePort + 10; p++) {
      final ok = await _start(
        runtime: runtime,
        exePath: exe.path,
        modelPath: modelPath,
        port: p,
        contextSize: contextSize,
        backend: useBackend,
        tuned: tuned,
        chatTemplate: chatTemplate,
        modelId: model.id,
      );
      if (!ok) {
        // **带优化开关起不来**（个别机型/驱动不支持 flash-attn / KV 量化）→ 退回兼容参数再试一次。
        // 这一步很重要：追性能绝不能把"本来能跑"变成"跑不起来"。
        if (tuned && _exitedEarly && !_tunedTried) {
          debugPrint('$_logTag 带性能开关启动失败，退回兼容参数重试');
          DiagnosticsLog.add(_logTag, '带性能开关启动失败，改用兼容参数重试');
          _tunedTried = true;
          tuned = false;
          final ok2 = await _start(
            runtime: runtime,
            exePath: exe.path,
            modelPath: modelPath,
            port: p,
            contextSize: contextSize,
            backend: useBackend,
            tuned: false,
            chatTemplate: chatTemplate,
            modelId: model.id,
          );
          if (!ok2) {
            if (_exitedEarly) {
              DiagnosticsLog.add(_logTag, '兼容参数也起不来，停止重试端口');
              return null;
            }
            continue;
          }
        } else if (_exitedEarly) {
          debugPrint('$_logTag 引擎自身启动失败，停止换端口重试');
          DiagnosticsLog.add(_logTag, '引擎自身启动失败，已停止重试端口');
          return null;
        } else {
          continue;
        }
      }
      _tunedActive = tuned;
      _port = p;
      _modelPath = modelPath;
      _backend = useBackend;
      // 启动自检：用**真机上失败的那个形状**（两条 system）问一句。
      // 理由很直接 —— 上一版就是"启动成功、一发消息就 400"，**启动成功不等于能用**。
      // **所有模型都做**（不只换了模板的）：Gemma 4 这类我们没下药的模型，
      // 一旦模板也不兼容，界面上那行红字就是唯一的线索。
      // 代价只是一次 1 token 的推理（模型已加载好，约一两秒）。
      final check = await _selfCheck(p);
      DiagnosticsLog.add(
        _logTag,
        check
            ? '启动自检通过（两条 system 的形状可正常请求）'
                '${chatTemplate != null ? ' · 已用 Gemma 兼容对话模板' : ''}'
            : '⚠️ 启动自检未通过：这个模型的模板可能与 DSH 不兼容（发消息会 400）。'
                '请把运行日志发回',
      );
      _spec = LocalModelSpec(
        port: p,
        modelId: model.id,
        displayName: model.name,
        contextSize: contextSize,
        // 能力位跟着清单走：只有多模态模型才给「本地对话」里的拍照/选图入口。
        vision: model.kind == 'vision',
      );
      _lastError = null; // 起来了就把上次的失败原因清掉
      debugPrint('$_logTag 本地模型服务已就绪：127.0.0.1:$p（${model.id}）');
      DiagnosticsLog.add(_logTag, '已就绪 127.0.0.1:$p ← ${model.fileName}');
      return p;
    }
    _lastError = '起了 10 个端口都没成功（多半是引擎一启动就退出，详见运行日志）';
    debugPrint('$_logTag $basePort 起 10 个端口都没起来');
    return null;
  }

  Future<bool> _start({
    required DshRuntime runtime,
    required String exePath,
    required String modelPath,
    required int port,
    required int contextSize,
    required LocalModelBackend backend,

    /// 是否带上性能优化开关（flash-attn / KV 量化 / 前缀复用）。
    /// 起不来时会自动退回不带这些开关再试一次 —— 见 [ensureRunning]。
    bool tuned = true,

    /// 覆盖对话模板（传模板**源码**）。null = 用模型自带的模板。
    /// 只有 Gemma 家族会传 —— 它自带模板太严，见 `loose_chat_templates.dart`。
    String? chatTemplate,


    /// 模型 id —— MNN 那条把它当作对外报的模型名。
    required String modelId,
  }) async {
    final threads = Platform.numberOfProcessors.clamp(2, 6);
    // ── MNN 的命令行（2026-11-03 起这是唯一一条路）─────────────────────────
    //
    //   mnn_mini_server <config.json> [port] [model-id]
    //
    // config.json 在**模型主文件所在的目录**：主文件是 llm.mnn.weight，
    // llm_config.json / tokenizer.txt / llm.mnn 都是同目录的伴生文件，
    // 引擎按 config 里的相对路径自己找。
    //
    // 不传 -ngl/-c/-t 那些 llama 参数 —— MNN 不认（会被当多余参数忽略，
    // 但日志里会多一行噪音，且让人误以为在调 llama）。
    final dir = File(modelPath).parent.path;
    final args = <String>[
      '$dir/llm_config.json',
      '$port',
      modelId,
    ];
    _exitCode = null;
    // ⚠️ proc 必须声明在 try 之外：等就绪失败时要拿它来 kill。
    Process? proc;
    try {
      proc = await Process.start(
        exePath,
        args,
        environment: <String, String>{
          // 7 个依赖 .so 都在 nativeLibraryDir，必须显式指路（与 libnode.so 同理）。
          'LD_LIBRARY_PATH': runtime.nativeLibDir,
        },
      );
      final started = proc;
      _proc = started;
      // 日志逐行进诊断日志（出问题时用户能一键导出，而不是抓瞎）。
      started.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => DiagnosticsLog.add(_logTag, line));
      started.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => DiagnosticsLog.add(_logTag, 'ERR $line'));
      unawaited(started.exitCode.then((code) {
        _exitCode = code;
        _onProcessExit(code);
      }));
    } catch (e) {
      debugPrint('$_logTag 启动失败（端口 $port）：$e');
      DiagnosticsLog.add(_logTag, '启动失败（端口 $port）：$e');
      _proc = null;
      return false;
    }

    final ready = await _waitReady(port);
    if (!ready) {
      // 进程已经退出 = 引擎自身的问题（模型/参数/上下文），不是端口问题。
      _exitedEarly = _exitCode != null;
      await _kill(proc);
      _proc = null;
      return false;
    }
    _exitedEarly = false;
    _readyOnce = true; // 就绪过 —— 之后的退出才算「崩溃」
    return true;
  }

  /// 进程退出（无论是被我们 kill 还是自己崩了）。
  ///
  /// ⚠️ 这里**必须清空 spec**：否则 UI 会显示"运行中"，而 overlay 还指着
  /// 一个已经死掉的端口 —— 用户看到的是"选了 local 模型但一发消息就报错"。
  void _onProcessExit(int code) {
    final spec = _spec;
    final backend = _backend;
    if (code != 0) {
      final reason = exitCodeReason(code);
      _lastError = '引擎进程退出了（code=$code：$reason）';
      debugPrint('$_logTag 进程退出，code=$code（$reason）');
      DiagnosticsLog.add(_logTag, '引擎退出：$reason');
      // ⚠️ 只在「曾经就绪过」之后才记崩溃：启动阶段的失败有另一套回退
      // （见 ensureRunning 的 tuned → 兼容参数），把它也算崩溃会导致无谓降级。
      final store = _crashes;
      if (_readyOnce && spec != null && backend != null && store != null) {
        unawaited(store.record(spec.modelId, backend.name, code));
        DiagnosticsLog.add(_logTag,
            '已记下这次崩溃（${spec.modelId} / ${backend.label}）—— 下次启动会自动换另一个后端');
      }
    }
    _proc = null;
    _port = null;
    _spec = null;
    _modelPath = null;
  }

  /// 轮询 `GET /health` 直到就绪。
  ///
  /// 为什么用 /health 而不是"端口能连上就行"：llama-server 在**加载模型期间**
  /// 就已经监听端口了，这时发推理请求会失败。就绪判定必须是它的健康检查。
  Future<bool> _waitReady(int port,
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      while (DateTime.now().isBefore(deadline)) {
        if (_exitCode != null) {
          debugPrint('$_logTag 等就绪期间进程已退出（code=$_exitCode）');
          return false;
        }
        try {
          final req = await client
              .getUrl(Uri.parse('http://127.0.0.1:$port/health'))
              .timeout(const Duration(seconds: 3));
          final res = await req.close().timeout(const Duration(seconds: 3));
          final body = await res.transform(utf8.decoder).join();
          if (res.statusCode == 200 && body.contains('ok')) return true;
        } catch (_) {
          // 还没起来：正常，继续等。
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      debugPrint('$_logTag 等就绪超时（${timeout.inSeconds}s）');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 启动自检：用**真机上失败的那个形状**问一句，验证这次真的能跑。
  ///
  /// 形状是 `[system, system, user]` —— 不是随手编的：本机用**同一个模型文件 +
  /// 同版本引擎**实测过，官方 Gemma 模板在这个形状上必然 400
  /// （`Conversation roles must alternate ...`），换兼容模板后 200。
  /// 所以这一问能如实回答"用户接下来发消息会不会立刻失败"。
  ///
  /// ⚠️ 自检失败**不会**阻止服务启动（服务本身是好的）—— 只如实记进运行日志，
  /// 并在界面上给一行红字。绝不假装通过。
  Future<bool> _selfCheck(int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .postUrl(Uri.parse('http://127.0.0.1:$port/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(<String, dynamic>{
        'messages': <Map<String, String>>[
          <String, String>{'role': 'system', 'content': '你是助手。'},
          <String, String>{'role': 'system', 'content': '当前环境：Android。'},
          <String, String>{'role': 'user', 'content': 'hi'},
        ],
        'max_tokens': 1,
        'temperature': 0,
      })));
      final res = await req.close().timeout(const Duration(minutes: 2));
      final body = await res.transform(utf8.decoder).join();
      _lastSelfCheckOk = res.statusCode == 200;
      if (_lastSelfCheckOk != true) {
        debugPrint('$_logTag 自检未通过：HTTP ${res.statusCode} '
            '${body.length > 300 ? body.substring(0, 300) : body}');
      }
      return _lastSelfCheckOk ?? false;
    } catch (e) {
      _lastSelfCheckOk = false;
      debugPrint('$_logTag 自检出错：$e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 引擎支持哪些后端（跑一次 `--list-devices` 读回来的，**不是猜的**）。
  ///
  /// 为什么值得多起一次进程：界面上"Vulkan 可选"必须是真的可选 ——
  /// 否则用户切过去、发现速度没变（其实还是 CPU 在跑）却不知道为什么。
  ///
  /// ⚠️ **时序坑（真机 2026-10-08）**：页面刚打开时引擎目录可能还没就绪
  /// （`_nativeLibDir` 为空 / 引擎进程还没落盘），这时的空结果**不算数、也不缓存**。
  /// 否则界面会断言"这版引擎没编 Vulkan"，而用户测一次速度再刷新就正常了 ——
  /// 那个"刷新一下就活了"的怪现象就是这里来的。
  /// [force] 给右上角刷新用：无视缓存重跑一次探测。
  Future<List<String>> listDevices({bool force = false}) async {
    if (!force && _devices != null) return _devices!;
    _vkProbeRan = false;
    if (_nativeLibDir.isEmpty) return const <String>[];
    // ⚠️ `--list-devices` 是 **llama.cpp 引擎自己的参数**。本版包里没有它
    //    （0.47 起下线）→ 以前每次刷新都会去起一个必然失败的进程（catch 吞掉）。
    //    现在直接短路：没有 llama.cpp 就**不探测**，并如实记下"结论可信"
    //    （= 本版确实没有 Vulkan 这个概念，不是"还没探测"）。
    if (!File(executablePath).existsSync()) {
      _devices = const <String>[];
      _vkProbeRan = true;
      return const <String>[];
    }
    try {
      final r = await Process.run(executablePath, <String>['--list-devices'],
          environment: <String, String>{'LD_LIBRARY_PATH': _nativeLibDir});
      final out = '${r.stdout}\n${r.stderr}';
      final devices = out
          .split('\n')
          .where((l) => l.contains('Vulkan') || l.contains('CPU'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList(growable: false);
      _devices = devices;
      // 真跑过探测了 —— 哪怕结果为空，这也是**可信的**"没有 Vulkan"。
      _vkProbeRan = true;
      debugPrint('$_logTag 设备列表：$devices');
      return devices;
    } catch (e) {
      debugPrint('$_logTag 读设备列表失败：$e');
      return const <String>[];
    }
  }

  /// 引擎里有没有 Vulkan 后端 —— 同时告诉调用方**这个结论可不可信**。
  ///
  /// `known=false` 表示还没成功探测过（引擎目录未就绪 / 探测进程起不来）。
  /// 界面这时不该断言"引擎没编 Vulkan"，而该提示"先启动一次再刷新"。
  Future<({bool has, bool known})> vulkanStatus({bool force = false}) async {
    final devs = await listDevices(force: force);
    return (
      has: devs.any((d) => d.toLowerCase().contains('vulkan')),
      known: _vkProbeRan,
    );
  }

  /// 跑一次真实推理并回报速度（数字取自 llama-server 的 `timings` 字段）。
  ///
  /// 为什么用"/v1/chat/completions + 小 max_tokens"而不是自己的计时器：
  /// 我们要的是**模型的生成速度**，不是网络往返 —— 服务端自己的 timings 才是准的。
  Future<LocalBenchResult?> measure({int maxTokens = 48}) async {
    final port = _port;
    final backend = _backend;
    if (port == null || backend == null) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .postUrl(Uri.parse('http://127.0.0.1:$port/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      final body =
          jsonEncode(benchRequestBody(_spec?.modelId ?? 'local', maxTokens));
      req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(minutes: 3));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        debugPrint(
            '$_logTag 测速失败：HTTP ${res.statusCode} ${text.substring(0, text.length.clamp(0, 200))}');
        return null;
      }
      final json = jsonDecode(text);
      final t = (json is Map ? json['timings'] : null) as Map?;
      if (t == null) return null;
      double d(Object? v) => (v as num?)?.toDouble() ?? 0;
      final r = LocalBenchResult(
        backend: backend,
        tokensPerSecond: d(t['predicted_per_second']),
        promptMs: d(t['prompt_ms']),
        predictedTokens: (t['predicted_n'] as num?)?.toInt() ?? 0,
        promptPerSecond: d(t['prompt_per_second']),
        // litert-lm 那条桥会带 `approx: true`（它只能按回调次数估）；
        // llama-server 不带这个字段 → 精确值。
        approx: t['approx'] == true,
      );
      debugPrint('$_logTag 测速结果：$r');
      DiagnosticsLog.add(_logTag, '测速 $r');
      return r;
    } catch (e) {
      debugPrint('$_logTag 测速异常：$e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 停掉服务（用户关掉、或换模型）。
  /// litert-lm 服务的默认起点端口（与 llama.cpp 那条路错开，便于日志辨认）。
  static const int _liteRtLmBasePort = 39541;

  /// 崩溃记录（跨重启）：崩溃发生在「用户发第一条真话」时，那时用户已经离开设置页，
  /// 不落盘的话 App 一重启就忘了，下次还会用同一个后端再崩一遍。
  ModelCrashStore? _crashes;

  /// 本次启动是否**已经就绪过**。用来区分「启动阶段失败」（有另一套回退）与
  /// 「运行中崩溃」（要记进崩溃记录并降级），否则会无谓降级。
  bool _readyOnce = false;

  /// 本次是否因为「上次崩过」而换了后端（界面用一句话说明）。
  String _downgradeNote = '';

  /// 界面用：本次启动的后端降级说明（空 = 没降级）。
  String get downgradeNote => _downgradeNote;

  /// 本次是否因为「模型文件自带的缓存比用户设的小」而收敛了上下文（空 = 没收敛）。
  String _contextNote = '';

  /// 界面用：本次启动的**上下文收敛**说明（空 = 用户设多少就是多少）。
  ///
  /// 为什么要让用户看见：他设了 16384，实际只有 4096 —— 不说明白就是界面在骗人，
  /// 而且对话一到上限就失败，他也不知道该怪谁。
  String get contextNote => _contextNote;

  /// 上次启动自检的结果（null = 没做过 —— 只有换了对话模板的模型才做）。
  bool? _lastSelfCheckOk;

  /// 界面用：false 表示"这个模型的模板可能和 DSH 不兼容"。
  bool? get lastSelfCheckOk => _lastSelfCheckOk;

  /// 当前这个"本机服务"是不是 litert-lm 那条路（停止时要用不同的方式收摊）。
  bool _liteRtLmActive = false;

  /// litert-lm 的会话缓存统计（复用次数 / 重建次数 / 最近重建原因）。
  ///
  /// 为什么放在 App 侧缓存：**对话是 DSH 直连那个本机端口的，App 不参与**，
  /// 所以只有"下次刷新页面时主动去问原生层一次"才知道复用了多少。缓存在这里，
  /// 界面 build 时同步读，不产生 I/O。
  Map<String, dynamic> _liteRtStats = const <String, dynamic>{};

  Map<String, dynamic> get liteRtStats => _liteRtStats;

  bool get isLiteRtLm => _liteRtLmActive;

  /// 主动去原生层拉一次会话缓存统计（启动 / 测速 / 页面刷新时调用）。
  Future<void> refreshLiteRtStats() async {
    if (!_liteRtLmActive) {
      _liteRtStats = const <String, dynamic>{};
      return;
    }
    try {
      final s = await DshHost.channel.invokeMethod<String>('litertlmStats');
      final decoded = s == null ? null : jsonDecode(s);
      _liteRtStats = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } catch (e) {
      debugPrint('$_logTag 读 litert-lm 统计失败：$e');
    }
  }

  /// litert-lm：通过原生通道（`dsh/native`）在 App 进程内起服务。
  Future<int?> _ensureLiteRtLm({
    required OnDeviceModel model,
    required String modelPath,
    required int contextSize,
    required LocalModelBackend backend,
    required int requestedPort,
  }) async {
    try {
      final p = await DshHost.channel
          .invokeMethod<int>('litertlmStart', <String, dynamic>{
        'modelPath': modelPath,
        'port': requestedPort,
        // LiteRT-LM 的后端名与 llama.cpp 不同：这里说 gpu / cpu。
        'backend': backend.liteRtName,
        'maxNumTokens': contextSize,
        'maxOutputTokens': 2048,
        'temperature': 0.8,
      });
      if (p == null || p <= 0) {
        // ⚠️ 这里必须记原因（2026-10-11 用户问「本地大模型启动的问题修复了没有」时查出来的
        //    真缺口）：litert-lm 这条路**原来一处都没写 `_lastError`** —— 于是
        //    Gemma 4 这类 `.litertlm` 模型起不来时，界面只能显示那句
        //    「本地服务没起来（详见运行日志）」，正是用户报的原话。
        //    llama.cpp 那条路早就写了原因，这条漏了。
        _lastError = litertStartReason(noPort: true);
        DiagnosticsLog.add(_logTag, 'litert-lm 启动失败：原生层没返回端口');
        return null;
      }
      _port = p;
      _modelPath = modelPath;
      _backend = backend;
      _liteRtLmActive = true;
      _spec = LocalModelSpec(
        port: p,
        modelId: model.id,
        displayName: model.name,
        contextSize: contextSize,
        // 能力位跟着清单走：只有多模态模型才给「本地对话」里的拍照/选图入口。
        vision: model.kind == 'vision',
      );
      debugPrint('$_logTag litert-lm 已就绪：127.0.0.1:$p（${model.id}）');
      DiagnosticsLog.add(_logTag, 'litert-lm 已就绪：127.0.0.1:$p（${model.id}）');
      _lastError = null; // 起来了就把上次的失败原因清掉（与 llama.cpp 那条路一致）
      return p;
    } on PlatformException catch (e) {
      final msg = e.message ?? e.code;
      // ── GPU 起不来 → **自动用 CPU 再试一次** ──────────────────────────────
      //
      // 依据是真机日志（2026-10-07）：加载模型 200ms 后就抛
      // `LiteRtLmJniException` —— 这么早失败说明是**后端初始化**阶段（最可能是
      // GPU delegate 的库在本机没有），而不是模型文件的问题。
      // 用户不该自己当侦探去猜"是不是要换 CPU"，而且 **CPU 能跑 > 完全不能用**。
      if (backend != LocalModelBackend.cpu) {
        DiagnosticsLog.add(
            _logTag, 'litert-lm 在 ${backend.label} 上起不来（$msg）→ 自动改用 CPU 重试');
        final retried = await _ensureLiteRtLm(
          model: model,
          modelPath: modelPath,
          contextSize: contextSize,
          backend: LocalModelBackend.cpu,
          requestedPort: requestedPort,
        );
        if (retried != null) {
          // 界面上也要说清"你要的 GPU 没能用上，现在跑的是 CPU"。
          _downgradeNote = tr('{0} 起不来，已自动改用 {1}（优先保证能用）',
              [backend.label, LocalModelBackend.cpu.label]);
        } else {
          // 两种后端都不行 —— 把 GPU 那次的原始原因也带上（CPU 那次的原因已在 _lastError 里）。
          _lastError = litertStartReason(
            nativeMessage: msg,
            backendLabel: backend.label,
            cpuReason: _lastError,
          );
        }
        return retried;
      }
      // CPU 也起不来 → 如实上报（这条错误会一路显示到界面上）。
      _lastError = litertStartReason(nativeMessage: msg);
      DiagnosticsLog.add(_logTag, 'litert-lm 启动失败：$msg');
      debugPrint('$_logTag litert-lm 启动失败：$msg');
      return null;
    } catch (e) {
      _lastError = litertStartReason(nativeMessage: '$e');
      DiagnosticsLog.add(_logTag, 'litert-lm 启动异常：$e');
      return null;
    }
  }

  /// litert-lm 启动失败时**给用户看的那句话**（纯函数 —— 所以能被测试钉住）。
  ///
  /// ## 为什么单独抽出来（2026-10-11）
  ///
  /// 用户报「点选本地大模型目前显示本地服务没起来」。查下来发现：llama.cpp 那条路
  /// 每一处失败都写了 `_lastError`（引擎文件不在 / 模型文件不在 / 端口都试过了 / 进程退出），
  /// 而 **litert-lm 这条路一处都没写** —— Gemma 4 这类 `.litertlm` 模型起不来时，
  /// `lastError` 是 null，界面只能显示那句没信息量的兜底文案。
  ///
  /// 抽成纯函数是为了**用测试钉住"每种失败都必须给出一句人话"**：
  /// 这个 bug 的形态是"少写一行赋值"，编译期、运行期都不报错，
  /// 只有用户在手机上看到那句废话时才会暴露。
  @visibleForTesting
  static String litertStartReason({
    String? nativeMessage,
    String? backendLabel,
    String? cpuReason,
    bool noPort = false,
  }) {
    if (noPort) {
      return 'litert-lm 引擎没起来（原生层没返回端口）—— '
          '多半是这个模型与这台手机不兼容，或可用内存不够；详见运行日志';
    }
    final msg = (nativeMessage ?? '').trim();
    if (msg.isEmpty) return 'litert-lm 启动失败（原生层没给原因，详见运行日志）';
    final cpu = (cpuReason ?? '').trim();
    if (cpu.isEmpty) return 'litert-lm 启动失败：$msg';
    final who = (backendLabel ?? '').trim();
    return who.isEmpty
        ? 'litert-lm 起不来（$msg）；改用 CPU 也一样（$cpu）'
        : 'litert-lm 起不来：$who 上报「$msg」，改用 CPU 也一样（$cpu）';
  }

  Future<void> stop() async {
    // litert-lm 因为是**进程内**的，停止要走原生通道（关引擎、释放内存）。
    _lastSelfCheckOk = null;
    if (_liteRtLmActive) {
      _liteRtLmActive = false;
      _liteRtStats = const <String, dynamic>{};
      _port = null;
      _spec = null;
      _modelPath = null;
      _backend = null;
      try {
        await DshHost.channel.invokeMethod<bool>('litertlmStop');
        debugPrint('$_logTag litert-lm 服务已停止');
        DiagnosticsLog.add(_logTag, 'litert-lm 服务已停止');
      } catch (e) {
        DiagnosticsLog.add(_logTag, 'litert-lm 停止时出错：$e');
      }
      return;
    }
    final proc = _proc;
    _proc = null;
    _port = null;
    _spec = null;
    _modelPath = null;
    _backend = null;
    if (proc == null) return;
    await _kill(proc);
    debugPrint('$_logTag 本地模型服务已停止');
  }

  Future<void> _kill(Process proc) async {
    try {
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  /// 测速请求体（抽成纯函数是为了**可测**）。
  ///
  /// 两个字段都有理由，别删：
  ///   * `stream: false` —— litert-lm 那条桥默认走 SSE，而测速解析的是普通 JSON，
  ///     不写这一行，Gemma 4 的【测速】**永远失败**（这是修掉的一个既有 bug）。
  ///   * `stateless: true` —— 测速不许动主会话缓存：桥会为它另开一个临时会话。
  ///     否则点一次【测速】就把正在进行的对话缓存冲掉，下一句又整段重算 ——
  ///     那等于"测速让你变慢"。
  @visibleForTesting
  static Map<String, dynamic> benchRequestBody(String modelId, int maxTokens) =>
      <String, dynamic>{
        'model': modelId,
        'stream': false,
        'stateless': true,
        'messages': <Map<String, String>>[
          <String, String>{
            'role': 'user',
            'content': '用一句话解释什么是黑洞，尽量简短。',
          },
        ],
        'max_tokens': maxTokens,
        'temperature': 0,
      };

  /// 给 UI 用的一句话状态。
  String statusText() {
    final s = _spec;
    if (s == null) return tr('未运行');
    final b = _backend?.label ?? '';
    final tail = _liteRtLmActive
        // litert-lm 那条路没有 flash-attn / KV 量化那些开关，别硬套"已开性能加速"。
        ? tr('（LiteRT-LM 引擎）')
        : (_tunedActive ? tr('（已开性能加速）') : tr('（兼容参数）'));
    return tr('运行中 · 端口 {0} · {1}', [
          '${s.port}',
          '$b ${s.displayName}'.trim(),
        ]) +
        tail;
  }

  /// 会话缓存统计的一句话（没有数据时返回空串）。
  ///
  /// 这是"到底快在哪"的**凭据**：复用 N 次 = 有 N 句省掉了重算整段历史。
  String liteRtCacheText() {
    if (!_liteRtLmActive || _liteRtStats.isEmpty) return '';
    return liteRtCacheLine(
      reuseCount: (_liteRtStats['reuseCount'] as num?)?.toInt() ?? 0,
      rebuildCount: (_liteRtStats['rebuildCount'] as num?)?.toInt() ?? 0,
      reason: (_liteRtStats['reason'] as String?) ?? '',
    );
  }

  /// 会话缓存那一行的文案（纯函数，便于测试断言"有据可查"这句话真的会出现）。
  @visibleForTesting
  static String liteRtCacheLine({
    required int reuseCount,
    required int rebuildCount,
    required String reason,
  }) {
    if (reuseCount + rebuildCount == 0) return tr('对话缓存：还没开始对话');
    final base = tr('对话缓存：省掉重算 {0} 次 · 整段重建 {1} 次', [
      '$reuseCount',
      '$rebuildCount',
    ]);
    final detail = rebuildReasonText(reason);
    return detail.isEmpty ? base : '$base（$detail）';
  }

  /// 重建原因（原生层给的是稳定代码，这里翻成人话）。
  ///
  /// 为什么要有这一行：如果"系统提示变了"一直出现，说明优化根本没生效 ——
  /// 用户看到这个才知道该把日志发给我，而不是继续觉得"还是慢"。
  @visibleForTesting
  static String rebuildReasonText(String code) => switch (code) {
        'first' => '',
        'system' => tr('因为系统提示变了'),
        'params' => tr('因为换了模型或参数'),
        'history' => tr('因为对话历史对不上'),
        'partial' => tr('因为上一轮没回完'),
        _ => '',
      };
}
