import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'dsh_runtime.dart';
import 'diagnostics_log.dart';

/// 「手机界面操作」桥的 Flutter 侧客户端。
///
/// ## 它是什么
///
/// App 内起一个 127.0.0.1 的小 HTTP 服务（Android 侧 [PhoneAgentBridge]），
/// 后面挂着一个**无障碍服务**。这样 **DSH 的 Agent（Node 进程）就能直接调它**
/// —— 不用绕 Flutter，Agent 侧就是一次普通 HTTP 请求。
///
/// ## 为什么要令牌
///
/// 桥只在本机，但同机的别的 App 也可能猜到端口。请求头带一个随机会话令牌，
/// 由本类生成并交给 Android 侧；Node 侧要用同一个令牌（见 [token]）。
///
/// ## 现在到哪一步了（探针）
///
/// - ✅ 桥能起、能停、端口已知
/// - ✅ 截图 / 点击 / 滑动 / 节点树 四个接口在 Android 侧实现
/// - ⬜ **无障碍服务必须用户手动在系统设置里开启**（App 不能自己开）—— 开启前
///   所有操作接口都会如实返回「未连接」
/// - ⬜ OCR / 视觉理解 还没接（后续可挂 DSH 已有的 llama.cpp）
class PhoneAgentBridge {
  PhoneAgentBridge._();

  static final PhoneAgentBridge instance = PhoneAgentBridge._();

  static const String _logTag = 'dsh-phone-agent';

  /// 桥监听的端口（本地模型那套在 39541，这个换开一段避免撞车）。
  static const int basePort = 39711;

  /// 会话令牌 —— Node 侧要用同一个值。
  String get token => _token;
  String _token = '';

  int? _port;
  bool _running = false;

  /// 无障碍服务是否已被系统绑定（= 用户开了且系统连上了）。
  bool get serviceConnected => _serviceConnected;
  bool _serviceConnected = false;

  int get port => _port ?? 0;

  bool get running => _running;

  /// 启动桥。返回实际端口；失败抛 [PlatformException]。
  Future<int> start() async {
    _token = _randomToken();
    final int? p = await DshHost.channel
        .invokeMethod<int>('phoneAgentStart', <String, dynamic>{
      'port': basePort,
      'token': _token,
    });
    if (p == null || p <= 0) {
      _running = false;
      throw StateError('手机操作桥启动失败（原生层没返回端口）');
    }
    _port = p;
    _running = true;
    DiagnosticsLog.add(_logTag, '手机操作桥已启动：127.0.0.1:$p');
    return p;
  }

  Future<void> stop() async {
    try {
      await DshHost.channel.invokeMethod<bool>('phoneAgentStop');
    } catch (_) {
      // 停不掉也要往下走：状态置 false，不让调用方以为还能用。
    }
    _running = false;
    _port = null;
  }

  /// 查状态（桥在不在 / 无障碍服务连上了没 / 当前前台包名）。
  Future<PhoneAgentStatus> status() async {
    final Map<Object?, Object?>? m = await DshHost.channel
        .invokeMethod<Map<Object?, Object?>>('phoneAgentStatus');
    final bool connected = m?['connected'] == true;
    _serviceConnected = connected;
    return PhoneAgentStatus(
      running: m?['running'] == true,
      connected: connected,
      port: (m?['port'] as num?)?.toInt() ?? 0,
      sdk: (m?['sdk'] as num?)?.toInt() ?? 0,
    );
  }

  // ── 直连调用（Flutter 侧自测用；Node 侧走 HTTP）────────────────────

  /// 抓当前屏幕（PNG 字节）。
  Future<Uint8List?> screenshot() async {
    final Map<String, dynamic>? r = await _get('/screenshot');
    if (r == null || r['ok'] != true) return null;
    final String? b64 = r['png'] as String?;
    if (b64 == null) return null;
    return base64Decode(b64);
  }

  /// 点一下。
  Future<bool> tap(int x, int y) async {
    final Map<String, dynamic>? r =
        await _post('/tap', <String, dynamic>{'x': x, 'y': y});
    return r?['ok'] == true;
  }

  /// 滑一下。
  Future<bool> swipe(int x1, int y1, int x2, int y2, {int ms = 300}) async {
    final Map<String, dynamic>? r = await _post('/swipe', <String, dynamic>{
      'x1': x1,
      'y1': y1,
      'x2': x2,
      'y2': y2,
      'ms': ms,
    });
    return r?['ok'] == true;
  }

  /// 手机里所有能从桌面启动的 App（label + package + 是否系统应用），JSON 字符串。
  Future<String?> listApps() async {
    final Object? r = await DshHost.channel.invokeMethod<Object>('listInstalledApps');
    if (r is String && r.isNotEmpty) return r;
    return null;
  }

