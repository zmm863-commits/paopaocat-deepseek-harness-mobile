/// **写 overlay 之前的写前校验**：把运行时 `resolveProfiles()` 会拒的东西挡在盘外。
///
/// ## 为什么要有这一层（2026-11-27，用户报 `session/new 失败：Internal error`）
///
/// 运行时对整张 provider 表是**全量、抛异常**校验的。查过运行包里那份
/// `@deepseek-ai/dsh-llm-pi-ai/lib/index.js`：
///
///   * `resolveProfiles()` 遇到坏条目调用 `invalid()`；
///   * `invalid()` 直接 `throw new PiAiCatalogError(...)`，**不跳单条**；
///   * 于是 `llm-pi-ai` 整条插件激活失败 → **所有厂家的适配器一起消失**；
///   * 外面 ACP 只能回一句 `Internal error`，用户看到的是「会话建不起来」。
///
/// 它会拒的条目（照抄自运行时代码，别凭印象改）：
///   * `provider "${p}" has an empty baseURL`
///   * `model "${id}" has an empty id`
///   * `lists model "${id}" more than once`
///   * `model "${id}" needs an api; the installed catalog does not describe it`
///   * `model "${id}" needs a baseURL; ...`
///   * `model "${id}" contextWindow must be a positive integer`
///   * 已删除字段（`provider` / `maxRetries` / `maxRetryDelayMs`）一出现就抛
///
/// 而在此之前，我们写 overlay 只挡了两条：空 baseURL、空 models。其余全是裸奔 ——
/// 尤其是**同一厂家把同一个模型 id 列两次**和 **contextWindow <= 0**，这两个我们
/// 自己的代码里一个去重都没有、一个是直接抄上游的值。
///
/// ## 处理原则：能修的修，修不了的只丢那一条
///
///   * **修**：模型 id/厂家 id 去重（保留第一个）、`contextWindow` 非法值兜底、
///     未知协议回落成 `openai-completions`、空 name 用 id 顶；
///   * **丢**：厂家没有 id / Base URL 空的或不是 http(s) / 一个可用模型都没有。
///
/// 宁可少一个厂家的模型，也不能让整张表不激活 —— 这与本仓其它地方
/// （「没有可用模型就不重写 overlay」）是同一条原则：不编"能用"的假象。
///
/// 所有修复/丢弃理由都会回传在 [OverlayPlan.notes] 里，调用方负责写进日志。
library;

import 'configured_models.dart';

/// 运行时认识的协议名（`llm-pi-ai` 里的 union；不认识的会被回落）。
const Set<String> kWireProtocols = <String>{
  'openai-completions',
  'openai-responses',
  'openai-codex-responses',
  'anthropic-messages',
  'google-generative-ai',
};

/// 上游没给 context、或给了 <= 0 时用的兜底值（与历史行为一致）。
const int kFallbackContextWindow = 1000000;

/// `contextWindow` 的下限。低于它时 DSH 的 `maxTokens = context - 已用 - 4096`
/// 必然被压成 1 → 「发什么都空回复」（2026-10-08 真机上踩过）。
const int kMinContextWindow = 1024;

/// 写前校验的结论：哪些厂家/模型可以写、改了什么、丢了什么。
class OverlayPlan {
  const OverlayPlan({
    required this.providers,
    required this.models,
    required this.notes,
  });

  /// 可以写进 overlay 的厂家（id 已去重，baseUrl/api 已归一）。
  final List<ProviderSpec> providers;

  /// `providerId → 该厂家可写的模型`（已去重、contextWindow 已兜底）。
  final Map<String, List<ModelSpec>> models;

  /// 给人看的修复/丢弃说明，一条一句，按出现顺序。空 = 什么都没动。
  final List<String> notes;

  bool get isEmpty => providers.isEmpty;

  List<ModelSpec> modelsOf(String providerId) =>
      models[providerId] ?? const <ModelSpec>[];
}

/// 纯函数校验器。不碰文件、不碰平台，方便单测把每条规则钉死。
class ModelOverlayRules {
  const ModelOverlayRules._();

