import 'dart:async' show Timer;

import 'package:flutter/material.dart';

import '../../data/artifact_opener.dart';
import '../../data/artifacts.dart';
import '../theme/dsh_tokens.dart';
import 'common.dart';

import '../../i18n/dsh_i18n.dart';
import '../cards/card_renderer.dart';
import '../cards/card_schema.dart';

enum ChatRole { user, assistant, thought, tool }

/// 消息流里的一条。字段沿用改造前的结构（工具调用那几项一个没动），
/// 只是搬到了一个独立文件里，方便新增产物卡片而不把 chat_page 撑爆。
class ChatMsg {
  ChatMsg({
    required this.text,
    required this.role,
    this.failed = false,
    this.detail,
    this.toolId,
    this.toolTitle,
    this.toolCommand,
    this.toolStatus,
    this.toolOutput,
    this.startedAt,
    this.endedAt,
  });

  String text;
  final ChatRole role;
  final bool failed;

  /// 思考块**开始**的时刻（只有 thought 消息有值）。
  ///
  /// 用来在回合结束后给一句「思考了 N 秒」（见 [_ThoughtRow]）。
  /// 拿不到就退回旧行为（留 4 行正文），**不编时间**。
  DateTime? startedAt;

  /// 思考块**结束**的时刻：被下一段思考 / 正式回答 / 工具调用打断，
  /// 或者回合结束时定下来。
  DateTime? endedAt;

  /// **技术细节**（原始报错）。
  ///
  /// 为什么要和 [text] 分开：用户反馈"会话里看到很多失败，会把用户吓跑"。
  /// 所以界面上默认只显示一句**人话**（能看懂、知道下一步），
  /// 原始报错折在"技术细节"里 —— 需要排查时点开就能看到，不丢证据。
  String? detail;

  String? toolId;
  String? toolTitle;
  String? toolCommand;
  String? toolStatus;
  String? toolOutput;
}

/// 消息流（设计稿 `page-11`：顶部 `内容由AI生成`，下面依次是消息/状态/产物）。
class MessageStream extends StatelessWidget {
  const MessageStream({
    super.key,
    required this.messages,
    required this.artifacts,
    required this.running,
    required this.controller,
    required this.onOpenArtifacts,
    this.cwd,
    this.turnStartedAt,
    this.thinkingMode = 'collapsed',
  });

  final List<ChatMsg> messages;
  final List<Artifact> artifacts;
  final bool running;
  final ScrollController controller;
  final VoidCallback onOpenArtifacts;

  /// 思考块怎么显示：`collapsed` / `expanded` / `hidden`
  /// （取值来自 `AppSettings.thinkingModeId`，见那里关于"为什么需要不显示"的说明）。
  final String thinkingMode;

  /// 会话的工作目录（产物预览显示相对路径用）
  final String? cwd;

  /// 这一轮的开始时刻；非空时运行行会多显示「已等待 M:SS」（审计 P1-1）。
  final DateTime? turnStartedAt;

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    final itemCount = messages.length + 1; // 第 0 项是「内容由AI生成」提示