  /// 点击应用列表 → 后台启动它（Agent 接管的钥匙动作）。
  Future<bool> launchApp(String packageName) async {
    final bool? ok = await DshHost.channel.invokeMethod<bool>(
        'launchApp', <String, dynamic>{'package': packageName});
    return ok == true;
  }

  /// 把总开关状态也写进钥匙文件，Node 侧读它判断"允许吗"。
  Future<void> recordEnabled(bool enabled) async {
    try {
      await DshHost.channel.invokeMethod<bool>('recordPhoneAgentEnabled',
          <String, dynamic>{'enabled': enabled});
    } catch (_) {}
  }

  /// 弹 Shizuku 授权框（用户点「去授权」时用）。
  Future<void> requestShizukuPermission() async {
    try {
      await DshHost.channel.invokeMethod<bool>('shizukuRequestPermission');
    } catch (_) {}
  }

  /// 重新绑定无头引擎。
  ///
  /// **授权之后必须调一次**：`attach()` 那次 bind 发生在授权之前，必然失败；
  /// 不重绑的话引擎永远是 `not connected`，建屏恒失败。
  Future<bool> rebindEngine() async {
    try {
      final bool? ok =
          await DshHost.channel.invokeMethod<bool>('phoneAgentRebind');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// 当前界面控件树（JSON 字符串）。
  Future<String?> nodes() async {
    final Map<String, dynamic>? r = await _get('/nodes');
    if (r == null || r['ok'] != true) return null;
    return r['nodes'] as String?;
  }

  // ── 后台虚拟屏（2026-10-24：对齐 aladdin 那套「看不见也能点」）──────────
  //
  // 这一组是「后台操作台」页面用的。引擎跑在 Shizuku 拉起的 shell 进程里
  // （见 EngineService/DisplayEngine），App 侧只是发 binder 命令。

  /// 无头引擎实时状态：Shizuku 授权 / 引擎连接 / 虚拟屏 id。
  ///
  /// `displayId < 0` 表示还没建屏。
  Future<PhoneAgentHeadless?> headlessInfo() async {
    final Map<String, dynamic>? r = await _get('/status');
    if (r == null || r['ok'] != true) return null;
    return PhoneAgentHeadless(
      shizukuGranted: r['shizukuPermission'] == true,
      engineConnected: r['connected'] == true,
      displayId: (r['display'] as num?)?.toInt() ?? -1,
    );
  }

  /// 建一块看不见的虚拟屏（后台模式第一步）。返回 `OK:<displayId>` 或 `ERR:<原因>`。
  Future<String?> createDisplay({
    int w = 1080,
    int h = 1920,
    int dpi = 320,
  }) async {
    final Map<String, dynamic>? r = await _post('/create', <String, dynamic>{
      'w': w,
      'h': h,
      'dpi': dpi,
    });
    return r?['result'] as String?;
  }

  /// 销毁虚拟屏（顺带释放截图缓冲与唤醒锁）。
  Future<String?> releaseDisplay() async {
    final Map<String, dynamic>? r = await _post('/release', <String, dynamic>{});
    return r?['result'] as String?;
  }

  /// 把目标应用启动到虚拟屏上（不会出现在物理屏）。返回 `OK` 或 `ERR:<原因>`。
  Future<String?> launchOnDisplay(String packageName) async {
    final Map<String, dynamic>? r = await _post('/launch', <String, dynamic>{
      'pkg': packageName,
    });
    return r?['result'] as String?;
  }

  /// 往虚拟屏发一个系统键：back / home / recents。
  Future<bool> sendKey(String action) async {
    final Map<String, dynamic>? r = await _get('/key?action=$action');
    return r?['ok'] == true;
  }

  // ── 免装 Shizuku：adb 无线调试通道（2026-10-24）────────────────────────
  //
  // 这条路让用户不用另装 Shizuku：App 自己跟手机的 adbd 配对（6 位配对码），
  // 然后把引擎 dex 起在 shell 身份里。状态与失败原因都从原生侧读。

  /// 免装通道的连接状态（binder 在不在 / dex 版本 / 上一次错误）。
  Future<Map<String, dynamic>?> vdshellStatus() async {
    try {
      final Map<Object?, Object?>? m =
          await DshHost.channel.invokeMethod<Map<Object?, Object?>>('vdshellStatus');
      if (m == null) return null;
      return <String, dynamic>{
        'binderAlive': m['binderAlive'] == true,
        'dexVersion': (m['dexVersion'] as num?)?.toInt() ?? 0,
        'error': m['error']?.toString() ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  /// 无线调试配对（[code] 6 位；[port] 留空则自动 mDNS 发现配对端口）。
  Future<bool> vdshellPair(String code, {int? port}) async {
    try {
      final bool? ok = await DshHost.channel.invokeMethod<bool>(
          'vdshellPair', <String, dynamic>{'code': code, 'port': port});
      return ok == true;
    } catch (e) {
      DiagnosticsLog.add(_logTag, 'vdshellPair 失败：$e');
      return false;
    }
  }

  /// 连接 → 部署 dex → 起 shell 进程 → 等 binder。
  Future<({bool ok, String error})> vdshellBootstrap() async {
    try {
      final Map<Object?, Object?>? m =
          await DshHost.channel.invokeMethod<Map<Object?, Object?>>('vdshellBootstrap');
      return (
        ok: m?['ok'] == true,
        error: m?['error']?.toString() ?? '',
      );
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }

  /// 停掉 shell 进程里的引擎。
  Future<void> vdshellStop() async {
    try {
      await DshHost.channel.invokeMethod<bool>('vdshellStop');
    } catch (_) {}
  }

  /// 连上 adbd 后跑一条调试命令（排障用）。
  Future<String> vdshellShell(String command) async {
    try {
      final String? out = await DshHost.channel
          .invokeMethod<String>('vdshellShell', <String, dynamic>{'command': command});
      return out ?? '';
    } catch (e) {
      return 'ERR:$e';
    }
  }

  /// 把一段文字敲进虚拟屏（KeyCharacterMap，不弹输入法）。
  Future<bool> inputText(String text) async {
    final Map<String, dynamic>? r =
        await _post('/input', <String, dynamic>{'text': text});
    return r?['ok'] == true;
  }

  Future<Map<String, dynamic>?> _get(String path) =>
      _request('GET', path, null);

  Future<Map<String, dynamic>?> _post(String path, Map<String, dynamic> body) =>
      _request('POST', path, body);

  Future<Map<String, dynamic>?> _request(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final int p = _port ?? 0;
    if (p <= 0) return null;
    final HttpClient c = HttpClient();
    try {
      final HttpClientRequest req = await c.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$p$path'),
      );
      req.headers.set('x-dsh-token', _token);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final HttpClientResponse resp = await req.close();
      final String text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        DiagnosticsLog.add(_logTag, '$path 返回 ${resp.statusCode}：$text');
        return null;
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      DiagnosticsLog.add(_logTag, '$path 调用失败：$e');
      return null;
    } finally {
      c.close(force: true);
    }
  }

  String _randomToken() {
    final Random r = Random.secure();
    final StringBuffer sb = StringBuffer('dph');
    for (int i = 0; i < 24; i++) {
      sb.write(r.nextInt(36).toRadixString(36));
    }
    return sb.toString();
  }
}

/// 桥的状态快照。
class PhoneAgentStatus {
  const PhoneAgentStatus({
    required this.running,
    required this.connected,
    required this.port,
    required this.sdk,
  });

  /// 桥（HTTP 服务）在不在。
  final bool running;

  /// 无障碍服务**已被系统绑定**（= 用户在系统设置里开了）。
  final bool connected;

  final int port;
  final int sdk;

  /// 给用户看的一句话（说人话，不出现端口这种细节）。
  ///
  /// 2026-10-24：无头模式已取代无障碍 —— 这里不再提「设置 → 无障碍」，
  /// 否则用户在系统里翻半天也找不到那个开关（它压根不存在了）。
  String get hint {
    if (!running) return '桥没起来';
    if (!connected) {
      return '还没连上 Shizuku —— 点下面的按钮授权，授权后会自动重连';
    }
    return '已就绪';
  }
}

/// 后台无头引擎的状态快照（虚拟屏视角）。
///
/// 与 [PhoneAgentStatus] 的区别：那个是「桥 + 授权」的总状态，
/// 这个是「引擎连到哪一步、虚拟屏建了没有」，给操作台页面用。
class PhoneAgentHeadless {
  const PhoneAgentHeadless({
    required this.shizukuGranted,
    required this.engineConnected,
    required this.displayId,
  });

  /// Shizuku 已授予本 App 权限（系统层面已勾选）。
  final bool shizukuGranted;

  /// shell 进程里的引擎已经连上（binder 可用）。
  final bool engineConnected;

  /// 已建虚拟屏的 displayId；`-1` = 没建。
  final int displayId;

  bool get hasDisplay => displayId >= 0;

  /// 一句话说清现在能做什么。
  String get hint {
    if (hasDisplay) return '虚拟屏在跑：display=$displayId';
    if (engineConnected) return '引擎就绪，可以建一块看不见的屏了';
    if (shizukuGranted) return '已授权 Shizuku，但引擎还没连上 —— 点「重连引擎」';
    return '引擎还没起来：上面可授权 Shizuku，或用「免装 Shizuku」无线调试配对';
  }
}
