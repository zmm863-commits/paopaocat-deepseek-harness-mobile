import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';
import '../../state/app_settings.dart';
import '../../local/dsh_runtime.dart';
import '../../local/phone_agent_bridge.dart';
import '../../local/diagnostics_log.dart';
import 'phone_agent_console_page.dart';
import 'dart:convert';

/// 设置页「屏幕助手」卡片：这个功能在 App 里唯一的门面。
///
/// ## 为什么它在这里（2026-10-22 用户问「这个功能放在 APP 的哪个位置」）
///
/// 这个能力的**主交互根本不在 App 里**——用户只在会话里说「帮我看今日头条」，
/// Agent 自己去调截图/点击。所以：
///   * **不放首页**：那里是能力入口（技能卡），这里不是"技能"，是权限+开关；
///   * **不加底部页签**：六页签是硬约束，为一行开关扩一页不值得；
///   * **放设置 → 应用**：和「手机权限」是同一类东西——一次性授权 + 平时不用管。
///
/// 卡片三态：
///   ① 无障碍没开 → 红提示 + 「去开启」按钮（跳系统无障碍设置页）；
///   ② 开了、桥在跑 → 绿状态 + 当前前台包名；
///   ③ 桥没起来 → 灰提示 + 尝试重启按钮。
class PhoneAgentSettingsSection extends StatefulWidget {
  const PhoneAgentSettingsSection({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<PhoneAgentSettingsSection> createState() =>
      _PhoneAgentSettingsSectionState();
}

class _PhoneAgentSettingsSectionState extends State<PhoneAgentSettingsSection> {
  PhoneAgentStatus? _status;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_checking) return;
    _checking = true;
    try {
      // 桥可能压根没起来（例如启动那次失败）——补拉一次，失败勿抛。
      if (!PhoneAgentBridge.instance.running) {
        try {
          await PhoneAgentBridge.instance.start();
        } catch (_) {/* 起不来就如实显示 */}
      }
      final PhoneAgentStatus st = await PhoneAgentBridge.instance.status();
      if (mounted) setState(() => _status = st);
    } finally {
      _checking = false;
    }
  }

