import 'package:flutter/material.dart';

import '../../data/workspace_store.dart';
import 'recent_changes_page.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';

import '../../i18n/dsh_i18n.dart';

/// 工作区管理器（取代原来那个"顶栏写着云端、内容是本机内存任务"的任务列表页）。
///
/// 用户原话：「这个按钮是工作区按钮，可以新建工作区，查看已建工作区，以及会话。」
/// 所以这一页回答三个问题：**我有哪些工作区**、**每个工作区下有哪些会话**、
/// **怎么新建/切换**。
///
/// 数据来源（全部真实，没有任何假数据）：
///   * 工作区 = App 私有目录下**真实存在的目录**（`workspaces.json` 里登记的
///     + 从磁盘会话的 cwd 里发现的）；
///   * 会话 = ① 本次运行真的聊过的（有真实标题 = 用户第一句话）；
///     ② 磁盘上的历史会话（ACP `session/list` 查出来的，只有 sessionId，
///     DSH 不给标题，所以**如实显示会话号**，不编标题）。
///
/// 与底部导航的「项目」不是一回事：`项目` 是多人协同的项目空间（设计稿 page-07），
/// 这一页是本机 DSH 的工作目录 + 会话，两者互不合并。
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    required this.store,
    required this.onNewWorkspace,
    required this.onOpenSession,
    required this.onRefreshIndex,
  });

  final WorkspaceStore store;

  /// 新建工作区（外层负责弹输入框 → 真建目录 → 刷新）
  final Future<void> Function() onNewWorkspace;

  /// 打开某条会话（外层负责 pop 本页 + 用 session/resume 恢复）
  final void Function(DshSession session, DshWorkspace workspace) onOpenSession;

  /// 重新读磁盘会话索引
  final Future<void> Function() onRefreshIndex;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  /// 展开了哪些工作区。
  ///
  /// 用户实测要求：「各个工作区会话会收缩，只有点击才可以展示有多少会话」。
  /// 所以这里**初始为空 = 全部收起**，会话数与会话列表都等用户点开才显示。
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    // 刻意**不**自动展开当前工作区：之前那行 `_expanded.add(current.path)`
    // 会让列表一进来就摊开一大块，和用户要的"全部收起"相反。
    // 打开就刷一次磁盘索引（历史会话）。结果会被 store 缓存住，重复进不会重复拉。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.store.indexLoaded) widget.onRefreshIndex();
    });
  }

  /// 切工作区 = 换 DSH 下一次开会话时用的 cwd。
  ///
  /// 放在 State 方法里（而不是 build 的闭包里）是为了让 `mounted` 检查
  /// 和 `context` 属于同一个对象，避免跨 await 用 builder 的 context。
  Future<void> _switchTo(DshWorkspace w) async {
    await widget.store.selectWorkspace(w);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('已切到「{0}」，新开的对话将在这个目录里运行', [w.name]))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedBuilder(
        animation: widget.store,
        builder: (context, _) {
          final store = widget.store;
          final spaces = store.allWorkspaces;

          return Column(
            children: [
              _TopBar(
                screenH: screenH,
                onNew: () => widget.onNewWorkspace(),
                onRefresh: () => widget.onRefreshIndex(),
                onRecent: () {
                  // 扫描哪个目录？优先用户选中的工作区，没有就扫第一个。
                  final list = store.allWorkspaces;
                  if (list.isEmpty) return;
                  final target = list.first;
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => RecentChangesPage(root: target.path),
                  ));
                },
              ),
              _StatusLine(store: store),
              SizedBox(height: screenH * 0.012),
              Expanded(
                child: spaces.isEmpty
                    ? SizedBox(
                        height: 220,
                        child: DshEmptyState(
                          icon: Icons.folder_off_outlined,
                          title: context.tr('暂无工作区'),
                          hint: context.tr('点右上角「新建工作区」建一个；工作区就是 DSH 运行的工作目录。'),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          DshMetrics.pagePad,
                          0,
                          DshMetrics.pagePad,
                          14,
                        ),
                        itemCount: spaces.length,
                        itemBuilder: (context, i) => _WorkspaceCard(
                          workspace: spaces[i],
                          store: store,
                          expanded: _expanded.contains(spaces[i].path),
                          onToggle: () => setState(() {
                            final p = spaces[i].path;
                            if (!_expanded.remove(p)) _expanded.add(p);
                          }),
                          onSwitch: () => _switchTo(spaces[i]),
                          onOpenSession: (s) =>
                              widget.onOpenSession(s, spaces[i]),
                        ),
                      ),
              ),
              _AccountStrip(screenH: screenH, store: store),
            ],
          );
        },
      ),
    );
  }
}

