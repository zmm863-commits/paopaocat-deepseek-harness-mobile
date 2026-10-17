import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'dsh_runtime.dart';

/// Bot 团队的**名册**：读 `<DSH_HOME>/bot/state.json`。
///
/// ## 为什么可以直接读文件
///
/// ds-bot 自己就是这么设计的 —— 它的源码注释写着：
/// 「Every Bot is one root Session; the roster, rooms, and the bot-to-bot exchange log
/// live in one JSON file under DSH_HOME」。也就是说**名册与群聊都是明文 JSON**，
/// 不需要经过任何 API 或 ACP。本机实测确认：`bots` / `rooms` 的 key 就是 session id。
///
/// ## 为什么 App 要显示它
///
/// 用户的诉求（2026-10-17 原话）是「**在我 APP 会话界面一样的聊天**，不是网页内切」。
/// 做法因此变成：**用 App 自己那个原生聊天页去打开 Bot 的会话**（Bot 本来就是普通
/// 会话），这份名册只负责告诉界面「有哪些会话值得打开」。
///
/// ⚠️ 这里**只读、从不写**：Bot 的状态、名册、群聊全部由 ds-bot 自己维护；
/// App 一旦动手去改这个文件，就等于两套写入方打架。
class BotTeam {
  const BotTeam({
    this.bots = const <BotTeamBot>[],
    this.rooms = const <BotTeamRoom>[],
    this.workspaceId,
  });

  final List<BotTeamBot> bots;
  final List<BotTeamRoom> rooms;
  final String? workspaceId;

  bool get isEmpty => bots.isEmpty && rooms.isEmpty;

  /// 团队里现在**有没有主 Bot**。
  ///
  /// 为什么要单独判断：主 Bot 是 ds-bot 首次启动时自动建的（`bootstrap()` 里的
  /// `createBot({..., main: true})`）；而 `create-bot` 接口**不带 main 参数**，
  /// 所以用户手动建的永远是普通 Bot。如果用户把主 Bot 删了、再新建一个，
  /// 那个新 Bot 不会自己变成主 Bot —— 界面上又看不出来，就成了"群龙无首"。
  /// 所以新建流程会拿这个判断来决定要不要事后 `set-main`。
  bool get hasMainBot => bots.any((b) => b.isMain);

  /// Bot 的会话都在同一个工作区下（ds-bot 固定这么放）。
  ///
  /// ACP 的 `session/resume` 会**校验 cwd 与持久化时一致**（不一致直接报
  /// `session cwd does not match`），所以打开 Bot 会话时必须把这个路径原样传过去。
  static String workspaceOf(DshRuntime runtime) =>
      '${runtime.nodeHome}/bot/workspace';

  static File stateFileOf(DshRuntime runtime) =>
      File('${runtime.nodeHome}/bot/state.json');

  /// 读名册。**读不到就返回空**（不是错误）：机器人还没建过团队时这个文件本来就不存在，
  /// 界面该显示的是「还没有 Bot」，而不是一条报错。
  static BotTeam read(DshRuntime runtime) {
    try {
      final f = stateFileOf(runtime);
      if (!f.existsSync()) return const BotTeam();
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) return const BotTeam();
      return fromJson(Map<String, dynamic>.from(raw));
    } catch (e) {
      // 解析失败也不抛：这是"看一眼团队"的展示路径，不该因为它把页面打崩。
      debugPrint('[bot-team] 读 state.json 失败（按空处理）：$e');
      return const BotTeam();
    }
  }

  /// 从已解析的 JSON 建名册。抽出来是为了能单测（不碰文件系统）。
  static BotTeam fromJson(Map<String, dynamic> raw) {
    final mainIds = <String>{
      for (final v in (raw['mainBotIds'] as List? ?? const []))
        if (v is String) v,
    };
    final bots = <BotTeamBot>[];
    final botsRaw = raw['bots'];
    if (botsRaw is Map) {
      for (final entry in botsRaw.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final m = Map<String, dynamic>.from(v);
        final id = (m['id'] ?? entry.key).toString();
        bots.add(BotTeamBot(
          id: id,
          name: (m['name'] ?? '').toString(),
          role: (m['role'] ?? '').toString(),
          model: (m['appliedModel'] ?? m['model'])?.toString(),
          color: (m['color'] ?? '').toString(),
          isMain: mainIds.contains(id),
        ));
      }
    }
    // 主 Bot 排最前（界面上它是要紧的那个），其余按名字稳定排序。
    bots.sort((a, b) {
      if (a.isMain != b.isMain) return a.isMain ? -1 : 1;
      return a.name.compareTo(b.name);
    });

    final rooms = <BotTeamRoom>[];
    final roomsRaw = raw['rooms'];
    if (roomsRaw is Map) {
      for (final entry in roomsRaw.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final m = Map<String, dynamic>.from(v);
        rooms.add(BotTeamRoom(
          id: (m['id'] ?? entry.key).toString(),
          name: (m['name'] ?? '').toString(),
          memberCount: (m['members'] as List?)?.length ?? 0,
          adminId: (m['admin'])?.toString(),
          mode: m['mode']?.toString(),
        ));
      }
      rooms.sort((a, b) => a.name.compareTo(b.name));
    }

    return BotTeam(
      bots: bots,
      rooms: rooms,
      workspaceId: raw['workspaceId']?.toString(),
    );
  }
}

/// 一个 Bot。**注意它的 [id] 就是它自己那份会话的 sessionId**（本机实测：
/// `state` 返回的 `sessionId` 与 `bot.id` 相同；ds-bot 在只有一个会话段时就是如此）。
class BotTeamBot {
  const BotTeamBot({
    required this.id,
    required this.name,
    required this.role,
    this.model,
    this.color,
    this.isMain = false,
  });

  final String id;
  final String name;
  final String role;
  final String? model;
  final String? color;
  final bool isMain;

  /// 模型 route 的后半段（`polli/openai-fast` → `openai-fast`）。
  String get modelShort {
    final m = model;
    if (m == null || m.isEmpty) return '';
    final i = m.indexOf('/');
    return i >= 0 ? m.substring(i + 1) : m;
  }
}

/// 一个群聊。它的 [id] 同样是那份会话的 sessionId。
class BotTeamRoom {
  const BotTeamRoom({
    required this.id,
    required this.name,
    required this.memberCount,
    this.adminId,
    this.mode,
  });

  final String id;
  final String name;
  final int memberCount;
  final String? adminId;

  /// ds-bot 的「谁回答」：`admin`（默认，只交给主持人点名）或 `everyone`（全员轮流答）。
  final String? mode;

  /// 这个群是不是**只有主持人能开口**。
  ///
  /// 2026-10-17 对照实验（本机实测）：`mode=admin` **且确实有 admin** 时，
  /// 普通消息只交给 admin —— admin 不回，群里就"没人理"（用户抱怨的正是这个）；
  /// 而没有 admin 时，成员**都会**回答（实践上等同全员）。
  bool get onlyAdminAnswers =>
      (mode ?? 'admin') == 'admin' && (adminId != null && adminId!.isNotEmpty);

  /// 界面上怎么描述「谁回答」。
  String get whoAnswersLabel =>
      onlyAdminAnswers ? '只由主持人点名（@名字可指定）' : '全员都会回答';
}
