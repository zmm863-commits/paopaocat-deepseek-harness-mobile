/// 「检查更新」（L1）的回归测试。
///
/// ## 三组，各锁一件事
///
///   1. **版本比较**是纯函数，也是"会不会误报新版"的唯一判据 —— 这里全是
///      真踩过的形状（`0.9` 与 `0.10` 谁新、`1.0` 与 `1.0.0`、`-beta` 后缀）。
///   2. **清单解析**必须"严进"：缺字段 / 类型不对 / 不是 JSON 都要抛出一个
///      **能读懂是哪个字段**的错，绝不返回半个对象（半个对象会变成"0.00 可用"）。
///   3. **拉取**全部走本地假服务（`sources` 指过去），**不打真网络** ——
///      打真网络既慢又不可复现，还会把"GitHub 今天抽风"混进"我代码坏了"。
///
/// ⚠️ 第 3 组里有两条是**安全底线**，别删：
///   * 响应超大时必须中止（清单是 1 KB 量级的东西，不该被一个 8 MB 的响应撑死）；
///   * 三条源全不通时必须**返回失败而不是抛异常**（启动时那次自动检查没有
///     try/catch 兜着它 —— 它一抛，用户看到的是"App 打不开"）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/app_version.dart';
import 'package:dsh_mobile/local/update_checker.dart';
import 'package:dsh_mobile/local/update_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// 起一个本地假服务：按 `handler` 回响应，并把收到的请求路径记下来给断言用。
Future<({HttpServer server, List<String> paths})> _fakeServer(
  Future<void> Function(HttpRequest req) handler,
) async {
  final paths = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    paths.add(req.uri.path + (req.uri.query.isEmpty ? '' : '?${req.uri.query}'));
    try {
      await handler(req);
    } catch (_) {
      // 客户端提前断开（超体积那条会这样）不算测试失败。
    }
  });
  return (server: server, paths: paths);
}

/// 用假服务回的 JSON 造一份清单文本。
String _manifest({
  String version = '9.9.9',
  String url = 'https://example.test/app.apk',
  Object? size = 123456789,
  Object? notes = const <String>['修好 A', '新增 B'],
}) =>
    jsonEncode(<String, Object?>{
      'version': version,
      'url': url,
      'versionCode': 999,
      'size': size,
      'sha256': 'a' * 64,
      'minVersionCode': 0,
      'publishedAt': '2026-10-14',
      'notes': notes,
    });

Future<void> _json(HttpRequest req, String body, {int status = 200}) async {
  req.response.statusCode = status;
  req.response.headers.contentType =
      ContentType('application', 'json', charset: 'utf-8');
  req.response.write(body);
  await req.response.close();
}

