import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/local/port_forwarder.dart';

/// 端口转发器：两条链路都要能说清「为什么是这个结果」。
///
/// * 上游活着 → 原样转发（SSE / WebSocket 靠的就是这条，不能被解析坏）；
/// * 上游死了 → **502 + 一整页可读的中文交代**（0.81 之前是一片白，
///   用户根本不知道发生了什么，也不知道该去哪儿按）。
void main() {
  /// 挑一个确定没人监听的端口：先 bind 再立刻释放。
  Future<int> deadPort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  Future<HttpClientResponse> get(int port, {String path = '/'}) async {
    final c = HttpClient();
    try {
      final req = await c.get('127.0.0.1', port, path);
      return await req.close();
    } finally {
      // 调用方读完再关；这里只放掉空闲连接池
      c.close(force: false);
    }
  }

  test('上游不通时回 502，且页面把「怎么回事 / 怎么办」写清楚', () async {
    final fwd = PortForwarder.create();
    final target = await deadPort();
    final listen = await fwd.start(targetPort: target, listenPort: 0);
    addTearDown(fwd.stop);

    final res = await get(listen);
    final body = await res.transform(utf8.decoder).join();

    expect(res.statusCode, 502);
    expect(res.headers.contentType?.mimeType, 'text/html');
    // 四条一定要在：出了什么事、去哪儿打开、它会自己重连、不用手动刷新。
    expect(body, contains('手机上的服务已经停了'));
    expect(body, contains('移动桌面平台'));
    expect(body, contains('不用手动刷新'));
    expect(body, contains('location.reload'));
    // 端口要写进页面（用户报问题时能直接念出来）
    expect(body, contains('127.0.0.1:$target'));
    // 不能引用任何外部资源 —— 此刻手机可能连网都没了
    expect(RegExp(r'(src|href)\s*=\s*["\x27]https?://').hasMatch(body), isFalse);
  });

  test('上游活着时逐字节转发，返回上游自己的状态码与正文', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(upstream.close);
    upstream.listen((req) {
      req.response
        ..statusCode = 401
        ..headers.contentType = ContentType.json
        ..write('{"ok":false,"why":"no-token"}');
      req.response.close();
    });

    final fwd = PortForwarder.create();
    final listen = await fwd.start(targetPort: upstream.port, listenPort: 0);
    addTearDown(fwd.stop);

    final res = await get(listen, path: '/api/models');
    final body = await res.transform(utf8.decoder).join();

    // 关键：转发器**不许**改写上游的状态码 —— DSH 的 403/401 围栏全靠它
    expect(res.statusCode, 401);
    expect(body, '{"ok":false,"why":"no-token"}');
  });

  test('页面模板里的端口占位符会被真实端口替换（不留 __PORT__）', () async {
    final fwd = PortForwarder.create();
    final target = await deadPort();
    final listen = await fwd.start(targetPort: target, listenPort: 0);
    addTearDown(fwd.stop);

    final body =
        await (await get(listen)).transform(utf8.decoder).join();
    expect(body, isNot(contains('__PORT__')));
  });

  test('停掉之后端口立刻拒绝连接（开关一关，电脑那边就该连不上）', () async {
    final fwd = PortForwarder.create();
    final target = await deadPort();
    final listen = await fwd.start(targetPort: target, listenPort: 0);
    await fwd.stop();

    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, listen),
      throwsA(isA<SocketException>()),
    );
  });

  // ── 对外地址改写（0.81）：让用户手里的链接长期有效 ────────────────────
  //
  // 真机现场（2026-10-30 截图）：电脑打开复制的地址，得到
  // `dsh web authentication required; reopen the URL printed by dsh web.`
  // 因为 DSH 的 launchToken 是进程内随机生成、每次重启都换 —— 复制出去的地址
  // 一次就废。转发层现在把「App 固定口令」换成当前 launchToken，并把 Host
  // 改回回环（连 --trusted-host 都不用了，开关也不再重启 DSH）。
  group('首个请求头改写', () {
    /// 起一个假上游，记录它收到的 path / host / origin。
    Future<(HttpServer, List<(String path, String host, String origin)>)>
        upstreamRecorder() async {
      final seen = <(String, String, String)>[];
      final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((req) {
        seen.add((
          req.uri.toString(),
          req.headers.value('host') ?? '',
          req.headers.value('origin') ?? '',
        ));
        req.response
          ..statusCode = 200
          ..write('ok');
        req.response.close();
      });
      return (srv, seen);
    }

    test('固定口令被换成 launchToken，Host 改回回环', () async {
      final (up, seen) = await upstreamRecorder();
      addTearDown(up.close);
      final fwd = PortForwarder.create();
      final listen = await fwd.start(
        targetPort: up.port,
        listenPort: 0,
        rewrite: ForwardRewrite(
          fixedToken: 'fixed-token-abc',
          upstreamToken: 'launch-token-xyz',
          upstreamAuthority: '127.0.0.1:${up.port}',
        ),
      );
      addTearDown(fwd.stop);

      final res = await get(listen, path: '/?token=fixed-token-abc');
      expect(res.statusCode, 200);
      await res.drain<void>();

      expect(seen, hasLength(1));
      expect(seen.first.$1, contains('token=launch-token-xyz'));
      expect(seen.first.$1, isNot(contains('fixed-token-abc')));
      // Host 必须是上游自己 —— 否则 DSH 的 browser-trust fence 直接 403
      expect(seen.first.$2, '127.0.0.1:${up.port}');
    });

    test('别的 token 原样送上去（不许把鉴权打开）', () async {
      final (up, seen) = await upstreamRecorder();
      addTearDown(up.close);
      final fwd = PortForwarder.create();
      final listen = await fwd.start(
        targetPort: up.port,
        listenPort: 0,
        rewrite: const ForwardRewrite(
          fixedToken: 'fixed-token-abc',
          upstreamToken: 'launch-token-xyz',
          upstreamAuthority: '127.0.0.1:1',
        ),
      );
      addTearDown(fwd.stop);

      final res = await get(listen, path: '/?token=someone-else');
      await res.drain<void>();

      expect(seen.single.$1, contains('token=someone-else'));
      expect(seen.single.$1, isNot(contains('launch-token-xyz')));
    });

    test('不带 token 的请求只改 Host，路径与其它参数不动', () async {
      final (up, seen) = await upstreamRecorder();
      addTearDown(up.close);
      final fwd = PortForwarder.create();
      final listen = await fwd.start(
        targetPort: up.port,
        listenPort: 0,
        rewrite: const ForwardRewrite(
          fixedToken: 'fixed-token-abc',
          upstreamToken: 'launch-token-xyz',
          upstreamAuthority: '127.0.0.1:46123',
        ),
      );
      addTearDown(fwd.stop);

      final res = await get(listen, path: '/api/sessions?limit=5');
      await res.drain<void>();

      expect(seen.single.$1, '/api/sessions?limit=5');
      expect(seen.single.$2, '127.0.0.1:46123');
    });

    test('强制 Connection: close（否则同连接上的第二个请求会带着外部 Host 被 403）', () async {
      final com = Completer<String>();
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(srv.close);
      srv.listen((c) {
        final b = <int>[];
        c.listen((d) {
          b.addAll(d);
          final txt = utf8.decode(b, allowMalformed: true);
          if (txt.contains('\r\n\r\n') && !com.isCompleted) {
            final m = RegExp(r'\r\nconnection:\s*([^\r\n]+)', caseSensitive: false)
                .firstMatch(txt);
            com.complete(m?.group(1)?.trim() ?? '(没有 connection 头)');
            c.destroy();
          }
        });
      });

      final fwd = PortForwarder.create();
      final listen = await fwd.start(
        targetPort: srv.port,
        listenPort: 0,
        rewrite: const ForwardRewrite(
          fixedToken: 'nope',
          upstreamToken: 'x',
          upstreamAuthority: '127.0.0.1:1',
        ),
      );
      addTearDown(fwd.stop);

      final sock = await Socket.connect(InternetAddress.loopbackIPv4, listen);
      sock.write('GET / HTTP/1.1\r\nHost: 192.168.1.100:45721\r\n\r\n');

      expect(await com.future.timeout(const Duration(seconds: 5)), 'close');
      sock.destroy();
    });

    test('整页几十个资源：每一次请求都要被改写（否则第 2 个起就 403）', () async {
      // 真机风险点（0.81 自评里写的）：我们只改写「一个连接上的第一个请求头」，
      // 靠 `Connection: close` 让每个请求各占一条连接。这一条就是拿 40 个请求
      // 把「整页资源」的场景压一遍 —— 只要有一个没被改写，上游看到的 Host
      // 就还是外部地址，DSH 的 browser-trust fence 会 403。
      const n = 40;
      final hosts = <String>[];
      final up = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(up.close);
      up.listen((req) {
        hosts.add(req.headers.value('host') ?? '');
        req.response
          ..write('x' * 1024)
          ..close();
      });

      final fwd = PortForwarder.create();
      final listen = await fwd.start(
        targetPort: up.port,
        listenPort: 0,
        rewrite: ForwardRewrite(
          fixedToken: 'fixed-token-abc',
          upstreamToken: 'launch-token-xyz',
          upstreamAuthority: '127.0.0.1:${up.port}',
        ),
      );
      addTearDown(fwd.stop);

      final sw = Stopwatch()..start();
      var ok = 0;
      for (var i = 0; i < n; i++) {
        final res = await get(listen, path: '/asset/$i.js');
        if (res.statusCode == 200) ok++;
        await res.drain<void>();
      }
      sw.stop();

      expect(ok, n, reason: '40 个资源必须全部 200');
      expect(hosts.length, n, reason: '每个请求都该打到上游');
      // 关键断言：**没有一次**带着外部 Host 上去
      expect(hosts.every((h) => h == '127.0.0.1:${up.port}'), isTrue,
          reason: '有一次没改写就会 403：${hosts.where((h) => h != '127.0.0.1:${up.port}').take(3)}');
      // 局域网里这点开销应该无感（40 个请求各自一条连接）
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)),
          reason: '40 个请求花了 ${sw.elapsedMilliseconds}ms');
    });
  });
}
