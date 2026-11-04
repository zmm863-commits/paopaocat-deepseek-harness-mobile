import 'package:flutter/material.dart';

import '../../data/expert_catalog.dart';
import '../../data/expert_store.dart';
import '../../data/skill_store.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';

import '../../i18n/dsh_i18n.dart';

/// 「专家」页要切到哪个 Tab 的请求（0 = 专家，1 = 技能）。
///
/// 为什么要这个东西：对话页的附件菜单里有「使用技能」，
/// 而从对话页切回底部导航时 `ExpertPage` 的状态会被 IndexedStack 保留，
/// 直接改下标不会触发任何回调。这里用一个带自增序号的请求对象，
/// 保证"同一个 Tab 再点一次"也能触发（[seq] 变化 → notifyListeners）。
class ExpertTabRequest extends ChangeNotifier {
  int tab = 0;
  int seq = 0;

  void request(int target) {
    tab = target;
    seq++;
    notifyListeners();
  }
}

/// 专家中心（设计稿 `page-09`）。
///
/// 设计稿结构（y / 屏高，源：`pdf-images/ocr-all.txt` page-09 节）：
///   | 元素 | y | 屏高 | x |
///   |---|---|---|---|
///   | 顶栏 Tab | 193~260 | 7.3%~9.8% | 303 / 549 / 768 |
///   | 分类胶囊行 | 495~546 | **18.7%~20.7%** | 103~1143 |
///   | 首排专家卡文字 | 754~903 | 28.6%~34.2% | 左列 119~495、右列 681~1098 |
///
/// **本轮改动（用户要求）**：取消「连接器」Tab，只保留 `专家` / `技能`；
/// 专家页从"设计稿样例 8 张卡"换成**真实专家库**（数据来源见 [ExpertCatalog]），
/// 每名专家带一个会**真的写进 `$DSH_HOME/AGENTS.md`** 的开关（见 [ExpertStore]）。
class ExpertPage extends StatefulWidget {
  const ExpertPage({
    super.key,
    required this.dshHome,
    required this.workspacePath,
    required this.onOpenChatWithPrompt,
    this.tabRequest,
    this.refreshTick = 0,
  });

  /// 设备的 `DSH_HOME`（Android 上 = `<filesDir>/dshhome`）。
  final String dshHome;

  /// 当前工作区，用于扫描项目级技能根 `<工作区>/.dsh/skills`。
  final String workspacePath;

  /// 「用对话生成技能」→ 打开对话页并预填一段精确指令（复用已跑通的 ACP 链路）。
  final void Function(String prompt) onOpenChatWithPrompt;

  /// 外部（对话页附件菜单）请求切 Tab。
  final ExpertTabRequest? tabRequest;

  /// 底部 Tab 切到本页时的刷新计数（见 app_shell 的 `_pageTicks`）。
  final int refreshTick;

  @override
  State<ExpertPage> createState() => _ExpertPageState();
}

/// 只保留「专家」与「技能」——「连接器」是同类产品的云端能力，用户明确要求去掉。
List<String> get _topTabs => [tr('专家'), tr('技能')];

class _ExpertPageState extends State<ExpertPage> {
  int _topTab = 0;

  /// 0 = 全部；1..n = 对应 [ExpertCatalog.divisions] 的某一项。
  int _category = 0;

  ExpertCatalog? _catalog;
  ExpertStore? _experts;
  late SkillStore _skills;

  bool _loading = true;
  String? _loadError;

  List<SkillEntry> _skillList = const [];
  bool _skillsLoading = false;

  @override
  void initState() {
    super.initState();
    _skills = SkillStore(
        dshHome: widget.dshHome, workspacePath: widget.workspacePath);
    widget.tabRequest?.addListener(_onTabRequest);
    _boot();
  }

  @override
  void dispose() {
    widget.tabRequest?.removeListener(_onTabRequest);
    super.dispose();
  }

