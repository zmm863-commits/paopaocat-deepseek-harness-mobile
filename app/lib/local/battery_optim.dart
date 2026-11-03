import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// 后台运行 / 电池优化 / 厂商自带的省电开关（2026-10-31）。
///
/// ## 为什么这里没有「开关」
///
/// 把进程留在后台需要过**三道**关，其中只有一道 App 能动手：
///
/// | 关卡 | App 能做什么 |
/// |---|---|
/// | ① 前台服务 + 常驻通知 | ✅ 已经做了（[WebBridge]），这是 Android 认可的形态 |
/// | ② 忽略电池优化（AOSP） | ⚠️ 只能**弹系统确认框**，用户点允许才生效 |
/// | ③ 厂商自己的省电/自启动开关 | ❌ 系统 API 读不到也写不了，只能**把用户送到那一页** |
///
/// 所以界面上不设开关：开关只能记住"用户点过"，改不了系统行为 ——
/// 那正是故障复盘里批的「UI 状态 ≠ 运行状态」，和「轮换池开关亮着但代理早死了」
/// 是同一类病。这里要的是：**能检测的如实检测，检测不了的诚实说不知道**。
///
/// ## 第三关为什么非做不可
///
/// vivo 在 OriginOS 上会在 App 离开屏幕后**直接掐断网络**，不开「允许后台高耗电」
/// 就是连不上；小米的「省电策略」、华为/荣耀的「应用启动管理」、OPPO 的「后台行为」
/// 同理。这些页面是各家的私有 activity（跳转表在 `VendorSettings.kt`）。
class BatteryOptim {
  BatteryOptim._();

  static const MethodChannel _ch = MethodChannel('dsh/native');

  // ── ② 忽略电池优化（AOSP 标准页）─────────────────────────────────────

  /// 现在是否已豁免。`null` = 查不到 —— 界面必须显示成"不确定"，
  /// **不能**默认成 true（假绿灯）或 false（假警报）。
  static Future<bool?> isIgnoring() async {
    try {
      return await _ch.invokeMethod<bool>('batteryOptimStatus');
    } catch (_) {
      return null;
    }
  }

  /// 弹系统确认框。返回 `already` / `requested` / `fallback` / `null`。
  static Future<String?> request() async {
    try {
      return await _ch.invokeMethod<String>('batteryOptimRequest');
    } catch (_) {
      return null;
    }
  }

  /// 直接打开本应用的系统详情页。
  static Future<bool> openSettings() async {
    try {
      return await _ch.invokeMethod<bool>('batteryOptimOpenSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ── ③ 厂商自己的开关 ─────────────────────────────────────────────────

  /// 认厂商：`vivo` / `xiaomi` / `huawei` / `honor` / `oppo`。
  ///
  /// 返回 null = 标准 Android 或没适配的牌子 —— 这时界面上**不该**显示
  /// "去开厂商开关"，因为压根没有那一页（显示了只会点出一片空白）。
  static Future<String?> vendor() async {
    try {
      return await _ch.invokeMethod<String>('vendorKey');
    } catch (_) {
      return null;
    }
  }

  /// 打开厂商自己的那个页面。返回 `vendor` / `details` / `null`。
  ///
  /// [switchWire] 取 `background`（允许后台高耗电 / 省电策略 / 应用启动管理 /
  /// 后台行为）或 `autostart`（自启动）。
  static Future<String?> openVendorSettings(String switchWire) async {
    try {
      return await _ch.invokeMethod<String>(
        'openVendorSettings',
        <String, dynamic>{'switch': switchWire},
      );
    } catch (_) {
      return null;
    }
  }

  // ── 「去过」记忆 ─────────────────────────────────────────────────────

  /// 哪些厂商开关用户**已经去过**设置页。
  ///
  /// 这不是"已开启"——系统不告诉 App。它只回答"我把他送到那儿了吗"，
  /// 所以界面上写「已去过，回来确认一眼」，而不是打勾。
  static Future<Set<String>> visited(String filesDir) async {
    try {
      final f = File('$filesDir/background_access.json');
      if (!f.existsSync()) return <String>{};
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is Map && raw['visited'] is List) {
        return (raw['visited'] as List).map((e) => '$e').toSet();
      }
    } catch (_) {
      // 读坏了就当没去过 —— 最多多提示一次，不能因此崩。
    }
    return <String>{};
  }

  /// 记下"已把用户送到 [switchWire] 那一页"。
  static Future<void> markVisited(String filesDir, String switchWire) async {
    try {
      final set = await visited(filesDir);
      if (!set.add(switchWire)) return;
      final f = File('$filesDir/background_access.json');
      f.writeAsStringSync(jsonEncode(<String, dynamic>{
        'visited': set.toList()..sort(),
      }));
    } catch (_) {
      // 存不下只是下次要多点一次，不值得冒抛错的风险。
    }
  }
}
