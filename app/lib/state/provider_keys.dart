import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/configured_models.dart';
import '../local/local_model_spec.dart';

/// **每个厂家各自的 API Key**，只存系统安全区（Android Keystore）。
///
/// 为什么单独一个文件：v1 时代整个 App 只有一个 Key（`dsh_model_api_key`），
/// 配第二个厂家就等于把第一个覆盖掉。v2 要多厂家并存，Key 必须按厂家分开存，
/// 而且**绝不进 `models.json`**（那是明文文件）。
///
/// 老用户的迁移在这里做：如果该厂家没有自己的 Key，但存在旧的
/// `dsh_model_api_key`，且旧的 `dsh_model_provider` 就是它（或旧记录缺失），
/// 就把旧 Key 复制一份到新键名下 —— 这样升级上来的用户不会突然"凭据没了"。
class ProviderKeys {
  ProviderKeys._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// v1 的单 Key 键名（保留，只用于迁移和向后兼容）。
  static const String legacyApiKeyKey = 'dsh_model_api_key';
  static const String legacyProviderKey = 'dsh_model_provider';

  static String secureKeyFor(String providerId) =>
      'dsh_provider_key_${ConfiguredModels.sanitizeProviderId(providerId)}';

  static Future<String?> read(String providerId) async {
    final key = secureKeyFor(providerId);
    try {
      final own = await _secure.read(key: key);
      if (own != null && own.trim().isNotEmpty) return own.trim();
    } catch (e) {
      debugPrint('[dsh-keys] 读 $key 失败: $e');
    }

    // 一次性迁移：老用户只有 legacy 那把 Key。
    try {
      final legacy = await _secure.read(key: legacyApiKeyKey);
      if (legacy == null || legacy.trim().isEmpty) return null;
      final legacyProvider = await _secure.read(key: legacyProviderKey);
      final sameProvider = legacyProvider == null ||
          legacyProvider.trim().isEmpty ||
          ConfiguredModels.sanitizeProviderId(legacyProvider) ==
              ConfiguredModels.sanitizeProviderId(providerId);
      if (!sameProvider) return null;
      await _secure.write(key: key, value: legacy.trim());
      debugPrint('[dsh-keys] 已把旧 Key 迁移到 $key');
      return legacy.trim();
    } catch (e) {
      debugPrint('[dsh-keys] 迁移旧 Key 失败: $e');
      return null;
    }
  }

  static Future<void> write(String providerId, String apiKey) async {
    try {
      final key = secureKeyFor(providerId);
      final v = apiKey.trim();
      if (v.isEmpty) {
        await _secure.delete(key: key);
        return;
      }
      await _secure.write(key: key, value: v);
    } catch (e) {
      debugPrint('[dsh-keys] 写 Key 失败: $e');
    }
  }

  static Future<void> delete(String providerId) async {
    try {
      await _secure.delete(key: secureKeyFor(providerId));
    } catch (e) {
      debugPrint('[dsh-keys] 删 Key 失败: $e');
    }
  }

  // ─────────────────────────────────────────────── 备用 Key（多账号）
  //
  // ## 为什么需要它（用户 2026-10-11 反馈：Agnes 生图/生视频经常 429 或排队）
  //
  // 限流/额度是**按账号**算的 —— 同一个账号下多建几把 Key **共享同一份配额**，
  // 加多少都没用。**只有不同账号的多把 Key 才能真正加容量**，
  // 于是被限流时能立刻换另一把继续（见 assets/toolbox/agnes-retry.mjs）。
  //
  // 所以这里存的是"**另一把（另一个账号的）Key**"，界面上要说清这一点，
  // 免得用户以为"同一账号多建几把"有用。
  //
  // 主 Key 仍然走 [secureKeyFor]（第一把），备用走下面这个键 —— 这样老用户的
  // 单 Key 行为完全不变，也不用迁移。

  static String extraSecureKeyFor(String providerId) =>
      '${secureKeyFor(providerId)}_extra';

