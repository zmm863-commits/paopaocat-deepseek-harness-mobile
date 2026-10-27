import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show AssetManifest, rootBundle;


import '../data/atomic_file.dart';
import '../data/configured_models.dart';
import '../state/provider_keys.dart';
import 'diagnostics_log.dart';
import 'dsh_runtime.dart';

/// 「泡泡猫设计站」的**本机后端**：把 paopaocat-studio-web 的 Node 服务跑在手机里。
///
/// ## 为什么必须跑后端（不能只托管静态文件）
///
/// 设计站是「前端 + Node 后端」一体架构：前端所有能力都打 `/agnes-studio/api/*`
/// （`proxy` 转发模型请求、`models` 列模型、`library/save` 存资料、`cover`/`drama`/
/// `mv`/`slice` 等 15 个引擎）。只托管 `public/` 的结果是**界面能开、一用就 404**
/// —— 这正是 2026-10-27 第一版踩的坑。
///
/// ## 两个用户要求（2026-10-27）怎么满足
///
/// 1. **资料存手机、下次还能看到** → `AGNES_DATA_DIR` 指到
///    `<filesDir>/workspace/.agnes`，也就是 App 资料库扫描的那棵树。
/// 2. **模型用手机上配好的** → App 写一份 `dsh-models.json`（厂商 → baseUrl + Key），
///    后端 `parseKeyHeaders()` 在没有前端凭据时用它兜底。**Key 不出手机**：
///    它只在这个文件里，浏览器拿不到，前端也不需要填。
///
/// 服务只绑 `127.0.0.1`，对外由 [PortForwarder] 开的那条转发暴露。
class AgnesWeb {
  AgnesWeb._(this.process, this.port);

  final Process process;
  final int port;

  static AgnesWeb? _current;
  static AgnesWeb? get current => _current;

  /// 外部（电脑访问的转发）是否正在用这个服务。
  ///
  /// 「电脑访问」开着时，手机页面退出**不能**把它停掉 —— 否则电脑那边
  /// 突然 502。反过来，只在 App 内设计站页用过它、页面走了就该停，避免
  /// 一个 7MB 的静态站 + Node 后端在后台白占内存。
  static bool _keepAlive = false;

  /// 当前服务的本机地址（`http://127.0.0.1:<port>/`），没起就是 null。
  static String? get localUrl => _current == null ? null : 'http://127.0.0.1:${_current!.port}/';

  /// 对外地址（`http://<网卡IP>:<转发端口>/`）。
  ///
  /// 存成静态而不是只放面板里：设置页退出再进来时，面板是**新 State**，
  /// 拿不到上次算的地址 —— 用户会看到「设计站未启动」，而其实它正在跑。
  static String? publicUrl;
  static String? lastError;

  /// 健康巡检定时器（后端挂了自动拉起，见 [_watch]）。
  static Timer? _watchdog;

  /// 上次用的端口。**自动拉起必须复用同一个** —— 对外那条 TCP 转发是
  /// 按 `targetPort` 建的，端口一变转发就指向空气，「自愈」等于没愈。
  static int? _preferredPort;

  /// assets 里的后端与前端前缀。
  static const String serverAssetPrefix = 'assets/agnes-server/';
  static const String siteAssetPrefix = 'assets/studio-site/';

  /// 部署根（`server/` 与 `public/` 必须在同一个父目录下，
  /// 因为 `index.mjs` 用的是 `resolve(HERE, '..', 'public')`）。
  static String rootOf(DshRuntime rt) => '${rt.filesDir}/agnes-web';

  static String _modelsFile(DshRuntime rt) => '${rootOf(rt)}/dsh-models.json';

  /// 解包 + 写模型配置（幂等）。失败抛异常，由调用方如实显示。
  static Future<void> prepare(DshRuntime rt) async {
    final root = Directory(rootOf(rt));
    await _unpackTo(serverAssetPrefix, root, 'server', rt);
    await _unpackTo(siteAssetPrefix, root, 'public', rt);
    await writeModelsFile(rt);
  }

