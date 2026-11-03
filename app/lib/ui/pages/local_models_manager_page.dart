import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/local_model_server.dart';
import '../../local/model_downloader.dart';
import '../../local/model_fit.dart';
import '../../local/model_manifest.dart';
import '../../local/model_store.dart';
import '../../state/app_settings.dart';
import '../theme/dsh_tokens.dart';

/// 「本地大模型」—— **只管两件事：把模型下下来、把它跑起来。**
///
/// ## 为什么重做（2026-11-03）
///
/// 旧版是 `local_model_home_page`（一大段"这是什么/它擅长什么/代价是什么"）
/// + `ondevice_models_page`（1667 行的复合页，还带测速、知识库、独立聊天）。
/// 那套设计的**前提**是「本地模型上下文小，没法在正常会话里用，只能单独开个
/// 聊天窗口」。用户换 MNN 后把这个前提推翻了：
///
/// > 「mnn引擎提供的就是个大模型的api端点」
/// > 「我的正常会话可以加载本地大模型！而不是单独用一个聊天窗口」
/// > 「有一个本地大模型的功能块！只提供下载运行和调用」
///
/// 所以这一页**只做资产管理**：
///   * 下载 / 删除模型
///   * 启动 / 停止那个本地端点
///
/// **出去聊天在会话的模型选择器里选「本地大模型」**——那才是使用入口，
/// 不在这里。这样它和云端厂家就是同一种东西了。
///
/// ## 为什么不复用旧的 ondevice_models_page
///
/// 那页有 17 个状态字段和一堆绑定在其上的交互（测速缓存、崩溃降级提示、
/// 知识库联动、独立对话跳转）。按新定位重写一版更短、更直，比在里面
/// 删改出五六百行"看起来像新页"的补丁更可控。
class LocalModelsManagerPage extends StatefulWidget {
  const LocalModelsManagerPage({
    super.key,
    required this.runtime,
    required this.settings,
    required this.onModelChanged,
  });

  final DshRuntime runtime;
  final AppSettings settings;

  /// 模型/服务变了要通知壳层（overlay 与首页状态都跟着变）。
  final Future<void> Function() onModelChanged;

  @override
  State<LocalModelsManagerPage> createState() => _LocalModelsManagerPageState();
}

class _LocalModelsManagerPageState extends State<LocalModelsManagerPage> {
  /// 清单（可下载的）与已装登记。
  List<OnDeviceModel> _manifest = const <OnDeviceModel>[];
  Map<String, InstalledModel> _installed = const <String, InstalledModel>{};

  /// 正在下载的模型 id → 进度（0..1）。不在表里 = 没在下载。
  final Map<String, double> _downloading = <String, double>{};

  /// 正在起/停的模型 id（避免连点）。
  String? _busy;

  /// 上一次操作的错误（人话）。
  String? _error;

  bool _loading = true;

  /// 这台手机的**实测速度**（按模型 id）——落盘在 `<models>/bench.json`。
  /// 换手机/换模型都要重测，所以它是"本机档案"，不是清单的一部分。
  Map<String, BenchRecord> _bench = const <String, BenchRecord>{};

  /// 正在测速的模型 id。
  String? _benching;

  /// 模型目录：`<nodeHome>/models`（与旧页一致，别另起一套）。
  String get _modelsDir {
    final home = widget.runtime.nodeHome;
    return home.isEmpty ? 'models' : '$home/models';
  }

