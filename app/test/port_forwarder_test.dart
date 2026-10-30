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
}
