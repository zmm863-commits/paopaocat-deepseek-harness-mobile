import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../i18n/dsh_i18n.dart';
import '../../state/app_settings.dart';
import '../../local/dsh_runtime.dart';
import '../../local/model_downloader.dart';
import '../../local/model_importer.dart';
import '../../local/local_model_server.dart';
import '../../local/model_fit.dart';
import '../../local/model_manifest.dart';
import '../../local/serial_gate.dart';
import '../../local/model_store.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';
import '../widgets/dsh_panel.dart';
import '../../local/kb_store.dart';
import 'kb_page.dart';
import 'local_chat_page.dart';

/// 「本地大模型」页（B 路线：引擎内置、模型按需下载 / 本地导入）。
///
/// ## 这一页要如实回答的三个问题
///
/// 1. **这台机器能跑哪个** —— 清单按「内存 + 芯片」挑文件，芯片命中就拿 NPU 专属版
///    （Gemma 4 有 `sm8750` / `Google Tensor G6` 的预编译版），否则退回通用版。
/// 2. **装没装** —— 读的是磁盘上的登记表，并且**核对文件是否真的在、大小是否一致**；
///    文件被删了就不显示"已安装"（登记表不是真相，磁盘才是）。
/// 3. **校验到什么程度** —— sha256 有没有比对过要**直说**：清单还没回填哈希时，
///    只能做体积校验，界面就写"仅体积校验"，不能含混地打个"已校验"。
///
/// 下载与导入最终走**同一条**落盘纪律：`.part` → 校验 → 原子改名 → 登记。
class OnDeviceModelsPage extends StatefulWidget {
  const OnDeviceModelsPage({
    super.key,
    required this.runtime,
    required this.onModelChanged,
    required this.settings,
  });

  /// 「推理后端 / 上下文长度」这两项偏好落在这儿（真机反馈：转页面就重置）。
  final AppSettings settings;

  /// 拿 `nativeLibDir`（引擎 `.so` 与可执行文件都在那儿）等运行时路径。
  final DshRuntime runtime;

  /// 本地服务起/停之后必须重写 overlay —— 由 AppShell 提供
  /// （不重写的话 DSH 根本不知道有 `local` 这个厂家）。
  final Future<void> Function() onModelChanged;

  @override
  State<OnDeviceModelsPage> createState() => _OnDeviceModelsPageState();
}

class _OnDeviceModelsPageState extends State<OnDeviceModelsPage> {
  OnDeviceManifest _manifest = OnDeviceManifest.empty;
  DeviceProfile _profile = const DeviceProfile(ramGb: 0);

  /// 已装知识库（只用于「知识库」栏目那一行现状：几个、共多大）。
  List<KbInstalled> _kbInstalled = const <KbInstalled>[];

  Map<String, InstalledModel> _installed = const <String, InstalledModel>{};  LocalModelStore? _store;

  bool _loading = true;
  String? _loadError;

  /// 用户手动指定的内存档（宿主读不到总量时才需要）。
  int _manualRamGb = 0;

  /// 正在下载的模型 id（同一时间只允许一个，避免抢带宽/抢内存）。
  /// **正在下载的模型**（key = 模型 id）—— 支持同时下多个。
  ///
  /// 用户 2026-10-06 定：以前"一次只能下一个、别的按钮全灰"太憋屈；
  /// 但也不是无上限 —— 见 [_maxConcurrentDownloads]。
  final Map<String, _ActiveDownload> _downloads = <String, _ActiveDownload>{};

  /// 同时下载的上限。
  ///
  /// 为什么是 3：手机上几个 GB 的文件，并发太多会互相抢带宽（每个都变慢）、
  /// 也多占内存与连接数；3 个能把"国内主源 4–5 MB/s"用满，再多收益很小。
  static const int _maxConcurrentDownloads = 3;

  /// 登记表写入的**串行闸**（见 `local/serial_gate.dart` 的说明）。
  ///
  /// 为什么必须有：`LocalModelStore.register()` 是"读整表 → 改一条 → 写整表"，
  /// 三个下载同时完成时并发调用会互相覆盖 —— 用户下成 3 个，最后可能只登记 1 个。
  final SerialGate _registryGate = SerialGate();

  /// 正在启动/停止本地推理服务（按钮期间禁用以防重复点击）。
  bool _serverBusy = false;

  /// 本地模型的上下文档位（默认 16k）。
  ///
  /// 为什么必须能调：DSH 每轮请求光系统提示就 ~7000 tokens，
  /// 早期写死的 2048 会让**每一句话**都被引擎拒绝（真机日志实测）。
  /// 档位越大越吃内存，所以把选择权交给用户。
  int _contextSize = 16384;

  /// **真正生效**的上下文长度 —— 下限硬性 8192。
  ///
  /// ⚠️ 为什么必须有这个下限（2026-10-08 真机踩坑，现象极具迷惑性）：
  /// DSH 算生成上限的公式是 `maxTokens = contextWindow − 已用 prompt − 4096(安全余量)`，
  /// 而它一轮的固定开销（AGENTS.md + 技能清单 + 运行时快照）就约 **3125~7000 tokens**。
  /// 所以一旦把 contextWindow 写成 **4096**，提示一进去可用量就是**负的** →
  /// `maxTokens` 被强制成 **1** → 模型只吐一个 token 就停。
  ///
  /// 真机表现因此非常反直觉：**回复只有一两个字、看不懂，但"很快"**；
  /// 而同一页的【测速】却显示 90 tok/s 完全正常 —— 因为测速是 App 直接发
  /// `max_tokens=48` 给引擎，**不经过 DSH 这个 clamp**（`benchRequestBody`）。
  /// 于是"测速飞快、聊天乱码"同时出现，很容易被误判成模型坏了或引擎不兼容。
  ///
  /// 所以：档位里不再提供 4k（见下方选项），并且这里再兜一层 —— 任何来源的小值
  /// （旧设置残留、以后新加的下拉等）写出 overlay 前都会被抬到 8192。
  int get _effectiveContextSize => _contextSize < 8192 ? 8192 : _contextSize;

  /// 选中的推理后端。默认 Vulkan（引擎没有 Vulkan 时会自动退回 CPU，见下方提示）。
  /// 默认后端。
  ///
  /// ⚠️ **为什么默认 CPU，而不是 GPU**（真机日志两次证明，2026-10-07）：
  /// Vulkan（Adreno 840）在**长对话**下（DSH 一轮的 ~7000 token 系统提示 + 多轮历史）
  /// 会让引擎**段错误（code=-11）**当场崩掉服务 —— 用户看到的是"本地模型整个不能用"
  /// （Connection error）。而 CPU 后端同样条件下稳定。
  ///
  /// **崩一次的代价（完全用不了）远大于慢一点**，所以默认给 CPU；
  /// 想快可以在下面切 GPU，万一崩了，崩溃记忆会让下次启动自动回到 CPU。
  LocalModelBackend _backend = LocalModelBackend.cpu;

  /// 引擎里到底有没有 Vulkan 后端（跑 `--list-devices` 读回来的，不是猜的）。
  bool? _engineHasVulkan;

  /// 系统 API 级别。引擎是按 android-28 编的（Vulkan 1.1 的门槛），
  /// 低于 28 的系统加载不了它 —— 与其让用户看到"启动失败"，不如先把原因说清楚。
  int _sdkInt = 0;

  /// 测速结果（按后端分别记着，这样才能对比）。
  final Map<LocalModelBackend, LocalBenchResult> _bench = {};
  bool _benchBusy = false;

  /// 实测记录（按模型 id）—— 有记录的模型，提示框显示**实测**结论而不是预估。
  BenchStore? _fitStore;
  Map<String, BenchRecord> _fitRecords = const <String, BenchRecord>{};
  String? _testingId;

