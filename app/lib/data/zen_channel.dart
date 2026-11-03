import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../i18n/dsh_i18n.dart';
import '../local/dsh_runtime.dart';
import '../local/zen_proxy.dart';
import 'configured_models.dart';

/// 「社区免费通道（实验）」的**开关逻辑**。
///
/// ## 它到底做了什么（一句话，别在界面里含糊）
///
/// 起一个**本地代理**（`assets/toolbox/zen-proxy.mjs`），由它把请求按
/// **官方 CLI 的形状**转发到 OpenCode Zen 的匿名免费额度，然后把拿到的免费模型
/// 写进本机的模型配置 —— 于是"设置里打开开关 → 模型选择器里出现一批免费模型"。
///
/// ⚠️ 上游的免费层**只允许它自家 CLI 用**（非官方形状会被 403 拒），所以这属于
/// **绕过一个有意设置的访问限制**。因此在本 App 里的定位被刻意收窄为：
///   * 默认关闭、必须用户显式打开（[AppSettings.zenEnabled]）；
///   * 界面**如实标注**：随时可能失效、不承诺稳定性，并且**不需要用户填任何 Key**
///     （这条通道本来就是匿名的，上游凭据是公开的 `public` —— 别催用户去配
///     一个自己的 Key，那与它的事实不符，2026-10-11 用户纠正过）；
///   * **不做** IP 轮换 / 重试轰炸（不实现任何"放大器"）。
///
/// ## 端口每次都会变
///
/// 代理监听的是系统分配的随机端口（`--port 0`），所以**每次启动都要把
/// `baseUrl` 重新写一遍** —— 否则配置里还指着上次那个已经不存在的端口，
/// 表现就是"打开了开关但所有模型都连不上"。见 [refresh]。
class ZenChannel {
  ZenChannel._();

  /// 写进模型配置里的厂家 id（`providers.zen`，也是 route 前缀）。
  static const String providerId = 'zen';

  /// **第二条免密上游**（Kilo AI 公共网关）的厂家 id。
  ///
  /// 为什么单独建一个厂家而不是塞进 zen：两条上游的模型 id 会撞（都有
  /// `xxx:free` 这种形状），分厂家走就是两条独立的 baseUrl，天然不冲突；
  /// 用户也能一眼看出某个模型来自哪条通道。
  static const String kiloProviderId = 'kilo';

  /// **第三条免密上游**（OVHcloud AI Endpoints）的厂家 id。
  ///
  /// 它和 Kilo 一样是纯免 Key、免伪装的 OpenAI 兼容公共端点；区别只在
  /// OVHcloud 的 `/models` 没有 `isFree` 标记，整表即免费池（2026-11-01 实测 22 个）。
  static const String ovhProviderId = 'ovh';

  /// Kilo 那条在界面上显示的名字。
  ///
  /// 用户 2026-11-01：改名为「第三方免key通道」—— 因为会话选择器里 zen 与 polli
  /// 都叫「免费模型」，用户分不清哪个是哪个。zen 是**第三方社区通道**（随时可能
  /// 失效），polli 是**默认承诺的那条**，名字必须区分开。
  /// ⚠️ 2026-11-03 起**三条上游合并成一个厂家**（用户：「会话页面模型选择会出现
  /// 三个第三方免key通道，把他们合并」），所以这两个"· Kilo / · OVHcloud"后缀
  /// 不再出现在界面上 —— 保留常量只是为了兼容旧配置的迁移判断。
  static String get kiloLabel => tr('免Key通道');

  /// 同上（合并后不再单独显示）。
  static String get ovhLabel => tr('免Key通道');

  /// 这个厂家用的环境变量名（占位值由 `ProviderKeys.envFor` 注入）。
  static const String apiKeyEnv = 'ZEN_API_KEY';

