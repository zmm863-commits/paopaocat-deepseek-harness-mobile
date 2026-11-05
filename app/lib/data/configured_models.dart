import 'dart:convert';
import 'media_port_rule.dart';
import 'dart:io';

import '../i18n/dsh_i18n.dart';
import 'atomic_file.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// 用户**真实配置过**的模型清单：读写 `<filesDir>/models.json`。
///
/// 为什么需要它：改造前对话页的模型面板读的是 `data/model_catalog.dart` 里
/// **写死的设计稿清单**（`Hy4 preview` / `GLM-5.3` / `Hy3` …）。那些名字是
/// 云端服务的显示名，在用户自己的端点上**根本不存在**。
/// 用户实测反馈：「会话界面模型选择读取的不是设置里已经有的模型，而是我
/// 截图上的模型」——就是这个问题。
///
/// ## 2026-10-04 起：v2（多厂家并存 + 轮换组）
///
/// 用户实测反馈还有两条直接指向这里：
///   * 「模型设置页面，设置完一个模型，无法再选择其他厂家模型」——
///     旧格式（v1）**整份文件只允许一个 provider/baseUrl**，
///     再配第二个厂家的模型就只能把第一个覆盖掉。
///   * 「设立一个模型轮换按钮，比如取名叫 cat，里面包含不同厂家的模型，
///     DSH 调用 cat 时遇到 429 限流就自动换下一个」——旧格式根本没有"组"。
///
/// 所以 v2 的结构是：
/// ```json
/// {
///   "version": 2,
///   "selected": "deepseek/deepseek-chat",   // 或 "rotate/cat"
///   "providers": [
///     {"id":"deepseek","label":"DeepSeek","baseUrl":"https://api.deepseek.com/v1",
///      "api":"openai-completions","apiKeyEnv":"DEEPSEEK_API_KEY"}
///   ],
///   "models": [
///     {"provider":"deepseek","id":"deepseek-chat","name":"DeepSeek Chat","context":65536}
///   ],
///   "groups": [
///     {"name":"cat","members":["deepseek/deepseek-chat","qwen/qwen-max"]}
///   ]
/// }
/// ```
///
/// **关键约定（整套代码都依赖它，改之前先看这里）：**
///   * 一条模型的全限定标识是 `route = "<provider>/<model>"`；
///   * **轮换组的 provider 固定是 `rotate`**，所以组 `cat` 的 route 就是
///     `rotate/cat` —— 这样"组"和"普通模型"在界面上是同一种东西
///     （可选中的一项），在 overlay 里也是同一种东西（provider + model）。
///     因此**真实厂家的 provider id 不许叫 `rotate`**（[sanitizeProviderId]
///     会把这个名字让开）。
///   * **API Key 不进这个文件**：Key 一律在 `flutter_secure_storage`
///     （见 `state/provider_keys.dart`），这里只存 `apiKeyEnv` 这个**变量名**。
class ConfiguredModels {
  const ConfiguredModels._();

  /// 当前写盘格式的版本号。读到更小的版本会做迁移（见 [readConfig]）。
  static const int currentVersion = 2;

  /// 轮换组占用的 provider 名（见类注释里的约定）。
  static const String rotateProviderId = 'rotate';

  /// **凭据由 App 自己提供**的厂家 —— 用户**不用、也不该被要求**填 Key。
  ///
  /// 目前两个（字符串必须与各自的常量一致，有测试盯着）：
  ///   * `zen`   —— 「免费模型（无需 Key）」：本地代理按官方 CLI 形状转发到
  ///     OpenCode Zen 的**匿名**通道，上游凭据就是那个公开的 `public`；
  ///   * `local` —— 本机模型服务：本机 llama 不校验 Key，注入占位值即可。
  ///
  /// ## 为什么非要有这份名单（2026-10-11 用户纠正："这个项目的特点就是不用写key"）
  ///
  /// 这两家的 Key **不进安全区**（`ProviderKeys.read()` 永远读不到），
  /// 由 `ProviderKeys.envFor()` 注入占位值让 DSH 的凭据检查过得去。
  /// 于是任何"只看安全区"的判断都会把它们当成**没配 Key**，表现有两处：
  ///   * 模型选择器给「免费模型」那一组打红字「未配 Key」，展开还催用户
  ///     "去「设置 → 模型 → 我的模型」填 Key 并「测试并保存」" ——
  ///     而这条通道的**设计前提就是不用写 Key**，这句话本身是错的；
  ///   * `ModelStore._firstUsable()` 会跳过它们 → 只装了免费通道的用户看到的是
  ///     "还没有可用模型：去填地址和 API Key"，明明能用的模型就在旁边。
  ///
  /// 所以判定口径统一成一句：**Key 要么在安全区，要么由 App 自己提供**。
  static const Set<String> appProvidedCredentialIds = <String>{
    'zen',
    'local',
    // 2026-10-15 新增：Pollinations 免 Key 通道（见 data/polli_channel.dart）。
    // 它的匿名层**本来就不要 Key**，所以这里必须算进去 —— 否则模型选择器会给它
    // 打红字「未配 Key」并催用户"去填地址和 Key"，而用户根本不需要填。
    'polli',
  };

