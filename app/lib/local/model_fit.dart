import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart' show tr;
import 'model_manifest.dart';
import '../data/atomic_file.dart';

/// 一台手机跑某个模型的**匹配度**。用户口径三个档：
/// 无法运行（红）/ 勉强运行（白）/ 流畅运行（绿）。
enum ModelFit {
  /// 红：跑不了，或跑起来也没法用。
  unsupported,

  /// 白：能跑，但没有余量 / 实测算不上流畅。
  barely,

  /// 绿：跑得舒服。
  smooth,
}

/// 一次判定的结果 + **依据**。
///
/// 为什么必须带 reason：只给颜色等于让用户自己猜。三个档的边界是**我们定的**，
/// 就得把"为什么这么判"写在旁边（例如"内存 6 GB，这个模型要 8 GB"、
/// "实测 12.3 tok/s"）。用户不同意阈值时，也有据可争。
class ModelFitResult {
  const ModelFitResult({
    required this.fit,
    required this.reason,
    this.measured = false,
  });

  final ModelFit fit;
  final String reason;

  /// true = 这是**真机实测**的结论；false = 按配置预估的。
  final bool measured;
}

/// 速度阈值（tok/s）。**这是"能跑"与"能用"的分界，写在一处便于以后按机型调**。
///
/// 依据：低于 5 tok/s 时一句话要等十几秒（手册里那条"对话体验不成立"的线）；
/// 10 tok/s 以上才算读起来不别扭。两个值都是**体验线**，不是硬件线。
class FitThresholds {
  const FitThresholds._();

  /// 低于它 → 基本没法用于对话。
  static const double unusableTokPerSec = 5.0;

  /// 高于它 → 算流畅。
  static const double smoothTokPerSec = 10.0;

  /// 内存余量：低于这个数就把"流畅"降为"勉强" —— 系统和 App 自己也要吃内存。
  static const int minRamHeadroomGb = 2;

  /// 单文件过大时（即便内存够）也降一档：加载慢、且容易在后台被回收。
  static const int bigFileBytes = 2 * 1024 * 1024 * 1024; // 2 GiB
}

/// 按**设备配置**预估匹配度（不需要真跑模型，进页面立刻能给）。
///
/// [engineBundled] 是这个模型用的推理引擎有没有随包 —— 没随包的一律"无法运行"，
/// 因为现在真跑不起来（图形/视频那两个引擎尚未随包）。
ModelFitResult estimateFit({
  required OnDeviceModel model,
  required DeviceProfile profile,
  required bool engineBundled,

  /// 清单声明的**伴生文件**（VAE/T5 等）是不是都装齐了。
  /// 没装齐不能算绿 —— 与"没带引擎"同样的诚实：缺件就不假装能跑。
  bool companionsInstalled = true,
}) {
  // **已知缺口优先**：缺 VAE / T5 这类外部文件的模型，就算引擎与内存都够也不能算绿。
  final blocked = (model.blockedReason ?? '').trim();
  if (blocked.isNotEmpty) {
    return ModelFitResult(
      fit: ModelFit.unsupported,
      reason: '${tr(blocked)}'
          '　${tr('需要内存 ≥ {0} GB', ['${model.minRamGb}'])}',
    );
  }
  // ⚠️ MNN 不走这条判断（2026-11-02）。它的 companions 不是"可选的外部解码器"，
  // 而是**引擎本身必须读的配置文件**（llm_config.json / tokenizer.txt / llm.mnn.json）。
  // 下载器本来就会把它们和权重**一起下**，不存在"先下主文件、伴生文件后补"这种状态 ——
  // 用 mmproj 那套"缺件就红"的规则套上去，会让每个 MNN 模型都误报「无法运行」。
  final needsCompanionCheck =
      model.companions.isNotEmpty && model.engine != 'mnn';
  if (needsCompanionCheck && !companionsInstalled) {
    final compGb =
        ((model.totalBytes - model.bytes) / 1073741824).toStringAsFixed(1);
    return ModelFitResult(
      fit: ModelFit.unsupported,
      reason: '${tr('还缺伴生文件（共 {0} GB，如 VAE / T5）—— 先在列表里把它下全', [compGb])}'
          '　${tr('需要内存 ≥ {0} GB', ['${model.minRamGb}'])}',
    );
  }
  if (!engineBundled) {
    // ⚠️ **内存要求不能被"引擎"短路掉**（真机反馈：「只有文本大模型显示内存，
    // 其他大模型没有显示」）。以前这里只写引擎，用户就不知道"引擎一上，
    // 这台手机够不够跑它" —— 那个信息必须一起给。
    return ModelFitResult(
      fit: ModelFit.unsupported,
      reason: '${tr('缺 {0} 引擎（这版未随包）—— 不是手机不行', [model.engine])}'
          '　${tr('需要内存 ≥ {0} GB', ['${model.minRamGb}'])}',
    );
  }
  if (profile.ramGb <= 0) {
    // 读不到内存时不敢给绿灯：宁可保守，也别让用户下完才发现跑不动。
    return ModelFitResult(
      fit: ModelFit.barely,
      reason: tr('读不到本机内存，先按保守估计'),
    );
  }
  if (profile.ramGb < model.minRamGb) {
    return ModelFitResult(
      fit: ModelFit.unsupported,
      reason: tr('内存不够：本机 {0} GB，这个模型要 {1} GB',
          ['${profile.ramGb}', '${model.minRamGb}']),
    );
  }
  final headroom = profile.ramGb - model.minRamGb;
  if (headroom < FitThresholds.minRamHeadroomGb) {
    return ModelFitResult(
      fit: ModelFit.barely,
      reason: tr('内存刚好卡住：本机 {0} GB，模型要 {1} GB，余量不足 {2} GB', [
        '${profile.ramGb}',
        '${model.minRamGb}',
        '${FitThresholds.minRamHeadroomGb}'
      ]),
    );
  }
  // 用**总大小**（本体 + 视觉编码器等伴生文件）：一个 1.6 GB 的多模态条目
  // 实际要占 1.7 GB，只按本体算会低估。
  if (model.totalBytes >= FitThresholds.bigFileBytes && profile.ramGb <= 8) {
    return ModelFitResult(
      fit: ModelFit.barely,
      reason: tr('文件偏大（{0} GB），8 GB 机上加载与缓存都吃紧', [_gb(model.totalBytes)]),
    );
  }
  return ModelFitResult(
    fit: ModelFit.smooth,
    reason: tr('内存 {0} GB ≥ 需要 {1} GB，余量充足',
        ['${profile.ramGb}', '${model.minRamGb}']),
  );
}

