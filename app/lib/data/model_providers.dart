/// 内置服务商预设：端点预先填好，用户只需要填 API Key。
///
/// 关于端口/路径的可信度（**全部实测过**，2026-10-03，本机直接请求 `/models`）：
///
/// | 服务商 | Base URL | 实测结果 |
/// |---|---|---|
/// | Command（聚合） | `https://api.commandcode.ai/provider/v1` | **200** + 完整模型清单 |
/// | LongCat（美团） | `https://api.longcat.chat/openai/v1` | **401** `missing_api_key`（主机与路径真实存在） |
/// | MiMo（小米） | `https://api.xiaomimimo.com/v1` | **401** `invalid_key`（主机与路径真实存在） |
/// | DeepSeek 官方 | `https://api.deepseek.com` | 本机 DSH 的 `dsh-deepseek-account-platform` 里
///   `inferenceOrigin` 默认就是 `https://api.deepseek.com` |
///
/// 401 不等于"端点错"：它只说明**该端点要求鉴权**，能返回结构化 JSON 就证明
/// 主机名、路径、协议都是对的。
///
/// ⚠️ 三家 `/models` 都**必须带 Key**（无 Key 一律 401），所以「获取模型」
/// 按钮在 Key 为空时要给出明确提示，而不是默默失败。
library;

import 'agnes_builtin.dart';

import '../i18n/dsh_i18n.dart';

/// 一个厂家可能有的**多套端点**（"套餐"与"充值/按量"用的是不同地址）。
///
/// 用户 2026-10-04 反馈：「几个大模型有可能套餐使用和充值使用的 API 端口不一样，
/// 比如 mimo，记得加个按钮」。实测证实（两套都返回 `401 Invalid API Key`，
/// 即主机与路径真实存在）：
///   * 充值/按量：`https://api.xiaomimimo.com/v1`
///   * 套餐：      `https://token-plan-cn.xiaomimimo.com/v1`
/// 填错端点会 401/404，而用户根本不会知道该填哪个 —— 所以界面上要**一键切换**。
class ProviderEndpoint {
  const ProviderEndpoint(
      {required this.label, required this.baseUrl, this.note});

  /// 界面上显示的名字，例如「充值/按量」「套餐(token plan)」
  final String label;

  /// 这一档的端点根（不含 `/models`）
  final String baseUrl;

  /// 一句话说明（为什么会 401、该选哪个）
  final String? note;
}

/// 一个内置服务商。
class ModelProvider {
  const ModelProvider({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.keyHint,
    this.note,
    this.intro,
    this.keyUrl,
    this.topUpUrl,
    this.endpoints = const <ProviderEndpoint>[],
    this.modelsPath = '/models',
    this.exampleModels = const <String>[],
  });

  /// 写进 overlay 的 `providers.<id>:` 键。**改动会让老用户的 overlay 失效**，
  /// 所以 `command` 保留了它历史上的短名 `com`。
  final String id;

  /// 界面上显示的名字
  final String name;

  /// OpenAI 兼容端点根（不含 `/models`）。有 [endpoints] 时这是**默认那一档**
  /// （一律放"充值/按量"，因为它对所有人都能用）。
  final String baseUrl;

  /// 取模型列表的路径
  final String modelsPath;

  /// Key 输入框下的提示
  final String keyHint;

  /// 界面上的一句话说明（含坑）
  final String? note;

  /// 「我的模型」展开后的**一句话介绍**：这家是什么、适合谁。
  ///
  /// 与 [note] 的分工：`note` 讲"坑"（该选哪档端点、路径容易写错），
  /// 这里是"要不要用它"的判断依据 —— 用户 2026-10-05 的方案要求
  /// 每张卡展开后第一眼就是这句话。
  final String? intro;

  /// 去哪儿申请 Key
  final String? keyUrl;

  /// 去哪儿充值（有实测过的地址才填；没有就不显示按钮）
  final String? topUpUrl;