  static File fileOf(String filesDir) => File('$filesDir/models.json');

  // ------------------------------------------------------------------ 数据模型

  /// 一个厂家端点（overlay 里 `providers` 的一个 key）。
  static ProviderSpec provider({
    required String id,
    required String baseUrl,
    String? label,
    String api = 'openai-completions',
    String? apiKeyEnv,
  }) =>
      ProviderSpec(
        id: sanitizeProviderId(id),
        label: (label ?? '').trim().isEmpty ? id : label!.trim(),
        baseUrl: baseUrl.trim(),
        api: api.isEmpty ? 'openai-completions' : api,
        apiKeyEnv: (apiKeyEnv ?? '').trim().isEmpty
            ? envNameFor(sanitizeProviderId(id))
            : apiKeyEnv!.trim(),
      );

  /// provider id 里只允许出现这些字符（overlay 的 YAML key + DSH 的路由键）。
  /// 同时**让开 `rotate`**：那个名字被"轮换组"占用，见类注释。
  static String sanitizeProviderId(String raw) {
    var s = raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_.-]'), '-');
    s = s.replaceAll(RegExp(r'-{2,}'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.isEmpty) s = 'provider';
    if (s == rotateProviderId) s = 'rotate-real';
    return s;
  }

  /// 从用户给的名字推出一个**可用且不冲突**的 provider id。
  ///
  /// 背景（2026-10-12 别人那份 v0.57 真机日志）：[sanitizeProviderId] 把非
  /// `[a-z0-9_.-]` 的字符换成 `-`，**纯中文名字换完是空的** → 兜底成固定的
  /// `'provider'`。于是那位用户的「书生·端砚」id 就叫 `provider`（日志里处处
  /// `provider=provider`）。后果：
  ///   * 再加一家纯中文名字的厂家 → **id 一样，会在 models.json 里互相覆盖（真丢数据）**；
  ///   * 安全区 key 变成 `dsh_provider_key_provider`、环境变量变成 `PROVIDER_API_KEY`；
  ///   * 而 `provider` 恰好又是解析坏数据时的**哨兵值**，真假分不出来。
  ///
  /// 所以：推不出有意义的名字（或推出来已经被占用）时，改用 `custom`、
  /// `custom-2`、`custom-3`…；[taken] 传"已经用掉的名字"。
  static String uniqueProviderId(String preferred, {required Set<String> taken}) {
    final base = sanitizeProviderId(preferred);
    // `sanitizeProviderId` **永远不返回空串**（空的时候它兜 `provider`），
    // 所以这里判的是那个哨兵值本身 —— 它代表"这个名字推不出东西"。
    final stem = base == 'provider' ? 'custom' : base;
    if (!taken.contains(stem)) return stem;
    for (var i = 2; i < 1000; i++) {
      final cand = '$stem-$i';
      if (!taken.contains(cand)) return cand;
    }
    // 极端情况（999 家同名）：用时间戳兜底，**绝不返回已占用的名字**。
    return '$stem-${DateTime.now().millisecondsSinceEpoch % 100000}';
  }

  /// 默认的凭据环境变量名：`deepseek` → `DEEPSEEK_API_KEY`。
  static String envNameFor(String providerId) =>
      '${providerId.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '_')}_API_KEY';

  // ------------------------------------------------------------ 兼容用法：读