  /// 读备用 Key 列表（文件里是 JSON 数组；坏数据按空处理，绝不因此抛异常）。
  static Future<List<String>> readExtras(String providerId) async {
    try {
      final raw = await _secure.read(key: extraSecureKeyFor(providerId));
      if (raw == null || raw.trim().isEmpty) return <String>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>[];
      final out = <String>[];
      for (final e in decoded) {
        if (e is String && e.trim().isNotEmpty && !out.contains(e.trim())) {
          out.add(e.trim());
        }
      }
      return out;
    } catch (e) {
      debugPrint('[dsh-keys] 读备用 Key 失败（按空处理）: $e');
      return <String>[];
    }
  }

  static Future<void> writeExtras(String providerId, List<String> keys) async {
    try {
      final key = extraSecureKeyFor(providerId);
      final clean = <String>[];
      for (final k in keys) {
        final v = k.trim();
        if (v.isNotEmpty && !clean.contains(v)) clean.add(v);
      }
      if (clean.isEmpty) {
        await _secure.delete(key: key);
        return;
      }
      await _secure.write(key: key, value: jsonEncode(clean));
    } catch (e) {
      debugPrint('[dsh-keys] 写备用 Key 失败: $e');
    }
  }

  /// 追加一把备用 Key；返回 `null` 表示成功，否则是**错误码**。
  ///
  /// ⚠️ 这里刻意返回**码**（`empty` / `is-primary` / `duplicate`）而不是中文句子：
  /// 本文件在 i18n 扫描器的 `SKIP_FILES` 里（当初被当成"只有内部日志的文件"跳过了），
  /// 所以**写在这里的文案不会被翻译门禁检查** —— 英文界面会直接露中文。
  /// 交给界面（`model_settings_panel.dart`，会被扫描）去出文案。
  static Future<String?> addExtra(String providerId, String key) async {
    final v = key.trim();
    if (v.isEmpty) return 'empty';
    final primary = await read(providerId);
    if (primary != null && primary == v) return 'is-primary';
    final list = await readExtras(providerId);
    if (list.contains(v)) return 'duplicate';
    list.add(v);
    await writeExtras(providerId, list);
    return null;
  }

  static Future<void> removeExtra(String providerId, int index) async {
    final list = await readExtras(providerId);
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    await writeExtras(providerId, list);
  }

  /// **全部 Key，主 Key 在第一位**（生图/生视频脚本按这个顺序轮换）。
  ///
  /// 主 Key 为空（用户只填了备用、没填主）时，备用整体上移 —— 这样
  /// "只填了一把备用" 也能正常工作，而不是变成"没有 Key"。
  static Future<List<String>> readAll(String providerId) async {
    final primary = await read(providerId);
    final out = <String>[];
    if (primary != null && primary.trim().isNotEmpty) out.add(primary.trim());
    for (final k in await readExtras(providerId)) {
      if (!out.contains(k)) out.add(k);
    }
    return out;
  }

