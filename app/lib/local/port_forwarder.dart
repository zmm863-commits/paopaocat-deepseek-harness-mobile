import 'dart:async';
import 'dart:convert';
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
  Future<int> reservePort({int preferred = 0}) async {
    // 优先复用上次的端口（[BridgePrefs] 记住的那个）：端口稳定，用户才能把
    // 链接收藏起来、不用每次都回手机复制。被占用才换一个。
    if (preferred > 0) {
      try {
        final probe = await ServerSocket.bind(InternetAddress.anyIPv4, preferred);
        await probe.close();
        _reserved = preferred;
        return preferred;
      } catch (_) {
        DiagnosticsLog.add('lan', '预定端口 $preferred 被占用，改让系统挑');
      }
    }
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
  Future<int> start({
    required int targetPort,
    int listenPort = 0,
    ForwardRewrite? rewrite,
  }) async {
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

        if (rewrite != null) {
          _bridgeWithRewrite(client, upstream, rewrite, closeBoth);
          return;
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
        // 上游连不上 = 手机上的服务已经停了（开关被关、进程被系统回收、
        // 换网后端口变了……）。以前这里直接 destroy，浏览器只会看到
        // ERR_EMPTY_RESPONSE 或一片白 —— 用户完全不知道为什么、也不知道该怎么办。
        // 现在回一个**看得懂**的页面，并且它自己会重连（详见 [offlinePage]）。
        _serveOfflinePage(client, targetPort);
        _open.remove(client);
      });
    }, onError: (Object e) {
      DiagnosticsLog.add('lan', '转发器监听出错：$e');
    });

    return server.port;
  }

  /// 只对**第一个请求头**做改写，之后原样透传（SSE / WebSocket 不受影响）。
  ///
  /// ## 为什么非改不可（2026-10-30 用户真机截图）
  ///
  /// 电脑打开 `http://192.168.0.100:45721/?token=<launchToken>`，返回的是
  /// `dsh web authentication required; reopen the URL printed by dsh web.`
  ///
  /// 根因（读了 `dsh-client-connection` 的实现）：DSH 的 `launchToken` 是
  /// **进程内随机生成、没有任何注入口子**（`processLaunchToken` = `randomBytes`），
  /// 藏在内存 Map 里。于是**服务每重启一次，token 就换一把** —— 而 App 有三个
  /// 地方会重启它（切模型、开关电脑访问、Bot 服务自愈）。用户收藏/复制的地址
  /// 注定一次就废。光固定端口和 IP 不够，**token 也得固定**。
  ///
  /// 做法：App 对外只发**自己的固定口令**（`BridgePrefs.token`，与设计站同一个），
  /// 转发层收到第一个请求时把手里的固定口令换成当前的 launchToken，再交给 DSH。
  /// 用户那边的地址从此长期有效。
  ///
  /// ## 顺手把 Host 也改回回环
  ///
  /// DSH 的 browser-trust fence 是按 Host 判断的：外部地址一律 403。以前靠
  /// `--trusted-host` 参数放行 —— 但那是**启动参数**，改不了热，于是「开一次
  /// 电脑访问 = 重启一次 DSH」，真机上还撞见过重启后 profile 激活失败
  /// （退出码 1，`file-upload connection / ui-deliverables connection`），
  /// 整个面板红一片。现在把 Host 改写成 `127.0.0.1:<port>`，DSH 认为自己被
  /// 本机访问，天然放行 —— **不需要 trusted-host，也就不需要重启**。
  ///
  /// 安全性：只有 token 恰好等于 App 固定口令时才替换成真 token；别的 token
  /// 原样送上去让 DSH 自己 401。所以这条通道**没有**把鉴权打开。
  void _bridgeWithRewrite(
    Socket client,
    Socket upstream,
    ForwardRewrite rw,
    void Function() closeBoth,
  ) {
    final buf = <int>[];
    var forwarded = false;
    Timer? guard;
    var logged = false;

    void flush({required bool raw}) {
      if (forwarded) return;
      forwarded = true;
      guard?.cancel();
      if (buf.isEmpty) return;
      if (!raw) {
        final end = _headEnd(buf);
        if (end > 0) {
          final head = utf8.decode(buf.sublist(0, end), allowMalformed: true);
          final rest = List<int>.from(buf.sublist(end));
          buf.clear();
          final out = _rewriteHead(head, rw);
          if (!logged) {
            logged = true;
            DiagnosticsLog.add('lan',
                '已把对外口令换成当前 launchToken（Host → ${rw.upstreamAuthority}）');
          }
          try {
            upstream.add(utf8.encode(out));
            if (rest.isNotEmpty) upstream.add(rest);
          } catch (_) {}
          return;
        }
      }
      // 头没等到（非 HTTP、或客户端连上不吭声）：原样送上去，别卡着。
      final all = List<int>.from(buf);
      buf.clear();
      try {
        upstream.add(all);
      } catch (_) {}
    }

    // 客户端连上却一直不发请求头（端口探测、健康检查）：10 秒后别占着不干活。
    guard = Timer(const Duration(seconds: 10), () => flush(raw: true));

    client.listen((chunk) {
      if (forwarded) {
        try {
          upstream.add(chunk);
        } catch (_) {}
        return;
      }
      buf.addAll(chunk);
      if (_headEnd(buf) > 0) {
        flush(raw: false);
      } else if (buf.length > _maxHeadBytes) {
        flush(raw: true);
      }
    }, onDone: closeBoth, onError: (Object e) => closeBoth(), cancelOnError: true);

    upstream.listen(client.add,
        onDone: closeBoth, onError: (Object e) => closeBoth(), cancelOnError: true);
  }

  static const int _maxHeadBytes = 16384;

  /// 找到 `\r\n\r\n` 之后的下一个字节位置（没有就 -1）。
  static int _headEnd(List<int> b) {
    for (var i = 3; i < b.length; i++) {
      if (b[i - 3] == 13 && b[i - 2] == 10 && b[i - 1] == 13 && b[i] == 10) {
        return i + 1;
      }
    }
    return -1;
  }

  /// 改写第一个请求头：请求行里的 token、Host / Origin / Referer。
  /// 纯函数，便于单测。
  static String _rewriteHead(String head, ForwardRewrite rw) {
    final lines = head.split('\r\n');
    if (lines.isEmpty) return head;

    final parts = lines[0].split(' ');
    if (parts.length >= 2) {
      final uri = parts[1];
      final q = uri.indexOf('?');
      if (q > 0) {
        final path = uri.substring(0, q);
        final params = uri.substring(q + 1).split('&');
        var changed = false;
        for (var i = 0; i < params.length; i++) {
          if (!params[i].startsWith('token=')) continue;
          String v;
          try {
            v = Uri.decodeComponent(params[i].substring(6));
          } catch (_) {
            v = params[i].substring(6);
          }
          // 只换「恰好是我方固定口令」的那一个 —— 别人的 token 原样送，让 DSH 拒。
          if (rw.fixedToken.isNotEmpty && v == rw.fixedToken) {
            params[i] = 'token=${Uri.encodeComponent(rw.upstreamToken)}';
            changed = true;
          }
        }
        if (changed) parts[1] = '$path?${params.join('&')}';
      }
      lines[0] = parts.join(' ');
    }

    var hasConnection = false;
    for (var i = 1; i < lines.length; i++) {
      final lower = lines[i].toLowerCase();
      if (lower.startsWith('host:')) {
        lines[i] = 'Host: ${rw.upstreamAuthority}';
      } else if (lower.startsWith('origin:')) {
        lines[i] = 'Origin: http://${rw.upstreamAuthority}';
      } else if (lower.startsWith('referer:')) {
        final u = Uri.tryParse(lines[i].substring(8).trim());
        if (u != null) {
          final q = u.hasQuery ? '?${u.query}' : '';
          lines[i] = 'Referer: http://${rw.upstreamAuthority}${u.path}$q';
        }
      } else if (lower.startsWith('connection:')) {
        // ⚠️ 必须断开长连接（2026-10-30 想清楚才加）：我们只改写**一个连接上的
        // 第一个请求头**，而 HTTP/1.1 默认 keep-alive —— 浏览器会在同一个连接上
        // 接着发第二个请求，那一次的 Host 是**外部地址**（没被改写）→ DSH 的
        // browser-trust fence 直接 403，表现为「首页能开、点两下就白」。
        // 让服务端每个连接只处理一个请求，既省掉「解析 body 才知道下一个头在哪」
        // 的复杂状态机，也不影响 SSE / WebSocket（它们本来就是一条长响应）。
        lines[i] = 'Connection: close';
        hasConnection = true;
      }
    }
    if (!hasConnection) lines.insert(lines.length - 2, 'Connection: close');
    return lines.join('\r\n');
  }

  /// 上游不通时给浏览器的那一页（HTTP 502）。
  ///
  /// 为什么要有它（2026-10-30，0.81）：用户把 App 划掉 / 系统回收进程 / 手机
  /// 换了网之后，电脑端原来只会看到**一片白**或 `ERR_EMPTY_RESPONSE` ——
  /// 既不知道发生了什么，也不知道该去哪儿按。现在至少能读懂、能照着做。
  void _serveOfflinePage(Socket client, int targetPort) {
    final body = offlinePageHtml.replaceAll('__PORT__', '$targetPort');
    final bytes = utf8.encode(body);
    final head = 'HTTP/1.1 502 Bad Gateway\r\n'
        'Content-Type: text/html; charset=utf-8\r\n'
        'Cache-Control: no-store, must-revalidate\r\n'
        'Connection: close\r\n'
        'Content-Length: ${bytes.length}\r\n'
        '\r\n';
    try {
      client.add(utf8.encode(head));
      client.add(bytes);
      // 必须 flush 后再关：直接 destroy 有几率把还没写出去的字节丢掉，
      // 浏览器就又变成白屏了（那就白做这一页）。
      client.flush().then<void>((_) {
        try {
          client.destroy();
        } catch (_) {}
      }).catchError((Object _) {
        try {
          client.destroy();
        } catch (_) {}
      });
    } catch (_) {
      try {
        client.destroy();
      } catch (_) {}
    }
    // 每连一次记一条会把诊断日志刷满（页面自己每 3 秒还会探一次），节流到 60 秒。
    final now = DateTime.now();
    if (_lastOfflineLog == null ||
        now.difference(_lastOfflineLog!) > const Duration(seconds: 60)) {
      _lastOfflineLog = now;
      DiagnosticsLog.add('lan',
          '外部访问时本机服务(127.0.0.1:$targetPort)连不上 → 已回「服务已停止」页');
    }
  }

  DateTime? _lastOfflineLog;

  /// 「手机上的服务已停止」页。
  ///
  /// 三条硬约束：
  /// * **不引用任何外部资源** —— 此刻手机可能已经断网、服务也没了，CDN 上的
  ///   字体/图标一定加载不出来，页面会变得比白屏更难看；
  /// * **自己去重连**（每 3 秒 HEAD 一次本地址）：用户回手机把开关重新打开之后，
  ///   电脑这边不用再点刷新；
  /// * 判据是「**不再是 502**」而不是「200」—— 手机回来的那一刻，上游可能是
  ///   401（还没换 cookie）或 404（探的路径不存在），但只要不是我们自己这一页，
  ///   就说明服务已经活了，刷新即可。
  static const String offlinePageHtml = r'''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>手机上的服务已停止 · 泡泡猫 DSH</title>
<style>
:root{color-scheme:light dark}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
font:15px/1.7 -apple-system,"PingFang SC","Microsoft YaHei",system-ui,sans-serif;
background:#0f1115;color:#e6e8ee;padding:24px}
.card{max-width:560px;width:100%;background:#171a21;border:1px solid #262b36;
border-radius:16px;padding:28px 28px 24px}
.tag{display:inline-flex;align-items:center;gap:8px;font-size:12px;color:#f0b25a;
background:#2a2114;border:1px solid #4a3a1c;border-radius:999px;padding:4px 10px}
.dot{width:7px;height:7px;border-radius:50%;background:#f0b25a;animation:p 1.4s infinite}
@keyframes p{0%,100%{opacity:1}50%{opacity:.25}}
h1{font-size:20px;margin:16px 0 6px;font-weight:600}
p{margin:10px 0;color:#aab1c2}
b{color:#e6e8ee;font-weight:600}
ul{margin:10px 0 14px;padding-left:20px;color:#aab1c2}
li{margin:4px 0}
.how{background:#12161d;border:1px solid #232936;border-radius:10px;padding:12px 14px;color:#cfd5e3}
.status{margin-top:16px;font-size:13px;color:#7f8798}
kbd{background:#232936;border-radius:4px;padding:1px 6px;font-size:12px;color:#cfd5e3;
font-family:ui-monospace,Menlo,monospace}
</style>
</head>
<body>
<div class="card">
<span class="tag"><span class="dot"></span>连接已中断</span>
<h1>手机上的服务已经停了</h1>
<p>电脑连不上手机里的 <b>泡泡猫 · DeepSeek Harness</b>。常见原因：</p>
<ul>
<li>手机上的「<b>移动桌面平台</b>」开关被关掉了</li>
<li>App 被系统收回后台了，或者被从最近任务里划掉</li>
<li>手机换了网络（Wi-Fi 断了、切了热点），地址变了</li>
</ul>
<p class="how">在手机上打开 <kbd>设置 → 移动桌面平台</kbd>，把开关重新打开。<br>
这个页面会自己重连 —— <b>不用手动刷新</b>。</p>
<p class="status" id="s">正在等待手机回来…</p>
<p class="status">（手机那头是 127.0.0.1:__PORT__）</p>
</div>
<script>
(function(){
var t=0,url=location.href,el=document.getElementById('s');
function tick(){
t+=3;
el.textContent='正在等待手机回来… 已等 '+t+' 秒';
fetch(url,{method:'HEAD',cache:'no-store'}).then(function(r){
if(r.status!==502){location.reload()}
}).catch(function(){});
}
setInterval(tick,3000);
})();
</script>
</body>
</html>
''';

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

/// 对外地址的「翻译规则」：让用户手里的地址**长期有效**。
///
/// 见 [PortForwarder._bridgeWithRewrite] 的长注释（为什么 token 必须改写、
/// 为什么顺带把 Host 改回回环）。纯数据、可测。
class ForwardRewrite {
  const ForwardRewrite({
    required this.fixedToken,
    required this.upstreamToken,
    required this.upstreamAuthority,
  });

  /// 给用户的那把固定口令（App 自己生成，跨重启不变）。
  final String fixedToken;

  /// DSH 当前进程的 launch token（每次重启都变）。
  final String upstreamToken;

  /// DSH 自认为的地址，例如 `127.0.0.1:46123`（写进 Host）。
  final String upstreamAuthority;
}
