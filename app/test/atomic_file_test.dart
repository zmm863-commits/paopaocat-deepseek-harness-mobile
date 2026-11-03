/// 落盘纪律的测试（审计 P0-9）。
///
/// ## 为什么这几条测试非有不可
///
/// P0-9 说的是一条**会静默吃掉用户数据**的链：
///
///   进程被杀 → 留下半份 JSON → 下次启动读成"空配置" → 下次保存把空写回去
///   → 用户的厂家与模型全没了，**且界面上没有任何提示**。
///
/// 修法有两半，两半都必须被钉住：
///   ① 写：`<目标>.part.<唯一后缀>` + `rename`（不会留半份）；
///   ② 读：解析失败**不当成空**，而是把坏文件挪到 `.corrupt` 并报错。
/// 第 ② 半是真正堵住"数据全没了"的那一步 —— 只要原始字节还在，
/// 人就能救回来。所以这里专门断言"坏文件的字节**还在**"。
///
/// ⚠️ 2026-10-16 起临时文件名**带唯一后缀**（`.part.<微秒>-<pid>-<序号>`）：
///    真机上两次保存同一个目标时隔 21ms 撞了同一个 `.part`，先完成的把它 rename 走，
///    后一个直接 `Cannot rename …`，**那一次更新就丢了**（产物索引真丢过一次）。
///    所以断言也从"没有那个固定名 `.part`"改成"**没有任何 `.part*` 残留**"，
///    并补一条"并发保存同一个目标，两次都要落地"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/data/atomic_file.dart';
import 'package:dsh_mobile/data/configured_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('atomic-file-test-');
    ConfiguredModels.lastReadError = null;
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('原子写', () {
    /// 盘上还剩几个 `.part*`（带不带唯一后缀都算）。
    int partLeftovers(Directory dir) => dir
        .listSync()
        .where((e) => e is File && e.path.contains('.part'))
        .length;

    test('写出内容，并且不留下任何 .part（含带唯一后缀的）', () async {
      final f = File('${tmp.path}/a.json');
      await writeStringAtomic(f, '{"x":1}');
      expect(f.readAsStringSync(), '{"x":1}');
      expect(partLeftovers(tmp), 0,
          reason: '临时文件应当已经被 rename 掉，不该留在盘上（${tmp.listSync().map((e) => e.path).join(', ')}）');
    });

    test('并发保存同一个目标：两次都要落地，且不留临时文件', () async {
      // 真机踩过的那条：两次保存相隔 21ms、共用固定名 `.part` → 后一次 rename 失败、
      // **那次更新就丢了**。修法是每次写用唯一临时名 —— 这条测试钉住它。
      final f = File('${tmp.path}/c.json');
      await Future.wait(<Future<void>>[
        writeStringAtomic(f, 'first'),
        writeStringAtomic(f, 'second'),
        writeStringAtomic(f, 'third'),
      ]);
      expect(<String>['first', 'second', 'third'], contains(f.readAsStringSync()),
          reason: '目标文件必须是其中一次的完整内容（不能是空/半份）');
      expect(partLeftovers(tmp), 0, reason: '并发写完应当没有临时文件残留');
    });

    test('覆盖已有文件（rename 覆盖）', () async {
      final f = File('${tmp.path}/a.json');
      await writeStringAtomic(f, 'old');
      await writeStringAtomic(f, 'new');
      expect(f.readAsStringSync(), 'new');
    });

    test('目标目录不存在也会自己建出来', () async {
      final f = File('${tmp.path}/sub/dir/a.json');
      await writeStringAtomic(f, 'ok');
      expect(f.readAsStringSync(), 'ok');
    });

    test('同步版行为一致', () {
      final f = File('${tmp.path}/s.json');
      writeStringAtomicSync(f, 'sync');
      expect(f.readAsStringSync(), 'sync');
      expect(partLeftovers(tmp), 0);
    });

    test('中途失败不会把目标文件截断成半份（.part 与目标互不影响）', () async {
      final f = File('${tmp.path}/a.json');
      await writeStringAtomic(f, '{"good":1}');
      // 模拟"正在写临时文件的时候崩了"：按实现的样子造一个**带唯一后缀**的半份
      // 临时文件。目标文件必须还是完整的那份 —— 这才是原子性的定义。
      File('${f.path}.part.999-1-1').writeAsStringSync('{"half":');
      expect(f.readAsStringSync(), '{"good":1}',
          reason: '目标文件被半份临时文件污染了 —— 原子性没了');
      // 下一次写照样成功（互不影响）
      await writeStringAtomic(f, '{"good":2}');
      expect(f.readAsStringSync(), '{"good":2}');
      // ⚠️ 那次"崩掉"留下的临时文件**不会被下一次写顺手清掉**（名字是唯一的，
      //    实现无法知道谁是谁的残留）—— 所以这里只断言"真写进去的那次没有残留"：
      //    盘上最多留着我们手工造的那一个，别的都不该多出来。
      expect(partLeftovers(tmp), 1,
          reason: '只应有我们手工造的那个残留（${tmp.listSync().map((e) => e.path).join(', ')}）');
      File('${f.path}.part.999-1-1').deleteSync();
    });
  });

  group('坏文件隔离', () {
    test('挪走且**保住字节**（这是"数据还能救回来"的前提）', () {
      final f = File('${tmp.path}/a.json');
      f.writeAsStringSync('{"providers":[{"id":"d');
      final moved = quarantineCorrupt(f);
      expect(moved, isNotNull);
      expect(f.existsSync(), isFalse, reason: '原文件应该已经被挪走');
      expect(moved!.readAsStringSync(), '{"providers":[{"id":"d',
          reason: '用户那半份原始字节必须还在 —— 否则没法人工恢复');
    });

    test('只保留最近一次（不堆垃圾）', () {
      final f = File('${tmp.path}/a.json');
      f.writeAsStringSync('first');
      quarantineCorrupt(f);
      f.writeAsStringSync('second');
      final moved = quarantineCorrupt(f);
      expect(moved!.readAsStringSync(), 'second');
      // 目录里只该有一个 .corrupt
      final corrupts = tmp
          .listSync()
          .where((e) => e.path.endsWith(kCorruptSuffix))
          .toList();
      expect(corrupts.length, 1);
    });

    test('文件不存在时返回 null，不改任何东西', () {
      expect(quarantineCorrupt(File('${tmp.path}/nope.json')), isNull);
    });
  });

  group('ConfiguredModels.readConfig：损坏不再被当成"空配置"', () {
    test('文件不存在 = 还没配过：返回空且**不报错**', () {
      final cfg = ConfiguredModels.readConfig(tmp.path);
      expect(cfg.providers, isEmpty);
      expect(ConfiguredModels.lastReadError, isNull,
          reason: '"还没配过"不该被说成"读坏了"');
    });

    test('文件在但解析不了 = 损坏：隔离原文件 + 置 lastReadError', () {
      final f = ConfiguredModels.fileOf(tmp.path);
      f.writeAsStringSync('{"providers":[{"id":"deep'); // 半份 JSON
      final cfg = ConfiguredModels.readConfig(tmp.path);
      expect(cfg.providers, isEmpty);
      expect(ConfiguredModels.lastReadError, isNotNull,
          reason: '读坏了必须让界面能说出来，不能假装"还没配"');
      expect(f.existsSync(), isFalse, reason: '坏文件应该被隔离');
      final moved = File('${f.path}$kCorruptSuffix');
      expect(moved.existsSync(), isTrue);
      expect(moved.readAsStringSync(), '{"providers":[{"id":"deep');
    });

    // ── 三条免 Key 通道的旧数据迁移（2026-11-03）──────────────────────
    //
    // `pm install -r` 不清数据，升级后 models.json 里还留着 kilo/ovh 两个厂家。
    // 不迁移的话会话选择器里还是三个同名分组 —— 真机第一次启动就是这样。
    test('旧数据迁移：kilo/ovh 并进 zen，只剩一个免Key厂家', () {
      final f = ConfiguredModels.fileOf(tmp.path);
      f.writeAsStringSync('''
{
 "version": 2,
 "providers": [
   {"id": "zen", "label": "免Key通道", "baseUrl": "http://127.0.0.1:1/v1", "apiKeyEnv": "Z"},
   {"id": "kilo", "label": "旧的 Kilo", "baseUrl": "http://127.0.0.1:1/kilo/v1", "apiKeyEnv": "Z"},
   {"id": "ovh", "label": "旧的 OVH", "baseUrl": "http://127.0.0.1:1/ovh/v1", "apiKeyEnv": "Z"}
 ],
 "models": [
   {"provider": "zen", "id": "zen-a"},
   {"provider": "kilo", "id": "kilo-b"},
   {"provider": "ovh", "id": "ovh-c"}
 ]
}
''');
      final cfg = ConfiguredModels.readConfig(tmp.path);
      expect(cfg.providers.map((p) => p.id).toList(), <String>['zen'],
          reason: 'kilo/ovh 必须被摘掉（否则选择器里还是三个分组）');
      expect(cfg.models.map((m) => m.id).toList(),
          <String>['zen-a', 'kilo-b', 'ovh-c'],
          reason: '三条的模型都要保住');
      expect(cfg.models.every((m) => m.provider == 'zen'), isTrue,
          reason: '全部归到 zen 下 —— 转发靠模型名判断，不靠 provider');
    });

    test('旧数据迁移：重名模型只留一条', () {
      final f = ConfiguredModels.fileOf(tmp.path);
      f.writeAsStringSync('''
{
 "version": 2,
 "providers": [
   {"id": "zen", "label": "免Key通道", "baseUrl": "http://127.0.0.1:1/v1", "apiKeyEnv": "Z"},
   {"id": "kilo", "label": "旧的 Kilo", "baseUrl": "http://127.0.0.1:1/kilo/v1", "apiKeyEnv": "Z"}
 ],
 "models": [
   {"provider": "zen", "id": "same"},
   {"provider": "kilo", "id": "same"},
   {"provider": "kilo", "id": "kilo-only"}
 ]
}
''');
      final cfg = ConfiguredModels.readConfig(tmp.path);
      final ids = cfg.models.map((m) => m.id).toList();
      expect(ids, <String>['same', 'kilo-only']);
      expect(ids.where((x) => x == 'same').length, 1);
    });

    test('没有 zen 时不动（不能凭空造一个厂家出来）', () {
      final f = ConfiguredModels.fileOf(tmp.path);
      f.writeAsStringSync('''
{
 "version": 2,
 "providers": [
   {"id": "kilo", "label": "Kilo", "baseUrl": "http://127.0.0.1:1/kilo/v1", "apiKeyEnv": "Z"}
 ],
 "models": [{"provider": "kilo", "id": "kilo-b"}]
}
''');
      final cfg = ConfiguredModels.readConfig(tmp.path);
      expect(cfg.providers.map((p) => p.id).toList(), <String>['kilo']);
    });

    test('顶层不是对象（比如是数组/数字）= 同样按损坏处理', () {
      ConfiguredModels.fileOf(tmp.path).writeAsStringSync('[1,2,3]');
      ConfiguredModels.readConfig(tmp.path);
      expect(ConfiguredModels.lastReadError, isNotNull);
    });

    test('空文件当作"还没配过"（不是损坏）', () {
      ConfiguredModels.fileOf(tmp.path).writeAsStringSync('');
      ConfiguredModels.readConfig(tmp.path);
      expect(ConfiguredModels.lastReadError, isNull);
    });

    test('好的配置：正常读出来，且不置错误', () async {
      await ConfiguredModels.saveConfig(
        filesDir: tmp.path,
        config: const ConfiguredConfig(
          version: ConfiguredModels.currentVersion,
          providers: [
            ProviderSpec(
              id: 'deepseek',
              label: 'DeepSeek',
              baseUrl: 'https://api.deepseek.com/v1',
              api: 'openai-completions',
              apiKeyEnv: 'DEEPSEEK_API_KEY',
            ),
          ],
          models: [
            ModelSpec(provider: 'deepseek', id: 'deepseek-chat'),
          ],
          groups: <RotationGroupSpec>[],
          selected: 'deepseek/deepseek-chat',
        ),
      );
      final cfg = ConfiguredModels.readConfig(tmp.path);
      expect(ConfiguredModels.lastReadError, isNull);
      expect(cfg.providers.map((p) => p.id), contains('deepseek'));
      expect(cfg.models.map((m) => m.id), contains('deepseek-chat'));
    });

    test('保存成功后清掉上一次的"读坏了"状态', () async {
      ConfiguredModels.fileOf(tmp.path).writeAsStringSync('{broken');
      ConfiguredModels.readConfig(tmp.path);
      expect(ConfiguredModels.lastReadError, isNotNull);
      await ConfiguredModels.saveConfig(
        filesDir: tmp.path,
        config: ConfiguredConfig.empty,
      );
      expect(ConfiguredModels.lastReadError, isNull,
          reason: '写成功了，"读坏了"这个提示就该消失，否则界面会一直挂着它');
    });

    test('保存是原子的：写完之后盘上没有 .part', () async {
      await ConfiguredModels.saveConfig(
        filesDir: tmp.path,
        config: ConfiguredConfig.empty,
      );
      final stray = tmp.listSync().where((e) => e.path.endsWith('.part')).toList();
      expect(stray, isEmpty);
      // 且文件本身是合法 JSON
      final raw = ConfiguredModels.fileOf(tmp.path).readAsStringSync();
      expect(() => jsonDecode(raw), returnsNormally);
    });
  });

  group('完好的配置不会被误判成损坏', () {
    test('写坏再读的**典型流程**：坏文件被隔离，用户后续保存不再破坏它', () async {
      final f = ConfiguredModels.fileOf(tmp.path);
      f.writeAsStringSync('{"providers":[{"id":"d');
      ConfiguredModels.readConfig(tmp.path); // 隔离
      // 用户后续（在空配置基础上）保存一次 —— 老版本这一步会把用户数据永久抹掉
      await ConfiguredModels.saveConfig(
        filesDir: tmp.path,
        config: ConfiguredConfig.empty,
      );
      final moved = File('${f.path}$kCorruptSuffix');
      expect(moved.existsSync(), isTrue, reason: '原始字节必须还在，可人工恢复');
      expect(moved.readAsStringSync(), contains('"providers"'));
    });
  });
}