  /// 读盘（**v1 兼容视图**）。
  ///
  /// 仍然返回"单厂家"形状，给还没迁移过来的旧调用点用（`settings_page.dart`
  /// 拿 `.models` 去注册模型 id）。v2 文件也能读：provider/baseUrl 取
  /// "选中项所属的那个厂家"，`selected` 返回**不带 provider 前缀的 model id**
  /// —— 保持和旧行为一致，避免调用方把 `deepseek/xxx` 当成 model id 用。
  static ({
    String? provider,
    String? baseUrl,
    String? selected,
    List<({String id, String? name, int? context})> models,
  }) read(String filesDir) {
    final cfg = readConfig(filesDir);
    final active = cfg.selected;
    if (active == null || active.isEmpty) {
      return (
        provider: cfg.providers.isEmpty ? null : cfg.providers.first.id,
        baseUrl: cfg.providers.isEmpty ? null : cfg.providers.first.baseUrl,
        selected: null,
        models: <({String id, String? name, int? context})>[
          for (final m in cfg.models)
            (id: m.id, name: m.name, context: m.context),
        ],
      );
    }

    // 选中项是轮换组时，`selected` 就回组名，provider 回 `rotate`。
    final slash = active.indexOf('/');
    final head = slash < 0 ? '' : active.substring(0, slash);
    final tail = slash < 0 ? active : active.substring(slash + 1);
    final isGroup = head == rotateProviderId;

    final owner =
        isGroup ? null : _firstOrNull(cfg.providers, (p) => p.id == head);

    return (
      provider: isGroup ? rotateProviderId : (owner?.id ?? head),
      baseUrl: owner?.baseUrl ??
          (cfg.providers.isEmpty ? null : cfg.providers.first.baseUrl),
      selected: tail,
      models: <({String id, String? name, int? context})>[
        for (final m in cfg.models)
          (id: m.id, name: m.name, context: m.context),
      ],
    );
  }

  /// 读盘（**v2 完整视图**）。
  ///
  /// ## ⚠️ 这里**不再**把读失败当成"空配置"（审计 P0-9）
  ///
  /// 原来的写法是 `catch { return empty; }`，于是：
  /// **半份 JSON（进程被杀/磁盘满）→ 读成空 → 下一次保存把空写回去 →
  /// 用户的厂家与模型全没了，且没有任何提示。**
  ///
  /// 现在区分两种情形：
  ///   * 文件**不存在** → 真的还没配过 → 返回空（正确）；
  ///   * 文件**在但解析不了** → 这是**损坏**，不是"没配"：
  ///     把坏文件挪到 `.corrupt`（保住用户的原始字节，可人工恢复），
  ///     记进 [lastReadError]，界面据此说话。
  ///
  /// 关键在"挪走"：留着的话下一次保存照样会覆盖它 —— 挪走之后，
  /// 即使随后写了一份空配置，用户原来的数据还在 `.corrupt` 里。
  ///
  /// v1 文件（没有 `providers` 数组）会被**就地迁移**成 v2 结构返回；
  /// 迁移只读不写（写盘由调用方决定，避免读一次就改用户文件）。
  static ConfiguredConfig readConfig(String filesDir) {
    final f = fileOf(filesDir);
    if (!f.existsSync()) {
      lastReadError = null;
      return ConfiguredConfig.empty;
    }
    try {
      final raw = f.readAsStringSync();
      // 0 字节 / 全空白 = 没有内容可丢，按"还没配过"处理（也与我们自己的
      // `looksCorruptJson` 口径一致）。真损坏（有内容但解析不了）走下面。
      if (raw.trim().isEmpty) {
        lastReadError = null;
        return ConfiguredConfig.empty;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        // 能解出来但不是对象 → 同样是损坏，走隔离路径。
        return _treatAsCorrupt(f, '顶层不是 JSON 对象（是 ${decoded.runtimeType}）');
      }
      lastReadError = null;
      return _parse(decoded);
    } catch (e) {
      return _treatAsCorrupt(f, '$e');
    }
  }

  /// 损坏处置：隔离原文件 + 记录原因 + 返回空配置。
  ///
  /// 隔离失败（比如只读挂载）时**仍然**记录错误 —— 至少用户在界面上能看到
  /// "你的配置读不出来"，而不是一片空白的"还没配"。
  static ConfiguredConfig _treatAsCorrupt(File f, String why) {
    final moved = quarantineCorrupt(f);
    final where = moved == null ? '（原文件未能隔离，请勿覆盖）' : '（已另存为 ${moved.path}）';
    lastReadError = '模型配置读不出来：$why $where';
    debugPrint('[dsh-models] ⚠️ models.json 解析失败，已按损坏处理$where：$why');
    return ConfiguredConfig.empty;
  }

  /// 最近一次读盘是不是"文件在、但读坏了"。null = 正常（或还没配过）。
  ///
  /// 界面必须用它把"你配过、现在读不出来"和"还没配"分开说 ——
  /// 这两种情形对用户的意义完全不同。修完配置或成功保存一次会被清空。
  static String? lastReadError;