  LocalModelStore get _store => LocalModelStore(dir: _modelsDir);

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final raw =
          await rootBundle.loadString('assets/models/model_manifest.json');
      final manifest = OnDeviceManifest.parse(raw);
      final installed = await _store.list(refresh: true);
      final bench = await BenchStore(dir: _modelsDir).load(refresh: true);
      if (!mounted) return;
      setState(() {
        _manifest = manifest.models;
        _installed = installed;
        _bench = bench;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // ── 下载 ─────────────────────────────────────────────────────────────────

  Future<void> _download(OnDeviceModel m) async {
    if (_downloading.containsKey(m.id)) return;
    setState(() {
      _downloading[m.id] = 0;
      _error = null;
    });
    try {
      final r = await ModelDownloader(
        dir: _store.dir,
        client: HttpClient(),
      ).download(
        m,
        requireHash: false, // 清单顶层开关；这里跟它保持一致（见 manifest.note）
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            // 带伴生文件时 total 已是总和（下载器算好的）。
            _downloading[m.id] =
                p.total <= 0 ? 0 : (p.received / p.total).clamp(0.0, 1.0);
          });
        },
      );
      // 下完登记（registry 才会把它算作"已装"）。
      await _store.register(InstalledModel(
        installedAt: DateTime.now(),
        id: m.id,
        family: m.family,
        name: m.name,
        fileName: m.fileName,
        bytes: m.bytes,
        kind: m.kind,
        engine: m.engine,
        format: m.format,
        quant: m.quant,
        license: m.license,
        sourceLabel: r.sourceLabel,
        sha256: m.sha256,
        companions: m.companions
            .map((c) => InstalledCompanion(
                  fileName: c.fileName,
                  bytes: c.bytes,
                ))
            .toList(),
      ));
      await _reload();
      await widget.onModelChanged();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _downloading.remove(m.id));
    }
  }

  // ── 删除 ─────────────────────────────────────────────────────────────────

  Future<void> _delete(OnDeviceModel m) async {
    // 正在跑的那个先停掉，否则文件被占用 / 停完 overlay 还指着死端口。
    if (LocalModelServer.instance.spec?.modelId == m.id) {
      await LocalModelServer.instance.stop();
      await widget.onModelChanged();
    }
    await _store.remove(m.id);
    await _reload();
    await widget.onModelChanged();
  }

  // ── 启动 / 停止 ──────────────────────────────────────────────────────────

  Future<void> _start(OnDeviceModel m) async {
    setState(() {
      _busy = m.id;
      _error = null;
    });
    try {
      final path = _store.pathForEntry(m);
      final port = await LocalModelServer.instance.ensureRunning(
        runtime: widget.runtime,
        model: m,
        modelPath: path,
      );
      if (port == null) {
        final why = LocalModelServer.instance.lastError ?? '未知原因';
        if (mounted) setState(() => _error = tr('启动失败：{0}', [why]));
      } else {
        await widget.onModelChanged();
      }
    } finally {
      if (mounted) setState(() => _busy = null);
      await _reload();
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = 'stop');
    try {
      await LocalModelServer.instance.stop();
      await widget.onModelChanged();
    } finally {
      if (mounted) setState(() => _busy = null);
      await _reload();
    }
  }

  // ── 测速 ─────────────────────────────────────────────────────────────────

  /// 对**正在运行**的模型跑一次真推理，量出这台手机的 tok/s 并落盘。
  ///
  /// 为什么值得单独做：用户问的是「这台手机跑哪个模型能到多少 token」——
  /// 光看参数量估不出来（内存带宽、CPU 调度、量化格式都影响），只有真跑一次。
  ///
  /// 数字取自引擎自己报的 `timings`（MNN 的 LlmContext 直接给 prefill/decode 耗时），
  /// 不是我在外面掐表 —— 掐表会把首字延迟算进吞吐里，偏小。
  Future<void> _runBench(String modelId) async {
    if (_benching != null) return;
    setState(() {
      _benching = modelId;
      _error = null;
    });
    try {
      final r = await LocalModelServer.instance.measure();
      if (r == null) {
        if (mounted) {
          setState(() => _error =
              tr('测速失败：引擎没返回性能数据（模型可能刚崩，或这版引擎不支持）'));
        }
        return;
      }
      await BenchStore(dir: _modelsDir).save(BenchRecord(
        modelId: modelId,
        tokensPerSecond: r.tokensPerSecond,
        promptMs: r.promptMs,
        at: DateTime.now(),
      ));
      if (mounted) {
        setState(() {
          _bench = <String, BenchRecord>{
            ..._bench,
            modelId: BenchRecord(
              modelId: modelId,
              tokensPerSecond: r.tokensPerSecond,
              promptMs: r.promptMs,
              at: DateTime.now(),
            ),
          };
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _benching = null);
    }
  }

  // ── 视图 ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final running = LocalModelServer.instance.spec;
    final runningId = running?.modelId;

    // 已装的 = **登记表里有 且 文件真的还在**。
    //
    // ⚠️ 只查登记表是不够的（2026-11-03 真机踩到）：`pm install -r` 覆盖安装
    // 会**保留数据和文件**，于是登记表里留着一份记录、而模型文件早就没了。
    // 结果界面把它列进「已下载」，用户点「启动」必然失败，还看不出为什么。
    // `fileOk()` 会连主文件长度和伴生文件一起验（旧页也是这么判的）。
    final installedEntries = <(OnDeviceModel, InstalledModel)>[];
    final installedIds = <String>{};
    for (final m in _manifest) {
      final i = _installed[m.id];
      if (i == null) continue;
      if (_store.fileOk(i)) {
        installedEntries.add((m, i));
        installedIds.add(m.id);
      }
      // 文件不全的不算已装 —— 落到下面「可下载」里，用户重新下一次就好。
    }

    // 可下载的 = 文件不完整的（含"登记表有记录但文件丢了"）。
    final available = <OnDeviceModel>[
      for (final m in _manifest)
        if (!installedIds.contains(m.id)) m,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('本地大模型')),
        actions: <Widget>[
          IconButton(
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh),
            tooltip: context.tr('刷新'),
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: DshColors.accent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: <Widget>[
                _statusCard(running),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 10),
                  _errorCard(_error!),
                ],
                const SizedBox(height: 18),
                _sectionTitle(context.tr('已下载'), installedEntries.length),
                const SizedBox(height: 8),
                if (installedEntries.isEmpty)
                  _emptyHint(context.tr('还没有下载任何模型。下面挑一个点「下载」。'))
                else
                  for (final (m, i) in installedEntries)
                    _modelCard(
                      m,
                      installed: i,
                      isRunning: runningId == m.id,
                    ),
                const SizedBox(height: 20),
                _sectionTitle(context.tr('可下载'), available.length),
                const SizedBox(height: 8),
                for (final m in available) _modelCard(m, installed: null),
              ],
            ),
    );
  }

  /// 顶部状态条：服务在不在跑、跑的是哪个、停在哪个端口。
  Widget _statusCard(LocalModelSpec? running) {
    final on = running != null;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
        border: Border.all(
          color: on ? DshColors.ok.withValues(alpha: 0.55) : DshColors.line,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            on ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: on ? DshColors.ok : DshColors.textFaint,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _busy != null && _busy != 'stop'
                      // 加载 1-2GB 的模型要**几十秒**（真机实测 1.5B 约 45 秒），
                      // 这期间不能只转圈不说 —— 用户会以为卡死了（真机反馈）。
                      ? context.tr('正在加载模型…（大模型可能要 30-60 秒）')
                      : on
                          ? context.tr('运行中：{0}', [running.displayName])
                          : context.tr('本地服务没在运行'),
                  style: TextStyle(
                    color: DshColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  on
                      ? context.tr('端点 127.0.0.1:{0} —— 去会话的模型选择器里选它就能聊',
                          ['${running.port}'])
                      : context.tr('启动任意一个已下载的模型，它就会出现在会话的模型选择器里'),
                  style: TextStyle(
                      color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
                ),
              ],
            ),
          ),
          if (on)
            TextButton(
              onPressed: _busy == 'stop' ? null : _stop,
              child: Text(context.tr('停止')),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, int count) => Row(
        children: <Widget>[
          Text(text,
              style: TextStyle(
                  color: DshColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Text('($count)',
              style: TextStyle(color: DshColors.textFaint, fontSize: 11.5)),
        ],
      );

  Widget _emptyHint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(text,
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 11.5, height: 1.5)),
      );

  Widget _errorCard(String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: DshColors.err.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.err.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.error_outline, size: 16, color: DshColors.err),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: DshColors.err, fontSize: 11.5, height: 1.45)),
            ),
          ],
        ),
      );

  /// 一个模型一张卡 —— 左边名字/规格，右边动作按钮。
  Widget _modelCard(
    OnDeviceModel m, {
    required InstalledModel? installed,
    bool isRunning = false,
  }) {
    final dl = _downloading[m.id];
    final busy = _busy == m.id;
    final total = m.bytes + m.companions.fold<int>(0, (a, c) => a + c.bytes);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
        border: Border.all(
          color: isRunning ? DshColors.ok.withValues(alpha: 0.55) : DshColors.line,
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        m.name,
                        style: TextStyle(
                            color: DshColors.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isRunning) ...<Widget>[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: DshColors.ok.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(DshMetrics.radius(5)),
                        ),
                        child: Text(context.tr('运行中'),
                            style: TextStyle(
                                color: DshColors.ok, fontSize: 9.5)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${_fmtBytes(total)}　${context.tr('需要内存 ≥ {0} GB', ['${m.minRamGb}'])}',
                  style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
                ),
                // 这台手机实测跑出来的速度（没测过就不显示，别拿估算冒充实测）
                if (_bench[m.id] != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Row(
                    children: <Widget>[
                      Icon(Icons.speed,
                          size: 12, color: DshColors.accent),
                      const SizedBox(width: 3),
                      Text(
                        context.tr('本机实测 {0} tok/s', [
                          _bench[m.id]!.tokensPerSecond.toStringAsFixed(1)
                        ]),
                        style: TextStyle(
                            color: DshColors.accent, fontSize: 10.5),
                      ),
                    ],
                  ),
                ],
                if (dl != null) ...<Widget>[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(DshMetrics.radius(3)),
                    child: LinearProgressIndicator(
                      value: dl,
                      minHeight: 4,
                      backgroundColor: DshColors.line,
                      valueColor: AlwaysStoppedAnimation<Color>(DshColors.accent),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    context.tr('下载中 {0}%', ['${(dl * 100).round()}']),
                    style: TextStyle(color: DshColors.accent, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _actionButton(m, installed: installed, dl: dl, busy: busy, isRunning: isRunning),
        ],
      ),
    );
  }

  Widget _actionButton(
    OnDeviceModel m, {
    required InstalledModel? installed,
    required double? dl,
    required bool busy,
    required bool isRunning,
  }) {
    if (dl != null) {
      return SizedBox(
        width: 64,
        child: Text(context.tr('下载中'),
            textAlign: TextAlign.center,
            style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
      );
    }
    if (installed == null) {
      return FilledButton.tonal(
        onPressed: () => _download(m),
        child: Text(context.tr('下载')),
      );
    }
    // 已装：
    //   * 没在跑 → 「启动」+ 删除图标
    //   * 在跑   → 「测速」+「删除」（测速要求服务活着，所以只在这里给）
    if (isRunning) {
      final benchingThis = _benching == m.id;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FilledButton.tonal(
            onPressed: _benching != null ? null : () => _runBench(m.id),
            child: benchingThis
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.tr('测速')),
          ),
          IconButton(
            onPressed: busy ? null : () => _delete(m),
            icon: Icon(Icons.delete_outline,
                size: 19, color: DshColors.textFaint),
            tooltip: context.tr('删除'),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FilledButton.tonal(
          onPressed: busy ? null : () => _start(m),
          child: busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.tr('启动')),
        ),
        IconButton(
          onPressed: busy ? null : () => _delete(m),
          icon:
              Icon(Icons.delete_outline, size: 19, color: DshColors.textFaint),
          tooltip: context.tr('删除'),
        ),
      ],
    );
  }

  static String _fmtBytes(int b) {
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    return '${(b / (1024 * 1024)).round()} MB';
  }
}
