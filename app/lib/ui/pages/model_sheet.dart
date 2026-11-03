import 'package:flutter/material.dart';

import '../../data/configured_models.dart';
import '../../local/local_model_server.dart';
import '../../data/model_catalog.dart';
import '../../state/model_store.dart';
import '../../state/usage_store.dart';
import '../theme/dsh_tokens.dart';

import '../../i18n/dsh_i18n.dart';

/// 模型选择弹层 —— **两级**结构（用户 2026-10-05 的方案）：
///
///   第一级：按**厂家**分组列出（厂家名 + 该厂家已注册的模型数量 +
///   「已配 Key / 未配 Key」状态）；
///   点厂家 → 就地展开第二级：列出这个厂家的模型，**点某个模型 = 选中并使用**。
///
/// **「轮换池」也是一个分组**（名字就叫「轮换池」），点开能看到池子里有哪些模型
/// —— 用户从 0.09 就提过"组要能显示在模型列表里"，这里不能丢。数据上池子还是
/// `rotate/<池名>`，对 DSH 来说它就是一个普通的 provider + model。
///
/// ## 不能弄坏的两件事
///
///   1. 选中仍然是走 `store.selectModel(entry)` + `Navigator.pop(entry)`：
///      对话页拿到它之后走 `_switchModelInPlace`（ACP
///      `session/set_config_option`）**在会话内切换、不重建会话**（用户第 11 条）。
///      这里只负责"选"，不碰那套逻辑。
///   2. 清单的唯一来源仍然是 `ModelStore`（= 用户自己配的 `<filesDir>/models.json`），
///      **不再**读 `data/model_catalog.dart` 里任何写死的名字。
Future<ModelEntry?> showModelSheet(
  BuildContext context, {
  required ModelStore store,
  UsageStore? usage,
}) {
  return showModalBottomSheet<ModelEntry>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => _ModelSheet(store: store, usage: usage),
  );
}

/// 单行高度（设计稿行距 170 设计像素 ≈ 59dp，实测取 62dp）。
const double _kSheetRowHeight = 62;

/// 第一级（厂家行）的高度：比模型行矮一点，一眼能看出层级。
const double _kGroupRowHeight = 54;

/// 一个**分组**：一个厂家，或者「轮换池」。
class _Group {
  _Group({
    required this.id,
    required this.title,
    required this.entries,
    required this.isPool,
    required this.keyReady,
    this.keyless = false,
  });

  /// 厂家 id / `rotate` / `orphan:<前缀>`。
  final String id;
  final String title;
  final List<ModelEntry> entries;

  /// 这一组是不是「轮换池」。
  final bool isPool;

  /// 这一组里**有没有配过 Key**（池子看它的成员）。
  final bool keyReady;

  /// 这一组的凭据**由 App 自己提供**（免费模型 / 本机模型）。
  ///
  /// 界面据此说「无需 Key」—— 既不显示「未配 Key」（那是错的，它本来就不用配），
  /// 也不显示「已配 Key」（那是假话，用户根本没填过）。见
  /// `ConfiguredModels.appProvidedCredentialIds`。
  final bool keyless;

  /// 这一组在界面上该显示哪句凭据状态。
  String get keyLabel {
    if (keyless) return tr('无需 Key');
    return keyReady ? tr('已配 Key') : tr('未配 Key');
  }

