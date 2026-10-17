import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/agnes_builtin.dart';
import '../../data/api_error_text.dart';
import '../../data/chat_model_rule.dart';
import '../../data/configured_models.dart';
import '../../data/model_fetcher.dart';
import '../../data/model_order.dart';
import '../../data/model_providers.dart';
import '../../local/dsh_runtime.dart';
import '../../local/local_model_server.dart';
import '../../state/provider_keys.dart';
import '../theme/dsh_tokens.dart';

import '../../i18n/dsh_i18n.dart';
import '../widgets/common.dart';

/// 「设置 → 模型」区的**全部内容**（用户 2026-10-05 的新版方案）。
///
/// 这一块是整段重写的：旧结构是「当前模型卡 → 分组卡片 → 轮换组 → 添加模型长表单 →
/// Agnes 单独一块」，用户的原话是「设置页面模型这一块还是凌乱，取消现有的」。
/// 新结构只有两块 + 一个池子，顺序就是用户给的顺序：
///
///   1. **我的模型** —— 内置厂家的下拉卡片，顺序固定
///      `Agnes（免费）→ DeepSeek → Command（聚合）→ MiMo → LongCat`
///      （LongCat 是**真实内置厂家**，没被点名但放最后一张而不是删掉 ——
///       删掉会让已经配了 LongCat 的用户丢功能）。
///      每张卡收起时只有一行「厂家名 + 状态徽标 + 箭头」，展开后依次是：
///      介绍 → （MiMo 才有的端点切换）→ 去注册/充值 → 获取模型 → 「只需要填 API Key」→
///      Key 输入框 → 「测试并保存」。
///      **内置厂家的地址不允许用户填**（一律用 [ModelProvider.baseUrl]，MiMo 走两档切换）。
///      Agnes 那张卡**不显示图形/视频端点行**（用户明确说"图形和视频已经内置端口，
///      不需要显示出来"），也不给「获取模型」——它只要 介绍 + 去注册 + 免费口径 +
///      Key + 测试并保存。
///   2. **添加模型** —— 用户自己加别的大模型，允许手填 Base URL，**默认收起**。
///   3. **轮换池**（旧的「轮换组」改名）—— 也是下拉菜单，展开才摊内容；展开后既能看到
///      池子里有什么、也能看到**所有已注册的模型**，点一下就把那个模型放进池子。
///
/// ## 「测试并保存」的数据流（这是本轮的硬要求，别改坏）
///
///   ① Key → `ProviderKeys.write`（只进系统安全区，**绝不进 models.json / 不进日志**）。
///      Key 输入框留空时回落到安全区里已经存好的那把（与「获取模型」同一口径）——
///      否则"重开卡片想再测一次"的用户会被挡在"请先填 Key"上，而他明明填过了；
///   ② 决定这家要有哪些模型：**已经登记过的**就用它 → 否则真拉一次 `/models`
///      （**全部登记、不截断** —— 用户 2026-10-16 明确要求）→ 再否则回退到
///      `ModelProvider.exampleModels`（并在界面与日志里**如实说明**用的是预置建议模型）；
///      一条都凑不出来就**不算保存成功**，明确报错；
///      ⚠️ 登记前先过 [_isChatModel]：Agnes 的图像/视频模型是**内置端口**，
///      用户明确要求"不需要显示出来"，绝不能让它们混进会话的模型列表（详见那个方法）；
///   ③ upsert 进 `models.json`：**其它厂家、它们的模型、轮换池一个都不能丢**；
///   ④ `await widget.onModelChanged()` —— 它会重读 `models.json` + 重写 overlay +
///      重建 runtime，于**会话侧立刻能看到这个模型**（用户实测 bug：
///      「填了模型了，会话页面没有读出来」，根因就是"只写了 Key、清单里一条模型都没有"，
///      以及"写盘了但没通知会话侧重读"）；
///   ⑤ 真打一次最小对话请求（`testModelConnection`）—— 通过才把状态改成"已测试通过"
///      并收起卡片；不通过就贴中文原因。**测试失败不阻止登记**：模型已经在 ③ 落盘了，
///      界面会如实写"模型已经登记好、但测试没通过"，免得用户以为白填了。
class ModelSettingsPanel extends StatefulWidget {
  const ModelSettingsPanel({
    super.key,
    required this.filesDir,
    required this.onModelChanged,
    this.refreshTick = 0,
    this.syncTick = 0,
    this.showModels = true,
    this.showPool = true,
  });

  /// 运行时私有目录（`models.json` 就在它下面）。
  final String filesDir;

  /// 落盘之后必须调它：重读 `models.json` + 重写 overlay + 重建 runtime。
  final Future<void> Function() onModelChanged;

  /// **切页**刷新计数（底部 Tab 切到设置页时 +1，见 app_shell 的 `_pageTicks`）。
  ///
  /// 它一变就会**重读磁盘 + 把展开态收回去** —— 这是"切换即刷新"那条要求的完整语义。
  final int refreshTick;

  /// **别处改了模型**时的同步计数（本页自己改完模型 `_modelTick++`）。
  ///
  /// 只让它**重读数据**，**不动展开态、不清勾选** —— 两个方向必须分开：
  ///
  /// ⚠️ 这里原本只有 [refreshTick] 一个数，两个方向混在一起，于是用户在模型面板里
  /// 点任何会落盘的东西（获取模型 / 测试并保存 / 加模型 / 删模型）→ 触发同步 → 被当成
  /// "切页" → `_openProvider` 被清空、`_addOpen` 关掉、`_picked` 清空 → 界面像**自己退出了**，
  /// 用户得重新展开、重新勾、重新填。真机反馈原话（2026-10-15）：
  /// 「设置模型的时候，怎么一点就退出，我还要再进去保存」。
  final int syncTick;

  /// 是否渲染「我的模型 / 添加模型」这两段。
  ///
  /// 用户要求把轮换池**单独做成设置页的一个板块**，于是这个面板会被实例化两次：
  /// 一个只渲染模型（本参数 false 的那个不渲染池），一个只渲染池。
  final bool showModels;

  /// 是否渲染「模型轮换池」这一段。
  final bool showPool;

  @override
  State<ModelSettingsPanel> createState() => _ModelSettingsPanelState();
}

/// 一张内置厂家卡 / 自定义表单的**运行态**：只影响界面，不落盘。
class _Runtime {
  _Runtime({required this.baseUrl});

  bool busy = false;

  /// 本次会话里"测试通过"过（界面徽标用它，不落盘 —— 重启后如实回到"已配 Key"）。
  bool testedOk = false;
  int? latencyMs;

  ApiErrorText? error;
  String? notice;
  bool noticeOk = false;

  /// 实际要用的端点。内置厂家默认就是预设那一档；只有 MiMo 会被切换按钮改掉。
  String baseUrl;
}

class _ModelSettingsPanelState extends State<ModelSettingsPanel> {
  static const _secure = FlutterSecureStorage();

  // 与 settings_page.dart（对话页齿轮）用**同一组键**：那两个页面改的是同一份配置。
  static const _kApiKey = 'dsh_model_api_key';
  static const _kBaseUrl = 'dsh_model_base_url';
  static const _kProvider = 'dsh_model_provider';
  static const _kModel = 'dsh_model_id';

  /// ModelStore 恢复选中项时优先读它（轮换池也走这里，值是完整 route）。
  static const _kSelected = 'dsh_model_selected_id';

  /// 一次「测试并保存」最多自动登记多少个模型。
  ///
  /// 为什么要有个上限：Command 是聚合端点，`/models` 动辄几百个 —— 全写进
  /// `models.json` 会让会话里的模型面板变成一堵墙，而用户并没有选它们。
  /// 想精确挑选就走「获取模型」自己勾（那条路没有上限）。
  ConfiguredConfig _cfg = ConfiguredConfig.empty;
  final Map<String, bool> _keyReady = <String, bool>{};

  /// 上次读配置是不是**读坏了**（文件在、但解析不了）。见 [ConfiguredModels.lastReadError]。
  ///
  /// 为什么要显示：老行为是"读坏 → 当成空 → 界面显示『还没配置』"，
  /// 用户看到的是"我的模型全没了"，而不是"你的配置读不出来、已另存备份"。
  /// 这两种情形对用户的意义完全不同（审计 P0-9）。
  String? _readError;

  /// 手风琴：同一时刻只有一张内置厂家的卡是展开的（用户方案的"点开展开"）。
  String? _openProvider;

  /// 「添加模型」默认收起。
  bool _addOpen = false;

  /// 「轮换池」默认收起（用户要求：也是下拉菜单，展开才有内容）。
  bool _poolOpen = false;

  /// 每个内置厂家的运行态（懒建）。
  final Map<String, _Runtime> _rt = <String, _Runtime>{};

  /// 每个内置厂家自己的 Key 输入框（不回显安全区里的 Key，只装用户这次敲的）。
  final Map<String, TextEditingController> _keyCtrls =
      <String, TextEditingController>{};

  // ── 「获取模型」的暂存（只属于当前展开的那张卡）──────────────────────
  String? _fetchedFor;
  List<FetchedModel> _fetched = const <FetchedModel>[];
  final Set<String> _picked = <String>{};
  ApiErrorText? _fetchError;
  String? _fetchNotice;

  // ── 轮换池（旧的「轮换组」，**只改文案不改数据字段/route**）──────────
  bool _poolBusy = false;
  bool _poolFormOpen = false;
  bool _deleting = false;

  /// 正在编辑的池子的**原名**（null = 新建）。池名允许改，所以得单独记住原名。
  String? _poolEditing;
  final _poolName = TextEditingController();
  List<String> _poolMembers = <String>[];

  /// 「本机模型已从轮换池移出」的一次性提示（用户 2026-10-12 的要求）。
  ///
  /// 为什么要有：这是**改了用户已有的配置**，不能悄悄改。移出哪些池子要写在界面上。
  String? _poolLocalMigrated;
  String? _poolMessage;
  bool _poolOk = false;

  /// 哪张池子卡是展开的（摊出成员与顺序调整）。
  String? _openPoolCard;