  /// 界面上显示的名字。
  ///
  /// 沿革：2026-10-31 从「免费模型」改成「第三方免key通道」（要和 polli 区分开）；
  /// 2026-11-03 用户反馈「文本表述太乱了，简明扼要」→ 精简成 **「免Key通道」**。
  ///
  /// 四条命名规则（一次说清，别再改乱）：
  ///   * `免Key通道` —— 这个（Zen/Kilo/OVH 三条上游，合并成一个厂家）
  ///   * `免费模型（无需 Key）` —— polli（默认承诺那条，必须能开箱即用）
  ///   * 会话选择器里只出现**一个**「免Key通道」，不再有 ·Kilo/·OVHcloud 后缀
  static String get label => tr('免Key通道');

  /// 开启（或在启动时刷新）：起代理、取模型、**逐个测哪些此刻真能用**、写配置。
  ///
  /// 返回 `models` = 写进去的（能用的）模型数；`tested` = 一共测了几个；
  /// `alive` = 其中能用的几个。失败时 `error` 是给用户看的中文。
  ///
  /// 为什么要测（用户 2026-10-31）：上游 `/models` 列表里常有**已退役/被限流**的
  /// 模型 —— 列表有它、真发对话却报错。所以只留 ping 通的，别给用户一个选了就坏的。
  static Future<({bool ok, String? error, int models, int tested, int alive})>
      enable({
    required DshRuntime runtime,
  }) async {
    final port = await ZenProxy.instance.ensureRunning(runtime: runtime);
    if (port == null) {
      return (
        ok: false,
        error: tr('本地代理没能启动起来（详见运行日志）。'),
        models: 0,
        tested: 0,
        alive: 0,
      );
    }
    // 三条上游逐条取模型：**一条挂了不能拖垮别的** ——
    // 拿不到就当空列表，这次不写那个厂家，下一轮刷新再试。
    final models = await ZenProxy.instance.fetchFreeModels(port);
    final kiloModels =
        await ZenProxy.instance.fetchFreeModels(port, lane: ZenLane.kilo);
    final ovhModels =
        await ZenProxy.instance.fetchFreeModels(port, lane: ZenLane.ovh);
    if (models.isEmpty && kiloModels.isEmpty && ovhModels.isEmpty) {
      return (
        ok: false,
        error: tr('连上了代理，但三条通道都没取到免费模型 —— 上游可能暂时不可用。'),
        models: 0,
        tested: 0,
        alive: 0,
      );
    }

    // ── 逐个测：只留此刻真能对话的（用户 2026-10-31「ping 不通不列」）──
    final zenPing = await ZenProxy.instance.pingModels(port, models);
    final kiloPing =
        await ZenProxy.instance.pingModels(port, kiloModels, lane: ZenLane.kilo);
    final ovhPing =
        await ZenProxy.instance.pingModels(port, ovhModels, lane: ZenLane.ovh);
    final aliveZen = zenPing.alive;
    final aliveKilo = kiloPing.alive;
    final aliveOvh = ovhPing.alive;
    final tested = zenPing.tested + kiloPing.tested + ovhPing.tested;
    final alive = aliveZen.length + aliveKilo.length + aliveOvh.length;

    if (alive == 0) {
      // 一个都测不通 —— 不写配置（写了也是选了就报错），如实告诉用户。
      return (
        ok: false,
        error: tested > 0
            ? tr('测了 {0} 个模型，这会儿一个都连不上 —— 上游可能暂时限流或不可用。',
                <Object?>['$tested'])
            : tr('连上了代理，但三条通道都没取到免费模型 —— 上游可能暂时不可用。'),
        models: 0,
        tested: tested,
        alive: 0,
      );
    }

    try {
      final cfg = ConfiguredModels.readConfig(runtime.filesDir);
      await ConfiguredModels.saveConfig(
        filesDir: runtime.filesDir,
        config: _withZen(
          cfg,
          port: port,
          models: aliveZen,
          kiloModels: aliveKilo,
          ovhModels: aliveOvh,
        ),
      );
      // 把这次探活的结果落盘：下次启动直接用，不必再等一遍
      _writeAliveCache(runtime,
          zen: aliveZen, kilo: aliveKilo, ovh: aliveOvh);
      debugPrint('[dsh-zen] ping $tested 个 → $alive 个可用，已写入'
          '（zen ${aliveZen.length} / kilo ${aliveKilo.length} / ovh ${aliveOvh.length}，'
          '端口 $port）');
      return (
        ok: true,
        error: null,
        models: alive,
        tested: tested,
        alive: alive,
      );
    } catch (e) {
      debugPrint('[dsh-zen] 写配置失败：$e');
      return (
        ok: false,
        error: tr('写模型配置失败：{0}', <Object?>['$e']),
        models: 0,
        tested: tested,
        alive: alive,
      );
    }
  }