  static ConfiguredConfig _parse(Map decoded) {
    final rawProviders = decoded['providers'];
    final rawModels = decoded['models'];

    // ── provider 列表 ────────────────────────────────────────────────
    final providers = <ProviderSpec>[];
    if (rawProviders is List) {
      for (final item in rawProviders) {
        if (item is! Map) continue;
        final id =
            sanitizeProviderId('${item['id'] ?? item['provider'] ?? ''}');
        if (id.isEmpty ||
            id == 'provider' && (item['id'] ?? item['provider']) == null) {
          continue;
        }
        providers.add(provider(
          id: id,
          label: item['label']?.toString(),
          baseUrl: '${item['baseUrl'] ?? item['base_url'] ?? ''}',
          api: '${item['api'] ?? 'openai-completions'}',
          apiKeyEnv: item['apiKeyEnv']?.toString(),
        ));
      }
    }

    // ── v1 迁移：整份文件只有一个 provider/baseUrl ────────────────────
    //
    // ⚠️⚠️ 2026-11-05 网友真机事故的**真正根因**就在这里。
    //
    // 老格式（v1）文件只有顶层 `provider` / `baseUrl`。迁移时如果 `baseUrl`
    // **缺失或为空**，原来的代码照样造出一条厂家记录：
    //     id=com（默认值）, label=com, baseUrl=""
    // 之后每次写 overlay 都带着它 → 引擎 `llm-pi-ai` 抛
    //     provider "com" has an empty baseURL
    // → **整条 llm 插件激活失败** → 所有厂家都没有适配器 → 用户看到的是
    //   「会话没能建起来」，换任何模型都不行。
    //
    // 这正好解释了他反馈的两件事：
    //   ① 是**升级上来的**才出现 —— 只有读到老格式文件才会走这段；
    //   ② **设置里看不到** —— id 是 `com`，和内置的「Command（聚合，推荐）」
    //      撞了，`_customProviders()` 按"不在内置清单里"过滤时把它当内置的排掉；
    //      而内置卡没有删除按钮。于是它在设置页完全隐形、也删不掉，
    //      只在会话的模型选择器里露一个「com · 0 个模型」。
    //
    // 现在的规矩：**地址为空就不造厂家**。宁可让 providers 留空、交给上层
    // 的自愈路径（`ensureModelConfig` 会用默认端点重建一份正常配置），
    // 也绝不落一条会让全局瘫痪的记录。
    final legacyBase = '${decoded['baseUrl'] ?? ''}'.trim();
    final legacyId = sanitizeProviderId('${decoded['provider'] ?? 'com'}');
    var legacyProvider = providers.isEmpty && legacyBase.isNotEmpty
        ? legacyId
        : null;
    if (providers.isEmpty && legacyBase.isNotEmpty) {
      providers.add(provider(
        id: legacyProvider!,
        label: '${decoded['provider'] ?? legacyProvider}',
        baseUrl: legacyBase,
        apiKeyEnv: decoded['apiKeyEnv']?.toString(),
      ));
    } else if (providers.isEmpty) {
      debugPrint('[dsh-models] 老格式文件里 baseUrl 为空 → 不造厂家'
          '（造出来会让整条 llm 插件激活失败，见 2026-11-05 事故）');
    }

    // ── 模型列表 ─────────────────────────────────────────────────────
    final models = <ModelSpec>[];
    if (rawModels is List) {
      for (final item in rawModels) {
        if (item is String) {
          final id = item.trim();
          if (id.isEmpty) continue;
          models.add(ModelSpec(
            provider: _ownerFor(id, providers, legacyProvider),
            id: id,
          ));
          continue;
        }
        if (item is! Map) continue;
        final id =
            (item['id'] ?? item['model'] ?? item['name'])?.toString().trim();
        if (id == null || id.isEmpty) continue;
        final pid = (item['provider'] ?? '').toString().trim();
        final ctx = item['context'] is int
            ? item['context'] as int
            : int.tryParse('${item['context'] ?? ''}');
        models.add(ModelSpec(
          provider: pid.isEmpty
              ? _ownerFor(id, providers, legacyProvider)
              : sanitizeProviderId(pid),
          id: id,
          name: item['name']?.toString(),
          context: ctx,
        ));
      }
    }

    // v1 里 provider 字段可能只在顶层写了一次；补上每个模型的归属。
    //
    // ⚠️ providers 可能为空 —— 老文件 baseUrl 也为空时，上面**故意没造厂家**。
    // 那种情况下这些模型无处可挂，直接丢弃：留着只会在模型选择器里出现
    // 一条指向不存在厂家的死条目（而且 `providers.first` 当场抛
    // `Bad state: No element`，整份配置被当成损坏文件）。
    final fixed = providers.isEmpty
        ? <ModelSpec>[]
        : <ModelSpec>[
            for (final m in models)
              providers.any((p) => p.id == m.provider)
                  ? m
                  : m.copyWith(provider: providers.first.id),
          ];

    // ── 轮换组 ──────────────────────────────────────────────────────
    final groups = <RotationGroupSpec>[];
    final rawGroups = decoded['groups'];
    if (rawGroups is List) {
      for (final item in rawGroups) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final members = <String>[];
        final rawMembers = item['members'];
        if (rawMembers is List) {
          for (final m in rawMembers) {
            final v = m is Map ? '${m['route'] ?? ''}' : '$m';
            final t = v.trim();
            if (t.isNotEmpty && !members.contains(t)) members.add(t);
          }
        }
        groups.add(RotationGroupSpec(name: name, members: members));
      }
    }