    return ListView.builder(
      controller: controller,
      // 设计稿（page-11）：`内容由AI生成` 文字带 403~442，也就是正文顶边
      // 在设计稿里是 403/2640 = 15.3%，减去顶栏（11.1%）后的留白 ≈ 4.2% 屏高；
      // 但那段留白里还有顶栏自己的 370~403 空白，所以这里只补一点点。
      padding: EdgeInsets.fromLTRB(
          DshMetrics.pagePad, screenH * 0.006, DshMetrics.pagePad, 14),
      itemCount: itemCount + (running ? 1 : 0),
      itemBuilder: (context, i) {
        // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
        // ignore: prefer_const_constructors
        if (i == 0) return _AiNotice();
        if (i == itemCount) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: DshColors.accent,
                  ),
                ),
                const SizedBox(width: 9),
                Text(context.tr('正在处理…'),
                    style: TextStyle(fontSize: 12, color: DshColors.textDim)),
                // 「已等待 M:SS」（审计 P1-1）。
                //
                // 为什么放在**这里**而不是顶栏：顶栏很挤（三个按钮在 320dp 上
                // 已经接近溢出，见 chat_page 里 _actionStyle 的注释），而这一行
                // 在消息流里、全宽，而且正好是用户盯着看的地方。
                //
                // 为什么值得显示：旧行为是"只有一个转圈"，最长能静默 10 分钟，
                // 用户分不清"在算"还是"卡死了"。数字每秒自己走，至少能判断
                // "还在动 / 没动"，旁边就是停止按钮。
                if (turnStartedAt != null) ...[
                  Text(' · ',
                      style: TextStyle(fontSize: 12, color: DshColors.textDim)),
                  _ElapsedText(startedAt: turnStartedAt!),
                ],
              ],
            ),
          );
        }
        final msg = messages[i - 1];
        final block = switch (msg.role) {
          // 这一轮还没结束、并且它是最新一条 → 这段思考**还在长**，先别折叠。
          ChatRole.thought => _ThoughtRow(
              msg: msg,
              mode: thinkingMode,
              streaming: running && i == messages.length,
            ),
          ChatRole.tool => ToolCallCard(msg: msg),
          ChatRole.user => _UserBubble(msg: msg),
          ChatRole.assistant => _AssistantBlock(
              msg: msg,
              artifacts: artifacts,
              onOpenArtifacts: onOpenArtifacts,
              cwd: cwd,
            ),
        };
        // 「上下文 / 待办」提示条插在第一条消息之前。
        // 设计稿 page-01/11 正文上方那条分隔+提示就是这个位置（y≈403）。
        if (i != 1) return block;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_ContextBanner(messages: messages), block],
        );
      },
    );
  }
}

/// 「待办 / 上下文」提示条。
///
/// 内容**不编造**：只从真实的 `todo` 工具输出里摘 `- [ ]` 条目；
/// 一条都没有时整条不渲染，不会为了对齐设计稿放假数据。
class _ContextBanner extends StatelessWidget {
  const _ContextBanner({required this.messages});

  final List<ChatMsg> messages;

  /// 从 tool 消息里抽未完成项。
  ///
  /// 认两种写法（DSH 的 todo 工具输出就是 Markdown 复选框）：
  ///   `- [ ] 未完成`
  ///   `- [x] 已完成`
  static List<String> pendingFrom(List<ChatMsg> messages) {
    final pending = <String>[];
    for (final m in messages) {
      if (m.role != ChatRole.tool) continue;
      final out = m.toolOutput;
      if (out == null || out.isEmpty) continue;
      for (final line in out.split('\n')) {
        final t = line.trim();
        final undone = RegExp(r'^[-*]\s*\[\s\]\s*\S').firstMatch(t);
        if (undone != null) {
          final text = t.replaceFirst(RegExp(r'^[-*]\s*\[\s\]\s*'), '').trim();
          if (text.isNotEmpty && !pending.contains(text)) pending.add(text);
          continue;
        }
        // 已完成的行从待办里划掉（同一个 todo 工具会被反复调用）
        final done = RegExp(r'^[-*]\s*\[[xX]\]\s*\S').firstMatch(t);
        if (done != null) {
          final text =
              t.replaceFirst(RegExp(r'^[-*]\s*\[[xX]\]\s*'), '').trim();
          pending.remove(text);
        }
      }
    }
    return pending;
  }

  @override
  Widget build(BuildContext context) {
    final pending = pendingFrom(messages);
    if (pending.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(
          horizontal: DshMetrics.cardPad, vertical: 9),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.checklist, size: 14, color: DshColors.accent),
              const SizedBox(width: 7),
              Text(
                context.tr('待办 {0} 项', [pending.length]),
                style: TextStyle(
                  color: DshColors.textDim,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final t in pending.take(4))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '· $t',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: DshColors.textFaint, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

/// 设计稿里正文上方那行 `内容由AI生成`（y≈371~409，居中，弱化色）。
///
/// 与首条消息的间距取设计稿比例：371→547 之间夹着这行字本身，
/// 换算下来"字底到正文顶"约 4.4% 屏高，扣掉行高后取 9dp。
class _AiNotice extends StatelessWidget {
  const _AiNotice();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 9),
      child: Text(
        context.tr('内容由AI生成'),
        textAlign: TextAlign.center,
        style: TextStyle(color: DshColors.textFaint, fontSize: 11.5),
      ),
    );
  }
}

