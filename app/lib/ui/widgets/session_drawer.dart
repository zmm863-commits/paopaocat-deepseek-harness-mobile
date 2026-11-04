import 'package:flutter/material.dart';

import '../../data/workspace_store.dart';
import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';

/// 左侧「会话」抽屉（2026-10-23，改造 C）。
///
/// 用户参照同类产品提的交互：「左上角点击符号，左侧拉出会话列表，能看到会话，
/// 点击就能到会话页面」。所以这里刻意做成**左侧抽屉 + 点一条就切过去**，
/// 而不是现在那个"右上角 → 整页工作区 → 展开工作区 → 点会话"的四步。
///
/// 三段：
///   1. 顶部：新建会话 / 回首页
///   2. **正在运行**（本次 App 里还活着、可能正在跑回答的会话）—— 排最前，
///      因为"同时进行"的会话最先要能找到；
///   3. 历史会话（磁盘上的），点一条恢复它。
///
/// 数据是**外部喂进来的**（[live] / [loadHistory]），抽屉自己不碰运行时：
/// 这样它能在 widget 测试里独立渲染，也不会偷偷起进程。
class SessionDrawer extends StatefulWidget {
  const SessionDrawer({
    super.key,
    required this.onNewChat,
    required this.onHome,
    required this.onPick,
    this.currentSessionId,
    this.live = const <DrawerSession>[],
    this.loadHistory,
    this.workspaceLabel,
  });

  /// 新建一个会话。
  final VoidCallback onNewChat;

  /// 回首页（抽屉底部，给没有返回键的场景留一条路）。
  final VoidCallback onHome;

  /// 点了一条会话 → 打开它（壳层负责"最多留一个会话页"）。
  final void Function(DrawerSession session) onPick;

  /// 当前页正在看的会话（抽屉里高亮）。
  final String? currentSessionId;

  /// 本次运行中活着的会话。
  final List<DrawerSession> live;

  /// 磁盘历史会话。为 null 时这一段不显示（单测里没有运行时）。
  final Future<List<DshSession>> Function()? loadHistory;

  /// 抽屉副标题里显示的当前工作区名。
  final String? workspaceLabel;

  @override
  State<SessionDrawer> createState() => _SessionDrawerState();
}

/// 抽屉里的一行（会话）。live 与历史共用它，避免两套渲染逻辑。
class DrawerSession {
  const DrawerSession({
    required this.sessionId,
    required this.title,
    required this.cwd,
    this.running = false,
    this.live = false,
    this.subtitle,
  });

  final String sessionId;
  final String title;
  final String cwd;

  /// 正在生成回答（行尾显示"回答中"小标）。
  final bool running;

  /// 本次 App 里还活着（进程没回收）。
  final bool live;

  /// 额外说明（磁盘会话用它显示"空会话"/"未开始"之类）。
  final String? subtitle;
}

class _SessionDrawerState extends State<SessionDrawer> {
  List<DshSession> _history = const <DshSession>[];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loader = widget.loadHistory;
    if (loader == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await loader();
      if (!mounted) return;
      setState(() {
        _history = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final liveIds = {for (final s in widget.live) s.sessionId};
    final history = _history.where((s) => !liveIds.contains(s.id)).toList();

    return Drawer(
      backgroundColor: DshColors.bg,
      width: MediaQuery.sizeOf(context).width * 0.82,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            Divider(height: 1, color: DshColors.divider),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  if (widget.live.isNotEmpty) ...[
                    _sectionTitle(context, context.tr('正在进行的会话')),
                    for (final s in widget.live)
                      _row(
                        context,
                        title: s.title,
                        subtitle: s.subtitle,
                        running: s.running,
                        selected: s.sessionId == widget.currentSessionId,
                        onTap: () => widget.onPick(s),
                      ),
                  ],
                  _sectionTitle(context, context.tr('历史会话')),
                  if (_loading)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(context.tr('正在读磁盘上的会话…'),
                          style: TextStyle(
                              color: DshColors.textDim, fontSize: 12.5)),
                    )
                  else if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        context.tr('会话列表读不出来：{0}', [_error!]),
                        style: TextStyle(color: DshColors.err, fontSize: 12.5),
                      ),
                    )
                  else if (history.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(context.tr('还没有别的会话'),
                          style: TextStyle(
                              color: DshColors.textDim, fontSize: 12.5)),
                    )
                  else
                    for (final s in history)
                      _row(
                        context,
                        title: (s.title == null || s.title!.trim().isEmpty)
                            ? context.tr('未命名会话')
                            : s.title!,
                        subtitle: _historySubtitle(s),
                        selected: s.id == widget.currentSessionId,
                        onTap: () => widget.onPick(DrawerSession(
                          sessionId: s.id,
                          title: (s.title == null || s.title!.trim().isEmpty)
                              ? context.tr('未命名会话')
                              : s.title!,
                          cwd: s.cwd,
                          subtitle: s.emptyShell
                              ? context.tr('空会话')
                              : null,
                        )),
                      ),
                ],
              ),
            ),
            Divider(height: 1, color: DshColors.divider),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.tr('会话'),
                    style: TextStyle(
                        color: DshColors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                if (widget.workspaceLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      context.tr('本机 · {0}', [widget.workspaceLabel!]),
                      style:
                          TextStyle(color: DshColors.textDim, fontSize: 11.5),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.tr('关闭'),
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(text,
          style: TextStyle(
              color: DshColors.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _row(
    BuildContext context, {
    required String title,
    required VoidCallback onTap,
    bool running = false,
    bool selected = false,
    String? subtitle,
  }) {
    return Semantics(
      button: true,
      selected: selected,
      label: title,
      child: InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? DshColors.accentDim : Colors.transparent,
            borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          ),
          child: Row(
            children: [
              Icon(
                running ? Icons.graphic_eq : Icons.chat_bubble_outline,
                size: 15,
                color: running ? DshColors.accent : DshColors.textDim,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? DshColors.accent : DshColors.text,
                        fontSize: 13.5,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle,
                            style: TextStyle(
                                color: DshColors.textDim, fontSize: 11)),
                      ),
                  ],
                ),
              ),
              if (running)
                Text(context.tr('回答中'),
                    style:
                        TextStyle(color: DshColors.accent, fontSize: 10.5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              onPressed: () {
                Navigator.of(context).maybePop();
                widget.onNewChat();
              },
              icon: const Icon(Icons.add, size: 17),
              label: Text(context.tr('新建会话')),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () {
                Navigator.of(context).maybePop();
                widget.onHome();
              },
              icon: const Icon(Icons.home_outlined, size: 17),
              label: Text(context.tr('回首页')),
            ),
          ),
        ],
      ),
    );
  }

  /// 历史行的副标题：时间 + （空会话）如实标注。
  ///
  /// 「空会话」= 打开过但一句没发（见 `local/session_projcache.dart`）。
  /// 为什么要显示：这类会话点进去是白板，不标的话用户会以为"我的对话丢了"。
  String? _historySubtitle(DshSession s) {
    final parts = <String>[];
    if (s.createdAt != null) parts.add(_dateLabel(s.createdAt!));
    if (s.emptyShell) parts.add(context.tr('空会话'));
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  static String _dateLabel(DateTime t) {
    final now = DateTime.now();
    final d = now.difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 7) return '${d.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }
}
