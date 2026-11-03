import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/local/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个小清单：两条 family 各有一个"通用版 + 机型专属版"，用来验证择优逻辑。
const String _fixture = '''
{
  "version": 7,
  "updatedAt": "2026-10-06",
  "models": [
    {
      "id": "alpha-gpu", "family": "alpha", "name": "Alpha 通用", "kind": "vision",
      "engine": "litert-lm", "format": "litertlm", "quant": "int4",
      "fileName": "alpha-gpu.litertlm", "bytes": 1000, "sha256": null,
      "license": "Apache-2.0", "minRamGb": 6, "socMatch": [],
      "sources": [{"label": "A", "url": "https://a/alpha-gpu.litertlm", "priority": 0}]
    },
    {
      "id": "alpha-npu", "family": "alpha", "name": "Alpha 骁龙专属", "kind": "vision",
      "engine": "litert-lm", "format": "litertlm", "quant": "int4",
      "fileName": "alpha-npu.litertlm", "bytes": 2000, "sha256": null,
      "license": "Apache-2.0", "minRamGb": 8,
      "socMatch": ["sm8750", "snapdragon8elite"],
      "sources": [{"label": "A", "url": "https://a/alpha-npu.litertlm", "priority": 0}]
    },
    {
      "id": "beta-q4", "family": "beta", "name": "Beta 4GB 可跑", "kind": "text",
      "engine": "llama.cpp", "format": "gguf", "quant": "Q4_K_M",
      "fileName": "beta-q4.gguf", "bytes": 500, "sha256": "abc",
      "license": "Apache-2.0", "minRamGb": 4, "socMatch": [],
      "sources": [{"label": "B", "url": "https://b/beta-q4.gguf", "priority": 0}]
    }
  ]
}
''';