  /// Base URL 必须是能解析的 http(s) 地址。
  ///
  /// 运行时不校验协议（它只拒空串），但 `ftp://` / 打错成 `htps://` 的地址
  /// 一路走到底只会变成"请求发不出去"，而且看起来像网络问题。这里提前挡掉。
  static bool isHttpUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return false;
    if (uri.host.isEmpty) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }

  /// `contextWindow` 归一：null/<=0 → 兜底值；小于下限 → 抬到下限。
  static int sanitizeContextWindow(int? raw) {
    if (raw == null || raw <= 0) return kFallbackContextWindow;
    if (raw < kMinContextWindow) return kMinContextWindow;
    return raw;
  }

  /// 把一个 [ConfiguredConfig] 压成"运行时肯收"的形状。
  static OverlayPlan plan(ConfiguredConfig config) {
    final notes = <String>[];
    final outProviders = <ProviderSpec>[];
    final outModels = <String, List<ModelSpec>>{};
    final seenProviders = <String>{};

    for (final p in config.providers) {
      final id = p.id.trim();
      if (id.isEmpty) {
        notes.add('丢掉一个没有 id 的厂家');
        continue;
      }
      if (!seenProviders.add(id)) {
        notes.add('厂家 "$id" 重复出现 → 只保留第一个');
        continue;
      }

      final base = p.baseUrl.trim();
      if (base.isEmpty) {
        notes.add('厂家 "$id" 的 Base URL 是空的 → 整条丢掉（空 baseURL 会让整张表不激活）');
        continue;
      }
      if (!isHttpUrl(base)) {
        notes.add('厂家 "$id" 的 Base URL 不是 http(s) 地址："$base" → 整条丢掉');
        continue;
      }

      var api = p.api.trim();
      if (api.isEmpty) api = 'openai-completions';
      if (!kWireProtocols.contains(api)) {
        notes.add('厂家 "$id" 的协议 "$api" 不认识 → 回落成 openai-completions');
        api = 'openai-completions';
      }

      if (p.apiKeyEnv.trim().isEmpty) {
        notes.add('厂家 "$id" 没有 apiKeyEnv → 整条丢掉');
        continue;
      }
      // ⚠️ 凭据引用必须匹配 `^[A-Za-z_][A-Za-z0-9_]*$`（引擎的 `credentialRef()`）。
      // 2026-11-27 真机：厂家叫「7API」→ `7API_API_KEY` 非法 → TypeError →
      // 整条 llm-pi-ai 不激活 → 所有模型都没有适配器。正常路径下
      // `ConfiguredModels.provider()` 已经把名字规整过了，能走到这里说明是
      // 代码里手工构造的配置 —— 丢掉它，别让它把整张表带走。
      if (!ConfiguredModels.credentialRefPattern.hasMatch(p.apiKeyEnv.trim())) {
        notes.add('厂家 "$id" 的 apiKeyEnv "${p.apiKeyEnv}" 不是合法凭据引用'
            '（必须以字母/下划线开头）→ 整条丢掉');
        continue;
      }

      final kept = <ModelSpec>[];
      final seenModels = <String>{};
      // ⚠️ 用 `p.id` 而不是 `id` 去筛：models 里存的是原始 provider 键。
      for (final m in config.models.where((m) => m.provider == p.id)) {
        final mid = m.id.trim();
        if (mid.isEmpty) {
          notes.add('厂家 "$id" 里有一个空模型 id → 丢掉这一条');
          continue;
        }
        if (!seenModels.add(mid)) {
          notes.add('厂家 "$id" 把模型 "$mid" 列了两次 → 只保留第一个'
              '（运行时会整表拒绝：lists model more than once）');
          continue;
        }
        final ctx = sanitizeContextWindow(m.context);
        if (m.context != null && m.context! <= 0) {
          notes.add('厂家 "$id" 的模型 "$mid" contextWindow=${m.context} → 兜底成 $ctx');
        } else if (m.context != null && m.context! < kMinContextWindow) {
          notes.add('厂家 "$id" 的模型 "$mid" contextWindow=${m.context} 太小 → 抬到 $ctx');
        }
        final name = (m.name ?? '').trim();
        kept.add(m.copyWith(
          name: name.isEmpty ? mid : name,
          context: ctx,
        ));
      }

      if (kept.isEmpty) {
        notes.add('厂家 "$id" 没有可用的模型 → 整条丢掉（空 models 同样会让整张表不激活）');
        continue;
      }

      outProviders.add(p.copyWith(baseUrl: base, api: api));
      outModels[id] = kept;
    }

    return OverlayPlan(
      providers: outProviders,
      models: outModels,
      notes: notes,
    );
  }
}
