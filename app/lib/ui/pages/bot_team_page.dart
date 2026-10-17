import 'dart:async';

import 'package:flutter/material.dart';

import '../../local/bot_server.dart';
import '../../local/bot_team.dart';
import '../../local/diagnostics_log.dart';
import '../../local/dsh_runtime.dart';
import '../theme/dsh_tokens.dart';
import 'bot_dialogs.dart';

/// 「Bot 团队」页 —— **不嵌网页**，只用 App 自己的风格列出来，点进去交给原生聊天页。
///
/// ## 为什么是这样（用户 2026-10-17 的纠正）
///
/// 我第一版把 dsh web 整个塞进 WebView，用户的反馈是：
/// 「**我想要的是在我 APP 会话界面一样的聊天，不是要的这种网页内切的方式**」。
/// 于是这一版换了思路 —— **Bot 本来就是普通会话**（ds-bot 源码原话：Every Bot is
/// one root Session），而 App 早就有自己的会话界面。所以：
///
///   * 这一页只做「**有哪些 Bot / 群聊**」的名册列表（读 `<DSH_HOME>/bot/state.json`，
///     明文 JSON）；
///   * 点任意一条 → 回调给壳层，用**现有的原生聊天页**（`ChatPage` + ACP resume）
///     把它打开 —— 界面上看到的就是用户熟悉的那个聊天页，一个字都不换。
///
/// ## 后台那个 web 服务为什么还留着
///
/// Bot 之所以会回话、会互相派活，是因为 **ds-bot 的宿主跑在一个 node 进程里**；
/// 而它需要一个页面宿主（`dsh-web-app` 带的连接层）才活得起来。所以 [BotServer]
/// 照旧要在后台把那个进程起起来 —— 但它**不再对用户可见**（没有 WebView 了）。
class BotTeamPage extends StatefulWidget {
  const BotTeamPage({
    super.key,
    required this.runtime,
    required this.onOpenSession,
  });

  final DshRuntime runtime;

  /// 点某个 Bot 或群聊时回调：交回它的 `sessionId` 与工作区，
  /// 由壳层用**现有的原生聊天页**打开。
  final void Function({
    required String sessionId,
    required String cwd,
    required String title,
  }) onOpenSession;

  @override
  State<BotTeamPage> createState() => _BotTeamPageState();
}

enum _Phase { starting, ready, failed }

