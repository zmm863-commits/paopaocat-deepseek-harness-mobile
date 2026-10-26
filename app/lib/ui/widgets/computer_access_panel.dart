import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../i18n/dsh_i18n.dart';
import '../../local/bot_server.dart';
import '../../local/dsh_runtime.dart';
import '../../local/lan_endpoints.dart';
import '../theme/dsh_tokens.dart';

/// 「电脑访问」面板：把手机上的 DSH 网页服务绑到某张网卡，让电脑用浏览器直接打开。
///
/// ## 这个面板解决什么（2026-10-26 用户提出）
///
/// 目标是「手机当移动电脑」：一根线（或同一个网络）连到任意一台电脑，电脑
/// **不装任何客户端**，浏览器打开一个网址就能开发 —— 资料、模型调用、工具执行
/// 全在手机上。
///
/// ## 为什么绑的是网卡，而不是「0.0.0.0」
///
/// `dsh --profile web --help` 明确写着 wildcard 地址会被拒绝，`--host` 只能是
/// 某一个本地接口的 IPv4/IPv6 字面量。所以必须先把候选网卡枚举出来让用户选
/// （见 [LanEndpoints]），再把地址传进启动参数。
///
/// ## ⚠️ 换绑定地址 = 重启 DSH 进程
///
/// `--host` 是启动参数，改不了热绑定。开关一拨就要重启 web 服务，Bot 页的
/// WebView 会短暂断开（[BotServer.live] 会通知它新地址并重连）。
class ComputerAccessPanel extends StatefulWidget {
  const ComputerAccessPanel({super.key, required this.runtime});

  final DshRuntime runtime;

  @override
  State<ComputerAccessPanel> createState() => _ComputerAccessPanelState();
}

class _ComputerAccessPanelState extends State<ComputerAccessPanel> {
  List<LanEndpoint> _lan = const [];
  String? _selected;
  String? _url;
  String? _error;
  String? _note;
  bool _busy = false;
  bool _on = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final eps = await LanEndpoints.list();
    if (!mounted) return;
    setState(() {
      _lan = eps;
      final keep = _selected != null && eps.any((e) => e.address == _selected);
      if (!keep) _selected = eps.isEmpty ? null : eps.first.address;
      // 服务可能已经在别处起来了（例如进过 Bot 页）：把它真实的绑定状态显示出来，
      // 否则用户会看到"开关是关的，但电脑其实连得上"。
      final cur = BotServer.current;
      if (cur != null && cur.listenHost != null) {
        _on = true;
        _url = cur.url;
      }
    });
  }

  Future<void> _apply({required bool on}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      if (on) {
        final host = _selected;
        if (host == null) {
          throw StateError(context.tr(
              '没找到可用网卡。先在系统里打开「USB 网络共享」，或连上同一个 Wi-Fi，再点刷新。'));
        }
        final server = await BotServer.ensureStarted(
          runtime: widget.runtime,
          listenHost: host,
        );
        if (!mounted) return;
        setState(() {
          _url = server.url;
          _on = server.listenHost != null;
          if (!_on) {
            _error = context.tr(
                '这个运行时版本不支持对外监听（不认识 --host），已退回本机模式。');
          }
        });
      } else {
        if (BotServer.current == null) {
          if (!mounted) return;
          setState(() {
            _on = false;
            _url = null;
          });
          return;
        }
        await BotServer.ensureStarted(runtime: widget.runtime, listenHost: null);
        if (!mounted) return;
        setState(() {
          _on = false;
          _url = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.computer_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.tr('让电脑用浏览器打开手机上的 DSH'),
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
            if (_busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Switch(value: _on, onChanged: (v) => _apply(on: v)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          context.tr(
              '资料、模型、工具执行都在手机上，电脑只需要一个浏览器。手机和电脑要在同一张网里（USB 网络共享或同一个 Wi-Fi）。'),
          style: TextStyle(fontSize: 11, color: scheme.outline, height: 1.55),
        ),
        const SizedBox(height: 10),
        if (_lan.isEmpty)
          Text(
            context.tr('没找到可用网卡。打开「USB 网络共享」或连上 Wi-Fi 后点刷新。'),
            style: TextStyle(fontSize: 11.5, color: scheme.error, height: 1.5),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: scheme.outlineVariant, width: 0.8),
            ),
            child: DropdownButton<String>(
              value: _selected,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              style: TextStyle(fontSize: 12, color: scheme.onSurface),
              items: <DropdownMenuItem<String>>[
                for (final e in _lan)
                  DropdownMenuItem<String>(
                    value: e.address,
                    child:
                        Text(e.display, style: const TextStyle(fontSize: 12)),
                  ),
              ],
              // 已经绑着的时候不让改：改要重启服务，先关掉开关更不容易懵。
              onChanged: _on
                  ? null
                  : (v) => setState(() {
                        _selected = v;
                        _note = null;
                      }),
            ),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            TextButton.icon(
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(context.tr('刷新网卡'),
                  style: const TextStyle(fontSize: 12)),
            ),
            const Spacer(),
            if (_on && _url != null)
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _url!));
                  if (!mounted) return;
                  setState(() => _note = context.tr('网址已复制'));
                },
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: Text(context.tr('复制网址'),
                    style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
        if (_on && _url != null) ...[
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
            ),
            child: SelectableText(
              _url!,
              style: const TextStyle(
                  fontSize: 11.5, height: 1.5, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('这个网址带身份凭证（token），别发给别人。'),
            style:
                TextStyle(fontSize: 10.5, color: scheme.outline, height: 1.5),
          ),
        ],
        if (_note != null) ...[
          const SizedBox(height: 6),
          Text(_note!, style: TextStyle(fontSize: 11, color: scheme.outline)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!,
              style: TextStyle(
                  fontSize: 11, color: scheme.error, height: 1.55)),
        ],
      ],
    );
  }
}