/// 用户消息：设计稿里是一个左对齐的长文本块，超长时给「展开」。
///
/// 注意设计稿的用户消息**不是右侧小气泡**（和常见聊天 App 不同），
/// 而是一段占满宽度的正文 + 左下角 `展开∨`。这里照设计稿来。
class _UserBubble extends StatefulWidget {
  const _UserBubble({required this.msg});

  final ChatMsg msg;

  @override
  State<_UserBubble> createState() => _UserBubbleState();
}

class _UserBubbleState extends State<_UserBubble> {
  bool _expanded = false;

  /// 超过这个长度才给「展开」（设计稿里短消息没有展开按钮）
  static const int _collapseThreshold = 90;

  /// 折叠时显示的行数。设计稿 page-02 的样例长消息折叠后正好 5 行正文。
  static const int _collapsedLines = 5;

  @override
  Widget build(BuildContext context) {
    final text = widget.msg.text;
    final needCollapse = text.length > _collapseThreshold;

    return Container(
      width: double.infinity,
      // 设计稿：用户消息末行 785~842 → 下方 `展开√` 885~938，
      // 再往下 `已完成` 1057~1105。也就是"正文底 → 展开"约 2% 屏高，
      // 换算后块与块之间约 10dp。
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(DshMetrics.cardPad),
      // 网站的卡片观感：半透明底 + 1px 细边 + 大圆角（+ 柔和光晕）
      decoration: DshColors.panel(color: DshColors.userBubble),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 可选中复制（用户反馈「会话页面的对话无法复制」）。
          // 这里用 SelectionArea 包 Text，而不是换成 SelectableText：
          // SelectableText 不支持 overflow.ellipsis，会让下面「展开/收起」的折叠失效。
          SelectionArea(
            child: Text(
              text,
              maxLines: (!_expanded && needCollapse) ? _collapsedLines : null,
              overflow:
                  (!_expanded && needCollapse) ? TextOverflow.ellipsis : null,
              style:
                  TextStyle(color: DshColors.text, fontSize: 13.5, height: 1.5),
            ),
          ),
          if (needCollapse)
            Semantics(
              button: true,
              label: _expanded ? context.tr('收起用户消息') : context.tr('展开用户消息'),
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _expanded ? context.tr('收起') : context.tr('展开'),
                        style: TextStyle(color: DshColors.accent, fontSize: 12),
                      ),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 15,
                        color: DshColors.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 思考块：设计稿里没有单独展示（应该是折叠进"已完成"的），
/// 这里保持弱化折行，便于排查模型行为，不抢版面对齐的注意力。
///
/// 2026-10-12（用户：「思考过程都是英文的，这个怎么回避」）—— 这里的显示方式
/// 改成跟设置走，三档：`collapsed`（默认，收起 + 可点开）/ `expanded`（全文）/
/// `hidden`（**完全不渲染**）。
///
/// ⚠️ 为什么"不显示"是必要的：思考用哪种语言**是模型训练出来的倾向**，
/// 我们往 `AGENTS.md` 里写「用中文思考」只能提高概率、不能保证。
/// 想让用户"绝对看不到英文思考"，唯一的硬保证就是**根本不画它**。
class _ThoughtRow extends StatefulWidget {
  const _ThoughtRow({
    required this.msg,
    this.mode = 'collapsed',
    this.streaming = false,
  });

  final ChatMsg msg;

  /// `collapsed` / `expanded` / `hidden`（见 `AppSettings.kThinkingModeIds`）。
  final String mode;

  /// 这一段**还在长**（这一轮没结束，且它是最新一条）。
  ///
  /// 流式期间不折叠：思考每长一点都可能跨过折叠阈值，一折叠就是"字突然消失"
  /// 的跳变，观感上就是"卡一下"。等这一轮结束再收起来。
  final bool streaming;

  @override
  State<_ThoughtRow> createState() => _ThoughtRowState();
}

class _ThoughtRowState extends State<_ThoughtRow> {
  /// 思考默认折到几行：给个"看见有这么一段"的量，又不至于把版面顶开。
  static const int _collapsedLines = 4;

  /// 超过这个长度才值得折叠（短思考直接显示全文，不给一个点了没反应的按钮）。
  static const int _collapseThreshold = 160;

  /// 用户点了「展开」——只对**这一条**生效（不是全局改设置）。
  bool _expandedHere = false;

  /// 这一段思考花了多久。
  ///
  /// 拿不到（回放的老会话没有时间戳 / 页面被销毁时没收尾）就返回 null ——
  /// 那时界面退回旧行为，**不编一个时间出来**。
  Duration? get _duration {
    final s = widget.msg.startedAt;
    final e = widget.msg.endedAt;
    if (s == null || e == null) return null;
    final d = e.difference(s);
    return d.isNegative ? Duration.zero : d;
  }

  /// 结束后要不要给「展开/收起」按钮（流式中不给：那时已经全文铺开了）。
  bool get _showToggle =>
      widget.mode == 'collapsed' &&
      !widget.streaming &&
      widget.msg.text.length > _collapseThreshold;

  @override
  Widget build(BuildContext context) {
    if (widget.mode == 'hidden') return const SizedBox.shrink();

    final text = widget.msg.text;
    // 短思考（没到阈值）没什么可折的，别给一个点了没反应的「展开」。
    final needCollapse = text.length > _collapseThreshold;
    // 回合结束后，长思考收成**一行摘要**（对标 WorkBuddy 的
    // `tool_call_process_preview`：结束后只留一行，点开才看全文）。
    final canOneLine = needCollapse && !widget.streaming && widget.mode == 'collapsed';
    final oneLine = canOneLine && !_expandedHere;
    final showAll = widget.streaming ||
        widget.mode == 'expanded' ||
        _expandedHere ||
        !needCollapse;

    // AnimatedSize：折叠/展开、以及流式时长高变化都走同一段 160ms 的补间，
    // 不再"瞬移"。这是"看起来顺不顺"最直接的一处。
    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: oneLine
            ? _oneLineRow(context)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SelectionArea(child: _body(context, text, showAll)),
                  if (_showToggle) _toggle(context, inline: false),
                ],
              ),
      ),
    );
  }

  /// 正文。流式时套一层底部渐隐（见 [_BottomFade]）。
  Widget _body(BuildContext context, String text, bool showAll) {
    final t = Text(
      text,
      maxLines: showAll ? null : _collapsedLines,
      overflow: showAll ? null : TextOverflow.ellipsis,
      style: TextStyle(
          color: DshColors.textFaint, fontSize: 11.5, height: 1.45),
    );
    // 只有**正在长**的时候才渐隐：结束后文字是完整的，淡掉反而像缺字。
    if (!widget.streaming) return t;
    return _BottomFade(child: t);
  }

  /// 结束后的单行摘要：「思考了 12 秒 · 展开」。
  ///
  /// 时长不足 1 秒（或者根本没有时间戳）就只写「思考」——
  /// **宁可少说，也不要编一个"思考了 0 秒"**。
  Widget _oneLineRow(BuildContext context) {
    final d = _duration;
    final label = (d == null || d.inSeconds < 1)
        ? context.tr('思考')
        : _durationLabel(context, d);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
              color: DshColors.textFaint, fontSize: 11.5, height: 1.2),
        ),
        const SizedBox(width: 8),
        _toggle(context, inline: true),
      ],
    );
  }

  /// 「思考了 12 秒」/「思考了 1 分 05 秒」。
  String _durationLabel(BuildContext context, Duration d) {
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    if (s < 60) return context.tr('思考了 {0} 秒', [s]);
    return context.tr('思考了 {0} 分 {1} 秒', [s ~/ 60, s % 60]);
  }

  /// 「展开 / 收起」按钮。[inline] = 放在摘要那一行里（而不是正文下面）。
  Widget _toggle(BuildContext context, {required bool inline}) {
    return Semantics(
      button: true,
      label: _expandedHere ? context.tr('收起思考') : context.tr('展开思考'),
      child: InkWell(
        onTap: () => setState(() => _expandedHere = !_expandedHere),
        child: Padding(
          padding: inline
              ? const EdgeInsets.symmetric(vertical: 1)
              : const EdgeInsets.only(top: 2, bottom: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _expandedHere ? context.tr('收起') : context.tr('展开'),
                style: TextStyle(
                    color: DshColors.textFaint,
                    fontSize: 11,
                    height: 1.2),
              ),
              Icon(
                _expandedHere
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 14,
                color: DshColors.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部渐隐：流式时"新字从雾里出来"。
///
/// 做法：`ShaderMask` + `BlendMode.dstIn` —— 让最后 [_fade] 像素的 alpha 归零，
/// 底下透出页面背景，看上去就是"字从雾里浮出来"。
///
/// 为什么不用 Lottie：WorkBuddy 那边跑的是 `deep_thinking.json`，
/// 但**新增依赖要动 pubspec 的资产清单**（见 MASTER §F.1），观感差别却就在这一层——
/// 渐隐便宜得多，也不占帧。
class _BottomFade extends StatelessWidget {
  const _BottomFade({required this.child});

  final Widget child;

  /// 渐隐的高度（逻辑像素）。
  static const double _fade = 28;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final h = bounds.height;
        // 文字比渐隐区还短 → 整段都不淡（否则最后一行会淡到看不见）。
        if (h <= _fade) {
          return const LinearGradient(
            colors: <Color>[Colors.white, Colors.white],
          ).createShader(bounds);
        }
        // 前 (h - fade) 像素全不透明，最后 fade 像素线性淡到 0。
        final start = (h - _fade) / h;
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const <Color>[
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: <double>[0, start, 1],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}

/// 「已完成」状态行（设计稿 y≈1057，左侧带一个勾）
class _DoneRow extends StatelessWidget {
  const _DoneRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.check_circle, size: 14, color: DshColors.ok),
          const SizedBox(width: 7),
          Text(context.tr('已完成'),
              style: TextStyle(color: DshColors.textDim, fontSize: 12.5)),
        ],
      ),
    );
  }
}

/// 助手回复块：`已完成` + 正文 + 产物卡片摘要。
///
/// 设计稿 page-02 / 11 的层级是：用户长消息（可展开）→ `已完成` → 助手正文。
/// 助手正文本身也可能很长（page-11 里就跨了好几屏），所以同样给「展开/收起」，
/// 默认折叠到 [_collapsedLines] 行 —— 上一轮只给用户消息做了展开，这里补齐。
class _AssistantBlock extends StatefulWidget {
  const _AssistantBlock({
    required this.msg,
    required this.artifacts,
    required this.onOpenArtifacts,
    this.cwd,
  });

  final ChatMsg msg;
  final List<Artifact> artifacts;
  final VoidCallback onOpenArtifacts;

  /// 会话的工作目录（产物预览显示相对路径用）
  final String? cwd;

  @override
  State<_AssistantBlock> createState() => _AssistantBlockState();
}

class _AssistantBlockState extends State<_AssistantBlock> {
  bool _expanded = false;

  /// 「技术细节」是否展开（默认收起 —— 用户不想一进来就看见报错原文）。
  bool _detailOpen = false;

  /// 超过这个长度才折叠
  static const int _collapseThreshold = 220;
  static const int _collapsedLines = 8;

  @override
  Widget build(BuildContext context) {
    final msg = widget.msg;
    final text = msg.text;
    // 失败信息不折叠：报错被截断会让人查不出原因
    final needCollapse = !msg.failed && text.length > _collapseThreshold;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
        // ignore: prefer_const_constructors
        if (!msg.failed)
          // ignore: prefer_const_constructors
          _DoneRow()
        else
          // 用户反馈：「会话的时候，看到很多失败，会把用户吓跑的」。
          // 所以失败不用红色警示条开场 —— 一个安静的提示图标就够，
          // 具体怎么回事写在下面那句人话里，原始报错折在"技术细节"里。
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: <Widget>[
                // ignore: prefer_const_constructors（DshColors 是运行时变量）
                Icon(Icons.info_outline, size: 14, color: DshColors.textFaint),
                const SizedBox(width: 5),
                Text(context.tr('没能完成'),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 11, height: 1.4)),
              ],
            ),
          ),
        if (text.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 9),
            padding: const EdgeInsets.all(DshMetrics.cardPad),
            decoration: DshColors.panel(color: DshColors.aiBubble),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 可选中复制（同上：助手回复是用户最常想复制的内容）。
                SelectionArea(
                  child: Text(
                    text,
                    maxLines:
                        (!_expanded && needCollapse) ? _collapsedLines : null,
                    overflow: (!_expanded && needCollapse)
                        ? TextOverflow.ellipsis
                        : null,
                    style: TextStyle(
                      // 失败也用正常文字色（原来是大红字 + 等宽，看着像系统崩了）
                      color: msg.failed ? DshColors.textDim : DshColors.text,
                      fontSize: msg.failed ? 12.5 : 13.5,
                      height: 1.55,
                    ),
                  ),
                ),
                if (msg.failed && (msg.detail?.isNotEmpty ?? false))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Semantics(
                          button: true,
                          label: _detailOpen
                              ? context.tr('收起技术细节')
                              : context.tr('技术细节'),
                          child: InkWell(
                            onTap: () =>
                                setState(() => _detailOpen = !_detailOpen),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: <Widget>[
                                  Icon(
                                    _detailOpen
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    size: 15,
                                    color: DshColors.textFaint,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    context.tr('技术细节'),
                                    style: TextStyle(
                                        color: DshColors.textFaint,
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (_detailOpen)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: SelectionArea(
                              child: Text(
                                msg.detail!,
                                style: TextStyle(
                                  color: DshColors.textFaint,
                                  fontSize: 11,
                                  height: 1.5,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (needCollapse)
                  Semantics(
                    button: true,
                    label: _expanded ? context.tr('收起回复') : context.tr('展开回复'),
                    child: InkWell(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _expanded ? context.tr('收起') : context.tr('展开'),
                              style: TextStyle(
                                  color: DshColors.accent, fontSize: 12),
                            ),
                            Icon(
                              _expanded
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                              size: 15,
                              color: DshColors.accent,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (widget.artifacts.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(DshMetrics.cardPad),
            decoration: DshColors.panel(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DshSectionLabel(
                  context.tr('产物'),
                  trailing: Semantics(
                    button: true,
                    child: InkWell(
                      onTap: widget.onOpenArtifacts,
                      child: Text(
                        context.tr('全部'),
                        style: TextStyle(color: DshColors.accent, fontSize: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final a in widget.artifacts.take(3))
                  _ArtifactRow(artifact: a, cwd: widget.cwd),
              ],
            ),
          ),
      ],
    );
  }
}

/// 产物行（设计稿 page-02 里正文中的 `《XX家族_AI漫剧通用剧本模板.md》`）
///
/// **可点击**：点它打开文件 —— 路径在产物进列表前已经核实过，直接用
/// （见 [ArtifactOpener]）。之前这行没有 onTap，用户点了没反应。
///
/// **可分享**：右侧分享按钮 + 长按整行，都是「解析出真实路径、再拉起
/// 系统分享面板」。解析不到就如实说「找不到这个文件」，绝不假装分享成功。
class _ArtifactRow extends StatelessWidget {
  const _ArtifactRow({required this.artifact, this.cwd});

  final Artifact artifact;

  /// 会话的工作目录（预览页显示相对路径用）
  final String? cwd;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => ArtifactOpener.open(context, artifact, cwd: cwd),
      onLongPress: () => ArtifactOpener.share(context, artifact, cwd: cwd),
      borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            DshFileTypeBadge(extension: artifact.extension),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    artifact.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: DshColors.text, fontSize: 12.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    artifact.subtitle,
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                  ),
                ],
              ),
            ),
            // 分享按钮：不触发整行的 onTap（按钮自己处理这次点击）。
            IconButton(
              onPressed: () =>
                  ArtifactOpener.share(context, artifact, cwd: cwd),
              tooltip: context.tr('分享'),
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: Icon(Icons.ios_share, color: DshColors.textFaint),
            ),
            Icon(Icons.open_in_new, size: 14, color: DshColors.textFaint),
          ],
        ),
      ),
    );
  }
}