  /// 关闭：把厂家与它的模型从配置里摘掉，并停掉代理。
  ///
  /// ⚠️ **只摘自己那部分**：用户自己的厂家、模型、轮换池一个都不能动。
  static Future<void> disable({required DshRuntime runtime}) async {
    try {
      final cfg = ConfiguredModels.readConfig(runtime.filesDir);
      bool mineProvider(ProviderSpec p) =>
          p.id == providerId ||
          p.id == kiloProviderId ||
          p.id == ovhProviderId;
      bool mineModel(ModelSpec m) =>
          m.provider == providerId ||
          m.provider == kiloProviderId ||
          m.provider == ovhProviderId;
      if (cfg.providers.any(mineProvider) || cfg.models.any(mineModel)) {
        await ConfiguredModels.saveConfig(
          filesDir: runtime.filesDir,
          config: ConfiguredConfig(
            version: cfg.version,
            providers: <ProviderSpec>[
              for (final p in cfg.providers)
                if (!mineProvider(p)) p,
            ],
            models: <ModelSpec>[
              for (final m in cfg.models)
                if (!mineModel(m)) m,
            ],
            groups: cfg.groups,
            // 选中的如果正好是免费通道的模型，退回"没选"（让界面自己挑一个），
            // 而不是留一个已经不存在的 route。
            selected: ((cfg.selected ?? '').startsWith('$providerId/') ||
                    (cfg.selected ?? '').startsWith('$kiloProviderId/') ||
                    (cfg.selected ?? '').startsWith('$ovhProviderId/'))
                ? null
                : cfg.selected,
          ),
        );
      }
    } catch (e) {
      debugPrint('[dsh-zen] 关闭时清理配置失败（不影响停代理）：$e');
    }
    await ZenProxy.instance.stop();
  }

  /// 启动时调用：若开关是开的，就把端口与模型列表刷新一遍。
  ///
  /// 为什么每次启动都要刷：端口是系统随机分配的（见类注释），配置里那份
  /// 昨天的 `baseUrl` 今天一定是错的。
  /// 上次探活通过的模型清单（落盘缓存）。
  ///
  /// ## 为什么要有它（2026-11-03 真机反馈「这一版初始化特别慢」）
  ///
  /// 启动流程里 `refreshIfEnabled` 是 **await** 的，而它内部要把三条通道的
  /// 模型逐个探活。0.81 只有 OpenCode 一条（约 22 个），这版接了 Kilo 和
  /// OVHcloud 之后变成 **48 个** —— 要测的数量翻倍，启动就被拖长了。
  ///
  /// 现在的做法：**先用上次的结果把配置写出来**（毫秒级），探活丢到后台跑，
  /// 跑完再更新一次。这样既不用让用户盯着加载页等，也仍然守「只列能用的」规矩。
  static File _aliveCacheFile(DshRuntime runtime) =>
      File('${runtime.filesDir}/zen-alive.json');

  static ({List<String> zen, List<String> kilo, List<String> ovh, int at})?
      _readAliveCache(DshRuntime runtime) {
    try {
      final f = _aliveCacheFile(runtime);
      if (!f.existsSync()) return null;
      final m = jsonDecode(f.readAsStringSync());
      if (m is! Map) return null;
      List<String> ls(Object? v) => (v is List)
          ? v.whereType<String>().toList(growable: false)
          : const <String>[];
      return (
        zen: ls(m['zen']),
        kilo: ls(m['kilo']),
        ovh: ls(m['ovh']),
        at: (m['at'] is num) ? (m['at'] as num).toInt() : 0,
      );
    } catch (_) {
      return null;
    }
  }

