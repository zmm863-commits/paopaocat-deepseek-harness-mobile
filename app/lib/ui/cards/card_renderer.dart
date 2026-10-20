/// 卡片的**渲染器**：只认数据（[CardSpec]），不关心具体是哪一类卡片。
///
/// ## 这里是"新增一类卡片不用改 Flutter 代码"的实现点
///
/// 渲染器**没有**任何 `if (type == 'tool')` 这样的分支 ——
/// 它只按 [CardSpec] 里的字段画。类型只影响两件事：
///   1. 头部图标（认识的类型用专属图标，不认识的用通用图标）；
///   2. 状态色（由 [CardSpec.statusTone] 决定，不由类型决定）。
///
/// 所以服务端下发 `type: 'form'` / `type: 'task'` / 任何新类型时，
/// **App 不用重新发版**就能把它画出来。
///
/// ## 视觉口径
///
/// 工具卡与审批弹层共用这一套渲染，于是两处的排版**被统一**了
/// （等宽内容的字号、字段间距、标题字重以工具卡为准）。
/// 这是有意的：同一份数据只有一种画法，才谈得上"协议化"。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_tokens.dart';
import 'card_schema.dart';

/// 卡片类型的"档位"：只决定图标与默认状态色。
class CardTypeProfile {
  const CardTypeProfile({required this.icon, this.tone = CardStatusTone.neutral});

  final IconData icon;
  final CardStatusTone tone;
}

/// 通用档：**不认识任何具体类型**时用它。
const CardTypeProfile genericCardType =
    CardTypeProfile(icon: Icons.article_outlined, tone: CardStatusTone.neutral);

const Map<String, CardTypeProfile> _cardTypes = <String, CardTypeProfile>{
  'tool': CardTypeProfile(icon: Icons.build_outlined, tone: CardStatusTone.busy),
  'approval': CardTypeProfile(icon: Icons.gpp_maybe_outlined, tone: CardStatusTone.busy),
  'doc': CardTypeProfile(icon: Icons.description_outlined, tone: CardStatusTone.neutral),
  'form': CardTypeProfile(icon: Icons.dashboard_customize_outlined, tone: CardStatusTone.neutral),
  'question': CardTypeProfile(icon: Icons.help_outline, tone: CardStatusTone.neutral),
  'task': CardTypeProfile(icon: Icons.checklist_rtl, tone: CardStatusTone.neutral),
  'error': CardTypeProfile(icon: Icons.error_outline, tone: CardStatusTone.err),
};

/// 取一种卡片类型的档位。**没登记的类型 → 通用档**（不是报错）。
CardTypeProfile cardTypeProfile(String type) =>
    _cardTypes[type] ?? genericCardType;

/// 状态色。
Color cardToneColor(CardStatusTone tone) {
  switch (tone) {
    case CardStatusTone.ok:
      return DshColors.ok;
    case CardStatusTone.err:
      return DshColors.err;
    case CardStatusTone.busy:
      return DshColors.busy;
    case CardStatusTone.neutral:
      return DshColors.textDim;
  }
}

/// 渲染一张卡片。
class CardRenderer extends StatelessWidget {
  const CardRenderer({
    super.key,
    required this.spec,
    this.expanded = false,
    this.onToggle,
    this.onAction,
    this.headerPadding = EdgeInsets.zero,
    this.bodyPadding = EdgeInsets.zero,
    this.titleSize = 12.5,
    this.titleMaxLines = 1,
  });

  final CardSpec spec;

  /// 展开区当前是不是展开着。
  final bool expanded;

  /// 点头部（可展开时才有点击行为）。
  final VoidCallback? onToggle;

  /// 点了某个动作。
  final ValueChanged<CardAction>? onAction;

  /// 头部的内边距（工具卡 12，弹层里 0）。
  final EdgeInsets headerPadding;

  /// 展开区的内边距。
  final EdgeInsets bodyPadding;

  /// 标题字号（工具卡 12.5，弹层标题可以给大一点）。
  final double titleSize;