/// 工具调用卡片（设计稿里的"工具调用卡片"）。
///
/// 改造前是 Card + 状态文字；这里改成设计稿的形态：
/// 状态图标 + 标题 + 状态文字（`已完成` / `进行中`…），命令与输出默认折叠。
/// 把一条工具调用消息编译成**卡片规格**（`CardSpec`）。
///
/// 为什么需要它（2026-10-20 接收 CHG-04 时补的）：交付包里的 `card_schema_test.dart`
/// 直接调用了 `toolCardSpec(...)`，但**补丁没有带上这个定义** —— 也就是说
/// 「工具卡改走协议」这半句只到了协议层，没到落地层。这里按协议把工具卡的数据补全：
/// 类型 / 标题 / 状态文字 / 状态色 / 头部图标 / 展开区（命令与输出），
/// 与改动前的 `ToolCallCard` 外观**逐项对应**（命令行不加边框、输出超 1500 字截断）。
///
/// 状态色与图标是**这一次的属性**（✓ / ! / ⟳），所以由这里给，而不是由类型档位给。
CardSpec toolCardSpec(ChatMsg msg, BuildContext context) {
  final done = msg.toolStatus == 'completed';
  final failed = msg.toolStatus == 'failed';
  final tone = done
      ? CardStatusTone.ok
      : (failed ? CardStatusTone.err : CardStatusTone.busy);
  final icon = done
      ? Icons.check_circle_outline
      : (failed ? Icons.error_outline : Icons.autorenew);
  final statusLabel = switch (msg.toolStatus) {
    'completed' => context.tr('已完成'),
    'failed' => context.tr('失败'),
    'in_progress' => context.tr('进行中'),
    _ => msg.toolStatus ?? '',
  };
  final command = msg.toolCommand?.trim();
  final output = msg.toolOutput?.trim();
  // 输出超长时截断 —— 与旧实现同一口径（同一句话，不另写文案）：
  // 长输出塞进卡片会把整条消息撑爆，用户真正要看的那几行反而找不到。
  final outputText = (output != null && output.length > 1500)
      ? context.tr('{0}\n…（已截断）', [output.substring(0, 1500)])
      : output;

  return CardSpec(
    type: 'tool',
    title: msg.toolTitle ?? context.tr('工具'),
    status: statusLabel.isEmpty ? null : statusLabel,
    statusTone: tone,
    icon: icon,
    // ⚠️ `expandable` 必须显式置真：协议里「能不能展开」的判据是
    //    `expandable && expandedFields.any((f) => !f.isEmpty)` —— 只填 expandedFields
    //    不置这个标志，卡片就永远展不开（这条被 card_schema_test 抓到过）。
    expandable: true,
    // 命令与输出都是**展开后**才看的东西（默认折叠是旧行为，别改成常驻）。
    expandedFields: <CardField>[
      if (command != null && command.isNotEmpty)
        CardField(value: command, kind: CardFieldKind.mono),
      if (outputText != null && outputText.isNotEmpty)
        CardField(value: outputText, kind: CardFieldKind.mono),
    ],
  );
}

