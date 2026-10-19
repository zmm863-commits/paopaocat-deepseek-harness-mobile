/// 「检查更新」：拉那份 `update.json`、解析、比版本。
///
/// ## 这一层只干三件事，不碰安装
///
///   1. 按 [defaultUpdateSources]（或用户自填的镜像）依次拉清单，**一个源失败就换下一个**；
///   2. 严格解析 —— 缺字段 / 类型不对都给出**具体是哪个字段**的问题，不假装解析成功；
///   3. 与 [kAppVersion] 比大小，告诉调用方"有没有新版、新版是什么"。
///
/// 下载、校验、装包是下一阶段（L2）的事，不在这里。所以这个文件里
/// **没有任何写文件的动作** —— 检查更新不该有副作用。
///
/// ## 静默约定（重要，别改）
///
/// [checkForUpdate] **不抛异常、不弹窗**：网络不通是常态（国内访问 GitHub 时好时坏），
/// 一次检查失败绝不该打扰用户，更不该卡启动。失败信息一律通过返回值的
/// [UpdateCheckResult.errorZh] 交给调用方 —— 由**设置页**决定要不要显示。
/// 启动时的自动检查连设置页都不用刷，看一眼日志就够。
///
/// ## 为什么不引第三方 HTTP 包
///
/// 同 `model_fetcher.dart`：只为一次 GET 给 APK 加依赖不值。用 `dart:io` 的
/// HttpClient，并且自己**限制响应体积**（见 [kMaxManifestBytes]）——
/// 清单是 1 KB 量级的东西，真有人塞个 100 MB 的响应回来，不该把我们撑死。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../app_version.dart';
import '../i18n/dsh_i18n.dart';
import 'update_source.dart';

/// 清单响应体积上限。正常 1 KB 量级；给到 256 KB 是留足余量
/// （将来 notes 写长一点也不会撞上），同时挡住"拿大文件冒充清单"。
const int kMaxManifestBytes = 256 * 1024;

/// 单个源的默认超时。**刻意短**：检查更新是后台行为，宁可这次查不到，
/// 也不要让用户点了按钮干等 20 秒。
const Duration kUpdateCheckTimeout = Duration(seconds: 8);

/// 清单解析失败。带上"哪个字段有问题"，方便定位是发版时手写错了。
class UpdateManifestError implements Exception {
  const UpdateManifestError(this.zh, {this.detail});

  /// 中文人话（会显示在设置页上）。
  final String zh;

  /// 机器侧细节（字段名、收到的类型），进日志。
  final String? detail;

  @override
  String toString() => detail == null ? zh : '$zh（$detail）';
}

/// 一份清单解析出来的版本信息。
///
/// 字段与 `update.json` 一一对应；只有 [version] 和 [url] 是必需的 ——
/// 少了 `size`/`sha256` 只影响"能不能精确显示与校验"，不该让整次检查失败。
/// 这次更新该下**哪个包**（[UpdateInfo.pickVariant] 的结果）。
///
/// 有它之后，"下哪个包"只在**一处**决定 —— 界面不自己拼 URL、也不自己猜大小，
/// 免得出现"按精简包显示体积、实际下了完整包"这种对不上账的事。
class UpdateVariant {
  const UpdateVariant({
    required this.url,
    required this.includesRuntime,
    this.size,
    this.sha256,
  });

  final String url;
  final int? size;
  final String? sha256;

  /// 这个包里**含运行时**（装完即用、无网也能打开）。
  final bool includesRuntime;

