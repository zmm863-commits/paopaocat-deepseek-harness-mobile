/// 通道自检：各个模型通道跑一次**最小请求**，把失败**按状态码分类**成人话 + 下一步。
///
/// ## 为什么需要它（用户 2026-10-16 提的「探查机制」第 ① 层）
///
/// 真机上"模型用不了"有好几种完全不同的原因，但它们**表现出来的都是"失败了"**：
///   * **403**：上游把请求当成非官方客户端（zen 就明确这么干，见 zen-proxy 的实测表）；
///   * **404**：接口或**模型名已退役**（DeepSeek 的 V3/R1 名字就是这种）；
///   * **401**：Key 不对/过期；
///   * **429 / 5xx**：限流或上游自身问题；
///   * 连不上：手机网络 / 代理 / 本机服务没起来。
///
/// 用户看不出区别（都是一句英文报错），层②也得靠猜。**分类之后**：既能当场告诉用户
/// 怎么办，也能一键把结果发出去核对（第 ② 层）。
///
/// ## 2026-10-16：免 Key 那条要**打一次真对话**，不能只看清单
///
/// 上游对"清单"与"对话"是**两道独立的闸**（本机两次实测都撞上）：
///
/// | 探测 | 结果 |
/// |---|---|
/// | `GET /inference/v1/models` | **200**（哪怕门禁关着、哪怕你的出口被地区封） |
/// | `POST /inference/v1/chat/completions` | **403 FreeTierError** / **403 RegionError** |
///
/// 所以只看清单的旧版自检会把"这条根本用不了"报成"这条通道是好的" —— 那是
/// **假通过**，比不报还坏。现在免 Key 那条走**本机代理**发一句最小的对话
/// （与 App 真正用的路径完全同一条），最多试 3 个模型（有些免费模型是**按地区**
/// 放的：本机实测 `cat-jam-free` 就是 RegionError，只试一个会把"这个模型不许用"
/// 误报成"整条通道坏了"）。
///
/// ⚠️ 自检**只碰两处**：① 用户已存的 Key 对应厂家的 `GET /models`；② 本机
/// 127.0.0.1 上的代理。**不写文件、不读用户资料、不上传任何东西**。
/// 报告里 Key 由 `DiagnosticsLog` 统一脱敏。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart';
import '../state/app_settings.dart';
import '../state/provider_keys.dart';
import 'zen_proxy.dart';

/// 一次探测的结论。
enum ChannelOutcome {
  /// 通。
  ok,

  /// 没配（没打开 / 没 Key）—— 不是故障。
  notConfigured,

  /// 连不上：超时 / DNS / 网络不通。
  network,

  /// 403：上游把请求当成非官方客户端。
  blocked,

  /// 403：**地区封锁**（与请求形状无关，换网络才有用）。
  ///
  /// 2026-10-15 本机实测：同一个出口、同一时刻，403 有两种完全不同的含义
  /// （`FreeTierError` = 门禁；`RegionError` = 地区）。混成一条会把用户引去
  /// "反复换模型"或"反复换网络"里错的那一条。
  region,

  /// 404：接口或模型名已退役。
  gone,

  /// 401：Key 不行。
  auth,

  /// 429：限流。
  rateLimited,

  /// 5xx：上游自身问题。
  server,

  /// 其它（例如返回了但形状不认识）。
  unknown,
}

/// 一个通道的检查结果。
class ChannelCheck {
  const ChannelCheck({
    required this.id,
    required this.title,
    required this.outcome,
    required this.detail,
    required this.next,
  });

  /// 稳定 id（日志里用来区分）。
  final String id;

  /// 界面上的名字。
  final String title;

  final ChannelOutcome outcome;

  /// 事实：状态码/错误原文（**不含 Key**）。
  final String detail;

  /// 给用户看的下一步（人话）。
  final String next;

  bool get ok => outcome == ChannelOutcome.ok;