void main() {
  group('清单解析', () {
    test('读出版本与条目，字段齐全', () {
      final m = OnDeviceManifest.parse(_fixture);
      expect(m.version, 7);
      expect(m.models.length, 3);
      final alpha = m.byId('alpha-gpu')!;
      expect(alpha.family, 'alpha');
      expect(alpha.bytes, 1000);
      expect(alpha.license, 'Apache-2.0');
      expect(alpha.isUniversal, isTrue);
      expect(alpha.hasHash, isFalse);
      expect(m.byId('beta-q4')!.hasHash, isTrue);
      expect(m.byId('不存在'), isNull);
    });

    test('内存不够的条目被过滤掉', () {
      final m = OnDeviceManifest.parse(_fixture);
      const p4 = DeviceProfile(ramGb: 4);
      final ids = m.availableFor(p4).map((e) => e.id).toList();
      expect(ids, contains('beta-q4'));
      expect(ids, isNot(contains('alpha-gpu')), reason: '通用版要 6GB');
      expect(ids, isNot(contains('alpha-npu')), reason: '专属版要 8GB');
    });

    test('机型专属命中时优先，且大小不是决定因素', () {
      final m = OnDeviceManifest.parse(_fixture);
      const p = DeviceProfile(ramGb: 8, soc: 'SM8750');
      expect(m.bestFor('alpha', p)!.id, 'alpha-npu');
    });

    test('SoC 写法不同也能匹配（空格/横杠/大小写归一化）', () {
      final m = OnDeviceManifest.parse(_fixture);
      for (final soc in <String>[
        'Snapdragon 8 Elite',
        'snapdragon-8_elite',
        'SM8750'
      ]) {
        expect(m.bestFor('alpha', DeviceProfile(ramGb: 8, soc: soc))!.id,
            'alpha-npu',
            reason: '$soc 应该命中专属版');
      }
      for (final soc in <String>['', 'Dimensity 9300', 'Tensor G6']) {
        expect(m.bestFor('alpha', DeviceProfile(ramGb: 8, soc: soc))!.id,
            'alpha-gpu',
            reason: '$soc 应退回通用版');
      }
    });

    test('从宿主设备信息构造画像：骁龙机型命中 NPU 专属版', () {
      final p = DeviceProfile.fromDeviceInfo(<String, dynamic>{
        'totalRamGb': 8,
        'soc': 'Qualcomm SM8750',
        'model': 'SM-S9280',
        'abis': <String>['arm64-v8a', 'armeabi-v7a'],
      });
      expect(p.ramGb, 8);
      expect(p.abi, 'arm64-v8a');
      final m = OnDeviceManifest.parse(_fixture);
      // 归一化后 "Qualcomm SM8750" 里含 "sm8750" → 拿专属版
      expect(m.bestFor('alpha', p)!.id, 'alpha-npu');
    });

    test('从宿主设备信息构造画像：内存读不到时保守处理（给 0，不猜）', () {
      final p = DeviceProfile.fromDeviceInfo(const <String, dynamic>{});
      expect(p.ramGb, 0, reason: '猜错内存会让用户下到跑不动的模型');
      expect(p.abi, 'arm64-v8a', reason: 'ABI 未知时按我们实际发布的架构兜底');
      final m = OnDeviceManifest.parse(_fixture);
      expect(m.availableFor(p), isEmpty, reason: '内存未知时一条都不给');
    });

    test('从宿主设备信息构造画像：没有 arm64 时用第一个 ABI', () {
      final p = DeviceProfile.fromDeviceInfo(<String, dynamic>{
        'totalRamGb': 12,
        'soc': '',
        'abis': <String>['x86_64'],
      });
      expect(p.abi, 'x86_64');
      final m = OnDeviceManifest.parse(_fixture);
      expect(m.availableFor(p), isEmpty, reason: '清单只有 arm64 的条目');
    });

    test('内存不足时给不出条目（而不是硬塞一个）', () {
      final m = OnDeviceManifest.parse(_fixture);
      expect(m.bestFor('alpha', const DeviceProfile(ramGb: 4, soc: 'SM8750')),
          isNull);
    });
  });

  group('随包清单自检（防止手改 JSON 改坏）', () {
    test('assets/models/model_manifest.json 能解析且每条自洽', () {
      final f = File('assets/models/model_manifest.json');
      expect(f.existsSync(), isTrue,
          reason: '清单必须随包存在（pubspec assets 里要列到文件级）');
      final m = OnDeviceManifest.parse(f.readAsStringSync());
      expect(m.version, greaterThan(0));
      expect(m.models, isNotEmpty);

      final ids = <String>{};
      for (final e in m.models) {
        expect(ids.add(e.id), isTrue, reason: 'id 重复：${e.id}');
        expect(e.bytes, greaterThan(0), reason: '${e.id} 没有真实字节数，就无法做体积校验');
        expect(e.sources, isNotEmpty, reason: '${e.id} 没有下载源');
        expect(e.minRamGb, greaterThanOrEqualTo(1),
            reason: '${e.id} minRamGb 不合理');
        expect(e.fileName.contains('/'), isFalse,
            reason: '${e.id} fileName 不该带路径');
        expect(e.engine, isNotEmpty);
        expect(e.license, isNotEmpty);
        for (final s in e.sources) {
          expect(s.url.startsWith('https://'), isTrue,
              reason: '${e.id} 的源必须 https：${s.url}');
          expect(Uri.parse(s.url).path.endsWith('/${e.fileName}'), isTrue,
              reason: '${e.id} 源地址里的文件名与 fileName 不一致：${s.url}');
        }
      }
    });

    test('清单在常见设备画像下都有得选', () {
      final m = OnDeviceManifest.parse(
          File('assets/models/model_manifest.json').readAsStringSync());
      // ⚠️ 2026-10-08 起清单收敛为 **LiteRT-LM + Gemma 4**（用户选定路线 A），
      //    唯一的端侧 LLM `gemma-4-e2b` 要 **6 GB 内存**（2.41 GiB 权重 + KV cache），
      //    所以 **4 GB 机型不再有可选项** —— 这是产品决定，不是清单坏了。
      //    原先这里还有一档 `ramGb: 4`，随 llama.cpp 那批小模型一起下线了。
      //    仍旧守住这条测试的本意：**能跑得动的机型必须至少有一个可选项**。
      for (final p in const <DeviceProfile>[
        DeviceProfile(ramGb: 6, soc: 'unknown'),
        DeviceProfile(ramGb: 6, soc: 'SM8750'),
        DeviceProfile(ramGb: 8, soc: 'Google Tensor G6'),
        DeviceProfile(ramGb: 12, soc: 'Snapdragon 8 Elite'),
      ]) {
        expect(m.availableFor(p), isNotEmpty, reason: '$p 一条都装不了，说明清单覆盖不到');
      }
    });

    test('发布纪律：requireHash 为 true 时不允许存在没有 sha256 的条目', () {
      final m = OnDeviceManifest.parse(
          File('assets/models/model_manifest.json').readAsStringSync());
      if (!m.requireHash) {
        // 当前是开发态：只提示，不失败。回填完 sha256 后要把 requireHash 打开。
        final missing = m.models.where((e) => !e.hasHash).length;
        // ignore: avoid_print
        print('[清单] 开发态：$missing / ${m.models.length} 条还没回填 sha256');
        return;
      }
      final missing =
          m.models.where((e) => !e.hasHash).map((e) => e.id).toList();
      expect(missing, isEmpty, reason: '这些条目缺 sha256：$missing');
    });
  });

  group('JSON 健壮性', () {
    test('根节点不是对象时明确报错', () {
      expect(
          () => OnDeviceManifest.parse('[]'), throwsA(isA<FormatException>()));
    });

    test('缺字段时给安全默认值而不是崩', () {
      final m = OnDeviceManifest.parse(jsonEncode(<String, dynamic>{
        'version': 1,
        'models': <dynamic>[
          <String, dynamic>{
            'id': 'x',
            'name': 'X',
            'fileName': 'x.gguf',
            'bytes': 10,
            'sources': <dynamic>[
              <String, dynamic>{'url': 'https://h/x.gguf'},
            ],
          }
        ],
      }));
      final x = m.models.single;
      expect(x.kind, 'text');
      expect(x.engine, 'llama.cpp');
      expect(x.license, 'unknown');
      expect(x.minRamGb, 4);
      expect(x.sources.single.label, 'https://h/x.gguf');
    });
  });
  test('多模态条目的伴生文件（mmproj）能被解析，且计入总大小', () {
    final m = OnDeviceManifest.parse('''
{
  "version": 1,
  "requireHash": false,
  "models": [
    {
      "id": "vlm", "family": "vlm", "name": "示例多模态", "kind": "vision",
      "engine": "llama.cpp", "format": "gguf", "quant": "Q8_0",
      "fileName": "vlm.gguf", "bytes": 1000, "sha256": null,
      "license": "Apache-2.0", "minRamGb": 3, "socMatch": [],
      "abi": "arm64-v8a",
      "sources": [{"label": "a", "url": "https://e/a.gguf", "priority": 0}],
      "companions": [
        {
          "fileName": "mmproj-vlm.gguf", "bytes": 400, "sha256": null,
          "sources": [
            {"label": "b", "url": "https://e/mmproj.gguf", "priority": 1},
            {"label": "a", "url": "https://e/mmproj2.gguf", "priority": 0}
          ]
        }
      ]
    }
  ]
}
''');
    final v = m.models.single;
    expect(v.kind, 'vision');
    expect(v.companions.length, 1);
    expect(v.companions.single.fileName, 'mmproj-vlm.gguf');
    expect(v.companions.single.bytes, 400);
    // 伴生文件的源也要能按 priority 排序（下载器用的就是 sortedSources）。
    // 解析后保持文件原样，排序在用到时做 —— 所以断言在 sortedSources 上。
    expect(v.companions.single.sources.first.url, 'https://e/mmproj.gguf',
        reason: '解析保持文件原序');
    expect(
        v.companions.single.sortedSources.first.url, 'https://e/mmproj2.gguf',
        reason: 'sortedSources 才是选源用的顺序');
    expect(v.totalBytes, 1400, reason: '本体 1000 + 编码器 400');
  });

  test('没有 companions 字段的老条目照样能解析（向后兼容）', () {
    final m = OnDeviceManifest.parse('''
{"version":1,"requireHash":false,"models":[
 {"id":"t","family":"t","name":"t","kind":"text","engine":"llama.cpp",
  "format":"gguf","quant":"Q4","fileName":"t.gguf","bytes":10,"sha256":null,
  "license":"MIT","minRamGb":2,"socMatch":[],"abi":"arm64-v8a",
  "sources":[{"label":"a","url":"https://e/t.gguf","priority":0}]}]}
''');
    expect(m.models.single.companions, isEmpty);
    expect(m.models.single.totalBytes, 10);
  });
  test('blockedReason 能被解析（还缺外部文件的模型）', () {
    final m = OnDeviceManifest.parse('''
{"version":1,"requireHash":false,"models":[
 {"id":"v","family":"v","name":"v","kind":"video","engine":"stable-diffusion.cpp",
  "format":"gguf","quant":"Q3","fileName":"v.gguf","bytes":10,"sha256":null,
  "license":"Apache-2.0","minRamGb":8,"socMatch":[],"abi":"arm64-v8a",
  "blockedReason":"还需要 VAE 与 T5",
  "sources":[{"label":"a","url":"https://e/v.gguf","priority":0}]}]}
''');
    expect(m.models.single.blockedReason, '还需要 VAE 与 T5');
  });

  test('kvTokens 能被解析（不写 = 0 = 未知，按用户档位来）', () {
    final m = OnDeviceManifest.parse('''
{"version":1,"models":[
 {"id":"a","family":"a","name":"A","kind":"text","engine":"litert-lm",
  "format":"litertlm","fileName":"a.litertlm","bytes":1,"quant":"int4",
  "license":"Apache-2.0","minRamGb":4,"kvTokens":4096,
  "sources":[{"label":"a","url":"https://e/a.litertlm","priority":0}]},
 {"id":"b","family":"b","name":"B","kind":"text","engine":"litert-lm",
  "format":"litertlm","fileName":"b.litertlm","bytes":1,"quant":"int4",
  "license":"Apache-2.0","minRamGb":4,
  "sources":[{"label":"a","url":"https://e/b.litertlm","priority":0}]}]}
''');
    expect(m.models[0].kvTokens, 4096);
    expect(m.models[1].kvTokens, 0, reason: '没写就是未知，不能擅自当成 0 格缓存');
  });

  // （2026-11-03）上面这组「ekv 后缀必须写 kvTokens」的守卫**已随引擎收敛删除**：
  // 它盯的是 litert-lm 的 `.litertlm` 文件（文件名带 ekv4096 这类后缀），
  // 而 litert-lm 已按用户口径从清单下线 —— 现在清单里 100% 是 MNN 模型，
  // 一个 ekv 文件名都没有，这条守卫会永远空转。它防的那个 Status 9 回归
  // 也只发生在 litert-lm 上，MNN 侧不适用。

  group('随包清单自洽（审计 P1-10）', () {
    test('requireHash 打开时，每个模型都必须有 sha256', () async {
      // 开 requireHash 的语义是"没有 sha256 就拒绝安装"。所以清单一旦打开这个开关，
      // **每一条**都必须已经填好哈希 —— 否则那些条目全员下不了，而报错看起来
      // 像"清单坏了"，不像"我们忘了填"。
      //
      // 本机填不了真值（三个模型 584 MB~2.58 GB，本机只有 4 MiB 的测试残留，
      // 不是同一份文件）→ 所以这里不检查"有没有填"，只检查**开关与内容一致**。
      final raw = File('assets/models/model_manifest.json').readAsStringSync();
      final man = OnDeviceManifest.parse(raw);

      if (man.requireHash) {
        final missing = man.models.where((m) => !m.hasHash).map((m) => m.id).toList();
        expect(missing, isEmpty,
            reason: 'requireHash=true 但这些条目没有 sha256，会被拒绝安装：$missing');
      } else {
        // 没打开时，至少要如实体现在界面上（下载结果里 hashVerified=false）。
        // 这条断言的意义是：**别让 requireHash 悄悄变成 true** —— 改了这里就说明
        // 你确认过哈希都填好了。
        expect(man.requireHash, isFalse,
            reason: 'requireHash 被改成 true 了？先确认三个模型的 sha256 都填好了，'
                '再把这条断言一起改掉（那是你的确认动作）。');
      }
    });

    test('sha256 字段存在时必须是 64 位十六进制（填错格式等于没填）', () async {
      final raw = File('assets/models/model_manifest.json').readAsStringSync();
      final man = OnDeviceManifest.parse(raw);
      for (final m in man.models) {
        if (!m.hasHash) continue;
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(m.sha256!), isTrue,
            reason: '${m.id} 的 sha256 格式不对：${m.sha256}');
      }
    });
  });
}
