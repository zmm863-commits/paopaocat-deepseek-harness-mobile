import 'package:flutter/foundation.dart';

import '../data/workspace_store.dart';
import 'acp_client.dart';
import 'dsh_runtime.dart';
import 'session_projcache.dart';

/// 读磁盘上的会话索引（= ACP `session/list`）。
///
/// 为什么必须为它单开一个 ACP 连接：
///   * `session/list` 是 **ACP 连接级**的能力 —— 只有活着的
///     `dsh --profile acp` 子进程才能回答；
///   * DSH 把会话存成 `<DSH_HOME>/sessions/<cwd 编码>/<id>/session.v4.jsonl.zstd`，
///     而那是 **zstd 多帧**压缩文件，Dart 侧没有 zstd 解码器（`dart:io` 不提供），
///     界面层读不了它。
///
/// 这个连接**只用来列会话**：列完立刻关掉，不在界面期间常驻第二个 node 进程。
/// 代价是一次 node 启动（秒级），所以上层（[WorkspaceStore.refreshIndex]）会
/// 把结果缓存住，并且只在用户主动刷新/首次打开工作区页时才跑。
///
/// 失败**不吞**：异常向上抛，界面如实显示"会话索引读取失败：<原因>"。
Future<List<DshSession>> listPersistedSessions(
    {required DshRuntime runtime}) async {
  debugPrint('[ws-index] 开一次性 ACP 连接读 session/list…');
  final acp = await AcpClient.start(
    runtime: runtime,
    // cwd 用 filesDir：这次连接自己不开会话，只要一个合法目录即可。
    workspace: runtime.filesDir,
    overlayPath: runtime.hasModelConfig ? runtime.overlayPath : null,
    onLog: (m) => debugPrint('[ws-index]$m'),
  );

  try {
    final rows = await acp.listSessions();
    debugPrint('[ws-index] session/list 返回 ${rows.length} 条');
    // 顺手给每条会话标一个「是不是 0 消息空壳」（缺陷 A 的第二半）。
    //
    // 判据全在本地文件上（投影缓存 + 转录大小，见 session_projcache.dart），
    // **不额外起进程、不改协议**。标出来之后由界面决定要不要显示 ——
    // 这里不删任何东西：磁盘上的会话目录一个都不动，用户的数据永远还在。
    final sizes = scanTranscriptSizes(runtime.nodeHome);
    var shells = 0;
    var withUsage = 0;
    final out = <DshSession>[];
    // Bot 团队的会话（ds-bot 把它们统一放在 `<DSH_HOME>/bot/workspace` 下）**不混进
    // App 的工作区/会话列表**：那是 Bot 自己的内部工作区，对用户没有意义，
    // 而且这条路径编码成目录名会很长很难看（真机上就冒出来过一串乱名字）。
    // ⚠️ 这里只是**不显示**：磁盘上的会话一个都不动、也不删（与「空壳会话」同一原则）。
    final botWorkspace = '${runtime.nodeHome}/bot/workspace';
    var botSessions = 0;

    for (final r in rows) {
      // 宽松判据：不同版本的 ds-bot 可能把 DSH_HOME 放在别处，按后缀认更稳。
      if (r.cwd == botWorkspace || r.cwd.endsWith('/bot/workspace')) {
        botSessions++;
        continue;
      }
      final facts = readSessionFacts(
        dshHome: runtime.nodeHome,
        sessionId: r.sessionId,
        transcriptBytes: sizes,
      );
      final empty = facts.state == SessionContentState.empty;
      if (empty) shells++;
      if (facts.totalTokens != null) withUsage++;
      out.add(DshSession(
        id: r.sessionId,
        cwd: r.cwd,
        createdAt: r.createdAt,
        emptyShell: empty,
        totalTokens: facts.totalTokens,
      ));
    }
    if (botSessions > 0) {
      debugPrint('[ws-index] 跳过 $botSessions 条 Bot 团队会话（$botWorkspace；磁盘上仍在，只是不显示）');
    }
    if (shells > 0) {
      debugPrint('[ws-index] 其中 $shells 条是 0 消息空壳（列表里不显示；磁盘上仍在，没删）');
    }
    debugPrint('[ws-index] $withUsage/${rows.length} 条带 token 用量（取自投影缓存）');
    return out;
  } finally {
    // 无论成功失败都要把进程收掉：真机上多一个常驻 node 就是多一份内存。
    await acp.close();
  }
}