    // ── ⚠️ 媒体端口模型**不进会话清单**（用户 2026-10-12 排查时发现）──────
    //
    // Agnes 的图像 / 视频模型是**内置端口**，走 `/images/generations` 与 `/videos`，
    // 拿去打 `/chat/completions` **必然 400**。
    //
    // 写入侧（设置页）早就过滤了；**读取侧原来不过滤** → 老版本写进去的残留、
    // 或用户手填的条目，会一直留在「会话模型面板」里，选中就 400 —— 这跟
    // `prompt_expert` 那个 400 是**同一条链路，只是入口不同**（修那个 bug 时
    // 我在这份注释里承认过"清单里已经存在的媒体模型它管不着"，但当时只修了
    // "提示词专家"这一个使用点，没修"读取/写 overlay"这条路）。
    //
    // 为什么滤在**这里**就够：会话面板（`choices`）、写 overlay（`dsh_runtime`）、
    // 诊断报告全都读 `readConfig`。滤一次，全部生效，不用逐个改 ——
    // 这种"漏一个入口就复发"的规则，越少调用点越安全。
    // 落盘时（用户下次保存）顺带把残留清掉，不用另做迁移。
    final chatModels = <ModelSpec>[
      for (final m in fixed)
        if (!isMediaPortModel(m.provider, m.id)) m,
    ];

    // ⚠️ 清掉**已废弃厂家**的模型（见 [kRetiredProviderIds]）。留着的后果不是"多几条
    // 选项"那么轻：一旦 `selected` 指向它，ACP 建会话就内部失败，用户看到的是
    // 「会话没有建立起来」——而那正是 2026-10-17 用户连报两轮的现象。
    final aliveModels = <ModelSpec>[
      for (final m in chatModels)
        if (!kRetiredProviderIds.contains(m.provider)) m,
    ];
    final droppedRetired = chatModels.length - aliveModels.length;
    if (droppedRetired > 0) {
      debugPrint('[dsh-models] 清掉 $droppedRetired 条已废弃厂家的模型'
          '（${kRetiredProviderIds.join(',')}）');
    }

    var selected = decoded['selected']?.toString();
    // 选中项正好是被滤掉的媒体模型 → 一并清掉。否则界面会显示一个
    // "当前用的模型"却哪儿都找不到它（选中必然失败）。
    if (selected != null && isMediaPortRoute(selected)) {
      debugPrint('[dsh-models] 选中项 $selected 是媒体端口模型 → 已清掉');
      selected = null;
    }
    // 选中项指向已废弃厂家 → 同样清掉（否则会话建不起来，且改成 null 后
    // 运行时会回退到第一个可用模型）。
    if (selected != null) {
      final i = selected.indexOf('/');
      final pid = i > 0 ? selected.substring(0, i) : '';
      if (kRetiredProviderIds.contains(pid)) {
        debugPrint('[dsh-models] 选中项 $selected 属于已废弃厂家 → 已清掉');
        selected = null;
      }
    }

    // ── 旧数据迁移：三条免 Key 通道 → 一条（2026-11-03）───────────────
    //
    // 2026-11-03 起三条上游（zen/kilo/ovh）合并成一个厂家，但**升级安装时
    // `models.json` 里还留着旧的三个 provider**（`pm install -r` 不清数据）。
    // 不迁移的话用户升级后打开会话，看到的还是三个同名分组 —— 真机实测
    // 第一次启动就是这样（App 先用旧配置渲染，enable 的重写还没生效）。
    //
    // 所以在这里做**读取时迁移**：只要看到 kilo/ovh 这两条遗留厂家，
    // 就把它们的模型并进 zen、删掉它们自己。这样不管谁读配置
    // （会话面板 / 写 overlay / 诊断报告）拿到的都是合并后的形状。
    final merged = _mergeLegacyKeylessLanes(providers, aliveModels, selected);