class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.msg});

  final ChatMsg msg;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final msg = widget.msg;
    // 2026-10-20（CHG-04）：工具卡改走**卡片协议** —— 外观全部由 `toolCardSpec()`
    // 产出的数据决定，这里只负责外面的框与折叠状态。渲染器里没有任何
    // `if (type == 'tool')` 分支，所以以后加卡片类型不用改这里。
    final spec = toolCardSpec(msg, context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: CardRenderer(
        spec: spec,
        expanded: _open,
        onToggle: () => setState(() => _open = !_open),
        headerPadding: const EdgeInsets.all(12),
        bodyPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        titleSize: 12.5,
        titleMaxLines: 1,
      ),
    );
  }
}

/// 附件菜单（设计稿 `page-03`）：`拍照` / `照片／视频` / `添加文件`
/// 下面是 `专家中心` / `使用技能` / `定时任务`。
///
/// **本轮改动（用户要求）**：去掉 `连接器` —— 它是 WorkBuddy 的云端能力，
/// 本地 DSH 没有对应实现，留着只会点出一个"暂未实现"的提示。
class AttachMenu extends StatelessWidget {
  const AttachMenu({super.key, required this.onPick, required this.onClose});

  final void Function(String label) onPick;
  final VoidCallback onClose;

  static const _row1 = [
    (icon: Icons.camera_alt_outlined, label: '拍照'),
    (icon: Icons.photo_library_outlined, label: '照片／视频'),
    (icon: Icons.insert_drive_file_outlined, label: '添加文件'),
  ];