  /// 标题最多几行。**null = 不限行**（审批弹层里工具名要看得全，
  /// 不能截成一行加省略号 —— 用户要靠它判断该不该点允许）。
  ///
  /// ⚠️ 不限行时标题用 [SelectableText]（可复制），但 `SelectableText`
  /// **不支持** `maxLines` / `overflow.ellipsis`，所以"单行 + 省略号"那种
  /// 标题必须用 [Text]（见 `_UserBubble` 里同样的取舍）。
  final int? titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final profile = cardTypeProfile(spec.type);
    final tone = spec.statusTone == CardStatusTone.neutral
        ? profile.tone
        : spec.statusTone;
    final toneColor = cardToneColor(tone);
    final canExpand = spec.hasExpandedContent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _header(context, profile, toneColor, canExpand),
        if (canExpand && expanded)
          Padding(
            padding: bodyPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final f in spec.expandedFields)
                  if (!f.isEmpty) _field(context, f),
              ],
            ),
          ),
        if (spec.fields.isNotEmpty)
          Padding(
            padding: bodyPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final f in spec.fields)
                  if (!f.isEmpty) _field(context, f),
              ],
            ),
          ),
        if (spec.details != null && spec.details!.trim().isNotEmpty)
          _details(context, spec.details!),
        if (spec.actions.isNotEmpty) _actions(context),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    CardTypeProfile profile,
    Color toneColor,
    bool canExpand,
  ) {
    final status = spec.status;
    final hasStatus = status != null && status.isNotEmpty;
    // 有状态文字时图标跟着状态色（工具卡的 ✓ / ! / ⟳）；
    // 没有状态时用弱化色（审批弹层里那个"build"小图标就是弱化的）。
    final iconColor = hasStatus ? toneColor : DshColors.textDim;
    final title = spec.title ?? '';
    final titleStyle = TextStyle(
      color: DshColors.text,
      fontSize: titleSize,
      fontWeight: FontWeight.w500,
    );
    return InkWell(
      onTap: canExpand ? onToggle : null,
      child: Padding(
        padding: headerPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(spec.icon ?? profile.icon, size: 15, color: iconColor),
            const SizedBox(width: 9),
            Expanded(
              child: titleMaxLines == null
                  ? SelectableText(title, style: titleStyle)
                  : Text(
                      title,
                      maxLines: titleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
            ),
            if (hasStatus) ...[
              Text(status, style: TextStyle(fontSize: 11, color: toneColor)),
              if (canExpand) const SizedBox(width: 6),
            ],
            if (canExpand)
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
                color: DshColors.textFaint,
              ),
          ],
        ),
      ),
    );
  }

  Widget _field(BuildContext context, CardField f) {
    switch (f.kind) {
      case CardFieldKind.sectionLabel:
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            f.label ?? '',
            style: TextStyle(color: DshColors.textDim, fontSize: 12.5),
          ),
        );
      case CardFieldKind.chip:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: DshColors.busy.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
              border: Border.all(
                  color: DshColors.busy.withValues(alpha: 0.5), width: 0.8),
            ),
            child: Text(
              f.label ?? f.value ?? '',
              style: TextStyle(color: DshColors.busy, fontSize: 11.5),
            ),
          ),
        );
      case CardFieldKind.warn:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: DshColors.err.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
            border: Border.all(color: DshColors.err.withValues(alpha: 0.5), width: 0.8),
          ),
          child: Text(
            f.value ?? '',
            style: TextStyle(color: DshColors.err, fontSize: 11.5, height: 1.5),
          ),
        );
      case CardFieldKind.caption:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            f.value ?? '',
            style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
          ),
        );
      case CardFieldKind.mono:
        return f.boxed ? _monoBox(context, f) : _monoText(context, f);
      case CardFieldKind.text:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (f.label != null && f.label!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  f.label!,
                  style: TextStyle(color: DshColors.textDim, fontSize: 12),
                ),
              ),
            Text(
              f.value ?? '',
              style: TextStyle(color: DshColors.text, fontSize: 12.5, height: 1.5),
            ),
          ],
        );
    }
  }

  /// 等宽内容（带边框的那一版：对话框里的"要执行的内容"）。
  Widget _monoBox(BuildContext context, CardField f) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: DshColors.surfaceHigh,
        borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          f.value ?? '',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  /// 等宽内容（不套边框：工具卡里的命令 / 输出）。
  Widget _monoText(BuildContext context, CardField f) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SelectableText(
        f.value ?? '',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          height: 1.4,
          color: DshColors.textDim,
        ),
      ),
    );
  }

  /// 技术细节（折叠）。
  Widget _details(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            spec.detailsLabel ?? '',
            style: TextStyle(color: DshColors.textFaint, fontSize: 11),
          ),
          children: <Widget>[
            SelectableText(
              text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                height: 1.4,
                color: DshColors.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 动作区（服务端下发的按钮）。
  Widget _actions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          for (final a in spec.actions)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: a.primary
                  ? FilledButton(
                      onPressed: () => onAction?.call(a),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: a.destructive
                            ? DshColors.err
                            : DshColors.onAccent,
                        backgroundColor: a.destructive
                            ? DshColors.err.withValues(alpha: 0.18)
                            : DshColors.accent,
                      ),
                      child: Text(a.label),
                    )
                  : TextButton(
                      onPressed: () => onAction?.call(a),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor:
                            a.destructive ? DshColors.err : DshColors.accent,
                      ),
                      child: Text(a.label),
                    ),
            ),
        ],
      ),
    );
  }
}
