/// 长会话助手的数据层（用户意见④）。
///
/// 对齐 `dsh-smart-compact` 的**用户价值** —— 「预算可见 + 笔记接力 + 主动换窗 +
/// 本地回读」，但**不动宿主**。原因很实在：手机上跑的是 `acp` profile，而那个插件
/// 的 `inject` 里硬要 `webServer`（只有 web profile 提供），在手机上**根本挂载不了**；
/// 就算绕开，它的压缩槽也被 `compaction-basic` 占着，还得给宿主打补丁 ——
/// 而手机的 DSH 是版本化 zip 解包树，一升级补丁就没了。
///
/// 所以这里走「App 侧等价实现」：用会话本身就有的信息做预算估算与笔记接力。
library;

/// 估算用的一条消息（只要角色与正文，不依赖 UI 层类型）。
class BudgetMessage {
  const BudgetMessage({required this.role, required this.text});

  /// `user` / `assistant` / `tool` / `thought`
  final String role;
  final String text;
}

/// 估算结果。
class ContextBudget {
  const ContextBudget({
    required this.chars,
    required this.estTokens,
    required this.windowTokens,
    required this.messages,
  });

  /// 计入的字符总数。
  final int chars;

  /// 估算的 token 数（**是估算**，见 [estimateContextBudget] 的口径）。
  final int estTokens;

  /// 当作多大的窗口来算。
  final int windowTokens;

  /// 计入的消息条数。
  final int messages;

  /// 0.0 ~ 1.0；> 1 表示按估算已经超窗。
  double get ratio => windowTokens <= 0 ? 0 : estTokens / windowTokens;

  /// 人读的百分比文案。
  String get percentLabel =>
      '${(ratio * 100).clamp(0, 999).toStringAsFixed(0)}%';

  /// 是否建议主动换窗（估算超过 70%）。
  bool get shouldRollover => ratio >= 0.7;
}

/// 估算上下文用量。
///
/// **口径故意保守**：中文约 1 token ≈ 1.5 字符、英文约 1 token ≈ 4 字符，
/// 这里统一按 **2 字符 ≈ 1 token** 估（估多不估少），并给每条消息加一点固定开销
/// （角色、分隔符）。工具输出往往最长，所以**全部计入**。
///
/// ⚠️ 这是估算，不是真实用量：ACP 目前不把 `usage` 推给客户端，界面文案必须
/// 写明「约」，不假装精确。
ContextBudget estimateContextBudget(
  List<BudgetMessage> messages, {
  int windowTokens = 128000,
}) {
  if (messages.isEmpty) {
    return ContextBudget(
      chars: 0,
      estTokens: 0,
      windowTokens: windowTokens,
      messages: 0,
    );
  }
  var chars = 0;
  for (final m in messages) {
    chars += m.text.length + 8;
  }
  return ContextBudget(
    chars: chars,
    estTokens: (chars / 2).round(),
    windowTokens: windowTokens,
    messages: messages.length,
  );
}

/// 生成一段「交接笔记」模板，交给用户确认后作为新会话的第一条消息。
///
/// **不替用户或模型编内容**：已知事实（消息条数、工作目录、产出过的文件）由 App 填，
/// 真正需要判断的部分（目标 / 已完成 / 未完成 / 关键决定 / 下一步）留成待填项，
/// 让模型在新窗口里自己写 —— 这正是 smart-compact「零模型调用换窗」的关键：
/// 换窗本身不调模型，笔记由模型在新窗口里补。
String buildHandoffNote({
  required int messageCount,
  String? sessionTitle,
  String? workspacePath,
  List<String> artifacts = const <String>[],
}) {
  final buf = StringBuffer();
  buf.writeln('这是一次**交接笔记**：上一个会话的上下文快写满了，我换了一张新窗口继续。');
  buf.writeln('请先读这份笔记，然后接着往下做，**不要把已经确认过的结论重新推翻**。');
  buf.writeln();
  buf.writeln('## 已知事实（由 App 记录，未经模型加工）');
  buf.writeln('- 上一会话共 $messageCount 条消息');
  if (sessionTitle != null && sessionTitle.trim().isNotEmpty) {
    buf.writeln('- 它的标题：${sessionTitle.trim()}');
  }
  if (workspacePath != null && workspacePath.isNotEmpty) {
    buf.writeln('- 工作目录：$workspacePath');
  }
  if (artifacts.isNotEmpty) {
    buf.writeln('- 它产生过的文件（共 ${artifacts.length} 个）：');
    for (final a in artifacts.take(20)) {
      buf.writeln('  - $a');
    }
    if (artifacts.length > 20) {
      buf.writeln('  - …还有 ${artifacts.length - 20} 个');
    }
  }
  buf.writeln();
  buf.writeln('## 需要你补的（请照着填，别留空）');
  buf.writeln('1. **目标**：我们原本要做什么？');
  buf.writeln('2. **已完成**：已经确认做完、验证过的事（尽量带证据/路径）。');
  buf.writeln('3. **未完成**：还差什么、卡在哪。');
  buf.writeln('4. **关键决定与理由**：为什么这么做（写下来，免得新窗口把它推翻）。');
  buf.writeln('5. **下一步**：紧接着要做的第一件事。');
  buf.writeln();
  buf.writeln('（模板可以删改；写完它就是新窗口的起点。）');
  return buf.toString();
}