  /// 把 App 的模型配置写成后端认的 `dsh-models.json`。
  ///
  /// ⚠️ 这个文件里有明文 Key —— 它落在 App 私有目录（沙箱内），
  /// **不会**被下发给浏览器（`/api/vendors` 只返回 id/label/baseUrl）。
  static Future<void> writeModelsFile(DshRuntime rt) async {
    try {
      final cfg = ConfiguredModels.readConfig(rt.filesDir);
      final vendors = <String, Map<String, Object?>>{};
      for (final p in cfg.providers) {
        final base = p.baseUrl.trim();
        if (base.isEmpty) continue;
        // ⚠️ Key 是**按厂商分开存**的（`dsh_provider_key_<id>`，见
        //    state/provider_keys.dart）。这里必须逐家读 —— 一开始我只读了
        //    legacy 的单 Key（`dsh_model_api_key`），于是「一家都读不到 →
        //    所有厂商的模型都空」，设计站下拉里一个模型都没有。
        final key = await ProviderKeys.read(p.id);
        final hasKey = key != null && key.trim().isNotEmpty;
        // 无需 Key 的厂商（本机 ollama）也算可用。
        final keyless = p.id == 'ollama';
        final models = cfg.models
            .where((m) => m.provider == p.id)
            .map((m) => m.id)
            .where((id) => id.trim().isNotEmpty)
            .toList();
        vendors[p.id] = <String, Object?>{
          'baseUrl': base,
          'label': p.label.isEmpty ? p.id : p.label,
          // 只有「真能用」的厂商才导出模型：否则下拉里全是选了就报
          // 「没填 Key」的项 —— 正是用户说的那种坏体验。
          'models': (hasKey || keyless) ? models : <String>[],
          if (hasKey) 'apiKey': key.trim(),
        };
      }
      final body = const JsonEncoder.withIndent('  ')
          .convert(<String, Object?>{'vendors': vendors});
      writeStringAtomicSync(File(_modelsFile(rt)), '$body\n');
      DiagnosticsLog.add('agnes',
          '已写模型配置：${vendors.length} 家（Key 不出手机）');
    } catch (e) {
      DiagnosticsLog.add('agnes', '写模型配置失败（设计站会提示没填 Key）：$e');
    }
  }

