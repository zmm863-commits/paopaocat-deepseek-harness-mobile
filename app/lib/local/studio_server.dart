import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// 「APP界面设计台」（m3e-canvas）的静态托管：**把随包的网页产物解包到私有目录，
/// 再用一个只绑 `127.0.0.1` 的小 HTTP 服务把它发出去**。
///
/// ## 为什么必须有这个服务（不能干脆让 WebView 直接读文件）
///
/// 产物是 **Next.js 静态导出**：HTML 里引用的是**绝对路径**（`/_next/static/…`）。
/// 用 `file:///android_asset/flutter_assets/assets/studio/index.html` 打开时，那些
/// `/_next/…` 会被解析成**文件系统根**（`file:///_next/…`）→ 全部 404、页面白屏。
/// 这不是靠改路径能绕过的（导出结构把绝对前缀写死了）。
///
/// 所以起一个**进程内的 loopback 服务**：把 `<filesDir>/studio/` 当网站根，
/// WebView 访问 `http://127.0.0.1:<随机端口>/` —— 绝对路径正好落在根下。
///
/// ## ⚠️ 它不是"容器"、也不是"外部服务"
///
///   * 它是 **App 自己进程里的一个 `HttpServer`**，不是 Docker、不需要宿主机；
///   * **只绑 loopback**（`127.0.0.1`，非 loopback 地址连不上）→ 不对外暴露；
///   * **不联网**：只读本地文件，一个字节都不往外发；
///   * 端口由系统随机分配（`port = 0`），页面关掉就 `stop()`。
///
/// ## 两个安全点（别省）
///
///   1. **路径穿越**：`%2e%2e%2f` 这类请求一律拒 —— 只允许根目录内的普通文件；
///   2. **只读**：只接受 `GET` / `HEAD`，其余一律 405。
class StudioServer {
  StudioServer._(this._server, this._port, this._root);

  final HttpServer _server;
  final int _port;
  final Directory _root;

  /// 把产物解包到私有目录时用的清单标记（内容指纹，见 [_unpack]）。
  static const String markerName = '.studio-unpacked';

  /// 产物在 Flutter assets 里的前缀（与 `pubspec.yaml` 的 `assets/studio/` 对应）。
  static const String assetPrefix = 'assets/studio/';

  /// 基址**以 `/` 结尾**（是"入口"不是"基址"，拼子路径自己接）。
  String get url => 'http://127.0.0.1:$_port/';

  /// 服务端口（日志/排查用；页面退出后这个端口就没了）。
  int get port => _port;

  /// 解包（幂等）+ 起服务。失败**抛异常**，由调用方如实显示原因。
  ///
  /// [filesDir] 是 App 私有目录（`DshRuntime.filesDir`）。
  /// [assetPrefix] / [subdir] / [markerName] 三个参数是为了**复用给别的静态 Web 产物**
  /// （2026-11-14 加：白板 Drawnix 也用这一套解包 + loopback 托管）。
  /// 不传就是原来的「APP界面设计台」行为，老调用方一个字都不用改。
  static Future<StudioServer> start({
    required String filesDir,
    String assetPrefix = 'assets/studio/',
    String subdir = 'studio',
    String markerName = '.studio-unpacked',
    String logTag = 'studio',
  }) async {
    final root =
        await _unpack(filesDir, assetPrefix, subdir, markerName, logTag);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = StudioServer._(server, server.port, root);
    // 不 await：`listen` 会一直挂着，直到服务被关掉。
    unawaited(s._serve());
    debugPrint('[dsh-studio] APP界面设计台已就绪：${s.url}（根=${root.path}）');
    return s;
  }

  Future<void> stop() async {
    try {
      await _server.close(force: true);
      debugPrint('[dsh-studio] 已关闭（端口 $_port）');
    } catch (e) {
      // 已经不在监听上了不算失败（照 MediaPreviewServer 的口径：如实记一条就行）。
      debugPrint('[dsh-studio] 关闭时出错（可能已经关了）：$e');
    }
  }

  // ─────────────────────────────────────────────────────────── 解包

