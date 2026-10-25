import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../local/phone_agent_bridge.dart';
import '../theme/dsh_tokens.dart';
import '../../i18n/dsh_i18n.dart';

/// 泡泡猫规则库：列出用户录的规则，支持复制分享（导出 JSON）、粘贴导入、删除。
///
/// 规则就是一个 JSON（`{name, params, steps}`），用户录完规则后把 JSON 复制出来，
/// 发给别人；别人在这里粘贴导入，就能用同一套「OCR 锚定的操作脚本」。
class PhoneAgentRulesPage extends StatefulWidget {
  const PhoneAgentRulesPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => const PhoneAgentRulesPage(),
    ));
  }

  @override
  State<PhoneAgentRulesPage> createState() => _PhoneAgentRulesPageState();
}

class _PhoneAgentRulesPageState extends State<PhoneAgentRulesPage> {
  List<Map<String, dynamic>> _rules = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _note;
  bool _running = false;
  String _runMsg = '';

  PhoneAgentBridge get _bridge => PhoneAgentBridge.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final String? raw = await _bridge.listRules();
    if (!mounted) return;
    setState(() {
      _rules = <Map<String, dynamic>>[];
      if (raw != null && raw.isNotEmpty) {
        try {
          final List<dynamic> arr = jsonDecode(raw) as List<dynamic>;
          _rules = arr.whereType<Map<String, dynamic>>().toList();
        } catch (_) {}
      }
      _loading = false;
    });
  }

  Future<void> _copy(Map<String, dynamic> rule) async {
    await Clipboard.setData(ClipboardData(text: jsonEncode(rule)));
    if (!mounted) return;
    setState(() => _note = '规则「${rule['name']}」的 JSON 已复制，发给别人即可');
  }

  // ── 执行规则（回放：虚拟屏里 OCR 找文字 → 点击）────────────────────

  Future<void> _runRule(Map<String, dynamic> rule) async {
    if (_running) return;
    final PhoneAgentHeadless? info = await _bridge.headlessInfo();
    if (info == null || !info.engineConnected) {
      setState(() => _note = '引擎没起 —— 先去「泡泡猫助手」配对启动引擎，再执行');
      return;
    }
    final List<dynamic> steps = (rule['steps'] as List<dynamic>?) ?? <dynamic>[];
    setState(() {
      _running = true;
      _runMsg = '开始执行「${rule['name']}」（${steps.length} 步）…';
    });
    for (int i = 0; i < steps.length; i++) {
      if (!mounted) return;
      final Map<String, dynamic> step =
          (steps[i] as Map).cast<String, dynamic>();
      final String action = (step['action'] ?? '').toString();
      setState(() => _runMsg = '第 ${i + 1}/${steps.length} 步：$action');
      final bool ok = await _runStep(step);
      if (!ok) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _runMsg = '第 ${i + 1} 步失败（$action）';
        });
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _runMsg = '「${rule['name']}」执行完成';
    });
  }

  Future<bool> _runStep(Map<String, dynamic> step) async {
    final String action = (step['action'] ?? '').toString();
    if (action == 'launch') {
      final String? r = await _bridge.launchOnDisplay(step['pkg'].toString());
      return r != null && r.startsWith('OK');
    } else if (action == 'waitText') {
      return await _waitText(step['text'].toString(),
          (step['timeout'] as num?)?.toInt() ?? 8000);
    } else if (action == 'tapText') {
      final (int, int)? pos = await _findText(step['text'].toString());
      if (pos == null) return false;
      return await _bridge.tap(pos.$1, pos.$2);
    } else if (action == 'input') {
      return await _bridge.inputText(step['text'].toString());
    } else if (action == 'tap') {
      return await _bridge.tap(
          (step['x'] as num).toInt(), (step['y'] as num).toInt());
    } else if (action == 'swipe') {
      return await _bridge.swipe(
        (step['x1'] as num).toInt(), (step['y1'] as num).toInt(),
        (step['x2'] as num).toInt(), (step['y2'] as num).toInt(),
      );
    } else if (action == 'waitMs') {
      await Future<void>.delayed(
          Duration(milliseconds: (step['ms'] as num?)?.toInt() ?? 1000));
      return true;
    } else if (action == 'key') {
      return await _bridge.sendKey(step['key'].toString());
    } else if (action == 'collectPrices') {
      final List<({String text, int cx, int cy})> lines = await _bridge.ocr();
      final RegExp re = RegExp(r'[¥￥]\s*(\d+(?:\.\d+)?)');
      final List<double> prices = <double>[];
      for (final l in lines) {
        final RegExpMatch? m = re.firstMatch(l.text);
        if (m != null) prices.add(double.parse(m.group(1)!));
      }
      prices.sort();
      if (!mounted) return true;
      setState(() => _note = prices.isEmpty
          ? '没抓到价格'
          : '抓到 ${prices.length} 个价格，最低 ¥${prices.first}');
      return true;
    } else if (action == 'release') {
      await _bridge.releaseDisplay();
      return true;
    }
    return false;
  }

  Future<(int, int)?> _findText(String text) async {
    final List<({String text, int cx, int cy})> lines = await _bridge.ocr();
    for (final l in lines) {
      if (l.text.contains(text)) return (l.cx, l.cy);
    }
    return null;
  }

  Future<bool> _waitText(String text, int timeoutMs) async {
    final DateTime deadline =
        DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      final (int, int)? pos = await _findText(text);
      if (pos != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return false;
  }

  Future<void> _delete(Map<String, dynamic> rule) async {
    final String name = (rule['name'] ?? '').toString();
    final bool ok = await _bridge.deleteRule(name);
    if (!mounted) return;
    setState(() => _note = ok ? '已删除「$name」' : '删除失败');
    await _load();
  }

  Future<void> _import() async {
    final TextEditingController c = TextEditingController();
    final String? json = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(ctx.tr('粘贴规则 JSON')),
        content: TextField(
          controller: c,
          maxLines: 6,
          minLines: 4,
          decoration: InputDecoration(
            hintText: ctx.tr('把别人分享给你的规则 JSON 粘贴到这里'),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(c.text.trim()),
            child: Text(ctx.tr('导入')),
          ),
        ],
      ),
    );
    c.dispose();
    if (json == null || json.isEmpty) return;
    // 校验是合法 JSON 且含 name/steps
    try {
      final Map<String, dynamic> rule = jsonDecode(json) as Map<String, dynamic>;
      if (rule['name'] == null || rule['steps'] == null) {
        setState(() => _note = 'JSON 不完整：要有 name 和 steps');
        return;
      }
      final bool ok = await _bridge.saveRule(jsonEncode(rule));
      if (!mounted) return;
      setState(() => _note = ok ? '已导入「${rule['name']}」' : '导入失败');
      await _load();
    } catch (_) {
      if (mounted) setState(() => _note = '不是合法 JSON');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('泡泡猫规则库')),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.download, size: 20),
            tooltip: context.tr('导入规则'),
            onPressed: _import,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(DshMetrics.pagePad),
        children: <Widget>[
          Text(
            context.tr('这里是你录的规则。点「复制」把 JSON 发给别人；别人粘贴到「导入」里就能用。'),
            style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
          if (!_loading && _rules.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  context.tr('还没有规则。去「后台操作台」点「开始录制」，录一条吧。'),
                  style: TextStyle(color: DshColors.textDim, fontSize: 12.5),
                ),
              ),
            ),
          for (final Map<String, dynamic> rule in _rules)
            _ruleCard(rule),
          if (_runMsg.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                if (_running)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (_running) const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _runMsg,
                    style: TextStyle(
                        color: _running ? DshColors.textDim : DshColors.accent,
                        fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
          if (_note != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _note!,
              style: TextStyle(color: DshColors.accent, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _ruleCard(Map<String, dynamic> rule) {
    final String name = (rule['name'] ?? '').toString();
    final List<dynamic> steps = (rule['steps'] as List<dynamic>?) ?? <dynamic>[];
    return InkWell(
      borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
      onTap: () => _viewCode(rule),
      child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
        border: Border.all(color: DshColors.line, width: DshMetrics.borderWidth),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.bolt, size: 18, color: DshColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name,
                  style: TextStyle(
                    color: DshColors.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${steps.length} 步',
                  style: TextStyle(color: DshColors.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(_running ? Icons.hourglass_top : Icons.play_arrow, size: 20),
            tooltip: context.tr('执行'),
            onPressed: _running ? null : () => _runRule(rule),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: context.tr('复制 JSON'),
            onPressed: () => _copy(rule),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: context.tr('删除'),
            onPressed: () => _delete(rule),
          ),
        ],
      ),
    ),
    );
  }

  /// 点开一条规则 → 查看它的 JSON 代码（格式化 + 等宽字体 + 可复制）。
  Future<void> _viewCode(Map<String, dynamic> rule) async {
    final String code = const JsonEncoder.withIndent('  ').convert(rule);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${rule['name']} · ${ctx.tr('代码')}',
                style: const TextStyle(fontSize: 15),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: ctx.tr('复制'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(ctx.tr('已复制代码'))),
                  );
                }
              },
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              code,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.tr('关闭')),
          ),
        ],
      ),
    );
  }
}