  /// 读 filesDir/phone-agent.json（Android 侧落盘的 端口+令牌）——
  /// 给用户"Agent 从哪拿钥匙"的完成度展示。读不到就说明还没写出来。
  Future<({int port, String token})?> _readKeyFile() async {
    try {
      final Map<Object?, Object?>? raw =
          await DshHost.channel.invokeMethod<Map<Object?, Object?>>(
              'readPhoneAgentInfo');
      if (raw == null) return null;
      final num? port = raw['port'] as num?;
      final String? token = raw['token'] as String?;
      if (port == null || token == null || token.isEmpty) return null;
      return (port: port.toInt(), token: token);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final PhoneAgentStatus? st = _status;
    final bool connected = st?.connected ?? false;
    final Color stateColor = connected
        ? DshColors.ok
        : (st == null ? DshColors.textFaint : DshColors.err);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(width: 7, height: 7,
              decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                connected
                    ? context.tr('屏幕助手已开启，Agent 可以看屏幕、点屏幕')
                    : (st?.hint ?? context.tr('正在检查…')),
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          context.tr('在会话里直接说「帮我看当前屏幕 / 帮我打开某应用」即可使用；'
              '助手只在你下达指令时操作界面，不会自行乱点。'),
          style: TextStyle(color: DshColors.textDim, fontSize: 11.5, height: 1.5),
        ),
        const SizedBox(height: 10),
        // 2026-10-24：「免装 Shizuku」通道 —— 用无线调试配对，自己把引擎起在 shell 里
        _VdShellBlock(),
        const SizedBox(height: 10),
        // 2026-10-24：把「后台操作台」摆在这里 —— 用户要在 App 里**亲眼确认**
        // 虚拟屏建没建起来、画面对不对、点得中不中，而不是只能靠会话里猜。
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
          icon: const Icon(Icons.desktop_windows_outlined, size: 18),
          label: Text(context.tr('打开后台操作台（虚拟屏 + 实时画面）')),
          onPressed: () => PhoneAgentConsolePage.open(context),
        ),
        const SizedBox(height: 12),
        if (!connected)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
            icon: const Icon(Icons.security, size: 18),
            label: Text(context.tr('去授权 Shizuku')),
            onPressed: () async {
              try {
                await DshHost.channel
                    .invokeMethod<bool>('shizukuRequestPermission');
              } catch (e) {
                DiagnosticsLog.add('dsh-phone-agent', '申请 Shizuku 授权失败：$e');
              }
            },
          )
        else
          OutlinedButton.icon(
            icon: const Icon(Icons.verified_outlined, size: 18),
            label: Text(context.tr('重新检查状态')),
            onPressed: _refresh,
          ),
        if (connected) ...<Widget>[
          const SizedBox(height: 10),
          // ── 总开关（用户 2026-10-22：「是不是加个应用开关」）────────────
          // 这是安全闸：关了 Node 侧读到 enabled:false，技能据此拒调。
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeTrackColor: DshColors.accent,
            secondary: Icon(Icons.screen_search_desktop_outlined,
                size: 20, color: DshColors.accent),
            title: Text(
              context.tr('允许 Agent 操作手机界面'),
              style: TextStyle(color: DshColors.text, fontSize: 13.5),
            ),
            subtitle: Text(
              context.tr('截图 / 点击 / 滑动 / 打开下面的应用。关闭后 Agent 会拒绝此类请求。'),
              style: TextStyle(color: DshColors.textDim, fontSize: 11, height: 1.35),
            ),
            value: widget.settings.phoneAgentEnabled,
            onChanged: (bool v) async {
              await widget.settings.setPhoneAgentEnabled(v);
              await PhoneAgentBridge.instance.recordEnabled(v);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 4),
          _AppPicker(enabled: widget.settings.phoneAgentEnabled),
          const SizedBox(height: 2),
          FutureBuilder<({int port, String token})?>(
            future: _readKeyFile(),
            builder: (BuildContext c, AsyncSnapshot<({int port, String token})?> snap) {
              final ({int port, String token})? k = snap.data;
              return Text(
                k == null
                    ? context.tr('桥未就绪（重启 App 会自动再拉起）')
                    : context.tr('桥已就绪：127.0.0.1:{0}（Agent 从 phone-agent.json 拿钥匙）', <Object>[k.port]),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.4),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// 手机里的应用：搜索 + 点按启动（用户点名「帮我打开 X」时的图形兜底）。
/// 列表**先点「载入应用列表」再拉**——枚举全机应用要几十毫秒，不该在卡片展开时偷偷做。
class _AppPicker extends StatefulWidget {
  const _AppPicker({required this.enabled});

  final bool enabled;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  List<({String label, String pkg, bool system})> _apps =
      const <({String label, String pkg, bool system})>[];
  bool _loading = false;
  String? _error;
  final TextEditingController _search = TextEditingController();
  String? _lastOpened;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final String? raw = await PhoneAgentBridge.instance.listApps();
      if (raw == null) {
        if (mounted) setState(() => _error = '拉不到应用清单（详见运行日志）');
        return;
      }
      final List<dynamic> arr = jsonDecode(raw) as List<dynamic>;
      final List<({String label, String pkg, bool system})> list =
          <({String label, String pkg, bool system})>[
        for (final Map<String, dynamic> o in arr.cast<Map<String, dynamic>>())
          (
            label: o['label']?.toString() ?? '',
            pkg: o['package']?.toString() ?? '',
            system: o['system'] == true,
          ),
      ];
      list.sort((a, b) => a.label.compareTo(b.label));
      if (mounted) {
        setState(() {
          _apps = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '解析失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          context.tr('打开总开关后，在这里选择要交给 Agent 操作的应用。'),
          style: TextStyle(color: DshColors.textFaint, fontSize: 11.5, height: 1.4),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              context.tr('手机里的应用'),
              style: TextStyle(color: DshColors.text, fontSize: 12.5,
                  fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (_apps.isNotEmpty)
              Text(
                context.tr('{0} 个', <Object>[_apps.length]),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11),
              ),
            TextButton(
              onPressed: _loading ? null : _load,
              child: Text(_loading ? '…' : (_apps.isEmpty ? context.tr('载入应用列表')
                  : context.tr('刷新'))),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(_error!, style: TextStyle(color: DshColors.err, fontSize: 11)),
          ),
        if (_apps.isNotEmpty) ...<Widget>[
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            style: TextStyle(color: DshColors.text, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18, color: DshColors.textDim),
              hintText: context.tr('搜索应用名'),
            ),
          ),
          const SizedBox(height: 6),
          ..._buildRows(),
          if (_lastOpened != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.tr('已在前台打开「{0}」。想让它跑到后台虚拟屏里 → 用上面的「后台操作台」。',
                    <Object>[_lastOpened!]),
                style: TextStyle(color: DshColors.ok, fontSize: 11.5, height: 1.4),
              ),
            ),
        ],
      ],
    );
  }

  List<Widget> _buildRows() {
    final String q = _search.text.trim().toLowerCase();
    final List<({String label, String pkg, bool system})> shown = _apps
        .where((a) => q.isEmpty || a.label.toLowerCase().contains(q))
        .take(8)
        .toList();
    return <Widget>[
      for (final a in shown)
        InkWell(
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          onTap: () async {
            final bool ok = await PhoneAgentBridge.instance.launchApp(a.pkg);
            if (mounted) {
              setState(() => _lastOpened = ok ? a.label : null);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: DshColors.surface,
              borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
              border: Border.all(color: DshColors.line, width: DshMetrics.borderWidth),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.apps, size: 16, color: DshColors.accent),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    a.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: DshColors.text, fontSize: 13),
                  ),
                ),
                if (a.system)
                  Text(context.tr('系统'),
                      style: TextStyle(color: DshColors.textFaint, fontSize: 10)),
                Icon(Icons.open_in_new, size: 14, color: DshColors.textFaint),
              ],
            ),
          ),
        ),
      if (_apps.length > shown.length)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            context.tr('只显示搜索结果前 {0} 条；继续输入缩小范围', <Object>[shown.length]),
            style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
          ),
        ),
    ];
  }
}