  Color get keyColor {
    if (keyless) return DshColors.accent;
    return keyReady ? DshColors.ok : DshColors.err;
  }
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.store, this.usage});

  /// 用量台账（有就显示"用过 N 次 · X 字"，没有就不显示 —— 不编数字）。
  final UsageStore? usage;

  final ModelStore store;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  ModelEntry? _selected;

  /// 当前展开的厂家（手风琴：同时只展开一个，免得面板被撑爆）。
  String? _open;

  @override
  void initState() {
    super.initState();
    _selected = widget.store.selected;
    widget.store.addListener(_sync);
  }

  @override
  void dispose() {
    widget.store.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    setState(() => _selected = widget.store.selected);
  }

  /// 把清单按**厂家**分组（第一级）。
  ///
  /// 顺序：轮换池 → 配置里的厂家（用户配置顺序）→ 兜底项（清单里有、但配置的
  /// `providers` 里找不到归属的那些，按 route 前缀各成一组）。
  List<_Group> _groups() {
    final store = widget.store;
    final cfg = store.config;
    final catalog = store.catalog;
    final used = <String>{};
    final out = <_Group>[];

    // ① 轮换池（数据上是 `rotate/<池名>`，界面上一律叫「轮换池」）
    final poolEntries = <ModelEntry>[
      for (final e in catalog)
        if (e.routeId.startsWith('${ConfiguredModels.rotateProviderId}/')) e,
    ];
    if (cfg.groups.isNotEmpty || poolEntries.isNotEmpty) {
      used.addAll(poolEntries.map((e) => e.routeId));
      var ready = false;
      for (final g in cfg.groups) {
        for (final m in g.members) {
          if (store.providerHasKey(m.split('/').first)) ready = true;
        }
      }
      out.add(_Group(
        id: ConfiguredModels.rotateProviderId,
        title: context.tr('轮换池'),
        entries: poolEntries,
        isPool: true,
        keyReady: ready,
      ));
    }

    // ①.5 **本地大模型暂时不列在这里**（2026-11-03 用户决定）。
    //
    // 0.82 不出这个功能，所以会话的模型选择器里也不该出现它 ——
    // 否则用户会选到一个「服务没跑」的空分组，又是一次"看着能用其实不能"。
    //
    // 完整实现、恢复办法见 `settings_tab.dart` 里那段注释（两处入口一起加回）。

    // ② 配置里的每个厂家
    //
    // ⚠️ **一条模型都没有的厂家也要列出来**（不能 `continue` 掉）。
    // `models.json` 里"有厂家、但没有模型条目"是真实会出现的状态（老版本写过这种
    // 文件，用户实测也踩过）。以前这里直接跳过 → 用户在会话里**看不到自己刚配的
    // 那家**，只看到一句"还没有可用的模型"，于是又回去重填一遍 Key
    // （那句提示对他做的事是无效的）。现在它照样成为一个分组，点开写明
    // "这家还没有登记模型 + 去哪儿补"，把"看不见"变成"看得见且知道下一步"。
    for (final p in cfg.providers) {
      final prefix = '${p.id}/';
      final entries = <ModelEntry>[
        for (final e in catalog)
          if (e.routeId.startsWith(prefix)) e,
      ];
      used.addAll(entries.map((e) => e.routeId));
      // 凭据由 App 自己提供的厂家（免费模型 / 本机模型）：**不用写 Key**，
      // 所以既不能标「未配 Key」，也不能标「已配 Key」—— 见 appProvidedCredentialIds。
      final keyless = ConfiguredModels.appProvidedCredentialIds.contains(p.id);
      out.add(_Group(
        id: p.id,
        title: p.label.trim().isEmpty ? p.id : p.label,
        entries: entries,
        isPool: false,
        keyReady: keyless || store.providerHasKey(p.id),
        keyless: keyless,
      ));
    }

    // ③ 兜底：清单里有、但不属于上面任何一组（例如 models.json 缺失时
    //    ModelStore 从安全存储/overlay 里捞出来的那一条）。不许把它藏起来。
    for (final e in catalog) {
      if (used.contains(e.routeId)) continue;
      used.add(e.routeId);
      final head = e.routeId.split('/').first;
      out.add(_Group(
        id: 'orphan:$head',
        title: head,
        entries: <ModelEntry>[e],
        isPool: false,
        keyReady: store.providerHasKey(head),
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // 面板高度按设计稿比例（标题落在屏高 ~38% 附近），实测 0.68 最接近。
    final sheetHeight = media.size.height * 0.68;
    final groups = _groups();
    final models = widget.store.catalog;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: sheetHeight,
        child: Container(
          decoration: BoxDecoration(
            color: DshColors.surfaceStrong,
            borderRadius: BorderRadius.vertical(top: Radius.circular(DshMetrics.radius(18))),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: DshColors.divider,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(2)),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                context.tr('选择模型'),
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              // 如实交代来源：这些模型是**你自己配的**，不是 App 变出来的。
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  models.isEmpty
                      ? (groups.isEmpty
                          ? context.tr('还没有可用模型。')
                          : context.tr(
                              '一个可选模型都还没有 —— 下面按厂家列出的是你已经登记过的分组（有的还没有模型）。点厂家名展开看下一步。'))
                      : context.tr('共 {0} 个模型，分 {1} 组（{2}）——点厂家名展开，点模型就切过去。', [
                          models.length,
                          groups.length,
                          groups.map((g) => g.title).join('、')
                        ]),
                  style: TextStyle(
                    color: DshColors.textFaint.withValues(alpha: 0.9),
                    fontSize: 10.5,
                    height: 1.4,
                  ),
                ),
              ),
              const Divider(height: 12, thickness: 0.5),
              // （这里原来有一条"本地模型没启动"的引导提示，
              //   2026-11-03 随入口一起撤下 —— 0.82 不提供该功能，
              //   指路指到一个不存在的地方比不指更糟。恢复见 settings_tab.dart。）

              Expanded(
                child: groups.isEmpty
                    ? _emptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        itemCount: groups.length,
                        itemBuilder: (context, i) => _groupBlock(groups[i]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 第一级一行 + （展开时）第二级的模型列表。
  Widget _groupBlock(_Group g) {
    final open = _open == g.id;
    return Column(
      children: [
        Semantics(
          button: true,
          label: context.tr('{0}，{1} 个模型，{2}，{3}', [
            g.title,
            g.entries.length,
            g.keyLabel,
            open ? '收起' : '展开'
          ]),
          container: true,
          child: InkWell(
            onTap: () => setState(() => _open = open ? null : g.id),
            child: Container(
              height: _kGroupRowHeight,
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: open ? DshColors.accentDim : Colors.transparent,
                borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
              ),
              child: Row(
                children: [
                  Icon(
                    open ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                    color: open ? DshColors.accent : DshColors.textDim,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    g.isPool ? Icons.autorenew : Icons.dns_outlined,
                    size: 15,
                    color: open ? DshColors.accent : DshColors.textDim,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      g.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: open ? DshColors.accent : DshColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _pill(
                    g.isPool
                        ? context.tr('{0} 个池子', [g.entries.length])
                        : context.tr('{0} 个模型', [g.entries.length]),
                  ),
                  _pill(
                    g.keyLabel,
                    color: g.keyColor,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (open) ...[
          if (g.entries.isEmpty)
            _emptyGroupHint(g)
          else ...[
            // 未配 Key 要**明确写出来**：不然用户选中了却在发言时失败，
            // 完全不知道是为什么（这正是本轮要治的那个坑）。
            if (!g.keyReady) _notConfiguredHint(g),
            for (final e in g.entries)
              _modelRow(e, g, selected: e.routeId == _selected?.routeId),
          ],
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  /// 展开后的一条提示：这一组还没配 API Key（选中了发言必然失败）。
  ///
  /// 之所以要写出来：不然用户选中了却在发言时失败，完全不知道是为什么
  /// （这正是本轮要治的那个坑）。
  Widget _notConfiguredHint(_Group g) => Padding(
        padding: const EdgeInsets.fromLTRB(34, 2, 20, 6),
        child: Text(
          g.isPool
              ? context.tr(
                  '这个池子里的模型所在厂家都还没配 API Key —— 现在选中它，发言时必然失败。去「设置 → 模型 → 我的模型」给其中至少一家填 Key。')
              : context.tr(
                  '「{0}」还没配 API Key —— 现在选中它，发言时必然失败。去「设置 → 模型 → 我的模型」填 Key 并「测试并保存」。',
                  [g.title]),
          style: TextStyle(
            color: DshColors.err,
            fontSize: 10.5,
            height: 1.5,
          ),
        ),
      );

  /// 展开后的一条提示：这台厂家**已经登记，但名下一条模型都没有**。
  ///
  /// 这是"填了 Key、会话里却看不到"的另一种形状（厂房在、模型清单空）。
  /// 必须把"缺的是模型清单、不是 Key"讲清楚，并给出**真的能解决**的下一步 ——
  /// 否则用户会照着一句无效的提示反复重填 Key。正常路径下这种状态不会出现
  /// （设置页「测试并保存」保证至少登记一条模型），这里是给老文件/手改文件的兜底。
  Widget _emptyGroupHint(_Group g) => Padding(
        padding: const EdgeInsets.fromLTRB(34, 2, 20, 6),
        child: Text(
          context.tr(
              '「{0}」已经登记，但名下一条模型都没有 —— 现在选中它没有任何模型可用。\n去「设置 → 模型 → 我的模型」点开这家：{1}点「测试并保存」（它会自动把模型登记进来），或点「获取模型」自己勾几个。',
              [g.title, g.keyReady ? '' : '填好 API Key，然后']),
          style: TextStyle(
            color: g.keyReady ? DshColors.textDim : DshColors.err,
            fontSize: 10.5,
            height: 1.5,
          ),
        ),
      );

  Widget _pill(String text, {Color? color}) {
    final tint = color ?? DshColors.textDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      margin: const EdgeInsets.only(left: 4),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(DshMetrics.radius(20)),
        border: Border.all(color: tint.withValues(alpha: 0.5), width: 0.7),
      ),
      child: Text(
        text,
        style:
            TextStyle(color: tint, fontSize: 9.5, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// 第二级：一条模型。**点它 = 选中并使用**（走 `store.selectModel`，
  /// 对话页据此走"会话内切换、不重建会话"那条路）。
  Widget _modelRow(ModelEntry e, _Group g, {required bool selected}) {
    final cfg = widget.store.config;
    final group = cfg.groupOfRoute(e.routeId);
    // 池子行自己写描述：`ModelChoice.description` 里那句"轮换组 · N 个模型"
    // 是数据层的历史文案（那个文件本轮不许改），界面上统一叫「轮换池」。
    // 用量：**只显示真记过账的**，一条都没有就不加这段话（不编数字）。
    final rec = widget.usage?.of(e.routeId);
    final usageBit = (rec == null || rec.requests <= 0)
        ? ''
        : '　·　${context.tr('用过 {0} 次 · {1} 字', [
                '${rec.requests}',
                UsageStore.shortChars(rec.totalChars)
              ])}';
    final description = (group != null
            ? context.tr('轮换池 · {0} 个成员：{1}', [
                group.members.length,
                group.members.map(_memberLabel).join(' → ')
              ])
            : (e.description ?? e.routeId)) +
        usageBit;
    return Semantics(
      button: true,
      selected: selected,
      label: '${group != null ? '轮换池 ' : ''}${e.name} $description',
      container: true,
      child: InkWell(
        onTap: () {
          widget.store.selectModel(e);
          Navigator.of(context).pop(e);
        },
        child: Container(
          height: _kSheetRowHeight,
          margin: const EdgeInsets.symmetric(horizontal: 26, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? DshColors.accentDim : Colors.transparent,
            borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
            border: selected
                ? Border.all(color: DshColors.accent, width: 0.8)
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? DshColors.accent : DshColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: DshColors.textFaint,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check, size: 16, color: DshColors.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _memberLabel(String route) {
    // 本机模型不在 models.json 里（运行时虚拟厂家），所以要**单独认一下** ——
    // 否则池子里的本机成员会被显示成「local/xxx（已失效）」，看着像坏了。
    if (route.startsWith('${LocalModelSpec.providerId}/')) {
      final spec = LocalModelServer.instance.spec;
      if (spec != null &&
          route == '${LocalModelSpec.providerId}/${spec.modelId}') {
        return '${spec.displayName}（${context.tr('本机')}）';
      }
      if (spec == null) {
        return context.tr('{0}（本机服务没在运行）', [route]);
      }
    }
    final m = widget.store.config.modelOfRoute(route);
    if (m == null) return context.tr('{0}（已失效）', [route]);
    return '${m.displayName}（${m.provider}）';
  }

  /// 空态：明确告诉用户**去哪儿**把模型配出来，而不是给一堆假模型让他点。
  Widget _emptyState() => Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 30, color: DshColors.textFaint),
            const SizedBox(height: 12),
            Text(
              context.tr('还没有可用的模型'),
              style: TextStyle(
                color: DshColors.text,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr(
                  '去「设置 → 模型 → 我的模型」：点开一家内置厂家（地址已经内置好）→ 只填 API Key → 点「测试并保存」。\n\n保存成功后，这里就会按厂家分组列出你的模型，点一下就能用；此前那种"没配置也能随便切模型"的假象，就是硬编码清单造成的。'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11.5, height: 1.6),
            ),
          ],
        ),
      );
}