/// 按**真机实测**的速度判档（跑过一次之后用它覆盖预估）。
ModelFitResult fitFromMeasurement({
  required double tokensPerSecond,
  required double promptMs,
}) {
  final tps = tokensPerSecond.toStringAsFixed(1);
  if (tokensPerSecond < FitThresholds.unusableTokPerSec) {
    return ModelFitResult(
      fit: ModelFit.unsupported,
      reason: tr('实测 {0} tok/s，一句话要等十几秒，基本没法用', [tps]),
      measured: true,
    );
  }
  if (tokensPerSecond < FitThresholds.smoothTokPerSec) {
    return ModelFitResult(
      fit: ModelFit.barely,
      reason: tr(
          '实测 {0} tok/s（首字 {1} ms），能用但偏慢', [tps, promptMs.toStringAsFixed(0)]),
      measured: true,
    );
  }
  return ModelFitResult(
    fit: ModelFit.smooth,
    reason: tr('实测 {0} tok/s（首字 {1} ms）', [tps, promptMs.toStringAsFixed(0)]),
    measured: true,
  );
}

String _gb(int bytes) => (bytes / 1073741824).toStringAsFixed(1);

/// 一次实测的留档（按模型 id）。
class BenchRecord {
  const BenchRecord({
    required this.modelId,
    required this.tokensPerSecond,
    required this.promptMs,
    required this.at,
  });

  final String modelId;
  final double tokensPerSecond;
  final double promptMs;
  final DateTime at;

  factory BenchRecord.fromJson(Map<String, dynamic> j) => BenchRecord(
        modelId: (j['modelId'] as String?) ?? '',
        tokensPerSecond: (j['tokensPerSecond'] as num?)?.toDouble() ?? 0,
        promptMs: (j['promptMs'] as num?)?.toDouble() ?? 0,
        at: DateTime.tryParse((j['at'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'modelId': modelId,
        'tokensPerSecond': tokensPerSecond,
        'promptMs': promptMs,
        'at': at.toIso8601String(),
      };
}

/// 实测结果落盘（`<dir>/bench.json`）。
///
/// 为什么要存：测一次要**真的把模型加载起来**（几秒到几十秒）。不存的话每次进页面
/// 都得重测，用户会以为"这 App 一直卡"。写失败也不抛错（与登记表同样的纪律）。
class BenchStore {
  BenchStore({required this.dir});

  final String dir;

  String get path => '$dir/bench.json';

  Map<String, BenchRecord>? _cache;

  Future<Map<String, BenchRecord>> load({bool refresh = false}) async {
    if (!refresh && _cache != null) return _cache!;
    final out = <String, BenchRecord>{};
    try {
      final f = File(path);
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map && raw['records'] is List) {
          for (final e in raw['records'] as List) {
            if (e is Map) {
              final r = BenchRecord.fromJson(Map<String, dynamic>.from(e));
              if (r.modelId.isNotEmpty) out[r.modelId] = r;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[dsh-fit] 读实测记录失败（当作空）：$e');
    }
    _cache = out;
    return out;
  }

  BenchRecord? get(String modelId) => _cache?[modelId];

  Future<void> save(BenchRecord record) async {
    final all = Map<String, BenchRecord>.from(await load());
    all[record.modelId] = record;
    _cache = all;
    try {
      await Directory(dir).create(recursive: true);
      await writeStringAtomic(File(path), jsonEncode(<String, dynamic>{
        'version': 1,
        'records': all.values.map((r) => r.toJson()).toList(),
      }));
    } catch (e) {
      debugPrint('[dsh-fit] 写实测记录失败：$e');
    }
  }
}
