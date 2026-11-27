import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/data/model_overlay_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// 写前校验的**规则门禁**：每一条都对着运行时 `resolveProfiles()` 的真实拒绝理由。
///
/// 为什么要把这些钉成单测：这些规则本身没有 UI，改了也看不出来；而它们唯一的
/// 作用就是"别让一条坏配置把整张 provider 表带走"。运行时的行为是
/// `invalid()` → throw → 整条 `llm-pi-ai` 不激活 → `session/new: Internal error`，
/// 也就是说**漏一条就等于全部模型不可用**。所以每条规则都得有测试盯着。
void main() {
  ProviderSpec provider({
    String id = 'deepseek',
    String baseUrl = 'https://api.deepseek.com/v1',
    String api = 'openai-completions',
    String apiKeyEnv = 'DEEPSEEK_API_KEY',
  }) =>
      ProviderSpec(
        id: id,
        label: id,
        baseUrl: baseUrl,
        api: api,
        apiKeyEnv: apiKeyEnv,
      );

  ModelSpec model(
    String providerId, {
    String id = 'deepseek-v4.1-flash',
    String? name,
    int? context,
  }) =>
      ModelSpec(provider: providerId, id: id, name: name, context: context);

  ConfiguredConfig config({
    List<ProviderSpec>? providers,
    List<ModelSpec>? models,
  }) =>
      ConfiguredConfig(
        version: ConfiguredModels.currentVersion,
        providers: providers ?? <ProviderSpec>[provider()],
        models: models ?? <ModelSpec>[model('deepseek')],
        groups: const <RotationGroupSpec>[],
        selected: null,
      );

  test('正常配置原样通过，一条 notes 都不该有', () {
    final plan = ModelOverlayRules.plan(config());
    expect(plan.notes, isEmpty);
    expect(plan.providers.single.id, 'deepseek');
    expect(plan.modelsOf('deepseek').single.id, 'deepseek-v4.1-flash');
  });

  test('同一厂家把同一个模型 id 列两次 → 只留第一个（运行时会整表拒绝）', () {
    final plan = ModelOverlayRules.plan(config(
      models: <ModelSpec>[
        model('deepseek', id: 'dup', context: 128000),
        model('deepseek', id: 'dup', context: 128000),
      ],
    ));
    expect(plan.modelsOf('deepseek').length, 1);
    expect(plan.notes.join(), contains('列了两次'));
  });

  test('contextWindow 是 0 或负数 → 兜底成 1000000（否则运行时报 must be a positive integer）', () {
    final plan = ModelOverlayRules.plan(config(
      models: <ModelSpec>[
        model('deepseek', id: 'zero', context: 0),
        model('deepseek', id: 'neg', context: -5),
      ],
    ));
    final kept = plan.modelsOf('deepseek');
    expect(kept.map((m) => m.context), everyElement(kFallbackContextWindow));
    expect(plan.notes.where((n) => n.contains('兜底成')), hasLength(2));
  });

  test('contextWindow 太小 → 抬到 1024（否则 maxTokens 被 clamp 成 1、空回复）', () {
    final plan = ModelOverlayRules.plan(config(
      models: <ModelSpec>[model('deepseek', context: 500)],
    ));
    expect(plan.modelsOf('deepseek').single.context, kMinContextWindow);
  });

  test('Base URL 是空 / 不是 http(s) → 整条厂家丢掉，而不是写进 overlay', () {
    for (final bad in <String>['', '   ', 'ftp://example.com', 'htps://x.com', 'example.com']) {
      final plan = ModelOverlayRules.plan(config(
        providers: <ProviderSpec>[provider(baseUrl: bad)],
      ));
      expect(plan.providers, isEmpty, reason: '「$bad」应该被丢掉');
      expect(plan.notes, isNotEmpty, reason: '「$bad」必须留下说明');
    }
  });

  test('未知协议 → 回落成 openai-completions（丢整条太伤，这条能修）', () {
    final plan = ModelOverlayRules.plan(config(
      providers: <ProviderSpec>[provider(api: 'not-a-real-protocol')],
    ));
    expect(plan.providers.single.api, 'openai-completions');
    expect(plan.notes.join(), contains('不认识'));
  });

  test('空模型 id → 只丢那一条；全丢光 → 厂家也丢', () {
    final mixed = ModelOverlayRules.plan(config(
      models: <ModelSpec>[
        model('deepseek', id: ''),
        model('deepseek', id: 'ok'),
      ],
    ));
    expect(mixed.modelsOf('deepseek').single.id, 'ok');
    expect(mixed.notes.join(), contains('空模型 id'));

    final allBad = ModelOverlayRules.plan(config(
      models: <ModelSpec>[model('deepseek', id: '  ')],
    ));
    expect(allBad.providers, isEmpty);
    expect(allBad.notes.join(), contains('没有可用的模型'));
  });

  test('厂家重复出现 → 只保留第一个', () {
    final plan = ModelOverlayRules.plan(config(
      providers: <ProviderSpec>[provider(), provider(baseUrl: 'https://other.example.com')],
    ));
    expect(plan.providers, hasLength(1));
    expect(plan.providers.single.baseUrl, 'https://api.deepseek.com/v1');
    expect(plan.notes.join(), contains('重复出现'));
  });

  test('没有 apiKeyEnv → 整条丢掉（运行时拿不到凭据）', () {
    final plan = ModelOverlayRules.plan(config(
      providers: <ProviderSpec>[provider(apiKeyEnv: ' ')],
    ));
    expect(plan.providers, isEmpty);
    expect(plan.notes.join(), contains('apiKeyEnv'));
  });

  test('模型 name 是空白 → 用 id 顶上（YAML 里空 name 会被当成空串）', () {
    final plan = ModelOverlayRules.plan(config(
      models: <ModelSpec>[model('deepseek', id: 'm1', name: '   ')],
    ));
    expect(plan.modelsOf('deepseek').single.name, 'm1');
  });

  group('凭据引用（2026-11-27 真机：厂家叫「7API」导致所有模型不可用）', () {
    // 真机原文：
    //   TypeError: credential ref "7API_API_KEY" must match /^[A-Za-z_][A-Za-z0-9_]*$/
    //   → dsh: warning: 1 entry did not activate
    //   → session/new 失败：{"details":"no adapter registered for provider \"custom\""}
    test('envNameFor：数字开头的厂家名要加前缀，产出合法凭据引用', () {
      for (final id in <String>['7api', '7router', '9-router', 'custom', 'a.b']) {
        final name = ConfiguredModels.envNameFor(id);
        expect(ConfiguredModels.credentialRefPattern.hasMatch(name), isTrue,
            reason: '「$id」推出来的 "$name" 必须是合法凭据引用');
      }
      expect(ConfiguredModels.envNameFor('7api'), isNot('7API_API_KEY'));
      expect(ConfiguredModels.envNameFor('7api'), startsWith('P'),
          reason: '数字开头时加 P 前缀');
    });

    test('provider() 工厂会把已存盘的非法 apiKeyEnv 就地改名', () {
      final p = ConfiguredModels.provider(
        id: '7api',
        baseUrl: 'https://7api.example.com/v1',
        label: '7API',
        apiKeyEnv: '7API_API_KEY', // ← 存量用户 models.json 里的旧值
      );
      expect(p.apiKeyEnv, ConfiguredModels.envNameFor('7api'));
      expect(ConfiguredModels.credentialRefPattern.hasMatch(p.apiKeyEnv), isTrue);
    });

    test('合法的 apiKeyEnv 原样保留（不要顺手改掉用户/内置的命名）', () {
      final p = ConfiguredModels.provider(
        id: 'agnes',
        baseUrl: 'https://api.agnes-ai.cn/v1',
        apiKeyEnv: 'AGNES_API_KEY',
      );
      expect(p.apiKeyEnv, 'AGNES_API_KEY');
    });

    test('万一还漏进来一个非法 apiKeyEnv → 只丢这个厂家，并说清原因', () {
      final plan = ModelOverlayRules.plan(config(
        providers: <ProviderSpec>[
          ProviderSpec(
            id: '7api',
            label: '7API',
            baseUrl: 'https://7api.example.com/v1',
            apiKeyEnv: '7API_API_KEY', // 手工构造，绕过 provider()
          ),
        ],
        models: <ModelSpec>[model('7api', id: 'gpt-x')],
      ));
      expect(plan.providers, isEmpty);
      expect(plan.notes.join(), contains('不是合法凭据引用'));
    });
  });

  test('多厂家：一个坏的两个好的 → 只有坏的那个消失', () {
    final plan = ModelOverlayRules.plan(config(
      providers: <ProviderSpec>[
        provider(id: 'broken', baseUrl: ''),
        provider(id: 'agnes', baseUrl: 'https://api.agnes-ai.cn/v1'),
        provider(id: 'amd', baseUrl: 'https://developer.amd.com.cn/radeon/api/v1'),
      ],
      models: <ModelSpec>[
        model('broken', id: 'x'),
        model('agnes', id: 'agnes-3.0-flash'),
        model('amd', id: 'DeepSeek-V4-Flash'),
      ],
    ));
    expect(plan.providers.map((p) => p.id), <String>['agnes', 'amd']);
    expect(plan.modelsOf('agnes').single.id, 'agnes-3.0-flash');
    expect(plan.modelsOf('amd').single.id, 'DeepSeek-V4-Flash');
  });
}