  static void _writeAliveCache(
    DshRuntime runtime, {
    required List<String> zen,
    required List<String> kilo,
    required List<String> ovh,
  }) {
    try {
      _aliveCacheFile(runtime).writeAsStringSync(jsonEncode(<String, Object?>{
        'at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'zen': zen,
        'kilo': kilo,
        'ovh': ovh,
      }));
    } catch (e) {
      debugPrint('[dsh-zen] 写探活缓存失败（不影响功能）: $e');
    }
  }

  static Future<void> refreshIfEnabled({
    required bool enabled,
    required DshRuntime runtime,
  }) async {
    if (!enabled) {
      // 开关关着但配置里还留着上次的痕迹（比如用户在别处改过配置）→ 清掉。
      await disable(runtime: runtime);
      return;
    }

    // ── 快速路径：上次探活过就直接用它写配置，不等这轮探活 ──────────
    //
    // 缓存超过 24 小时就不用（免费通道变动很快，太旧的清单里可能大半都挂了）。
    final cached = _readAliveCache(runtime);
    if (cached != null) {
      final ageSec = DateTime.now().millisecondsSinceEpoch ~/ 1000 - cached.at;
      final alive = cached.zen.length + cached.kilo.length + cached.ovh.length;
      if (ageSec < 24 * 3600 && alive > 0) {
        final port = await ZenProxy.instance.ensureRunning(runtime: runtime);
        if (port != null) {
          try {
            final cfg = ConfiguredModels.readConfig(runtime.filesDir);
            await ConfiguredModels.saveConfig(
              filesDir: runtime.filesDir,
              config: _withZen(
                cfg,
                port: port,
                models: cached.zen,
                kiloModels: cached.kilo,
                ovhModels: cached.ovh,
              ),
            );
            debugPrint('[dsh-zen] 启动走缓存快速路径：$alive 个模型'
                '（缓存 ${ageSec ~/ 60} 分钟前），探活已转后台');
            // 后台重探，跑完再更新一次配置（不阻塞启动）
            unawaited(enable(runtime: runtime));
            return;
          } catch (e) {
            debugPrint('[dsh-zen] 快速路径写配置失败，退回完整流程: $e');
          }
        }
      }
    }

    // ── 常规路径：没有可用缓存时才同步探活 ──
    final r = await enable(runtime: runtime);
    if (r.ok) return;
    // ⚠️ 刷新失败就把免费模型**从配置里摘掉**，而不是留着指向一个已经失效的本地端口
    // —— 留着的话用户会在模型列表里看到一批"选了就报错"的模型，比"暂时没有它"更糟。
    debugPrint('[dsh-zen] 启动刷新失败（先把免费模型摘掉）：${r.error}');
    _lastRefreshError = r.error;
    await disable(runtime: runtime);
  }

  /// 上一次启动刷新的失败原因（设置页显示用；进程内有效）。
  static String? _lastRefreshError;
  static String? get lastRefreshError => _lastRefreshError;

  /// 清楚记录/清除上次错误（用户在设置页手动重试成功时调用）。
  static void clearRefreshError() => _lastRefreshError = null;

  /// 现在通不通（设置页显示状态用）。
  static Future<({bool running, int? port, int models, String? lastError})> status() async {
    final port = ZenProxy.instance.port;
    if (port == null) {
      return (running: false, port: null, models: 0, lastError: null);
    }
    final h = await ZenProxy.instance.health(port);
    return (
      running: true,
      port: port,
      models: h?.models ?? 0,
      lastError: h?.lastError,
    );
  }