  // ── 「添加模型」（自定义厂家）表单 ──────────────────────────────────
  final _cLabel = TextEditingController();
  final _cId = TextEditingController();
  final _cBase = TextEditingController();
  final _cKey = TextEditingController();
  final _cModel = TextEditingController();
  final _cContext = TextEditingController();
  bool _cBusy = false;
  List<FetchedModel> _cFetched = const <FetchedModel>[];
  final Set<String> _cPicked = <String>{};
  ApiErrorText? _cError;
  String? _cNotice;
  bool _cNoticeOk = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant ModelSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 两个计数器**都只重读数据**，界面状态（展开了哪张卡、勾选了哪些模型）一律保留。
    //
    // ⚠️ 这里原本在 refreshTick 变化时把展开态全清掉（`_openProvider = null` 等），
    //    本意是"每次切回这一页都像重进来一次"。真机反馈（2026-10-16）暴露了它的代价：
    //    「选择大模型经常发生跳转，比如我在云端大模型填写，一下子跳到免费大模型，
    //     还得滑屏到云端的填写框」—— 卡片被收起 → 整页高度骤减 → 滚动位置突变，
    //    用户正在填的表单就这么"跳"走了（免费模型那张卡在列表上方，所以看到的永远是它）。
    //
    //    "切换即刷新"要的是**数据新鲜**（重读 `models.json` / 系统安全区里的 Key），
    //    不是把用户正在填的表单收起来。所以现在只 `_reload()`：
    //      · 厂家/模型/轮换池的**数据**照旧重读（切页仍然"刷"）；
    //      · 界面状态不再被打断（这条同时覆盖了 2026-10-15 那次"一点就退出"的修复）。
    if (oldWidget.refreshTick != widget.refreshTick ||
        oldWidget.syncTick != widget.syncTick) {
      _reload();
    }
  }

  @override
  void dispose() {
    for (final c in _keyCtrls.values) {
      c.dispose();
    }
    _poolName.dispose();
    _cLabel.dispose();
    _cId.dispose();
    _cBase.dispose();
    _cKey.dispose();
    _cModel.dispose();
    _cContext.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 基础读写

  _Runtime _rtOf(ModelProvider p) =>
      _rt.putIfAbsent(p.id, () => _Runtime(baseUrl: p.baseUrl));

  /// 用「实际的端点」现造一个 provider 去拉列表 / 打测试请求。
  /// 用户可能切换过端点（MiMo 两档），不能用预设那份。
  ModelProvider _draft(ModelProvider p, String base) => ModelProvider(
        id: p.id,
        name: p.name,
        baseUrl: base,
        keyHint: p.keyHint,
        modelsPath: p.modelsPath,
      );

  TextEditingController _keyCtrl(String pid) =>
      _keyCtrls.putIfAbsent(pid, () => TextEditingController());

  List<ModelSpec> _modelsOf(String provId) => <ModelSpec>[
        for (final m in _cfg.models)
          if (m.provider == provId) m,
      ];

  /// 从磁盘重读配置 + 每个厂家的 Key 状态。
  ///
  /// 每次改动后都**重读**，而不是在内存里拼一个乐观结果：界面上的徽标、模型条数、
  /// 池子成员必须等于磁盘上的真值。
  Future<void> _reload() async {
    var cfg = ConfiguredModels.readConfig(widget.filesDir);
    // ⚠️ 本机模型不许进轮换池（用户 2026-10-12）。老用户的池子里可能**已经**有 ——
    //    这里真的把它移出去并落盘。只把候选行删掉是不够的：
    //    池子照样会去试本机模型，用户看到的还是"改了没用"。
    final swept = _stripLocalFromPools(cfg.groups);
    if (swept.removed > 0) {
      cfg = _withSelection(
        providers: cfg.providers,
        models: cfg.models,
        groups: swept.groups,
        keep: cfg.selected,
      );
      // ⚠️ 这里**必须**用同步写：`initState` 里发起的异步写会绑在 fake-async 区上，
      //    测试里永不返回（迁移静默失效、测试却全绿）。详见 `saveConfigSync` 的注释。
      ConfiguredModels.saveConfigSync(
          filesDir: widget.filesDir, config: cfg);
      debugPrint('[dsh-model-panel] 已把本机模型移出轮换池：'
          '${swept.touched.join('、')}（用户 2026-10-12 要求）');
      _poolLocalMigrated = swept.touched.join('、');
    }
    final ready = <String, bool>{};
    for (final p in cfg.providers) {
      // 「凭据由 App 自己提供」的厂家（免费模型 / 本机模型）**不用写 Key**，
      // 这里必须直接算可用 —— 否则池子成员那一行会给它加一句"这家还没配 Key"，
      // 而它恰恰不用配（与 ModelStore 同一口径，见 appProvidedCredentialIds）。
      if (ConfiguredModels.appProvidedCredentialIds.contains(p.id)) {
        ready[p.id] = true;
        continue;
      }
      final k = await ProviderKeys.read(p.id);
      ready[p.id] = k != null && k.trim().isNotEmpty;
    }
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      // 读坏了要让界面说出来（P0-9）：否则用户只看到"还没配置"，
      // 会以为是自己没配，而实际是文件坏了、已经另存成 .corrupt 等他处理。
      _readError = ConfiguredModels.lastReadError;
      _keyReady
        ..clear()
        ..addAll(ready);
    });
    debugPrint(
      '[dsh-model-panel] 本页刷新：${cfg.providers.length} 个厂家 / '
      '${cfg.models.length} 个模型 / ${cfg.groups.length} 个轮换池，'
      'selected=${cfg.selected ?? '-'}',
    );
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openUrl(String? url, String what) async {
    final target = (url ?? '').trim();
    if (target.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    debugPrint('[dsh-model-panel] 打开$what → $target');
    try {
      final result = await DshHost.openUrl(target);
      if (!mounted) return;
      if (result == 'no_app') {
        messenger.showSnackBar(
          SnackBar(
              content: Text(context.tr('这台设备没有能打开网页的应用，请手动访问：{0}', [target]))),
        );
      }
    } catch (e) {
      final t = translateException(e);
      debugPrint('[dsh-model-panel] 打开$what失败：${t.zh}');
      if (!mounted) return;
      messenger.showSnackBar(
          SnackBar(content: Text(context.tr('打不开网页：{0}', [t.zh]))));
    }
  }

  /// 表单里那把 Key：输入框留空时回落到这家厂家安全区里已经存好的那把。
  Future<String> _effectiveKey(
      String provId, TextEditingController ctrl) async {
    final typed = ctrl.text.trim();
    if (typed.isNotEmpty) return typed;
    return (await ProviderKeys.read(provId))?.trim() ?? '';
  }

  /// 把「选中项 / 老的单厂家键」同步一遍。
  ///
  /// 为什么还要写这几处：`ui/settings_page.dart`（对话页齿轮）与 `ModelStore` 的
  /// 回落路径仍在读 `dsh_model_id` / `dsh_model_provider` / `dsh_model_base_url`，
  /// 以及 ModelStore 自己的 `dsh_model_selected_id`。不同步的话，设置页说配好了、
  /// 齿轮页还是空 —— 那等于"没配上"。**Key 依然只进系统安全区。**
  Future<void> _syncLegacyKeys(ConfiguredConfig cfg) async {
    final sel = (cfg.selected ?? '').trim();
    final slash = sel.indexOf('/');
    if (slash <= 0) return;
    final pid = sel.substring(0, slash);
    try {
      await _secure.write(key: _kSelected, value: sel);
      // 轮换池也写：它存的是完整 route（`rotate/<池名>`），ModelStore 优先读它。
      if (pid == ConfiguredModels.rotateProviderId) return;
      final spec = cfg.providerOf(pid);
      if (spec == null) return;
      if (!cfg.models.any((m) => m.route == sel)) return;
      await _secure.write(key: _kModel, value: sel.substring(slash + 1));
      await _secure.write(key: _kProvider, value: pid);
      await _secure.write(key: _kBaseUrl, value: spec.baseUrl);
      final k = await ProviderKeys.read(pid);
      if (k != null && k.trim().isNotEmpty) {
        await _secure.write(key: _kApiKey, value: k);
      }
    } catch (e) {
      debugPrint('[dsh-model-panel] 同步旧键失败：$e');
    }
  }

  // ------------------------------------------------------------------ 我的模型

  Widget _myModelsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHead(
          context.tr('我的模型'),
          context.tr('点厂家名字展开：介绍 → 去注册 → 获取模型 → 填 Key → 测试并保存'),
        ),
        const SizedBox(height: 10),
        for (final p in myModelProviders()) _providerCard(p),
      ],
    );
  }

  /// 一张内置厂家卡：收起态一行，展开态是整段配置流程。
  Widget _providerCard(ModelProvider p) {
    final rt = _rtOf(p);
    final open = _openProvider == p.id;
    final ready = _keyReady[p.id] ?? false;
    final mine = _modelsOf(p.id);
    final (String badge, Color badgeColor) = rt.testedOk
        ? (context.tr('已测试通过'), DshColors.ok)
        : ready
            ? (context.tr('已配 Key'), DshColors.ok)
            : (context.tr('未配 Key'), DshColors.err);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: DshColors.panel(
        radius: 11,
        color: DshColors.surfaceHigh,
        borderColor: open ? DshColors.accent : DshColors.line,
        glow: false,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 收起态：就一行 —— 厂家名 + 状态徽标 + 展开箭头 ──────────────
          Semantics(
            button: true,
            label: context.tr('{0}，{1}，{2} 个模型，{3}',
                [p.name, badge, mine.length, open ? '收起' : '展开']),
            container: true,
            child: InkWell(
              onTap: () => setState(() {
                _openProvider = open ? null : p.id;
                // 换一张卡就把上一张的拉取结果丢掉，免得张冠李戴
                _fetchedFor = null;
                _fetched = const <FetchedModel>[];
                _picked.clear();
                _fetchError = null;
                _fetchNotice = null;
                rt.error = null;
                rt.notice = null;
              }),
              borderRadius: BorderRadius.circular(DshMetrics.radius(11)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(11, 10, 6, 10),
                child: Row(
                  children: [
                    Icon(
                      open ? Icons.expand_more : Icons.chevron_right,
                      size: 16,
                      color: open ? DshColors.accent : DshColors.textDim,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: open ? DshColors.accent : DshColors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (mine.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          context.tr('{0} 个模型', [mine.length]),
                          style: TextStyle(
                              color: DshColors.textFaint, fontSize: 10.5),
                        ),
                      ),
                    _pill(badge, color: badgeColor),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(11, 0, 11, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(height: 14, thickness: 0.6, color: DshColors.divider),
                  // ① 一句话介绍：这家是什么、适合谁
                  DshRichText(
                    p.intro ??
                        p.note ??
                        context.tr('内置厂家：端点已预填，你只需要填 API Key。'),
                    style: TextStyle(
                      color: DshColors.textDim,
                      fontSize: 11.5,
                      height: 1.6,
                    ),
                  ),
                  // Agnes 的免费口径必须照抄官方的限定（"当前/限时免费"，
                  // 不是"永久免费"）—— 这是诚实性要求。
                  if (p.id == AgnesBuiltin.providerId) ...[
                    const SizedBox(height: 8),
                    _infoBox(AgnesBuiltin.freeNote),
                  ],
                  // ② MiMo 才有的两档端点切换（内置地址不给用户手填，只给一键切换）
                  if (p.hasEndpointVariants) ...[
                    const SizedBox(height: 12),
                    _endpointChooser(p, rt),
                  ],
                  const SizedBox(height: 12),
                  // ③ 去注册 / 充值
                  _providerLinkRow(p),
                  // ④ 获取模型（Agnes 不要这一行 —— 用户的原话是"Agnes 只要…"）
                  if (p.id != AgnesBuiltin.providerId) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: rt.busy ? null : () => _fetchModels(p),
                          icon: rt.busy
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.cloud_download_outlined,
                                  size: 16),
                          label: Text(rt.busy
                              ? context.tr('获取中…')
                              : context.tr('获取模型')),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.tr('列表里没有你想要的，就点它拉一次再勾选。'),
                            style: TextStyle(
                              color: DshColors.textFaint,
                              fontSize: 10.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_fetchedFor == p.id && _fetchNotice != null) ...[
                      const SizedBox(height: 8),
                      _noticeBox(_fetchNotice!, true),
                    ],
                    if (_fetchedFor == p.id && _fetchError != null) ...[
                      const SizedBox(height: 8),
                      _errorBox(_fetchError!),
                    ],
                    if (_fetchedFor == p.id && _fetched.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _fetchedList(
                        models: _fetched,
                        onTap: (id) => setState(() {
                          if (!_picked.add(id)) _picked.remove(id);
                        }),
                        picked: _picked,
                        already: <String>{
                          for (final m in mine) m.id,
                        },
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: (rt.busy || _picked.isEmpty)
                            ? null
                            : () => _addPicked(p),
                        icon: const Icon(Icons.playlist_add, size: 16),
                        label: Text(
                          _picked.isEmpty
                              ? context.tr('勾选上面的模型（可多选）')
                              : context
                                  .tr('把勾选的 {0} 个加入我的模型', [_picked.length]),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                  // ⑤ 一行提示：只需要填 API Key
                  _rowHint(context.tr('只需要填 API Key'),
                      context.tr('地址已经内置好了 —— 不用你填端点。')),
                  const SizedBox(height: 8),
                  // ⑥ Key 输入框
                  _keyField(p),
                  // ⑥b 备用 Key（多账号）：只有 Agnes 的生图/生视频会用到多把 Key，
                  //     所以只在这一张卡里显示。限流按**账号**算 —— 同一账号多建几把
                  //     共享同一份配额，界面上必须把这句话说清楚，否则用户白忙。
                  if (p.id == AgnesBuiltin.providerId) ...<Widget>[
                    const SizedBox(height: 10),
                    _BackupKeysBlock(providerId: p.id),
                  ],
                  const SizedBox(height: 10),
                  // ⑦ 测试并保存
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: rt.busy ? null : () => _testAndSave(p),
                      icon: rt.busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_outlined, size: 17),
                      label: Text(rt.busy
                          ? context.tr('正在测试并保存…')
                          : context.tr('测试并保存')),
                    ),
                  ),
                  if (rt.error != null) ...[
                    const SizedBox(height: 10),
                    _errorBox(rt.error!),
                  ],
                  if (rt.notice != null) ...[
                    const SizedBox(height: 10),
                    _noticeBox(rt.notice!, rt.noticeOk),
                  ],
                  if (mine.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      context.tr(
                          '这家已经登记的模型（{0} 个）—— 会话的模型面板里能选的就是它们：', [mine.length]),
                      style:
                          TextStyle(color: DshColors.textDim, fontSize: 11.5),
                    ),
                    const SizedBox(height: 6),
                    for (final m in mine) _registeredModelRow(p, m),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 一行「只需要填 API Key」的提示（用户原话就是这句）。
  Widget _rowHint(String title, String note) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.key_outlined, size: 14, color: DshColors.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$title　',
                    style: TextStyle(
                      color: DshColors.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: note,
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _keyField(ModelProvider p) => TextField(
        controller: _keyCtrl(p.id),
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: 'API Key',
          hintText: p.keyHint,
          helperText: context.tr(
              '只存本机安全区（Android Keystore）：不写进 models.json、不进日志、界面上也读不出来；填完点「测试并保存」。'),
          helperMaxLines: 3,
          helperStyle: TextStyle(
              color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
          labelStyle: TextStyle(color: DshColors.textDim, fontSize: 12.5),
          floatingLabelStyle:
              TextStyle(color: DshColors.accent, fontSize: 12.5),
          isDense: true,
        ),
      );

  Widget _providerLinkRow(ModelProvider p) {
    final hasKeyUrl = (p.keyUrl ?? '').trim().isNotEmpty;
    final hasTopUp = (p.topUpUrl ?? '').trim().isNotEmpty;
    if (!hasKeyUrl && !hasTopUp) {
      return Text(
        context.tr('这家没有内置的注册地址 —— 去它的官网申请 Key 就行。'),
        style: TextStyle(color: DshColors.textFaint, fontSize: 11),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        if (hasKeyUrl)
          _linkButton(
            icon: Icons.open_in_new,
            label: context.tr('去注册 / 申请 Key'),
            onTap: () =>
                _openUrl(p.keyUrl, context.tr('{0} 注册 / 申请 Key', [p.name])),
          ),
        if (hasTopUp)
          _linkButton(
            icon: Icons.account_balance_wallet_outlined,
            label: context.tr('充值'),
            onTap: () => _openUrl(p.topUpUrl, context.tr('{0} 充值', [p.name])),
          ),
      ],
    );
  }

  Widget _linkButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// 多套端点的两档切换（只有 MiMo 有）。
  ///
  /// 用户方案：「内置厂家的地址一律不要让用户填」—— 所以这里**不给输入框**，
  /// 只给两档按钮，点一下把端点换掉（地址仍然全是我们内置的实测值）。
  Widget _endpointChooser(ModelProvider p, _Runtime rt) {
    final current = _normalizeUrl(rt.baseUrl);
    ProviderEndpoint? picked;
    for (final e in p.endpoints) {
      if (_normalizeUrl(e.baseUrl) == current) picked = e;
    }
    final shown = picked ?? p.endpoints.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('端点（这家有两套，点一下切换；选错会 401/404）'),
          style: TextStyle(color: DshColors.textDim, fontSize: 11.5),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in p.endpoints)
              _chip(
                label: e.label,
                selected: picked != null && e.label == picked.label,
                onTap: () => setState(() {
                  rt.baseUrl = e.baseUrl;
                  rt.notice =
                      context.tr('端点已切到「{0}」：{1}', [e.label, e.baseUrl]);
                  rt.noticeOk = true;
                  rt.error = null;
                  rt.testedOk = false;
                  _fetchedFor = null;
                  _fetched = const <FetchedModel>[];
                  _fetchNotice = null;
                  _fetchError = null;
                }),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          shown.note ?? context.tr('已选：{0}', [shown.label]),
          style:
              TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
        ),
        const SizedBox(height: 2),
        Text(
          shown.baseUrl,
          style: DshFonts.code(color: DshColors.textFaint, fontSize: 10.5),
        ),
      ],
    );
  }

  /// 一条"已登记"的模型：显示名 + route + 上下文长度 + 设为默认 / 删除。
  ///
  /// [p] 传的是这张卡对应的**内置预设**（[ModelProvider]）；删除时要落盘的是
  /// 配置里那个 [ProviderSpec]（拿不到就按预设现造一个，语义一样）。
  Widget _registeredModelRow(ModelProvider p, ModelSpec m) {
    final isDefault = (_cfg.selected ?? '').trim() == m.route;
    final ctx = formatContextLength(m.context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Icon(
            isDefault
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 14,
            color: isDefault ? DshColors.accent : DshColors.textFaint,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDefault ? DshColors.accent : DshColors.text,
                    fontSize: 12,
                    fontWeight: isDefault ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                Text(
                  <String>[
                    m.route,
                    if (ctx.isNotEmpty) ctx,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      DshFonts.code(color: DshColors.textFaint, fontSize: 10),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: (isDefault || _anyBusy)
                ? null
                : () => _setDefaultRoute(m.route),
            child: Text(
              isDefault ? context.tr('默认') : context.tr('设为默认'),
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
          IconButton(
            tooltip: context.tr('删除这条模型'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.delete_outline, size: 16, color: DshColors.err),
            onPressed: _anyBusy ? null : () => _deleteModel(_specFor(p), m),
          ),
        ],
      ),
    );
  }

  /// 一个内置厂家在 `models.json` 里的那条记录（没写过就按预设现造）。
  ProviderSpec _specFor(ModelProvider p) =>
      _cfg.providerOf(p.id) ??
      ConfiguredModels.provider(
        id: p.id,
        label: p.name,
        baseUrl: _rtOf(p).baseUrl,
      );

  bool get _anyBusy =>
      _poolBusy || _cBusy || _deleting || _rt.values.any((r) => r.busy);

  // ------------------------------------------------- 获取模型 / 加入我的模型

  Future<void> _fetchModels(ModelProvider p) async {
    final rt = _rtOf(p);
    if (rt.busy) return;
    final key = await _effectiveKey(p.id, _keyCtrl(p.id));
    if (!mounted) return;
    if (key.isEmpty) {
      setState(() {
        _fetchedFor = p.id;
        _fetched = const <FetchedModel>[];
        _fetchNotice = null;
        _fetchError = ApiErrorText(
          zh: context.tr(
              '获取模型列表需要 API Key：先在上面填好 Key 再点「获取模型」。（实测这四家的 /models 都要鉴权，不带 Key 一律 401。）'),
        );
      });
      return;
    }
    setState(() {
      rt.busy = true;
      _fetchedFor = p.id;
      _fetched = const <FetchedModel>[];
      _fetchError = null;
      _fetchNotice = null;
      _picked.clear();
    });
    final result = await fetchModelList(
      provider: _draft(p, rt.baseUrl),
      apiKey: key,
    );
    if (!mounted) return;
    setState(() {
      rt.busy = false;
      if (result.ok) {
        _fetched = result.models;
        _fetchNotice = context.tr(
            '拉到 {0} 个模型 —— 勾好再一次性加入，不会有上限、也不会顶掉别家。', [result.models.length]);
      } else {
        _fetchError = result.error;
      }
    });
    debugPrint(
      '[dsh-model-panel] 获取模型：厂家=${p.id} 结果=${result.ok ? '成功 ${result.models.length} 个' : '失败 ${result.error?.zh ?? ''}'}',
    );
  }

  /// 把勾选的模型**一次性** upsert 进 models.json，并立刻通知会话侧。
  Future<void> _addPicked(ModelProvider p) async {
    final rt = _rtOf(p);
    if (rt.busy || _picked.isEmpty) return;
    setState(() => rt.busy = true);
    final old = ConfiguredModels.readConfig(widget.filesDir);
    final before = old.models.where((m) => m.provider == p.id).length;
    // 保存顺序也按「free 优先」——`models.json` 里的顺序就是界面上看到的顺序。
    final add = sortModelsFreeFirst(
      <ModelSpec>[
        for (final f in _fetched)
          if (_picked.contains(f.id) &&
              !old.models.any((m) => m.provider == p.id && m.id == f.id))
            ModelSpec(
                provider: p.id,
                id: f.id,
                name: f.label,
                context: f.contextLength),
      ],
      idOf: (m) => m.id,
      nameOf: (m) => m.name,
    );
    final next = _upsertProvider(
      old: old,
      spec: ConfiguredModels.provider(
        id: p.id,
        label: p.name,
        baseUrl: rt.baseUrl,
      ),
      models: <ModelSpec>[
        for (final m in old.models)
          if (m.provider == p.id) m,
        ...add,
      ],
      preferSelected: old.selected,
    );
    await ConfiguredModels.saveConfig(filesDir: widget.filesDir, config: next);
    final after = next.models.where((m) => m.provider == p.id).length;
    debugPrint(
      '[dsh-model-panel] 「加入我的模型」已写盘：厂家=${p.id} $before→$after 个模型；'
      '全文 ${next.providers.length} 个厂家 / ${next.models.length} 个模型 / '
      '${next.groups.length} 个轮换池',
    );
    // 让会话侧立刻看见（重读 models.json + 重写 overlay + 重建 runtime）
    await widget.onModelChanged();
    await _syncLegacyKeys(next);
    debugPrint('[dsh-model-panel] onModelChanged 已返回（overlay 已重写、会话已重读清单）');
    if (!mounted) return;
    setState(() {
      rt.busy = false;
      rt.noticeOk = true;
      rt.error = null;
      rt.notice = add.isEmpty
          ? context.tr('勾选的这些已经在「我的模型」里了，没有重复写。')
          : context.tr(
              '已加入 {0} 个模型（这家现在共 {1} 个）—— 会话的模型面板里立刻能选。', [add.length, after]);
      _picked.clear();
      _fetchNotice = null;
    });
    await _reload();
  }

  // -------------------------------------------------「测试并保存」（核心链路）

  /// 内置厂家：填 Key → 测试并保存。数据流见类注释（Key → 模型 → 落盘 → 通知 → 测试）。
  Future<void> _testAndSave(ModelProvider p) async {
    final rt = _rtOf(p);
    if (rt.busy) return;
    final pid = p.id;
    final base = rt.baseUrl;
    // Key 输入框**刻意不回显**安全区里的值（只装用户这次敲的）。所以这里留空时
    // 回落到安全区里已经存好的那把 —— 与「获取模型」的 [_effectiveKey] 同一口径。
    //
    // 为什么必须回落：用户重开这张卡再点「测试并保存」是很自然的动作（比如想在
    // 会话里看到这家），此时输入框必然是空的。把空串直接当"没填 Key"就会把一个
    // 已经配好的用户挡在一个他没法照做的提示上 —— 那正是"我明明填了却用不了"的
    // 那一类死路。
    final typed = _keyCtrl(pid).text.trim();
    final key =
        typed.isNotEmpty ? typed : (await ProviderKeys.read(pid))?.trim() ?? '';
    // ⚠️ 上面那行是 await（读安全区）—— 审计列的 4 处缺失 mounted 守卫之一。
    // 不补的话：用户点了按钮就切走 → dispose 之后下面两个 setState 都会抛。
    if (!mounted) return;
    final usingStored = typed.isEmpty && key.isNotEmpty;
    if (key.isEmpty) {
      setState(() {
        rt.notice = null;
        rt.error = ApiErrorText(
          zh: context.tr(
              '请先填 API Key 再点「测试并保存」—— 安全区里也还没有这一家的 Key。这一家的模型列表与对话都要求鉴权，不带 Key 一律 401。'),
        );
      });
      return;
    }

    setState(() {
      rt.busy = true;
      rt.error = null;
      rt.notice = null;
    });
    debugPrint('[dsh-model-panel] 测试并保存开始：厂家=$pid 端点=$base');

    // ① Key 只进系统安全区。
    await ProviderKeys.write(pid, key);
    debugPrint('[dsh-model-panel] Key 已写入安全区：厂家=$pid'
        '（不进 models.json、不进日志）');

    final old = ConfiguredModels.readConfig(widget.filesDir);
    final before = old.models.where((m) => m.provider == pid).length;

    // ② 决定这家要有哪些模型。
    //
    // 先剔掉"不该进会话"的条目（目前只有 Agnes 的图像 / 视频模型，见 [_isChatModel]）。
    // 老版本可能已经把它们的 id 写进 `models.json` 了，这一步顺手把那种残留清掉。
    var mine = <ModelSpec>[
      for (final m in old.models)
        if (m.provider == pid && _isChatModel(pid, m.id)) m,
    ];
    var source = mine.isNotEmpty ? 'keep' : '';
    var listed = 0;
    var hidden = 0;
    ApiErrorText? listErr;
    // ⚠️ 2026-10-17 用户反复反馈「go 拉取的模型明显不对 / 拉取的少」，根因就在下一行：
    //    原来只有 `mine.isEmpty`（一个模型都没有）时才去拉真实清单；而卡片一打开往往
    //    已经带着**预置建议模型**（`p.exampleModels`，只有几个），于是"测试并保存"
    //    永远用那几个预置的，用户看到的就是"这么少、明显不对"。
    //    改法：如果现在登记的**看起来就是预置清单**，先拉一次真实的再覆盖；
    //    用户自己勾过的（不等于预置）则保持不动，免得把他的选择冲掉。
    final looksLikePreset = mine.isNotEmpty &&
        mine.length <= p.exampleModels.length &&
        mine.every((m) => p.exampleModels.contains(m.id));
    if (looksLikePreset) {
      debugPrint('[dsh-model-panel] 厂家=$pid 当前是预置模型（${mine.length} 个）→ 先拉真实清单');
    }
    if (mine.isEmpty || looksLikePreset) {
      final r = await fetchModelList(provider: _draft(p, base), apiKey: key);
      final usable = r.ok
          ? <FetchedModel>[
              for (final m in r.models)
                if (_isChatModel(pid, m.id)) m,
            ]
          : const <FetchedModel>[];
      hidden = r.ok ? r.models.length - usable.length : 0;
      if (usable.isNotEmpty) {
        listed = r.models.length;
        // **全部登记，不截断**（用户 2026-10-16：「所有模型全部可以获取」）。
        //
        // 这里以前有个上限（最早 12、后来 40），理由是"聚合端点几百个会把选择器撑爆"。
        // 用户明确要全部之后把上限去掉了 —— 模型多时的可读性交给**排序**
        // （带 free 的排前面，见 data/model_order.dart）与选择器自身的滚动，
        // 而不是把模型藏起来、让人以为自己账号里没有。
        mine = sortModelsFreeFirst(
          <ModelSpec>[
            for (final m in usable)
              ModelSpec(
                  provider: pid,
                  id: m.id,
                  name: m.label,
                  context: m.contextLength),
          ],
          idOf: (m) => m.id,
          nameOf: (m) => m.name,
        );
        source = 'fetched';
      } else {
        // 拉取失败，或者拉回来的**全是**"不该进会话"的模型 → 回退到内置建议模型。
        // 这两种情况在界面上的说法必须分开（一个是接口没通，一个是接口通了但只有
        // 图像/视频模型），不能都写成"拉取失败"。
        listErr = r.error;
        listed = r.models.length;
        mine = sortModelsFreeFirst(
          <ModelSpec>[
            for (final id in p.exampleModels)
              if (id.trim().isNotEmpty) ModelSpec(provider: pid, id: id.trim()),
          ],
          idOf: (m) => m.id,
        );
        source = mine.isEmpty ? 'none' : (r.ok ? 'preset-filtered' : 'preset');
      }
    }

    // 一条模型都凑不出来 → **不算保存成功**（否则又会出现"填了 Key 但会话里一条都看不到"）。
    if (mine.isEmpty) {
      if (!mounted) return;
      setState(() {
        rt.busy = false;
        rt.notice = null;
        rt.error = ApiErrorText(
          zh: context.tr(
              '没法给「{0}」登记任何模型，所以没有保存成功：自动拉取失败，这家也没有内置建议模型。请点「获取模型」自己勾选，或到「添加模型」里手填 model id。',
              [p.name]),
          detail: listErr?.detail,
        );
      });
      debugPrint('[dsh-model-panel] 厂家=$pid 一个模型都没有 → 未登记、不算保存成功');
      return;
    }

    // ③ upsert（其它厂家 / 它们的模型 / 轮换池一个都不动）。
    //
    // ⚠️ `models:` 只传 `mine`：[_upsertProvider] 会**整段替换**属于这个厂家的
    // 那一段，其它厂家的模型由它自己原样夹带过去。这里要是把别家的也带上，
    // 就等于把它们又追加了一遍（重复条目）。
    final next = _upsertProvider(
      old: old,
      spec: ConfiguredModels.provider(id: pid, label: p.name, baseUrl: base),
      models: mine,
      preferSelected: old.selected,
    );
    await ConfiguredModels.saveConfig(filesDir: widget.filesDir, config: next);
    final after = next.models.where((m) => m.provider == pid).length;
    debugPrint(
      '[dsh-model-panel] models.json 已写入：厂家=$pid $before→$after 个模型'
      '（来源=${_sourceName(source)}）；全文 ${next.providers.length} 个厂家 / '
      '${next.models.length} 个模型 / ${next.groups.length} 个轮换池'
      '（其它厂家与池子一条没动），selected=${next.selected ?? '-'}',
    );

    // ④ 立刻让会话侧看到。
    await widget.onModelChanged();
    await _syncLegacyKeys(next);
    debugPrint('[dsh-model-panel] onModelChanged 已返回：'
        'overlay 已重写、ModelStore 已重读 models.json（会话侧现在就能选）');

    // ⑤ 真打一次最小对话请求（与对话同一条 OpenAI 兼容通道）。
    final test = await testModelConnection(
      baseUrl: base,
      apiKey: key,
      modelId: mine.first.id,
    );
    debugPrint('[dsh-model-panel] 测试结果：厂家=$pid 模型=${mine.first.id} '
        '→ ${test.ok ? '通过 ${test.latencyMs ?? 0}ms' : '失败：${test.error?.zh ?? ''}'}');

    final sourceNote = _sourceNote(source, listed, p, listErr, hidden: hidden);
    // 用了安全区里那把 Key 就如实说一句：用户没在这张卡里重新输入，得让他知道
    // 测试用的是哪把 Key，不然"我没填它怎么测的"会成为新的疑问。
    final keyNote = usingStored ? tr('（这次用的是安全区里已经存好的那把 Key，没有改动它。）') : '';
    if (hidden > 0) {
      debugPrint('[dsh-model-panel] 厂家=$pid 有 $hidden 个模型按内置端口处理、'
          '不登记进会话列表（Agnes 的图像/视频）');
    }
    if (!mounted) return;
    setState(() {
      rt.busy = false;
      rt.testedOk = test.ok;
      rt.latencyMs = test.latencyMs;
      rt.error = test.ok ? null : test.error;
      rt.noticeOk = test.ok;
      rt.notice = (test.ok
              ? context.tr('连通性测试通过（{0}ms）。已把「{1}」的 {2} 个模型登记进来，会话的模型面板里现在就能选。',
                  [test.latencyMs ?? 0, p.name, after])
              : context.tr(
                  '模型已经登记好（{0} 个，会话里能选），但连通性测试没通过 —— 先按下面的原因排查，别急着在新会话里用它。',
                  [after])) +
          sourceNote +
          keyNote;
    });
    await _reload();
  }

  String _sourceName(String source) {
    switch (source) {
      case 'keep':
        return context.tr('沿用这家已登记的模型');
      case 'fetched':
        return context.tr('接口真实返回');
      case 'preset-filtered':
        return context.tr('内置建议模型（接口只返回了图像/视频模型）');
      case 'preset':
        return context.tr('内置建议模型（没拉到真实列表）');
      default:
        return source;
    }
  }

  /// 这条模型该不该作为**会话里可选的一项**登记进 `models.json`。
  ///
  /// 现在只有一条规则，但它是用户点名的要求：Agnes 的**图像 / 视频**模型是
  /// **内置端口**（`AgnesBuiltin.imageModel` / `videoModel`，生成图片/视频时由
  /// 工具箱自动调用）——「图形和视频已经内置端口，不需要显示出来」。
  ///
  /// 为什么必须在这里挡：Agnes 的 `/models` 一旦真返回了这两个 id，
  /// 「测试并保存」会把它们原样写进 `models.json`，于是它们就出现在**会话的模型
  /// 面板**里 —— 用户要求隐藏的东西被塞了回去，选中还必然聊不了天
  /// （它们不走 `/chat/completions`，而连通性测试用的正是这个模型名）。
  ///
  /// 判定故意写得宽一点（含 `image` / `video` 都挡），这样官方以后换成
  /// `agnes-image-3` 这种新名字也照样挡住，不会悄悄漏回来。
  ///
  /// ⚠️ 规则本体**不在这里** —— 已上提到 `data/chat_model_rule.dart` 的
  /// [isChatModelFor]，因为「提示词专家」那边也必须用**同一份**规则
  /// （它挑的是**已经在** `models.json` 里的模型，本页这条只管"写进去"）。
  /// 两边各写一套的话，一边改了另一边忘，就会重新出现
  /// "清单里有媒体模型 → 挑中 → 上游 400"（用户 2026-10-12 报的那条）。
  bool _isChatModel(String providerId, String modelId) =>
      isChatModelFor(providerId, modelId);

  /// 「这些模型是哪儿来的」必须如实写在界面上 —— 别让用户以为预置建议也是真拉到的。
  String _sourceNote(
    String source,
    int listed,
    ModelProvider p,
    ApiErrorText? listErr, {
    int hidden = 0,
  }) {
    if (source == 'keep') return '';
    // 被过滤掉的那些必须交代清楚，否则用户会以为"接口一共就返回了这么几个模型"。
    final hiddenNote = hidden <= 0
        ? ''
        : context.tr(
            '另外接口返回的 {0} 个是图像/视频模型 —— 那些端口是内置的（生成图片/视频时自动调用），不列进会话的模型列表。',
            [hidden]);
    if (source == 'fetched') {
      // 全部登记之后就没有"只登记前 N 个"那种说法了；文案沿用原来那句
      // （"共 {0} 个"在不再截断之后本身就意味着"全部"），免得为一个分支新加四语翻译。
      final head = context.tr('（模型清单来自接口真实返回，共 {0} 个。）', [listed]);
      return '$head$hiddenNote';
    }
    if (source == 'preset-filtered') {
      return context.tr(
          '（注意：接口确实打通了，但它返回的 {0} 个模型全是图像/视频模型 —— 那些端口是内置的、不列进会话；这里登记的是预置文本模型 {1}。）',
          [listed, p.exampleModels.join('、')]);
    }
    if (source == 'preset') {
      return context.tr(
          '（注意：自动拉取模型列表失败了{0}，这里登记的是这家的预置建议模型 {1} —— 不一定等于你账号下真实可用的清单。填好 Key 后点「获取模型」可以拉真实的。）',
          [
            listErr == null ? '' : '（${listErr.headline}）',
            p.exampleModels.join('、')
          ]);
    }
    return '';
  }

  // ------------------------------------------------------------------ 添加模型

  Widget _addModelSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHead(
          context.tr('添加模型'),
          context.tr('其它大模型：自己填 Base URL 与 model id'),
          trailing: TextButton.icon(
            onPressed: _cBusy
                ? null
                : () => setState(() {
                      _addOpen = !_addOpen;
                      if (!_addOpen) {
                        _cFetched = const <FetchedModel>[];
                        _cPicked.clear();
                        _cError = null;
                        _cNotice = null;
                      }
                    }),
            icon: Icon(_addOpen ? Icons.expand_less : Icons.expand_more,
                size: 18),
            label: Text(_addOpen ? context.tr('收起') : context.tr('展开')),
          ),
        ),
        if (!_addOpen)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              context.tr(
                  '默认收起 —— 上面这几家内置厂家之外的服务商（自建端点、其它云厂商）点右上「展开」再填。这里可以手填 Base URL，因为它不是内置厂家。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.6),
            ),
          )
        else ...[
          const SizedBox(height: 12),
          _customForm(),
        ],
      ],
    );
  }

  /// 当前表单"最终会用哪个 provider id" —— **推导与保存走同一个函数**
  /// （[ConfiguredModels.uniqueProviderId]），不许两套规则。
  String _previewProviderId() {
    final label = _cLabel.text.trim();
    final raw = _cId.text.trim();
    return ConfiguredModels.uniqueProviderId(
      raw.isEmpty ? (label.isEmpty ? 'custom' : label) : raw,
      taken: _takenProviderIds(),
    );
  }

  /// 已经被占用的 provider id（现有厂家 + 保留名）。
  Set<String> _takenProviderIds() => <String>{
        for (final p in _cfg.providers) p.id,
        // 这两个是保留名：`rotate` 被轮换组占用，`local` 是本机模型的虚拟厂家。
        ConfiguredModels.rotateProviderId,
        LocalModelSpec.providerId,
      };

  /// **实时显示**"现在这样填，最终会用哪个 id"。
  ///
  /// 为什么必须有（2026-10-12 别人那份 v0.57 日志的教训）：这个框的说明写着
  /// 「留空就按厂家名生成，例如 qwen」—— 而**纯中文名字推不出字母**，
  /// 老逻辑会兜成固定的 `provider`，再加一家纯中文的厂家 **id 就撞了**
  /// （models.json 里互相覆盖，真丢数据）。光改推导不够：
  /// 用户在下到那一步之前根本看不见 id 到底是什么。
  Widget _cIdPreview(BuildContext context) {
    final raw = _cId.text.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: Text(
        raw.isEmpty
            ? context.tr('留空 → 会生成 provider id「{0}」（中文名推不出字母，所以自动编号）',
                [_previewProviderId()])
            : context.tr('会用 provider id「{0}」', [_previewProviderId()]),
        style: TextStyle(
            color: DshColors.textFaint, fontSize: 10.5, height: 1.45),
      ),
    );
  }

  Widget _customForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _cField(
          controller: _cLabel,
          label: context.tr('厂家名'),
          hint: context.tr('例如 通义千问 / 我的自建端点'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        _cField(
          controller: _cId,
          label: context.tr('provider id（写进 overlay 的 providers.<id>）'),
          hint: context.tr('留空就按厂家名生成，例如 qwen'),
          onChanged: (_) => setState(() {}),
        ),
        _cIdPreview(context),
        const SizedBox(height: 10),
        _cField(
          controller: _cBase,
          label: 'Base URL',
          hint: 'https://api.example.com/v1',
          helper: context.tr('自定义厂家才需要你填地址；内置厂家的地址一律自动用内置值。'),
        ),
        const SizedBox(height: 10),
        _cField(
          controller: _cKey,
          label: 'API Key',
          hint: 'sk-...',
          obscure: true,
          helper: context.tr('只存本机安全区：不写进 models.json、不进日志。'),
        ),
        const SizedBox(height: 10),
        _cField(
          controller: _cModel,
          label: 'model id',
          hint: context.tr('例如 qwen-max（多个用换行分隔）'),
          helper: context.tr('点下面的「获取模型」可以直接勾选。'),
        ),
        const SizedBox(height: 10),
        _cField(
          controller: _cContext,
          label: context.tr('上下文长度（可选）'),
          hint: context.tr('例如 65536'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _cBusy ? null : _fetchCustomModels,
              icon: _cBusy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_outlined, size: 16),
              label: Text(_cBusy ? context.tr('获取中…') : context.tr('获取模型')),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _cBusy ? null : _saveCustom,
                icon: const Icon(Icons.verified_outlined, size: 17),
                label:
                    Text(_cBusy ? context.tr('正在测试并保存…') : context.tr('测试并保存')),
              ),
            ),
          ],
        ),
        if (_cFetched.isNotEmpty) ...[
          const SizedBox(height: 10),
          _fetchedList(
            models: _cFetched,
            onTap: (id) => setState(() {
              if (!_cPicked.add(id)) _cPicked.remove(id);
            }),
            picked: _cPicked,
            already: const <String>{},
          ),
          const SizedBox(height: 6),
          Text(
            context
                .tr('勾选 {0} 个 —— 保存时会和上面手填的 model id 一起登记。', [_cPicked.length]),
            style: TextStyle(color: DshColors.textFaint, fontSize: 11),
          ),
        ],
        if (_cError != null) ...[
          const SizedBox(height: 10),
          _errorBox(_cError!),
        ],
        if (_cNotice != null) ...[
          const SizedBox(height: 10),
          _noticeBox(_cNotice!, _cNoticeOk),
        ],
      ],
    );
  }

  Future<void> _fetchCustomModels() async {
    if (_cBusy) return;
    final base = _cBase.text.trim();
    if (base.isEmpty) {
      setState(() {
        _cError = ApiErrorText(zh: context.tr('先填 Base URL 再拉模型列表。'));
      });
      return;
    }
    final key = _cKey.text.trim();
    if (key.isEmpty) {
      setState(() {
        _cError = ApiErrorText(
          zh: context.tr('获取模型列表需要 API Key：自定义端点绝大多数也要鉴权。'),
        );
      });
      return;
    }
    setState(() {
      _cBusy = true;
      _cError = null;
      _cNotice = null;
      _cPicked.clear();
    });
    final result = await fetchModelList(
      provider: ModelProvider(
        id: ConfiguredModels.sanitizeProviderId(
          _cId.text.trim().isEmpty ? _cLabel.text.trim() : _cId.text.trim(),
        ),
        name: _cLabel.text.trim().isEmpty
            ? context.tr('自定义端点')
            : _cLabel.text.trim(),
        baseUrl: base,
        keyHint: 'API Key',
      ),
      apiKey: key,
    );
    if (!mounted) return;
    setState(() {
      _cBusy = false;
      if (result.ok) {
        _cFetched = result.models;
        _cNotice = context.tr('拉到 {0} 个模型，勾选后保存。', [result.models.length]);
        _cNoticeOk = true;
      } else {
        _cError = result.error;
      }
    });
  }

  Future<void> _saveCustom() async {
    if (_cBusy) return;
    final label = _cLabel.text.trim();
    final base = _cBase.text.trim();
    final key = _cKey.text.trim();
    final typedIds = _cModel.text
        .split(RegExp(r'[\n,，;；\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    // ⚠️ id 必须**唯一且可用**（见 `ConfiguredModels.uniqueProviderId` 的注释：
    //    老逻辑对纯中文名字会兜成固定的 `provider`，两家就会互相覆盖、真丢数据）。
    //    要先读配置才知道哪些名字被占了。
    final rawId = _cId.text.trim().isEmpty
        ? (label.isEmpty ? 'custom' : label)
        : _cId.text.trim();
    final old = ConfiguredModels.readConfig(widget.filesDir);
    final pid =
        ConfiguredModels.uniqueProviderId(rawId, taken: _takenProviderIds());
    if (pid != ConfiguredModels.sanitizeProviderId(rawId)) {
      // 如实记一笔：否则用户在 overlay 里找 `provider` 会找不到。
      debugPrint('[dsh-model-panel] provider id 「${ConfiguredModels.sanitizeProviderId(rawId)}」'
          '不可用或已占用 → 自动改用「$pid」');
    }
    final ctx = int.tryParse(_cContext.text.trim());

    final problem = base.isEmpty
        ? context.tr('Base URL 不能为空（自定义厂家必须自己填地址）。')
        : key.isEmpty
            ? context.tr('API Key 不能为空 —— 「测试并保存」要真打一次请求。')
            : (typedIds.isEmpty && _cPicked.isEmpty)
                ? context.tr('至少要有一个 model id：手填一个，或用「获取模型」勾一个。')
                : null;
    if (problem != null) {
      setState(() {
        _cNotice = null;
        _cError = ApiErrorText(zh: problem);
      });
      return;
    }

    setState(() {
      _cBusy = true;
      _cError = null;
      _cNotice = null;
    });
    await ProviderKeys.write(pid, key);
    debugPrint('[dsh-model-panel] 自定义厂家 Key 已写入安全区：provider=$pid');

    final before = old.models.where((m) => m.provider == pid).length;
    final mine = <ModelSpec>[
      for (final m in old.models)
        if (m.provider == pid) m,
      for (final id in typedIds)
        if (!old.models.any((m) => m.provider == pid && m.id == id))
          ModelSpec(provider: pid, id: id, name: id, context: ctx),
      for (final f in _cFetched)
        if (_cPicked.contains(f.id) &&
            !old.models.any((m) => m.provider == pid && m.id == f.id))
          ModelSpec(
              provider: pid, id: f.id, name: f.label, context: f.contextLength),
    ];
    final next = _upsertProvider(
      old: old,
      spec: ConfiguredModels.provider(
        id: pid,
        label: label.isEmpty ? pid : label,
        baseUrl: base,
      ),
      models: mine,
      preferSelected: old.selected,
    );
    await ConfiguredModels.saveConfig(filesDir: widget.filesDir, config: next);
    final after = next.models.where((m) => m.provider == pid).length;
    debugPrint(
      '[dsh-model-panel] 自定义厂家已写盘：provider=$pid $before→$after 个模型；'
      '全文 ${next.providers.length} 个厂家 / ${next.models.length} 个模型 / '
      '${next.groups.length} 个轮换池（其它一条没动）',
    );
    await widget.onModelChanged();
    await _syncLegacyKeys(next);
    debugPrint('[dsh-model-panel] onModelChanged 已返回（overlay 已重写、会话已重读清单）');

    final test = await testModelConnection(
      baseUrl: base,
      apiKey: key,
      modelId: mine.first.id,
    );
    if (!mounted) return;
    setState(() {
      _cBusy = false;
      _cNoticeOk = test.ok;
      _cError = test.ok ? null : test.error;
      _cNotice = test.ok
          ? context.tr('连通性测试通过（{0}ms）。已登记 {1} 个模型，会话里现在能选。',
              [test.latencyMs ?? 0, after])
          : context.tr('模型已经登记好（{0} 个，会话里能选），但连通性测试没通过 —— 见下面的原因。', [after]);
    });
    await _reload();
  }

  // ------------------------------------------------------------------ 轮换池

  Widget _poolSection() {
    // 轮换池被单独做成设置页的一个板块时（`showModels == false`），外层
    // `_CollapsibleSection` 已经给了「模型轮换池」标题与折叠箭头 ——
    // 这里就**只出内容**，不再重复一个标题行和一套展开/收起。
    if (!widget.showModels) return _poolBody();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHead(
          context.tr('模型轮换池'),
          context.tr('几个模型排成一队：前一个不可用就自动换下一个'),
          trailing: TextButton.icon(
            onPressed: () => setState(() => _poolOpen = !_poolOpen),
            icon: Icon(_poolOpen ? Icons.expand_less : Icons.expand_more,
                size: 18),
            label: Text(_poolOpen ? context.tr('收起') : context.tr('展开')),
          ),
        ),
        if (!_poolOpen)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _cfg.groups.isEmpty
                  ? context.tr('默认收起 —— 点右上「展开」看它是什么、怎么把模型放进去。')
                  : context.tr('共 {0} 个：{1} —— 点右上「展开」看内容。', [
                      _cfg.groups.length,
                      _cfg.groups.map((g) => g.name).join('、')
                    ]),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.6),
            ),
          )
        else ...[
          const SizedBox(height: 10),
          _poolBody(),
        ],
      ],
    );
  }

  /// 轮换池的正文 —— 标题与折叠之外的部分都在这里（独立板块模式下只渲染它）。
  Widget _poolBody() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_poolLocalMigrated != null) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: DshColors.surfaceHigh,
                borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                border: Border.all(color: DshColors.line, width: 0.8),
              ),
              child: Text(
                context.tr(
                    '已把本机模型移出轮换池：{0}。本机模型只在手机上跑，不进池子（你的要求）。',
                    [_poolLocalMigrated!]),
                style: TextStyle(
                    color: DshColors.textDim, fontSize: 11, height: 1.5),
              ),
            ),
          ],
          _poolExplain(),
          const SizedBox(height: 14),
          if (_cfg.groups.isEmpty)
            Text(
              context.tr('还没有轮换池。'),
              style: TextStyle(color: DshColors.textDim, fontSize: 12),
            )
          else
            for (final g in _cfg.groups) _poolCard(g),
          if (_poolFormOpen) ...[
            const SizedBox(height: 2),
            _poolForm(),
          ],
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: _poolBusy ? null : _beginAddPool,
            icon: const Icon(Icons.add, size: 17),
            label: Text(context.tr('+ 新建轮换池')),
          ),
          const SizedBox(height: 18),
          _poolModelPicker(),
        ],
      );

  /// 「轮换池是干什么的」——用户点名要求把这件事说清楚。
  ///
  /// 下面这段是照着 `assets/toolbox/rotate-proxy.mjs` 的真实实现写的：
  /// 按顺序尝试成员，只有上游失败（429 / 5xx / 连不上 / 等响应头超时）才换下一个；
  /// **一旦开始把流式响应下发就不再切换**（响应头已经发出去了，协议上做不到），
  /// 全部成员都失败才把错误抛回会话。不许写成"永久容错""失败必切换"。
  Widget _poolExplain() => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: DshColors.accentDim,
          borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
          border: Border.all(
              color: DshColors.accent.withValues(alpha: 0.5), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr(
                  '轮换池 = 把几个模型排成一队：前一个被限流（429）或不可用时，自动换下一个，直到有一个能答。池子本身不存 Key，用的是各厂家各自的 Key。'),
              style:
                  TextStyle(color: DshColors.text, fontSize: 12, height: 1.65),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr(
                  '真实行为（本地轮换代理）：按池子里的顺序依次尝试，只有上游失败（429 限流 / 5xx / 连不上 / 等响应头等到超时）才换下一个 —— 流式响应一旦开始下发就不再切换（HTTP 响应头已经发出去，这是协议本身的约束，不是偷懒）；全部成员都失败，才会把错误抛回会话。它还会记住每个池子"上次成功"的那个成员，下次先从它开始试。'),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 11, height: 1.6),
            ),
            const SizedBox(height: 6),
            DshRichText(
              context.tr('池子在会话的模型面板里就是一项，名字就是池名（数据上是 `rotate/<池名>`）。'),
              style: DshFonts.code(color: DshColors.textFaint, fontSize: 10),
            ),
          ],
        ),
      );

  Widget _poolCard(RotationGroupSpec g) {
    final isDefault = (_cfg.selected ?? '').trim() == g.route;
    final editing = _poolFormOpen && _poolEditing == g.name;
    final open = _openPoolCard == g.name;
    // 正在编辑这个池子时，展示的是**表单里那份暂存的有序成员**。
    final members = editing ? _poolMembers : g.members;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(11, 9, 8, 6),
      decoration: BoxDecoration(
        color: DshColors.surfaceHigh,
        borderRadius: BorderRadius.circular(DshMetrics.radius(11)),
        border: Border.all(
          color: editing ? DshColors.accent : DshColors.line,
          width: editing ? 1 : 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: context.tr('轮换池 {0}，{1} 个模型，{2}',
                [g.name, g.members.length, open ? '收起' : '展开']),
            container: true,
            child: InkWell(
              onTap: () => setState(() => _openPoolCard = open ? null : g.name),
              child: Row(
                children: [
                  Icon(
                    open ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: open ? DshColors.accent : DshColors.textDim,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.autorenew,
                    size: 14,
                    color: isDefault ? DshColors.accent : DshColors.textDim,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isDefault ? DshColors.accent : DshColors.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _pill(context.tr('{0} 个模型', [g.members.length])),
                  if (isDefault)
                    _pill(context.tr('默认'), color: DshColors.accent),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
          if (open && editing) ...[
            const SizedBox(height: 6),
            Text(
              context.tr('正在下面的「编辑轮换池」表单里改成员 —— 改完点「保存轮换池」。'),
              style:
                  TextStyle(color: DshColors.accent, fontSize: 11, height: 1.5),
            ),
          ] else if (open) ...[
            const SizedBox(height: 6),
            if (members.isEmpty)
              Text(
                context.tr('这个池子一个成员都没有 —— 在模型面板里选中它会直接失败，建议放进一两个模型或删掉它。'),
                style:
                    TextStyle(color: DshColors.err, fontSize: 11, height: 1.5),
              )
            else
              for (var i = 0; i < members.length; i++)
                _poolMemberRow(i, members[i], editable: editing),
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton(
                  onPressed: (isDefault || _anyBusy)
                      ? null
                      : () => _setDefaultRoute(g.route),
                  child: Text(
                    isDefault ? context.tr('默认') : context.tr('设为默认'),
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
                const Spacer(),
                if (!editing)
                  TextButton.icon(
                    onPressed: _anyBusy ? null : () => _editPool(g),
                    icon: Icon(Icons.edit_outlined,
                        size: 15, color: DshColors.textDim),
                    label: Text(context.tr('编辑成员'),
                        style: const TextStyle(fontSize: 11.5)),
                  ),
                TextButton.icon(
                  onPressed: _anyBusy ? null : () => _confirmDeletePool(g),
                  icon: Icon(Icons.delete_outline,
                      size: 15, color: DshColors.err),
                  label: Text(context.tr('删除'),
                      style: const TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _poolMemberRow(int index, String route, {required bool editable}) {
    final m = _cfg.modelOfRoute(route);
    final label = m == null
        ? context.tr('{0}（已失效）', [route])
        : '${m.displayName}（${m.provider}）';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: Row(
        children: [
          Text(
            '${index + 1}',
            style: TextStyle(
              color: index == 0 ? DshColors.accent : DshColors.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: DshColors.text, fontSize: 12),
            ),
          ),
          if (editable) ...[
            _miniIcon(
              icon: Icons.arrow_upward,
              tooltip: context.tr('上移（会更早被尝试）'),
              onTap: index == 0 ? null : () => _movePoolMember(index, -1),
            ),
            _miniIcon(
              icon: Icons.arrow_downward,
              tooltip: context.tr('下移（会更晚被尝试）'),
              onTap: index == _poolMembers.length - 1
                  ? null
                  : () => _movePoolMember(index, 1),
            ),
            _miniIcon(
              icon: Icons.close,
              tooltip: context.tr('移出这个池子'),
              color: DshColors.err,
              onTap: () => setState(() {
                _poolMembers.remove(route);
                _poolMessage = null;
              }),
            ),
          ],
        ],
      ),
    );
  }

  /// 展开后底部的「所有已注册的模型」—— **点一下就把它加入池子**（用户原话）。
  ///
  /// 点的落点分四种情况（都在 [_poolTapModel] 里）：
  ///   * 正在编辑/新建池子 → 直接改暂存的有序成员（可上移下移、可移出）；
  ///   * 只有一个池子 → 立刻加进去并落盘（"点一下就能进池子"）；
  ///   * 一个池子都没有 → 开一个新建表单，这个模型当第 1 个成员；
  ///   * 有多个池子 → 弹一个选择框问加进哪个。
  Widget _poolModelPicker() {
    final models = _cfg.models;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ⚠️ 本机模型**不再**出现在候选里（用户 2026-10-12：「轮换池不要进本地大模型」）。
        //    这条**推翻了更早的一个要求** —— 原来这里给本机模型留了一行，
        //    注释写着"用户明确要求能把它加进池子"。
        //    只删候选行不够：老用户的池子里可能**已经**躺着本机成员，
        //    那些由 [_stripLocalFromPools] 在打开本页时真的移出去。
        Text(
          context.tr('所有已注册的模型（点一下就进池子{0}）', [_poolTargetLabel()]),
          style: TextStyle(
            color: DshColors.text,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        if (models.isEmpty)
          Text(
            context.tr('你还没登记任何模型 —— 先在上面「我的模型」里填 Key 并「测试并保存」，再回来把它们放进池子。'),
            style: TextStyle(color: DshColors.err, fontSize: 11.5, height: 1.5),
          )
        else
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              color: DshColors.surfaceHigh,
              borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
              border: Border.all(color: DshColors.line, width: 0.8),
            ),
            // ⚠️ 这层透明 [Material] **不能删**：ListTile 的背景与点击水波画在
            // "最近的 Material 祖先"上，而上面这个 Container 有底色 —— Flutter 会
            // 在 debug 模式下为此 reportError（"ListTile background color or ink
            // splashes may be invisible"）。实测这条报错会让 widget 测试直接失败，
            // 真机 debug 日志里也会刷红字。把 Material 放在容器**里面**就消掉了：
            // 水波画在这层透明 Material 上，正好压在容器底色之上。
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: models.length,
                padding: EdgeInsets.zero,
                itemBuilder: (_, i) {
                  final m = models[i];
                  final inEditing =
                      _poolFormOpen && _poolMembers.contains(m.route);
                  final poolsWithIt = <String>[
                    for (final g in _cfg.groups)
                      if (g.members.contains(m.route)) g.name,
                  ];
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: Icon(
                      inEditing ? Icons.check_circle : Icons.add_circle_outline,
                      size: 17,
                      color: inEditing ? DshColors.accent : DshColors.textDim,
                    ),
                    title: Text(
                      m.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: DshColors.text, fontSize: 12.5),
                    ),
                    subtitle: Text(
                      <String>[
                        m.route,
                        if (!(_keyReady[m.provider] ?? false))
                          context.tr('这家还没配 Key'),
                        if (poolsWithIt.isEmpty)
                          context.tr('还不在任何池子里')
                        else
                          context.tr('已在池子：{0}', [poolsWithIt.join('、')]),
                      ].join(' · '),
                      maxLines: 2,
                      style: TextStyle(
                        color: DshColors.textFaint,
                        fontSize: 10.5,
                        height: 1.4,
                      ),
                    ),
                    onTap: _poolBusy ? null : () => _poolTapModel(m.route),
                  );
                },
              ),
            ),
          ),
        const SizedBox(height: 6),
        Text(
          context.tr('池子里的顺序 = 尝试顺序：1 先试，失败了再试 2 …… 编辑成员时可以上移下移。'),
          style: TextStyle(
              color: DshColors.textFaint, fontSize: 10.5, height: 1.5),
        ),
      ],
    );
  }

  String _poolTargetLabel() {
    if (_poolFormOpen) {
      final name = _poolName.text.trim();
      return name.isEmpty ? context.tr('（新建的这个）') : '「$name」';
    }
    if (_cfg.groups.length == 1) return '「${_cfg.groups.first.name}」';
    if (_cfg.groups.isEmpty) return context.tr('（会自动开一个新建表单）');
    return context.tr('（会先问加进哪一个）');
  }

  Widget _poolForm() {
    final available = _cfg.models;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
      decoration: BoxDecoration(
        color: DshColors.accentDim,
        borderRadius: BorderRadius.circular(DshMetrics.radius(11)),
        border: Border.all(color: DshColors.accent, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _poolEditing == null
                ? context.tr('新建轮换池')
                : context.tr('编辑轮换池「{0}」', [_poolEditing]),
            style: TextStyle(
              color: DshColors.accent,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _poolName,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              labelText: context.tr('池名'),
              hintText: context.tr('例如 cat'),
              helperText: context.tr('只能用字母、数字和横线；它会作为模型名出现在会话的模型面板里。'),
              helperMaxLines: 2,
              helperStyle: TextStyle(
                  color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
              labelStyle: TextStyle(color: DshColors.textDim, fontSize: 12.5),
              floatingLabelStyle:
                  TextStyle(color: DshColors.accent, fontSize: 12.5),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            context.tr('成员（顺序 = 尝试顺序：1 先试，失败再试 2 ……）'),
            style: TextStyle(
              color: DshColors.text,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          if (_poolMembers.isEmpty)
            Text(
              context.tr('还没放成员 —— 从下面「所有已注册的模型」里点几个。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11.5, height: 1.5),
            )
          else
            for (var i = 0; i < _poolMembers.length; i++)
              _poolMemberRow(i, _poolMembers[i], editable: true),
          if (_poolMessage != null) ...[
            const SizedBox(height: 8),
            _noticeBox(_poolMessage!, _poolOk),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(
                onPressed: _poolBusy ? null : _closePoolForm,
                child: Text(context.tr('取消')),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _poolBusy ? null : _savePool,
                  icon: const Icon(Icons.save_outlined, size: 17),
                  label: Text(
                      _poolBusy ? context.tr('保存中…') : context.tr('保存轮换池')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('可选模型共 {0} 个 —— 在下面的列表里点一下就会加进这里。', [available.length]),
            style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  void _beginAddPool() {
    setState(() {
      _poolOpen = true;
      _poolFormOpen = true;
      _poolEditing = null;
      _poolName.clear();
      _poolMembers = <String>[];
      _poolMessage = null;
      _poolOk = false;
    });
  }

  void _editPool(RotationGroupSpec g) {
    setState(() {
      _poolOpen = true;
      _poolFormOpen = true;
      _poolEditing = g.name;
      _poolName.text = g.name;
      _poolMembers = <String>[...g.members];
      _poolMessage = null;
      _poolOk = false;
      _openPoolCard = g.name;
    });
  }

  void _closePoolForm() {
    setState(() {
      _poolFormOpen = false;
      _poolEditing = null;
      _poolName.clear();
      _poolMembers = <String>[];
      _poolMessage = null;
      _poolOk = false;
    });
  }

  void _movePoolMember(int index, int delta) {
    final to = index + delta;
    if (to < 0 || to >= _poolMembers.length) return;
    setState(() {
      final v = _poolMembers.removeAt(index);
      _poolMembers.insert(to, v);
      _poolMessage = null;
    });
  }

  /// 「所有已注册的模型」里点了一条 route。
  Future<void> _poolTapModel(String route) async {
    if (_poolBusy) return;
    // ⚠️ 本机模型不许进池子（用户 2026-10-12）。候选里已经不列它了，
    //    这里再挡一道：成员行的上移/下移/移出也走同一个函数，
    //    不能出现"候选里没有、但别处还能加进来"。
    if (!_poolAcceptsRoute(route)) {
      _toast(context.tr(
          '本机模型不能进轮换池 —— 它只在你手机上跑，轮换池是给云端模型排队用的。'));
      return;
    }
    // ① 正在编辑/新建 → 直接改暂存成员（可上移下移、可移出）
    if (_poolFormOpen) {
      setState(() {
        if (!_poolMembers.remove(route)) _poolMembers.add(route);
        _poolMessage = null;
      });
      return;
    }
    // ② 只有一个池子 → 点一下就进去并落盘
    if (_cfg.groups.length == 1) {
      final g = _cfg.groups.first;
      if (g.members.contains(route)) {
        _toast(context.tr('「{0}」已经在池子「{1}」里了。', [route, g.name]));
        return;
      }
      await _persistPool(
        name: g.name,
        originalName: g.name,
        members: <String>[...g.members, route],
        why: context.tr('把 {0} 加进池子「{1}」', [route, g.name]),
      );
      return;
    }
    // ③ 一个池子都没有 → 开新建表单，这个模型当第 1 个成员
    if (_cfg.groups.isEmpty) {
      setState(() {
        _poolFormOpen = true;
        _poolEditing = null;
        _poolName.clear();
        _poolMembers = <String>[route];
        _poolOk = true;
        _poolMessage =
            context.tr('已经把「{0}」放进新池子的第 1 位 —— 给池子起个名字（例：cat）再保存。', [route]);
      });
      return;
    }
    // ④ 多个池子 → 问一句加进哪个
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(context.tr('把这个模型放进哪个池子？')),
        children: [
          for (final g in _cfg.groups)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(g.name),
              child:
                  Text(context.tr('{0}（{1} 个成员）', [g.name, g.members.length])),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('__new__'),
            child: Text(context.tr('新建一个池子…')),
          ),
        ],
      ),
    );
    if (!mounted || picked == null) return;
    if (picked == '__new__') {
      setState(() {
        _poolFormOpen = true;
        _poolEditing = null;
        _poolName.clear();
        _poolMembers = <String>[route];
        _poolOk = true;
        _poolMessage = context.tr('已经把「{0}」放进新池子的第 1 位 —— 起个名字再保存。', [route]);
      });
      return;
    }
    final g = _cfg.groups.firstWhere((x) => x.name == picked);
    if (g.members.contains(route)) {
      _toast(context.tr('「{0}」已经在池子「{1}」里了。', [route, g.name]));
      return;
    }
    await _persistPool(
      name: g.name,
      originalName: g.name,
      members: <String>[...g.members, route],
      why: context.tr('把 {0} 加进池子「{1}」', [route, g.name]),
    );
  }

  Future<void> _savePool() async {
    if (_poolBusy) return;
    final name = _poolName.text.trim().toLowerCase();
    final cfg = _cfg;
    if (name.isEmpty) {
      setState(() {
        _poolOk = false;
        _poolMessage = context.tr('池名不能为空 —— 这个名字会当成模型名显示在会话的模型面板里。');
      });
      return;
    }
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(name)) {
      setState(() {
        _poolOk = false;
        _poolMessage = context.tr('池名只能用字母、数字和横线（例：cat、fast-1）。');
      });
      return;
    }
    if (name == ConfiguredModels.rotateProviderId) {
      setState(() {
        _poolOk = false;
        _poolMessage = context.tr('池名不能叫 rotate —— 这个名字被轮换代理自己占用了。');
      });
      return;
    }
    if (cfg.groups.any((g) => g.name == name && g.name != _poolEditing)) {
      setState(() {
        _poolOk = false;
        _poolMessage = context.tr('已经有一个叫「{0}」的池子了，换个名字。', [name]);
      });
      return;
    }
    // 成员只保留"现在真实存在"的模型（表单开着的期间模型可能被删掉）
    final members = <String>[
      for (final r in _poolMembers)
        if (cfg.models.any((m) => m.route == r)) r,
    ];
    if (members.isEmpty) {
      setState(() {
        _poolOk = false;
        _poolMessage = context.tr('至少要放 1 个成员 —— 池子里一个模型都没有的话，选中它必然失败。');
      });
      return;
    }
    await _persistPool(
      name: name,
      originalName: _poolEditing,
      members: members,
      why: context.tr('轮换池已保存'),
    );
  }

  /// 池子的落盘：`readConfig` → 只改 `groups`（+ 必要时修 selected）→ `saveConfig`
  /// → `onModelChanged` → 重读。**providers / models 一律不碰。**
  Future<void> _persistPool({
    required String name,
    required String? originalName,
    required List<String> members,
    required String why,
  }) async {
    if (_poolBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _poolBusy = true);
    try {
      final cfg = ConfiguredModels.readConfig(widget.filesDir);
      final at = originalName == null
          ? -1
          : cfg.groups.indexWhere((g) => g.name == originalName);
      // 落盘前**再滤一次**：任何路径都不许把本机模型写进池子（用户 2026-10-12）。
      final safe = _stripLocalFromPool(members);
      if (safe.length != members.length) {
        debugPrint('[dsh-model-panel] 落盘前剔掉本机成员：'
            '${members.where((m) => !_poolAcceptsRoute(m)).join('、')}');
      }
      final spec = RotationGroupSpec(name: name, members: safe);
      final groups = <RotationGroupSpec>[
        for (var i = 0; i < cfg.groups.length; i++)
          if (i == at) spec else cfg.groups[i],
        if (at < 0) spec,
      ];
      var sel = cfg.selected;
      if (originalName != null &&
          originalName != name &&
          sel == '${ConfiguredModels.rotateProviderId}/$originalName') {
        sel = spec.route;
      }
      final next = _withSelection(
        providers: cfg.providers,
        models: cfg.models,
        groups: groups,
        keep: sel,
      );
      await ConfiguredModels.saveConfig(
          filesDir: widget.filesDir, config: next);
      debugPrint(
        '[dsh-model-panel] $why：池=$name 成员=${members.join(' → ')}；'
        '全文 ${next.providers.length} 个厂家 / ${next.models.length} 个模型 / '
        '${next.groups.length} 个轮换池，selected=${next.selected ?? '-'}',
      );
      await widget.onModelChanged();
      await _syncLegacyKeys(next);
      debugPrint('[dsh-model-panel] onModelChanged 已返回（overlay 已重写、会话已重读清单）');
      if (!mounted) return;
      setState(() {
        _poolBusy = false;
        _poolFormOpen = false;
        _poolEditing = null;
        _poolName.clear();
        _poolMembers = <String>[];
      });
      messenger.showSnackBar(
        SnackBar(
            content: Text(context
                .tr('轮换池「{0}」已保存：{1} 个成员按顺序依次尝试', [name, members.length]))),
      );
      await _reload();
    } catch (e) {
      final t = translateException(e);
      debugPrint('[dsh-model-panel] 保存轮换池失败：${t.zh}');
      if (mounted) {
        setState(() {
          _poolBusy = false;
          _poolOk = false;
          _poolMessage = context.tr('保存失败：{0}', [t.zh]);
        });
      }
    }
  }

  Future<void> _confirmDeletePool(RotationGroupSpec g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('删除轮换池「{0}」？', [g.name])),
        content: Text(
          context.tr('只会删掉这个池子（{0} 个成员）和它在模型面板里的那一项；成员模型本身与各厂家的 Key 都不动。',
              [g.members.length]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_poolBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _poolBusy = true);
    try {
      final cfg = ConfiguredModels.readConfig(widget.filesDir);
      final next = _withSelection(
        providers: cfg.providers,
        models: cfg.models,
        groups: <RotationGroupSpec>[
          for (final x in cfg.groups)
            if (x.name != g.name) x,
        ],
        keep: cfg.selected,
      );
      await ConfiguredModels.saveConfig(
          filesDir: widget.filesDir, config: next);
      debugPrint('[dsh-model-panel] 已删除轮换池「${g.name}」');
      await widget.onModelChanged();
      await _syncLegacyKeys(next);
      if (mounted && _poolEditing == g.name) {
        setState(() {
          _poolFormOpen = false;
          _poolEditing = null;
          _poolName.clear();
          _poolMembers = <String>[];
        });
      }
      messenger
          .showSnackBar(SnackBar(content: Text(tr('已删除轮换池「{0}」', [g.name]))));
      await _reload();
    } catch (e) {
      debugPrint('[dsh-model-panel] 删除轮换池失败：$e');
      messenger.showSnackBar(SnackBar(content: Text(tr('删除失败：{0}', [e]))));
    } finally {
      if (mounted) setState(() => _poolBusy = false);
    }
  }

  // ------------------------------------------------------- 模型/默认项的维护

  Future<void> _setDefaultRoute(String route) async {
    if (route.trim().isEmpty || _anyBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    final old = ConfiguredModels.readConfig(widget.filesDir);
    final known = old.models.any((m) => m.route == route) ||
        old.groups.any((g) => g.route == route);
    if (!known) {
      messenger.showSnackBar(
        SnackBar(content: Text(context.tr('这一项已经不在配置里了，请重新选择。'))),
      );
      await _reload();
      return;
    }
    await ConfiguredModels.saveConfig(
      filesDir: widget.filesDir,
      config: _withSelection(
        providers: old.providers,
        models: old.models,
        groups: old.groups,
        keep: route,
      ),
    );
    debugPrint('[dsh-model-panel] 已切换默认：$route');
    await widget.onModelChanged();
    await _syncLegacyKeys(ConfiguredModels.readConfig(widget.filesDir));
    if (!mounted) return;
    messenger.showSnackBar(
        SnackBar(content: Text(context.tr('已切换默认模型：{0}', [route]))));
    await _reload();
  }

  /// 删掉一条模型（这个厂家因此一条不剩时，连它的 provider 一起删）。
  Future<void> _deleteModel(ProviderSpec p, ModelSpec m) async {
    if (_anyBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _deleting = true);
    try {
      final old = ConfiguredModels.readConfig(widget.filesDir);
      final models = <ModelSpec>[
        for (final x in old.models)
          if (x.route != m.route) x,
      ];
      final leftForProvider = models.any((x) => x.provider == p.id);
      final providers = <ProviderSpec>[
        for (final x in old.providers)
          if (leftForProvider || x.id != p.id) x,
      ];
      final pruned = _pruneGroups(old.groups, (r) => r == m.route);
      final next = _withSelection(
        providers: providers,
        models: models,
        groups: pruned.groups,
        keep: old.selected,
      );
      if (!leftForProvider) await ProviderKeys.delete(p.id);
      await ConfiguredModels.saveConfig(
          filesDir: widget.filesDir, config: next);
      debugPrint(
        '[dsh-model-panel] 已删除模型 ${m.route}'
        '（厂家${leftForProvider ? '保留' : '一并删除'}；'
        '${pruned.touched.isEmpty ? '池子未受影响' : '受影响的池子：${pruned.touched.join('、')}'}）',
      );
      await widget.onModelChanged();
      await _syncLegacyKeys(next);
      final note = StringBuffer(tr('已删除模型 {0}', [m.route]));
      if (!leftForProvider) {
        note.write(tr('；「{0}」已没有模型，厂家与它的 Key 一起删掉了', [p.label]));
      }
      if (pruned.removed.isNotEmpty) {
        note.write(
            tr('；轮换池 {0} 因此一个成员都不剩，整池一起删掉了', [pruned.removed.join('、')]));
      }
      messenger.showSnackBar(SnackBar(content: Text(note.toString())));
      await _reload();
    } catch (e) {
      debugPrint('[dsh-model-panel] 删除模型失败：$e');
      messenger.showSnackBar(SnackBar(content: Text(tr('删除失败：{0}', [e]))));
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 配置读坏了：**先说这件事**，再谈"还没配置"（P0-9）。
        // 不然用户看到的是"我的模型没了"，而真相是"文件坏了、已另存备份"。
        if (_readError != null) ...[
          _noticeBox(_readError!, false),
          const SizedBox(height: 16),
        ],
        if (widget.showModels) ...[
          _myModelsSection(),
          const SizedBox(height: 22),
          _addModelSection(),
        ],
        if (widget.showPool) ...[
          if (widget.showModels) const SizedBox(height: 22),
          _poolSection(),
        ],
      ],
    );
  }

  // ------------------------------------------------------------- 小组件工厂

  /// 区内部的小分节标题：左侧一条青→紫渐变竖条 + 标题 + 说明（+ 可选按钮）。
  ///
  /// ⚠️ 标题外面那层 [Semantics] **不能删**（用户实测反馈："截图上有，但
  /// uiautomator 语义树里读不到「当前模型」「我的模型」"）：这一行是
  /// 「渐变竖条 + 标题 + 一长串说明（+ 可能还有一个按钮）」的复合 Row，
  /// Flutter 不会替这种纯文字行单独产出一个语义节点，于是标题在语义树里
  /// **根本不存在** —— 读屏用户也听不到"这是哪一节"。这里显式补一个
  /// `header: true` 的节点，让无障碍与 uiautomator 都能读到分节标题。
  Widget _sectionHead(String title, String note, {Widget? trailing}) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              gradient: DshColors.grad,
              borderRadius: BorderRadius.circular(DshMetrics.radius(2)),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            header: true,
            container: true,
            label: title,
            excludeSemantics: true,
            child: Text(
              title,
              style: TextStyle(
                color: DshColors.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note,
              style: TextStyle(color: DshColors.textFaint, fontSize: 11),
            ),
          ),
          if (trailing != null) trailing,
        ],
      );

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? null : DshColors.surfaceHigh,
            gradient: selected ? DshColors.grad : null,
            borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
            border: Border.all(
              color: selected ? Colors.transparent : DshColors.line,
              width: 1,
            ),
            boxShadow: selected ? DshColors.accentShadow : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? DshColors.onAccent : DshColors.textDim,
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  /// 小图标按钮：成员行里要放三个，默认 48px 的 IconButton 会把一行挤爆。
  ///
  /// [color] 默认 null → 用当前皮肤的次要文字色。刻意不写成
  /// `Color color = DshColors.textDim`：皮肤是运行时变量，不能当常量默认值。
  Widget _miniIcon({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    Color? color,
  }) {
    final tint = color ?? DshColors.textDim;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(7)),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(
            icon,
            size: 15,
            color: onTap == null ? DshColors.textFaint : tint,
          ),
        ),
      ),
    );
  }

  /// 小药丸标签（Key 状态、成员数、「默认」）。默认灰，语义色由调用方给。
  Widget _pill(String text, {Color? color}) {
    final tint = color ?? DshColors.textDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      margin: const EdgeInsets.only(left: 4),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(DshMetrics.radius(20)),
        border: Border.all(color: tint.withValues(alpha: 0.5), width: 0.7),
      ),
      child: Text(
        text,
        style:
            TextStyle(color: tint, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _noticeBox(String text, bool ok) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: (ok ? DshColors.ok : DshColors.err).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
          border: Border.all(
            color: (ok ? DshColors.ok : DshColors.err).withValues(alpha: 0.5),
            width: 0.8,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: ok ? DshColors.ok : DshColors.err,
            fontSize: 11.5,
            height: 1.55,
          ),
        ),
      );

  Widget _infoBox(String text) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
          border: Border.all(color: DshColors.line, width: 0.8),
        ),
        // 用 DshRichText：这些说明里带 `**…**`（照官方原文抄的），
        // 走普通 Text 会把星号原样显示出来。以前这里靠调用方先过一遍
        // `_plain()` 把标记**删掉**，而别处（更新说明、各页提示）是**渲染**成
        // 粗体 —— 同一类文案两种待遇，就是审计说的"两处口径"。现在统一成渲染。
        child: DshRichText(
          text,
          style: TextStyle(color: DshColors.textDim, fontSize: 11, height: 1.6),
        ),
      );

  Widget _errorBox(ApiErrorText err) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: DshColors.err.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
          border: Border.all(
              color: DshColors.err.withValues(alpha: 0.5), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 15, color: DshColors.err),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    err.headline,
                    style: TextStyle(
                      color: DshColors.err,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
            if (err.retryable) ...[
              const SizedBox(height: 6),
              Text(
                context.tr('这类错误通常过一会儿重试就好。'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11),
              ),
            ],
            if (err.detail != null && err.detail!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              // ⚠️ 透明 Material 不能删：ExpansionTile 内部就是一个 ListTile，
              // 而外面这层 Container 有底色 —— 见 `_poolModelPicker` 里那段注释
              // （debug 模式下会报 "ListTile background color or ink splashes
              // may be invisible"，报错会刷日志、也会让 widget 测试失败）。
              Material(
                type: MaterialType.transparency,
                child: Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      context.tr('技术细节'),
                      style:
                          TextStyle(color: DshColors.textFaint, fontSize: 11),
                    ),
                    children: [
                      SelectableText(
                        err.detail!,
                        style: TextStyle(
                          color: DshColors.textFaint,
                          fontSize: 10.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      );

  /// 「获取模型」拉回来的多选列表（勾选后一次性加入）。
  ///
  /// [models] 由调用方明确传进来：内置卡与「添加模型」各有各的暂存清单，
  /// 不能靠"当前展开的是谁"去猜 —— 猜错就会张冠李戴。
  Widget _fetchedList({
    required List<FetchedModel> models,
    required void Function(String id) onTap,
    required Set<String> picked,
    required Set<String> already,
  }) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        border: Border.all(color: DshColors.line, width: 1),
      ),
      // ⚠️ 透明 Material 不能删（理由同 `_poolModelPicker`：ListTile 在带底色的
      // Container 里会被 debug 模式 reportError）。
      child: Material(
        type: MaterialType.transparency,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: models.length,
          padding: EdgeInsets.zero,
          separatorBuilder: (_, __) =>
              Divider(height: 1, thickness: 1, color: DshColors.line),
          itemBuilder: (_, i) {
            final m = models[i];
            final isPicked = picked.contains(m.id);
            final isAlready = already.contains(m.id);
            final ctx = formatContextLength(m.contextLength);
            return ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.symmetric(horizontal: 6),
              leading: Checkbox(
                value: isPicked || isAlready,
                onChanged: isAlready ? null : (_) => onTap(m.id),
              ),
              title: Text(
                m.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      m.openAiCompatible ? DshColors.text : DshColors.textFaint,
                  fontSize: 13,
                ),
              ),
              // 「可看图」要标出来（用户 2026-10-16 问"deepseek 的视觉模型为什么不抓"）——
              // 视觉能力现在是**并进普通模型**里的（DeepSeek 的 `deepseek-flash` 就是），
              // 不标的话用户根本不知道哪条能收图片。
              subtitle: Text(
                <String>[
                  if (m.acceptsImage) context.tr('可看图'),
                  m.id,
                  if (ctx.isNotEmpty) ctx,
                  if (isAlready) context.tr('已在我的模型里'),
                  if (!m.openAiCompatible)
                    context.tr('仅支持 /messages 协议，本 App 用 OpenAI 兼容协议，选它可能调不通'),
                ].join(' · '),
                maxLines: 2,
                style: DshFonts.code(
                  color: DshColors.textFaint,
                  fontSize: 10.5,
                  height: 1.4,
                ),
              ),
              onTap: isAlready ? null : () => onTap(m.id),
            );
          },
        ),
      ),
    );
  }

  Widget _cField({
    required TextEditingController controller,
    required String label,
    String? hint,
    String? helper,
    bool obscure = false,
    /// 用来**实时刷新**联动显示（例如下面那个"最终会用哪个 provider id"）。
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: !obscure,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        helperStyle:
            TextStyle(color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
        labelStyle: TextStyle(color: DshColors.textDim, fontSize: 12.5),
        floatingLabelStyle: TextStyle(color: DshColors.accent, fontSize: 12.5),
        isDense: true,
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// 下面几个是**纯函数**（不依赖 State）：配置的合并/兜底规则集中在这里，
// 界面代码只负责调用，免得同一个不变量在几处各写一遍。
// ══════════════════════════════════════════════════════════════════════

/// 用新的 providers / models / groups 拼一份配置，并把 `selected` 修到
/// **真实存在**的那一项上。
///
/// 这是"删到空 / 删掉默认项"的安全网：`selected` 指向不存在的 route 时，
/// 对话页会拿一个空路由去跑。失效就顺延到第一个模型，其次第一个轮换池。
ConfiguredConfig _withSelection({
  required List<ProviderSpec> providers,
  required List<ModelSpec> models,
  required List<RotationGroupSpec> groups,
  String? keep,
}) {
  final valid = <String>{
    for (final m in models) m.route,
    for (final g in groups) g.route,
  };
  final cur = (keep ?? '').trim();
  final String? selected = valid.contains(cur)
      ? cur
      : (models.isNotEmpty
          ? models.first.route
          : (groups.isNotEmpty ? groups.first.route : null));
  return ConfiguredConfig(
    version: ConfiguredModels.currentVersion,
    providers: providers,
    models: models,
    groups: groups,
    selected: selected,
  );
}

/// 把「这个厂家 + 它的模型」**upsert** 进整份配置。
///
/// 不变量（这是"配了第二家就把第一家覆盖掉"那个 bug 的正解，别弄丢）：
///   * `providers`：id 相同就**就地替换**（不是追加第二份、也不改名），
///     id 不存在才追加到末尾；
///   * `models`：只替换 `provider == spec.id` 的那一段，
///     **其它厂家的模型原样保留**；
///   * `groups`：**原样透传** —— 轮换池绝不能因为配模型而丢；
///   * `selected`：仍然存在就保留，失效则由 [_withSelection] 顺延。
ConfiguredConfig _upsertProvider({
  required ConfiguredConfig old,
  required ProviderSpec spec,
  required List<ModelSpec> models,
  String? preferSelected,
}) {
  final pid = spec.id;
  final at = old.providers.indexWhere((p) => p.id == pid);
  final providers = <ProviderSpec>[
    for (var i = 0; i < old.providers.length; i++)
      if (i == at) spec else old.providers[i],
    if (at < 0) spec,
  ];
  // 该厂家原有的模型整段换成这次给的；其它厂家的原样夹带过来
  final next = <ModelSpec>[];
  var placed = false;
  for (final m in old.models) {
    if (m.provider == pid) {
      if (!placed) {
        next.addAll(models);
        placed = true;
      }
      continue;
    }
    next.add(m);
  }
  if (!placed) next.addAll(models);
  return _withSelection(
    providers: providers,
    models: next,
    groups: old.groups,
    keep: preferSelected ?? old.selected,
  );
}

/// 本机模型（`local/xxx`）**不许**进轮换池 —— 用户 2026-10-12 的要求。
///
/// 原话：「轮换池不要进本地大模型」。落地口径：轮换池是给**云端**模型排队用的，
/// 本机模型只在手机上跑，把它排进池子既没有意义（它不需要"失败了换一个"），
/// 还会让池子里的云端成员被本机模型拖慢。
///
/// ⚠️ 这条**推翻了更早的一个要求**：旧代码在候选列表里专门给本机模型留了一行，
/// 注释写着「用户明确要求"能把它加进池子"」。所以判断必须**同时**在
/// 候选列表、点击入口、落盘三处生效，并且要把**已经躺在池子里的**真的移出去。
bool _poolAcceptsRoute(String route) =>
    !route.startsWith('${LocalModelSpec.providerId}/');

/// 滤掉一组成员里的本机模型（不改原列表）。
List<String> _stripLocalFromPool(List<String> members) => <String>[
      for (final m in members)
        if (_poolAcceptsRoute(m)) m,
    ];

/// 从**所有**池子里剔掉本机模型 —— 打开本页时做一次，用于收拾老配置。
///
/// 语义与 [_pruneGroups] 一致：剔空的池子**整个删掉**（只留一个成员被剔光的池子
/// 等于"选中就必然失败"），并在提示里如实说清楚动了哪些。
({List<RotationGroupSpec> groups, List<String> touched, int removed})
    _stripLocalFromPools(List<RotationGroupSpec> groups) {
  final touched = <String>[];
  var removed = 0;
  final out = <RotationGroupSpec>[];
  for (final g in groups) {
    final keep = _stripLocalFromPool(g.members);
    if (keep.length == g.members.length) {
      out.add(g);
      continue;
    }
    if (keep.isEmpty) {
      removed++;
      touched.add('${g.name}（整个池子只剩本机模型，已删）');
      continue;
    }
    removed += g.members.length - keep.length;
    touched.add('${g.name}（${g.members.length}→${keep.length}）');
    out.add(g.copyWith(members: keep));
  }
  return (groups: out, touched: touched, removed: removed);
}

/// 从所有池子里剔除**已经失效**的成员（模型被删 / 厂家被删时用）。
///
/// 为什么要剔：代理拿到不存在的成员会直接跳过，但界面上留一条"永远不会被尝试"
/// 的成员是骗人的；成员被剔光的池子也只剩"选中就必然失败"，所以连池子一起删掉，
/// 并在提示里如实说清楚。
({List<RotationGroupSpec> groups, List<String> touched, List<String> removed})
    _pruneGroups(
  List<RotationGroupSpec> groups,
  bool Function(String route) dead,
) {
  final touched = <String>[];
  final removed = <String>[];
  final out = <RotationGroupSpec>[];
  for (final g in groups) {
    final keep = <String>[
      for (final m in g.members)
        if (!dead(m)) m,
    ];
    if (keep.length == g.members.length) {
      out.add(g);
      continue;
    }
    if (keep.isEmpty) {
      removed.add(g.name);
      continue;
    }
    touched.add('${g.name}（${g.members.length}→${keep.length}）');
    out.add(g.copyWith(members: keep));
  }
  return (groups: out, touched: touched, removed: removed);
}

/// 把 URL 归一化后比较（去空白、去尾部斜杠、忽略大小写）——
/// 用户手抄的地址常常多个斜杠，不能因为一个 `/` 就认不出是同一档端点。
String _normalizeUrl(String url) {
  final t = url.trim().toLowerCase();
  return t.endsWith('/') ? t.substring(0, t.length - 1) : t;
}


/// 「备用 Key」（多账号）—— Agnes 的生图/生视频专用。
///
/// ## 为什么要有它（用户 2026-10-11 反馈）
///
/// 「Agnes 生图/生视频经常 429 或者排队」。限流与额度是**按账号**算的：
/// 同一个账号下多建几把 Key **共享同一份配额**，加多少都没用；
/// **只有另一个账号的 Key 才能真的加容量** —— 一把被限流时立刻换另一把继续。
/// 所以这个区块必须把"多账号才有用"这句话写在脸上，否则用户会白折腾。
///
/// 主 Key 仍然在「API Key」那一栏（行为完全不变）；这里存的是**额外的**那些。
/// 两者都会注入 node 环境（`AGNES_API_KEY` + `AGNES_API_KEYS`），
/// 由 `assets/toolbox/agnes-retry.mjs` 在 429 时轮换。
///
/// ⚠️ 界面**永不显示**已保存 Key 的内容（安全区里的东西读出来只用来判断"有几把"），
/// 只显示序号 —— 免得录屏/截图把 Key 带出去。
class _BackupKeysBlock extends StatefulWidget {
  const _BackupKeysBlock({required this.providerId});

  final String providerId;

  @override
  State<_BackupKeysBlock> createState() => _BackupKeysBlockState();
}

class _BackupKeysBlockState extends State<_BackupKeysBlock> {
  List<String> _extras = <String>[];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await ProviderKeys.readExtras(widget.providerId);
    if (!mounted) return;
    setState(() {
      _extras = list;
      _loading = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _add() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('添加另一把 Key（另一个账号）')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              context.tr('请填**另一个账号**的 Key —— 同一账号多建几把共享同一份配额，加了也没用。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.45),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctl,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('保存')),
          ),
        ],
      ),
    );
    final typed = ctl.text;
    ctl.dispose();
    if (ok != true) return;
    setState(() => _busy = true);
    final err = await ProviderKeys.addExtra(widget.providerId, typed);
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    // 存储层返回的是**错误码**（那个文件不被 i18n 门禁扫描），文案在这里出。
    final msg = switch (err) {
      null => context.tr('已添加。生图/生视频被限流时会自动换用这一把。'),
      'empty' => context.tr('Key 不能为空'),
      'is-primary' => context.tr('这就是当前那把主 Key，不用再加一遍'),
      'duplicate' => context.tr('这把 Key 已经在列表里了'),
      _ => err,
    };
    _toast(msg);
  }

  Future<void> _remove(int index) async {
    setState(() => _busy = true);
    await ProviderKeys.removeExtra(widget.providerId, index);
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(context.tr('正在读取备用 Key…'),
            style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
        border: Border.all(color: DshColors.line, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.vpn_key_outlined, size: 14, color: DshColors.textDim),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  context.tr('备用 Key（多账号）· 已添加 {0} 把', ['${_extras.length}']),
                  style: TextStyle(
                      color: DshColors.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          DshRichText(
            context.tr('生图/生视频经常遇到 429（限流）或排队时，多一把 Key 就能在被限流时'
                '**自动换另一把**继续。注意：限流按**账号**算 —— **同一个账号**多建几把 Key '
                '共享同一份配额，加了也没用，必须是**另一个账号**的 Key。'),
            style:
                TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.45),
          ),
          if (_extras.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            for (var i = 0; i < _extras.length; i++)
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      context.tr('备用 Key {0}（内容不显示）', ['${i + 2}']),
                      style: TextStyle(color: DshColors.textDim, fontSize: 11),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _remove(i),
                    style: TextButton.styleFrom(foregroundColor: DshColors.err),
                    child: Text(context.tr('删除')),
                  ),
                ],
              ),
          ],
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.add, size: 16),
              label: Text(context.tr('添加另一把 Key')),
            ),
          ),
        ],
      ),
    );
  }
}
