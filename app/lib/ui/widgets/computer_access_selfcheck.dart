import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';

/// 「连不上？点这里自检」—— 把"到底是哪一环坏了"变成一段人话。
///
/// ## 为什么要这个（2026-10-31，三个用户反馈堆出来的）
///
/// 三天的用户反馈是同一种形状：**"连不上"**，但真正的原因分属完全不同的层：
///
/// | 用户看到的 | 真实原因 |
/// |---|---|
/// | `INET_E_RESSOURCE_NOT_FOUND` | 浏览器没把地址当网址（DNS 层，**根本没连到手机**） |
/// | `ERR_CONNECTION_REFUSED` | 端口没人听（App 被系统冻结 / 转发器没起来） |
/// | `dsh web authentication required` | 连上了，口令不对（旧地址 / 没重置） |
///
/// 三者需要的解法完全不同，但用户只会说"连不上"。来回三轮才能定位一次。
///
/// 这个自检**真的发一次请求**（不是只看开关状态），然后把结论写成
/// 「哪一环通了、哪一环没通、下一步做什么」。
class SelfCheckItem {
  const SelfCheckItem({
    required this.label,
    required this.ok,
    required this.detail,
    this.warn = false,
  });

  /// 这一项检查什么（人话，比如「本地回环」）。
  final String label;

  /// 这一项通过了没有。
  final bool ok;

  /// 具体结果（数字、状态码、错误原因）。
  final String detail;

  /// 不致命但值得看一眼（比如"能连上，但返回 200 而不是 303"）。
  final bool warn;
}

/// 自检报告：一串检查项 + 可直接复制的地址 + 排查建议。
class SelfCheckReport {
  const SelfCheckReport({
    required this.items,
    this.url,
    this.tips = const <String>[],
  });

  final List<SelfCheckItem> items;

  /// 给用户复制的完整地址（带 `http://` 和完整 token）。
  final String? url;

  /// 针对**当前结果**给出的下一步建议（不是通用套话）。
  final List<String> tips;

  bool get allOk => items.every((i) => i.ok || i.warn);

  /// 有没有"致命"项没过。
  bool get hasFailure => items.any((i) => !i.ok && !i.warn);
}

/// 自检的**判定逻辑**（纯函数，可单测）。
///
/// 输入是"探测到的原始事实"，输出是人话结论。把判定与探测分开，
/// 是为了能在单测里覆盖 401 / 303 / 连不上 / 端口没听 这几种组合 ——
/// 真机上没法稳定复现。
SelfCheckReport evaluateSelfCheck({
  required bool forwardRunning,
  required int? forwardPort,
  required bool serverRunning,
  required int? serverPort,
  required String? host,
  required String token,
  required bool tcpOk,
  required int? tokenStatus,
  Object? tcpError,
}) {
  final items = <SelfCheckItem>[];
  final tips = <String>[];

  // ① 开关
  items.add(SelfCheckItem(
    label: '对外开关',
    ok: forwardRunning,
    detail: forwardRunning ? '已打开' : '关着 —— 先把它打开',
  ));
  if (!forwardRunning) {
    tips.add('先把上面的开关打开，等进度走完（首启约 40~80 秒）。');
    return SelfCheckReport(items: items, tips: tips);
  }

  // ② 监听端口
  items.add(SelfCheckItem(
    label: '监听端口',
    ok: forwardPort != null,
    detail: forwardPort == null ? '没有端口 —— 转发器没起来' : '端口 $forwardPort',
  ));
  if (forwardPort == null) {
    tips.add('转发器没起来：把开关关掉再打开一次；还不行就看「设置 → 关于」里的诊断日志。');
    return SelfCheckReport(items: items, tips: tips);
  }

  // ③ DSH 服务本身
  items.add(SelfCheckItem(
    label: 'DSH 服务（手机内）',
    ok: serverRunning,
    detail: serverRunning
        ? '运行中${serverPort == null ? '' : '（内部端口 $serverPort）'}'
        : '没在跑 —— 转发器会空转，电脑必然打不开',
  ));
  if (!serverRunning) {
    tips.add('DSH 服务没起来：先回首页发一条消息让它启动，再来看这里。');
  }

  // ④ 本地回环能不能连上（这一项失败 = 电脑必然连不上）
  items.add(SelfCheckItem(
    label: '本地回环',
    ok: tcpOk,
    detail: tcpOk
        ? '127.0.0.1:$forwardPort 连得上'
        : '127.0.0.1:$forwardPort 连不上${tcpError == null ? '' : '（$tcpError）'}',
  ));
  if (!tcpOk) {
    tips.add('手机自己都连不上自己：说明转发器进程已经死了 —— 关掉开关再打开。');
  }

  // ⑤ 带口令访问（最能定性的一项）
  if (tcpOk) {
    final status = tokenStatus;
    if (status == null) {
      items.add(const SelfCheckItem(
        label: '带口令访问',
        ok: false,
        detail: '请求没有回音（超时或连接被重置）',
      ));
      tips.add('端口在听但请求没回来：DSH 可能还在启动，等 10 秒再试。');
    } else if (status == 303 || status == 302) {
      items.add(SelfCheckItem(
        label: '带口令访问',
        ok: true,
        detail: '返回 $status（正常：会写 cookie 并跳转）',
      ));
    } else if (status == 401) {
      items.add(const SelfCheckItem(
        label: '带口令访问',
        ok: false,
        detail: '返回 401 —— 手机上这一层认为口令不对',
      ));
      tips.add('点一次面板上的「重置口令」，然后**重新复制**地址给电脑（旧地址会立刻失效）。');
    } else if (status == 200) {
      items.add(const SelfCheckItem(
        label: '带口令访问',
        ok: true,
        warn: true,
        detail: '返回 200（能连，但没走"口令换 cookie"那一步，可能已登录过）',
      ));
    } else {
      items.add(SelfCheckItem(
        label: '带口令访问',
        ok: false,
        detail: '返回 $status（预期是 303 或 401）',
      ));
      tips.add('这一层返回了意料之外的状态码：把这份结果截图发出来。');
    }
  }

  final url = (host != null && host.isNotEmpty)
      ? 'http://$host:$forwardPort/?token=$token'
      : null;

  if (url != null) {
    items.add(SelfCheckItem(
      label: '电脑要用的地址',
      ok: true,
      detail: url,
    ));
  }

  // ⑥ 电脑侧的三条（手机这边查不到，但必须提醒 —— 前三个反馈里两个栽在这）
  final broken = items.where((i) => !i.ok && !i.warn).length;
  if (broken == 0) {
    tips.add('手机这一侧全部正常。电脑还打不开的话，按这个顺序查：');
    tips.add('① 电脑上 ping 一下手机 IP —— 不通就是路由器开了「AP 隔离」或不在同一网段；');
    tips.add('② 地址必须带小写的 http://，不能用 https（Edge 会自动切成 https，要先关掉"自动切换到 HTTPS"）；');
    tips.add('③ 地址要整段粘贴，别手打 —— 少一个字符就变成"找不到主机"。');
  }

  return SelfCheckReport(items: items, url: url, tips: tips);
}