    return ConfiguredConfig(
      version: (decoded['version'] is int) ? decoded['version'] as int : 1,
      providers: merged.providers,
      models: merged.models,
      groups: groups,
      selected: selected,
    );
  }

  /// 合并遗留的 kilo/ovh 厂家（2026-11-03 三通道合并的兼容层）。
  ///
  /// 为什么写在这里而不是 `ZenChannel`：这里不能 import 它（会循环依赖），
  /// 而且这本来就该是"读配置"的事 —— 谁读都得看到同一个形状。
  /// 两个 id 是**历史常量**，与 `ZenChannel.kiloProviderId/ovhProviderId` 对应。
  static ({List<ProviderSpec> providers, List<ModelSpec> models})
      _mergeLegacyKeylessLanes(
    List<ProviderSpec> providers,
    List<ModelSpec> models,
    String? selected,
  ) {
    const zenId = 'zen';
    const legacy = <String>{'kilo', 'ovh'};
    final hasZen = providers.any((p) => p.id == zenId);
    final hasLegacy = providers.any((p) => legacy.contains(p.id));
    if (!hasZen || !hasLegacy) {
      return (providers: providers, models: models);
    }

    final outProviders = <ProviderSpec>[
      for (final p in providers)
        if (!legacy.contains(p.id)) p,
    ];
    final seen = <String>{};
    final outModels = <ModelSpec>[];
    for (final m in models) {
      if (legacy.contains(m.provider)) {
        // 并进 zen，重名只留一条（顺序维持原样，等于 zen 的优先）
        if (!seen.add(m.id)) continue;
        outModels.add(ModelSpec(
            provider: zenId, id: m.id, name: m.name, context: m.context));
      } else {
        if (m.provider == zenId) seen.add(m.id);
        outModels.add(m);
      }
    }
    debugPrint('[dsh-models] 旧数据迁移：kilo/ovh 并进 zen'
        '（厂家 ${providers.length} → ${outProviders.length}）');
    return (providers: outProviders, models: outModels);
  }

  /// v1 没有"每条模型的 provider"这个字段，只能按"唯一那个 provider"归属。
  static String _ownerFor(
    String modelId,
    List<ProviderSpec> providers,
    String? legacyProvider,
  ) {
    if (legacyProvider != null) return legacyProvider;
    // 形如 `deepseek/xxx` 的 v1.5 写法：前缀就是 provider
    final slash = modelId.indexOf('/');
    if (slash > 0) {
      final head = sanitizeProviderId(modelId.substring(0, slash));
      if (providers.any((p) => p.id == head)) return head;
    }
    return providers.isEmpty ? 'com' : providers.first.id;
  }

  // ------------------------------------------------------------ 兼容用法：写

  /// 落盘（**v1 兼容入口**）。
  ///
  /// 语义：把 `provider` 这个厂家 **upsert** 进 v2 文件，并用 `models` 替换
  /// **该厂家自己的**模型列表；其它厂家的 provider 与模型一律保留。
  ///
  /// 这样即使老的调用点（一次性配一个厂家）来写，也**不会再把别的厂家删掉**
  /// —— 这正是用户那条「设置完一个模型就无法再选其他厂家」的一半原因。
  static Future<void> save({
    required String filesDir,
    required String provider,
    required String baseUrl,
    required String selectedId,
    required List<({String id, String? name, int? context})> models,
  }) async {
    final pid = sanitizeProviderId(provider);
    final old = readConfig(filesDir);

    final providers = <ProviderSpec>[
      for (final p in old.providers)
        if (p.id != pid) p,
      ConfiguredModels.provider(id: pid, label: provider, baseUrl: baseUrl),
    ];
    final next = <ModelSpec>[
      for (final m in old.models)
        if (m.provider != pid) m,
      for (final m in models)
        if (m.id.trim().isNotEmpty)
          ModelSpec(
            provider: pid,
            id: m.id.trim(),
            name: m.name,
            context: m.context,
          ),
    ];

    await saveConfig(
      filesDir: filesDir,
      config: ConfiguredConfig(
        version: currentVersion,
        providers: providers,
        models: next,
        groups: old.groups,
        selected: '$pid/${selectedId.trim()}',
      ),
    );
  }

  /// 落盘（**v2 入口**，设置页的多厂家 + 轮换组都走这里）。
  static Future<void> saveConfig({
    required String filesDir,
    required ConfiguredConfig config,
  }) async {
    try {
      final dir = Directory(filesDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final payload = _payloadOf(config);
      // 原子写（审计 P0-9）：先写 .part 再 rename。直接 writeAsString 是先截断
      // 再写，进程在中间被杀就留半份 JSON —— 而"半份"正是上面那条丢数据链的起点。
      await writeStringAtomic(fileOf(filesDir), jsonEncode(payload));
      // 写成功了 → 之前那次"读坏了"的状态不再成立。
      lastReadError = null;
      debugPrint(
        '[dsh-models] models.json v2 已写入：${config.providers.length} 个厂家 / '
        '${config.models.length} 个模型 / ${config.groups.length} 个轮换组，'
        'selected=${config.selected ?? '-'}',
      );
    } catch (e) {
      debugPrint('[dsh-models] 写 models.json 失败: $e');
    }
  }

  /// **同步**版保存。给"必须在 `initState` 里立刻落盘"的迁移用（见 `_reload` 里
  /// 那次「把本机模型移出轮换池」）。
  ///
  /// 为什么不能用 [saveConfig]：`await writeAsString(...)` 那条链**绑在发起它的
  /// 那个 zone 上**。`initState` 里发起的异步写在真机上没问题，但 `flutter test`
  /// 的 fake-async 区里那个 await **永不返回**（同文件 `model_panel_flow_test.dart`
  /// 里「测试并保存」那条注释记的是同一件事）。结果是：迁移在测试里静默不执行，
  /// 只有真机上才生效 —— 那正是"测试全绿、用户说没改"的来源。
  /// `models.json` 只有几 KB，同步写一次的开销可以忽略。
  static void saveConfigSync({
    required String filesDir,
    required ConfiguredConfig config,
  }) {
    try {
      final dir = Directory(filesDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      writeStringAtomicSync(fileOf(filesDir), jsonEncode(_payloadOf(config)));
      lastReadError = null;
      debugPrint(
        '[dsh-models] models.json v2 已写入（同步）：'
        '${config.providers.length} 个厂家 / ${config.models.length} 个模型 / '
        '${config.groups.length} 个轮换组，selected=${config.selected ?? '-'}',
      );
    } catch (e) {
      debugPrint('[dsh-models] 同步写 models.json 失败: $e');
    }
  }

  /// 落盘用的 JSON 正文 —— [saveConfig] 与 [saveConfigSync] **必须完全一致**，
  /// 所以只在这里拼一次。以前这段内联在 `saveConfig` 里，加同步版时抄一份就等着
  /// 两边慢慢跑偏（字段少一个 → 用户的模型配置被静默截断）。
  static Map<String, dynamic> _payloadOf(ConfiguredConfig config) =>
      <String, dynamic>{
        'version': currentVersion,
        if ((config.selected ?? '').trim().isNotEmpty)
          'selected': config.selected!.trim(),
        'updatedAt': DateTime.now().toIso8601String(),
        'providers': <Map<String, dynamic>>[
          for (final p in config.providers)
            <String, dynamic>{
              'id': p.id,
              if (p.label.trim().isNotEmpty) 'label': p.label.trim(),
              'baseUrl': p.baseUrl,
              'api': p.api,
              'apiKeyEnv': p.apiKeyEnv,
            },
        ],
        'models': <Map<String, dynamic>>[
          for (final m in config.models)
            <String, dynamic>{
              'provider': m.provider,
              'id': m.id,
              if ((m.name ?? '').trim().isNotEmpty) 'name': m.name!.trim(),
              if (m.context != null && m.context! > 0) 'context': m.context,
            },
        ],
        'groups': <Map<String, dynamic>>[
          for (final g in config.groups)
            <String, dynamic>{'name': g.name, 'members': g.members},
        ],
      };
}

/// 一个厂家端点。
class ProviderSpec {
  const ProviderSpec({
    required this.id,
    required this.label,
    required this.baseUrl,
    this.api = 'openai-completions',
    required this.apiKeyEnv,
  });

  /// 路由键：overlay 里 `providers.<id>`，也是 route 的前缀。
  final String id;

  /// 界面上显示的厂家名（用户自己填的，例如「DeepSeek」「通义千问」）。
  final String label;

  final String baseUrl;

  /// DSH 侧的协议实现，默认 `openai-completions`。
  final String api;

  /// 凭据所在的环境变量名（**不是 Key 本身**）。
  final String apiKeyEnv;

  ProviderSpec copyWith({
    String? label,
    String? baseUrl,
    String? api,
    String? apiKeyEnv,
  }) =>
      ProviderSpec(
        id: id,
        label: label ?? this.label,
        baseUrl: baseUrl ?? this.baseUrl,
        api: api ?? this.api,
        apiKeyEnv: apiKeyEnv ?? this.apiKeyEnv,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'baseUrl': baseUrl,
        'api': api,
        'apiKeyEnv': apiKeyEnv,
      };
}

/// 一条真实存在的模型（属于某个厂家）。
class ModelSpec {
  const ModelSpec({
    required this.provider,
    required this.id,
    this.name,
    this.context,
  });

  final String provider;

  /// 发给上游的 model id（**不含** provider 前缀）。
  final String id;

  final String? name;
  final int? context;

  /// 全限定标识：`<provider>/<model>`。
  String get route => '$provider/$id';

  String get displayName =>
      (name != null && name!.trim().isNotEmpty) ? name!.trim() : id;

  ModelSpec copyWith({String? provider, String? name, int? context}) =>
      ModelSpec(
        provider: provider ?? this.provider,
        id: id,
        name: name ?? this.name,
        context: context ?? this.context,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'provider': provider,
        'id': id,
        if ((name ?? '').trim().isNotEmpty) 'name': name!.trim(),
        if (context != null && context! > 0) 'context': context,
      };
}

/// 一个「轮换组」：名字 + 有序成员（成员是 ModelSpec.route）。
class RotationGroupSpec {
  const RotationGroupSpec({required this.name, required this.members});

  final String name;
  final List<String> members;

  /// 组在界面/overlay 里的 route（provider 固定是 `rotate`）。
  String get route => '${ConfiguredModels.rotateProviderId}/$name';

  RotationGroupSpec copyWith({String? name, List<String>? members}) =>
      RotationGroupSpec(
          name: name ?? this.name, members: members ?? this.members);

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'name': name, 'members': members};
}

