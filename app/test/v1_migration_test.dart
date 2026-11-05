/// 老格式（v1）`models.json` 迁移的回归测试。
///
/// ## 为什么要有它（2026-11-05 网友真机事故）
///
/// 用户从 0.81 升到 0.82 之后，会话的模型选择器里冒出一个「com · 0 个模型」，
/// 而设置页里**完全看不到它**。随后所有消息都发不出去，日志里是：
///
///     llm-pi-ai (@deepseek-ai/dsh-llm-pi-ai): Error:
///       provider "com" has an empty baseURL
///     dsh: warning: 1 entry did not activate
///     session/new 失败：{"code":-32603,"message":"Internal error",
///       "data":{"details":"no adapter registered for provider \"zen\""}}
///
/// 根因在 `readConfig` 的老格式迁移：v1 文件只有顶层 `provider` / `baseUrl`，
/// 迁移时若 `baseUrl` **缺失或为空**，旧代码照样造出一条厂家记录
/// （`id=com` 是默认值，`label=com`，`baseUrl=""`）。这条记录进了 overlay 之后，
/// 引擎的 llm 插件在激活阶段就抛错 → **整条插件不激活** → 一个适配器都没有 →
/// 换任何厂家都建不起会话。
///
/// 两个现象都能对上：
///   * **升级才有** —— 只有读到老格式文件才会走迁移；
///   * **设置里看不到** —— id 是 `com`，和内置「Command（聚合，推荐）」撞了，
///     `_customProviders()` 按"不在内置清单里"过滤，把它当内置的排掉；
///     而内置卡没有删除按钮，于是它隐形且删不掉。
///
/// 所以这里钉死一条：**地址为空就绝不造厂家**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/configured_models.dart';

void main() {
  Directory tmp() {
    final d = Directory.systemTemp.createTempSync('dsh-v1-migrate-');
    addTearDown(() {
      if (d.existsSync()) d.deleteSync(recursive: true);
    });
    return d;
  }

  void writeRaw(Directory dir, Map<String, Object?> json) {
    File('${dir.path}/models.json').writeAsStringSync(jsonEncode(json));
  }

  test('★★ 老格式文件里 baseUrl 为空 → 不许造出「com」厂家（会毒死整条 llm 插件）',
      () {
    // 现场：只有顶层的 provider / models，没有 baseUrl。
    // 这正是升级时能读到的那种老文件。
    final dir = tmp();
    writeRaw(dir, <String, Object?>{
      'version': 1,
      'provider': 'com',
      'models': <Object?>['deepseek/deepseek-v4.1-flash'],
    });

    final cfg = ConfiguredModels.readConfig(dir.path);

    expect(cfg.providers, isEmpty,
        reason: '地址为空就绝不能造厂家 —— 造出来会让所有厂家都没有适配器');
    expect(
      cfg.providers.any((p) => p.baseUrl.trim().isEmpty),
      isFalse,
      reason: '配置里一条空 baseURL 的记录都不许有（引擎会因此整条插件不激活）',
    );
  });

  test('★ 老格式文件里 baseUrl 缺失（连字段都没有）→ 同样不造厂家', () {
    final dir = tmp();
    writeRaw(dir, <String, Object?>{
      'version': 1,
      'provider': 'com',
    });

    final cfg = ConfiguredModels.readConfig(dir.path);
    expect(cfg.providers, isEmpty);
  });

  test('老格式文件里 baseUrl 有值 → 照常迁移（别把这个正常场景也改坏）', () {
    final dir = tmp();
    writeRaw(dir, <String, Object?>{
      'version': 1,
      'provider': 'myvps',
      'baseUrl': 'https://example.com/v1',
      'models': <Object?>['some-model'],
    });

    final cfg = ConfiguredModels.readConfig(dir.path);

    expect(cfg.providers.length, 1);
    expect(cfg.providers.first.id, 'myvps');
    expect(cfg.providers.first.baseUrl, 'https://example.com/v1');
    expect(cfg.models.any((m) => m.id == 'some-model'), isTrue,
        reason: '模型列表要跟着迁过来，不能因为修空地址把正常迁移也弄丢');
  });

  test('v2 文件（有 providers 数组）不受影响', () {
    final dir = tmp();
    writeRaw(dir, <String, Object?>{
      'version': 2,
      'providers': <Object?>[
        <String, Object?>{
          'id': 'deepseek',
          'label': 'DeepSeek 官方',
          'baseUrl': 'https://api.deepseek.com',
          'apiKeyEnv': 'PROVIDER_DEEPSEEK_KEY',
        },
      ],
      'models': <Object?>[
        <String, Object?>{
          'provider': 'deepseek',
          'id': 'deepseek-v4.1-flash',
        },
      ],
      'groups': <Object?>[],
      'selected': 'deepseek/deepseek-v4.1-flash',
    });

    final cfg = ConfiguredModels.readConfig(dir.path);
    expect(cfg.providers.length, 1);
    expect(cfg.providers.first.id, 'deepseek');
    expect(cfg.models.length, 1);
  });
}