class _BotTeamPageState extends State<BotTeamPage> {
  _Phase _phase = _Phase.starting;
  String? _error;
  String _lastLine = '';
  BotTeam _team = const BotTeam();
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    _poll?.cancel();
    // ⚠️ 刻意**不**停 [BotServer]：Bot 团队要接着在后台干活（它不是一个"页面服务"）。
    super.dispose();
  }

  Future<void> _boot() async {
    if (mounted) {
      setState(() {
        _phase = _Phase.starting;
        _error = null;
        _lastLine = '';
      });
    }
    try {
      // 宿主没起来的话，state.json 还是上一次的（甚至不存在）—— 先确保它在跑。
      await BotServer.ensureStarted(
        runtime: widget.runtime,
        onLog: (line) {
          if (!mounted) return;
          setState(() => _lastLine = line);
        },
      );
      if (!mounted) return;
      _reload();
      setState(() => _phase = _Phase.ready);
      // 名册是小 JSON，重读很便宜；3 秒一次让"刚建的 Bot / 刚开的群"能自己冒出来。
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) _reload();
      });
    } catch (e) {
      DiagnosticsLog.add('bot-team', '打开失败：$e');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '$e';
      });
    }
  }

  /// 上次读到的 `state.json` 修改时间（用于跳过无变化的轮询）。
  DateTime? _lastMtime;

  void _reload({bool force = false}) {
    // ⚠️ 先拿**文件修改时间**做闸门，再决定要不要解析。
    // 为什么：`state.json` 里的 `rooms[].log` 是**累积**的（每条群消息都留下），
    // 所以这个文件会随着使用一直变大（本机现在还只有几 KB，但长期能到几百 KB 甚至 MB）。
    // 每 3 秒把它整份读进来 + `jsonDecode`，在文件大的时候纯属白烧 CPU ——
    // 而绝大多数轮询间隔里它根本没变。
    final f = BotTeam.stateFileOf(widget.runtime);
    DateTime? mtime;
    try {
      mtime = f.existsSync() ? f.lastModifiedSync() : null;
    } catch (_) {
      // 读不到 mtime（少见）就当"有变化"走完整路径，宁可多解析一次也不要漏更新。
      mtime = null;
    }
    if (!force && mtime != null && mtime == _lastMtime) return;
    _lastMtime = mtime;

    final t = BotTeam.read(widget.runtime);
    // 内容没变就不 setState（避免整页反复重建）。
    final same = t.bots.length == _team.bots.length &&
        t.rooms.length == _team.rooms.length &&
        _sameIds(t);
    if (same && !force) return;
    setState(() => _team = t);
  }

  /// 切群的「谁回答」—— 这是用户抱怨「几方完全没有联系」的直接解法。
  ///
  /// 走 ds-bot 自己的 `update-room`（**不**直接改 state.json：那会变成两套写入方打架）。
  Future<void> _toggleRoomMode(BotTeamRoom r) async {
    final server = BotServer.current;
    if (server == null) {
      _snack('Bot 服务还没起来，稍后再试');
      return;
    }
    final toEveryone = r.onlyAdminAnswers;
    final target = toEveryone ? 'everyone' : 'admin';
    try {
      final res = await server.callApi(
        'update-room',
        <String, dynamic>{'id': r.id, 'mode': target},
      );
      final ok = res['ok'] == true;
      if (!ok) {
        final err = res['error'];
        final msg = err is Map ? (err['message'] ?? '$err') : '$err';
        _snack('改不动：$msg');
        return;
      }
      _snack(toEveryone ? '已改成「全员都会回答」' : '已改成「只由主持人点名」');
      _reload(force: true);
    } catch (e) {
      _snack('改不动：$e');
    }
  }

  /// 从 API 返回里抠出人能看懂的错因。
  String _errText(Map<String, dynamic> res) {
    final e = res['error'];
    if (e is Map) return (e['message'] ?? '$e').toString();
    return e?.toString() ?? '未知原因';
  }

  /// 新建一个 Bot（走 ds-bot 的 `create-bot`）。模型不传 —— 让它用团队默认的那个，
  /// 建好后可以在它的会话里改（免得在这里逼用户先选模型）。
  Future<void> _newBot() async {
    final server = BotServer.current;
    if (server == null) {
      _snack('Bot 服务还没起来，稍后再试');
      return;
    }
    final r = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const NewBotDialog(),
    );
    if (r == null || !mounted) return;
    final name = r['name'] ?? '';
    final role = r['role'] ?? '';
    try {
      final res = await server.callApi('create-bot', <String, dynamic>{
        'name': name,
        if (role.isNotEmpty) 'role': role,
      });
      if (res['ok'] == true) {
        _snack('已建好「$name」');
        _reload(force: true);
      } else {
        _snack('建不了：${_errText(res)}');
      }
    } catch (e) {
      _snack('建不了：$e');
    }
  }

  /// 新建群聊（走 `create-room`）。至少选两个成员，否则 ds-bot 也没法建。
  Future<void> _newRoom() async {
    final server = BotServer.current;
    if (server == null) {
      _snack('Bot 服务还没起来，稍后再试');
      return;
    }
    if (_team.bots.length < 2) {
      _snack('至少要两个 Bot 才能建群');
      return;
    }
    final r = await showDialog<Map<String, Object>>(
      context: context,
      builder: (_) => NewRoomDialog(candidates: _team.bots),
    );
    if (r == null || !mounted) return;
    final members = (r['members'] as List?)?.cast<String>() ?? const <String>[];
    final name = (r['name'] as String?) ?? '';
    try {
      final res = await server.callApi('create-room', <String, dynamic>{
        'members': members,
        if (name.isNotEmpty) 'name': name,
      });
      if (res['ok'] == true) {
        _snack('群聊建好了');
        _reload(force: true);
      } else {
        _snack('建不了：${_errText(res)}');
      }
    } catch (e) {
      _snack('建不了：$e');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  bool _sameIds(BotTeam t) {
    for (var i = 0; i < t.bots.length; i++) {
      if (t.bots[i].id != _team.bots[i].id) return false;
      if (t.bots[i].model != _team.bots[i].model) return false;
    }
    for (var i = 0; i < t.rooms.length; i++) {
      if (t.rooms[i].id != _team.rooms[i].id) return false;
    }
    return true;
  }

  void _open(String sessionId, String title) {
    widget.onOpenSession(
      sessionId: sessionId,
      cwd: BotTeam.workspaceOf(widget.runtime),
      title: title,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(
        backgroundColor: DshColors.navBg,
        foregroundColor: DshColors.text,
        // 它是底部导航的一项（不是推入的页），所以不该有返回箭头。
        automaticallyImplyLeading: false,
        title: const Text('Bot 团队'),
        actions: [
          if (_phase == _Phase.ready) ...[
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _reload();
                setState(() {});
              },
            ),
            // 新建入口：删掉网页界面之后，这里是**唯一**能加 Bot / 加群的地方。
            PopupMenuButton<String>(
              tooltip: '新建',
              icon: const Icon(Icons.add),
              onSelected: (v) {
                if (v == 'bot') unawaited(_newBot());
                if (v == 'room') unawaited(_newRoom());
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'bot', child: Text('新建 Bot')),
                PopupMenuItem(value: 'room', child: Text('新建群聊')),
              ],
            ),
          ],
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.starting:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                const Text('正在启动 Bot 团队…',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text(
                  '首次启动要把 Bot 的运行环境拉起来，大约 10~25 秒。\n（Bot 跑在本机，不用联网）',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: DshColors.textDim),
                ),
                if (_lastLine.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    _lastLine,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        color: DshColors.textDim,
                        fontFamily: DshFonts.mono),
                  ),
                ],
              ],
            ),
          ),
        );
      case _Phase.failed:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 44, color: DshColors.err),
                const SizedBox(height: 14),
                const Text('Bot 服务没能起来',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text(
                  _error ?? '（没有更多信息）',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: DshColors.textDim),
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: () => unawaited(_boot()), child: const Text('重试')),
              ],
            ),
          ),
        );
      case _Phase.ready:
        return _buildList();
    }
  }

  Widget _buildList() {
    if (_team.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, size: 44, color: DshColors.textDim),
              const SizedBox(height: 14),
              const Text('还没有 Bot',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(
                'Bot 团队是长在会话之上的：先在这个 App 的会话里让主 Bot 建几个 Bot，\n'
                '它们就会出现在这里，点进去就是你和它的聊天。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: DshColors.textDim),
              ),
            ],
          ),
        ),
      );
    }

    final mainBots = _team.bots.where((b) => b.isMain).toList();
    final others = _team.bots.where((b) => !b.isMain).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (mainBots.isNotEmpty) ...[
          _sectionTitle('主 Bot'),
          for (final b in mainBots) _botTile(b),
        ],
        if (others.isNotEmpty) ...[
          _sectionTitle('Bot（${others.length}）'),
          for (final b in others) _botTile(b),
        ],
        if (_team.rooms.isNotEmpty) ...[
          _sectionTitle('群聊（${_team.rooms.length}）'),
          for (final r in _team.rooms) _roomTile(r),
        ],
        const SizedBox(height: 14),
        Text(
          '点任意一条，就是你熟悉的那个聊天页 —— Bot 本来就是普通会话。\n'
          '群里没人接话时，点群右侧的按钮切「全员都会回答」，或在群里直接 @它的名字。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: DshColors.textFaint),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text(
          text,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: DshColors.textDim),
        ),
      );

  Widget _botTile(BotTeamBot b) => _tile(
        leading: _avatarDot(_colorOf(b.color)),
        title: b.name.isEmpty ? b.id : b.name,
        subtitle: [
          if (b.role.isNotEmpty) b.role,
          if (b.modelShort.isNotEmpty) b.modelShort,
        ].join(' · '),
        badge: b.isMain ? '主' : null,
        onTap: () => _open(b.id, b.name.isEmpty ? b.id : b.name),
      );

  Widget _roomTile(BotTeamRoom r) => _tile(
        leading: _avatarDot(DshColors.accent2),
        title: r.name.isEmpty ? r.id : r.name,
        // 「谁回答」直接摆出来 —— 用户看到的「几方完全没有联系」，
        // 根因就是这里：群交给主持人以后，普通消息只送到主持人那里。
        subtitle: '${r.memberCount} 位成员 · ${r.whoAnswersLabel}',
        badge: '群',
        onTap: () => _open(r.id, r.name.isEmpty ? r.id : r.name),
        trailing: IconButton(
          tooltip: r.onlyAdminAnswers ? '改成「全员都会回答」' : '改成「只由主持人点名」',
          icon: Icon(
            r.onlyAdminAnswers ? Icons.person_outline : Icons.groups_outlined,
            size: 19,
            color: DshColors.textDim,
          ),
          onPressed: () => unawaited(_toggleRoomMode(r)),
        ),
      );

  Widget _tile({
    required Widget leading,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? badge,
    Widget? trailing,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Material(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
          child: InkWell(
            borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15.5, fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (badge != null) ...[
                              const SizedBox(width: 7),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: DshColors.accentDim,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  badge,
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      color: DshColors.accent,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: DshColors.textDim),
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing ??
                      Icon(Icons.chevron_right,
                          size: 18, color: DshColors.textFaint),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _avatarDot(Color c) => Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.22),
          shape: BoxShape.circle,
          border: Border.all(color: c.withValues(alpha: 0.55), width: 1),
        ),
        child: Icon(Icons.smart_toy_outlined, size: 17, color: c),
      );

  /// ds-bot 的颜色是**名字**（它自己的 20 色表），不是色值 —— 这里做个最小映射，
  /// 认不出来的就退回强调色（不猜、也不报错）。
  Color _colorOf(String? name) {
    switch (name) {
      case 'deepseek':
        return DshColors.accent;
      case 'blue':
      case 'sky':
      case 'cobalt':
        return const Color(0xFF4A9EFF);
      case 'violet':
      case 'magenta':
      case 'rose':
        return const Color(0xFFB47CFF);
      case 'green':
      case 'aurora':
        return const Color(0xFF34C77B);
      case 'orange':
      case 'tangerine':
        return const Color(0xFFFF9F45);
      case 'red':
        return DshColors.err;
      case 'yellow':
        return const Color(0xFFE8C34A);
      case 'cyan':
        return const Color(0xFF38C7C7);
      case 'gray':
      case 'charcoal':
      case 'graphite':
      case 'black':
        return DshColors.textDim;
      default:
        return DshColors.accent;
    }
  }
}