  /// 一句话结论（界面与日志共用）。
  String get label => switch (outcome) {
        ChannelOutcome.ok => tr('正常'),
        ChannelOutcome.notConfigured => tr('未启用'),
        ChannelOutcome.network => tr('连不上（网络）'),
        ChannelOutcome.blocked => tr('被上游拒绝（403：当成非官方客户端）'),
        ChannelOutcome.region => tr('被上游拒绝（403：地区封锁）'),
        ChannelOutcome.gone => tr('接口或模型名已退役（404）'),
        ChannelOutcome.auth => tr('Key 无效（401）'),
        ChannelOutcome.rateLimited => tr('被限流（429）'),
        ChannelOutcome.server => tr('上游自身故障（5xx）'),
        ChannelOutcome.unknown => tr('未知（需要人工看）'),
      };

  /// 日志/报告里的一行（**这是"一键发给开发者"的主要内容**）。
  String toLogLine() => '[$id] $title → $label ｜ $detail ｜ '
      '${tr('下一步')}：$next';
}

class ChannelSelfCheck {
  ChannelSelfCheck._();

  /// 超时：自检要"快"，不能让人等半分钟。
  static const Duration timeout = Duration(seconds: 12);

  /// 跑全部检查。**不会抛**（单个通道失败就是一条结论）。
  static Future<List<ChannelCheck>> run({
    required AppSettings settings,
  }) async {
    final out = <ChannelCheck>[];

    // ① Pollinations（免 Key 通道；默认开）
    if (!settings.polliEnabled) {
      out.add(ChannelCheck(
        id: 'polli',
        title: tr('免费模型（无需 Key）'),
        outcome: ChannelOutcome.notConfigured,
        detail: tr('开关是关的'),
        next: tr('要用就回「设置 → 模型」把「免费模型（无需 Key）」打开。'),
      ));
    } else {
      out.add(await _probe(
        id: 'polli',
        title: tr('免费模型（无需 Key）'),
        url: 'https://text.pollinations.ai/openai/models',
        key: null,
        onOk: (n) => tr('拿到 {0} 个模型', <Object?>[n]),
        nextOk: tr('直接就能用，不用填 Key。'),
      ));
    }

    // ② 第三方免key通道（原 OpenCode Zen；免 Key，默认关，经本地代理）——
    //    见文件头：这条要真打一次对话才算测到。
    if (!settings.zenEnabled) {
      out.add(ChannelCheck(
        id: 'zen',
        title: tr('免Key通道'),
        outcome: ChannelOutcome.notConfigured,
        detail: tr('开关是关的'),
        next: tr('要用就回「设置 → 模型」把「免Key通道」打开（它经 App 内代理转发）。'),
      ));
    } else {
      out.add(await _probeZen());
    }

    // ③ 用户自己配了 Key 的厂家（逐一看，只探有 Key 的）
    for (final p in _customProviders) {
      final key = (await ProviderKeys.read(p.id))?.trim();
      if (key == null || key.isEmpty) {
        out.add(ChannelCheck(
          id: p.id,
          title: p.title,
          outcome: ChannelOutcome.notConfigured,
          detail: tr('没有存 Key'),
          next: tr('要用就回「设置 → 模型」填上它的 API Key。'),
        ));
        continue;
      }
      out.add(await _probe(
        id: p.id,
        title: p.title,
        url: '${p.baseUrl}/models',
        key: key,
        onOk: (n) => tr('拿到 {0} 个模型', <Object?>[n]),
        nextOk: tr('这条是好的。'),
      ));
    }

    return out;
  }

  /// 有 Key 才需要自检的厂家（内置那几张卡的固定端点）。
  ///
  /// ⚠️ 不是 `const`：标题要过 `tr()`（外语界面下"DeepSeek 官方"也得是外语）。
  static List<({String id, String title, String baseUrl})> get _customProviders =>
      <({String id, String title, String baseUrl})>[
        (id: 'deepseek', title: tr('DeepSeek 官方'), baseUrl: 'https://api.deepseek.com'),
        (id: 'agnes', title: tr('Agnes'), baseUrl: 'https://api.agnes-ai.cn/v1'),
        (id: 'mimo', title: tr('MiMo（小米）'), baseUrl: 'https://api.mimo.ai/v1'),
      ];