  static const _row2 = [
    (icon: Icons.auto_awesome_outlined, label: '专家中心'),
    (icon: Icons.extension_outlined, label: '使用技能'),
    (icon: Icons.schedule_outlined, label: '定时任务'),
    // 用户意见④：长会话的「预算可见 + 笔记接力 + 主动换窗」
    // （复刻 dsh-smart-compact 的用户价值，但不动宿主、纯 App 侧实现 —— 那个插件
    //   在手机的 acp profile 下装不上，见 lib/local/context_budget.dart 的说明）。
    (icon: Icons.auto_awesome_motion_outlined, label: '长会话助手'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // 这一条是**盖在消息上的标题带**（不是页面背景）：用半透明的 navBg 时
      // 深色下底下的消息会透上来。弹层/覆盖层一律用不透明的 surfaceStrong。
      color: DshColors.surfaceStrong,
      padding: const EdgeInsets.fromLTRB(
          DshMetrics.pagePad, 14, DshMetrics.pagePad, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final item in _row1)
                Expanded(
                  child: _AttachCell(
                    icon: item.icon,
                    label: context.tr(item.label),
                    onTap: () => onPick(item.label),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Divider(height: 18, thickness: 0.5),
          for (final item in _row2)
            InkWell(
              onTap: () => onPick(item.label),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Icon(item.icon, size: 17, color: DshColors.textDim),
                    const SizedBox(width: 12),
                    Text(
                      context.tr(item.label),
                      style: TextStyle(color: DshColors.text, fontSize: 13.5),
                    ),
                    const Spacer(),
                    Icon(Icons.chevron_right,
                        size: 15, color: DshColors.textFaint),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child:
                TextButton(onPressed: onClose, child: Text(context.tr('收起'))),
          ),
        ],
      ),
    );
  }
}

