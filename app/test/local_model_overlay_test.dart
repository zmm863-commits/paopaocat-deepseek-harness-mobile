import 'dart:io';

import 'package:dsh_mobile/data/configured_models.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/local/local_model_spec.dart';
import 'package:flutter_test/flutter_test.dart';

/// 端侧模型接入 overlay 的**集成测试**（不是纯逻辑单测）。
///
/// 为什么非要测这一层：`local_model_server.dart` 起进程、`dsh_runtime.dart` 写 overlay，
/// 两者各自都可以"看起来对"，但真正让 DSH 用上本地模型的，是 overlay 里那 5 行 YAML。
/// 写错一个缩进、少一个 baseURL，表现就是"模型列表里看不到"或"连接被拒"——
/// 而那是最难在真机上定位的一类问题。
///
/// 这里跑的是**真实的** `writeOverlayFromConfig`（写真实文件、再读回来），
/// 只有"起 llama 进程"那一小段被绕开。
void main() {
  late Directory tmp;
  late DshRuntime runtime;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dsh-overlay-test-');
    runtime = DshRuntime(<String, dynamic>{'nodeHome': tmp.path});
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const spec = LocalModelSpec(
    port: 39341,
    modelId: 'qwen2.5-1.5b-instruct-q4_k_m',
    displayName: 'Qwen2.5-1.5B',
  );

  test('contextWindow 必须跟引擎 -c 一致（16384），否则 DSH 把 maxTokens 压成 1', () async {
    // 真机踩坑（2026-10-08）：overlay 里 local 模型的 contextWindow 曾经硬编码 4096。
    // DSH 的 clamp 逻辑是：
    //   maxTokens = contextWindow - 已用 prompt - 4096(安全余量)
    // 用户一轮 prompt 就有 6822 tokens，于是 available 变负 → maxTokens 被强制成 1
    // → 模型只吐一个 token 就停，表现为"发什么都空回复"。
    // 所以这里钉死：必须是 16384（跟 llama-server 的 -c 一致），绝不能再写回 4096。
    await runtime.writeOverlayFromConfig(
      config: ConfiguredConfig.empty,
      activeRoute: spec.route,
      localModel: spec,
    );
    final text = File(runtime.overlayPath).readAsStringSync();
    expect(text, contains('contextWindow: 16384'),
        reason: '必须与引擎 -c 16384 一致，否则 DSH 把 maxTokens 压成 1');
    expect(text, isNot(contains('contextWindow: 4096')));
  });

  test('★ 空配置也要写出权限预设（否则 Android 上每步都要用户批准）', () async {
    // 2026-10-17 真机铁证：用户那份会话产物里 `"sandboxMode": {"val": "workspace-write"}`。
    // 原因：BotServer 传 --patch 是有条件的（`if (runtime.hasModelConfig)`），
    // 而"还没配模型"时 overlay 不存在 → 整个 patch 没传 → 连**权限预设**一起丢 →
    // 退回默认 workspace-write + approval:ask；Android 上没有沙箱后端，
    // 于是每个工具调用都弹「请求执行操作」（用户原话）。
    // 所以：即使一个模型都没配，也必须能写出一份带 `danger-full-access` 的 overlay。
    // ⚠️ 注意不能走 writeOverlayFromConfig：它在"没有带模型的厂家"时会拒绝写
    //（`拒绝写空 providers（会写坏 overlay）`），而那正是本 bug 的成因。
    await runtime.writeMinimalOverlay();
    final text = File(runtime.overlayPath).readAsStringSync();
    expect(text, isNot(contains('providers:')),
        reason: '最小 overlay 故意不写 providers，避免写坏');
    expect(text, contains('dsh-permission-presets'),
        reason: '权限预设段必须存在，否则会话掉进 approval:ask');
    expect(text, contains('defaultPreset: danger-full-access'),
        reason: 'danger-full-access = approval never，Android 上必须用它才不会每步都问');
  });

  test('opencode-go 必须写全 api/baseURL，并补上 x-opencode-session 头', () async {
    // 2026-10-17 真机回归（用户连报两轮「会话没有建立起来」）。
    //
    // 我曾"故意不写 api/baseURL"，以为 DSH 会用它**内置**的 opencode-go provider。
    // DSH 的原话（用户 97 版日志里那行完整 error）：
    //   llm-pi-ai: provider "opencode-go" model "deepseek-v4.1-flash" needs an api;
    //   the installed catalog does not describe it,
    //   so set the route's api to the wire protocol its endpoint speaks
    // 也就是说 **DSH 的 catalog 里没有这个 provider**，必须显式写明协议；
    // 而 OpenCode 又**硬性要求** `x-opencode-session` 头（不带会 400 MissingSessionID，
    // curl 实测），所以要用 `headers`（schema 支持 `headers: z.dict(z.string())`）补上。
    // 这三行缺任何一行，会话都建不起来 —— 钉死。
    const cfg = ConfiguredConfig(
      version: 2,
      providers: <ProviderSpec>[
        ProviderSpec(
          id: 'opencode-go',
          label: 'OpenCode Go',
          baseUrl: 'https://opencode.ai/zen/go/v1',
          api: 'openai-completions',
          apiKeyEnv: 'OPENCODE_GO_API_KEY',
        ),
      ],
      models: <ModelSpec>[
        ModelSpec(
            provider: 'opencode-go',
            id: 'deepseek-v4.1-flash',
            name: 'DeepSeek V4.1 Flash'),
      ],
      groups: <RotationGroupSpec>[],
      selected: 'opencode-go/deepseek-v4.1-flash',
    );
    await runtime.writeOverlayFromConfig(
      config: cfg,
      activeRoute: 'opencode-go/deepseek-v4.1-flash',
    );
    final text = File(runtime.overlayPath).readAsStringSync();
    expect(text, contains('api: openai-completions'),
        reason: '不写 api → DSH 直接拒绝建会话（needs an api）');
    expect(text, contains('opencode.ai/zen/go/v1'),
        reason: '不写 baseURL → 同一条错误');
    expect(text, contains('x-opencode-session'),
        reason: 'OpenCode 硬性要求这个头，不带会 400 MissingSessionID');
  });

  test('overlay 必须显式指定权限预设（否则 dsh-permission-presets 不激活）', () async {
    // 复现过的真机问题（2026-10-09）：overlay 把 sandbox-policy 改成
    // danger-full-access 之后，"沙箱 + 审批"组合出来的默认值匹配不上 profile 里
    // 声明的任何预设 → 插件**不激活**，启动时刷
    //   permission (@deepseek-ai/dsh-permission-presets): Error: composed sandbox
    //   and approval defaults match no preset; configure defaultPreset explicitly
    //   dsh: warning: 1 entry did not activate
    // 本机拿同样的 patch 验证过：加这一行，两行报错都消失。
    await runtime.writeOverlayFromConfig(
      config: ConfiguredConfig.empty,
      activeRoute: spec.route,
      localModel: spec,
    );
    final text = File(runtime.overlayPath).readAsStringSync();
    expect(text, contains('dsh-permission-presets'));
    expect(text, contains('defaultPreset: danger-full-access'));
    expect(text, contains('sandbox-policy'));
    // 迁移判据：老 overlay（只有 sandbox-policy、没有 defaultPreset）必须被判为
    // "需要重写"，否则老用户装上新版也修不掉那条错误。
    expect(runtime.overlayHasSandboxFix, isTrue);
    File(runtime.overlayPath).writeAsStringSync(
        '- id: sandbox-policy\n  name: "@deepseek-ai/dsh-sandbox-policy"\n'
        '  config:\n    mode: danger-full-access\n');
    expect(runtime.overlayHasSandboxFix, isFalse,
        reason: '老 overlay 没有 defaultPreset，必须被判为要重写');
  });

  test('本地模型在跑时：overlay 里注册 local 厂家，端口/模型/默认路由都对', () async {
    await runtime.writeOverlayFromConfig(
      // 极端情况：用户一个云厂家都没配、也没有轮换组，只有本机模型。
      // 这条路径以前是"拒绝写 overlay"的，现在必须能写出来。
      config: ConfiguredConfig.empty,
      activeRoute: spec.route,
      localModel: spec,
    );

    final overlays = File(runtime.overlayPath);
    expect(overlays.existsSync(), isTrue, reason: '有本地模型时不该拒绝写 overlay');
    final text = overlays.readAsStringSync();

    expect(text, contains('"local":'));
    expect(text, contains('api: openai-completions'));
    expect(text, contains('baseURL: "http://127.0.0.1:39341/v1"'));
    expect(text, contains('- id: "qwen2.5-1.5b-instruct-q4_k_m"'));
    expect(text, contains('（本机运行）'));
    // 默认路由必须指向它，否则用户选了也用不上
    expect(text, contains('provider: "local"'));
    expect(text, contains('model: "qwen2.5-1.5b-instruct-q4_k_m"'));
    // ACP 那段也要覆盖（漏了会退回官方端点）
    expect(RegExp(r'- id: acp[\s\S]*?provider: "local"').hasMatch(text), isTrue);
  });

  test('回读：端口与"有没有 local 厂家"都能读出来（启动时清理残留下线端口要用）', () async {
    await runtime.writeOverlayFromConfig(
      config: ConfiguredConfig.empty,
      activeRoute: spec.route,
      localModel: spec,
    );
    expect(runtime.overlayHasLocalProvider, isTrue);
    expect(runtime.readLocalModelPort(), 39341);
  });

  test('本地服务没在跑（localModel=null）时不写 local；默认回落给云厂家', () async {
    const cfg = ConfiguredConfig(
      version: 1,
      providers: <ProviderSpec>[
        ProviderSpec(
          id: 'deepseek',
          label: 'DeepSeek',
          baseUrl: 'https://api.deepseek.com',
          apiKeyEnv: 'PROVIDER_DEEPSEEK_KEY',
        ),
      ],
      models: <ModelSpec>[
        ModelSpec(
            provider: 'deepseek', id: 'deepseek-chat', name: 'DeepSeek Chat'),
      ],
      groups: <RotationGroupSpec>[],
      selected: 'deepseek/deepseek-chat',
    );

    // 用户之前选的就是本地模型，但这次服务没起来（App 刚重启）
    await runtime.writeOverlayFromConfig(
      config: cfg,
      activeRoute: spec.route,
      localModel: null,
    );

    final text = File(runtime.overlayPath).readAsStringSync();
    expect(text, isNot(contains('"local":')), reason: '不能留一个指向死端口的厂家');
    expect(text, isNot(contains('127.0.0.1:39341')));
    // 选中的本地模型不可用 → 必须回落到能用的厂家，而不是写一个不存在的 route
    expect(text, contains('provider: "deepseek"'));
    expect(text, contains('model: "deepseek-chat"'));
    expect(runtime.readLocalModelPort(), isNull);
  });

  test('本地模型与云厂家可以共存：两个都写进去，默认指向选中的那个', () async {
    const cfg = ConfiguredConfig(
      version: 1,
      providers: <ProviderSpec>[
        ProviderSpec(
          id: 'deepseek',
          label: 'DeepSeek',
          baseUrl: 'https://api.deepseek.com',
          apiKeyEnv: 'PROVIDER_DEEPSEEK_KEY',
        ),
      ],
      models: <ModelSpec>[
        ModelSpec(
            provider: 'deepseek', id: 'deepseek-chat', name: 'DeepSeek Chat'),
      ],
      groups: <RotationGroupSpec>[],
      selected: 'deepseek/deepseek-chat',
    );

    await runtime.writeOverlayFromConfig(
      config: cfg,
      activeRoute: spec.route,
      localModel: spec,
    );

    final text = File(runtime.overlayPath).readAsStringSync();
    expect(text, contains('"local":'), reason: '本地模型在跑就该在列表里');
    expect(text, contains('"deepseek":'), reason: '云厂家也不能丢（用户要能切回去）');
    expect(text, contains('provider: "local"'));
    expect(text, contains('model: "qwen2.5-1.5b-instruct-q4_k_m"'));
  });

  test('route 形态就是 DSH 里看到的那个：local/<模型 id>', () {
    expect(spec.route, 'local/qwen2.5-1.5b-instruct-q4_k_m');
    expect(LocalModelSpec.providerId, 'local');
  });
  // ── 2026-10-07 真机 bug 的回归测试 ────────────────────────────────────
  //
  // 用户真机报错原文：
  //   `llm-pi-ai: no credential for provider route "local"; its profile resolves
  //    LOCAL_MODEL_API_KEY, which is not set`
  // 界面还把他引去"注册 Agnes 拿 Key"（对一个**本机**模型给这种指引是错的）。
  // 根因：overlay 写了 `apiKeyEnv: LOCAL_MODEL_API_KEY`，但没人注入这个变量。
  // 下面两条把"两边必须对得上"焊死。

  test('overlay 里 local 厂家引用的凭据变量名，就是共享常量那个', () async {
    await runtime.writeOverlayFromConfig(
      config: ConfiguredConfig.empty,
      activeRoute: spec.route,
      localModel: spec,
    );
    final yml = File(runtime.overlayPath).readAsStringSync();
    expect(yml, contains('apiKeyEnv: ${LocalModelSpec.apiKeyEnvName}'),
        reason: 'overlay 与注入侧必须用同一个常量，不能再各写一份字面量');
    expect(LocalModelSpec.apiKeyEnvName.isNotEmpty, isTrue);
    expect(LocalModelSpec.apiKeyPlaceholder.isNotEmpty, isTrue,
        reason: '本机服务不校验 Key，但 DSH 要求这个变量有值');
  });

  test('注入侧真的把这个凭据变量塞进进程环境（不是只在注释里提）', () {
    // 读源码做"契约检查"：删掉那行注入，这条测试就会红。
    // 为什么值得这么测：这类"overlay 要 X、env 没给 X"的错配**只在真机上暴露**，
    // 而且已经发生过一次；把它变成一条会在提交前就失败的测试。
    final src = File('lib/state/provider_keys.dart').readAsStringSync();
    final injects = RegExp(
            r"env\[LocalModelSpec\.apiKeyEnvName\]\s*=\s*LocalModelSpec\.apiKeyPlaceholder")
        .hasMatch(src);
    expect(injects, isTrue,
        reason: 'provider_keys.dart 必须注入 env[LocalModelSpec.apiKeyEnvName]');
  });

  group('上下文取 min（真机 Status 9 的那个坑）', () {
    // 真机 2026-10-09 事故：Gemma 3 1B 的文件名带 `ekv4096`（KV 只有 4096 格），
    // 而 App 按用户档位 16384 启动 → 第二轮就把缓存吃到 3920/4096，第三轮报
    //   Status Code: 9 · Prefill input length exceeds available state entries
    //   (remaining capacity: 176)
    //
    // 修法就是这个函数：启动时把上下文收敛到模型物理装得下的数。

    test('模型只带 4096 格 → 即使用户设了 16384，也按 4096 启动', () {
      expect(effectiveLocalContext(requested: 16384, modelKvTokens: 4096), 4096);
      expect(effectiveLocalContext(requested: 32768, modelKvTokens: 4096), 4096);
      expect(effectiveLocalContext(requested: 8192, modelKvTokens: 4096), 4096);
    });

    test('模型容量比用户档位大 → 听用户的（别白占内存）', () {
      expect(effectiveLocalContext(requested: 8192, modelKvTokens: 16384), 8192);
      expect(
          effectiveLocalContext(requested: 16384, modelKvTokens: 4096 * 4), 16384);
    });

    test('清单没写容量（0）→ 维持老行为，按用户档位', () {
      expect(effectiveLocalContext(requested: 16384, modelKvTokens: 0), 16384);
      expect(effectiveLocalContext(requested: 8192, modelKvTokens: 0), 8192);
      // 负数（清单写错）也不能把上下文收敛成 0 或负数 —— 那会让引擎直接起不来。
      expect(effectiveLocalContext(requested: 16384, modelKvTokens: -1), 16384);
    });
  });

  group('纯数字的轮换池名（用户报的「001 导致所有模型都不能用」）', () {
    /// 构造一份"轮换池名叫 001"的配置。
    ConfiguredConfig cfgWithPool(String poolName) => ConfiguredConfig(
          version: 1,
          providers: <ProviderSpec>[
            const ProviderSpec(
              id: 'deepseek',
              label: 'DeepSeek',
              baseUrl: 'https://api.deepseek.com',
              apiKeyEnv: 'PROVIDER_DEEPSEEK_KEY',
            ),
          ],
          models: <ModelSpec>[
            const ModelSpec(
                provider: 'deepseek',
                id: 'deepseek-chat',
                name: 'DeepSeek Chat'),
          ],
          groups: <RotationGroupSpec>[
            RotationGroupSpec(
                name: poolName, members: const <String>['deepseek/deepseek-chat']),
          ],
          selected: 'rotate/$poolName',
        );

    test('池名叫 001 时 id 必须带引号（否则 YAML 会把它当整数 1，全部模型都不能用）', () async {
      // 真机事故（2026-10-10，用户报）：池名是纯数字时，overlay 里写过
      //     - id: 001
      // YAML 把 001 解析成**整数 1**，而 dsh-llm-pi-ai 校验 id 必须是字符串：
      //     $.providers.rotate.models[0].id expected string but got 1
      //   → dsh: warning: 2 entries did not activate（整张 providers 表都没有适配器）
      //   → ACP `session/new 失败：Internal error`
      // 后果是**会话和定时任务全挂，且换任何模型都不行**（坏的是 provider 注册表，
      // 不是某一个模型）—— 用户只能靠"把池名改成 001池"自救。
      await runtime.writeOverlayFromConfig(
        config: cfgWithPool('001'),
        activeRoute: 'rotate/001',
      );
      final text = File(runtime.overlayPath).readAsStringSync();

      expect(text, contains('- id: "001"'),
          reason: '纯数字 id 必须带引号，否则 YAML 当成整数');
      expect(text, isNot(contains('- id: 001')),
          reason: '这就是那个让所有模型都不能用的裸写形式');
      // 默认路由也要带引号（同样是数字）
      expect(text, contains('model: "001"'));
    });

    test('非数字池名照样带引号（统一规则，不靠"猜这个值会不会是数字"）', () async {
      await runtime.writeOverlayFromConfig(
        config: cfgWithPool('cat'),
        activeRoute: 'rotate/cat',
      );
      final text = File(runtime.overlayPath).readAsStringSync();
      expect(text, contains('- id: "cat"'));
      expect(text, contains('model: "cat"'));
    });

    test('结构性兜底：overlay 里**所有**标识符都是带引号的', () async {
      // 上面两条钉的是"这一个 bug"；这一条钉的是"这一类 bug"——
      // 以后往 overlay 里加新字段时，只要忘了加引号就会在这里红。
      await runtime.writeOverlayFromConfig(
        config: cfgWithPool('001'),
        activeRoute: 'rotate/001',
        localModel: spec,
      );
      final lines = File(runtime.overlayPath).readAsLinesSync();

      final bad = <String>[];
      for (final line in lines) {
        if (line.trimLeft().startsWith('#')) continue;
        // 厂家段落头：`      xxx:` / `      "xxx":`
        final head = RegExp(r'^ {6}(\S+):\s*$').firstMatch(line);
        if (head != null && !head.group(1)!.startsWith('"')) {
          bad.add('厂家名未加引号 → $line');
        }
        // 模型 id / 默认路由值
        final idm = RegExp(r'^-?\s*- id:\s*(\S+)').firstMatch(line);
        if (idm != null) {
          final v = idm.group(1)!;
          // 启动项那几个 `- id: llm-pi-ai` 是 DSH 自己的常量，不带引号。
          // 判据是「这个 id 会不会被 YAML 当成数字/布尔」：下面这些是 cordis 里的
          // **固定条目名**（纯字母，合法 YAML 字符串），而模型 id 可能是 `001`、
          // `yes` 这种会被 YAML 改写的值 —— 所以**模型 id 必须一律加引号**，
          // 这里只放行这些常量名。`bot` 是 2026-10-19 新增的那条（让 ds-bot 与 App
          // 共用工作区），它同样是固定条目名。
          const consts = <String>{
            'llm-pi-ai',
            'agent-default-model',
            'acp',
            'sandbox-policy',
            'permission',
            'bot',
          };
          if (!v.startsWith('"') && !consts.contains(v)) {
            bad.add('模型 id 未加引号 → $line');
          }
        }
        for (final key in <String>['provider', 'model']) {
          final m = RegExp('^\\s+$key:\\s*(\\S+)').firstMatch(line);
          if (m != null && !m.group(1)!.startsWith('"')) {
            bad.add('$key 值未加引号 → $line');
          }
        }
      }
      expect(bad, isEmpty, reason: '这些行会让 YAML 把标识符当数字/布尔：\n${bad.join('\n')}');
    });
  });
}
