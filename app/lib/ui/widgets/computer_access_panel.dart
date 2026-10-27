import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../i18n/dsh_i18n.dart';
import '../../local/bot_server.dart';
import '../../local/dsh_runtime.dart';
import '../../local/lan_endpoints.dart';
import '../../local/port_forwarder.dart';
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
      // 转发器可能已经在跑（离开页面再进来）：把真实状态显示出来，
      // 否则用户会看到"开关是关的，但电脑其实连得上"。
      if (PortForwarder.instance.running) {
        _on = true;
        final cur = BotServer.current;
        final fwd = PortForwarder.instance.port;
        if (cur != null && fwd != null && _selected != null) {
          final token = Uri.parse(cur.url).queryParameters['token'] ?? '';
          _url = 'http://$_selected:$fwd/'
              '${token.isEmpty ? '' : '?token=$token'}';
        }
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
        // ⚠️ 关键：**不要让 DSH 绑网卡**（2026-10-26 真机结论）。
        //    `dsh-web-app 0.1.7-rc.2` 一旦绑非回环地址，它自己的内部插件
        //    （file-upload / ui-deliverables / sessionController）就再也连不上
        //    "自己"，整个 profile 激活失败、进程退出码 1。
        //    所以 DSH 继续绑 127.0.0.1，App 在对外端口上开一个转发。
        //
        // ⚠️⚠️ 第二个坑（2026-10-27）：**必须先定转发端口，再起 DSH**。
        //    浏览器是拿 `网卡地址:转发端口` 访问的，而 DSH 自认为绑在回环上 ——
        //    它的 browser-trust fence 会把所有 `/api/*` 以 **403** 拒掉
        //    （真机实测：directoryPicker/list、llm/listProviders 全 403，
        //    表现为「工作区选不出来 + 模型列表加载失败 + 暂无会话」）。
        //    要让它放行，就得在**启动参数**里带上 `--trusted-host <地址:端口>`，
        //    而那是启动参数、改不了热 —— 所以顺序只能是：挑端口 → 带信任启动 → 开转发。
        final fwdPort = await PortForwarder.instance.reservePort();
        final authority = '$host:$fwdPort';
        final server = await BotServer.ensureStarted(
          runtime: widget.runtime,
          trustedAuthorities: <String>[authority],
        );
        if (!mounted) return;
        await PortForwarder.instance.start(
          targetPort: server.port,
          listenPort: fwdPort,
        );
        final token = Uri.parse(server.url).queryParameters['token'] ?? '';
        final url = 'http://$host:$fwdPort/${token.isEmpty ? '' : '?token=$token'}';
        if (!mounted) return;
        setState(() {
          _url = url;
          _on = true;
        });
      } else {
        await PortForwarder.instance.stop();
        // 关掉时也要把信任白名单清掉，否则下次起服务还带着旧 authority
        // （端口会变，留着没用还多一次重启）。
        await BotServer.ensureStarted(
          runtime: widget.runtime,
          trustedAuthorities: const <String>[],
        );
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
