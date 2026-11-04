/// 卡片协议：**一张卡片 = 一份数据**（[CardSpec]）。
///
/// ## 为什么要有这一层（对标同类产品的 C2）
///
/// 同类产品的卡片（approval / doc / form / question / task / error）是
/// **服务端下发**、客户端只负责解释；我们现在是**反过来的** —— 卡片长什么样
/// **写死在 Flutter 里**（`ToolCallCard`），于是每多一类卡片就要改一次 Dart 代码、
/// 重新发一次包。
///
/// 这一层把"卡片长什么样"从代码里拿出来：
///   * [CardSpec] = **数据**（可以从 JSON 来，也可以从本地 ACP 事件造出来）；
///   * `card_renderer.dart` = 解释器 + 渲染器（**只认数据**）；
///   * 新增一类卡片 = **加一条数据**，不是加一个 widget。
///
/// ## 边界（这几条是硬约定，别改坏）
///
/// - **未知类型不报错**：走渲染器的**通用档**，字段照画、动作照点 ——
///   这就是"不改 Flutter 代码也能渲染新类型"的实现点。
/// - **不编内容**：字段缺了就少画一项，绝不用占位文字假装有。
/// - 这一层**不认识语言**：文案由调用方翻译好再传进来（schema 不引 Flutter 依赖）。
library;

import 'package:flutter/widgets.dart' show IconData;

/// 字段的呈现方式。
enum CardFieldKind {
  /// 普通文本：标签 + 内容。
  text,

  /// 等宽内容（命令、参数、输出）。
  mono,

  /// 一枚小胶囊（类别标签）。
  chip,

  /// 只有标签的小标题（分段用）。
  sectionLabel,

  /// 警示框（取不到详情时**如实说明**，不填充推测内容）。
  warn,

  /// 极小字的脚注（如调用 ID）。
  caption,
}

/// 卡片里的一个字段。
class CardField {
  const CardField({
    this.label,
    this.value,
    this.kind = CardFieldKind.text,
    this.boxed = false,
  });

  /// 字段名（`text` / `sectionLabel` / `chip` 时用）。
  final String? label;

  /// 字段内容。**空就等于没有这一项** —— 渲染时不画，更不编。
  final String? value;

  final CardFieldKind kind;

  /// 等宽内容要不要套一层边框（对话框里的"要执行的内容"要，工具卡里的命令不要）。
  final bool boxed;

  /// 这个字段是不是空的（空 → 渲染时整项跳过）。
  bool get isEmpty {
    final l = label?.trim() ?? '';
    final v = value?.trim() ?? '';
    return l.isEmpty && v.isEmpty;
  }

  /// 容错解析：字段缺了 / 类型不对 → 少画，**不编内容**。
  factory CardField.fromJson(Map<String, dynamic> json) {
    return CardField(
      label: _asText(json['label']),
      value: _asText(json['value']),
      kind: _kindOf(json['kind']),
      boxed: json['boxed'] == true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (label != null) 'label': label,
        if (value != null) 'value': value,
        'kind': kind.name,
        if (boxed) 'boxed': true,
      };
}

/// 卡片上的一个动作（服务端下发的按钮）。
class CardAction {
  const CardAction({
    required this.id,
    required this.label,
    this.primary = false,
    this.destructive = false,
  });

  /// 动作标识（回传服务端用）。
  final String id;

  /// 按钮上的字。
  final String label;

  /// 主按钮（实心）。
  final bool primary;

  /// 危险动作（拒绝/删除一类）。
  final bool destructive;

  factory CardAction.fromJson(Map<String, dynamic> json) {
    return CardAction(
      id: _asText(json['id']) ?? '',
      label: _asText(json['label']) ?? '',
      primary: json['primary'] == true,
      destructive: json['destructive'] == true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        if (primary) 'primary': true,
        if (destructive) 'destructive': true,
      };
}

/// 状态色（由解释器映射到主题色）。
enum CardStatusTone {
  neutral,
  busy,
  ok,
  err,
}

/// 一张卡片的完整规格。
class CardSpec {
  const CardSpec({
    required this.type,
    this.title,
    this.status,
    this.statusTone = CardStatusTone.neutral,
    this.icon,
    this.fields = const <CardField>[],
    this.expandedFields = const <CardField>[],
    this.details,
    this.detailsLabel,
    this.actions = const <CardAction>[],
    this.expandable = false,
  });

