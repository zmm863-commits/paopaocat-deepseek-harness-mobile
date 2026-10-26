import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/configured_models.dart';
import '../local/dsh_runtime.dart';

import '../i18n/dsh_i18n.dart';
import 'widgets/common.dart';
import 'theme/dsh_tokens.dart';

/// 模型设置：决定 DSH 用哪个端点、哪个模型、哪个 Key。
///
/// Key 存系统安全存储（Android Keystore / iOS Keychain），并以环境变量形式
/// 注入 node 进程；overlay 里用 `apiKeyEnv` 引用同名变量，Key 不进命令行。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.runtime});

  final DshRuntime runtime;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _secure = FlutterSecureStorage();
  static const _kApiKey = 'dsh_model_api_key';
  static const _kBaseUrl = 'dsh_model_base_url';
  static const _kProvider = 'dsh_model_provider';
  static const _kModel = 'dsh_model_id';

  final _apiKey = TextEditingController();
  final _baseUrl =
      TextEditingController(text: 'https://api.commandcode.ai/provider/v1');
  final _provider = TextEditingController(text: 'com');
  final _model = TextEditingController(text: 'deepseek/deepseek-v4.1-flash');

  bool _busy = false;
  String? _message;

  /// 读已保存的设置失败的原因（null = 正常）。失败时页面**必须**把它显示出来。
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _baseUrl.dispose();
    _provider.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var key = await _secure.read(key: _kApiKey);

      // 与 LocalShell 一致：开发/自动化场景可从私有目录读取，
      // 否则设置页永远是空的，无法用 adb 注入的方式验证流程。
      if (key == null || key.isEmpty) {
        final dev = File('${widget.runtime.filesDir}/dev-api-key.txt');
        if (dev.existsSync()) key = dev.readAsStringSync().trim();
      }

      final base = await _secure.read(key: _kBaseUrl);
      final prov = await _secure.read(key: _kProvider);
      final model = await _secure.read(key: _kModel);
      if (!mounted) return;
      setState(() {
        _loadError = null; // 读成功 → 清掉上一次的错误
        if (key != null && key.isNotEmpty) _apiKey.text = key;
        if (base != null && base.isNotEmpty) _baseUrl.text = base;
        if (prov != null && prov.isNotEmpty) _provider.text = prov;
        if (model != null && model.isNotEmpty) _model.text = model;
      });
    } catch (e) {
      // ⚠️ 原来是 `catch (_) {}`：读失败 = 页面一片空白，用户以为"我没配过"，
      // 于是重新填一遍（而他真正的配置其实还在安全区里）。
      debugPrint('[settings] 读取已保存的设置失败：$e');
      if (!mounted) return;
      setState(() => _loadError = context.tr(
          '读取已保存的设置失败（{0}）。下面显示的是空表单，**不代表你没配过** —— 请先不要重填，把这条报给开发者。',
          ['$e']));
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final key = _apiKey.text.trim();
      if (key.isEmpty) throw StateError(context.tr('API Key 不能为空'));

      await _secure.write(key: _kApiKey, value: key);
      await _secure.write(key: _kBaseUrl, value: _baseUrl.text.trim());
      await _secure.write(key: _kProvider, value: _provider.text.trim());
      await _secure.write(key: _kModel, value: _model.text.trim());

      await widget.runtime.writeModelConfig(
        baseUrl: _baseUrl.text.trim(),
        providerId: _provider.text.trim(),
        modelId: _model.text.trim(),
        // 已配置清单里的其它模型一并注册。清单来源见 data/configured_models.dart
        // （用户真实获取/填写的模型，不再是写死的设计稿清单）。
        extraModelIds: ConfiguredModels.read(widget.runtime.filesDir)
            .models
            .map((m) => m.id)
            .where((id) => id != _model.text.trim())
            .toList(),
      );

      debugPrint(
          '[dsh-settings] model config saved; overlay=${widget.runtime.overlayPath}');
      if (!mounted) return;
      setState(() => _message = context.tr('已保存。返回后即可在对话界面使用。'));
    } catch (e) {
      debugPrint('[dsh-settings] save failed: $e');
      if (mounted) setState(() => _message = context.tr('保存失败：{0}', [e]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final configured = widget.runtime.hasModelConfig;

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('模型设置'))),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          // 读设置失败就说出来（审计点名的那处静默吞掉）。
          //
          // 原因：`_load()` 原来是 `catch (_) {}` —— 安全存储读不出来时，
          // 页面显示的是**一片空白的表单**。用户分不清"我没配过"和
          // "我配过、但现在读不到了"，而且他会直接在上面重新填一遍 Key。
          if (_loadError != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                border: Border.all(
                    color: scheme.error.withValues(alpha: 0.5), width: 0.8),
              ),
              child: DshRichText(
                _loadError!,
                style: TextStyle(
                    color: scheme.error, fontSize: 11.5, height: 1.55),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: configured
                  ? scheme.surfaceContainerHighest
                  : scheme.errorContainer,
              borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
            ),
            child: Row(
              children: [
                Icon(
                    configured
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    configured
                        ? context.tr('模型已配置。')
                        : context.tr('尚未配置模型 —— 不配置的话，对话无法调用模型。'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'API Key',
              helperText: context.tr('存在系统安全存储，不会写进命令行'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _provider,
            decoration: InputDecoration(
              labelText: 'provider id',
              helperText: context.tr('例如 com / deepseek-official'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _model,
            decoration: InputDecoration(
              labelText: 'model id',
              helperText: context.tr('例如 deepseek/deepseek-v4.1-flash'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_busy ? context.tr('保存中…') : context.tr('保存')),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(_message!,
                style: TextStyle(fontSize: 12, color: scheme.outline)),
          ],
          const SizedBox(height: 24),
          Text(
            context.tr(
                '说明：DSH 的运行方式由 overlay 决定 —— 它把模型路由指向你填的端点。这也是为什么换端点必须重新保存一次。'),
            style: TextStyle(fontSize: 11, color: scheme.outline, height: 1.5),
          ),
        ],
      ),
    );
  }
}
