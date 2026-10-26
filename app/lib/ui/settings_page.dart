import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/configured_models.dart';
import '../local/bot_server.dart';
import '../local/dsh_runtime.dart';
import '../local/lan_endpoints.dart';

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

  /// ── 电脑访问 ──────────────────────────────────────────────
  ///
  /// 目标场景（2026-10-26 用户提出）：手机就是"移动电脑"，一根线连到任意一台
  /// 电脑，电脑不装任何客户端，浏览器打开一个网址就能开发 —— 资料和运行时都在
  /// 手机上。
  ///
  /// 这里只做「把 web 服务绑到某张网卡」这一件事。真正的线要这样通：
  ///   手机打开「USB 网络共享」（RNDIS）→ 电脑自动多出一张网卡 →
  ///   手机侧地址通常固定（如 192.168.42.129）→ 浏览器打开下面这个 URL。
  /// 普通 App 开不了 USB 网络共享（要系统权限），所以那一步仍然在系统设置里。
  List<LanEndpoint> _lan = const [];
  String? _lanSelected;
  String? _lanUrl;
  String? _lanError;
  String? _lanNote;
  bool _lanBusy = false;
  bool _lanOn = false;

  /// 读已保存的设置失败的原因（null = 正常）。失败时页面**必须**把它显示出来。
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
    _loadLan();
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

  /// 刷新候选网卡地址（USB 共享 / Wi-Fi），并把「已经在跑的服务」状态带回来。
  Future<void> _loadLan() async {
    final eps = await LanEndpoints.list();
    if (!mounted) return;
    setState(() {
      _lan = eps;
      final keep =
          _lanSelected != null && eps.any((e) => e.address == _lanSelected);
      if (!keep) _lanSelected = eps.isEmpty ? null : eps.first.address;
      // 服务可能是在 Bot 页起的：这里要把它真实的绑定状态显示出来，
      // 否则用户会看到"开关是关的，但电脑其实连得上"。
      final cur = BotServer.current;
      if (cur != null && cur.listenHost != null) {
        _lanOn = true;
        _lanUrl = cur.url;
      }
    });
  }

  /// 开启 / 关闭对外监听。
  ///
  /// ⚠️ 会**重启** web 服务：`--host` 是启动参数，热改不了。重启期间 Bot 页的
  /// WebView 会断开重连（[BotServer.live] 会通知它新地址）。
  Future<void> _applyLan({required bool on}) async {
    if (_lanBusy) return;
    setState(() {
      _lanBusy = true;
      _lanError = null;
    });
    try {
      if (on) {
        final host = _lanSelected;
        if (host == null) {
          throw StateError(context.tr(
              '没找到可用网卡地址。先在系统里打开「USB 网络共享」，再点刷新。'));
        }
        final server = await BotServer.ensureStarted(
          runtime: widget.runtime,
          listenHost: host,
        );
        if (!mounted) return;
        setState(() {
          _lanUrl = server.url;
          _lanOn = server.listenHost != null;
          if (!_lanOn) {
            _lanError = context.tr('这个运行时版本不支持对外监听，已退回本机模式。');
          }
        });
      } else {
        if (BotServer.current == null) {
          if (!mounted) return;
          setState(() {
            _lanOn = false;
            _lanUrl = null;
          });
          return;
        }
        await BotServer.ensureStarted(runtime: widget.runtime, listenHost: null);
        if (!mounted) return;
        setState(() {
          _lanOn = false;
          _lanUrl = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _lanError = '$e');
    } finally {
      if (mounted) setState(() => _lanBusy = false);
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

  /// 「电脑访问」区块：选一张网卡 → 把 web 服务绑上去 → 显示可直接打开的网址。
  Widget _lanSection(ColorScheme scheme) {
    final hasLan = _lan.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.computer_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.tr('电脑访问（一根线 / 同一网络）'),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (_lanBusy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Switch(
                  value: _lanOn,
                  onChanged: (v) => _applyLan(on: v),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            context.tr(
                '把网页服务绑到手机的一张网卡上，电脑用浏览器打开下面的网址就能开发；资料和模型都在手机上，电脑只需要浏览器。'),
            style: TextStyle(fontSize: 11, color: scheme.outline, height: 1.5),
          ),
          const SizedBox(height: 10),
          if (!hasLan)
            Text(
              context.tr('没找到可用网卡。先在系统里打开「USB 网络共享」，再点刷新。'),
              style:
                  TextStyle(fontSize: 11.5, color: scheme.error, height: 1.5),
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
                value: _lanSelected,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                style: TextStyle(fontSize: 12, color: scheme.onSurface),
                items: <DropdownMenuItem<String>>[
                  for (final e in _lan)
                    DropdownMenuItem<String>(
                      value: e.address,
                      child: Text(e.display,
                          style: const TextStyle(fontSize: 12)),
                    ),
                ],
                // 已经绑着的时候不让改：改要重启服务，先关掉开关更不容易懵。
                onChanged: _lanOn
                    ? null
                    : (v) => setState(() {
                          _lanSelected = v;
                          _lanNote = null;
                        }),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: _lanBusy ? null : _loadLan,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(context.tr('刷新网卡'),
                    style: const TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              if (_lanOn && _lanUrl != null)
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _lanUrl!));
                    if (!mounted) return;
                    setState(() => _lanNote = context.tr('网址已复制'));
                  },
                  icon: const Icon(Icons.copy_all_outlined, size: 16),
                  label: Text(context.tr('复制网址'),
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
          if (_lanOn && _lanUrl != null) ...[
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                _lanUrl!,
                style: const TextStyle(
                    fontSize: 11.5, height: 1.5, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              context.tr(
                  '这个网址带身份凭证（token），别发给别人。电脑和手机要在同一张网上（USB 共享或同一 Wi-Fi）。'),
              style:
                  TextStyle(fontSize: 10.5, color: scheme.outline, height: 1.5),
            ),
          ],
          if (_lanNote != null) ...[
            const SizedBox(height: 6),
            Text(_lanNote!,
                style: TextStyle(fontSize: 11, color: scheme.outline)),
          ],
          if (_lanError != null) ...[
            const SizedBox(height: 6),
            Text(_lanError!,
                style:
                    TextStyle(fontSize: 11, color: scheme.error, height: 1.5)),
          ],
        ],
      ),
    );
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
          _lanSection(scheme),
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
