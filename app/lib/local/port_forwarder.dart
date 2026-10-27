import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'diagnostics_log.dart';

/// 把手机上的 DSH 网页服务"借"到外部网络上的**最小端口转发器**。
///
/// ## 为什么不能直接让 DSH 绑网卡（2026-10-26 真机结论）
///
/// 随包运行时是 `dsh-web-app 0.1.7-rc.2`，它**支持** `--host`，但一旦真把服务
/// 绑到非回环地址（例如 `192.168.3.7`），它自己的一批内部插件就起不来了：
///
/// ```
/// file-upload connection / ui-deliverables connection,
/// sessionController / bot sessionController, connection
/// ```
///
/// 这些插件是**连 `127.0.0.1`** 去访问同一进程里的 web 服务的；服务搬到 192.168
/// 之后它们连不上，于是整个 profile 激活失败、进程退出（退出码 1）。
///
/// 所以正确的做法是**不动 DSH 的绑定**（它继续只认回环，内部一切正常），
/// 由 App 在对外端口上开一个 TCP 转发：外部 → 这台转发器 → `127.0.0.1:<port>`。
///
/// ## 边界
///
/// * 只做 TCP 字节转发，不解析 HTTP（因此 SSE / WebSocket 升级都能过）。
/// * 任一方向断开就把两端一起销毁，避免半开连接堆积。
/// * 只监听 `0.0.0.0`（所有网卡）；手机丢了或换网时由调用方 [stop]。
class PortForwarder {
  PortForwarder._();

  /// DSH 自己那条转发（`instance` 只为兼容既有调用点保留）。
  static final PortForwarder instance = PortForwarder._();

  /// 另开一条独立转发（设计站后端用）——每条转发各有自己的监听端口。
  factory PortForwarder.create() => PortForwarder._();

  ServerSocket? _server;
  final List<Socket> _open = <Socket>[];
  int? _port;

  /// 当前对外端口；没开就是 null。
  int? get port => _port;

  bool get running => _server != null;

  /// 提前挑一个空闲端口并**记住它**，之后再 [start] 时就绑这一个。
  ///
  /// 为什么需要"先挑"（2026-10-27）：DSH 的 `--trusted-host` 是**启动参数**，
  /// 必须在我们知道对外端口之后、启动 DSH 之前就传进去（否则浏览器所有
  /// `/api/*` 都 403）。而正常顺序是"先起 DSH、再起转发"——那就永远拿不到
  /// 端口。所以先 reserve 一个，用它当 trusted-host 起 DSH，再绑同一个端口。
  ///
  /// 挑选方式：bind 到 0 拿到系统分配的端口后立刻释放。Release 到 re-bind
  /// 之间有个极小窗口（几十微秒），被别的进程抢走的概率可以忽略；真被抢了
  /// [start] 会抛出来，界面上看得到，不会静默错。
  Future<int> reservePort() async {
    final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final p = probe.port;
    await probe.close();
    _reserved = p;
    return p;
  }

  int? _reserved;

  /// 在 [listenPort] 上等连接，全部转到 `127.0.0.1:[targetPort]`。
  ///
  /// [listenPort] 传 0 表示"用 [reservePort] 预定的那个；没预定就让系统挑"。
  Future<int> start({required int targetPort, int listenPort = 0}) async {
    final want = listenPort != 0 ? listenPort : (_reserved ?? 0);
    await stop();
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, want);
    _server = server;
    _port = server.port;
    _reserved = null;
    DiagnosticsLog.add('lan',
        '端口转发已启动：0.0.0.0:${server.port} → 127.0.0.1:$targetPort');
    if (listenPort != 0 && server.port != listenPort) {
      // 不该发生：bind 指定端口成功时返回的就是它。真出现说明平台层有转换，
      // 必须留痕 —— 否则 trusted-host 与真实端口不一致，又是满屏 403。
      DiagnosticsLog.add('lan',
          '⚠ 实际监听端口(${server.port})与预定($listenPort)不一致，/api 可能 403');
    }

    server.listen((client) {
      _open.add(client);
      Socket.connect(InternetAddress.loopbackIPv4, targetPort)
          .then((upstream) {
        _open.add(upstream);

        void closeBoth() {
          try {
            client.destroy();
          } catch (_) {}
          try {
            upstream.destroy();
          } catch (_) {}
          _open.remove(client);
          _open.remove(upstream);
        }

        client.listen(
          upstream.add,
          onDone: closeBoth,
          onError: (Object e) => closeBoth(),
          cancelOnError: true,
        );
        upstream.listen(
          client.add,
          onDone: closeBoth,
          onError: (Object e) => closeBoth(),
          cancelOnError: true,
        );
      }).catchError((Object e) {
        debugPrint('[port-forward] 连不上本机服务：$e');
        try {
          client.destroy();
        } catch (_) {}
        _open.remove(client);
      });
    }, onError: (Object e) {
      DiagnosticsLog.add('lan', '转发器监听出错：$e');
    });

    return server.port;
  }

  /// 关掉监听和所有已建立的连接。
  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
      DiagnosticsLog.add('lan', '端口转发已停止');
    }
    for (final c in List<Socket>.from(_open)) {
      try {
        c.destroy();
      } catch (_) {}
    }
    _open.clear();
  }
}