/// 顶栏：左 `工作区`，右 `＋ 新建工作区`。
///
/// 原来这里是 `云端`（设计稿 page-10 顶栏）—— 本机没有云端账号，
/// 那个词会让人以为点进去是云端任务列表，所以按用户要求改成 `工作区`。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.screenH,
    required this.onNew,
    required this.onRefresh,
    required this.onRecent,
  });

  final double screenH;
  final VoidCallback onNew;
  final VoidCallback onRefresh;

  /// 「最近的改动」入口：agent 改了哪些文件，一眼能看到（2026-10-31）。
  final VoidCallback onRecent;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          DshMetrics.pagePad,
          screenH * 0.0562 - 21.3,
          DshMetrics.pagePad,
          0,
        ),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              // 这是从首页推入的二级页，必须有可见的返回入口
              // （上一版只有标题，用户只能靠系统返回键，属于"能走但不好走"）
              Semantics(
                button: true,
                label: context.tr('返回'),
                child: InkWell(
                  onTap: () => Navigator.of(context).maybePop(),
                  borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(2, 6, 8, 6),
                    child: Icon(Icons.arrow_back_ios_new,
                        size: 16, color: DshColors.text),
                  ),
                ),
              ),
              Text(
                context.tr('工作区'),
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              // 「最近的改动」入口（2026-10-31）：agent 一口气改了十几个文件之后，
              // 用户最想知道的就是"改了哪些"，而不用自己去目录里按时间猜。
              Semantics(
                button: true,
                label: context.tr('最近的改动'),
                child: InkWell(
                  onTap: onRecent,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.history,
                        size: 18, color: DshColors.textDim),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Semantics(
                button: true,
                label: context.tr('刷新会话索引'),
                child: InkWell(
                  onTap: onRefresh,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child:
                        Icon(Icons.refresh, size: 18, color: DshColors.textDim),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Semantics(
                button: true,
                label: context.tr('新建工作区'),
                child: InkWell(
                  onTap: onNew,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: DshColors.accentDim,
                      borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
                      border: Border.all(
                        color: DshColors.accent.withValues(alpha: 0.55),
                        width: 0.9,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add, size: 15, color: DshColors.accent),
                        const SizedBox(width: 4),
                        Text(
                          context.tr('新建工作区'),
                          style: TextStyle(
                            color: DshColors.accent,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一句话讲清楚"工作区到底是什么"，以及"切换会发生什么"。
///
/// 宁可把机制写出来，也不要让用户点完发现"好像没变化"。
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.store});

  final WorkspaceStore store;

  @override
  Widget build(BuildContext context) {
    final current = store.current;
    final busy = store.indexLoading;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          DshMetrics.pagePad, 8, DshMetrics.pagePad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: context.tr('工作区 = DSH 运行的工作目录（cwd）。当前：'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11.5),
                ),
                TextSpan(
                  text: current.name,
                  style: TextStyle(
                    color: DshColors.accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            current.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (busy) ...[
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
                const SizedBox(width: 6),
                Text(
                  context.tr('正在读磁盘上的历史会话…'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
                ),
              ] else if (store.indexError != null) ...[
                Icon(Icons.error_outline, size: 12, color: DshColors.err),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    context.tr('历史会话读取失败：运行时没起来或未配置模型（不影响下方本次会话）'),
                    style: TextStyle(color: DshColors.err, fontSize: 10.5),
                  ),
                ),
              ] else ...[
                Icon(Icons.inbox_outlined,
                    size: 12, color: DshColors.textFaint),
                const SizedBox(width: 5),
                Text(
                  store.indexLoaded
                      ? (store.hiddenEmptySessions > 0
                          ? context.tr('磁盘历史会话 {0} 条（其中 {1} 条是空会话，没列出来）', [store.totalDiskSessions, store.hiddenEmptySessions])
                          : context.tr('磁盘历史会话 {0} 条', [store.totalDiskSessions]))
                      : context.tr('磁盘历史会话：未读取'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 一个工作区卡片：名称 + 路径 + 会话数 + 切换/当前，展开后挂会话列表。
/// 「N 个会话 · 含本次运行」——收起时不显示（见 [_WorkspaceCard] 的注释）。
String _sessionsLabel(List<DshSession> sessions) {
  final live = sessions.any((s) => s.live) ? tr(' · 含本次运行') : '';
  return tr('{0} 个会话{1}', [sessions.length, live]);
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.workspace,
    required this.store,
    required this.expanded,
    required this.onToggle,
    required this.onSwitch,
    required this.onOpenSession,
  });

  final DshWorkspace workspace;
  final WorkspaceStore store;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onSwitch;
  final void Function(DshSession session) onOpenSession;

  /// 长按会话 → 改名（意见⑥）。
  ///
  /// 对话框**自己持有并释放**输入控制器（理由同 [_NewWorkspaceDialog]：
  /// 调用方 new 一个控制器、在 showDialog 返回后立刻 dispose，会让退场动画
  /// 期间的 TextField 用到已释放的控制器，实测会连锁出一串布局异常）。
  Future<void> _renameSession(BuildContext context, DshSession s) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameSessionDialog(initial: s.hasTitle ? s.title! : ''),
    );
    if (name == null) return;
    await store.renameSession(s.id, name);
  }

  @override
  Widget build(BuildContext context) {
    final isCurrent = store.current.path == workspace.path;
    final sessions = store.sessionsOf(workspace.path);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
        border: Border.all(
          color: isCurrent
              ? DshColors.accent.withValues(alpha: 0.6)
              : DshColors.divider,
          width: isCurrent ? 1.0 : 0.8,
        ),
      ),
      child: Column(
        children: [
          // 卡片头：**可展开区域**（含名称/路径/会话数，语义标签是整块信息）
          // 与**切换按钮**刻意做成两个并列的语义节点 —— 否则内层按钮会被
          // 合并进外层节点，无障碍和自动化都点不到它（上一版就是这样，
          // 语义树里根本看不到「切换」）。
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: '${workspace.name}'
                      '${isCurrent ? ' 当前工作区' : ''}'
                      '${expanded ? ' ${_sessionsLabel(sessions)}' : ' 已收起，点击展开'}',
                  child: InkWell(
                    onTap: onToggle,
                    borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
                    child: Padding(
                      padding: const EdgeInsets.all(DshMetrics.cardPad),
                      child: Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? DshColors.accentDim
                                  : DshColors.surfaceHigh,
                              borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                            ),
                            child: Icon(
                              isCurrent
                                  ? Icons.folder_open
                                  : Icons.folder_outlined,
                              size: 17,
                              color: isCurrent
                                  ? DshColors.accent
                                  : DshColors.textDim,
                            ),
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
                                        workspace.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: DshColors.text,
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    if (workspace.isDefault) ...[
                                      const SizedBox(width: 6),
                                      // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
                                      // ignore: prefer_const_constructors
                                      _Tag(text: context.tr('默认')),
                                    ],
                                    if (isCurrent) ...[
                                      const SizedBox(width: 6),
                                      // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
                                      // ignore: prefer_const_constructors
                                      _Tag(
                                          text: context.tr('当前'), accent: true),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  workspace.path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: DshColors.textFaint,
                                    fontSize: 10.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                // 收起时**不显示会话数**（用户明确要求：点开才展示
                                // 有多少会话），只给一句可展开的提示。
                                Text(
                                  expanded
                                      ? _sessionsLabel(sessions)
                                      : context.tr('点击展开会话'),
                                  style: TextStyle(
                                    color: DshColors.textDim,
                                    fontSize: 10.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (isCurrent)
                Icon(Icons.check_circle, size: 18, color: DshColors.accent)
              else
                Semantics(
                  button: true,
                  label: context.tr('切换到 {0}', [workspace.name]),
                  child: InkWell(
                    onTap: onSwitch,
                    borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: DshColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                      ),
                      child: Text(
                        context.tr('切换'),
                        style: TextStyle(color: DshColors.text, fontSize: 11.5),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 2),
              // 展开指示：纯装饰，不参与语义（避免又合并掉旁边的按钮）
              SizedBox(
                width: 22,
                child: Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: DshColors.textFaint,
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
          if (expanded) ...[
            Divider(height: 1, thickness: 0.5, color: DshColors.divider),
            if (sessions.isEmpty)
              SizedBox(
                height: 150,
                child: DshEmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: context.tr('暂无会话'),
                  hint:
                      context.tr('点底部的输入框开始一次对话，会话会出现在这里；本机历史会话由 DSH 的会话文件提供。'),
                ),
              )
            else
              for (final s in sessions)
                _SessionTile(
                  session: s,
                  onTap: () => onOpenSession(s),
                  onRename: () => _renameSession(context, s),
                ),
          ],
        ],
      ),
    );
  }
}

/// 会话改名弹层（意见⑥）。
///
/// 做成 StatefulWidget 的唯一理由与 [_NewWorkspaceDialog] 相同：
/// **控制器的生命周期要与对话框路由对齐**。
class _RenameSessionDialog extends StatefulWidget {
  const _RenameSessionDialog({required this.initial});

  final String initial;

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr('重命名会话')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(hintText: context.tr('给这条会话起个名字')),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          const SizedBox(height: 10),
          Text(
            context.tr(
                '这个名字只是本 App 的显示名 —— ACP 协议没有改名功能，DSH 那边这条会话不受影响。留空保存 = 恢复成默认显示。'),
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 11, height: 1.4),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('取消')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(context.tr('保存')),
        ),
      ],
    );
  }
}

/// 会话条目：点击 = 用 ACP `session/resume` 恢复这条会话。
class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.onTap,
    this.onRename,
  });

  final DshSession session;
  final VoidCallback onTap;

  /// 长按改名（意见⑥）。为空时不挂长按。
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${session.label}${session.hasTitle ? ' 本次运行' : ' 历史会话'}'
          '${session.createdLabel.isEmpty ? '' : ' ${session.createdLabel}'}',
      child: InkWell(
        onTap: session.resumable ? onTap : null,
        // 长按改名：历史会话也允许起个名，方便辨认（不用管能不能恢复）。
        onLongPress: onRename,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              DshMetrics.cardPad, 9, DshMetrics.cardPad, 9),
          child: Row(
            children: [
              Icon(
                session.live ? Icons.chat_bubble : Icons.history,
                size: 15,
                color: session.live ? DshColors.accent : DshColors.textFaint,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: DshColors.text, fontSize: 12.5),
                    ),
                    const SizedBox(height: 2),
                    // 意见 2（2026-10-15）：「会话都是可以显示时间和用了多少 tok」。
                    // 时间来自 ACP `session/list` 的 createdAt（取不到就如实说"时间未知"）；
                    // 用量来自投影缓存，**取不到就不显示那一段**（不编 0）。
                    Text(
                      <String>[
                        session.hasTitle
                            ? context.tr('本次运行 · {0}', [
                                session.createdLabel.isEmpty
                                    ? '刚刚'
                                    : session.createdLabel
                              ])
                            : context.tr('历史会话 · {0} · {1} · DSH 未提供标题', [
                                session.shortId,
                                session.createdLabel.isEmpty
                                    ? '时间未知'
                                    : session.createdLabel
                              ]),
                        if (session.tokensLabel.isNotEmpty) session.tokensLabel,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: DshColors.textFaint, fontSize: 10),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (session.resumable)
                Text(
                  context.tr('恢复'),
                  style: TextStyle(color: DshColors.accent, fontSize: 11.5),
                )
              else
                Text(
                  context.tr('暂不支持恢复'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.accent = false});

  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: accent ? DshColors.accentDim : DshColors.surfaceHigh,
        borderRadius: BorderRadius.circular(DshMetrics.radius(5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: accent ? DshColors.accent : DshColors.textDim,
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 底部账户区：**保留本机口径**（不写"体验版/积分"这类云端概念）。
class _AccountStrip extends StatelessWidget {
  const _AccountStrip({required this.screenH, required this.store});

  final double screenH;
  final WorkspaceStore store;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: (screenH * 0.063).clamp(48, 68),
      padding: const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: DshColors.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: DshColors.surfaceHigh,
              shape: BoxShape.circle,
            ),
            child: Text(
              context.tr('本'),
              style: TextStyle(
                color: DshColors.accent,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('本机用户'),
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                context.tr('本地运行时 · 非云端账户'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
              ),
            ],
          ),
          const Spacer(),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${store.allWorkspaces.length}',
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                context.tr('本机工作区'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
