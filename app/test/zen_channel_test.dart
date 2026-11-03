/// 「免费模型（无需 Key）」的配置注入测试。
///
/// ## 这一层最容易出的事故
///
/// 它是**往用户的模型配置里写东西**（`models.json`）。写错一次就可能：
///   * 把用户自己的厂家/模型**抹掉**（那是最不可接受的）；
///   * 端口变了但配置没更新 → 模型列表里一批"选了就连不上"的模型；
///   * 重复注入 → 同一个模型出现好几遍。
/// 所以下面逐条钉住。真正的进程/网络部分（起代理、取列表）见
/// `install/test-zen-proxy.mjs`（那里用假上游验形状）。
library;

import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/data/polli_channel.dart';
import 'package:dsh_mobile/data/zen_channel.dart';
import 'package:dsh_mobile/local/local_model_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ignore: prefer_const_constructors — 带参数的构造不是常量，这里刻意每次新建
  ConfiguredConfig userConfig() => ConfiguredConfig(
        version: 3,
        providers: const <ProviderSpec>[
          ProviderSpec(
            id: 'deepseek',
            label: 'DeepSeek',
            baseUrl: 'https://api.deepseek.com/v1',
            apiKeyEnv: 'PROVIDER_DEEPSEEK_KEY',
          ),
          ProviderSpec(
            id: 'mimo',
            label: 'MiMo（小米）',
            baseUrl: 'https://api.xiaomimimo.com/v1',
            apiKeyEnv: 'PROVIDER_MIMO_KEY',
          ),
        ],
        models: const <ModelSpec>[
          ModelSpec(provider: 'deepseek', id: 'deepseek-chat', name: 'DeepSeek Chat'),
          ModelSpec(provider: 'mimo', id: 'mimo-v2.6-pro'),
        ],
        groups: const <RotationGroupSpec>[],
        selected: 'deepseek/deepseek-chat',
      );

  test('开启：加一个 zen 厂家 + 每个免费模型各一条', () {
    final cfg = zenConfigForTest(userConfig(), port: 41000, models: <String>['big-pickle', 'exo-free']);
    final zen = cfg.providers.where((p) => p.id == ZenChannel.providerId).toList();
    expect(zen.length, 1);
    expect(zen.first.baseUrl, 'http://127.0.0.1:41000/v1',
        reason: '端口是系统随机分配的，必须用回填进来的那个');
    expect(zen.first.apiKeyEnv, ZenChannel.apiKeyEnv);
    expect(cfg.models.where((m) => m.provider == ZenChannel.providerId).map((m) => m.id).toList(),
        <String>['big-pickle', 'exo-free']);
  });

  test('⚠️ 绝不动用户自己的厂家与模型', () {
    final before = userConfig();
    final after = zenConfigForTest(before, port: 41000, models: <String>['big-pickle']);
    expect(after.providers.where((p) => p.id != ZenChannel.providerId).map((p) => p.id).toList(),
        <String>['deepseek', 'mimo']);
    expect(after.models.where((m) => m.provider != ZenChannel.providerId).map((m) => m.id).toList(),
        <String>['deepseek-chat', 'mimo-v2.6-pro']);
    // 用户选中的模型也不能被改掉
    expect(after.selected, 'deepseek/deepseek-chat');
    // 轮换池原样带走
    expect(after.groups.length, before.groups.length);
  });

  test('端口变了 → 覆盖旧的 zen 厂家（不是多出一个）', () {
    final first = zenConfigForTest(userConfig(), port: 41000, models: <String>['big-pickle']);
    final second = zenConfigForTest(first, port: 52000, models: <String>['exo-free']);
    final zen = second.providers.where((p) => p.id == ZenChannel.providerId).toList();
    expect(zen.length, 1, reason: '旧端口那份必须被覆盖掉');
    expect(zen.first.baseUrl, 'http://127.0.0.1:52000/v1');
    // 旧模型也要换掉，不能新旧混在一起
    expect(second.models.where((m) => m.provider == ZenChannel.providerId).map((m) => m.id).toList(),
        <String>['exo-free']);
  });

  test('重复注入不会把同一个模型写两遍', () {
    final once = zenConfigForTest(userConfig(), port: 41000, models: <String>['a-free', 'b-free']);
    final twice = zenConfigForTest(once, port: 41000, models: <String>['a-free', 'b-free']);
    final ids = twice.models.where((m) => m.provider == ZenChannel.providerId).map((m) => m.id).toList();
    expect(ids.length, 2, reason: '重复注入会出现两遍：$ids');
  });

  test('route 判定：zen/… 才算免费通道的路', () {
    expect(isZenRoute('zen/big-pickle'), isTrue);
    expect(isZenRoute('deepseek/deepseek-chat'), isFalse);
    expect(isZenRoute(null), isFalse);
    expect(isZenRoute(''), isFalse);
  });

  group('三通道合并成一个厂家（2026-11-03）', () {
    // 用户原话：「拉去模型后会话页面模型选择会出现三个第三方免key通道，
    // 把他们合并」。
    //
    // 关键设计：**只注册一个 provider**，三条上游的模型全挂在它下面；
    // 请求该发给谁由代理**按模型名**判断（zen-proxy.mjs 的 laneOfModel）。
    // 所以 baseUrl 只有 `/v1` 一条，不再有 /kilo/v1、/ovh/v1。
    test('三个上游的模型都在同一个厂家下，且只有这一个厂家', () {
      final cfg = zenConfigForTest(
        userConfig(),
        port: 4001,
        models: const <String>['zen-a'],
        kiloModels: const <String>['kilo-a'],
        ovhModels: const <String>['ovh-a'],
      );
      final zenProvs =
          cfg.providers.where((p) => p.id == 'zen').toList(growable: false);
      expect(zenProvs.length, 1, reason: '只允许一个 zen 厂家');
      expect(zenProvs.first.baseUrl, 'http://127.0.0.1:4001/v1',
          reason: '合并后统一走 /v1，靠模型名分流');
      expect(cfg.providers.any((p) => p.id == 'kilo'), isFalse,
          reason: 'kilo 不再单独注册（否则选择器里又多一个分组）');
      expect(cfg.providers.any((p) => p.id == 'ovh'), isFalse,
          reason: 'ovh 同理');

      final ids =
          cfg.models.where((m) => m.provider == 'zen').map((m) => m.id).toList();
      expect(ids, <String>['zen-a', 'kilo-a', 'ovh-a'],
          reason: '三批都要在，顺序 Zen→Kilo→OVH（与代理判断顺序一致）');
    });

    test('重名模型只出现一次（否则选择器里两条一模一样）', () {
      final cfg = zenConfigForTest(
        userConfig(),
        port: 4002,
        models: const <String>['same-model', 'zen-only'],
        kiloModels: const <String>['same-model'],
        ovhModels: const <String>['same-model', 'ovh-only'],
      );
      final ids =
          cfg.models.where((m) => m.provider == 'zen').map((m) => m.id).toList();
      expect(ids, <String>['same-model', 'zen-only', 'ovh-only']);
      expect(ids.where((x) => x == 'same-model').length, 1);
    });

    test('某条上游没模型也不影响其它两条（不留空分组）', () {
      final cfg = zenConfigForTest(
        userConfig(),
        port: 4003,
        models: const <String>['zen-a'],
        // kiloModels / ovhModels 故意留空
      );
      expect(cfg.providers.where((p) => p.id == 'zen').length, 1);
      expect(cfg.models.where((m) => m.provider == 'zen').map((m) => m.id),
          <String>['zen-a']);
    });

    test('合并函数本身：空串与重复都滤掉，保序', () {
      final out = mergedModelSpecs(
          'zen', <String>['a', '', 'b', 'a', 'c', 'b']);
      expect(out.map((m) => m.id).toList(), <String>['a', 'b', 'c']);
      expect(out.every((m) => m.provider == 'zen'), isTrue);
    });
  });

  test('Kilo 拿不到模型时**不写**那个厂家（不能留一个点不开的分组）', () {
    final cfg = zenConfigForTest(
      userConfig(),
      port: 4002,
      models: const <String>['mimo-v2.6-flash-free'],
      // kiloModels 故意留空
    );
    expect(cfg.providers.any((p) => p.id == 'kilo'), isFalse,
        reason: '空分组只会让用户在模型选择器里看到一条打不开的通道');
    expect(cfg.providers.any((p) => p.id == 'zen'), isTrue);
  });

  test('空模型列表 → 只加厂家、不加模型（调用方另有判断，不能崩）', () {
    final cfg = zenConfigForTest(userConfig(), port: 41000, models: const <String>[]);
    expect(cfg.providers.any((p) => p.id == ZenChannel.providerId), isTrue);
    expect(cfg.models.where((m) => m.provider == ZenChannel.providerId), isEmpty);
  });

  // ─────────────────────────── 2026-10-11：这一组**不用写 Key**（用户纠正）
  //
  // 用户原话：「这个项目的特点就是不用写key」。这条通道的凭据是本地代理按官方
  // 形状自己带的（上游那条是匿名通道，凭据就是公开的字面量 `public`），
  // 所以任何"只看安全区"的判断都会把它误判成**没配 Key**：
  //   * 模型选择器给它打红字「未配 Key」，展开还催用户"去填 Key 并测试并保存"；
  //   * `ModelStore._firstUsable()` 会跳过它 → 只装了免费通道的用户看到的是
  //     "还没有可用模型：去填地址和 API Key"，而能用的模型就在旁边。
  // 下面是钉住这份名单的测试：改 provider id / 改这份集合，必须两边一起改。

  test('zen / local / polli 属于「凭据由 App 自己提供」的厂家 —— 界面不该要求用户填 Key', () {
    expect(
      ConfiguredModels.appProvidedCredentialIds,
      <String>{
        ZenChannel.providerId,
        LocalModelSpec.providerId,
        // 2026-10-15 新增：Pollinations 免 Key 通道。它的匿名层**本来就不要 Key**
        // （实测不带任何 Authorization 就是 200），所以必须在名单里 ——
        // 否则换了供应商，同一个"催用户填 Key"的毛病会原样复现。
        PolliChannel.providerId,
      },
      reason: '这份名单就是"哪些厂家不用用户写 Key"。名单里少一个 → 那一组又会被'
          '标成「未配 Key」并催用户去填一个根本不需要的 Key（用户实测纠正过）；'
          '多一个（把一个真要 Key 的厂家塞进来）→ 会掩盖"用户确实还没填 Key"这个真实状态。',
    );
    // 具体到 zen：它的凭据变量名是 ZEN_API_KEY，而**安全区里永远没有**它 ——
    // 值由 `ProviderKeys.envFor` 注入占位值 `local-zen`，转发时被代理覆盖成 `public`。
    expect(ZenChannel.apiKeyEnv, 'ZEN_API_KEY');
  });
}