  /// 把配置里每个厂家的 Key 读出来，整理成 **环境变量名 → Key**，
  /// 交给 [DshRuntime] 注入 node 进程（overlay 里用 `apiKeyEnv` 引用变量名，
  /// 这样凭据不会出现在命令行/进程列表里）。
  static Future<Map<String, String>> envFor(ConfiguredConfig cfg) async {
    final env = <String, String>{};
    for (final p in cfg.providers) {
      final k = await read(p.id);
      if (k == null || k.isEmpty) continue;
      env[p.apiKeyEnv] = k;
      // ⚠️ **opencode-go 要额外注入 `OPENCODE_API_KEY`**（2026-10-17 真机回归的根因）。
      //
      // 原因：这个厂家的 overlay **故意不写 api/baseURL**（写了会丢 `x-opencode-session` 头），
      // 于是 DSH 用它**内置**的 provider —— 而内置 provider 的 auth 把变量名**硬编码**成
      // `OPENCODE_API_KEY`（见 pi-ai 的 providers/opencode-go.js：
      //   `auth: { apiKey: envApiKeyAuth("OpenCode API key", ["OPENCODE_API_KEY"]) }`）。
      // App 自己那套命名（如 OPENCODE_GO_API_KEY）它**读不到** → 拿不到 Key →
      // ACP `initialize` 成功、但 `session/new` / `session/resume` 全报 Internal error、
      // 进程随即退出（真机日志就是这串现象）。
      // 所以这里两个名字都给：App 自己的（给自定义路径）+ 内置那个（给内置 provider）。
      // opencode 与 opencode-go 都走 DSH 内置 provider，而内置 provider 的 auth
      // 把变量名硬编码成 OPENCODE_API_KEY（pi-ai 两个 provider 都是这么写的）。
      if (p.id == 'opencode-go' || p.id == 'opencode') {
        env['OPENCODE_API_KEY'] = k;
      }
    }
    // 向后兼容：老 overlay / 老调用点还在用这几个固定变量名。
    final primary = cfg.providers.isEmpty ? null : cfg.providers.first;
    if (primary != null) {
      final k = await read(primary.id);
      if (k != null && k.isNotEmpty) {
        env['COM_API_KEY'] = k;
        env['DEEPSEEK_API_KEY'] = k;
        env['OPENAI_API_KEY'] = k;
      }
    }
    // 轮换组那个本地代理：DSH 还是会带一个 Authorization 头，
    // 代理自己会用真正的上游 Key，所以这里给个占位值就行。
    env['ROTATE_API_KEY'] = 'local-rotate';

    // 「免费模型（无需 Key）」的本地代理也不需要真 Key（上游那条是匿名通道，
    // 凭据是公开的字面量 `public`，由本地代理自己带上）。给个占位值，让 overlay 里
    // 那个 provider 能通过 DSH 的"这家有没有凭据"检查 —— 与 ROTATE_API_KEY 同理。
    // ⚠️ 这个占位值**不会**被转发到上游（zen-proxy.mjs 用 `Bearer public` 覆盖它）。
    env['ZEN_API_KEY'] = 'local-zen';

    // **Pollinations（免 Key 通道）**同理，而且它比 zen 更"真的不用 Key"：
    // 上游的匿名层本来就不看这个头（实测带不带、带什么都 200）。
    // 这里给占位值只是为了让 overlay 里那个 provider 过 DSH 的凭据检查 ——
    // 见 data/polli_channel.dart 的类注释。
    env['POLLI_API_KEY'] = 'local-polli';

    // **端侧模型（`local`）同理，而且这里原先漏了 —— 那是个真 bug。**
    //
    // overlay 里给 `local` 厂家写了 `apiKeyEnv: LOCAL_MODEL_API_KEY`，但从来没人
    // 给这个环境变量赋值，于是 DSH 直接拒调（真机实测原文：
    // `llm-pi-ai: no credential for provider route "local"`）——
    // 用户看到的是"这个模型属于 local，但那一家的 API Key 还没配置"，
    // 明明本地服务已经跑起来了却用不了。
    //
    // 本机 llama.cpp 根本不校验 Key，所以给个占位值就够（与 ROTATE_API_KEY 同理）。
    env[LocalModelSpec.apiKeyEnvName] = LocalModelSpec.apiKeyPlaceholder;

    // 内置的 Agnes（免费生图 / 生视频）：**不管用户有没有把它配成一个"模型"**，
    // 只要存过 Key 就注入 —— 因为 make-image.mjs / make-video.mjs 认的是
    // 这个环境变量名（`AGNES_API_KEY`），用户可能只填了 Key 而没建 provider。
    // Agnes 可能有多把（多账号）：`AGNES_API_KEY` 给第一把（向后兼容），
    // `AGNES_API_KEYS` 给全部 —— make-image.mjs / make-video.mjs 会按这个顺序轮换，
    // 一把被 429 就立刻换下一把（见 assets/toolbox/agnes-retry.mjs）。
    final agnesKeys = await readAll('agnes');
    if (agnesKeys.isNotEmpty) {
      env['AGNES_API_KEY'] = agnesKeys.first;
      env['AGNES_API_KEYS'] = agnesKeys.join(',');
    }
    return env;
  }
}