  /// **多套端点**（空 = 这个厂家只有一套，就用 [baseUrl]）。
  /// 非空时界面必须给一个切换按钮，别让用户自己去猜该填哪个。
  final List<ProviderEndpoint> endpoints;

  /// 该服务商常见的 model id，供用户没联网/懒得拉列表时直接选
  final List<String> exampleModels;

  /// 取模型列表的完整地址
  Uri get modelsUri => Uri.parse('$baseUrl$modelsPath');

  /// 是否有"多套端点"需要用户选
  bool get hasEndpointVariants => endpoints.length > 1;

  /// 是否必须带 Key 才能取列表（实测：这四家都是）
  bool get listNeedsKey => true;

  /// 用户填的 model id 会作为 `provider:model` 的 model 部分写进 overlay。
  /// 这里只做一个显示用的拼接，真正的路由由 DSH 决定。
  String routeFor(String modelId) => '$id:$modelId';
}

/// 内置四家。
///
/// 顺序有讲究：`com`（Command）放第一个 —— 它是聚合端点，一个 Key 就能用到
/// DeepSeek / MiMo / LongCat / GLM / Claude / GPT 等全部模型，对用户最省事。
List<ModelProvider> get kModelProviders => <ModelProvider>[
      ModelProvider(
        id: 'com',
        name: tr('Command（聚合，推荐）'),
        baseUrl: 'https://api.commandcode.ai/provider/v1',
        keyHint: 'Command API Key',
        keyUrl: 'https://commandcode.ai',
        note: tr(
            '一个 Key 即可用 DeepSeek / MiMo / LongCat / GLM / Qwen / Claude / GPT 等全部模型。'),
        intro: tr(
            '聚合端点：一个 Key 就能用到 DeepSeek / MiMo / LongCat / GLM / Qwen / Claude / GPT 等多家模型。适合不想挨家注册、只想填一次 Key 的人。'),
        exampleModels: <String>[
          'deepseek/deepseek-v4.1-flash',
          'deepseek/deepseek-v4-pro',
          'xiaomi/mimo-v2.6-pro',
          'meituan/LongCat-2.0',
          'zai-org/GLM-5.3',
        ],
      ),
      ModelProvider(
        id: 'deepseek',
        name: tr('DeepSeek 官方'),
        baseUrl: 'https://api.deepseek.com',
        keyHint: tr('DeepSeek API Key（sk- 开头）'),
        keyUrl: 'https://platform.deepseek.com/api_keys',
        // 充值页也实测过（200），用户问"去哪儿充值"时给一个能点的入口。
        topUpUrl: 'https://platform.deepseek.com/top_up',
        note: tr(
            '官方直连。若你的 Key 是 Anthropic 协议的，端点要改成 https://api.deepseek.com/anthropic。'),
        intro:
            tr('DeepSeek 官方直连，用的是官方账号自己的额度与计费。适合已经有 DeepSeek 账号、想直接走官方端点的人。'),
        // ⚠️ 官方 `/models` 现在只列这两个（2026-10-16 核对）：
        //    deepseek-flash = DeepSeek-V4.1-Flash、deepseek-v4-pro = DeepSeek-V4-Pro。
        //    这里以前是 `deepseek-chat` / `deepseek-reasoner`（V3/R1 时代的名字）——
        //    名字换了以后，**拉取失败时的兜底清单会给出两个已经不存在的模型**，
        //    用户点"测试并保存"就会拿它们去测、然后失败。
        //    来源：https://api-docs.deepseek.com/api/list-models （返回样例）
        //    ⚠️ 以后这里会过时 —— 这正是"兜底清单需要跟着上游核对"的例子。
        exampleModels: <String>['deepseek-flash', 'deepseek-v4-pro'],
      ),
      // ── OpenCode Go（2026-10-17 用户要求「增加一个 opencode go 的设置页面」）──
      //
      // 端点依据（不是猜的）：DSH 内置的 pi-ai 里，`opencode-go` 这个 provider 的
      // 端点是 **`https://opencode.ai/zen/go/v1`**（免费那档 zen 是 `/zen/v1`），
      // 定义在 `@earendil-works/pi-ai/dist/providers/opencode-go.js`。
      // 它支持三种协议（openai-completions / anthropic-messages / openai-responses），
      // 本 App 的厂家卡片只走 openai-completions —— 那正好覆盖 23 个模型（含 deepseek / GLM 全套）。
      ModelProvider(
        id: 'opencode-go',
        name: tr('OpenCode Go'),
        baseUrl: 'https://opencode.ai/zen/go/v1',
        keyHint: tr('OpenCode API Key（同一个 Key 也用于免费那档）'),
        keyUrl: 'https://opencode.ai/auth',
        note: tr(
            '端点是 /zen/go/v1（免费那档是 /zen/v1，两个别混）。它同时支持 OpenAI 与 Anthropic 两种协议，这里走 OpenAI 兼容。'),
        intro: tr(
            'OpenCode 的 Go 套餐：一个 Key 就能用 DeepSeek V4/V4.1、GLM 5.x、Qwen3.8、Grok 4.x 这一批模型。'),
        // 拉取失败时的兜底清单（与 DSH 内置的 opencode-go 模型表对得上）。
        exampleModels: <String>[
          'deepseek-v4.1-flash',
          'deepseek-v4-pro',
          'glm-5.3',
          'qwen3.8-flash',
        ],
      ),
      ModelProvider(
        id: 'longcat',
        name: tr('LongCat（美团）'),
        baseUrl: 'https://api.longcat.chat/openai/v1',
        keyHint: 'LongCat API Key',
        // 注册入口：2026-10-04 实测 https://longcat.chat/ 返回 200（用户反馈"不知道去哪注册"，
        // 所以每个内置厂家能给就都给一个能打开的入口）。
        keyUrl: 'https://longcat.chat/',
        note: tr('路径是 /openai/v1（不是 /v1），漏掉 openai 会 404。'),
        intro: tr('美团 LongCat。适合已经拿到 LongCat Key 的用户。'),
        exampleModels: <String>['LongCat-Flash-Chat'],
      ),
      ModelProvider(
        id: 'mimo',
        name: tr('MiMo（小米）'),
        // 默认给"充值/按量"那套端点：它对所有人都能用；套餐用户请用界面上的切换按钮
        // 换到 `token-plan-cn` 那套（两套实测都真实存在，但填错会 401/404）。
        baseUrl: 'https://api.xiaomimimo.com/v1',
        keyHint: 'MiMo API Key',
        // 2026-10-04 实测 https://platform.xiaomimimo.com/ 返回 200（HTML），是真实控制台。
        // ⚠️ 裸域名 xiaomimimo.com 解析失败，别用那个。
        keyUrl: 'https://platform.xiaomimimo.com/',
        endpoints: <ProviderEndpoint>[
          ProviderEndpoint(
            label: tr('充值/按量'),
            baseUrl: 'https://api.xiaomimimo.com/v1',
            note: tr('按量付费（充值）账号用这个端点。'),
          ),
          ProviderEndpoint(
            label: tr('套餐(token plan)'),
            baseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
            note: tr('买了套餐的账号必须用这个端点，用错会 401/404。'),
          ),
        ],
        note: tr('小米 MiMo：**套餐与充值是两套端点**，用界面上的按钮切换（实测两套都真实存在）。'),
        intro: tr('小米 MiMo。套餐用户与按量付费用户走两套不同端点，展开后可以一键切换，不用自己猜地址。'),
        exampleModels: <String>['mimo-v2.5', 'mimo-v2.6-pro'],
      ),
    ];

