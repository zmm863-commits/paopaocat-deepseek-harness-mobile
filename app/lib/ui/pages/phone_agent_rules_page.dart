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
    return Container(
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
    );
  }
}