  static ConfiguredConfig _withZen(
    ConfiguredConfig cfg, {
    required int port,
    required List<String> models,
    /// 第二条上游（Kilo）的免费模型。空 = 那条当前不可用，**不写这个厂家**
    /// —— 写一个空厂家只会让用户在选择器里看到一条点不开的分组。
    List<String> kiloModels = const <String>[],
    /// 第三条上游（OVHcloud）的免费模型。同样空 = 不写这个厂家。
    List<String> ovhModels = const <String>[],
  }) {
    return ConfiguredConfig(
      version: cfg.version,
      providers: <ProviderSpec>[
        // 先摘掉旧的自己（三条都要摘：端口变了要覆盖），再追加新的
        for (final p in cfg.providers)
          if (p.id != providerId &&
              p.id != kiloProviderId &&
              p.id != ovhProviderId)
            p,
        ProviderSpec(
          id: providerId,
          label: label,
          baseUrl: 'http://127.0.0.1:$port/v1',
          apiKeyEnv: apiKeyEnv,
        ),
        // 2026-11-03：**三条上游合并成一个厂家**（用户：「会话页面模型选择会出现
        // 三个第三方免key通道，把他们合并」）。
        //
        // 合并后只剩上面这一个 provider（baseURL 挂 `/v1`）。请求该发去哪条上游
        // 由代理**按模型名自动判断**（zen-proxy.mjs 的 laneOfModel），
        // 所以不再需要 /kilo/v1、/ovh/v1 这两条路径。
      ],
      models: <ModelSpec>[
        for (final m in cfg.models)
          if (m.provider != providerId &&
              m.provider != kiloProviderId &&
              m.provider != ovhProviderId)
            m,
        // 三批模型全挂在**同一个** provider 下（去重、保序 Zen→Kilo→OVH，
        // 与代理 laneOfModel 的判断顺序一致）。
        ...mergedModelSpecs(providerId, <String>[
          ...models,
          ...kiloModels,
          ...ovhModels,
        ]),
      ],
      groups: cfg.groups,
      selected: cfg.selected,
    );
  }
}

/// 把多条上游的模型名合并成一串 ModelSpec（**去重、保序**）。
///
/// 为什么单独拎出来：这段有"顺序即优先级"的含义（先出现的赢），
/// 写在 `_withZen` 里没法测。独立出来就能用测试钉死"重名只出现一次"。
///
/// 去重是必需的：同一模型名可能两条上游都有（都是同类开源模型），
/// 重复会让会话选择器里出现两条一模一样的条目。
@visibleForTesting
List<ModelSpec> mergedModelSpecs(String provider, List<String> ids) {
  final seen = <String>{};
  final out = <ModelSpec>[];
  for (final id in ids) {
    if (id.isEmpty || !seen.add(id)) continue;
    out.add(ModelSpec(provider: provider, id: id, name: id));
  }
  return out;
}

/// 让"是否已写入配置"这类判断可以离线测试（不碰进程/网络）。
bool zenConfiguredIn(ConfiguredConfig cfg) =>
    cfg.providers.any((p) =>
        p.id == ZenChannel.providerId ||
        p.id == ZenChannel.kiloProviderId ||
        p.id == ZenChannel.ovhProviderId);

/// 仅供测试：暴露"把 zen 写进配置"的纯函数（不启动任何进程）。
ConfiguredConfig zenConfigForTest(
  ConfiguredConfig cfg, {
  required int port,
  required List<String> models,
  List<String> kiloModels = const <String>[],
  List<String> ovhModels = const <String>[],
}) =>
    ZenChannel._withZen(
      cfg,
      port: port,
      models: models,
      kiloModels: kiloModels,
      ovhModels: ovhModels,
    );

/// 某条 route 是不是"社区免费通道"的（界面据此加标注）。
bool isZenRoute(String? route) =>
    (route ?? '').startsWith('${ZenChannel.providerId}/') ||
    (route ?? '').startsWith('${ZenChannel.kiloProviderId}/') ||
    (route ?? '').startsWith('${ZenChannel.ovhProviderId}/');