/// 界面上**可被用户选中**的一项：普通模型或轮换组。
///
/// 模型面板只需要这个 —— 组和模型是同一种东西，用户不用理解区别。
class ModelChoice {
  const ModelChoice({
    required this.route,
    required this.name,
    required this.description,
    this.isGroup = false,
    this.memberCount = 0,
  });

  final String route;
  final String name;
  final String description;
  final bool isGroup;
  final int memberCount;
}

/// models.json 的完整内容。
class ConfiguredConfig {
  const ConfiguredConfig({
    required this.version,
    required this.providers,
    required this.models,
    required this.groups,
    required this.selected,
  });

  static const ConfiguredConfig empty = ConfiguredConfig(
    version: ConfiguredModels.currentVersion,
    providers: <ProviderSpec>[],
    models: <ModelSpec>[],
    groups: <RotationGroupSpec>[],
    selected: null,
  );

  final int version;
  final List<ProviderSpec> providers;
  final List<ModelSpec> models;
  final List<RotationGroupSpec> groups;

  /// 选中项的全限定 route（`deepseek/xxx` 或 `rotate/cat`）。
  final String? selected;

  bool get isEmpty => providers.isEmpty && models.isEmpty && groups.isEmpty;

  ProviderSpec? providerOf(String id) =>
      _firstOrNull(providers, (p) => p.id == id);