/// Agnes（免费）的内置卡：它不在 [kModelProviders] 里 —— 端点、注册地址与
/// "免费"的口径都来自 `data/agnes_builtin.dart`（全是官方文档原文），
/// 这里只是把它包成一张和别家同形的卡片，界面不用为它写一套特例。
///
/// ⚠️ `exampleModels` 只放**文本**模型：图像 / 视频那两个模型是内置端口
/// （见 `AgnesBuiltin`），用户明确要求"图形和视频已经内置端口，不需要显示出来"
/// —— 所以它们不该出现在会话的模型列表里，选上去也聊不了天。
ModelProvider get kAgnesModelProvider => ModelProvider(
      id: AgnesBuiltin.providerId,
      name: AgnesBuiltin.label,
      baseUrl: AgnesBuiltin.baseUrl,
      keyHint: tr('Agnes API Key（在 platform.agnes-ai.cn 创建，sk- 开头）'),
      keyUrl: AgnesBuiltin.registerUrl,
      intro: tr(
          'Agnes 官方端点：文本、图像、视频共用一个 Key（图形/视频的端口是内置的，不用你配），官方当前把这几个模型标为免费（限时优惠，以平台公告为准）。适合想先零成本试一下模型好不好用的人。'),
      exampleModels: <String>[AgnesBuiltin.textModel],
    );

