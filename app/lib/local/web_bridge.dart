import 'package:flutter/services.dart';

import 'diagnostics_log.dart';

/// 「电脑访问」保活：把 DSH 与设计站的两个 node 进程提级到前台服务。
///
/// ## 为什么必须有（2026-10-28 审计）
///
/// manifest 里原来只有 `DshSchedulerService`（定时任务）与
/// `VdShellPairingService`（免装配对），**没有服务托管这两条转发**。
/// 结果：App 切后台久了 / 内存紧张 / 从最近任务划掉 → node 进程被杀 →
/// 电脑端页面突然 502、设计站打不开，而 App 界面看起来一切正常。
///
/// Dart 侧的 30 秒健康巡检只能救「进程还在但假死」，救不了「整个进程没了」。
///
/// ## 它不做什么
///
/// 前台服务**不持有 socket、不碰 node** —— 那些都在 Dart 侧。它只负责
/// 「让这个 App 进程不被系统随意回收」，并在通知栏如实显示当前服务的两个地址。
class WebBridge {
  WebBridge._();

  static const MethodChannel _ch = MethodChannel('dsh/native');

  /// 这条保活服务**为谁活着**（与 `WebBridgeService.kt` 的常量一一对应）。
  ///
  /// 为什么要有区分（2026-11-02）：同一个服务被两个开关共用 ——
  /// 「后台运行」（默认开）和「移动桌面平台」。但通知栏文案必须对得上
  /// 用户做的事：没开电脑访问却写"电脑正在访问"就是撒谎。
  static const String modeKeepAlive = 'keepalive';
  static const String modeWebAccess = 'webaccess';

  /// 起前台服务。[detail] 显示在通知栏正文（例如两个访问地址）。
  ///
  /// [mode] 决定通知标题：`keepalive` → 「后台运行中」；`webaccess` → 「电脑正在访问」。
  static Future<bool> start(
    String detail, {
    String mode = modeWebAccess,
  }) async {
    try {
      final ok = await _ch.invokeMethod<bool>(
        'webBridgeStart',
        {'detail': detail, 'mode': mode},
      );
      DiagnosticsLog.add(
          'bridge',
          '前台服务已启动（通知栏「${mode == modeKeepAlive ? '后台运行中' : '电脑正在访问'}」）');
      return ok ?? false;
    } on MissingPluginException {
      // 桌面/iOS 上没有这个通道：不影响功能，只少了保活。
      DiagnosticsLog.add('bridge', '当前平台没有保活服务（不是 Android）');
      return false;
    } catch (e) {
      DiagnosticsLog.add('bridge', '起保活服务失败（电脑连接可能被系统回收中断）：$e');
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod<bool>('webBridgeStop');
      DiagnosticsLog.add('bridge', '前台服务已停止');
    } catch (_) {
      // 忽略：本来就可能已经没了
    }
  }
}