  /// 导入进度（宿主回推）。
  int _importDone = 0;
  int _importTotal = 0;
  String _importCurrent = '';

  @override
  void initState() {
    super.initState();
    // 先把上次记下的「推理后端 / 上下文长度」摆上来 —— 这一页是从设置页 push 进来的，
    // 返回即销毁；不读盘的话每次进来都回到 CPU / 16k（真机 2026-10-09 用户反馈）。
    _adoptSavedPanelPrefs();
    DshHost.bindImportProgress((done, total, current) {
      if (!mounted) return;
      setState(() {
        _importDone = done;
        _importTotal = total;
        _importCurrent = current;
      });
    });
    _load();
  }

  String _modelsDir(String dshHome) =>
      dshHome.isEmpty ? 'models' : '$dshHome/models';

  /// 把落盘的偏好读进面板状态。
  ///
  /// 服务**正在跑**时以它为准则在 [_load] 里做（这里只处理"没在跑"的默认情形）。
  void _adoptSavedPanelPrefs() {
    final s = widget.settings;
    _contextSize = s.localContextSize;
    _backend = LocalModelBackend.values.firstWhere(
      (b) => b.name == s.localBackendId,
      orElse: () => LocalModelBackend.cpu,
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ------------------------------------------------------------------ 知识库

  /// 「知识库」栏目（用户 2026-10-09 要求）：本地模型可查的离线资料。
  ///
  /// 这一栏只放**现状 + 入口**；下载/导入/删除都在独立页面里做
  /// —— 那些是多步操作，塞在设置页里会挤成一团。
  Widget _kbSection() {
    final total = _kbInstalled.fold<int>(0, (a, k) => a + k.bytes);
    return DshCollapsibleSection(
      title: context.tr('知识库'),
      initiallyOpen: false,
      child: DshGlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _kbInstalled.isEmpty
                  ? context.tr('还没有装知识库。知识库是给本地模型查的离线资料：'
                      '不联网、不花额度。')
                  : context.tr('已装 {0} 个 · 共 {1}', [
                      '${_kbInstalled.length}',
                      _fmt(total),
                    ]),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 11.5, height: 1.5),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _openKb(context),
                icon: const Icon(Icons.library_books_outlined, size: 16),
                label: Text(context.tr('管理知识库')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开知识库页；回来后刷新现状（用户可能刚下载或删除了）。
  Future<void> _openKb(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => KbPage(dshHome: widget.runtime.nodeHome),
      ),
    );
    final list = await KbStore(dshHome: widget.runtime.nodeHome).list();
    if (mounted) setState(() => _kbInstalled = list);
  }

  /// 打开「本地对话」（简单对话）—— 直连本机引擎，**不经过 DSH**。
  ///
  /// 服务没在跑也允许进：页面自己会说明"先回去启动它"，比给一个灰按钮让人猜好。
  void _openLocalChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalChatPage(
          dshHome: widget.runtime.nodeHome,
          settings: widget.settings,
          runtime: widget.runtime,
          onModelChanged: widget.onModelChanged,
        ),
      ),
    );
  }

  /// 载入页面数据。
  ///
  /// [forceProbe]：无视缓存重跑一次「引擎有没有 Vulkan」的探测 ——
  /// 只有右上角刷新会传 true。原因见下面那段注释（首次探测可能早于引擎就绪）。
  Future<void> _load({bool forceProbe = false}) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final raw =
          await rootBundle.loadString('assets/models/model_manifest.json');
      final manifest = OnDeviceManifest.parse(raw);
      final paths = await DshHost.getPaths();
      final dshHome = (paths['nodeHome'] as String?) ?? '';
      final store = LocalModelStore(dir: _modelsDir(dshHome));

      var profile = DeviceProfile.fromDeviceInfo(await DshHost.deviceInfo());
      if (profile.ramGb <= 0 && _manualRamGb > 0) {
        profile = DeviceProfile(
            ramGb: _manualRamGb, soc: profile.soc, abi: profile.abi);
      }

      final info = await DshHost.deviceInfo();
      // 自愈：老版本把**空名字**写进了登记表（用户口径：「下载前能看到模型名，
      // 下载后就看不到了」—— 下载前读清单、下载后读登记表）。这里用清单名把名字
      // 补回**数据层**，不是只在显示时兜底 —— 会话里的模型选择器、用量统计
      // 都读这张表，缺口留在那里用户下次还会碰到。
      final installed =
          await _healNames(store, manifest, await store.list(refresh: true));
      final fitStore = BenchStore(dir: store.dir);
      final fitRecords = await fitStore.load(refresh: true);
      // 知识库现状（只读一次，给「知识库」栏目显示几个/多大）。
      final kbList = await KbStore(dshHome: widget.runtime.nodeHome).list();
      if (!mounted) return;
      // 服务正在跑 → 面板显示**实际在跑的**参数（崩过自动降级、或与上次选择不同时，
      // 显示用户的选择就是在骗人）。这里只改界面，不把"实跑值"写回偏好。
      final srv = LocalModelServer.instance;
      final liveBackend = srv.running ? srv.backend : null;
      final liveContext = srv.running ? srv.spec?.contextSize : null;
      setState(() {
        _fitStore = fitStore;
        _fitRecords = fitRecords;
        _sdkInt = (info['sdkInt'] as num?)?.toInt() ?? 0;
        _manifest = manifest;
        _store = store;
        _profile = profile;
        _installed = installed;
        _kbInstalled = kbList;
        _loading = false;
        if (liveBackend != null) _backend = liveBackend;
        if (liveContext != null) _contextSize = liveContext;
      });
      // 引擎支持哪些后端：问一次（结果在 LocalModelServer 里缓存）。
      // ⚠️ `forceProbe` 只用在上方那个刷新按钮上 —— 用户测过一次速度后，
      //    引擎目录才真正就绪，这时必须**重探**，否则会一直沿用首次的空结果。
      final vk = await LocalModelServer.instance.vulkanStatus(force: forceProbe);
      if (mounted) {
        setState(() => _engineHasVulkan = vk.known ? vk.has : null);
      }
      // 会话缓存统计（litert-lm 那条路才有）：进页面拉一次，用户能看到复用了几次。
      await LocalModelServer.instance.refreshLiteRtStats();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _download(OnDeviceModel model) async {
    final store = _store;
    if (store == null || _downloads.containsKey(model.id)) return;
    if (_downloads.length >= _maxConcurrentDownloads) {
      // 说明为什么点不动，而不是给一个灰按钮让人猜。
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            context.tr('最多同时下载 {0} 个（再多每个都会变慢）', ['$_maxConcurrentDownloads'])),
      ));
      return;
    }
    final cancel = DownloadCancelToken();
    final active = _ActiveDownload(cancel);
    final downloader = ModelDownloader(dir: store.dir);
    setState(() => _downloads[model.id] = active);
    final messenger = ScaffoldMessenger.of(context);
    // 文案在 await 之前取好（跨 await 用 context 会被 lint 拦，也不安全）。
    final msgHashOk = context.tr('已下载并校验 sha256：{0}', [model.name]);
    final msgSizeOnly = context.tr('已下载（仅体积校验）：{0}', [model.name]);
    final msgFail = context.tr('下载失败：{0}');
    try {
      final r = await downloader.download(
        model,
        cancel: cancel,
        // 清单顶层的开关要真的传下去 —— 以前它没被读，打开也不生效（审计 P1-10）。
        requireHash: _manifest.requireHash,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => active.progress = p);
        },
      );
      // 并发下完可能同时回来 → **串行**写登记表。
      await _registerInstalled(
        store,
        InstalledModel.fromEntry(
          model,
          sha256: model.sha256,
          bytes: r.bytes,
          sourceLabel: r.sourceLabel,
        ),
      );
      final installed = await store.list(refresh: true);
      if (!mounted) return;
      setState(() => _installed = installed);
      messenger.showSnackBar(SnackBar(
        content: Text(r.hashVerified ? msgHashOk : msgSizeOnly),
      ));
      debugPrint('[dsh-ondevice] ✅ ${model.id} ← ${r.sourceLabel}');
    } catch (e) {
      debugPrint('[dsh-ondevice] ❌ ${model.id}: $e');
      messenger.showSnackBar(
        SnackBar(content: Text(msgFail.replaceFirst('{0}', '$e'))),
      );
    } finally {
      downloader.close();
      if (mounted) setState(() => _downloads.remove(model.id));
    }
  }

  /// 串行执行登记表写入（见 [_registryGate] 的说明）。
  Future<void> _registerInstalled(LocalModelStore store, InstalledModel m) =>
      _registryGate.run(() => store.register(m));

  Future<void> _importFromDevice() async {
    final store = _store;
    if (store == null) return;
    final importer = ModelImporter(dir: store.dir, store: store);
    // 候选＝清单里这台机器跑得动、且还没装的那些（原生按文件名匹配校验）。
    final candidates = _manifest
        .availableFor(_profile)
        .where((m) => !_installed.containsKey(m.id))
        .toList(growable: false);
    try {
      final summary = await importer.importFromDevice(candidates);
      if (!mounted) return;
      setState(() {
        _importDone = 0;
        _importTotal = 0;
        _importCurrent = '';
      });
      final installed = await store.list(refresh: true);
      if (!mounted) return;
      setState(() => _installed = installed);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(summary.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('导入失败：{0}', ['$e']))),
      );
    }
  }

  Future<void> _delete(InstalledModel installed) async {
    final store = _store;
    if (store == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(context
            .tr('确定删除「{0}」吗？会释放 {1}', [installed.name, _fmt(installed.bytes)])),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await store.remove(installed.id);
    final list = await store.list(refresh: true);
    if (!mounted) return;
    setState(() => _installed = list);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('已删除 {0}', [installed.name]))),
    );
  }

  /// 起本地推理服务（llama.cpp）并把它的模型注册进 DSH。
  ///
  /// 顺序不能反：**必须先确认服务真的就绪，再重写 overlay**。
  /// 反过来的话，overlay 会短暂指向一个还不存在的端口 —— 用户正好这时发消息就失败。
  Future<void> _startServer(InstalledModel m) async {
    final store = _store;
    if (store == null || _serverBusy) return;
    final entry = _manifest.byId(m.id);
    final modelPath = store.pathFor(m.fileName);
    setState(() => _serverBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    // ⚠️ 文案要在 await **之前**取好：await 之后再碰 context 会命中
    // use_build_context_synchronously（这期间页面可能已经被销毁）。
    // ⚠️ 带上**真正的原因**（用户 2026-10-11：「点选本地大模型目前显示本地服务没起来」——
    //    只说"没起来"等于没说）。原因由 LocalModelServer 记着，见它的 lastError。
    final why = LocalModelServer.instance.lastError;
    final msgNotUp = (why == null || why.trim().isEmpty)
        ? context.tr('本地服务没起来（详见运行日志）')
        : context.tr('本地服务没起来：{0}', <Object?>[why]);
    final msgReady = context.tr('本地模型已就绪：{0}', [m.name]);
    final msgStartFail = context.tr('启动失败：{0}');
    try {
      final port = await LocalModelServer.instance.ensureRunning(
        backend: _backend,
        contextSize: _effectiveContextSize,
        runtime: widget.runtime,
        model: entry ??
            OnDeviceModel(
              id: m.id,
              family: m.family,
              name: m.name,
              kind: m.kind,
              engine: m.engine,
              format: m.format,
              fileName: m.fileName,
              bytes: m.bytes,
              quant: m.quant,
              license: m.license,
              minRamGb: 1,
              sources: const <ModelSource>[],
            ),
        modelPath: modelPath,
      );
      if (port == null) {
        messenger.showSnackBar(SnackBar(content: Text(msgNotUp)));
        return;
      }
      await widget.onModelChanged();
      messenger.showSnackBar(SnackBar(content: Text(msgReady)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(msgStartFail.replaceFirst('{0}', '$e'))),
      );
    } finally {
      if (mounted) setState(() => _serverBusy = false);
    }
  }

  /// 跑一次真实推理，量出这台手机的生成速度。
  ///
  /// 为什么这个按钮是 P1 的核心：**Vulkan 到底快多少只有用户那台手机能回答**。
  /// 切成"仅 CPU"测一次、切成 Vulkan 再测一次，对比表就出来了。
  Future<void> _runBench() async {
    if (_benchBusy || !LocalModelServer.instance.running) return;
    final backend = _backend;
    setState(() => _benchBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    final msgFail = context.tr('测速失败（详见运行日志）');
    try {
      final r = await LocalModelServer.instance.measure();
      if (!mounted) return;
      if (r == null) {
        messenger.showSnackBar(SnackBar(content: Text(msgFail)));
        return;
      }
      setState(() => _bench[backend] = r);
    } finally {
      if (mounted) setState(() => _benchBusy = false);
    }
  }

  Future<void> _stopServer() async {
    if (_serverBusy) return;
    setState(() => _serverBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    final msgStopped = context.tr('本地服务已停止');
    try {
      await LocalModelServer.instance.stop();
      // 停了也要重写：否则 overlay 里还留着 local 厂家，指向一个已经关掉的端口。
      await widget.onModelChanged();
      messenger.showSnackBar(SnackBar(content: Text(msgStopped)));
    } finally {
      if (mounted) setState(() => _serverBusy = false);
    }
  }

  /// 把登记表里**空名字**的条目用清单名修回来并回写（数据层自愈）。
  ///
  /// 只在**确实为空**时动手，且优先用清单名（它才是最新的显示名），
  /// 清单里找不到就退 id —— 绝不覆盖用户/清单已有的好名字。
  Future<Map<String, InstalledModel>> _healNames(
    LocalModelStore store,
    OnDeviceManifest manifest,
    Map<String, InstalledModel> list,
  ) async {
    final fixes = <InstalledModel>[];
    for (final i in list.values) {
      if (i.name.trim().isNotEmpty) continue;
      final entry = manifest.byId(i.id);
      final want =
          (entry?.name.trim().isNotEmpty ?? false) ? entry!.name : i.id;
      if (want.trim().isEmpty || want == i.name) continue;
      fixes.add(i.withName(want));
    }
    if (fixes.isEmpty) return list;
    for (final m in fixes) {
      await _registryGate.run(() => store.register(m));
    }
    debugPrint('[dsh-ondevice] 登记表自愈：${fixes.length} 条空名字已补回清单名');
    return store.list(refresh: true);
  }

  /// 清单声明了伴生文件、但本地没下齐 → 返回缺的那些文件名（空 = 齐了）。
  List<String> _missingCompanions(OnDeviceModel? m) {
    final store = _store;
    if (store == null || m == null || m.companions.isEmpty) {
      return const <String>[];
    }
    return <String>[
      for (final c in m.companions)
        if (!_companionOnDisk(store, c)) c.fileName,
    ];
  }

  bool _companionOnDisk(LocalModelStore store, ModelCompanion c) {
    final f = File(store.pathFor(c.fileName));
    if (!f.existsSync()) return false;
    // 字节数对不上也算没下好（半截文件启动只会更糟）。
    return c.bytes <= 0 || f.lengthSync() == c.bytes;
  }

  /// 这个模型在这台手机上的匹配度：**有实测就用实测**，否则按配置预估。
  ModelFitResult _fitOf(OnDeviceModel m) {
    final rec = _fitRecords[m.id];
    if (rec != null && rec.tokensPerSecond > 0) {
      return fitFromMeasurement(
          tokensPerSecond: rec.tokensPerSecond, promptMs: rec.promptMs);
    }
    return estimateFit(
      model: m,
      profile: _profile,
      engineBundled: _engineAvailable(m),
      companionsInstalled: _missingCompanions(m).isEmpty,
    );
  }

  /// 真跑一次并记下来（用户口径：每个大模型都测一下，看是不是匹配这台手机）。
  ///
  /// 代价要说清：**这一步会把模型真的加载起来**（几秒到几十秒），
  /// 而且会切换当前正在跑的本地模型。所以是"点了才做"，不自动跑。
  Future<void> _runFitTest(InstalledModel m) async {
    final store = _store;
    final fitStore = _fitStore;
    if (store == null || fitStore == null || _testingId != null) return;
    setState(() => _testingId = m.id);
    final messenger = ScaffoldMessenger.of(context);
    final why2 = LocalModelServer.instance.lastError;
    final msgNotUp = (why2 == null || why2.trim().isEmpty)
        ? context.tr('本地服务没起来（详见运行日志）')
        : context.tr('本地服务没起来：{0}', <Object?>[why2]);
    final msgNoResult = context.tr('测速失败（详见运行日志）');
    final msgDone = context.tr('实测完成：{0}', [m.name]);
    final msgStartFail = context.tr('启动失败：{0}');
    try {
      final entry = _manifest.byId(m.id);
      final port = await LocalModelServer.instance.ensureRunning(
        backend: _backend,
        contextSize: _effectiveContextSize,
        runtime: widget.runtime,
        model: entry ??
            OnDeviceModel(
              id: m.id,
              family: m.family,
              name: m.name,
              kind: m.kind,
              engine: m.engine,
              format: m.format,
              fileName: m.fileName,
              bytes: m.bytes,
              quant: m.quant,
              license: m.license,
              minRamGb: 1,
              sources: const <ModelSource>[],
            ),
        modelPath: store.pathFor(m.fileName),
      );
      if (port == null) {
        messenger.showSnackBar(SnackBar(content: Text(msgNotUp)));
        return;
      }
      final r = await LocalModelServer.instance.measure();
      if (r == null) {
        messenger.showSnackBar(SnackBar(content: Text(msgNoResult)));
        return;
      }
      await fitStore.save(BenchRecord(
        modelId: LocalModelServer.instance.spec?.modelId ?? m.id,
        tokensPerSecond: r.tokensPerSecond,
        promptMs: r.promptMs,
        at: DateTime.now(),
      ));
      final records = await fitStore.load(refresh: true);
      if (!mounted) return;
      setState(() {
        _fitRecords = records;
        _bench[_backend] = r;
      });
      await widget.onModelChanged();
      messenger.showSnackBar(SnackBar(content: Text(msgDone)));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text(msgStartFail.replaceFirst('{0}', '$e'))));
    } finally {
      if (mounted) setState(() => _testingId = null);
    }
  }

  /// 三档提示框：红=无法运行、白=勉强运行、绿=流畅运行（用户口径）。
  Widget _fitBadge(ModelFitResult r) {
    final color = switch (r.fit) {
      ModelFit.unsupported => DshColors.err,
      ModelFit.barely => DshColors.textDim,
      ModelFit.smooth => DshColors.ok,
    };
    final label = switch (r.fit) {
      ModelFit.unsupported => context.tr('无法运行'),
      ModelFit.barely => context.tr('勉强运行'),
      ModelFit.smooth => context.tr('流畅运行'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(DshMetrics.radius(20)),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.7),
      ),
      child: Text(
        r.measured ? '$label · ${context.tr('实测')}' : label,
        style:
            TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// 一个下载**自己的**那一行：速率 · 进度 · 已下/总量 · 来源。
  ///
  /// 用户 2026-10-06 要求：「可以同时下载，但要在每个模型下边写下载速率」——
  /// 所以速率放最前面，且每个模型各有一行（不再是一个全局进度条）。
  Widget _downloadProgressLine(_ActiveDownload dl, OnDeviceModel model) {
    final p = dl.progress;
    final total = (p?.total ?? model.totalBytes);
    final received = p?.received ?? 0;
    final frac = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
    final parts = <String>[
      _speed(p?.bytesPerSecond ?? 0),
      '${(frac * 100).round()}%',
      '${_fmt(received)} / ${_fmt(total)}',
      if ((p?.sourceLabel ?? '').isNotEmpty)
        context.tr('来自 {0}', [p!.sourceLabel]),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(11, 0, 11, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LinearProgressIndicator(value: frac),
          const SizedBox(height: 4),
          Text(parts.join('　'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 10.5, height: 1.4)),
        ],
      ),
    );
  }

  /// 速率格式化（MB/s / KB/s / B/s）。0 = 还没测到，显示省略号而不是 0.0 MB/s。
  static String _speed(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '…';
    if (bytesPerSecond >= 1048576) {
      return '${(bytesPerSecond / 1048576).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  }

  static String _fmt(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    }
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  /// 这个**引擎名**在当前包里有没有（判据是 nativeLibraryDir 里那个 .so 在不在，
  /// 所以界面永远不会撒谎）。
  ///
  /// 现在包里只剩两类引擎：
  ///   * **llama.cpp**：**不再随包**（0.47 决策 + 真机实证在 Armv9.2 上长请求必段错误），
  ///     所以这一档永远判 false，等于"界面上不再提供它"；
  ///   * **stable-diffusion.cpp**：**2026-10-11 按用户要求整条删除**（纯死重，
  ///     压缩后约 14.9 MiB），连判断分支一起删掉了 —— 要恢复见 build.gradle.kts 的说明；
  ///   * **LiteRT-LM**：Google 官方 AAR 带进来的 .so（`litertlm-android`）✓ 在包里。
  bool _engineBundled(String engine) {
    final dir = widget.runtime.nativeLibDir;
    if (dir.isEmpty) return false;
    // 只认 MNN（2026-11-03）。另外两个引擎已从清单里下线。
    return switch (engine) {
      // 我们自编的最小 server（4.9MB，静态链了 libMNN.a）。
      'mnn' => File('$dir/libmnn_mini_server.so').existsSync(),
      _ => false,
    };
  }

  bool _engineAvailable(OnDeviceModel? m) =>
      m == null ? false : _engineBundled(m.engine);

  /// 为什么这个模型在**这一版**跑不了 —— 一句话给用户看。
  ///
  /// 用户 2026-10-11 真机日志：盘上留着一个旧版下载的 `.gguf`，界面只把「启动」
  /// 按钮藏起来、**一个字都不解释**，于是"点选本地大模型显示本地服务没起来"。
  static String _engineWhy(String engine) {
    switch (engine) {
      case 'mnn':
        return '包里没找到 MNN 引擎（libmnn_mini_server.so）—— 安装不完整，重装一次试试';
      default:
        // 清单里已只有 MNN；万一有旧数据残留，如实说"这版不支持"。
        return '这版只支持 MNN 引擎（这个模型要的是「$engine」）—— 换一个带 MNN 标记的模型';
    }
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 必须包一层 Scaffold：这一页是 push 出来的独立路由，
    // 以前直接返回 Column → **没有 Material 祖先** → 卡片里的 InkWell
    // 在点击时抛 `Null check operator used on a null value`（真机日志抓到两次，
    // 栈是 `Material.of ← _InkResponseState._createSplash`）；
    // 顺带也解决"这一页弹 SnackBar 没有宿主"的问题。
    return Scaffold(
      backgroundColor: DshColors.bg,
      body: _buildPageBody(context),
    );
  }

  Widget _buildPageBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DshPageHeader(
          title: context.tr('本地大模型（测试）'),
          subtitle: context.tr('本机运行，不联网也能用'),
          trailing: IconButton(
            // 连"有没有 Vulkan"一起重探（forceProbe）—— 用户跑过一次模型后
            // 引擎目录才就绪，只重载清单的话 GPU 会一直不可选（真机踩到过）。
            onPressed: _loading ? null : () => _load(forceProbe: true),
            tooltip: context.tr('重新载入清单'),
            icon: Icon(Icons.refresh,
                size: 20,
                color: _loading ? DshColors.textFaint : DshColors.textDim),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
                  ? _buildError()
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(
                          DshMetrics.pagePad, 0, DshMetrics.pagePad, 28),
                      children: _buildBody(),
                    ),
        ),
      ],
    );
  }

  Widget _buildError() => Padding(
        padding: const EdgeInsets.all(DshMetrics.pagePad),
        child: Text(
          context.tr('清单载入失败：{0}', [_loadError ?? '']),
          style: TextStyle(color: DshColors.accent3, fontSize: 12),
        ),
      );

  List<Widget> _buildBody() {
    // ⚠️ **顺序就是优先级**（用户 2026-10-07：「下载好后发现没有模型名了，排版太乱」）。
    // 用户进这一页是**来看自己的模型**的 —— 所以模型列表必须第一眼就在；
    // 设备信息 / 服务设置 / 说明全部往后放（服务卡还默认收起）。
    // 之前是 设备卡 → 说明 → 整屏服务设置 → 导入 → 才轮到模型，
    // 模型列表被挤到第三屏，看起来就像"模型名没了"。
    final out = <Widget>[];
    // 用户口径（2026-10-08）：**只保留「文本」与「多模态」两个板块**，
    // 撤掉「图形」与「视频」——集中火力把「对话」（纯文本 + 看图对话）做扎实。
    // 出图/出视频那套（stable-diffusion.cpp、sd-server、提示词→生成）**已于 2026-10-11 整条删除**：
    // 以后要恢复，把下面这个 where 去掉即可（引擎与页面入口都是现成的）。
    for (final g in _ModelGroup.values.where(
        (g) => g != _ModelGroup.image && g != _ModelGroup.video)) {
      final section = _groupSection(g);
      if (section != null) out.add(section); // 空分组不占位
    }
    out.add(_importSection());
    out.add(_serviceSection());
    out.add(_kbSection());
    out.add(_deviceCard());
    out.add(_whatThisMeansSection());
    out.add(const SizedBox(height: 10));
    out.add(Text(
      context.tr('清单里的 sha256 还没回填时，只能校验文件大小；回填后才会逐字节校验。'),
      style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
    ));
    return out;
  }

  // ------------------------------------------------------------------ 设备

  Widget _deviceCard() {
    final mem = _profile.ramGb > 0 ? '${_profile.ramGb} GB' : context.tr('未知');
    final soc = _profile.soc.trim().isEmpty ? context.tr('未知') : _profile.soc;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: DshGlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _kv(context.tr('运行内存'), mem),
            _kv(context.tr('芯片'), soc),
            _kv('ABI', _profile.abi),
            const SizedBox(height: 2),
            Text(
              context.tr('清单按「内存 + 芯片」挑文件：芯片命中就下 NPU 专属版，否则用通用版。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.5),
            ),
            if (_sdkInt > 0 && _sdkInt < 28) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                context.tr('本机模型需要 Android 9 或更高（当前系统较旧）'),
                style: TextStyle(
                    color: DshColors.accent3, fontSize: 11, height: 1.5),
              ),
            ],
            if (_profile.ramGb <= 0) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                context.tr('内存读不到，先手动选一个档'),
                style: TextStyle(
                    color: DshColors.accent3, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <int>[4, 6, 8, 12].map((gb) {
                  return OutlinedButton(
                    onPressed: () {
                      setState(() => _manualRamGb = gb);
                      _load();
                    },
                    child: Text('$gb GB', style: const TextStyle(fontSize: 12)),
                  );
                }).toList(growable: false),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 与设置页同一个排版：左侧 78 宽灰字 + 右侧值。
  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 78,
              child: Text(key,
                  style: TextStyle(color: DshColors.textFaint, fontSize: 12)),
            ),
            Expanded(
              child: Text(value,
                  style: TextStyle(
                      color: DshColors.text, fontSize: 12.5, height: 1.4)),
            ),
          ],
        ),
      );

  /// 「这些是什么意思？」——把这一页的概念一次讲清。
  ///
  /// 为什么要它：用户真机反馈过「推理后端，仅cpu和vulkan什么意思」
  /// 「缺 litert-lm 引擎是什么意思」——**这些解释必须长在选择的地方**，
  /// 只答在聊天里等于没答（他下次打开还是不知道）。
  Widget _whatThisMeansSection() => DshCollapsibleSection(
        title: context.tr('这些是什么意思？'),
        child: DshGlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _explain(
                context.tr('引擎是什么'),
                // ⚠️ 这段文案以前写错过（说"只随包了 llama.cpp"，而事实相反）：
                // llama.cpp 自 0.47 就不随包了，stable-diffusion 也已在 2026-10-11 删除。
                // 现在包里只有 **LiteRT-LM**（Gemma 4 那批 `.litertlm` 用它）。
                context.tr('模型文件只是"权重"（一堆数字），真正算的是引擎。'
                    '这一版随包的是 **LiteRT-LM**（跑 Gemma 4 那批 `.litertlm`）。'
                    '其它格式（比如 `.gguf` 的 llama.cpp）**没有**编进包里，'
                    '所以那些模型会显示「缺引擎」。'
                    '缺引擎不是你的手机不行，是包里没有那个引擎；引擎一上，红就会变绿。'),
              ),
              _explain(
                context.tr('推理后端：仅 CPU 与 Vulkan'),
                context.tr('同一份模型文件，区别只是"谁来算"：'
                    '仅 CPU = 手机 CPU 算，慢但几乎所有手机都能跑；'
                    'Vulkan = 交给手机 GPU 算，通常快 2–5 倍、更省电，需要 Android 9 以上。'
                    '切换后端要重启服务。同一个模型两个后端各测一次，就能直接比出哪个快。'),
              ),
              _explain(
                context.tr('视觉编码器（mmproj）'),
                context.tr('多模态模型"看图"靠它 —— 它是单独一个文件（几百 MB），'
                    '所以下载时会跟本体一起下（清单里叫"伴生文件"）。'
                    '少了下半截，模型就只能聊天、看不了图。'),
              ),
              _explain(
                context.tr('三色档位怎么算的'),
                context.tr('先看引擎有没有（没有 → 红）；引擎有再看内存'
                    '（不够 → 红；余量不足 2 GB、或 2 GB 以上文件装在 8 GB 机上 → 白）；'
                    '都过 → 绿。点【测试】真跑一次之后，改用实测速度判：'
                    '低于 5 tok/s 红、5–10 白、10 以上绿。'),
              ),
              _explain(
                context.tr('现在还不能"看图"'),
                context.tr('多模态模型下完可以对话，但图片还发不进模型：'
                    'App 目前只发纯文本。引擎其实已经带了看图能力，'
                    '只差"启动时指一下视觉编码器"和"把图片发出去"这两处接线，后面版本补。'),
              ),
            ],
          ),
        ),
      );

  /// 说明里的一个小节：一行标题 + 一段白话。
  Widget _explain(String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title,
                style: TextStyle(
                    color: DshColors.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(body,
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.55)),
          ],
        ),
      );

  // ------------------------------------------------------------------ 服务

  Widget _serviceSection() {
    final server = LocalModelServer.instance;
    final running = server.running;
    return DshCollapsibleSection(
      title: context.tr('本地模型服务'),
      // 默认收起：这一块是"设置"，不是"内容"。行内已经有「启动」按钮，
      // 真正要调后端/上下文的人才展开它。
      initiallyOpen: false,
      child: DshGlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: running ? DshColors.accent2 : DshColors.textFaint,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    server.statusText(),
                    style: TextStyle(
                        color: DshColors.text, fontSize: 12.5, height: 1.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 「简单对话」的入口 —— 用户 2026-10-09 定的口径：本地模型只做简单对话。
            // 会话里那条路（DSH Agent 协议）已按同一口径摘掉（见 model_sheet 的注释）。
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _openLocalChat(context),
                icon: const Icon(Icons.chat_bubble_outline, size: 16),
                label: Text(context.tr('跟它聊两句（简单对话）')),
              ),
            ),
            const SizedBox(height: 10),
            Text(context.tr('推理后端'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: LocalModelBackend.values.map((b) {
                final vk = b == LocalModelBackend.vulkan;
                final disabled = (vk && _engineHasVulkan == false) || running;
                final selected = _backend == b;
                return OutlinedButton(
                  style: selected
                      ? OutlinedButton.styleFrom(
                          side: BorderSide(color: DshColors.accent, width: 1))
                      : null,
                  onPressed: disabled
                      ? null
                      : () {
                          setState(() => _backend = b);
                          // 记住它 —— 只管**下次启动**；正在跑的服务不受影响。
                          widget.settings.setLocalBackend(b.name);
                        },
                  child: Text(
                    // 按钮上只放短名，两颗才能并排一行（完整说明在下方一行）。
                    b.shortLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected ? DshColors.accent : DshColors.textDim,
                    ),
                  ),
                );
              }).toList(growable: false),
            ),
            // `false` = 真探测过、确实没编 Vulkan；`null` = 还没探测成功
            // （引擎目录未就绪）。两者**必须分开说** —— 否则首次打开就被
            // 断言"没编 Vulkan"，用户跑一次模型刷新后又"活了"，很困惑。
            if (_engineHasVulkan == false) ...<Widget>[
              const SizedBox(height: 6),
              Text(context.tr('这版引擎没编 Vulkan，只有 CPU 后端'),
                  style: TextStyle(
                      color: DshColors.accent3, fontSize: 11, height: 1.5)),
            ] else if (_engineHasVulkan == null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                  context.tr('GPU 还没探测（引擎目录未就绪）：'
                      '先启动一次本地模型，再点右上角刷新，GPU 就会可选。'),
                  style: TextStyle(
                      color: DshColors.textFaint, fontSize: 10.5, height: 1.5)),
            ],
            // ⚠️ **服务运行中两颗按钮全是灰的**（切换要重启服务，这是设计）。
            //    但界面上原本**一句解释都没有** —— 真机 2026-10-08 用户就直接理解成
            //    "GPU 选不了"，以为引擎不支持，白绕了一圈。必须写明。
            if (running) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                  context.tr('服务运行中：要改推理后端或上下文长度，'
                      '先点上面的「停止」，再选、再启动。'),
                  style: TextStyle(
                      color: DshColors.accent3, fontSize: 11, height: 1.5)),
            ],
            // 因为"上次崩过"而换了后端 → 必须写明，否则用户会以为"我要的 GPU 怎么没了"。
            if (server.downgradeNote.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                server.downgradeNote,
                style: TextStyle(
                    color: DshColors.accent3, fontSize: 11, height: 1.5),
              ),
            ],
            // 模型文件自带的缓存比用户设的小 → 必须写明"实际生效的是多少"。
            // 不写就是界面在骗人：用户设了 16384，实际只有 4096，一到上限就失败。
            if (server.contextNote.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                server.contextNote,
                style: TextStyle(
                    color: DshColors.accent3, fontSize: 11, height: 1.5),
              ),
            ],
            // 启动自检没过 → 直接说清"这个模型现在是用不了的"，别让用户自己猜。
            if (server.lastSelfCheckOk == false) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                context.tr('⚠️ 这个模型的对话模板可能与 DSH 不兼容（启动自检没通过）：'
                    '发消息很可能直接失败。请到「设置 → 运行日志」导出后发回，'
                    '我会按真实报错改。'),
                style:
                    TextStyle(color: DshColors.err, fontSize: 11, height: 1.5),
              ),
            ],
            const SizedBox(height: 10),
            Text(context.tr('上下文长度'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              // ⚠️ **不提供 4096**（2026-10-08 真机踩坑）：DSH 每轮固定开销就约 3125~7000 tokens，
              //    而它算生成上限是 `contextWindow − 已用 − 4096` —— 选 4k 会算出负值，
              //    `maxTokens` 被强制成 1，模型只吐一个字就停（回复"看不懂但很快"，
              //    而【测速】因为直接发 max_tokens=48、不走这个 clamp，反而显示 90 tok/s 正常）。
              //    这是**必然坏**的一档，所以直接从选项里去掉；下限另有 _effectiveContextSize 兜底。
              children: <int>[8192, 16384, 32768].map((n) {
                final selected = _contextSize == n;
                return OutlinedButton(
                  style: selected
                      ? OutlinedButton.styleFrom(
                          side: BorderSide(color: DshColors.accent, width: 1))
                      : null,
                  onPressed: running
                      ? null
                      : () {
                          setState(() => _contextSize = n);
                          // 同样落盘：下次进这一页、下次启动服务都以此为准。
                          widget.settings.setLocalContextSize(n);
                        },
                  child: Text('${n ~/ 1024}k',
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              selected ? DshColors.accent : DshColors.textDim)),
                );
              }).toList(growable: false),
            ),
            const SizedBox(height: 4),
            Text(
              context.tr('对话越长越吃上下文：DSH 每轮光系统提示就要约 7k tokens，'
                  '所以别选 4k（会一直报"上下文不够"）。越大越吃内存，'
                  '服务和测速都用这个档位；改了要重启服务。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
            ),
            const SizedBox(height: 4),
            // 真机反馈：从别的页面转回来这两项就重置了。现在会记住，得**说出来**，
            // 否则用户不知道它记住了（也就在"服务运行中按钮是灰的"时能对上账）。
            Text(
              context.tr('「推理后端」和「上下文长度」会记住：下次进这一页、'
                  '下次启动本地服务都以它为准。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
            ),
            // 用户反馈「仅cpu和vulkan什么意思」—— 这个说明必须在**选择的地方**，
            // 不能只活在聊天记录里。
            const SizedBox(height: 6),
            DshRichText(
              context.tr('这两颗按钮跟手机档次无关 —— 同一份模型，只是换「谁来算」：'
                  'CPU 是通用的，慢一点但稳；GPU 用图形芯片加速，通常快好几倍，'
                  '但**部分机型在长对话时会把引擎干崩**（真机上遇到过，崩了就会报连不上）。'
                  '所以默认给了 CPU；想快就切 GPU 试 —— 万一崩，下次启动会自动换回 CPU。'),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 11, height: 1.5),
            ),
            const SizedBox(height: 4),
            Text(
              context.tr('第一次用建议：选一个 → 启动 →【测速】，再换另一个测一次，'
                  '哪个 tok/s 高就用哪个。切换要重启服务，所以跑着的时候按钮是灰的。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (running)
                  OutlinedButton(
                    onPressed: _serverBusy ? null : _stopServer,
                    child: Text(context.tr('停止服务'),
                        style: const TextStyle(fontSize: 12)),
                  ),
                if (running)
                  OutlinedButton(
                    onPressed: _benchBusy ? null : _runBench,
                    child: Text(
                        _benchBusy ? context.tr('测速中…') : context.tr('测速'),
                        style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            for (final e in _bench.entries)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(
                  '${e.key.label}　'
                  '${e.value.tokensPerSecond.toStringAsFixed(1)} tok/s　'
                  '${context.tr('首字 {0} ms', [
                        e.value.promptMs.toStringAsFixed(0)
                      ])}'
                  // LiteRT-LM 只能按回调次数估，必须标出来 —— 拿估算值和精确值
                  // 并排比是误导。
                  '${e.value.approx ? context.tr('（近似）') : ''}',
                  style: TextStyle(
                      color: DshColors.textDim, fontSize: 11, height: 1.5),
                ),
              ),
            // 会话缓存：这一行才是"还是慢"的直接答案 —— 省掉了几次重算整段历史。
            if (server.liteRtCacheText().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(
                  server.liteRtCacheText(),
                  style: TextStyle(
                      color: DshColors.textDim, fontSize: 11, height: 1.5),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              context.tr('服务只在 App 运行时存在；重开 App 会摘掉失效的本地路由，点「启动」即可恢复。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 导入

  Widget _importSection() {
    final importing = _importTotal > 0;
    return DshCollapsibleSection(
      title: context.tr('导入'),
      child: DshGlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DshTileRow(
              icon: Icons.folder_open,
              title: context.tr('从本地文件导入'),
              note: context.tr('可多选。网盘、微信、数据线拿到的模型文件都从这里进来，不需要存储权限。'),
              onTap: importing ? () {} : _importFromDevice,
            ),
            if (importing) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                context.tr('正在导入 {0}/{1}：{2}',
                    ['$_importDone', '$_importTotal', _importCurrent]),
                style: TextStyle(
                    color: DshColors.textDim, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: _importTotal == 0 ? 0 : _importDone / _importTotal,
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------- 文本 / 图形 / 视频

  /// 一个分组（文本 / 多模态 / 图形 / 视频）。
  ///
  /// ⚠️ 两条来自用户真机反馈（2026-10-07：「下载好后发现没有模型名了，排版太乱」）的规矩：
  ///
  /// 1. **空分组不渲染**（返回 null）—— 四个分组全都摆出「文本（0）」这种空板块，
  ///    是"乱"的主要来源；
  /// 2. **有内容的组常驻展开**，不再套折叠块：用户下载完进来就是要看模型名，
  ///    让他先点一下标题才看得到，实际结果就是"我的模型没了"。
  Widget? _groupSection(_ModelGroup group) {
    final rows = <Widget>[];
    for (final family in _manifest.families) {
      final all = _manifest.models.where((m) => m.family == family).toList();
      if (all.isEmpty) continue;
      if (_ModelGroup.of(all.first.kind) != group) continue;
      all.sort((a, b) => a.minRamGb.compareTo(b.minRamGb));

      // 已装的先列（同一个 family 可能有多个变体装着）。
      final installed = _installed.values
          .where((i) => i.family == family)
          .toList(growable: false);
      if (installed.isNotEmpty) {
        for (final i in installed) {
          rows.add(_installedRow(i, _manifest.byId(i.id)));
        }
        continue;
      }

      final best = _manifest.bestFor(family, _profile);
      if (best == null) {
        rows.add(_row(
          title: all.first.name,
          note: context.tr('内存不足：本机 {0} GB，这个模型要 {1} GB',
              ['${_profile.ramGb}', '${all.first.minRamGb}']),
          noteTint: DshColors.accent3,
          fit: _fitOf(all.first),
        ));
        continue;
      }
      final dl = _downloads[best.id];
      final full = _downloads.length >= _maxConcurrentDownloads;
      rows.add(_row(
        title: best.name,
        fit: _fitOf(best),
        // 同理：名字在上、按钮在下（下载行以前也会被按钮挤掉名字）。
        stackTitle: true,
        // ⚠️ 不要再写"需要内存 ≥ X GB"：上面的**依据行**（fit.reason）每一个档位
        // 都已经写了内存要求（见 model_fit.dart），这里再写一遍就是同一行里
        // 重复两遍 —— 用户说的"排版太乱"有它一份。许可保留（依据行不含它）。
        note: '${_fmt(best.totalBytes)}'
            '　${context.tr('许可：{0}', [best.license])}'
            // MNN 的 companions 是配置文件（llm_config/tokenizer），不是视觉编码器 ——
            // 标成 mmproj 是错的，用户会以为这模型能看图（2026-11-02）。
            '${best.companions.isEmpty || best.engine == 'mnn' ? '' : '　${context.tr('含视觉编码器（mmproj）')}'}',
        trailing: dl != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    context.tr('下载中 {0}%',
                        ['${((dl.progress?.fraction ?? 0) * 100).round()}']),
                    style: TextStyle(color: DshColors.textDim, fontSize: 11),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: () => dl.cancel.cancel(),
                    child: Text(context.tr('取消'),
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              )
            // 到上限时置灰 —— 点了会提示"最多同时下 N 个"，而不是静默没反应。
            //
            // ⚠️ 顺带加一道闸：**引擎不在包里的模型不给下**。
            // 清单现在只有 3 个 .litertlm，但这条闸必须留着 —— 用户真机上的坑正是
            // "下了一个本版根本跑不了的模型"（旧版清单里的 .gguf），下完才发现用不了，
            // 白下几百 MB。判据与「启动」按钮同一套（_engineBundled）。
            : OutlinedButton(
                onPressed: (full || !_engineBundled(best.engine))
                    ? null
                    : () => _download(best),
                child: Text(context.tr('下载'),
                    style: const TextStyle(fontSize: 12)),
              ),
      ));
      if (dl != null) rows.add(_downloadProgressLine(dl, best));
    }

    if (rows.isEmpty) return null;
    return DshStaticSection(
      title: '${group.label}（${rows.length}）',
      child: DshGlassCard(child: Column(children: rows)),
    );
  }

  Widget _installedRow(InstalledModel i, OnDeviceModel? entry) {
    final running = LocalModelServer.instance.spec?.modelId == i.id;
    final okFile = _store?.fileOk(i) ?? false;
    // ⚠️ **这一行就是用户 2026-10-11 那条日志的根因**。
    //
    // 以前写的是 `entry == null || _engineAvailable(entry)` —— 把"清单里没有这个模型"
    // 当成了"那它肯定是能跑的（比如用户自己导入的）"。
    //
    // 真机日志（nubia NX809J / v0.60 / 23:28:18 起）证明这个假设是错的：
    // 用户盘上留着一个**旧版本下载的 `.gguf`（llama.cpp）**，而它在新清单里已经没有了
    // （llama.cpp 自 0.47 起不随包）→ `entry == null` → `runnable` 被判成 **true**
    // → 界面给出「启动」按钮 → 一点就去找 `libllamaserver.so` → 必然"引擎不存在"，
    // 而且提示还告诉他"重装一次"（重装一百次也没用）。
    //
    // 正确判据：**登记表里记的 engine**（`InstalledModel.engine`；老条目的默认值
    // 正好就是 `'llama.cpp'`，见 model_store.dart 的字段默认值）。
    final engineName = entry?.engine ?? i.engine;
    final runnable = _engineBundled(engineName);
    final note = <String>[
      _fmt(i.bytes + i.companions.fold<int>(0, (a, c) => a + c.bytes)),
      // 同上：内存要求只由依据行（fit.reason）说一次。
      if (i.companions.isNotEmpty && engineName != 'mnn')
        context.tr('含视觉编码器（mmproj）'),
      // 只报"已经校验过"这一种：没回填 sha256 时挂一整句像故障提示，
      // 用户会以为自己的文件有问题（这一点页面底部已统一说明）。
      // 来源（ModelScope/…) 也从这一行去掉 —— 一行塞五六段是"乱"的主因之一。
      if (i.sha256?.isNotEmpty ?? false) context.tr('已校验 sha256'),
      if (!okFile) context.tr('文件已丢失'),
      // 跑不了就**必须说清为什么**：以前只把「启动」按钮藏起来，一个字都不解释，
      // 用户看到的就是"这个模型点了没反应/起不来"（真机反馈原话）。
      if (!runnable && okFile) _engineWhy(engineName),
    ].join('　');

    final fit = entry != null ? _fitOf(entry) : null;
    // 注：这里原来还有"出图引擎"（stable-diffusion.cpp）的分支。它已随
    // 端侧出图能力一起删除（2026-10-11），现在只剩文本/视觉模型这一种引擎。
    final busy = _serverBusy;
    final isRunning = running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _row(
          // ⚠️ **三重兜底**（用户真机反馈「下载好后看不到大模型名字」的根因）：
          // 老版本下载时会把**空名字**写进登记表（那时 fromEntry 还没有 name 字段），
          // 而 `fromJson` 里 `?? id` 这种兜底对**空字符串**不生效（'' 不是 null）——
          // 于是那一行只剩徽标/体积/按钮，名字整块消失。
          // 顺序：清单里的最新名字 → 登记表里的 → id。
          title: (entry?.name.trim().isNotEmpty ?? false)
              ? entry!.name
              : (i.name.trim().isNotEmpty
                  ? i.name
                  : (i.id.trim().isNotEmpty ? i.id : '（未命名模型）')),
          note: note,
          fit: fit,
          rowTint: isRunning ? DshColors.accent : null,
          // 用户口径：模型名放到「启动 / 测试」按钮**上方**（不再被按钮挤成省略号）。
          stackTitle: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isRunning)
                OutlinedButton(
                  onPressed:
                      busy ? null : _stopServer,
                  child: Text(context.tr('停止'),
                      style: const TextStyle(fontSize: 12)),
                )
              else if (runnable)
                OutlinedButton(
                  onPressed: (busy || !okFile)
                      ? null
                      : () => _startServer(i),
                  child: Text(context.tr('启动'),
                      style: const TextStyle(fontSize: 12)),
                ),
              // 「测试」是 tok/s 测速，只对能跑推理的引擎有意义。
              if (runnable && okFile) ...<Widget>[
                const SizedBox(width: 6),
                OutlinedButton(
                  onPressed: _testingId != null ? null : () => _runFitTest(i),
                  child: Text(
                      _testingId == i.id
                          ? context.tr('测试中…')
                          : context.tr('测试'),
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
              const SizedBox(width: 6),
              TextButton(
                onPressed: () => _delete(i),
                child: Text(context.tr('删除'),
                    style: TextStyle(color: DshColors.textDim, fontSize: 12)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 一行模型。观感与 [DshTileRow] 一致（同样的圆角/边距/层级），
  /// 只是右侧换成动作按钮、字号只用 13/11 两档。
  Widget _row({
    required String title,
    required String note,
    Widget? trailing,
    Color? noteTint,
    Color? rowTint,
    ModelFitResult? fit,
    // 用户口径（2026-10-08）：「**在启动和测试的两个按钮的上方写上模型的名字**」。
    //
    // 打开后标题**独占一行**、按钮整排落到它下方。旧版标题与按钮挤在同一行，且
    // `maxLines: 1` + ellipsis —— 手机上名字会被截成「Qwen3-0.6B…」甚至整块看不见
    // （用户真机就反馈过「下载好后看不到大模型名字」）。
    bool stackTitle = false,
  }) {
    final titleRow = Row(
      children: <Widget>[
        Flexible(
          child: Text(title,
              maxLines: stackTitle ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: DshColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ),
        if (fit != null) ...<Widget>[
          const SizedBox(width: 6),
          _fitBadge(fit),
        ],
      ],
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        titleRow,
        // 提示框的**依据**：三档的边界是我们定的，就得把理由写在旁边。
        if (fit != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(fit.reason,
                style: TextStyle(
                    color: fit.fit == ModelFit.unsupported
                        ? DshColors.err
                        : DshColors.textFaint,
                    fontSize: 10.5,
                    height: 1.45)),
          ),
        const SizedBox(height: 2),
        Text(note,
            style: TextStyle(
                color: noteTint ?? DshColors.textFaint,
                fontSize: 11,
                height: 1.45)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: DshColors.surfaceHigh,
          borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
          border: Border.all(color: rowTint ?? DshColors.line, width: 1),
        ),
        // stackTitle：**名字在上、按钮在下**；否则维持旧的一行两栏。
        child: stackTitle
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  body,
                  if (trailing != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: trailing),
                  ],
                ],
              )
            : Row(
                children: <Widget>[
                  Expanded(child: body),
                  if (trailing != null) ...<Widget>[
                    const SizedBox(width: 8),
                    trailing,
                  ],
                ],
              ),
      ),
    );
  }
}

/// 页面上的模型分组。
///
/// ⚠️ **当前只展示 `text` 与 `multimodal` 两组**（用户 2026-10-08 口径：
/// 「取消图形和视频这两个板块。保留文本和多模态，集中火力公关文本和多模态的使用」）。
///
/// `image` / `video` 两个枚举值**保留**（清单里那两条模型的 kind 仍然映射到它们，
/// 数据层与实现都已删除），所以这里不再需要过滤 ——
/// 要恢复端侧出图的话见 `build.gradle.kts` 里那段说明（三段都要做）。
///
/// 为什么把「多模态」单列（用户 2026-10-06 定）：它是"能看图但**用来对话**"的一类，
/// 引擎与用途都和纯文本不同（Gemma 4 要 litert-lm + 现场编译，SmolVLM 要 mmproj 视觉编码器）。
/// 混在「文本」里会让人以为"文本模型也缺引擎"——实测就这么误会过。
enum _ModelGroup {
  text,
  multimodal,
  image,
  video;

  String get label => switch (this) {
        _ModelGroup.text => tr('文本'),
        _ModelGroup.multimodal => tr('多模态'),
        _ModelGroup.image => tr('图形'),
        _ModelGroup.video => tr('视频'),
      };

  /// 清单里的 `kind` → 分组。
  ///
  /// `vision`（能看懂图的多模态模型，如 Gemma 4）归**文本**：它干的是对话与理解、
  /// 不生成图片；端侧出图（stable-diffusion）已于 2026-10-11 删除。
  ///
  /// ⚠️ 写成**枚举自带的静态方法**，而不是 extension 上的静态成员：
  /// 后者的调用形态是 `扩展名.of(...)`，写 `_ModelGroup.of(...)` 会直接编译不过。
  static _ModelGroup of(String kind) => switch (kind) {
        'vision' => _ModelGroup.multimodal,
        'image' => _ModelGroup.image,
        'video' => _ModelGroup.video,
        _ => _ModelGroup.text,
      };
}

/// 一个正在进行的下载：它自己的取消令牌与最新进度。
///
/// 为什么不用"全局一个进度"：用户要求**同时下载**，每个模型要显示各自的
/// 速率与进度 —— 单一字段做不到（会互相覆盖，界面只显示最后一个）。
class _ActiveDownload {
  _ActiveDownload(this.cancel);

  final DownloadCancelToken cancel;
  ModelDownloadProgress? progress;
}