class _AttachCell extends StatelessWidget {
  const _AttachCell(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: DshColors.surface,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
                ),
                child: Icon(icon, size: 20, color: DshColors.accent),
              ),
              const SizedBox(height: 7),
              Text(
                label,
                style: TextStyle(color: DshColors.textDim, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「已等待 M:SS」—— 自己每秒走一格。
///
/// 为什么必须做成**独立的小 StatefulWidget**：如果把计时器放在页面里
/// `setState`，一秒一次会把整个消息列表重建一遍（真机会明显掉帧）。
/// 这里只重建这一个 Text。
///
/// 为什么显示"等了多久"而不是进度条：我们**拿不到**真实进度 ——
/// ACP 只告诉我们"有输出/没输出"，没有"还剩多少"。给一个假的进度条
/// 比不给更糟（它会假装知道）。时间是真的，所以只给时间。
class _ElapsedText extends StatefulWidget {
  const _ElapsedText({required this.startedAt});

  final DateTime startedAt;

  @override
  State<_ElapsedText> createState() => _ElapsedTextState();
}

class _ElapsedTextState extends State<_ElapsedText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(widget.startedAt);
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    final text = s < 60
        ? '已等待 $s 秒'
        : '已等待 ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    return Text(
      context.tr(text),
      style: TextStyle(fontSize: 12, color: DshColors.textDim),
    );
  }
}