  /// 免 Key 那条的自检：经**本机代理**发一句最小的对话（见文件头的"两道闸"）。
  static Future<ChannelCheck> _probeZen() async {
    const String id = 'zen';
    final String title = tr('免Key通道');

    final int? port = ZenProxy.instance.port;
    if (port == null) {
      // 代理没起（用户打开开关时会起）。不要把这一条报成"坏了"——
      // 它只是**现在没在跑**，给一条能照着做的下一步。
      return ChannelCheck(
        id: id,
        title: title,
        outcome: ChannelOutcome.network,
        detail: tr('本机代理没在跑'),
        next: tr('回「设置 → 模型」把「免Key通道」打开一次（它会起代理），然后再点自检。'),
      );
    }

    List<String> models;
    try {
      models = await ZenProxy.instance.fetchFreeModels(port);
    } catch (e) {
      debugPrint('[selfcheck] zen 取模型失败：$e');
      models = const <String>[];
    }
    if (models.isEmpty) {
      return ChannelCheck(
        id: id,
        title: title,
        outcome: ChannelOutcome.gone,
        detail: tr('代理没能给出任何免费模型'),
        next: tr('回「设置 → 模型」点一次「获取模型」重新拉；一直拉不到就说明上游这条通道又变了，把自检结果发出去核对。'),
      );
    }

    final tried = <String>[];
    ({int status, bool region}) last = (status: 0, region: false);
    // 最多试 3 个：免费层里有**按地区**放的模型（本机实测 cat-jam-free 就是
    // RegionError），只试一个会把"这个模型不许用"误报成"整条通道坏了"。
    for (final String m in models.take(3)) {
      final r = await _zenChatOnce(port, m);
      if (r.status == 200) {
        return ChannelCheck(
          id: id,
          title: title,
          outcome: ChannelOutcome.ok,
          detail: tr('免费模型 {0} 个；试到第 {1} 个（{2}）能正常回答',
              <Object?>[models.length, tried.length + 1, m]),
          next: tr('这条通道现在是通的，不用填 Key。模型清单随时会变，以「获取模型」拉到的那份为准。'),
        );
      }
      last = r;
      tried.add(tr('{0} → HTTP {1}{2}',
          <Object?>[m, r.status, r.region ? tr('（地区封锁）') : '']));
    }

    final ChannelOutcome outcome =
        last.status == 0 ? ChannelOutcome.network : (last.region ? ChannelOutcome.region : _classify(last.status));
    return ChannelCheck(
      id: id,
      title: title,
      outcome: outcome,
      detail: tr('免费模型 {0} 个；试了 {1} 个都没通：{2}',
          <Object?>[models.length, tried.length, tried.join('；')]),
      next: _nextFor(outcome),
    );
  }

