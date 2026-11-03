/// 「本地对话」——跟本机模型**简单聊天**的地方（用户 2026-10-09 定的口径）。
///
/// 与「会话」的区别（这是本页存在的全部理由）：
///
/// | | 会话（DSH Agent） | 本页（简单对话） |
/// |---|---|---|
/// | 系统提示 | 约 3k~7k tokens（工具 + 技能 + 运行时） | **不带** |
/// | 工具协议 | 有（bash/fs/web/skill…） | **没有** |
/// | 走谁 | DSH Agent 循环（ACP） | **直连引擎**的 OpenAI 兼容端点 |
/// | 对话记录 | DSH 会话文件 | `<dshHome>/local_chat.json` |
///
/// 为什么不把本地模型塞进会话：1–2B 模型吃不下那套协议，实测会吐多语种乱码、
/// 还把工具调用当正文写出来（真机日志逐字可查）。所以它**只做简单对话**。
///
/// 另：本页会把引擎的报错**原样显示**（例如模板不兼容的原文），
/// 这正是判断"某种模型构建能不能用"的第一手依据。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/kb_index.dart';
import '../../local/kb_store.dart';
import '../../local/model_fit.dart';
import '../../local/model_manifest.dart';
import '../../local/model_store.dart';
import '../../local/diagnostics_log.dart';
import '../../local/local_chat.dart';
import '../../local/local_model_server.dart';
import 'kb_page.dart';
import '../../state/app_settings.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';

class LocalChatPage extends StatefulWidget {
  const LocalChatPage({
    super.key,
    required this.dshHome,
    required this.settings,
    required this.runtime,
    this.onModelChanged,
  });

  /// DSH_HOME（`.../files/dshhome`）—— 对话记录落在那儿。
  final String dshHome;

  /// 联网搜索用哪家存在这儿；Key 在系统安全区（`ProviderKeys`）。
  final AppSettings settings;

  /// 启动/切换本地模型要用它（引擎目录、node 路径都在里面）。
  final DshRuntime runtime;

  /// 切完模型后通知外层重写 overlay（本地厂家指向的模型变了）。
  final Future<void> Function()? onModelChanged;

  @override
  State<LocalChatPage> createState() => _LocalChatPageState();
}

