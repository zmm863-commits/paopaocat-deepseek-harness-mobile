import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../i18n/dsh_i18n.dart';
import '../../local/bot_server.dart';
import '../../local/dsh_runtime.dart';
import '../../local/agnes_web.dart';
import '../../local/battery_optim.dart';
import '../../state/app_settings.dart';
import '../../local/bridge_prefs.dart';
import '../../local/diagnostics_log.dart';
import '../../local/design_site.dart';
import '../../local/lan_endpoints.dart';
import '../../local/port_forwarder.dart';
import '../../local/web_bridge.dart';
import '../theme/dsh_tokens.dart';
import 'computer_access_actions.dart';
import 'computer_access_url.dart';
import 'computer_access_qr.dart';
import 'computer_access_selfcheck.dart';

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
  const ComputerAccessPanel({
    super.key,
    required this.runtime,
    required this.settings,
  });

  final DshRuntime runtime;

  /// 读「后台运行」开关：关掉电脑访问时要决定「退回后台保活」还是「彻底停掉」。
  final AppSettings settings;

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

  /// 系统「忽略电池优化」的真状态。`null` = 查不到（老设备 / 通道失败）。
  ///
  /// ⚠️ 用三态而不是 bool：查不到的时候**必须**能显示成"不确定"。
  /// 默认 false 会在查不到时给出一个假警报，默认 true 则是假绿灯。
  bool? _batteryIgnoring;

  /// 认出来的手机厂商（`vivo`/`xiaomi`/`huawei`/`honor`/`oppo`），null = 不用管。
  String? _vendor;

  /// 用户**去过**哪些厂商设置页。注意：这是"去过"，不是"已开启" ——
  /// 系统不告诉 App 那些开关的状态，界面上也不会把它画成勾。
  Set<String> _visited = <String>{};

  /// 进行中的人话阶段（「准备运行环境…」「正在启动 DSH 与设计站…」）。
  ///
  /// 首启要等 40~80 秒（解包 8~20 秒 + DSH 20~25 秒 + 设计站 5~10 秒），
  /// 原来界面上**只有一个转圈**，用户看不出是在干活还是卡死了。
  ///
  /// ⚠️ 用枚举而不是直接存字符串：i18n 扫描器只认 `context.tr('字面量')`，
  /// 把文案塞进一个 String 字段再 `tr(_stage!)` 就**永远进不了翻译表**
  /// （切到英/日/韩会露出一句中文，而且不报错）。这里在 [stageText] 里
  /// 逐个写成字面量，扫描器才看得见。
  _Stage? _stage;

  /// 这次操作已经等了多少秒。每 500ms 刷一次，只在这一秒变了才 setState。
  int _elapsed = 0;
  Timer? _tickTimer;
  DateTime? _stageStartedAt;

  /// 当前阶段的文案（只在 [_stage] 非空时调用）。
  String stageText(BuildContext context) => _stage!.text(context);

  void _beginProgress(_Stage stage) {
    _stageStartedAt ??= DateTime.now();
    _tickTimer ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final t = _stageStartedAt;
      if (t == null) return;
      final s = DateTime.now().difference(t).inSeconds;
      if (s != _elapsed) setState(() => _elapsed = s);
    });
    if (mounted) setState(() => _stage = stage);
  }

  void _endProgress() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _stageStartedAt = null;
    if (mounted) {
      setState(() {
        _stage = null;
        _elapsed = 0;
      });
    }
  }

  /// 设计站那条独立转发（与 DSH 那条互不影响）。
  final PortForwarder _designForward = PortForwarder.create();
  String? _designUrl;
  String? _designError;
  BridgePrefs? _prefs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // 设计站那条转发是**本面板创建**的，面板走了必须收掉；
    // DSH 那条是全局单例（Bot 页也在用），不能在这里停。
    _tickTimer?.cancel();
    unawaited(_designForward.stop());
    super.dispose();
  }

  Future<void> _load() async {
    _prefs = await BridgePrefs.load(widget.runtime.filesDir);
    // 顺手问一次后台那三道关的真状态（不阻塞主加载，查不到就显示"不确定"）。
    unawaited(_loadBackground());
    final eps = await LanEndpoints.list();
    if (!mounted) return;
    setState(() {
      _lan = eps;
      // 优先回到**上次用过的网卡**：端口已经固定，地址再固定住，用户收藏的
      // 链接才真的长期有效（真机日志里同一台手机两次开开关，注入的地址一次是
      // 192.168.199.2、一次是 192.168.1.60 —— 换了网卡，链接就废了）。
      final keep = _selected != null && eps.any((e) => e.address == _selected);
      if (!keep) {
        final remembered = _prefs?.dshHost ?? '';
        final hit = eps.where((e) => e.address == remembered).toList();
        if (hit.isNotEmpty) {
          _selected = hit.first.address;
        } else {
          _selected = eps.isEmpty ? null : eps.first.address;
        }
      }
      // 转发器可能已经在跑（离开页面再进来）：把真实状态显示出来，
      // 否则用户会看到"开关是关的，但电脑其实连得上"。
      if (PortForwarder.instance.running) {
        _on = true;
        _designUrl = AgnesWeb.publicUrl;
        _designError = AgnesWeb.lastError;
        final fwd = PortForwarder.instance.port;
        if (fwd != null && _selected != null) {
          // ⚠️ 用 **App 的固定口令**，不是 `cur.url` 里那个 launchToken ——
          //    2026-10-30 真机就是这个坑：`_apply()` 改了、`_load()` 没改，
          //    用户重进面板复制到的是会过期的那种地址，电脑上打开 401。
          _url = publicDshUrl(
            host: _selected!,
            port: fwd,
            token: _prefs?.token ?? '',
          );
        }
      }
    });
  }

  /// 换一把新口令：旧链接（电脑上收藏的、发给别人的）立即失效。
  Future<void> _rotateToken() async {
    final prefs = _prefs ?? await BridgePrefs.load(widget.runtime.filesDir);
    await prefs.rotateToken();
    _prefs = prefs;
    if (!mounted) return;
    if (_on) {
      await _apply(on: true); // 正在跑 → 重启后端，新口令立刻生效
    } else {
      setState(() => _note = context.tr('口令已重置，下次开启时生效'));
    }
  }

  /// 二维码 / 手打地址。两个地址都给（DSH 网页在前、设计站在后）。
  Future<void> _showQr() async {
    final entries = <String, String>{
      if (_url != null) context.tr('DSH 网页'): _url!,
      if (_designUrl != null) context.tr('设计站'): _designUrl!,
    };
    if (entries.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ComputerAccessQrDialog(entries: entries),
    );
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
        _beginProgress(_Stage.preparing);
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
        // 固定端口 + 访问口令（都记在 [BridgePrefs]，重启 App 也不变）。
        final prefs = await BridgePrefs.load(widget.runtime.filesDir);
        final fwdPort =
            await PortForwarder.instance.reservePort(preferred: prefs.dshPort);
        prefs.dshPort = fwdPort;
        prefs.dshHost = host; // 端口 + 网卡一起记，收藏的地址才真的不失效
        await prefs.save();
        AgnesWeb.accessToken = prefs.token;

        // ── 并行启动两个后端（2026-10-28 优化）──────────────────────────
        // 以前是「先起 DSH（20~25 秒）→ 再起设计站（5~10 秒）」串行，
        // 用户要等 70~80 秒。两者互不依赖，可以同时起，等待时间取最长的那个。
        _beginProgress(_Stage.starting);
        AgnesWeb.setKeepAlive(true);
        // ⚠️ 注意：**不再传 `trustedAuthorities`**（2026-10-30 改）。
        // 那一套要 `--trusted-host`，而它是启动参数 —— 开一次电脑访问就重启一次
        // DSH，真机上还撞见过重启后 profile 激活失败（退出码 1，面板红一片）。
        // 现在由转发层把 Host 改写成 127.0.0.1:<port>，DSH 认为自己被本机访问，
        // 天然放行 —— 开关电脑访问**完全不碰 DSH 进程**。
        final dshFuture = BotServer.ensureStarted(runtime: widget.runtime);
        // 设计站先失败也不能让异常「无人认领」（Dart 会把它当未捕获错误刷出来），
        // 所以这里就地接住，稍后再按正常流程报给界面。
        Object? agnesErr;
        final agnesFuture = AgnesWeb.ensureStarted(widget.runtime)
            .then<AgnesWeb?>((v) => v)
            .catchError((Object e) {
          agnesErr = e;
          return null;
        });

        BotServer server;
        try {
          server = await dshFuture;
        } catch (e) {
          // 真机 2026-10-30：首次拨开关时 DSH 重启后 profile 激活失败（退出码 1，
          // `file-upload connection / ui-deliverables connection`），整个面板红一片，
          // 再点一次开关就好了 —— 说明是**一次性**的竞争，不是配置错。
          // 与其让用户自己再点一次，不如替他们重试一次（只重试一次，失败照实报）。
          DiagnosticsLog.add('lan', '启动电脑访问失败，自动重试一次：$e');
          server = await BotServer.ensureStarted(runtime: widget.runtime);
        }
        if (!mounted) return;
        // 给用户的地址用**App 的固定口令**，不是 DSH 那个每次重启都变的 launchToken。
        // 转发层会在第一个请求里把它换成当前真 token（见 ForwardRewrite）。
        final launchToken = Uri.parse(server.url).queryParameters['token'] ?? '';
        final url = publicDshUrl(host: host, port: fwdPort, token: prefs.token);
        if (launchToken.isEmpty) {
          DiagnosticsLog.add('lan', '⚠ 没从 DSH 拿到 launchToken，电脑端会 401');
        }
        _beginProgress(_Stage.port);
        await PortForwarder.instance.start(
          targetPort: server.port,
          listenPort: fwdPort,
          rewrite: ForwardRewrite(
            fixedToken: prefs.token,
            upstreamToken: launchToken,
            upstreamAuthority: '127.0.0.1:${server.port}',
          ),
        );

        // ── 设计站：手机里的 Node 后端 + 第二条转发 ──────────────────────
        // 它不是纯静态站（15 个引擎都走 /agnes-studio/api/*），必须把后端跑起来。
        // 资料根指向 workspace/.agnes（进资料库），模型凭据由 dsh-models.json
        // 提供（Key 不出手机）。失败不影响 DSH 网页本身。
        String? designUrl;
        String? designErr;
        _beginProgress(_Stage.design);
        try {
          final agnes = await agnesFuture;
          if (agnes == null) throw StateError('${agnesErr ?? '设计站后端启动失败'}');
          final dPort = await _designForward.reservePort(preferred: prefs.agnesPort);
          prefs.agnesPort = dPort;
          await prefs.save();
          await _designForward.start(targetPort: agnes.port, listenPort: dPort);
          // URL 带口令：设计站端口不再裸奔（详见 AgnesWeb.accessToken 注释）。
          // ⚠️ 用**真正在跑的那个进程**的口令，而不是 prefs 里的值（2026-10-29 真机踩过）：
          //    服务可能是上一轮起的（进程还活着），prefs 却被重置口令改过 →
          //    面板显示的是新口令、服务认的是旧口令 → 电脑上打开就是「未通过访问口令」，
          //    表现就是用户说的「网页版连不上手机」。agnes.token 才是服务手里的那把。
          designUrl = 'http://$host:$dPort/?token=${agnes.token}';
          AgnesWeb.publicUrl = designUrl;
          AgnesWeb.lastError = null;
          await DesignSite.injectEntry(widget.runtime, designUrl);
        } catch (e) {
          designErr = '$e';
          AgnesWeb.lastError = designErr;
          await DesignSite.removeEntry(widget.runtime);
          // ⚠️ 这里**绝对不能** stop 保活（0.80 曾经写错在这一行）：
          //    设计站起不来时 DSH 网页本身还是好的，把前台服务停掉等于
          //    让唯一还活着的那个服务失去保护 —— 电脑端随后就 502 了。
          //    保活只在「关掉开关」时停（见下面的 else 分支）。
        }
        // 保活：把进程提级，否则切后台/被回收后电脑端会突然 502。
        await WebBridge.start(
            designUrl != null ? 'DSH：$url\n设计站：$designUrl' : url);
        if (!mounted) return;
        setState(() {
          _url = url;
          _on = true;
          _designUrl = designUrl;
          _designError = designErr;
        });
      } else {
        _beginProgress(_Stage.closing);
        await PortForwarder.instance.stop();
        await _designForward.stop();
        AgnesWeb.setKeepAlive(false);
        await AgnesWeb.stop();
        AgnesWeb.publicUrl = null;
        AgnesWeb.lastError = null;
        await DesignSite.removeEntry(widget.runtime);
        // 关开关时怎么处理保活（2026-11-02 调整）：
        //   * 「后台运行」开着 → **退回** keepalive（通知改成「后台运行中」），
        //     而不是彻底停掉 —— 用户关的是"电脑访问"，不是"让 App 在后台活着"。
        //   * 「后台运行」关着 → 才彻底 stop（通知栏那条跟着消失）。
        if (widget.settings.backgroundKeepAlive) {
          await WebBridge.start('DSH 在后台保持运行',
              mode: WebBridge.modeKeepAlive);
        } else {
          await WebBridge.stop();
        }
        // 这里**不再重启 DSH**（0.80 是重启的，为的是清掉 `--trusted-host`）。
        // 现在压根不用 trusted-host：Host 由转发层改写。所以关开关只是收掉
        // 监听与保活 —— Bot 页不会闪、正在跑的会话也不会被打断。
        if (!mounted) return;
        setState(() {
          _on = false;
          _url = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _endProgress();
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
        // 进度条 + 人话阶段（0.81）。原来只有一个转圈：首启要等 40~80 秒，
        // 用户完全看不出「是在干活还是卡死了」，也不知道还要等多久。
        if (_busy && _stage != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  stageText(context),
                  style: TextStyle(fontSize: 11.5, color: scheme.primary),
                ),
              ),
              Text(
                context.tr('已等 {0} 秒', [_elapsed]),
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
            ],
          ),
        ],
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
              borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
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
        ComputerAccessActions(
          busy: _busy,
          hasUrl: _on && _url != null,
          showRotate: _on,
          onRefresh: _load,
          onCopy: () async {
            await Clipboard.setData(ClipboardData(text: _url!));
            if (!mounted) return;
            setState(() => _note = context.tr('网址已复制'));
          },
          onQr: _showQr,
          onRotate: _rotateToken,
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
          const SizedBox(height: 8),
          Text(
            _designUrl != null
                ? context.tr('设计站（资料存手机、用手机模型）：{0}', [_designUrl!])
                : (_designError != null
                    ? context.tr('设计站没能启动：{0}', [_designError!])
                    : context.tr('设计站未启动')),
            style: TextStyle(
              fontSize: 10.5,
              height: 1.55,
              color: _designError != null ? scheme.error : scheme.outline,
            ),
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
        // 「连不上？点这里自检」（2026-10-31）
        //
        // 起因：三天里三个用户报"连不上"，但真因分属三层 ——
        // 浏览器没把地址当网址（DNS 层）/ 端口没人听 / 口令不对。
        // 用户只会说"连不上"，于是每来一个都要来回三轮。
        // 这个按钮真的发一次请求，把"哪一环断了"直接说清楚。
        if (_on) ...[
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _showSelfCheck,
              icon: const Icon(Icons.troubleshoot, size: 15),
              label: Text(context.tr('连不上？点这里自检'),
                  style: const TextStyle(fontSize: 11.5)),
            ),
          ),
        ],
        // 「后台运行」—— 只有**真状态 + 一键直达**，没有开关（2026-10-31）。
        //
        // 用户问"是不是要加个后台运行开关"。答案是不加：Android 不允许第三方
        // 应用给自己开后台权限，那种开关只能记住"用户点过"，改不了系统行为 ——
        // 正是那份故障复盘里批的「UI 状态 ≠ 运行状态」。
        if (_on) ...[
          const SizedBox(height: 4),
          _backgroundSection(scheme),
        ],
      ],
    );
  }

  /// 「后台运行」这一段：**三道关**逐条列出 —— 能检测的检测，检测不了的诚实说不知道。
  ///
  /// 为什么不是一个开关：见 [BatteryOptim] 顶部那张表。厂商那一关系统不告诉 App
  /// 开没开，所以那几行只写「去过 / 没去过」，**绝不打勾** —— 打勾就是替系统撒谎。
  Widget _backgroundSection(ColorScheme scheme) {
    final ignoring = _batteryIgnoring;
    final vendor = _vendor;
    final vendorLabel = _vendorBackgroundLabel(vendor);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.battery_saver_outlined,
                size: 15, color: DshColors.textDim),
            const SizedBox(width: 6),
            Text(context.tr('后台运行'),
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 4),
        _accessRow(
          scheme: scheme,
          ok: ignoring,
          title: context.tr('忽略电池优化'),
          detail: ignoring == true
              ? context.tr('已豁免：系统不会因为省电策略回收本服务')
              : ignoring == false
                  ? context.tr('未豁免：息屏几分钟后系统可能回收本服务，电脑那边就打不开了')
                  : context.tr('查不到当前状态（这台设备不支持查询）'),
          action: ignoring == true ? context.tr('去看看') : context.tr('允许'),
          // 已豁免时点「去看看」要走"打开详情页核对"，别再申请（见 _fixBattery）。
          onTap: _busy
              ? null
              : () => _fixBattery(alreadyIgnoring: ignoring == true),
        ),
        if (vendor != null && vendorLabel != null)
          _accessRow(
            scheme: scheme,
            ok: _visited.contains('background') ? true : null,
            title: vendorLabel,
            detail: _visited.contains('background')
                ? context.tr('已送你去过设置页，回来确认一眼是否已放行（系统不告诉 App）')
                : context.tr('这家 ROM 的开关系统读不到也改不了，只能你手动打开'),
            action: _visited.contains('background')
                ? context.tr('再去一次')
                : context.tr('去打开'),
            onTap: _busy ? null : () => _openVendor('background'),
          ),
        if (_vendorHasAutostart(vendor))
          _accessRow(
            scheme: scheme,
            ok: _visited.contains('autostart') ? true : null,
            title: context.tr('自启动'),
            detail: _visited.contains('autostart')
                ? context.tr('已送你去过设置页，回来确认一眼（系统不告诉 App）')
                : context.tr('允许 App 开机后自己起来'),
            action: _visited.contains('autostart')
                ? context.tr('再去一次')
                : context.tr('去打开'),
            onTap: _busy ? null : () => _openVendor('autostart'),
          ),
      ],
    );
  }

  /// 一行权限项：左边一个状态点，中间标题 + 说明，右边一个动作。
  ///
  /// [ok] 三态：`true` 绿点 / `false` 红点 / `null` 灰点（**不知道**）。
  /// 三态是刻意的 —— 只有 true/false 会逼着我们给厂商开关编一个答案。
  Widget _accessRow({
    required ColorScheme scheme,
    required bool? ok,
    required String title,
    required String detail,
    required String action,
    required VoidCallback? onTap,
  }) {
    final color = ok == true
        ? DshColors.ok
        : ok == false
            ? DshColors.err
            : scheme.outline;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Icon(Icons.circle, size: 6, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: ok == true ? color : DshColors.text,
                        fontWeight:
                            ok == true ? FontWeight.w600 : FontWeight.w400)),
                Text(detail,
                    style: TextStyle(
                        fontSize: 10, color: color, height: 1.45)),
              ],
            ),
          ),
          TextButton(
            onPressed: onTap,
            child: Text(action, style: const TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
    );
  }

  /// 这家的「后台不被杀」开关叫什么（各家名字完全不同，写错了用户找不到）。
  String? _vendorBackgroundLabel(String? v) {
    if (v == 'vivo') return context.tr('允许后台高耗电');
    if (v == 'xiaomi') return context.tr('省电策略');
    if (v == 'huawei' || v == 'honor') return context.tr('应用启动管理');
    if (v == 'oppo') return context.tr('后台行为');
    return null;
  }

  /// 哪些厂商有**独立**的自启动页（华为/荣耀把它和后台合成一页，OPPO 在详情页）。
  bool _vendorHasAutostart(String? v) => v == 'vivo' || v == 'xiaomi';

  /// 请求豁免 / 打开系统页，然后**回读真状态**。
  ///
  /// ⚠️ 不管走哪条路都要重新查一次：系统框弹完用户可能点了「取消」，
  /// 我们不能因为"弹过框"就把界面刷成绿灯 —— 那又是一次 UI 骗人。
  /// 「允许 / 去看看」那一行的点击（2026-11-01 修「点了没反应」）。
  ///
  /// 两种状态要点的是**两件不同的事**，以前都调 [BatteryOptim.request]：
  ///   * 还没豁免（按钮「允许」）→ 发系统确认框，让用户点允许；
  ///   * 已经豁免（按钮「去看看」）→ 再发确认框系统**不弹**（已经允许了），
  ///     用户点了就"没反应"。这时该做的是**打开详情页让他自己看一眼**。
  Future<void> _fixBattery({required bool alreadyIgnoring}) async {
    if (alreadyIgnoring) {
      // 已豁免：别再申请（系统不弹窗 = 看着没反应），直接送他去详情页核对。
      final ok = await BatteryOptim.openSettings();
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context.tr(
              '打不开系统设置页。请手动到「设置 → 应用 → 本应用 → 电池」里确认是「无限制」。')),
        ));
      }
      await _loadBackground();
      return;
    }
    final r = await BatteryOptim.request();
    if (!mounted) return;
    if (r == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.tr(
            '打不开系统设置页。请手动到「设置 → 应用 → 本应用 → 电池」里选「无限制」。')),
      ));
    }
    // 用户在系统页里操作完回到 App，给一点时间再回读。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _loadBackground();
  }

  /// 把用户送到厂商那一页，并记下"去过"（**不是**"已开启"）。
  Future<void> _openVendor(String switchWire) async {
    final r = await BatteryOptim.openVendorSettings(switchWire);
    if (!mounted) return;
    if (r == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.tr(
            '打不开系统设置页。请手动到「设置 → 应用 → 本应用」里找电池/自启动那一项。')),
      ));
      return;
    }
    await BatteryOptim.markVisited(widget.runtime.filesDir, switchWire);
    if (!mounted) return;
    setState(() => _visited = <String>{..._visited, switchWire});
    // 从设置页回来时顺手回读一次系统那一关（厂商那关读不到，只能读 AOSP 的）。
    await _loadBackground();
  }

  Future<void> _loadBackground() async {
    final ignoring = await BatteryOptim.isIgnoring();
    final vendor = await BatteryOptim.vendor();
    final visited = await BatteryOptim.visited(widget.runtime.filesDir);
    if (!mounted) return;
    setState(() {
      _batteryIgnoring = ignoring;
      _vendor = vendor;
      _visited = visited;
    });
  }

  /// 「连不上？点这里自检」—— 真的连一次，把结论写成一段人话。
  Future<void> _showSelfCheck() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final report = await runSelfCheck(
      forwardRunning: PortForwarder.instance.running,
      forwardPort: PortForwarder.instance.port,
      serverRunning: BotServer.current != null,
      serverPort: BotServer.current?.port,
      host: _selected,
      token: prefs.token,
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ComputerAccessSelfCheckDialog(report: report),
    );
  }
}

/// 电脑访问开关的过程阶段（用在「已等 N 秒」旁边那行字上）。
enum _Stage { preparing, starting, port, design, closing }

extension _StageText on _Stage {
  /// ⚠️ 每条都必须写成 `context.tr('字面量')`：
  /// i18n 扫描器只认这个形状，拼字符串或传变量都会被漏掉（切外语露中文）。
  String text(BuildContext context) => switch (this) {
        _Stage.preparing => context.tr('准备运行环境…'),
        _Stage.starting => context.tr('正在启动 DSH 与设计站…'),
        _Stage.port => context.tr('正在打开对外端口…'),
        _Stage.design => context.tr('正在接上设计站…'),
        _Stage.closing => context.tr('正在关闭…'),
      };
}