  ModelSpec? modelOfRoute(String route) =>
      _firstOrNull(models, (m) => m.route == route);

  RotationGroupSpec? groupOfRoute(String route) =>
      _firstOrNull(groups, (g) => g.route == route);

  /// 界面上可选的全部项：普通模型在前，轮换组在后。
  List<ModelChoice> get choices => <ModelChoice>[
        for (final m in models)
          ModelChoice(
            route: m.route,
            name: m.displayName,
            description: m.context == null || m.context! <= 0
                ? '${m.provider} · ${m.id}'
                : '${m.provider} · ${m.id} · ${_contextLabel(m.context!)}',
          ),
        for (final g in groups)
          ModelChoice(
            route: g.route,
            name: g.name,
            description: tr('轮换组 · {0} 个模型', [g.members.length]),
            isGroup: true,
            memberCount: g.members.length,
          ),
      ];

  static String _contextLabel(int context) {
    if (context >= 1000000) return '${(context / 1000000).toStringAsFixed(1)}M';
    if (context >= 1000) return '${(context / 1000).round()}K';
    return '$context';
  }

  ConfiguredConfig copyWith({
    List<ProviderSpec>? providers,
    List<ModelSpec>? models,
    List<RotationGroupSpec>? groups,
    String? selected,
    bool clearSelected = false,
  }) =>
      ConfiguredConfig(
        version: ConfiguredModels.currentVersion,
        providers: providers ?? this.providers,
        models: models ?? this.models,
        groups: groups ?? this.groups,
        selected: clearSelected ? null : (selected ?? this.selected),
      );
}

/// `firstWhere` 的"找不到就返回 null"版本。
///
/// 刻意不用 `package:collection` 的扩展（少一个依赖），也不用 `firstOrNull`
/// （那是 SDK 较新版本才有的成员，这里不赌版本）。
T? _firstOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}