  /// 给界面显示的一行小字：让用户知道自己下的是哪一个。
  String get label => includesRuntime ? tr('含运行环境') : tr('仅更新');
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.url,
    this.urlFull,
    this.sizeFull,
    this.sha256Full,
    this.versionCode,
    this.size,
    this.sha256,
    this.minVersionCode,
    this.publishedAt,
    this.notes = const <String>[],
  });

  /// 版本号，例如 `0.75`。
  final String version;

  /// APK 直链（Release 附件）。**这是"精简包"** —— 不含运行时，
  /// 给"手机里已经有运行时"的老用户更新用（省 32 MB）。
  final String url;

  /// **完整包**直链（含运行时，装完即用）。清单里没有这个字段时为 null。
  ///
  /// 为什么要有它：精简包在**没有运行时**的机器上连界面都进不去 ——
  /// 所以"新装 / 清了数据"这种情况必须拿完整包，不能只给精简包。
  final String? urlFull;

  /// 完整包的大小与哈希（显示与校验用；与 [size]/[sha256] 各管一个包）。
  final int? sizeFull;
  final String? sha256Full;

  /// Android 的 versionCode（能拿到就比它，比字符串更可靠）。
  final int? versionCode;

  /// 包大小（字节）。显示成 MB 用。
  final int? size;

  /// 包的 sha256（16 进制，小写比较）。L2 下载完要拿它校验。
  final String? sha256;

  /// 低于这个 versionCode 就必须更新（L1 只提示、不强制）。
  final int? minVersionCode;

  /// 发布时间（`YYYY-MM-DD`）。
  final String? publishedAt;

  /// 这一版改了什么，每条一句话。
  final List<String> notes;

  /// 从清单文本解析。**任何不合格都抛 [UpdateManifestError]** —— 不返回
  /// "半个对象"，因为半个对象最容易变成"显示成 0.00 可用"这种坏界面。
  static UpdateInfo parse(String body) {
    if (body.trim().isEmpty) {
      throw UpdateManifestError(tr('更新源返回了空内容。'), detail: 'empty body');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw UpdateManifestError(tr('更新源返回的不是合法 JSON。'),
          detail: 'jsonDecode: ${e.message}');
    }

    if (decoded is! Map) {
      throw UpdateManifestError(tr('更新源的格式不对：它应该是一个 JSON 对象。'),
          detail: 'top-level type = ${decoded.runtimeType}');
    }

    final version = _requireString(decoded, 'version');
    final url = _requireString(decoded, 'url');

    final notes = <String>[];
    final rawNotes = decoded['notes'];
    if (rawNotes is List) {
      for (final n in rawNotes) {
        if (n is String && n.trim().isNotEmpty) notes.add(n.trim());
      }
    }

    return UpdateInfo(
      version: version,
      url: url,
      urlFull: _optString(decoded, 'urlFull'),
      sizeFull: _optInt(decoded, 'sizeFull'),
      sha256Full: _optString(decoded, 'sha256Full')?.toLowerCase(),
      versionCode: _optInt(decoded, 'versionCode'),
      size: _optInt(decoded, 'size'),
      sha256: _optString(decoded, 'sha256'),
      minVersionCode: _optInt(decoded, 'minVersionCode'),
      publishedAt: _optString(decoded, 'publishedAt'),
      notes: notes,
    );
  }

  /// 挑这次该下哪个包。
  ///
  /// **2026-10-19 用户决定：不再发精简包，一律完整包**（内含运行环境）。
  /// 理由：精简包让"更新运行环境"变成必须联网下载 —— 升级体验不可控（用户连着报
  /// 「更新后像重装」「装精简包不该直接进页面吗」）。完整包自带运行环境，升级时
  /// 本地就能铺好，一个下载搞定。
  ///
  /// 所以规则简化成：**清单给了完整包（urlFull）就下完整包**；只给了 url 才退回它
  /// （兼容旧清单，那种情况下 App 会在准备运行环境那一步现下运行时）。
  UpdateVariant pickVariant({required bool runtimeReady}) {
    final full = urlFull;
    if (full != null) {
      return UpdateVariant(
        url: full,
        size: sizeFull,
        sha256: sha256Full,
        includesRuntime: true,
      );
    }
    return UpdateVariant(url: url, size: size, sha256: sha256, includesRuntime: false);
  }

  static String _requireString(Map<Object?, Object?> m, String key) {
    final v = m[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    // 占位符走 `tr` 的第二参数（**不要**在 key 里塞 Dart 插值，那样表里查不到）。
    throw UpdateManifestError(
      tr('更新源缺少 {0} 字段，或者它不是一个非空字符串。', [key]),
      detail: '$key = ${v == null ? 'missing' : v.runtimeType}',
    );
  }

  static String? _optString(Map<Object?, Object?> m, String key) {
    final v = m[key];
    if (v is String) {
      final s = v.trim();
      return s.isEmpty ? null : s;
    }
    return null;
  }

  /// 允许数字，也允许"数字字符串" —— 发版时手写 JSON 很容易把 `size` 写成
  /// `"111504031"`，没必要为这个让整次检查失败。
  static int? _optInt(Map<Object?, Object?> m, String key) {
    final v = m[key];
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }
}