/// 「我的模型」里内置卡片的**顺序**（用户 2026-10-05 指定的原文顺序）：
///
///   Agnes（免费）→ DeepSeek → Command（聚合）→ MiMo → LongCat
///
/// LongCat 是**真实内置厂家**（端点实测存在），只是没被点名 —— 放最后一张卡，
/// 而不是删掉：删掉会让已经配了 LongCat 的用户丢功能。
///
/// 这里**只有顺序**：id 与 baseUrl 一律取既有常量，没有任何语义改动。
const List<String> kMyModelOrder = <String>[
  AgnesBuiltin.providerId, // 'agnes'
  'deepseek',
  'opencode-go', // OpenCode Go（2026-10-17 新增）
  'com', // Command（聚合）：id 是历史短名，不能改
  'mimo',
  'longcat',
];

/// 「我的模型」内置卡片的完整定义（严格按 [kMyModelOrder] 的顺序）。
///
/// 用函数而不是 const 列表：`providerById` 要查 [kModelProviders]，
/// 而且顺序表里出现未知 id 时应当**跳过而不是崩**。
List<ModelProvider> myModelProviders() {
  final out = <ModelProvider>[kAgnesModelProvider];
  for (final id in kMyModelOrder) {
    if (id == kAgnesModelProvider.id) continue;
    final p = providerById(id);
    if (p != null) out.add(p);
  }
  return out;
}

/// 按 id 找服务商；找不到返回 null（用户可能手填了自定义 id）。
ModelProvider? providerById(String id) {
  if (id == kAgnesModelProvider.id) return kAgnesModelProvider;
  for (final p in kModelProviders) {
    if (p.id == id) return p;
  }
  return null;
}

/// 兜底服务商：老用户存储里可能只有 Base URL 没有 provider id。
/// 用它的端点去猜是四家里的哪一个。
ModelProvider? providerByBaseUrl(String baseUrl) {
  final normalized = baseUrl.trim().toLowerCase();
  // Agnes 不在 kModelProviders 里（见 kAgnesModelProvider），先单独对一次。
  if (kAgnesModelProvider.baseUrl.toLowerCase() == normalized) {
    return kAgnesModelProvider;
  }
  for (final p in kModelProviders) {
    if (p.baseUrl.toLowerCase() == normalized) return p;
  }
  // 宽松匹配：只看主机名，容忍用户手改了尾部斜杠
  final agnesHost = Uri.tryParse(kAgnesModelProvider.baseUrl)?.host;
  if (agnesHost != null && normalized.contains(agnesHost)) {
    return kAgnesModelProvider;
  }
  for (final p in kModelProviders) {
    final host = Uri.tryParse(p.baseUrl)?.host;
    if (host != null && normalized.contains(host)) return p;
  }
  return null;
}