  /// 对话页附件菜单点了「使用技能」/「专家中心」后切过来。
  /// 切到技能页时顺手重扫一次目录 —— 「对话生成技能」写完文件回到这里就能看到。
  void _onTabRequest() {
    final req = widget.tabRequest;
    if (req == null || !mounted) return;
    setState(() => _topTab = req.tab.clamp(0, _topTabs.length - 1));
    if (req.tab == 1) _refreshSkills();
  }

  @override
  void didUpdateWidget(covariant ExpertPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspacePath != widget.workspacePath) {
      _skills = SkillStore(
          dshHome: widget.dshHome, workspacePath: widget.workspacePath);
      _refreshSkills();
    }
    // 每切到本页一次就重载（用户要求「切换即刷新」）：
    // 重新读 experts.json（开关状态）+ 重扫技能目录。
    if (oldWidget.refreshTick != widget.refreshTick) _boot();
  }

  Future<void> _boot() async {
    try {
      final store = ExpertStore(dshHome: widget.dshHome);
      await store.load();
      final catalog = await ExpertCatalog.load();
      ExpertCatalogCache.current = catalog;
      if (!mounted) return;
      setState(() {
        _experts = store;
        _catalog = catalog;
        _loading = false;
      });
      debugPrint('[dsh-expert] 专家库就绪：${catalog.experts.length} 名 / '
          '${catalog.divisions.length} 个分区，来源 ${catalog.sourcePackage}@${catalog.sourceVersion}');
      await _refreshSkills();
    } catch (e) {
      debugPrint('[dsh-expert] 专家库载入失败：$e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = context.tr('专家库载入失败：{0}', [e]);
      });
    }
  }

  Future<void> _refreshSkills() async {
    if (!mounted) return;
    setState(() => _skillsLoading = true);
    try {
      final list = await _skills.list();
      if (!mounted) return;
      setState(() {
        _skillList = list;
        _skillsLoading = false;
      });
    } catch (e) {
      debugPrint('[dsh-skill] 列出技能失败：$e');
      if (!mounted) return;
      setState(() => _skillsLoading = false);
    }
  }

  /// 开关：写盘 + 重写 AGENTS.md，然后给用户一句诚实反馈。
  Future<void> _toggle(ExpertEntry e, bool on) async {
    final store = _experts!;
    final err = await store.setEnabled(e.slug, on);
    if (!mounted) return;
    final catalog = _catalog;
    if (err == null && catalog != null) {
      // 开关状态落盘后，用最新目录再写一次 AGENTS.md，保证 brief 进得去。
      await store.flushWithCatalog(catalog);
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          err ??
              (on
                  ? context.tr('已开启「{0}」→ 已写入 {1}\n新建一个会话后，模型就会看到这名专家的角色设定。',
                      [e.name, store.agentsMdPath])
                  : context.tr('已关闭「{0}」→ 已从 AGENTS.md 移除', [e.name])),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _openExpertDetail(ExpertEntry e) {
    final store = _experts!;
    final divisionName = _divisionName(e.division);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: DshColors.surfaceStrong,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(DshMetrics.radius(18))),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        maxChildSize: 0.92,
        builder: (ctx, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: DshColors.divider,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(2)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${e.emoji.isNotEmpty ? '${e.emoji} ' : ''}${e.name}',
                    style: TextStyle(
                      color: DshColors.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Switch(
                  value: store.isEnabled(e.slug),
                  activeThumbColor: DshColors.accent,
                  onChanged: (v) {
                    Navigator.of(ctx).pop();
                    _toggle(e, v);
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(divisionName,
                style: TextStyle(color: DshColors.accent, fontSize: 12)),
            const SizedBox(height: 12),
            Text(e.description,
                style: TextStyle(
                    color: DshColors.text, fontSize: 13.5, height: 1.6)),
            if (e.brief.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(context.tr('核心使命（来自插件原文）'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11.5)),
              const SizedBox(height: 6),
              Text(e.brief,
                  style: TextStyle(
                      color: DshColors.textDim, fontSize: 12.5, height: 1.6)),
            ],
            const SizedBox(height: 18),
            Text(context.tr('标识：{0}', [e.slug]),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
            const SizedBox(height: 6),
            Text(
              context.tr(
                  '开启后：专家摘要写进 {0}，DSH 内置的 agent-instructions 插件会在每个新会话的第一个请求前把它注入模型上下文；关闭则该段被移除。对已经打开的会话不生效——需要新建会话。',
                  [store.agentsMdPath]),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  String _divisionName(String slug) {
    final list = _catalog?.divisions ?? const <ExpertDivision>[];
    for (final d in list) {
      if (d.slug == slug) return d.name;
    }
    return slug;
  }

  List<ExpertEntry> get _visibleExperts {
    final all = _catalog?.experts ?? const <ExpertEntry>[];
    if (_category == 0) return all;
    final divisions = _catalog?.divisions ?? const <ExpertDivision>[];
    final idx = _category - 1;
    if (idx < 0 || idx >= divisions.length) return all;
    final slug = divisions[idx].slug;
    return [
      for (final e in all)
        if (e.division == slug) e,
    ];
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Column(
            children: [
              SizedBox(height: (screenH * 0.0562 - 21.3).clamp(0, 12)),
              // ⚠️ 这个高度**不能小于 30**：26 时冷启动第一次进本页会报
              // 3 次 `A RenderFlex overflowed by 2.0 pixels`（三个 _TopTab 各一次）。
              // 现在只剩 2 个 Tab，仍保留 30 —— 上轮对照实验确认 30 后 overflow 归零。
              SizedBox(
                height: 30,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _topTabs.length; i++)
                      _TopTab(
                        label: _topTabs[i],
                        selected: i == _topTab,
                        onTap: () => setState(() => _topTab = i),
                      ),
                  ],
                ),
              ),
              SizedBox(height: (screenH * 0.089 - 44).clamp(0, 60)),
              if (_topTab == 0) _buildCategoryRow() else _buildSkillToolbar(),
              SizedBox(height: screenH * 0.036 - 12),
            ],
          ),
        ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildCategoryRow() {
    final catalog = _catalog;
    final labels = <String>[
      context
          .tr('全部{0}', [catalog == null ? '' : ' ${catalog.experts.length}']),
      for (final d in catalog?.divisions ?? const <ExpertDivision>[])
        '${d.name} ${d.count}',
    ];
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
        itemCount: labels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (context, i) => Center(
          child: DshChip(
            label: labels[i],
            selected: i == _category,
            onTap: () => setState(() => _category = i),
          ),
        ),
      ),
    );
  }

  Widget _buildSkillToolbar() {
    return SizedBox(
      height: 38,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.tr('共 {0} 个技能 · {1}/skills',
                    [_skillList.length, widget.dshHome]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: DshColors.textFaint, fontSize: 11),
              ),
            ),
            _MiniButton(
              icon: Icons.refresh,
              label: context.tr('刷新'),
              onTap: _refreshSkills,
            ),
            const SizedBox(width: 6),
            _MiniButton(
              icon: Icons.add,
              label: context.tr('新建'),
              onTap: _openSkillEditor,
            ),
            const SizedBox(width: 6),
            _MiniButton(
              icon: Icons.forum_outlined,
              label: context.tr('对话生成'),
              onTap: _generateSkillByChat,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: DshColors.accent),
        ),
      );
    }
    if (_loadError != null) {
      return DshEmptyState(
        icon: Icons.error_outline,
        title: context.tr('专家库载入失败'),
        hint: _loadError,
      );
    }
    return _topTab == 0 ? _buildExperts() : _buildSkills();
  }

  Widget _buildExperts() {
    final list = _visibleExperts;
    final enabled = _experts?.enabledCount ?? 0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              DshMetrics.pagePad, 0, DshMetrics.pagePad, 8),
          child: Row(
            children: [
              Icon(
                enabled > 0 ? Icons.check_circle : Icons.toggle_off_outlined,
                size: 13,
                color: enabled > 0 ? DshColors.accent : DshColors.textFaint,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  enabled > 0
                      // 用户要求改成单选，所以这里把规则直接写给用户看：
                      // 一次只生效一位，避免多个人设同时注入互相打架。
                      ? context
                          .tr('已开启 {0} 位 · 同一时间只生效一位，开新的会自动关掉旧的', [enabled])
                      : context.tr('还没有开启任何专家；开启后会在会话的「专家中心」里出现'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: enabled > 0 ? DshColors.accent : DshColors.textFaint,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(
              DshMetrics.pagePad,
              0,
              DshMetrics.pagePad,
              16,
            ),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: DshMetrics.cardGap,
              // 设计稿单卡 379x470 设计像素（≈ 高宽比 1.24 的"竖卡"）。
              // 本轮卡里多了一行开关，卡片略高，取 0.82。
              childAspectRatio: 0.82,
            ),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final e = list[i];
              return _ExpertCard(
                expert: e,
                division: _divisionName(e.division),
                enabled: _experts?.isEnabled(e.slug) ?? false,
                onToggle: (v) => _toggle(e, v),
                onOpen: () => _openExpertDetail(e),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSkills() {
    if (_skillList.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: DshEmptyState(
              icon: Icons.extension_outlined,
              title:
                  _skillsLoading ? context.tr('正在读取技能目录…') : context.tr('暂无技能'),
              hint: context.tr(
                  'DSH 会扫描两个真实目录：\n用户级 {0}/skills\n项目级 {1}/.dsh/skills\n点右上「新建」手写一个，或「对话生成」让模型写一个。',
                  [widget.dshHome, widget.workspacePath]),
              centerY: 0.42,
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        DshMetrics.pagePad,
        0,
        DshMetrics.pagePad,
        16,
      ),
      itemCount: _skillList.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _SkillTile(
        skill: _skillList[i],
        onTap: () => _openSkillDetail(_skillList[i]),
      ),
    );
  }

  // ------------------------------------------------------------- 技能：增改删

  Future<void> _openSkillEditor({SkillEntry? editing}) async {
    final result = await showDialog<_SkillDraft>(
      context: context,
      builder: (ctx) => _SkillEditorDialog(store: _skills, editing: editing),
    );
    if (result == null || !mounted) return;

    final err = editing == null
        ? await _skills.create(
            name: result.name,
            description: result.description,
            body: result.body,
          )
        : await _skills.update(
            skill: editing,
            description: result.description,
            body: result.body,
          );
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          editing == null
              ? context.tr('已创建技能 {0} → {1}/skills/{2}/SKILL.md',
                  [result.name, widget.dshHome, result.name])
              : context.tr('已保存技能 {0}', [editing.name]),
        ),
      ),
    );
    await _refreshSkills();
  }

  Future<void> _openSkillDetail(SkillEntry skill) async {
    final body = await _skills.readBody(skill);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: DshColors.surfaceStrong,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(DshMetrics.radius(18))),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.66,
        maxChildSize: 0.94,
        builder: (ctx, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: DshColors.divider,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(2)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(skill.name,
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 8),
            Text(skill.description,
                style: TextStyle(
                    color: DshColors.textDim, fontSize: 13, height: 1.6)),
            const SizedBox(height: 12),
            Text(
                context.tr(
                    '来源：{0}\n{1}', [skill.isUser ? '用户级' : '项目级', skill.path]),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.6)),
            const Divider(height: 26),
            Text(body,
                style: TextStyle(
                    color: DshColors.text, fontSize: 12.5, height: 1.7)),
            const SizedBox(height: 20),
            Row(
              children: [
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _openSkillEditor(editing: skill);
                  },
                  child: Text(context.tr('编辑')),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    final err = await _skills.delete(skill);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(
                              err ?? context.tr('已删除技能 {0}', [skill.name]))),
                    );
                    await _refreshSkills();
                  },
                  child: Text(context.tr('删除'),
                      style: TextStyle(color: DshColors.err)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「用对话生成技能」：复用已跑通的对话页 + ACP 链路。
  ///
  /// 为什么不是 App 自己调一个 create_skill 工具：**手机运行时里没有这个工具**。
  /// `create_skill` 由桌面 web profile 的插件 `@michengai/dsh-skills-manager` 提供，
  /// 而 `dsh-runtime.zip`（26,495 条目）里既没有 `michengai` 也没有 `agency`。
  /// 所以走**模型自带 `write` 工具**这条路：它在工作区内有写权限，
  /// 而技能目录 `<工作区>/.dsh/skills` 正好在工作区内
  /// （也正是 `dsh-skill-filesystem` 会扫描的 `project-dsh` 根，rank 100）。
  void _generateSkillByChat() {
    final root = '${widget.workspacePath}/.dsh/skills';
    final prompt = context.tr('''
请帮我创建一个 DSH 技能，直接落盘，不要只给示例。

要求：
1. 用你的 write 工具创建文件：{0}/<技能名>/SKILL.md
2. <技能名> 必须匹配 ^[a-z0-9]+(?:-[a-z0-9]+)\$（小写字母/数字/连字符），这是 DSH 的技能名规范。
3. 文件内容严格是下面这个格式（frontmatter 只有 name 与 description）：
---
name: <技能名>
description: "<一句话说明什么时候该用这个技能>"
---

<技能正文：可执行的步骤、注意事项、输出格式；Markdown>
4. 技能主题由你根据下面的描述来定，正文要具体到能照着做，不要写空话。
5. 写完后告诉我：技能名、文件绝对路径、以及一句话说明它解决什么问题。

我想让这个技能做的事：
（在这里把你的需求写清楚，例如：把每天的聊天记录整理成一份 Markdown 日报，带待办清单）
''', [root]);
    widget.onOpenChatWithPrompt(prompt);
  }
}