/// 「免装 Shizuku」：用无线调试配对，把引擎 dex 起在 shell 身份里。
///
/// 用户侧只有两步：① 打开「无线调试」拿到 6 位配对码；② 填进来点一下。
/// 之后引擎一直在跑（App 重启后重来一次即可，配对关系本身是持久的）。
class _VdShellBlock extends StatefulWidget {
  @override
  State<_VdShellBlock> createState() => _VdShellBlockState();
}

class _VdShellBlockState extends State<_VdShellBlock> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _port = TextEditingController();
  bool _busy = false;
  bool _alive = false;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _code.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    final Map<String, dynamic>? st =
        await PhoneAgentBridge.instance.vdshellStatus();
    if (!mounted || st == null) return;
    setState(() {
      _alive = st['binderAlive'] == true;
      final String err = st['error']?.toString() ?? '';
      if (!_alive && err.isNotEmpty) _msg = err;
    });
  }

  Future<void> _openSettings() async {
    try {
      await DshHost.channel.invokeMethod<bool>('openWirelessDebuggingSettings');
    } catch (e) {
      DiagnosticsLog.add('dsh-phone-agent', '打开开发者选项失败：$e');
    }
  }

  Future<void> _pairAndStart() async {
    if (_busy) return;
    final String code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _msg = '配对码是 6 位数字（在「使用配对码配对设备」里看）');
      return;
    }
    setState(() {
      _busy = true;
      _msg = '正在配对…';
    });
    final int? port = int.tryParse(_port.text.trim());
    final bool ok = await PhoneAgentBridge.instance.vdshellPair(code, port: port);
    if (!ok) {
      if (mounted) {
        setState(() {
          _busy = false;
          _msg = '配对失败：确认「无线调试」开着、配对码是最新的（60 秒会变）';
        });
      }
      return;
    }
    if (mounted) setState(() => _msg = '已配对，正在起引擎（约 3~10 秒）…');
    final ({bool ok, String error}) r =
        await PhoneAgentBridge.instance.vdshellBootstrap();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _alive = r.ok;
      _msg = r.ok ? '引擎已就绪 —— 现在去后台操作台建屏' : '启动失败：${r.error}';
    });
  }

  Future<void> _stop() async {
    await PhoneAgentBridge.instance.vdshellStop();
    if (!mounted) return;
    setState(() {
      _alive = false;
      _msg = '引擎已停止';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: DshColors.surfaceHigh,
        borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
        border: Border.all(color: DshColors.line, width: DshMetrics.borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                _alive ? Icons.bolt : Icons.bolt_outlined,
                size: 16,
                color: _alive ? DshColors.ok : DshColors.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  context.tr('免装 Shizuku（用无线调试自己起引擎）'),
                  style: TextStyle(
                    color: DshColors.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('不装 Shizuku 也能后台操作：打开「无线调试」，把配对码填进来，'
                'App 会用 adb 通道把引擎起在 shell 里。配对码 60 秒过期，用最新的那个。'),
            style: TextStyle(color: DshColors.textDim, fontSize: 11, height: 1.45),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(38),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            icon: const Icon(Icons.developer_mode, size: 16),
            label: Text(context.tr('打开「无线调试」设置页'),
                style: const TextStyle(fontSize: 12)),
            onPressed: _openSettings,
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: TextStyle(color: DshColors.text, fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: '',
                    labelText: context.tr('配对码'),
                    hintText: '6 位数字',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: DshColors.text, fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: context.tr('端口'),
                    hintText: context.tr('可留空'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(40),
                  ),
                  icon: Icon(_busy ? Icons.hourglass_top : Icons.play_arrow,
                      size: 18),
                  label: Text(
                    _busy ? context.tr('处理中…') : context.tr('配对并启动引擎'),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  onPressed: _busy ? null : _pairAndStart,
                ),
              ),
              if (_alive) ...<Widget>[
                const SizedBox(width: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(64, 40),
                  ),
                  onPressed: _stop,
                  child: Text(context.tr('停止'),
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
          if (_msg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                _msg,
                style: TextStyle(
                  color: _alive ? DshColors.ok : DshColors.textDim,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