/// 一次检查的结果。**不抛异常**，失败也走这个对象（见文件头的静默约定）。
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.ok,
    this.info,
    this.hasUpdate = false,
    this.errorZh,
    this.sourceUsed,
    this.tried = const <String>[],
  });

  /// 有没有**成功拿到并解析**清单。注意：`ok = true` 且 `hasUpdate = false`
  /// 表示"已经是最新版"，这是好消息，不是失败。
  final bool ok;

  /// 远端最新版信息（成功时才有）。
  final UpdateInfo? info;

  /// 远端版本是不是比当前 [kAppVersion] 新。
  final bool hasUpdate;

  /// 失败原因（中文人话）。**只在 `ok = false` 时有值**。
  final String? errorZh;

  /// 最终成功用的是哪个源（成功时才有）。
  final String? sourceUsed;

  /// 依次试过的源，格式 `源 → 原因`（给"三条都不通"时显示，便于照方抓药）。
  final List<String> tried;

  /// 给界面用的一句话：**只描述事实**，不替用户决定要不要更新。
  String get summary => ok
      ? (hasUpdate
          ? tr('发现新版本 v{0}', [info!.version])
          : tr('已是最新版本（v{0}）', [kAppVersion]))
      : tr('检查失败：{0}', [errorZh ?? tr('原因未知')]);
}