// --------------------------------------------------------------------- 小组件

class _TopTab extends StatelessWidget {
  const _TopTab(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 设计稿：相邻 Tab 中心距 246 设计像素 ≈ 20% 屏宽。
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  color: selected ? DshColors.text : DshColors.textDim,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
              const SizedBox(height: 3),
              Container(
                width: 18,
                height: 2,
                decoration: BoxDecoration(
                  color: selected ? DshColors.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(1)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DshMetrics.radius(16)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(16)),
          border: Border.all(color: DshColors.divider, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: DshColors.accent),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(fontSize: 11.5, color: DshColors.text)),
          ],
        ),
      ),
    );
  }
}

/// 专家卡：名称 + 简介 + **开关**。
///
/// 纵向用 `Expanded` 承载简介，卡片高度不够时简介先被裁掉，
/// 而不是让整列溢出（实测冷启动首帧最容易在这里报 overflow）。
class _ExpertCard extends StatelessWidget {
  const _ExpertCard({
    required this.expert,
    required this.division,
    required this.enabled,
    required this.onToggle,
    required this.onOpen,
  });

  final ExpertEntry expert;
  final String division;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${expert.name} ${enabled ? "已开启" : "未开启"}',
      child: Container(
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
          border: Border.all(
            color: enabled ? DshColors.accent : DshColors.divider,
            width: enabled ? 1 : 0.8,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
            child: Padding(
              padding: const EdgeInsets.all(11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 26,
                    child: Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: DshColors.accentDim,
                            borderRadius: BorderRadius.circular(DshMetrics.radius(7)),
                          ),
                          child: Text(
                            expert.emoji.isNotEmpty ? expert.emoji : '🧠',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const Spacer(),
                        // 用 FittedBox 缩放**布局尺寸**（Transform.scale 只改绘制，
                        // 会让 46dp 的 Switch 撑破 26dp 的行高 → 正是上一轮 overflow 的同类坑）。
                        SizedBox(
                          width: 40,
                          height: 24,
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: Switch(
                              value: enabled,
                              activeThumbColor: DshColors.accent,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: onToggle,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    expert.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: DshColors.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    division,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: DshColors.accent, fontSize: 10),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Text(
                      expert.description,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: DshColors.textFaint,
                        fontSize: 10.5,
                        height: 1.32,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SkillTile extends StatelessWidget {
  const _SkillTile({required this.skill, required this.onTap});

  final SkillEntry skill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.tr('技能 {0}', [skill.name]),
      child: Material(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: DshColors.accentDim,
                    borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                  ),
                  child: Icon(Icons.extension_outlined,
                      size: 16, color: DshColors.accent),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              skill.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: DshColors.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: skill.isUser
                                  ? DshColors.accentDim
                                  : DshColors.surfaceHigh,
                              borderRadius: BorderRadius.circular(DshMetrics.radius(4)),
                            ),
                            child: Text(
                              skill.isUser
                                  ? context.tr('用户级')
                                  : context.tr('项目级'),
                              style: TextStyle(
                                fontSize: 9,
                                color: skill.isUser
                                    ? DshColors.accent
                                    : DshColors.textDim,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        skill.description.isEmpty
                            ? context.tr('（无简介）')
                            : skill.description,
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
                Icon(Icons.chevron_right, size: 16, color: DshColors.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ 技能编辑对话框

class _SkillDraft {
  const _SkillDraft(
      {required this.name, required this.description, required this.body});

  final String name;
  final String description;
  final String body;
}

/// 新建 / 编辑技能。控制器生命周期与对话框路由对齐（上一轮踩过
/// `A TextEditingController was used after being disposed` 的坑）。
class _SkillEditorDialog extends StatefulWidget {
  const _SkillEditorDialog({required this.store, this.editing});

  final SkillStore store;
  final SkillEntry? editing;

  @override
  State<_SkillEditorDialog> createState() => _SkillEditorDialogState();
}

class _SkillEditorDialogState extends State<_SkillEditorDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.editing?.name ?? '');
  late final TextEditingController _desc =
      TextEditingController(text: widget.editing?.description ?? '');
  late final TextEditingController _body = TextEditingController();

  bool _nameOk = true;
  String? _bodyError;

  @override
  void initState() {
    super.initState();
    if (widget.editing != null) {
      widget.store.readBody(widget.editing!).then((b) {
        if (mounted) setState(() => _body.text = b.trim());
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim().toLowerCase();
    if (widget.editing == null && !SkillStore.namePattern.hasMatch(name)) {
      setState(() => _nameOk = false);
      return;
    }
    if (_desc.text.trim().isEmpty || _body.text.trim().isEmpty) {
      setState(() => _bodyError = context.tr('简介与正文都不能为空'));
      return;
    }
    Navigator.of(context).pop(_SkillDraft(
      name: name,
      description: _desc.text.trim(),
      body: _body.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing != null;
    return AlertDialog(
      backgroundColor: DshColors.surfaceStrong,
      title: Text(
          editing
              ? context.tr('编辑技能 {0}', [widget.editing!.name])
              : context.tr('新建技能'),
          style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!editing) ...[
                TextField(
                  controller: _name,
                  decoration:
                      InputDecoration(hintText: context.tr('技能名（kebab-case）')),
                  onChanged: (_) {
                    if (!_nameOk) setState(() => _nameOk = true);
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  _nameOk
                      ? context.tr('技能名：{0}', [SkillStore.nameRule])
                      : context.tr('✗ 名字不合法。{0}', [SkillStore.nameRule]),
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: _nameOk ? DshColors.textFaint : DshColors.err,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _desc,
                maxLines: 2,
                decoration:
                    InputDecoration(hintText: context.tr('简介：什么时候该用这个技能')),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _body,
                maxLines: 8,
                decoration:
                    InputDecoration(hintText: context.tr('技能正文（Markdown 指令）')),
              ),
              if (_bodyError != null) ...[
                const SizedBox(height: 8),
                Text(_bodyError!,
                    style: TextStyle(color: DshColors.err, fontSize: 11)),
              ],
              const SizedBox(height: 10),
              Text(
                editing
                    ? context.tr('将覆盖写入 {0}', [widget.editing!.path])
                    : context.tr('将写入 {0}/<技能名>/SKILL.md（DSH 真实扫描的用户级技能根）',
                        [widget.store.userRoot]),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('取消')),
        ),
        FilledButton(
            onPressed: _save,
            child: Text(editing ? context.tr('保存') : context.tr('创建'))),
      ],
    );
  }
}