void main() {
  group('版本比较（会不会误报新版全靠它）', () {
    test('按数字段比，不是按字符串比', () {
      // 这一条是整组里最要紧的：字符串比较会认为 '0.9' > '0.10'，得出反的结论。
      expect(compareVersions('0.10', '0.9'), greaterThan(0));
      expect(compareVersions('0.9', '0.10'), lessThan(0));
      expect(compareVersions('0.74', '0.75'), lessThan(0));
      expect(compareVersions('0.75', '0.74'), greaterThan(0));
      expect(compareVersions('0.75', '0.75'), 0);
    });

    test('段数不同按补 0 处理', () {
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('1.0.1', '1.0'), greaterThan(0));
      expect(compareVersions('1', '1.0.0'), 0);
      expect(compareVersions('1.2', '1.2.0.1'), lessThan(0));
    });

    test('尾巴上的非数字后缀只取数字前缀（预览版不该天天弹更新）', () {
      expect(compareVersions('0.75-beta', '0.75'), 0);
      expect(compareVersions('0.75', '0.75-beta'), 0);
      expect(compareVersions('0.76-rc1', '0.75'), greaterThan(0));
    });

    test('认不出来的段算 0，空白版本不冒充新版', () {
      expect(compareVersions('', '0'), 0);
      expect(compareVersions('', '1'), lessThan(0));
      expect(compareVersions('x.y', '0.0'), 0);
      expect(compareVersions('0.75', ''), greaterThan(0));
    });

    test('当前版本与远端同号 = 不是新版（避免"永远提示更新"）', () {
      expect(compareVersions(kAppVersion, kAppVersion), 0);
      expect(compareVersions(kAppVersion, '99.99'), lessThan(0));
    });
  });

  group('清单解析（严进：半个对象比报错更糟）', () {
    test('正常清单每项都读对', () {
      final info = UpdateInfo.parse(_manifest(size: '111504031'));
      expect(info.version, '9.9.9');
      expect(info.url, 'https://example.test/app.apk');
      expect(info.versionCode, 999);
      // `size` 写成字符串也认（发版时手写 JSON 很容易加引号）。
      expect(info.size, 111504031);
      expect(info.sha256, 'a' * 64);
      expect(info.publishedAt, '2026-10-14');
      expect(info.notes, <String>['修好 A', '新增 B']);
    });

    test('可选字段缺了不影响：notes 空、size 没给也能用', () {
      final info = UpdateInfo.parse(jsonEncode(<String, Object>{
        'version': '1.0',
        'url': 'https://example.test/a.apk',
      }));
      expect(info.notes, isEmpty);
      expect(info.size, isNull);
      expect(info.publishedAt, isNull);
    });

    test('notes 里混进非字符串/空串只跳过，不整条失败', () {
      final info = UpdateInfo.parse(jsonEncode(<String, Object?>{
        'version': '1.0',
        'url': 'https://example.test/a.apk',
        'notes': <Object?>['好的', 42, '', '  也好的  ', null],
      }));
      expect(info.notes, <String>['好的', '也好的']);
    });

    test('缺 version / 缺 url → 报错并且点名字段', () {
      for (final missing in <String>['version', 'url']) {
        final m = <String, Object?>{
          'version': '1.0',
          'url': 'https://example.test/a.apk',
        }..remove(missing);
        expect(
          () => UpdateInfo.parse(jsonEncode(m)),
          throwsA(isA<UpdateManifestError>()
              .having((e) => e.toString(), 'toString', contains(missing))),
          reason: '缺 $missing 时必须点名',
        );
      }
    });

    test('空内容 / 不是 JSON / 顶层不是对象 → 各有各的话', () {
      expect(() => UpdateInfo.parse('   '),
          throwsA(isA<UpdateManifestError>()));
      expect(() => UpdateInfo.parse('not json at all'),
          throwsA(isA<UpdateManifestError>()));
      // 顶层是数组（有人把 releases 列表直接当清单发出来）也要挡住。
      expect(() => UpdateInfo.parse('[{"version":"1.0"}]'),
          throwsA(isA<UpdateManifestError>()));
      expect(() => UpdateInfo.parse('"1.0"'),
          throwsA(isA<UpdateManifestError>()));
    });
  });

  group('拉取（本地假服务，多源回退）', () {
    test('第一个源 500、第二个源好 → 用第二个，并如实记下试过谁', () async {
      final bad = await _fakeServer((req) => _json(req, 'boom', status: 500));
      final good = await _fakeServer((req) => _json(req, _manifest()));
      addTearDown(() async {
        await bad.server.close(force: true);
        await good.server.close(force: true);
      });

      final r = await checkForUpdate(
        sources: <String>[
          'http://127.0.0.1:${bad.server.port}/update.json',
          'http://127.0.0.1:${good.server.port}/update.json',
        ],
        timeout: const Duration(seconds: 5),
      );

      expect(r.ok, isTrue);
      expect(r.hasUpdate, isTrue, reason: '9.9.9 比当前 $kAppVersion 新');
      expect(r.info!.version, '9.9.9');
      expect(r.sourceUsed, contains('${good.server.port}'));
      expect(r.tried, hasLength(1), reason: '第一个源的失败要被记下来');
      expect(r.tried.first, contains('500'));
    });

    test('旧版本清单 = 没有新版（ok 为真，这不是失败）', () async {
      final s = await _fakeServer((req) => _json(req, _manifest(version: '0.0.1')));
      addTearDown(() => s.server.close(force: true));

      final r = await checkForUpdate(
        sources: <String>['http://127.0.0.1:${s.server.port}/update.json'],
      );
      expect(r.ok, isTrue);
      expect(r.hasUpdate, isFalse);
      // summary 是给界面用的一句话，不能自己抛异常。
      expect(r.summary, contains('已是最新版本'));
    });

    test('全是坏 JSON / 404 / 连不上 → 返回失败而不抛异常', () async {
      final junk = await _fakeServer((req) => _json(req, '{ 这不是 json'));
      final missing = await _fakeServer((req) => _json(req, 'nope', status: 404));
      addTearDown(() async {
        await junk.server.close(force: true);
        await missing.server.close(force: true);
      });

      final r = await checkForUpdate(
        sources: <String>[
          'http://127.0.0.1:${junk.server.port}/update.json',
          'http://127.0.0.1:${missing.server.port}/update.json',
          // 关掉的端口 → 连接被拒（SocketException）
          'http://127.0.0.1:1/update.json',
        ],
        timeout: const Duration(seconds: 3),
      );

      expect(r.ok, isFalse);
      expect(r.info, isNull);
      expect(r.errorZh, isNotNull);
      expect(r.tried, hasLength(3), reason: '三条都要留下失败原因');
      // ⚠️ **不按下标断言**（0.81 起多源是并发发出的，谁先失败不定）：
      //    只要求三种失败原因都留下痕迹，顺序交给调度。
      final joined = r.tried.join(' | ');
      expect(joined, contains('JSON'));
      expect(joined, contains('404'));
      expect(joined, anyOf(contains('连不上'), contains('拒绝')));
    });

    test('并发取源：慢的那条不能把快的拖住（0.81 真机白等 8 秒的回归）', () async {
      // 一条永远不回（客户端超时 3s 才失败），一条立刻回。
      // 串行版会先等满 3 秒；并发版应该**立刻**拿到快的那条。
      final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => slow.close(force: true));
      slow.listen((req) {
        // 故意不回，让客户端自己超时
      });
      final fast = await _fakeServer((req) => _json(req, '{"version":"9.9.9","url":"http://x/a.apk","size":1,"sha256":"aa"}'));

      addTearDown(() async {
        await fast.server.close(force: true);
      });

      final sw = Stopwatch()..start();
      final r = await checkForUpdate(
        sources: <String>[
          'http://127.0.0.1:${slow.port}/update.json', // 慢的放前面（真机上 raw 就是这个位置）
          'http://127.0.0.1:${fast.server.port}/update.json',
        ],
        timeout: const Duration(seconds: 3),
      );
      sw.stop();

      expect(r.ok, isTrue);
      expect(r.sourceUsed, contains('${fast.server.port}'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
          reason: '慢源在排队等超时的话这里会接近 3 秒');
    });

    test('响应超大时中止（清单是 1 KB 量级，不该被 8 MB 撑死）', () async {
      // 比上限大一点点即可，不必真写 8 MB。
      final big = 'x' * (kMaxManifestBytes + 4096);
      final s = await _fakeServer((req) async {
        req.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        // 分块吐，让客户端有机会在读的**过程中**就发现超了。
        for (var i = 0; i < big.length; i += 65536) {
          req.response.write(big.substring(
              i, i + 65536 > big.length ? big.length : i + 65536));
          await req.response.flush();
        }
        await req.response.close();
      });
      addTearDown(() => s.server.close(force: true));

      final r = await checkForUpdate(
        sources: <String>['http://127.0.0.1:${s.server.port}/update.json'],
        timeout: const Duration(seconds: 10),
      );
      expect(r.ok, isFalse);
      expect(r.tried.first, contains('过大'));
    });

    test('连不上就是一个明确的中文原因，且不抛', () async {
      // 0.0.0.0:1 这种端口不会被占用，连接会立刻被拒。
      final r = await checkForUpdate(
        sources: <String>['http://127.0.0.1:1/update.json'],
        timeout: const Duration(seconds: 3),
      );
      expect(r.ok, isFalse);
      expect(r.errorZh, isNotNull);
      expect(r.tried, hasLength(1));
      expect(r.tried.first, contains('连不上'));
    });

    test('用户自填源时只用它 —— 不去试内置那两条', () async {
      final s = await _fakeServer((req) => _json(req, _manifest()));
      addTearDown(() => s.server.close(force: true));

      final r = await checkForUpdate(
        customSource: 'http://127.0.0.1:${s.server.port}/update.json',
        timeout: const Duration(seconds: 5),
      );
      expect(r.ok, isTrue);
      // 只试了一条（`tried` 是"失败清单"，成功那条不进 tried）
      expect(r.tried, isEmpty);
      expect(r.sourceUsed, contains('${s.server.port}'));
    });

    test('bypassCache 会给 URL 挂时间戳（手动检查不吃 CDN 缓存）', () async {
      final s = await _fakeServer((req) => _json(req, _manifest()));
      addTearDown(() => s.server.close(force: true));
      final base = 'http://127.0.0.1:${s.server.port}/update.json';

      await checkForUpdate(sources: <String>[base], bypassCache: true);
      await checkForUpdate(sources: <String>[base]);

      expect(s.paths[0], contains('t='), reason: '第一次要带时间戳');
      expect(s.paths[1], isNot(contains('t=')), reason: '自动那次不带');
    });

    test('清单里的 sha256 与 size 会被带出来（L2 下载校验要用）', () async {
      final s = await _fakeServer((req) =>
          _json(req, _manifest(size: 111504031, url: 'https://x/y.apk')));
      addTearDown(() => s.server.close(force: true));

      final r = await checkForUpdate(
          sources: <String>['http://127.0.0.1:${s.server.port}/u.json']);
      expect(r.info!.url, 'https://x/y.apk');
      expect(r.info!.size, 111504031);
      expect(r.info!.sha256, 'a' * 64);
    });
  });

  group('小工具', () {
    test('formatBytes 用 1024 进制、保留一位小数', () {
      expect(formatBytes(null), '—');
      expect(formatBytes(0), '—');
      expect(formatBytes(900), '900 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(111504031), '106.3 MB');
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.00 GB');
    });

    test('更新源地址校验：只收 http(s) 且有主机名', () {
      expect(looksLikeUpdateSource('https://example.com/update.json'), isTrue);
      expect(looksLikeUpdateSource('http://127.0.0.1:8080/u.json'), isTrue);
      expect(looksLikeUpdateSource('  https://a.cn/x  '), isTrue);
      expect(looksLikeUpdateSource(''), isFalse);
      expect(looksLikeUpdateSource('ftp://a/b'), isFalse);
      expect(looksLikeUpdateSource('example.com/u.json'), isFalse);
      expect(looksLikeUpdateSource('https://'), isFalse);
    });

    test('内置源顺序：raw 在 jsDelivr 前面（新鲜度优先）', () {
      final list = defaultUpdateSources();
      expect(list, hasLength(2));
      expect(list.first, contains('raw.githubusercontent.com'));
      expect(list.last, contains('cdn.jsdelivr.net'));
      // 两条指的是**同一份**清单，只是入口不同 —— 这点别被名字绕进去。
      expect(list.first, endsWith('/$kUpdateManifestName'));
      expect(list.last, endsWith('/$kUpdateManifestName'));
      expect(kReleasesPage, contains('/releases/latest'));
    });
  });
}