  /// 卡片类型。**不认识也没关系** —— 渲染器会走通用档。
  final String type;

  /// 标题（渲染在头部）。
  final String? title;

  /// 右上角的状态文字（如「已完成」）。
  final String? status;

  final CardStatusTone statusTone;

  /// 头部图标。**不填就用类型档位的默认图标**。
  ///
  /// 为什么允许单独指定：工具卡的图标是**跟着状态走的**（✓ / ! / ⟳），
  /// 那不是"类型属性"而是"这一次的属性"，所以由造数据的一方给。
  final IconData? icon;

  /// 常驻字段。
  final List<CardField> fields;

  /// 展开后多出来的字段（工具卡的命令 / 输出）。
  final List<CardField> expandedFields;

  /// 折叠区里的原始内容（技术细节）。
  final String? details;

  /// 折叠区的标题。
  final String? detailsLabel;

  /// 动作（服务端下发的按钮）。
  final List<CardAction> actions;

  /// 这张卡片能不能展开（能不能展开只看**有没有展开区内容**）。
  final bool expandable;

  /// 容错解析一份 JSON 卡片。
  ///
  /// 规矩：**缺什么就少什么，绝不编**。
  /// `type` 都没有 → 当作通用卡片（`generic`），其余照常渲染。
  factory CardSpec.fromJson(Map<String, dynamic> json) {
    final type = _asText(json['type']) ?? 'generic';
    return CardSpec(
      type: type,
      title: _asText(json['title']),
      status: _asText(json['status']),
      statusTone: _toneOf(json['statusTone']),
      fields: _fieldsOf(json['fields']),
      expandedFields: _fieldsOf(json['expandedFields']),
      details: _asText(json['details']),
      detailsLabel: _asText(json['detailsLabel']),
      actions: _actionsOf(json['actions']),
      expandable: json['expandable'] == true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        if (title != null) 'title': title,
        if (status != null) 'status': status,
        'statusTone': statusTone.name,
        'fields': fields.map((f) => f.toJson()).toList(),
        'expandedFields': expandedFields.map((f) => f.toJson()).toList(),
        if (details != null) 'details': details,
        if (detailsLabel != null) 'detailsLabel': detailsLabel,
        'actions': actions.map((a) => a.toJson()).toList(),
        if (expandable) 'expandable': true,
      };

  /// 有没有可展开的内容（没有就别给一个点了没反应的箭头）。
  bool get hasExpandedContent =>
      expandable && expandedFields.any((f) => !f.isEmpty);
}

/// 把任意值取成字符串；**取不到就返回 null**（不编）。
String? _asText(Object? v) {
  if (v == null) return null;
  if (v is String) {
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
  // 数字 / 布尔这类标量：转成字符串是**如实**的，不算编内容。
  if (v is num || v is bool) return '$v';
  return null;
}

CardFieldKind _kindOf(Object? v) {
  final name = v is String ? v : null;
  if (name == null) return CardFieldKind.text;
  for (final k in CardFieldKind.values) {
    if (k.name == name) return k;
  }
  return CardFieldKind.text;
}

CardStatusTone _toneOf(Object? v) {
  final name = v is String ? v : null;
  if (name == null) return CardStatusTone.neutral;
  for (final t in CardStatusTone.values) {
    if (t.name == name) return t;
  }
  return CardStatusTone.neutral;
}

List<CardField> _fieldsOf(Object? v) {
  if (v is! List) return const <CardField>[];
  final out = <CardField>[];
  for (final item in v) {
    if (item is Map) {
      out.add(CardField.fromJson(Map<String, dynamic>.from(item)));
    }
    // 不是对象的元素直接跳过 —— 少一项好过崩一次。
  }
  return out;
}

List<CardAction> _actionsOf(Object? v) {
  if (v is! List) return const <CardAction>[];
  final out = <CardAction>[];
  for (final item in v) {
    if (item is Map) {
      out.add(CardAction.fromJson(Map<String, dynamic>.from(item)));
    }
  }
  return out;
}
