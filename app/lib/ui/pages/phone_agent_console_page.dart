import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/diagnostics_log.dart';
import '../../local/phone_agent_bridge.dart';
import '../../local/popup_dismiss.dart';
import '../theme/dsh_tokens.dart';

/// 「后台操作台」—— 屏幕助手的可视化面板。
///
/// ## 为什么要有这个页面（2026-10-24 用户要求）
///
/// 原来的屏幕助手只有 Agent 那条路：用户在会话里说「帮我点一下」，Agent 去调
/// HTTP 桥。设置页里只有开关和状态，**用户自己没法确认这套东西到底能不能用**
/// —— 建没建屏、屏里有没有画面、点了中不中，全是黑盒。
///
/// 这个页面把黑盒打开：建一块看不见的虚拟屏 → 把某个 App 拉进去 → 实时看画面
/// → 直接点/滑。自绘虚拟屏 + 定向注入的体验，
/// 底层用的还是本 App 已有的 `EngineService`（Shizuku shell 进程里跑）。
///
/// ## 三层门槛（页面按顺序引导）
///
/// 1. **Shizuku 授权** —— 没授权就没有 shell 身份，引擎起不来；
/// 2. **引擎连接** —— 授权前那次 bind 必然失败，所以要「重连引擎」；
/// 3. **建虚拟屏** —— 前两步都绿了才点得动。
class PhoneAgentConsolePage extends StatefulWidget {
  const PhoneAgentConsolePage({super.key});

  /// 从设置页推入（唯一入口）。
  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => const PhoneAgentConsolePage(),
    ));
  }

  @override
  State<PhoneAgentConsolePage> createState() => _PhoneAgentConsolePageState();
}

class _PhoneAgentConsolePageState extends State<PhoneAgentConsolePage> {
  /// 三个预设：桌面常见的 1080p / 720p / 竖屏小尺寸。
  static const List<({String label, int w, int h, int dpi})> _presets =
      <({String label, int w, int h, int dpi})>[
    (label: '1080×1920', w: 1080, h: 1920, dpi: 320),
    (label: '720×1280', w: 720, h: 1280, dpi: 240),
    (label: '1080×2400', w: 1080, h: 2400, dpi: 440),
  ];

  PhoneAgentHeadless? _info;
  Uint8List? _frame;

  /// 帧的像素尺寸（从 PNG header 直接读，不解码整张图）。
  (int, int)? _frameSize;

  List<({String label, String pkg})> _apps = const <({String label, String pkg})>[];
  bool _appsLoading = false;
  bool _polling = false;
  bool _busy = false;
  String? _note;
  int _preset = 0;
  Timer? _ticker;

  /// 拖动中的起止点（**必须是 State 字段**：每 0.5 秒来一帧就 setState，
  /// 局部变量会在重建时被清空，导致"拖到一半就断了"）。
  Offset? _dragStart;
  Offset? _dragLast;

  final TextEditingController _search = TextEditingController();

  /// 录制规则：开着时，点/滑/输入都被记成步骤（点会自动 OCR 转「点文字」锚点）。
  bool _recording = false;
  final List<Map<String, dynamic>> _steps = <Map<String, dynamic>>[];

  /// 预览是否放大（用户嫌默认 360 高太小，点不中）。放大后高度接近满屏。
  bool _zoomed = false;