/// 把字节数写成给人看的大小（`111.5 MB`）。
///
/// 用 1024 进制并保留一位小数：与系统「应用信息」里的显示口径一致，
/// 免得同一个包在系统里是 106.3 MB、在我们这里变成 111.5 MB 让人以为下错了。
String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '—';
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// 比较两个版本号：`a` 比 `b` 新返回正数，旧返回负数，相同返回 0。
///
/// 规则（都是踩过的坑，见测试）：
///   * **按数字段比，不按字符串** —— `0.9` 比 `0.10` **旧**，字符串比较会得出反的；
///   * 段数不同按补 0 处理 —— `1.0` 与 `1.0.0` 相等，`1.0.1` 比 `1.0` 新；
///   * 尾巴上的非数字后缀只取数字前缀 —— `0.75-beta` 与 `0.75` 视为同一版；
///   * 认不出来的一段算 0（宁可判成"没新版"，也不要因为一个怪版本号天天弹更新）。
int compareVersions(String a, String b) {
  final pa = _versionParts(a);
  final pb = _versionParts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int> _versionParts(String raw) {
  final out = <int>[];
  final cleaned = raw.trim();
  if (cleaned.isEmpty) return <int>[0];
  for (final seg in cleaned.split('.')) {
    final m = RegExp(r'\d+').firstMatch(seg);
    out.add(m == null ? 0 : (int.tryParse(m.group(0)!) ?? 0));
  }
  // 去掉尾部多余的 0，让 `1.0.0` 与 `1` 相等。
  while (out.length > 1 && out.last == 0) {
    out.removeLast();
  }
  return out;
}

/// 检查更新。
///
/// [customSource] 非空时**只用它** —— 用户显式填了镜像，说明他更清楚自己那边
/// 哪条通，这时再去试内置的源只是白等一次超时。
/// [sources] 覆盖内置源列表（**给测试与将来多源用**；两条都为 null 时用
/// [defaultUpdateSources]）。优先级：`customSource` > `sources` > 内置。
/// [bypassCache] 为 true 时给 URL 挂一个时间戳参数：手动点「检查更新」用它，
/// 免得刚在电脑上传了新清单、手机上却还拿到 CDN 缓存里的旧那份。
/// [clientFactory] 是测试注入口（真机上永远是默认的 `HttpClient()`）。
Future<UpdateCheckResult> checkForUpdate({
  String? customSource,
  List<String>? sources,
  bool bypassCache = false,
  Duration timeout = kUpdateCheckTimeout,
  HttpClient Function()? clientFactory,
}) async {
  final custom = (customSource ?? '').trim();
  final sourcesToTry = custom.isNotEmpty
      ? <String>[custom]
      : (sources ?? defaultUpdateSources());

  final tried = <String>[];
  for (final base in sourcesToTry) {
    final url = bypassCache
        ? '$base${base.contains('?') ? '&' : '?'}t=${DateTime.now().millisecondsSinceEpoch}'
        : base;
    try {
      final body = await fetchJsonManifest(
        url,
        timeout: timeout,
        clientFactory: clientFactory,
      );
      final info = UpdateInfo.parse(body);
      final hasUpdate = compareVersions(info.version, kAppVersion) > 0;
      debugPrint('[dsh-update] ok source=$base version=${info.version} '
          'current=$kAppVersion hasUpdate=$hasUpdate');
      return UpdateCheckResult(
        ok: true,
        info: info,
        hasUpdate: hasUpdate,
        sourceUsed: base,
        tried: tried,
      );
    } catch (e) {
      final why = _reasonOf(e);
      tried.add('$base → $why');
      debugPrint('[dsh-update] source failed: $base → $why');
    }
  }

  return UpdateCheckResult(
    ok: false,
    errorZh: custom.isNotEmpty
        ? tr('你填的这个更新源没有返回可用的版本信息。')
        : tr('三个更新源都没连上（多半是网络问题，过一会儿再试）。'),
    tried: tried,
  );
}

/// 把异常翻译成一句中文人话。**分类要具体** —— "网络错误"这种话对排查没帮助。
String _reasonOf(Object e) {
  if (e is UpdateManifestError) return e.zh;
  if (e is TimeoutException) return tr('超时');
  if (e is SocketException) {
    final m = e.message;
    return m.isEmpty ? tr('连不上') : '${tr('连不上')}：$m';
  }
  if (e is HandshakeException) return tr('安全连接失败');
  if (e is HttpException) return e.message;
  if (e is _ManifestTooLarge) return tr('返回内容过大（不像一份版本清单）');
  return e.toString();
}

class _ManifestTooLarge implements Exception {
  const _ManifestTooLarge(this.bytes);
  final int bytes;
  @override
  String toString() => 'manifest exceeds $kMaxManifestBytes bytes ($bytes)';
}

/// 拉一份**小 JSON 清单**（更新清单 `update.json`、运行时清单 `runtime.json` 都是它）。
///
/// 公开出来给 `runtime_bootstrap.dart` 复用：两者要做的事一模一样 ——
/// 从 URL 取一份 1 KB 量级的 JSON、**限制体积**、超时/非 200 都抛异常。
/// 同一件事写两遍，迟早只有一处被修（本项目的老教训）。
///
/// 抛出的异常由调用方分类（`SocketException` / `TimeoutException` /
/// [UpdateManifestError] / `_ManifestTooLarge`），`update_checker` 内部的
/// `_reasonOf` 就是把它们翻成人话的那一处。
Future<String> fetchJsonManifest(
  String url, {
  required Duration timeout,
  HttpClient Function()? clientFactory,
}) async {
  final client = (clientFactory ?? HttpClient.new)()
    ..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    // 带一个自己认得的 UA：更新源那边万一要看访问来源，日志里能认出来。
    request.headers.set(HttpHeaders.userAgentHeader, 'paopaocat-dsh-mobile/$kAppVersion');
    final response = await request.close().timeout(timeout);

    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }

    // 边收边数：超过上限立刻断开，别把整个响应读进内存再判断。
    final acc = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      acc.addAll(chunk);
      if (acc.length > kMaxManifestBytes) {
        throw _ManifestTooLarge(acc.length);
      }
    }
    return utf8.decode(acc, allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}