  /// 把 `assets/studio/**` 解到 `<filesDir>/studio/`，返回那个目录。
  ///
  /// **幂等**：指纹没变就直接用现有的（不必每次启动都拷 3 MB）。
  /// ⚠️ 指纹用**自己算的确定性**校验和，**不要用 `String.hashCode`** ——
  /// Dart 的字符串 hashCode 不保证跨进程一致，用它会导致每次启动都重新解包。
  static Future<Directory> _unpack(
      String filesDir, String assetPrefix, String subdir, String markerName,
      String logTag) async {
    final root = Directory('$filesDir/$subdir');
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest
        .listAssets()
        .where((p) => p.startsWith(assetPrefix))
        .toList()
      ..sort();
    if (assets.isEmpty) {
      // 明确报错，不要静默起一个空站点（那会表现为"打开是白屏"，最难查）。
      throw StateError(
          '安装包里没有 $assetPrefix（构建时没把「APP界面设计台」打进去）—— 请重新构建 App。');
    }

    var sum = 7;
    for (final a in assets) {
      for (final c in a.codeUnits) {
        sum = (sum * 31 + c) & 0x7fffffff;
      }
    }
    final fingerprint = '${assets.length}-$sum';

    final marker = File('${root.path}/$markerName');
    if (root.existsSync() && marker.existsSync()) {
      try {
        if (marker.readAsStringSync().trim() == fingerprint) {
          debugPrint('[$logTag] 产物未变（$fingerprint），跳过解包');
          return root;
        }
      } catch (e) {
        debugPrint('[$logTag] 读标记失败，改为重新解包：$e');
      }
    }

    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
    var count = 0;
    for (final a in assets) {
      final rel = a.substring(assetPrefix.length);
      if (rel.isEmpty) continue;
      final out = File('${root.path}/$rel');
      out.parent.createSync(recursive: true);
      final data = await rootBundle.load(a);
      out.writeAsBytesSync(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      count++;
    }
    marker.writeAsStringSync(fingerprint);
    debugPrint('[$logTag] 已解包 $count 个文件 → ${root.path}（$fingerprint）');
    return root;
  }

  // ─────────────────────────────────────────────────────────── 服务

  Future<void> _serve() async {
    await for (final req in _server) {
      try {
        await _handle(req);
      } catch (e) {
        // 单个请求出错不能带走整个服务（否则用户看到的是"突然白了"）。
        debugPrint('[dsh-studio] 处理请求失败：$e');
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.method != 'GET' && req.method != 'HEAD') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }
    final file = resolveIn(_root, req.uri.path);
    if (file == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final bytes = await file.readAsBytes();
    res
      ..statusCode = HttpStatus.ok
      ..headers.contentLength = bytes.length;
    // ⚠️ 用 `headers.set` 传字符串：`headers.contentType` 要的是 `ContentType` 对象，
    //    直接赋字符串是编译错误（而我们的表本来就是 mime 字符串）。
    res.headers.set(HttpHeaders.contentTypeHeader, contentTypeFor(file.path));
    // 本地页面不缓存：免得换了产物还看到旧的。
    res.headers.set('cache-control', 'no-store');
    if (req.method == 'GET') res.add(bytes);
    await res.close();
  }

  /// URL 路径 → 根目录内的文件（拿不到就 null）。
  ///
  /// ⚠️ 这里是**唯一**的路径入口，两条防线都在里面：
  ///   * 任何 `.` / `..` 路径段一律拒（`%2e%2e` 这类解码后也在这一步被拦）；
  ///   * 解析出的绝对路径必须仍在根目录之下（防符号链接之类的绕过）。
  ///
  /// **公开**是为了能直接单测（这个函数是安全边界，坏掉的表现是"能读到根目录外的
  /// 文件"或者"正常文件打不开"，两种都不该靠肉眼 review 保证）。
  static File? resolveIn(Directory root, String urlPath) {
    String p;
    try {
      p = Uri.decodeComponent(urlPath);
    } catch (_) {
      return null; // 非法编码
    }
    if (p.isEmpty || p == '/') p = '/index.html';
    if (p.endsWith('/')) p = '${p}index.html';

    final segs = p.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return null;
    for (final s in segs) {
      if (s == '.' || s == '..' || s.contains('\u0000')) return null;
    }

    final f = File('${root.path}/${segs.join('/')}');
    if (!f.existsSync()) return null;
    final real = f.absolute.path;
    final base = root.absolute.path;
    if (!real.startsWith('$base/')) return null;
    return f;
  }

  /// 按扩展名给 Content-Type。**公开**同样是为了可测。
  static String contentTypeFor(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.html') || p.endsWith('.htm')) {
      return 'text/html; charset=utf-8';
    }
    if (p.endsWith('.js') || p.endsWith('.mjs')) {
      return 'text/javascript; charset=utf-8';
    }
    if (p.endsWith('.css')) return 'text/css; charset=utf-8';
    if (p.endsWith('.json')) return 'application/json; charset=utf-8';
    if (p.endsWith('.webmanifest')) return 'application/manifest+json';
    if (p.endsWith('.svg')) return 'image/svg+xml';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.gif')) return 'image/gif';
    if (p.endsWith('.ico')) return 'image/x-icon';
    if (p.endsWith('.woff2')) return 'font/woff2';
    if (p.endsWith('.woff')) return 'font/woff';
    if (p.endsWith('.ttf')) return 'font/ttf';
    if (p.endsWith('.txt') || p.endsWith('.md')) {
      return 'text/plain; charset=utf-8';
    }
    return 'application/octet-stream';
  }
}