  PhoneAgentBridge get _bridge => PhoneAgentBridge.instance;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _search.dispose();
    super.dispose();
  }

  // ── 启动与状态 ──────────────────────────────────────────────────────────

  Future<void> _boot() async {
    try {
      if (!_bridge.running) await _bridge.start();
    } catch (e) {
      DiagnosticsLog.add('dsh-phone-agent', '操作台：桥启动失败 $e');
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    final PhoneAgentHeadless? info = await _bridge.headlessInfo();
    if (!mounted) return;
    setState(() => _info = info);
    if (info?.hasDisplay == true) {
      _ticker ??= Timer.periodic(const Duration(milliseconds: 450), (_) {
        _pollFrame();
      });
      _pollFrame();
    } else {
      _ticker?.cancel();
      _ticker = null;
      if (mounted) setState(() => _frame = null);
    }
  }

  Future<void> _pollFrame() async {
    if (_polling) return;
    _polling = true;
    try {
      final Uint8List? png = await _bridge.screenshot();
      if (!mounted || png == null) return;
      final (int, int)? size = _pngSize(png);
      setState(() {
        _frame = png;
        if (size != null) _frameSize = size;
      });
    } finally {
      _polling = false;
    }
  }

  /// 直接读 PNG 的 IHDR 拿宽高（比 `decodeImageFromList` 省一次整图解码）。
  (int, int)? _pngSize(Uint8List b) {
    if (b.length < 24) return null;
    if (b[0] != 0x89 || b[1] != 0x50 || b[2] != 0x4E || b[3] != 0x47) {
      return null;
    }
    final int w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final int h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    if (w <= 0 || h <= 0) return null;
    return (w, h);
  }

  Future<void> _run(Future<String?> Function() job, String okText) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final String? r = await job();
      final bool ok = r != null && r.startsWith('OK');
      _toast(ok ? okText : (r ?? '引擎没响应'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  void _toast(String msg) {
    if (!mounted) return;
    setState(() => _note = msg);
  }

  // ── 三层门槛 ────────────────────────────────────────────────────────────

  Future<void> _authorize() async {
    await _bridge.requestShizukuPermission();
    _toast('已弹出授权框 —— 允许之后自动重连引擎');
    // 授权框是系统对话框，用户点完才回；给一拍再重绑。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await _reconnect();
  }

  Future<void> _reconnect() async {
    final bool ok = await _bridge.rebindEngine();
    // bindUserService 是异步的，等它连上再读状态。
    for (int i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final PhoneAgentHeadless? info = await _bridge.headlessInfo();
      if (info?.engineConnected == true) break;
    }
    await _refresh();
    _toast(ok ? '已重连引擎' : '重连失败：引擎客户端还没建好');
  }

  Future<void> _createDisplay() async {
    final ({String label, int w, int h, int dpi}) p = _presets[_preset];
    await _run(() => _bridge.createDisplay(w: p.w, h: p.h, dpi: p.dpi),
        '虚拟屏已创建');
  }

  Future<void> _releaseDisplay() async {
    await _run(_bridge.releaseDisplay, '虚拟屏已销毁');
  }

  Future<void> _launch(String pkg, String label) async {
    await _run(() => _bridge.launchOnDisplay(pkg), '已把「$label」拉到虚拟屏');
    // 冷启动要几百毫秒才出第一帧。
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await _pollFrame();
  }

  // ── 手势 → 坐标 ─────────────────────────────────────────────────────────

  /// 把预览框里的点换算成虚拟屏像素坐标（`BoxFit.contain` 的逆运算）。
  Offset? _toDisplay(Offset local, Size box) {
    final (int, int)? fs = _frameSize;
    if (fs == null || box.width <= 0 || box.height <= 0) return null;
    final double fw = fs.$1.toDouble();
    final double fh = fs.$2.toDouble();
    final double scale = (box.width / fw < box.height / fh)
        ? box.width / fw
        : box.height / fh;
    final double dw = fw * scale;
    final double dh = fh * scale;
    final double ox = (box.width - dw) / 2;
    final double oy = (box.height - dh) / 2;
    final double x = (local.dx - ox) / scale;
    final double y = (local.dy - oy) / scale;
    if (x < 0 || y < 0 || x > fw || y > fh) return null;
    return Offset(x, y);
  }

  Future<void> _tapAt(Offset local, Size box) async {
    final Offset? p = _toDisplay(local, box);
    if (p == null) return;
    final bool ok = await _bridge.tap(p.dx.round(), p.dy.round());
    _toast(ok
        ? '点了 (${p.dx.round()}, ${p.dy.round()})'
        : '点击失败：引擎没连上');
    if (_recording && ok) {
      // 录制：把「点的位置」转成「点的文字」（OCR 锚点），换手机也能用。
      final String? anchor = await _ocrAnchorAt(p.dx.round(), p.dy.round());
      if (!mounted) return;
      setState(() {
        _steps.add(anchor != null
            ? <String, dynamic>{'action': 'tapText', 'text': anchor}
            : <String, dynamic>{'action': 'tap', 'x': p.dx.round(), 'y': p.dy.round()});
      });
    }
  }

  /// 找离 (x,y) 最近的 OCR 文字块，作为「点文字」锚点；太远（纯图标）返回 null。
  /// 一键关弹窗：扫屏找「跳过/关闭/以后再说…」点掉（最多 3 轮）。
  Future<void> _dismissPopups() async {
    final int hit = await dismissPopups(_bridge, rounds: 3);
    if (!mounted) return;
    setState(() => _note = hit == 0 ? '当前画面没有弹窗' : '关掉了 $hit 个弹窗');
  }

  Future<String?> _ocrAnchorAt(int x, int y) async {
    final List<({String text, int cx, int cy})> lines = await _bridge.ocr();
    ({String text, int cx, int cy})? best;
    double bestD = double.infinity;
    for (final l in lines) {
      final double d = ((l.cx - x) * (l.cx - x) + (l.cy - y) * (l.cy - y)).toDouble();
      if (d < bestD) {
        bestD = d;
        best = l;
      }
    }
    if (best == null || best.text.isEmpty) return null;
    return bestD <= 90 * 90 ? best.text : null;
  }

  Future<void> _swipeFromTo(Offset a, Offset b, Size box) async {
    final Offset? p1 = _toDisplay(a, box);
    final Offset? p2 = _toDisplay(b, box);
    if (p1 == null || p2 == null) return;
    final bool ok = await _bridge.swipe(
        p1.dx.round(), p1.dy.round(), p2.dx.round(), p2.dy.round());
    _toast(ok ? '已滑动' : '滑动失败：引擎没连上');
    if (_recording && ok) {
      setState(() {
        _steps.add(<String, dynamic>{
          'action': 'swipe',
          'x1': p1.dx.round(), 'y1': p1.dy.round(),
          'x2': p2.dx.round(), 'y2': p2.dy.round(),
        });
      });
    }
  }

  Future<void> _sendKey(String action) async {
    final bool ok = await _bridge.sendKey(action);
    _toast(ok ? '已发送 $action' : '按键失败：引擎没连上');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _pollFrame();
  }

  Future<void> _inputText() async {
    final TextEditingController c = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(ctx.tr('往虚拟屏里输入文字')),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: ctx.tr('只支持英文/数字/符号')),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(c.text),
            child: Text(ctx.tr('输入')),
          ),
        ],
      ),
    );
    c.dispose();
    if (text == null || text.isEmpty) return;
    final bool ok = await _bridge.inputText(text);
    _toast(ok ? '已输入' : '输入失败');
    if (_recording && ok) {
      setState(() => _steps.add(<String, dynamic>{'action': 'input', 'text': text}));
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _pollFrame();
  }

  // ── 录制规则 ─────────────────────────────────────────────────────────

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _saveRecordedRule();
    } else {
      setState(() {
        _recording = true;
        _steps.clear();
      });
      _toast('录制中：点 / 滑 / 输入都会记成步骤，点「停止录制」保存');
    }
  }

  Future<void> _saveRecordedRule() async {
    if (_steps.isEmpty) {
      setState(() => _recording = false);
      _toast('没录到任何步骤');
      return;
    }
    final TextEditingController c = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(ctx.tr('给这条规则起个名')),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: ctx.tr('例如：淘宝比价')),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(c.text.trim()),
            child: Text(ctx.tr('保存')),
          ),
        ],
      ),
    );
    c.dispose();
    setState(() => _recording = false);
    if (name == null || name.isEmpty) return;
    final Map<String, dynamic> rule = <String, dynamic>{
      'name': name,
      'params': <dynamic>[],
      'steps': _steps,
    };
    final bool ok = await _bridge.saveRule(jsonEncode(rule));
    if (!mounted) return;
    _toast(ok ? '规则「$name」已保存（${_steps.length} 步）' : '保存失败');
  }

  // ── 应用列表 ────────────────────────────────────────────────────────────

  Future<void> _loadApps() async {
    if (_appsLoading) return;
    setState(() => _appsLoading = true);
    try {
      final String? raw = await _bridge.listApps();
      if (raw == null) {
        _toast('拉不到应用清单');
        return;
      }
      final List<dynamic> arr = jsonDecode(raw) as List<dynamic>;
      final List<({String label, String pkg})> list =
          <({String label, String pkg})>[
        for (final Map<String, dynamic> o in arr.cast<Map<String, dynamic>>())
          if ((o['package']?.toString() ?? '').isNotEmpty)
            (
              label: o['label']?.toString() ?? o['package'].toString(),
              pkg: o['package'].toString(),
            ),
      ]..sort((a, b) => a.label.compareTo(b.label));
      if (mounted) setState(() => _apps = list);
    } catch (e) {
      _toast('解析应用清单失败：$e');
    } finally {
      if (mounted) setState(() => _appsLoading = false);
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final PhoneAgentHeadless? info = _info;
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(
        backgroundColor: DshColors.bg,
        elevation: 0,
        title: Text(
          context.tr('后台操作台'),
          style: TextStyle(color: DshColors.text, fontSize: 16),
        ),
        iconTheme: IconThemeData(color: DshColors.text),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            DshMetrics.pagePad, 4, DshMetrics.pagePad, 28),
        children: <Widget>[
          _statusCard(info),
          const SizedBox(height: DshMetrics.cardGap),
          _recordBar(),
          const SizedBox(height: DshMetrics.cardGap),
          _displayCard(info),
          const SizedBox(height: DshMetrics.cardGap),
          _previewCard(info),
          const SizedBox(height: DshMetrics.cardGap),
          _appCard(info),
          if (_note != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _note!,
              style: TextStyle(color: DshColors.textDim, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _recordBar() {
    return _box(
      child: Row(
        children: <Widget>[
          Icon(
            _recording ? Icons.fiber_manual_record : Icons.video_camera_back_outlined,
            size: 16,
            color: _recording ? DshColors.err : DshColors.accent,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _recording
                  ? '录制中（${_steps.length} 步）—— 点 / 滑 / 输入都会记下来'
                  : '录制规则：点一遍操作，存成可回放、可分享的规则',
              style: TextStyle(color: DshColors.textDim, fontSize: 11.5),
            ),
          ),
          FilledButton(
            onPressed: _toggleRecording,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              backgroundColor: _recording ? DshColors.err : null,
            ),
            child: Text(
              _recording ? context.tr('停止录制') : context.tr('开始录制'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _box({required Widget child}) => Container(
        padding: const EdgeInsets.all(DshMetrics.cardPad),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(14)),
          border: Border.all(color: DshColors.line, width: DshMetrics.borderWidth),
        ),
        child: child,
      );

  Widget _statusCard(PhoneAgentHeadless? info) {
    final bool granted = info?.shizukuGranted ?? false;
    final bool connected = info?.engineConnected ?? false;
    final bool bridgeUp = _bridge.running;
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            context.tr('三步打开后台操作'),
            style: TextStyle(
              color: DshColors.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          _stepRow(1, context.tr('已激活（Shizuku 或免装配对）'), granted || connected),
          _stepRow(2, context.tr('引擎已连上（shell 进程）'), connected),
          _stepRow(3, context.tr('虚拟屏已创建'), info?.hasDisplay ?? false),
          if (!bridgeUp)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                context.tr('本机操作桥没起来 —— 退出本页重进会自动拉起'),
                style: TextStyle(color: DshColors.err, fontSize: 11.5),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              if (!granted)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _authorize,
                    icon: const Icon(Icons.security, size: 18),
                    label: Text(context.tr('去授权 Shizuku')),
                  ),
                ),
              if (granted && !connected)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _reconnect,
                    icon: const Icon(Icons.link, size: 18),
                    label: Text(context.tr('重连引擎')),
                  ),
                ),
              if (granted && connected)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(context.tr('刷新状态')),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            info?.hint ?? context.tr('正在检查…'),
            style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _stepRow(int n, String label, bool done) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: <Widget>[
            Icon(
              done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: done ? DshColors.ok : DshColors.textFaint,
            ),
            const SizedBox(width: 8),
            Text('$n.', style: TextStyle(color: DshColors.textFaint, fontSize: 12)),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: done ? DshColors.text : DshColors.textDim,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _displayCard(PhoneAgentHeadless? info) {
    final bool canCreate = info?.engineConnected == true;
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            context.tr('虚拟屏'),
            style: TextStyle(
              color: DshColors.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (int i = 0; i < _presets.length; i++)
                ChoiceChip(
                  label: Text(_presets[i].label,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: _preset == i ? DshColors.onAccent : DshColors.textDim,
                      )),
                  selected: _preset == i,
                  selectedColor: DshColors.accent,
                  backgroundColor: DshColors.surfaceHigh,
                  onSelected: (_) => setState(() => _preset = i),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: (!canCreate || _busy) ? null : _createDisplay,
                  icon: const Icon(Icons.add_to_photos_outlined, size: 18),
                  label: Text(context.tr('创建虚拟屏')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (!(info?.hasDisplay ?? false) || _busy)
                      ? null
                      : _releaseDisplay,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(context.tr('销毁')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('虚拟屏是「看不见」的：目标 App 在里面跑，物理屏上什么都不显示。'),
            style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _previewCard(PhoneAgentHeadless? info) {
    final bool ready = info?.hasDisplay == true;
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                context.tr('实时画面'),
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                _frameSize == null
                    ? ''
                    : '${_frameSize!.$1}×${_frameSize!.$2}',
                style: TextStyle(color: DshColors.textFaint, fontSize: 11),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: ready ? () => setState(() => _zoomed = !_zoomed) : null,
                icon: Icon(_zoomed ? Icons.zoom_out_map : Icons.zoom_in_map,
                    size: 16),
                label: Text(_zoomed ? context.tr('缩小画面') : context.tr('放大画面'),
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: _zoomed
                ? MediaQuery.of(context).size.height * 0.72
                : 360,
            width: double.infinity,
            child: LayoutBuilder(
              builder: (BuildContext c, BoxConstraints cons) {
                final Size box = Size(cons.maxWidth, cons.maxHeight);
                return _previewBody(ready, box);
              },
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('点一下 = 在虚拟屏里点那个坐标；按住拖动 = 滑动。'
                '画面每 0.5 秒刷新一次。'),
            style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              _miniBtn(Icons.arrow_back, context.tr('返回'), 'back', ready),
              _miniBtn(Icons.home_outlined, context.tr('主屏'), 'home', ready),
              _miniBtn(Icons.apps, context.tr('最近任务'), 'recents', ready),
              OutlinedButton.icon(
                onPressed: ready ? _inputText : null,
                icon: const Icon(Icons.keyboard, size: 16),
                label: Text(context.tr('输入文字'),
                    style: const TextStyle(fontSize: 12)),
              ),
              OutlinedButton.icon(
                onPressed: ready ? _dismissPopups : null,
                icon: const Icon(Icons.close, size: 16),
                label: Text(context.tr('关弹窗'),
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniBtn(IconData icon, String label, String action, bool enabled) {
    return OutlinedButton.icon(
      onPressed: enabled ? () => _sendKey(action) : null,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _previewBody(bool ready, Size box) {
    if (!ready) {
      return Center(
        child: Text(
          context.tr('先建一块虚拟屏，这里就会出现画面'),
          style: TextStyle(color: DshColors.textFaint, fontSize: 12),
        ),
      );
    }
    final Uint8List? frame = _frame;
    if (frame == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: DshColors.accent,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              context.tr('等第一帧…（把 App 拉到虚拟屏后才有画面）'),
              style: TextStyle(color: DshColors.textFaint, fontSize: 11.5),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (TapUpDetails d) => _tapAt(d.localPosition, box),
      onPanStart: (DragStartDetails d) => _dragStart = d.localPosition,
      onPanUpdate: (DragUpdateDetails d) => _dragLast = d.localPosition,
      onPanEnd: (DragEndDetails d) {
        final Offset? a = _dragStart;
        final Offset? b = _dragLast;
        if (a != null && b != null && (b - a).distance > 24) {
          _swipeFromTo(a, b, box);
        }
        _dragStart = null;
        _dragLast = null;
      },
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.memory(
            frame,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          ),
          // 贴一个「点这里」的提示层，避免用户以为这是张静态图。
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: DshColors.bg.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
              ),
              child: Text(
                context.tr('可点 / 可拖'),
                style: TextStyle(color: DshColors.textDim, fontSize: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _appCard(PhoneAgentHeadless? info) {
    final bool ready = info?.hasDisplay == true;
    final String q = _search.text.trim().toLowerCase();
    final List<({String label, String pkg})> shown = _apps
        .where((a) => q.isEmpty || a.label.toLowerCase().contains(q))
        .toList();
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                context.tr('在虚拟屏里打开'),
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _appsLoading ? null : _loadApps,
                child: Text(_appsLoading
                    ? '…'
                    : (_apps.isEmpty
                        ? context.tr('载入应用列表')
                        : context.tr('刷新'))),
              ),
            ],
          ),
          if (_apps.isNotEmpty) ...<Widget>[
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: TextStyle(color: DshColors.text, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon:
                    Icon(Icons.search, size: 18, color: DshColors.textDim),
                hintText: context.tr('搜索应用名'),
              ),
            ),
            const SizedBox(height: 6),
            for (final a in shown)
              InkWell(
                borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
                onTap: ready ? () => _launch(a.pkg, a.label) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.apps, size: 15,
                          color: ready ? DshColors.accent : DshColors.textFaint),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          a.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: ready ? DshColors.text : DshColors.textFaint,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Text(
                        context.tr('拉到虚拟屏'),
                        style: TextStyle(
                            color: DshColors.textFaint, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ),
            Text(
              context.tr('共 {0} 个应用', <Object>[shown.length]),
              style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
            ),
          ] else
            Text(
              context.tr('先把虚拟屏建起来，再点「载入应用列表」选一个 App 拉进去。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11.5, height: 1.4),
            ),
        ],
      ),
    );
  }
}