  /// 起服务（已起着就复用）。返回带端口的实例。
  static Future<AgnesWeb> ensureStarted(DshRuntime rt) async {
    final running = _current;
    if (running != null && running.process.pid != 0) return running;

    await prepare(rt);
    final port = await _pickFreePort();
    final root = rootOf(rt);

    final env = <String, String>{
      ...rt.environment,
      'PORT': '$port',
      // 只绑回环：对外由 App 的 TCP 转发暴露，别直接把后端挂到网卡上。
      'HOST': '127.0.0.1',
      // 资料根 = **手机资料库本身**（用户 2026-10-27 第二次明确：连着手机资料库，
      // 不要另建目录）。
      //
      // 于是三件事同时成立：
      //   ① 已有文件（shots/、随手存的图……）在设计站的资料库面板里看得到；
      //   ② 生成的新文件直接落进这棵树（后端用 `media/图片|视频|音频`，
      //      与 App 自己的约定一致），App 资料库立刻可见；
      //   ③ 重启后仍在（同一个目录，不复制不搬家）。
      //
      // ⚠️ 不要加子目录、也不要用点目录：扫描器会跳过 `.` 开头的目录。
      'AGNES_DATA_DIR': '${rt.filesDir}/workspace',
      // 手机模型配置（Key 兜底的唯一来源）。
      'DSH_MOBILE_MODELS_FILE': _modelsFile(rt),
      if (!rt.environment.containsKey('NODE_OPTIONS'))
        'NODE_OPTIONS': '--max-old-space-size=1024',
    };

    final args = <String>[
      // 与 BotServer 同款：Android 上缺原生 addon，必须开 internals 再挂 shim。
      '--expose-internals',
      '--require', rt.fsShim,
      '--require', rt.execShimPath,
      '$root/server/index.mjs',
    ];

    final process = await Process.start(
      rt.nodeBinary,
      args,
      environment: env,
      includeParentEnvironment: true,
      workingDirectory: root,
    );
    final logs = <String>[];
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      if (l.trim().isEmpty) return;
      logs.add(l);
      if (logs.length > 40) logs.removeAt(0);
      DiagnosticsLog.add('agnes', l);
    }, onError: (Object e) => debugPrint('[agnes] stdout: $e'));
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      if (l.trim().isEmpty) return;
      logs.add(l);
      if (logs.length > 40) logs.removeAt(0);
      DiagnosticsLog.add('agnes:err', l);
    }, onError: (Object e) => debugPrint('[agnes] stderr: $e'));

    unawaited(process.exitCode.then((code) {
      if (_current?.process == process) _current = null;
      DiagnosticsLog.add('agnes', '设计站后端退出，码=$code（最近输出：${logs.join(' / ')}）');
    }));

    // 等它真的能应答（最多 45 秒），而不是"进程起来了"就当好了。
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    var ready = false;
    for (var i = 0; i < 45; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/healthz'));
        final res = await req.close();
        await res.drain<void>();
        if (res.statusCode == 200) {
          ready = true;
          break;
        }
      } catch (_) {
        // 还没起来，继续等
      }
    }
    client.close(force: true);
    if (!ready) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
      throw StateError('设计站后端 45 秒内没有就绪：${logs.take(6).join(' / ')}');
    }

    final w = AgnesWeb._(process, port);
    _current = w;
    _watch(rt, port);
    DiagnosticsLog.add('agnes', '设计站后端已就绪：127.0.0.1:$port（数据根 workspace/.agnes）');
    return w;
  }

  /// 后端健康巡检：每 30 秒 ping 一次 `/healthz`，连续 2 次失败就重启一次。
  ///
  /// 为什么需要（真机踩过）：node 进程会因为内存压力被系统杀掉，而「电脑访问」
  /// 的转发还开着 —— 表现是**设计站突然 502，用户不知道要关开一次开关**。
  /// 自己拉回来，除非连拉起也失败（那时把原因记进 [lastError]）。
  static void _watch(DshRuntime rt, int port) {
    _watchdog?.cancel();
    var fails = 0;
    var restarting = false;
    _watchdog = Timer.periodic(const Duration(seconds: 30), (t) async {
      if (restarting || !identical(_current?.port, port)) return;
      if (_current == null) {
        t.cancel();
        return;
      }
      final ok = await _ping(port);
      if (ok) {
        fails = 0;
        return;
      }
      fails++;
      if (fails < 2) return;
      fails = 0;
      restarting = true;
      DiagnosticsLog.add('agnes', '后端连续 2 次 /healthz 失败 → 尝试重启');
      try {
        await stop();
        if (_keepAlive) {
          // 端口会复用 [_preferredPort]，所以对外转发地址保持不变。
          await ensureStarted(rt);
          lastError = null;
          DiagnosticsLog.add('agnes', '后端已自动拉起');
        }
      } catch (e) {
        lastError = '$e';
        DiagnosticsLog.add('agnes', '自动拉起失败：$e');
      } finally {
        restarting = false;
        t.cancel();
      }
    });
  }

  static Future<bool> _ping(int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/healthz'));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 标记「外部正在用」：置 true 后 [releaseIfUnused] 不会再停服务。
  static void setKeepAlive(bool v) {
    _keepAlive = v;
    DiagnosticsLog.add('agnes', '设计站保活=${v ? '开' : '关'}');
  }

  /// 页面退出时调用：没人用（电脑访问没开）才真正停。
  static Future<void> releaseIfUnused() async {
    if (_keepAlive) return;
    await stop();
  }

  static Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    final w = _current;
    _current = null;
    if (w == null) return;
    try {
      w.process.kill(ProcessSignal.sigterm);
      await w.process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      try {
        w.process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  static Future<int> _pickFreePort() async {
    // 优先复用上次的端口（重启时）；占用失败再让系统挑。
    final want = _preferredPort;
    if (want != null) {
      try {
        final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, want);
        await probe.close();
        return want;
      } catch (_) {
        DiagnosticsLog.add('agnes', '上次的端口 $want 被占用，改让系统挑');
      }
    }
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    _preferredPort = p;
    return p;
  }

  /// 把 [prefix] 下的资产解到 `<root>/<sub>/`（按清单指纹幂等）。
  static Future<void> _unpackTo(
      String prefix, Directory root, String sub, DshRuntime rt) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets().where((p) => p.startsWith(prefix)).toList()
      ..sort();
    if (assets.isEmpty) throw StateError('安装包里没有 $prefix —— 构建时没把设计站打进去');

    var sum = 7;
    var bytes = 0;
    for (final a in assets) {
      for (final c in a.codeUnits) {
        sum = (sum * 31 + c) & 0x7fffffff;
      }
      bytes += (await rootBundle.load(a)).lengthInBytes;
    }
    sum = (sum * 31 + bytes) & 0x7fffffff;

    final target = Directory('${root.path}/$sub');
    final stamp = File('${root.path}/.$sub-$sum');
    if (target.existsSync() && stamp.existsSync()) return;

    if (target.existsSync()) {
      try {
        target.deleteSync(recursive: true);
      } catch (_) {}
    }
    target.createSync(recursive: true);
    for (final a in assets) {
      final rel = a.substring(prefix.length);
      if (rel.isEmpty) continue;
      final out = File('${target.path}/$rel');
      out.parent.createSync(recursive: true);
      final data = await rootBundle.load(a);
      out.writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: false,
      );
    }
    writeStringAtomicSync(stamp, '$sum\n');
    DiagnosticsLog.add('agnes',
        '已解包 $sub：${assets.length} 个文件 / ${(bytes / 1048576).toStringAsFixed(1)} MB');
  }
}