class _LocalChatPageState extends State<LocalChatPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<LocalChatMessage> _messages = <LocalChatMessage>[];

  bool _sending = false;
  bool _loaded = false;
  String _streaming = '';
  String? _error;

  /// 📚 知识库检索开关（默认开：用户装了知识库就是为了让它查）。
  bool _kbOn = true;

  /// 已建好索引、可以被检索的知识库（没索引的查不了，不该让用户白等）。
  List<KbInstalled> _kbReady = const <KbInstalled>[];

  /// 哪些**已建索引**的包的索引是**旧切法**建的（用户 2026-10-12 排查时发现）。
  ///
  /// 为什么必须在这一页说：知识库页会把旧索引标成「检索会不准」，但用户碰得
  /// 最多的是**这一页**，而这一页原来一个字都不说。
  ///
  /// 更要紧的一点：**旧切法的索引会把 0.66 新加的相关度门槛废掉** —— 旧切法把
  /// 好几篇互不相关的文章揉进同一块（实测 12 篇 → 2 块，一块里 9 篇），于是
  /// 那个块跟**任何**问句都能对上 ≥2 个词，正好过门槛。这不能怪门槛（它没权力
  /// 判断一块里混了几篇），是索引本身没重建 —— 所以必须直说"去重建"。
  List<String> _kbLegacy = const <String>[];

  /// **已下载的本地模型**（可以直接在页内切换，不用回上一页）。
  List<InstalledModel> _models = const <InstalledModel>[];

  /// 盘上有、但**这一版跑不了**的模型（例如旧版下载的 llama.cpp `.gguf`）。
  ///
  /// 不放进切换列表（放了就必然切换失败），但也不能装作它们不存在 ——
  /// 要在面板里如实说一句"有 N 个跑不了、为什么、去哪删"。
  List<InstalledModel> _hiddenModels = const <InstalledModel>[];

  /// 正在切换模型（切一次要停旧启新，几秒到几十秒）。
  bool _switching = false;

  /// 正在测速（切完模型会自动测一次，让用户当场看到这台手机上的真实速度）。
  bool _benching = false;

  /// 各模型的**实测速度**（与「本地大模型」页共用同一份 bench.json）。
  ///
  /// 两个用途：① 切换前的列表里直接显示"这个模型实测多少 tok/s"，好比较；
  /// ② 切完自动测速后把新结果也写回去（两页数据一致）。
  Map<String, BenchRecord> _bench = const <String, BenchRecord>{};

  /// 还没发出去的图片（文件绝对路径）。发送时随那一条 user 消息一起发。
  ///
  /// 为什么不让它直接进 `_messages`：发出去之前用户应该能反悔（点掉某张）。
  final List<String> _pending = <String>[];

  LocalChatStore get _store => LocalChatStore(dshHome: widget.dshHome);
  LocalModelServer get _server => LocalModelServer.instance;

  @override
  void initState() {
    super.initState();
    // 输入框有字才能点发送 —— 与聊天页同一套习惯。
    _input.addListener(() {
      if (mounted) setState(() {});
    });
    _restore();
    _loadModels();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 读一遍"已下载的本地模型"（清单 + 本地登记表，以登记表为准）。
  Future<void> _loadModels() async {
    try {
      // 只看**本地登记表**（已下载/已导入的都在这），并确认文件真的还在 ——
      // 不用读清单：切换只关心"盘上有哪些能跑的模型"。
      final store = LocalModelStore(
          dir: widget.dshHome.isEmpty ? 'models' : '${widget.dshHome}/models');
      final installed = await store.list(refresh: true);
      final list = <InstalledModel>[];
      final hidden = <InstalledModel>[];
      for (final m in installed.values) {
        if (m.fileName.isEmpty) continue;
        if (!File(store.pathFor(m.fileName)).existsSync()) continue;
        // ⚠️ **能不能跑由"包里有没有它要的引擎"决定，不是"文件在不在"**
        //    （用户 2026-10-11 真机日志的根因）：盘上留着一个旧版下载的 `.gguf`
        //    （llama.cpp），文件好端端在、登记表里也有，于是它会出现在这个切换列表里；
        //    一选就必然失败（引擎 0.47 起就不随包了），用户看到的却是
        //    「本地服务没起来」。
        if (!_runnable(m)) {
          hidden.add(m);
          continue;
        }
        list.add(m);
      }
      list.sort((a, b) => a.name.compareTo(b.name));
      hidden.sort((a, b) => a.name.compareTo(b.name));
      final bench = await BenchStore(dir: store.dir).load(refresh: true);
      if (!mounted) return;
      setState(() {
        _models = list;
        _hiddenModels = hidden;
        _bench = bench;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _models = const <InstalledModel>[];
          _hiddenModels = const <InstalledModel>[];
        });
      }
    }
  }

  /// 这一版能不能跑它 —— 判据是**包里有没有它要的引擎**（不是文件在不在）。
  ///
  /// 与「本地大模型」页的 `_engineBundled` 同一套判据（那边看的是清单里的 engine，
  /// 这边看的是登记表里的 engine；老条目的默认值正好是 `'llama.cpp'`）。
  bool _runnable(InstalledModel m) {
    final dir = widget.runtime.nativeLibDir;
    if (dir.isEmpty) return false;
    // 只认 MNN（2026-11-03）。
    return switch (m.engine) {
      'mnn' => File('$dir/libmnn_mini_server.so').existsSync(),
      _ => false,
    };
  }

  /// 切到另一个**已下载**的本地模型。
  ///
  /// 为什么值得做在页内：以前换模型要回上一页 → 停止 → 选模型 → 启动 → 再回来，
  /// 而"换个小模型试试"恰恰是最常见的手滑操作。
  ///
  /// 历史**不清空**：下一轮会把完整历史重发（桥那边发现模型变了会重建会话），
  /// 所以新模型能看到之前的对话 —— 这点界面上要如实告诉用户。
  Future<void> _switchTo(InstalledModel m) async {
    if (_switching) return;
    setState(() {
      _switching = true;
      _error = null;
    });
    try {
      final store = LocalModelStore(
          dir: widget.dshHome.isEmpty ? 'models' : '${widget.dshHome}/models');
      final backend = LocalModelBackend.values.firstWhere(
        (b) => b.name == widget.settings.localBackendId,
        orElse: () => LocalModelBackend.cpu,
      );
      final port = await LocalModelServer.instance.ensureRunning(
        runtime: widget.runtime,
        model: OnDeviceModel(
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
        contextSize: widget.settings.localContextSize,
        backend: backend,
      );
      if (!mounted) return;
      if (port == null) {
        // 带上**真正的原因**（`lastError`）—— 用户 2026-10-11 报的就是"只说没起来"。
        // 例如旧版 .gguf 会给出"这个模型要的是 llama.cpp 引擎，而它 0.47 起就不随包了"。
        final why = LocalModelServer.instance.lastError;
        setState(() => _error = (why == null || why.trim().isEmpty)
            ? context.tr('切换失败：引擎没起来（详见运行日志）')
            : context.tr('切换失败：{0}', [why]));
      } else {
        await widget.onModelChanged?.call();
        if (mounted) setState(() {});
        // ── 切完**自动测一次速**（用户 2026-10-09 要求：切换时能看到测速）──
        //
        // 为什么值得自动做：不同模型在这台手机上的速度差好几倍（实测
        // Qwen3 0.6B GPU 22.4 / CPU 11.0，Gemma 4 E2B GPU 31.9），而这个数字
        // **只有本机实测**才有 —— 不然用户只能靠体感猜。
        await _benchNow(showToast: false);
        if (!mounted) return;
        final rec = _bench[m.id];
        _toast(
          rec == null ? '已切换：{0}' : '已切换：{0} · 实测 {1} tok/s',
          rec == null ? [m.name] : [m.name, rec.tokensPerSecond.toStringAsFixed(1)],
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = context.tr('切换失败：{0}', ['$e']));
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 给**当前正在跑的**模型测一次速，并把结果写回共用的记录（两页一致）。
  ///
  /// [showToast] = 手动点测速时为 true（要说一声"正在测"），切换后自动测时为 false
  /// （切换本身已经有一条提示，不该连弹两条）。
  Future<void> _benchNow({bool showToast = false}) async {
    if (_benching || _sending) return;
    final spec = _server.spec;
    if (spec == null || !_server.running) return;
    setState(() => _benching = true);
    try {
      final r = await LocalModelServer.instance.measure();
      if (r == null) {
        if (showToast && mounted) _toast('测速失败（详见运行日志）');
        return;
      }
      final store = LocalModelStore(
          dir: widget.dshHome.isEmpty ? 'models' : '${widget.dshHome}/models');
      await BenchStore(dir: store.dir).save(BenchRecord(
        modelId: spec.modelId,
        tokensPerSecond: r.tokensPerSecond,
        promptMs: r.promptMs,
        at: DateTime.now(),
      ));
      final bench = await BenchStore(dir: store.dir).load(refresh: true);
      if (!mounted) return;
      setState(() => _bench = bench);
    } catch (e) {
      if (mounted) setState(() => _error = context.tr('测速失败：{0}', ['$e']));
    } finally {
      if (mounted) setState(() => _benching = false);
    }
  }

  /// 诊断报告里那一段摘要：前 24 个字，空白压成单空格。
///
/// 为什么需要：光看「注入 2 段 / 1226 字」**没法判断查到的相不相关**，
/// 而"答得乱七八糟"的争议点恰恰全在这里。有了它，报告自己就能回答这个问题。
String _kbSnippet(String text) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= 24 ? t : '${t.substring(0, 24)}…';
}

/// 弹一个"选哪个模型"的底部面板。
  Future<void> _pickModel() async {
    if (_switching) return;
    if (_models.isEmpty) {
      await _loadModels();
      if (!mounted) return;
      if (_models.isEmpty) {
        // 盘上确实有模型、只是这一版跑不了 → 不能只说"还没有已下载的模型"
        //（用户会去下载页找，然后发现"我明明有一个"）。
        if (_hiddenModels.isNotEmpty) {
          final names = _hiddenModels.take(3).map((m) => m.name).join('、');
          _toastMsg(context.tr(
              '盘上有 {0} 个模型本版跑不了：{1}。它们要 llama.cpp 引擎，'
              '而这个引擎 0.47 起就不随包了 —— 回「本地大模型」页可以删掉，'
              '或下载 Gemma 4 这类 .litertlm 模型',
              <Object?>['${_hiddenModels.length}', names]));
        } else {
          _toast('还没有已下载的模型：回「本地大模型」页下载一个');
        }
        return;
      }
    }
    final current = _server.spec?.modelId;
    final picked = await showModalBottomSheet<InstalledModel>(
      context: context,
      backgroundColor: DshColors.surfaceStrong,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(context.tr('切换本地模型'),
                  style: TextStyle(
                      color: DshColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
            for (final m in _models)
              ListTile(
                dense: true,
                leading: Icon(
                  m.id == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: m.id == current
                      ? DshColors.accent
                      : DshColors.textFaint,
                ),
                title: Text(m.name,
                    style: TextStyle(color: DshColors.text, fontSize: 13)),
                subtitle: Text(
                  <String>[
                    m.kind == 'vision'
                        ? context.tr('多模态（能看图）')
                        : context.tr('文本'),
                    _fmtSize(m.bytes),
                    // 有实测记录就直接显示 —— 用户切换前就能比较快慢。
                    if (_bench[m.id] != null)
                      context.tr('实测 {0} tok/s', [
                        _bench[m.id]!.tokensPerSecond.toStringAsFixed(1),
                      ])
                    else
                      context.tr('还没测过'),
                    if (m.id == current) context.tr('正在跑'),
                  ].join(' · '),
                  style: TextStyle(
                      color: DshColors.textFaint, fontSize: 10.5),
                ),
                onTap: () => Navigator.of(ctx).pop(m),
              ),
            const SizedBox(height: 8),
            // 盘上有跑不了的模型时，如实说一句 —— 否则用户会觉得"我的模型不见了"。
            if (_hiddenModels.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  context.tr('有 {0} 个模型本版跑不了，已从上面隐藏：{1}。'
                      '它们要 llama.cpp 引擎，而这个引擎 0.47 起就不随包了 —— '
                      '可在「本地大模型」页删掉。', [
                    '${_hiddenModels.length}',
                    _hiddenModels.take(3).map((m) => m.name).join('、'),
                  ]),
                  style: TextStyle(
                      color: DshColors.accent3, fontSize: 10.5, height: 1.4),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                context.tr('切换会重启本地服务（几秒到几十秒）。'
                    '对话记录不清空 —— 新模型能看到之前的对话。'),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) await _switchTo(picked);
  }

  static String _fmtSize(int bytes) => bytes >= 1073741824
      ? '${(bytes / 1073741824).toStringAsFixed(2)} GB'
      : '${(bytes / 1048576).toStringAsFixed(0)} MB';

  /// 找出**已建索引**的知识库（只有它们能被检索）。
  Future<void> _loadKbReady() async {
    try {
      final store = KbStore(dshHome: widget.dshHome);
      final installed = await store.list();
      final ready = <KbInstalled>[];
      final metas = <String, KbIndexMeta?>{};
      for (final kb in installed) {
        if (!kb.enabled) continue; // 用户关掉的包不参与问答
        final meta = await readIndexMeta(store.dirOf(kb.id));
        if (meta == null) continue; // 没建索引的包不能检索
        ready.add(kb);
        metas[kb.name] = meta;
      }
      // 判定抽在 `kb_index.dart` 里 —— 那样这条提示的触发条件能被单测钉住。
      final legacy = legacyChunkPackNames(metas);
      if (!mounted) return;
      setState(() {
        _kbReady = ready;
        _kbLegacy = legacy;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _kbReady = const <KbInstalled>[];
          _kbLegacy = const <String>[];
        });
      }
    }
  }

  Future<void> _restore() async {
    final list = await _store.load();
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(list);
      _loaded = true;
    });
    _toBottom();
    await _loadKbReady();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// 拍一张 / 从相册选一张。kind：`photo`（拍照）/ `media`（相册）。
  ///
  /// 走的是 App 现成的原生通道（`DshHost.pickAttachment`，聊天附件一直用它），
  /// 拿到的是 App 私有目录里的**真实绝对路径**；用户取消返回 null。
  Future<void> _pick(String kind) async {
    // ⚠️ 取图会离开 App（相机/相册是系统页面），回来的路上 App 可能被系统重建。
    //    走之前落一个时间戳：重建后 AppShell 据此把这一页**重新推回来**
    //    （用户真机反馈：取完图回来会掉回首页）。
    //    顺手记日志 —— 万一还是跳页，日志能直接看出是哪一段之后发生的事。
    await widget.settings.setPickInFlight(true, from: 'localchat');
    DiagnosticsLog.add('[dsh-pick]', '打开取图：$kind（离开 App，回来后应回到本地对话页）');
    debugPrint('[dsh-pick] 打开取图：$kind');
    try {
      final path = await DshHost.pickAttachment(kind);
      DiagnosticsLog.add('[dsh-pick]',
          '取图返回：${path == null ? '取消/空' : path.split('/').last}');
      debugPrint('[dsh-pick] 取图返回：$path');
      if (path == null) return; // 用户取消 —— 不该弹任何提示
      final lower = path.toLowerCase();
      const exts = <String>[
        '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.heic'
      ];
      if (!exts.any(lower.endsWith)) {
        // 相册那条路允许选视频；引擎这边只吃图片 —— 如实说，别默默塞进去让它报错。
        _toast('只能发图片：视频和其它文件这条路还不支持');
        return;
      }
      // ⚠️ 这里是**取图路径上唯一没有 mounted 守卫的 setState**（审计 P0-10 附带项）。
      //
      // 为什么这里最危险：取图会离开 App 去相机/相册，**中途页面最可能被系统回收**
      // ——用户反馈的"照完相/选完图回到首页"高度怀疑就是这条：
      // 页面已经 dispose 了还 setState，Flutter 会抛
      // "setState() called after dispose()"，上层的推页/回退逻辑跟着乱掉。
      // 同函数其余提示都走带守卫的 `_toast`，只有这一句漏了。
      if (!mounted) return;
      setState(() => _pending.add(path));
    } catch (e) {
      _toast('取图失败：{0}', ['$e']);
    } finally {
      // 不管成功、取消还是出错，都要把标记清掉 —— 否则下次启动会平白多推一页。
      await widget.settings.setPickInFlight(false);
    }
  }

  /// 切换 📚。没有"已建索引"的知识库时如实说清楚要先去装+建索引。
  Future<void> _toggleKb() async {
    if (_kbReady.isEmpty) {
      // 有可能用户刚在知识库页装了包并建了索引 → 顺手重查一次再判断。
      await _loadKbReady();
      if (!mounted) return;
      if (_kbReady.isEmpty) {
        _toast('还没有可检索的知识库：去「本地大模型 → 知识库」装一包并建立索引');
        return;
      }
    }
    setState(() => _kbOn = !_kbOn);
  }

  /// 弹提示（只收 i18n key，避免在 await 之后用 context）。
  void _toast(String key, [List<String>? args]) {
    if (!mounted) return;
    final msg = args == null ? context.tr(key) : context.tr(key, args);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 直接弹一句**已经翻好的**话。
  ///
  /// 与 [_toast] 的区别：`_toast('中文')` 里的字面量**不在 `tr(...)` 调用里**，
  /// 所以 i18n 扫描器看不见它 → 表里没有这条 → 切英/日/韩时 `tr` 查不到，
  /// **原样吐中文**（不报错，静默地没翻）。
  /// 调用点写成 `_toastMsg(context.tr('…', args))`，字面量才算"被 tr() 包住"，
  /// 扫描器才会把它收进表。
  void _toastMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _clear() async {
    final msg = context.tr('对话已清空');
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _error = null;
      _streaming = '';
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 引擎报错 → 能给出下一步的，就翻成人话；认不出来就**原样显示**（不猜）。
  ///
  /// 依据是真机诊断报告（2026-10-09 16:32:35）：Gemma 3 1B 报
  /// `Prefill input length exceeds available state entries (remaining capacity: 176)`，
  /// 用户当时只看到一句 `HTTP 500 {…}` —— 既不知道发生了什么，也不知道该做什么，
  /// 只能来问我。而这条其实**用户自己能救**（新开会话 / 换上下文更大的模型）。
  String _localChatErrorText(String raw) {
    switch (classifyLocalChatError(raw)) {
      case LocalChatErrorKind.contextFull:
        final ctx = _server.spec?.contextSize;
        return context.tr(
            '这个模型的对话缓存装不下了：它的上下文上限是 {0} token，'
            '当前这段对话已经接近上限。请点右上角新开一个会话，'
            '或换一个上下文更大的模型。',
            <String>[ctx == null ? '（未知）' : '$ctx']);
      case LocalChatErrorKind.unknown:
        return raw;
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    // 只有图、没有字也该能发（发图问"这是什么"是常见用法）。
    if ((text.isEmpty && _pending.isEmpty) || _sending) return;
    final port = _server.port;
    if (port == null || !_server.running) {
      setState(() => _error =
          context.tr('本地模型服务没在运行：先回「本地大模型」页启动它，再回来聊。'));
      return;
    }
    // ⚠️ 所有跨 await 还要用的**文案**与**厂家**，在这里一次算好：
    //    await 之后再碰 context 会踩 lint，而且页面可能已被销毁。
    const msgKbFailedKey = '知识库检索失败（已忽略，继续问）：{0}';

    // ── 📚 知识库：先用本地索引查一轮（不联网、不花额度，所以排在联网前面）──
    //
    // 检索失败**不阻塞**：知识库查不到就直接问，不用让用户为一次本地查询卡住。
    var kbContext = '';
    var kbHits = 0;
    final kbSw = Stopwatch()..start();
    if (_kbOn && _kbReady.isNotEmpty) {
      try {
        final store = KbStore(dshHome: widget.dshHome);
        final merged = <KbChunkHit>[];
        // 每个包的**切法**与段数（`chunkMode`：2=按文档边界，1=旧切法）。
        // 报告里没有这两个字段时，「注入 2 段」既可能是"包里只有 2 段"、
        // 也可能是"检索只给了 2 段"，**分不出来** —— 用户 2026-10-12 那次
        // 我就是这么把"每包上限 2 段"读成了"包里只有 2 段"。
        final modes = <String>[];
        for (final kb in _kbReady) {
          final dir = store.dirOf(kb.id);
          final ret = await KbRetriever.open(dir);
          if (ret == null) continue;
          final meta = await readIndexMeta(dir);
          modes.add('${kb.name}=${meta?.chunkMode ?? '?'}切/${meta?.chunks ?? '?'}段');
          final hits = await ret.search(text, topK: 3);
          // ⚠️ **每包最多取 2 段**：否则一个几十万段的大包几乎会把前 3 名全占了，
          //    用户自己导入的小包（几百段）永远轮不上 —— 那就是"打架"的真实形态。
          merged.addAll(hits.take(2).map((h) => h.withSource(kb.name)));
        }
        merged.sort((a, b) => b.score.compareTo(a.score));
        final top = merged.length > 3 ? merged.sublist(0, 3) : merged;
        kbContext = formatKbContext(top);
        kbHits = top.length;
        // 每轮记一笔注入量。**这是本次事故里唯一的盲区** —— 诊断报告里既看不出
        // 这一轮有没有走知识库，也看不出注入了多少（界面那个「知识库 N 段」标记
        // 只存在内存里）。有了这行，下次再出 Status 9 就能直接对上账。
        if (top.isEmpty) {
          // 门槛没过 → 不注入。这一行**必须**写：否则"没查到"和"没走这条路"
          // 在报告里长得一模一样，又变回盲区。
          debugPrint('[dsh-kb] 没有够相关的资料（相关度门槛没过）→ 不注入，'
              '模型按自己知道的答'
              '（${_kbReady.length} 包参与，切法 ${modes.join(' ')}，'
              '耗时 ${kbSw.elapsedMilliseconds}ms）');
        } else {
          // 每轮记一笔注入量 + **查到的到底相不相关**。
          //
          // 只记"注入 2 段 / 1226 字"是没用的：那个数字对"答得乱七八糟"这个
          // 争议点**完全没有解释力** —— 1000 字不相关的材料也是 1000 字。
          // 所以把分数和前 24 字摘要一起写进去，下次报告就能直接看出来。
          debugPrint('[dsh-kb] 注入 ${top.length} 段 / ${kbContext.length} 字'
              ' ≈ ${(kbContext.length * 0.7).round()} token'
              '（${_kbReady.length} 包参与，耗时 ${kbSw.elapsedMilliseconds}ms）'
              '${_kbReady.length > 1 ? ' 各包上限 2 段' : ''}'
              ' | 切法 ${modes.join(' ')}（2=按文档边界，1=旧切法）'
              ' | 分数 ${top.map((h) => h.score).join(',')}'
              ' | 摘要 ${top.map((h) => _kbSnippet(h.text)).join(' ‖ ')}');
        }
      } catch (e) {
        debugPrint('[dsh-kb] 检索失败（已忽略，继续问）：$e');
        if (mounted) {
          setState(() => _error = context.tr(msgKbFailedKey, ['$e']));
        }
      }
    } else {
      // 开关关着 / 一个已建索引的包都没有 —— 也记一笔，否则"没注入"和"没走这条
      // 路"在报告里长得一模一样。
      debugPrint('[dsh-kb] 未注入（开关=${_kbOn ? '开' : '关'}，'
          '已就绪的包=${_kbReady.length}）');
    }

    // ⚠️ **联网搜索已取消**（用户 2026-10-09 决定："干脆本地大模型取消联网搜索"）。
    //
    // 原因：它在真机上一直不可用。我这次抓到的是**两个独立原因**：
    //   ① 免费源（Bing/DuckDuckGo）被这里无条件要求填 Key —— 而设置页对免费源
    //      根本不显示 Key 输入框（两处口径分叉）；
    //   ② 就算过了①，`_bing` 的解析也认不出新版页面：它要求 `<h2>…<a href>`（链接
    //      在 h2 **里面**），而 cn.bing.com 现在把 `<a>` **包在 h2 外面** ——
    //      实测 5 个 `li.b_algo` 块**一个标题都取不到** → 报"没解析出结果"。
    //      这条已在 `web_search.dart` 里修好（两代结构都认 + 有单测），但用户
    //      决定这个功能先不要了 —— 所以入口撤掉，解析器与测试**留着**（park it），
    //      将来要恢复只需把入口加回来。
    //
    // 搜索失败原本会 `return`（不发这条消息）。现在这块整个删掉了，
    // 于是"发消息"这条路上不再有任何联网动作。

    final images = List<String>.from(_pending);
    final mergedContext = <String>[
      if (kbContext.trim().isNotEmpty) kbContext,
    ].join('\n\n');
    _input.clear();
    setState(() {
      _messages.add(LocalChatMessage(
        role: 'user',
        text: text,
        images: images,
        context: mergedContext,
        kbHits: kbHits,
        usedWeb: false,
      ));
      _pending.clear();
      _sending = true;
      _error = null;
      _streaming = '';
    });
    _toBottom();

    final acc = StringBuffer();
    // 出参：本轮有没有被截断（见 localChatStream 的 `notices` 参数）。
    final notices = <String>[];
    try {
      await for (final piece in localChatStream(
        port: port,
        // 最后一条就是这一轮的 user（见 localChatStream 的文档）。
        history: List<LocalChatMessage>.from(_messages),
        notices: notices,
      )) {
        acc.write(piece);
        if (!mounted) break;
        setState(() => _streaming = acc.toString());
        _toBottom();
      }
    } on LocalChatException catch (e) {
      if (mounted) setState(() => _error = _localChatErrorText(e.message));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      final reply = acc.toString();
      if (mounted) {
        setState(() {
          if (reply.trim().isNotEmpty) {
            _messages.add(LocalChatMessage(
              role: 'model',
              text: reply,
              // 顶到上限被砍 ≠ 答完了。如实标出来，界面会提示（别再让用户以为
              // 这就是全部内容）。
              truncated: notices.contains('length'),
            ));
          }
          _sending = false;
          _streaming = '';
        });
        await _store.save(_messages);
        _toBottom();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = _server;
    final running = server.running;
    final spec = server.spec;
    return Scaffold(
      backgroundColor: DshColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DshPageHeader(
              title: context.tr('本地对话'),
              subtitle: _switching
                  ? context.tr('正在切换模型…')
                  : _benching
                      ? context.tr('正在测速…')
                      : (running
                          ? (spec == null
                              ? context.tr('本机运行，不联网也能用')
                              : <String>[
                                  spec.displayName,
                                  '127.0.0.1:${spec.port}',
                                  // 有实测就写出来 —— 这是用户唯一能拿到的"本机真实速度"
                                  if (_bench[spec.modelId] != null)
                                    context.tr('实测 {0} tok/s', [
                                      _bench[spec.modelId]!
                                          .tokensPerSecond
                                          .toStringAsFixed(1),
                                    ]),
                                ].join(' · '))
                          : context.tr('本地模型服务没在运行')),
            ),
            // ⚠️ **这个 header 以前塞了 3 个图标**（测速 / 切换模型 / 清空对话），
            //    而 header 右侧的槽位只有 64px（见 DshPageHeader）→ 多出来的被挤到
            //    屏幕外（用户 2026-10-09 真机："界面图标都挤出屏幕以外"、
            //    "右上角的图标也是"）。现在它们搬到标题下面**右对齐**的一行 ——
            //    每个都带小字说明，不再是三个光秃秃的图标。
            _headerActions(context),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
                children: <Widget>[
                  _note(context),
                  if (!running) _notRunning(context),
                  if (_kbOn && _kbLegacy.isNotEmpty) _kbLegacyNotice(context),
                  if (_loaded && _messages.isEmpty && _streaming.isEmpty)
                    _emptyHint(context),
                  for (final m in _messages) _bubble(context, m),
                  if (_streaming.isNotEmpty)
                    _bubble(
                      context,
                      LocalChatMessage(role: 'model', text: _streaming),
                      streaming: true,
                    ),
                  if (_error != null) _errorBox(context, _error!),
                ],
              ),
            ),
            _inputRow(context),
          ],
        ),
      ),
    );
  }

  /// 顶部的如实说明：这条路为什么不经过 DSH。
  Widget _note(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          context.tr('本地模型只做简单对话：不经过 DSH，不带系统提示、不带工具 —— '
              '所以它不会像会话里那样乱答。'),
          style: TextStyle(
              color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
        ),
      );

  /// 旧切法索引的提示（见 [_kbLegacy]）。
  Widget _kbLegacyNotice(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.accent3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              context.tr('知识库「{0}」的索引还是旧切法建的：它把好几篇不相关的文章'
                  '塞在同一块里，检索会不准 —— 新的相关度门槛对它也无效。'
                  '去知识库页点「重建（推荐）」就好（在本机重建，不联网、不花额度）。',
                  [_kbLegacy.join('、')]),
              style: TextStyle(
                  color: DshColors.accent3, fontSize: 11, height: 1.55),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => unawaited(_openKbPage()),
                icon: const Icon(Icons.build_outlined, size: 15),
                label: Text(context.tr('去知识库页重建')),
              ),
            ),
          ],
        ),
      );

  /// 去知识库页（回来顺手重查一次：重建完提示就该消失）。
  Future<void> _openKbPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => KbPage(dshHome: widget.dshHome)),
    );
    await _loadKbReady();
  }

  Widget _notRunning(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.accent3),
        ),
        child: Text(
          context.tr('本地模型服务没在运行：先回「本地大模型」页启动它，再回来聊。'),
          style: TextStyle(
              color: DshColors.accent3, fontSize: 11.5, height: 1.5),
        ),
      );

  Widget _emptyHint(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Text(
          context.tr('直接问它就好（这里没有工具、没有技能，纯聊天）。'),
          textAlign: TextAlign.center,
          style: TextStyle(
              color: DshColors.textFaint, fontSize: 12, height: 1.6),
        ),
      );

  /// 一条气泡。用户靠右、模型靠左；模型那条**可选中复制**。
  Widget _bubble(BuildContext context, LocalChatMessage m,
      {bool streaming = false}) {
    final isUser = m.isUser;
    final body = streaming ? '${m.text}▍' : m.text;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: isUser ? DshColors.userBubble : DshColors.aiBubble,
          borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 用户发的图：显示缩略图（原图太大，气泡里放不下也没必要）。
            if (m.images.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: body.isEmpty ? 0 : 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final p in m.images)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                        child: Image.file(
                          File(p),
                          width: 108,
                          height: 108,
                          fit: BoxFit.cover,
                          // 文件可能已被清掉 —— 如实显示"图没了"，不要白块。
                          errorBuilder: (_, __, ___) => Container(
                            width: 108,
                            height: 108,
                            color: DshColors.surface,
                            alignment: Alignment.center,
                            child: Text(
                              context.tr('图片文件已不在'),
                              style: TextStyle(
                                  color: DshColors.textFaint, fontSize: 10),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (m.kbHits > 0 || m.usedWeb)
              Padding(
                padding: EdgeInsets.only(bottom: body.isEmpty ? 0 : 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (m.kbHits > 0) ...<Widget>[
                      Icon(Icons.menu_book,
                          size: 12, color: DshColors.textFaint),
                      const SizedBox(width: 3),
                      Text(context.tr('知识库 {0} 段', ['${m.kbHits}']),
                          style: TextStyle(
                              color: DshColors.textFaint, fontSize: 10)),
                    ],
                    if (m.kbHits > 0 && m.usedWeb) const SizedBox(width: 8),
                    if (m.usedWeb) ...<Widget>[
                      Icon(Icons.travel_explore,
                          size: 12, color: DshColors.textFaint),
                      const SizedBox(width: 3),
                      Text(context.tr('联网'),
                          style: TextStyle(
                              color: DshColors.textFaint, fontSize: 10)),
                    ],
                  ],
                ),
              ),
            if (body.isNotEmpty)
              SelectableText(
                body,
                style: TextStyle(
                    color: DshColors.text, fontSize: 13.5, height: 1.55),
              ),
            // 顶到长度上限被截断 → **必须说出来**。不说的话用户看到的就是
            // "句子说到一半没了"，会当成模型答错/答乱（2026-10-12 那次 768 段
            // 就是这么被误判的）。样式与页面里其它提示一致（accent3）。
            if (m.truncated)
              Container(
                margin: const EdgeInsets.only(top: 7),
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: DshColors.surface,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                  border: Border.all(color: DshColors.accent3),
                ),
                child: Text(
                  context.tr('这条回答顶到了长度上限、被截断了（不是答完）。'
                      '可以再发一句「继续」，或者把问题拆小一点再问。'),
                  style: TextStyle(
                      color: DshColors.accent3, fontSize: 10.5, height: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 错误框：**原样**显示引擎的话（这是判断模型构建能不能用的依据）。
  Widget _errorBox(BuildContext context, String message) => Container(
        margin: const EdgeInsets.only(top: 4, bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.err),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(context.tr('本地模型出错：{0}', [message]),
                style: TextStyle(
                    color: DshColors.err, fontSize: 11.5, height: 1.5)),
            const SizedBox(height: 6),
            Text(
              context.tr('这段话就是引擎的原话，没加工 —— 发我这份就能直接定位。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
            ),
          ],
        ),
      );

  /// 标题下面那一行操作（从 header 的 64px 槽位里搬出来的）。
  ///
  /// 为什么搬出来：`DshPageHeader` 的右侧槽位只有 64px，而这里原本塞了 **3 个
  /// IconButton**（3×48 = 144px）→ 多出来的被挤到屏幕外（用户 2026-10-09 真机反馈：
  /// "界面图标都挤出屏幕以外"、"右上角的图标也是"）。
  /// 现在改成右对齐的一行**带字的小按钮** —— 顺带解决"三个光秃秃的图标不知道是干嘛的"。
  Widget _headerActions(BuildContext context) {
    final running = _server.running;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 2),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          // 手动测速（切换后会自动测一次；这个给"想再测一遍"用）。
          _miniAction(
            context,
            label: context.tr('测速'),
            icon: Icons.speed,
            busy: _benching,
            onTap: (_switching || _benching || !running)
                ? null
                : () => _benchNow(showToast: true),
          ),
          // 页内直接换模型（以前要回上一页停掉再启动）。
          _miniAction(
            context,
            label: context.tr('切换本地模型'),
            icon: Icons.swap_horiz,
            busy: _switching,
            accent: _models.isNotEmpty,
            onTap: _switching ? null : _pickModel,
          ),
          _miniAction(
            context,
            label: context.tr('清空对话'),
            icon: Icons.delete_outline,
            onTap: _messages.isEmpty ? null : _clear,
          ),
        ],
      ),
    );
  }

  /// 紧凑的「图标 + 小字」按钮 —— 标题下的操作行、输入框下的开关行都用它。
  ///
  /// **为什么不用 IconButton**：它的点按区默认 **48×48**，排一排就把横向空间吃光了
  /// （真机上 4 个开关 + 输入框 = 输入框被挤成一条，图标还被挤出屏幕）。
  /// 这里高度约 32、宽度按文字自适应；外层都用 `Wrap`，再窄的屏也只是换行。
  Widget _miniAction(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    String? tooltip,
    bool busy = false,
    bool accent = false,
    bool active = false,
  }) {
    final enabled = onTap != null;
    final hl = (active || accent) && enabled;
    final color = !enabled
        ? DshColors.textFaint
        : (hl ? DshColors.accent : DshColors.textDim);
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
          border: Border.all(color: hl ? DshColors.accent : DshColors.line2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (busy)
              const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip, child: btn);
  }

  Widget _inputRow(BuildContext context) {
    final canSend = (_input.text.trim().isNotEmpty || _pending.isNotEmpty) &&
        !_sending;
    // 只有多模态模型才给拍照/相册入口 —— 纯文本模型（Qwen3 0.6B / Gemma 3 1B）
    // 看不见图，给了入口就是骗人（用户拍半天，模型答非所问）。
    final vision = _server.spec?.vision == true;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      decoration: BoxDecoration(
        // ⚠️ 这条输入栏是**盖在消息列表上的**：用 10% 白的 navBg 时，
        //    深色下消息文字会从它底下透上来（用户 2026-10-12 第 4 条）。
        color: DshColors.surfaceStrong,
        border: Border(top: BorderSide(color: DshColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_pending.isNotEmpty) _pendingStrip(context),
          // ── 第一行：**只有**输入框 + 发送 ────────────────────────────────
          // 这一行以前是「4 个 IconButton + 输入框 + 发送」：多模态模型下光按钮就
          // 吃掉约 240px，输入框被挤到只剩一条（用户 2026-10-09 真机反馈：
          // "四个小图标把对话框挤到右边"）。现在这一行只有两样东西。
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(color: DshColors.text, fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: vision
                        ? context.tr('跟本机模型说点什么（也可以发图）…')
                        : context.tr('跟本机模型说点什么…'),
                    hintStyle:
                        TextStyle(color: DshColors.textFaint, fontSize: 13),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(DshMetrics.radius(18)),
                      borderSide: BorderSide(color: DshColors.line2),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(DshMetrics.radius(18)),
                      borderSide: BorderSide(color: DshColors.line2),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(DshMetrics.radius(18)),
                      borderSide: BorderSide(color: DshColors.accent),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: canSend ? _send : null,
                tooltip: context.tr('发送'),
                icon: _sending
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: DshColors.accent))
                    : Icon(Icons.send_rounded,
                        size: 20,
                        color: canSend ? DshColors.accent : DshColors.textFaint),
              ),
            ],
          ),
          // ── 第二行：开关放到**输入框下面**（用户 2026-10-09 明确要求）─────
          // 用 Wrap 排：宽度不够只会换行，**永远不会把输入框挤走、也不会溢出屏幕**。
          const SizedBox(height: 2),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _miniAction(
                context,
                label: context.tr('知识库'),
                icon: _kbOn ? Icons.menu_book : Icons.menu_book_outlined,
                active: _kbOn,
                tooltip: context.tr('知识库'),
                onTap: _sending ? null : _toggleKb,
              ),
              if (vision) ...<Widget>[
                _miniAction(
                  context,
                  label: context.tr('拍照'),
                  icon: Icons.photo_camera_outlined,
                  onTap: _sending ? null : () => _pick('photo'),
                ),
                _miniAction(
                  context,
                  label: context.tr('相册'),
                  icon: Icons.image_outlined,
                  onTap: _sending ? null : () => _pick('media'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 待发图片的缩略图条（点右上角小叉可以撤掉这一张）。
  Widget _pendingStrip(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 2),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final p in List<String>.from(_pending))
              Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                    child: Image.file(
                      File(p),
                      width: 54,
                      height: 54,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 54,
                        height: 54,
                        color: DshColors.surface,
                        alignment: Alignment.center,
                        child: Icon(Icons.broken_image_outlined,
                            size: 18, color: DshColors.textFaint),
                      ),
                    ),
                  ),
                  Positioned(
                    right: -6,
                    top: -6,
                    // ⚠️ 原来是一颗裸 `GestureDetector` + 12px 图标，padding 只有 2
                    // —— 触控目标约 18dp，远低于 48dp 的建议值（审计 P1-4）。
                    // 缩略图本身只有 54dp，塞不下 48dp 的圆钮（会盖住整张图），
                    // 所以把它撑到 **32dp** 并让整个方框可点（opaque）——
                    // 比原来的 18dp 好得多，但**仍低于 48dp 的建议值**，这条如实留着。
                    child: Semantics(
                      button: true,
                      label: context.tr('移除这张图'),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _pending.remove(p)),
                        child: Container(
                          // 视觉上仍是小圆点，但触控区扩到 32dp（配合上面的
                          // behavior: opaque，整个方框都可点）。
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            // 同上：小圆点下面压着消息，不能用半透明。
                            color: DshColors.surfaceStrong,
                            shape: BoxShape.circle,
                            border: Border.all(color: DshColors.divider),
                          ),
                          child: Icon(Icons.close,
                              size: 12, color: DshColors.textDim),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      );
}