/// 真的跑一次自检（探测 → 交给 [evaluateSelfCheck] 判定）。
///
/// 判定部分在 [evaluateSelfCheck] 里（纯函数，可单测）；这里只负责"真的连一次"。
Future<SelfCheckReport> runSelfCheck({
  required bool forwardRunning,
  required int? forwardPort,
  required bool serverRunning,
  required int? serverPort,
  required String? host,
  required String token,
}) async {
  var tcpOk = false;
  int? status;
  Object? tcpError;

  if (forwardRunning && forwardPort != null) {
    try {
      final s = await Socket.connect('127.0.0.1', forwardPort,
          timeout: const Duration(seconds: 3));
      tcpOk = true;
      s.destroy();
    } catch (e) {
      tcpError = e;
    }
    if (tcpOk) {
      status = await _tokenProbe(forwardPort, token);
    }
  }

  return evaluateSelfCheck(
    forwardRunning: forwardRunning,
    forwardPort: forwardPort,
    serverRunning: serverRunning,
    serverPort: serverPort,
    host: host,
    token: token,
    tcpOk: tcpOk,
    tokenStatus: status,
    tcpError: tcpError,
  );
}

/// 带 token 访问一次，**看状态码本身**（不跟随跳转）。
Future<int?> _tokenProbe(int port, String token) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..findProxy = ((_) => 'DIRECT');
  try {
    final uri = Uri.parse('http://127.0.0.1:$port/?token=$token');
    final req = await client.getUrl(uri);
    req.followRedirects = false; // 关键：要看到 303 本身，而不是跟到首页
    final resp = await req.close();
    final code = resp.statusCode;
    await resp.drain<void>();
    return code;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 自检结果对话框。
class ComputerAccessSelfCheckDialog extends StatelessWidget {
  const ComputerAccessSelfCheckDialog({super.key, required this.report});

  final SelfCheckReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(context.tr('连通性自检')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final it in report.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      it.warn
                          ? Icons.warning_amber_rounded
                          : (it.ok ? Icons.check_circle : Icons.error),
                      size: 16,
                      color: it.warn
                          ? Colors.orange
                          : (it.ok ? scheme.primary : scheme.error),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${context.tr(it.label)}：${it.detail}',
                        style: const TextStyle(fontSize: 12.5, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            if (report.tips.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Divider(height: 18, color: scheme.outlineVariant),
              for (final tip in report.tips)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    context.tr(tip),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('知道了')),
        ),
      ],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
      ),
    );
  }
}