  /// 经本机代理发一次最小对话（`max_tokens: 1`）。
  ///
  /// ⚠️ 这个 POST **只打 127.0.0.1**（代理替我们按门禁形状转发）—— 手机上不直连
  ///    上游，也没有任何凭据经过这里。`region` 是按上游原话判的（`RegionError`）。
  static Future<({int status, bool region})> _zenChatOnce(
      int port, String model) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client
          .postUrl(Uri.parse('http://127.0.0.1:$port/v1/chat/completions'))
          .timeout(timeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      // 自检固定用一个种子：同一台手机上多次自检落到同一个上游会话（别每点一次
      // 就多开一个上游会话）。
      req.headers.set('x-zen-seed', 'selfcheck');
      req.add(utf8.encode(jsonEncode(<String, Object?>{
        'model': model,
        'stream': false,
        'max_tokens': 1,
        'messages': <Object?>[
          <String, String>{'role': 'user', 'content': 'hi'},
        ],
      })));
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final int code = res.statusCode;
      return (
        status: code,
        region: code == 403 && body.toLowerCase().contains('region'),
      );
    } on TimeoutException {
      return (status: 0, region: false);
    } on SocketException catch (e) {
      debugPrint('[selfcheck] zen 连不上本机代理：${e.message}');
      return (status: 0, region: false);
    } catch (e) {
      debugPrint('[selfcheck] zen 对话探测异常：$e');
      return (status: 0, region: false);
    } finally {
      client.close(force: true);
    }
  }

  /// 一次 `GET <url>/…` 探测 → 结论。
  static Future<ChannelCheck> _probe({
    required String id,
    required String title,
    required String url,
    required String? key,
    required String Function(int models) onOk,
    required String nextOk,
    String? userAgent,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (userAgent != null) {
        req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      }
      if (key != null && key.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      }
      final res = await req.close().timeout(timeout);
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final code = res.statusCode;

      if (code == 200) {
        // 数一下有几个模型（形状不认识也不当失败：能 200 就说明通道是通的）
        var n = 0;
        try {
          final j = jsonDecode(body);
          final data = (j is Map) ? j['data'] : null;
          if (data is List) n = data.length;
        } catch (_) {}
        return ChannelCheck(
          id: id,
          title: title,
          outcome: ChannelOutcome.ok,
          detail: tr('HTTP 200，{0}', <Object?>[onOk(n)]),
          next: nextOk,
        );
      }
      final ChannelOutcome outcome = _classify(code);
      return ChannelCheck(
        id: id,
        title: title,
        outcome: outcome,
        // 403 的两种含义（地区 / 门禁）当场分开，别让用户去猜
        detail: code == 403 && body.toLowerCase().contains('region')
            ? tr('HTTP 403（上游说：地区不可用）')
            : tr('HTTP {0}', <Object?>[code]),
        next: _nextFor(
            code == 403 && body.toLowerCase().contains('region')
                ? ChannelOutcome.region
                : outcome),
      );
    } on TimeoutException {
      return ChannelCheck(
        id: id,
        title: title,
        outcome: ChannelOutcome.network,
        detail: tr('超时（{0}s 没响应）', <Object?>[timeout.inSeconds]),
        next: _nextFor(ChannelOutcome.network),
      );
    } on SocketException catch (e) {
      return ChannelCheck(
        id: id,
        title: title,
        outcome: ChannelOutcome.network,
        detail: tr('连不上：{0}', <Object?>[e.osError?.message ?? e.message]),
        next: _nextFor(ChannelOutcome.network),
      );
    } catch (e) {
      debugPrint('[selfcheck] $id 探测异常：$e');
      return ChannelCheck(
        id: id,
        title: title,
        outcome: ChannelOutcome.unknown,
        detail: '$e',
        next: _nextFor(ChannelOutcome.unknown),
      );
    } finally {
      client.close(force: true);
    }
  }

  static ChannelOutcome _classify(int code) => switch (code) {
        0 => ChannelOutcome.network,
        401 => ChannelOutcome.auth,
        403 => ChannelOutcome.blocked,
        404 => ChannelOutcome.gone,
        429 => ChannelOutcome.rateLimited,
        >= 500 => ChannelOutcome.server,
        _ => ChannelOutcome.unknown,
      };

  /// 每种结论给一句**能照着做**的下一步（不写"请检查配置"这种空话）。
  static String _nextFor(ChannelOutcome o) => switch (o) {
        ChannelOutcome.network =>
          tr('先确认手机能上网（换 WiFi/流量试一下）；如果用代理，看代理是否在跑。'),
        ChannelOutcome.blocked =>
          tr('上游把请求当成"非官方客户端"拒了。这条通道可能已经变了，把自检结果发给开发者核对。'),
        ChannelOutcome.region =>
          tr('你所在地区不在它的放行范围 —— 这与请求形状无关：换网络，或先用别的模型。'),
        ChannelOutcome.gone =>
          tr('接口或**模型名已经退役**（名字换了就会这样）：回「设置 → 模型」点「获取模型」拉一份新的清单，重新勾选保存。'),
        ChannelOutcome.auth =>
          tr('Key 不对或过期了 —— 回「设置 → 模型」重新填一把再点「测试并保存」。'),
        ChannelOutcome.rateLimited => tr('被限流了：等一会儿再试，或换一个模型。'),
        ChannelOutcome.server => tr('上游自己出问题了，过一会儿再试（不是你的配置问题）。'),
        _ => tr('把自检结果发给开发者看一下（里面没有 Key）。'),
      };
}
