/// 模型条目（对话框/面板用的展示类型）。
///
/// ⚠️ **本文件在本轮被大幅删减 —— 请先读这段再动它。**
///
/// 这里原本有一份**写死的设计稿清单**（`Hy4 preview` / `Hy3` / `GLM-5.3` /
/// `GLM-5.3-Flash` …）外加三档「快速 / 均衡 / 极致」和 `0.29x` 这类倍率，
/// 用于把设计稿 `page-01` 的模型面板 1:1 还原出来。
///
/// 它造成了两个真实问题（用户实测反馈）：
///   1. 那些名字是**云端服务的显示名**，在用户自己的端点上根本不存在；
///      于是面板里显示的和设置里配的对不上 ——「模型选择读取的不是设置里
///      已经有的模型，而是我截图上的模型」；
///   2. 因为有个"未知 routeId 就回落到用户配置"的兜底，
///      表现成了「我选择任何模型都可以会话，明明没有配置」。
///
/// 现在清单的**唯一来源**是用户自己的配置：设置页把真实模型写进
/// `<filesDir>/models.json`，由 `data/configured_models.dart` 读写、
/// `state/model_store.dart` 载入。没有配置就是空清单，
/// 界面如实说"还没有可用模型"。
///
/// 所以：**不要再往这里加模型清单**，也不要恢复那份设计稿名单。
library;

/// 一个可切换的模型。
///
/// `id` 与 `routeId` 在新设计下是同一个值（就是端点上的真实 model id），
/// 保留两个字段是为了不动已有调用方的签名。
class ModelEntry {
  const ModelEntry({
    required this.id,
    required this.name,
    required this.routeId,
    this.multiplier = 1.0,
    this.badge,
    this.description,
  });

  /// 稳定标识（存盘、比较用）
  final String id;

  /// 界面显示名（现在通常是真实 model id 或服务商给的 display name）
  final String name;

  /// 实际传给 DSH 的 model id（overlay 里 `agent-default-model.model`）
  final String routeId;

  /// 计费倍率。**设计稿遗留字段**：我们无从得知用户端点的真实计价，
  /// 所以界面上已不再显示它（模型面板改显示上下文长度）。
  final double multiplier;

  /// 角标（设计稿遗留，当前不用）
  final String? badge;

  /// 列表里的一句话说明（新设计里放「真实 model id · 上下文长度」）
  final String? description;

  String get multiplierLabel => '${multiplier.toStringAsFixed(2)}x';

  bool get isFree => multiplier == 0;
}
