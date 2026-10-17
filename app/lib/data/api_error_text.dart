/// 错误翻译层：把模型/网络返回的**英文错误码与 JSON** 翻译成中文。
///
/// 用户明确要求：「如果用户使用过程中模型出现 429 或其他错误代码，要翻译成
/// 中文告诉用户」。这一层是**共享**的，三处都走它，避免各写一份口径不一：
///   1. 设置页的「获取模型」
///   2. 对话里模型调用失败
///   3. 定时任务的 headless 执行结果
///
/// 设计原则：
///   * `zh` 是给用户看的一句话中文，**必须能指导他下一步做什么**；
///   * `detail` 保留原始状态码与服务器原话，折叠展示，便于排查（不丢信息）；
///   * 拿不准时宁可说"未知错误（HTTP xxx）"也不编造原因。
library;

import 'dart:async';
import 'dart:io';

import '../i18n/dsh_i18n.dart';

/// 一条翻译好的错误。
class ApiErrorText {
  const ApiErrorText({
    required this.zh,
    this.statusCode,
    this.detail,
    this.retryable = false,
  });

  /// 面向用户的中文说明
  final String zh;

  /// HTTP 状态码（网络层错误时为 null）
  final int? statusCode;

  /// 原始信息：状态码 + 服务器返回的正文（可能很长，展示时截断）
  final String? detail;

  /// 是否值得重试（429、5xx、超时 → true；401/403/404 → false）
  final bool retryable;

  /// 展示用：`中文说明（HTTP 429）`
  String get headline => statusCode == null ? zh : '$zh（HTTP $statusCode）';

  @override
  String toString() => headline;
}

/// 从服务器返回体里挖出它的原话（OpenAI / Anthropic 两种常见结构都认）。
String? extractServerMessage(String? body) {
  if (body == null || body.trim().isEmpty) return null;
  final trimmed = body.trim();
  // 极长的 HTML 错误页没啥用，直接截断
  final text = trimmed.length > 600 ? '${trimmed.substring(0, 600)}…' : trimmed;
  final lower = text.toLowerCase();
  // 常见结构：{"error":{"message":"..."}} / {"message":"..."} / {"error":"..."}
  for (final key in <String>[
    '"message"',
    '"error_description"',
    '"detail"',
    '"msg"'
  ]) {
    final idx = lower.indexOf(key);
    if (idx < 0) continue;
    final colon = text.indexOf(':', idx);
    if (colon < 0) continue;
    final quote = text.indexOf('"', colon + 1);
    if (quote < 0) continue;
    final end = text.indexOf('"', quote + 1);
    if (end > quote) {
      final value = text.substring(quote + 1, end);
      if (value.trim().isNotEmpty) return value;
    }
  }
  return text;
}

/// 按 HTTP 状态码 + 返回体内容翻译。
ApiErrorText translateHttpError({required int statusCode, String? body}) {
  final server = extractServerMessage(body);
  final sniff = (body ?? '').toLowerCase();

  // 先看返回体：同样的 4xx，原因可能完全不同（额度 vs Key 无效）
  final looksQuota = sniff.contains('quota') ||
      sniff.contains('insufficient') ||
      sniff.contains('balance') ||
      sniff.contains('exceeded your current');
  final looksRate = sniff.contains('rate limit') ||
      sniff.contains('too many requests') ||
      sniff.contains('rpm') ||
      sniff.contains('tpm');
  final looksContext = sniff.contains('context length') ||
      sniff.contains('context_length_exceeded') ||
      sniff.contains('maximum context') ||
      sniff.contains('too long');
  final looksModel = sniff.contains('unknown model') ||
      sniff.contains('model not found') ||
      sniff.contains('does not exist') ||
      sniff.contains('no such model') ||
      sniff.contains('model_not_found');
  // 地区限制（2026-10-17 实测）：OpenCode 对某些模型回
  // `403 {"type":"RegionError","message":"This model is not available in your country"}`
  // —— 这跟 Key、跟套餐都无关，笼统报"没有权限"会把人往错方向带。
  final looksRegion = sniff.contains('regionerror') ||
      sniff.contains('not available in your country') ||
      sniff.contains('not available in your region');
  final looksKey = sniff.contains('invalid_api_key') ||
      sniff.contains('invalid api key') ||
      sniff.contains('missing_api_key') ||
      sniff.contains('unauthorized') ||
      sniff.contains('authentication') ||
      sniff.contains('invalid key');

  String zh;
  var retryable = false;

  switch (statusCode) {
    case 400:
      zh = looksModel
          ? tr('模型名不被该端点接受。请点「获取模型」从列表里选一个，别手填错名字。')
          : tr('请求被拒绝（多为模型名写错或参数不被支持）。');
      break;
    case 401:
      zh = looksKey || server == null
          ? tr('API Key 无效或没填。请回设置页检查 Key，并确认它属于当前选中的服务商。')
          : tr('未通过鉴权：{0}', [server]);
      break;
    case 402:
      zh = tr('账户余额不足，请先充值。');
      break;
    case 403:
      zh = looksQuota
          ? tr('额度已用完或该模型未开通，请到服务商后台查看用量。')
          : looksRegion
              ? tr('这个模型在你所在地区不可用（不是 Key 的问题）。')
              : tr('没有访问该模型的权限（可能是套餐不含、或 Key 权限受限）。');
      break;
    case 404:
      zh = looksModel
          ? tr('这个模型在该端点上不存在。请点「获取模型」重新选。')
          : tr(
              '地址或模型不存在：请检查 Base URL 是否写对（例如 LongCat 必须是 /openai/v1，漏掉 openai 就会 404）。');
      break;
    case 408:
      zh = tr('服务端处理超时，稍后重试。');
      retryable = true;
      break;
    case 413:
      zh = looksContext
          ? tr('上下文超出该模型上限。请精简输入，或换一个上下文窗口更大的模型。')
          : tr('本次请求内容过大（上传或上下文太长）。请精简后重试。');
      break;
    case 422:
      zh = tr('参数或模型不被支持：请确认模型名可用，并确认该模型支持 OpenAI 兼容协议。');
      break;
    case 429:
      retryable = true;
      zh = looksQuota
          ? tr('已达额度上限（不是手速太快，是额度用完了），请到服务商后台查看用量或升级套餐。')
          : looksRate
              ? tr('请求太频繁，被限流了。等几秒到一分钟再试。')
              : tr('请求太频繁或已达额度上限，请稍后重试。');
      break;
    case 500:
    case 502:
    case 503:
    case 504:
    case 529:
      retryable = true;
      zh = statusCode == 529
          ? tr('服务商过载，稍后重试。')
          : tr('服务商暂时不可用（服务端错误），不是你的配置问题，稍后重试即可。');
      break;
    default:
      if (statusCode >= 500) {
        retryable = true;
        zh = tr('服务端返回异常状态，稍后重试。');
      } else if (statusCode >= 400) {
        zh = tr('请求被拒绝，请检查模型名、Base URL 与 Key。');
      } else {
        zh = tr('服务端返回了无法识别的状态码。');
      }
  }
  return ApiErrorText(
    zh: zh,
    statusCode: statusCode,
    detail: <String>[
      if (statusCode >= 0) 'HTTP $statusCode',
      if (server != null && server.isNotEmpty) server,
    ].join('\n'),
    retryable: retryable,
  );
}

/// 翻译 **DSH 会话内部**抛回来的英文错误（不是 HTTP 层，是 runtime 抛的串）。
///
/// 为什么单独一层：HTTP 层的错误由 [translateHttpError] 管，但"轮次直接失败"这类
/// 错误是 DSH 自己抛的英文串，会原样进到对话里。用户真机截图给过一个典型：
/// ```
/// 执行失败: Bad state: session/prompt 失败: Internal error: turn failed:
/// llm-pi-ai: no credential for provider route "agnes"; its profile resolves
/// AGNES_API_KEY, which is not set -- store AGNES_API_KEY ...
/// ```
/// 用户看不懂、也不知道去哪儿修。这类错误**几乎都能给出唯一的下一步动作**，
/// 所以逐条翻译；**认不出来就返回 null**，调用方原样展示（不丢原文，排查靠它）。
ApiErrorText? translateDshError(String raw) {
  final s = raw.toLowerCase();

  // ⓪' 「免费模型（无需 Key）」那条匿名通道被上游闸住了（2026-10-15 实测）。
  //
  // 为什么单列一条：上游 2026-10-13/14 第三次收紧后，这条通道会返回
  // `403 FreeTierError`；本地代理 `zen-proxy.mjs` 已经把解释写进了错误体
  // （含"这不是你没配 Key"）—— 但**下面 403 那条通用文案会把它盖成
  // "没有访问该模型的权限（套餐不含 / Key 权限受限）"**，用户照着去查自己的
  // Key 只会白折腾。所以这里按代理的标记先认出来，直接给能行动的那句话。
  if (s.contains('社区免费通道') ||
      s.contains('freetiererror') ||
      s.contains('free tier can only be used from within opencode')) {
    return ApiErrorText(
      zh: tr(
          '「免费模型（无需 Key）」这条通道被上游关掉了（不是你没配 Key —— 它本来就不用 Key）。\n下一步：去「设置 → 模型」换一个自己配了 Key 的模型；这条通道以后再恢复就能继续用。'),
      detail: raw,
    );
  }

  // ⓪ 本地模型"上下文不够"（真机实测最常见的一种失败）。
  //
  // 引擎原文：`request (6959 tokens) exceeds the available context size (2048 tokens),
  // try increasing it`。它其实是**我们给的上下文太小**，不是用户操作错 ——
  // 所以要直接告诉他去哪儿把它调大，而不是让他看英文。
  final ctx =
      RegExp(r'exceeds the available context size\s*\((\d+)').firstMatch(raw);
  if (ctx != null || s.contains('exceed_context_size')) {
    final need =
        RegExp(r'request\s*\((\d+)\s*tokens\)').firstMatch(raw)?.group(1);
    final have = ctx?.group(1);
    return ApiErrorText(
      zh: tr(
          '本地模型的上下文不够：这一轮要 {0} tokens，但只给了 {1}。\n下一步：打开「设置 → 本地大模型（测试）」，在「本地模型服务」里把上下文调大一档（推荐 16k），再重新启动服务。',
          [need ?? '很多', have ?? '太少']),
      detail: raw,
    );
  }

  // ① 缺凭据：把"没配 Key 的厂家"设成了默认模型（用户截图里就是这个）。
  final credential =
      RegExp(r'no credential for provider route\s*"([^"]+)"').firstMatch(raw);
  if (credential != null || s.contains('missing_credential')) {
    final route = credential?.group(1)?.trim() ?? '';
    final env = RegExp(r'resolves\s+(\w+)').firstMatch(raw)?.group(1);
    // **本机代理（local / rotate）不是"用户忘了填 Key"** ——它们跑在这台手机上，
    // 压根不需要真 Key。以前这里一视同仁地叫用户"去 Agnes 注册拿 Key"，
    // 真机截图证实那条指引是错的（用户看着一个本机模型被要求去注册云端）。
    final isLocalRoute = route == 'local' || route == 'rotate';
    return ApiErrorText(
      zh: isLocalRoute
          ? tr(
              '本机模型不需要 API Key —— 如果看到这条，说明 App 注入本机凭据时出了问题（这是个 bug，请在「运行日志」里反馈这条消息）。')
          : tr(
              '现在这个模型属于「{0}」，但那一家的 API Key 还没配，所以调不通。\n下一步：打开「设置 → 模型」，把这一家的 Key 填上（Agnes 可以到 platform.agnes-ai.cn 免费注册拿 Key），保存后回到会话重发一次。',
              [route.isEmpty ? '某个厂家' : route]),
      detail: <String>[
        if (env != null && env.isNotEmpty) tr('缺少环境变量：{0}', [env]),
        raw,
      ].join('\n'),
    );
  }

  // ② 连不上端点：网络不通 / baseURL 写错 / 本地轮换代理没起来 / **本机引擎崩了**。
  //
  // 最后那种是真机 2026-10-07 的现场：用户发第一句真话 → 引擎段错误崩掉 →
  // overlay 还指着那个死端口 → 每次重发都是同一句英文。所以文案里必须带上
  // 「本机模型就回去点一次启动」这条**具体动作**，否则用户只能反复重发。
  // ⚠️ 不能要求**同时**出现 "transport"：真机日志（2026-10-16）里 DSH 给的是
  // `Internal error: turn failed: Connection error.` —— 没有 transport 字样，
  // 于是它落到"未知错误"：用户看到一句英文，也不知道其实是**网络不通**
  // （那条链路本该可重试，见 retryable）。所以这里放宽成"出现任一即可"。
  if (s.contains('connection error') ||
      (s.contains('transport') && s.contains('connection'))) {
    return ApiErrorText(
      zh: tr(
          '连不上模型端点。\n可能是：手机网络不通、Base URL 写错，或者你在用「轮换组」而本地代理没起来（回设置页切一下模型就会重新起）；'
          '如果你用的是本机模型，多半是引擎刚崩了或被系统回收了 —— 去「设置 → 本地大模型（测试）」重新点一次「启动」。改完重发一次即可。'),
      detail: raw,
      retryable: true,
    );
  }

  // ③ 模型没在 DSH 里注册：改过配置后没有重新走一次"切模型"，overlay 还是旧的。
  if (s.contains('unknown model') ||
      s.contains('not a known model') ||
      s.contains('no such model') ||
      s.contains('unknown provider')) {
    return ApiErrorText(
      zh: tr(
          '这个模型没有在 DSH 的路由里注册。\n下一步：回「设置 → 模型」把默认模型重新点一次（这会让 App 重写配置），或者到会话里用模型按钮重新选一次。'),
      detail: raw,
    );
  }

  // ④ 沙箱/权限类（Android 上没有 landlock，正常情况下不该出现；出现就说明
  //    overlay 里的 sandbox-policy 没生效 —— 提示一句就能自救）。
  if (s.contains('no backend usable') || s.contains('sandbox')) {
    return ApiErrorText(
      zh: tr(
          '执行环境被沙箱挡住了（Android 上不该出现）。\n下一步：回「设置 → 模型」随便切一次模型，App 会重写运行配置并补上「danger-full-access」，之后重发即可。'),
      detail: raw,
    );
  }

  // ⑤ **兜底：把"上游 HTTP 状态码 + 返回体"从原始报错里抠出来**，交给
  //    [translateHttpError] —— 它已经把 400/401/402/403/404/429/5xx 各自的
  //    人话与"下一步"都写好了。
  //
  //    为什么必须有这一条（2026-10-12 别人那份 v0.57 真机日志）：会话路径（ACP）
  //    的失败长这样 ——
  //      `Bad state: session/prompt 失败：Internal error: turn failed: 401:
  //       {"message":"Invalid 'Authorization' header or token.","code":"UNAUTHORIZED"}`
  //    上面的 ⓪~④ **一条都匹配不上** → 返回 null → 界面只能说
  //    「这条没能回上来。可以再发一次」—— 而**对 401 来说"再发一次"是错的建议**：
  //    那位用户因此白试了 4 次（App 自动重试一轮 + 他手动再来一轮）。
  //    最冤的是：401 的人话早就写在 `translateHttpError` 里，只是这条路碰不到它。
  //
  //    两种形状都认：`<码>: {`（带 JSON 体，ACP 就是这个）与 `turn failed: <码>`。
  final httpMatch = RegExp(r'\b([45]\d\d)\b\s*:\s*\{').firstMatch(raw) ??
      RegExp(r'turn failed:\s*([45]\d\d)\b').firstMatch(raw);
  final httpCode = int.tryParse(httpMatch?.group(1) ?? '');
  if (httpCode != null) {
    return translateHttpError(statusCode: httpCode, body: raw);
  }

  return null;
}

/// 网络层异常（没有 HTTP 状态码）翻译。
ApiErrorText translateException(Object error) {
  if (error is TimeoutException) {
    return ApiErrorText(
      zh: tr('请求超时：网络太慢或服务商无响应。检查网络后重试。'),
      detail: 'TimeoutException',
      retryable: true,
    );
  }
  if (error is SocketException) {
    final msg = error.message;
    final dns = msg.toLowerCase().contains('failed host lookup') ||
        msg.toLowerCase().contains('nodename nor servname') ||
        error.osError?.errorCode == 11001;
    return ApiErrorText(
      zh: dns
          ? tr('域名解析失败：请检查 Base URL 有没有写错，以及当前网络能否上网。')
          : tr('网络不通：请检查手机网络/代理，然后重试。'),
      detail: 'SocketException: $msg',
      retryable: true,
    );
  }
  if (error is HandshakeException) {
    return ApiErrorText(
      zh: tr('TLS/HTTPS 握手失败：可能是网络中间人证书或系统时间不对。'),
      detail: 'HandshakeException: ${error.message}',
    );
  }
  if (error is HttpException) {
    // ⚠️ 这里原来是 `tr('HTTP 协议层出错：{0}.message', [error])` ——
    // `.message` 被误写进了**字面量**里，于是用户看到的是
    // 「HTTP 协议层出错：HttpException: xxx.message」（审计 P1-3），
    // 而且三张翻译表连这个笔误一起翻了。
    //
    // 现在与上面几个分支同一口径：`zh` 给一句**人话**，真实报文进 `detail`。
    return ApiErrorText(
      zh: tr('HTTP 协议层出错：连接被中途关闭，或响应不完整。检查网络后重试。'),
      detail: 'HttpException: ${error.message}',
      retryable: true,
    );
  }
  if (error is FormatException) {
    return ApiErrorText(
      zh: tr('服务端返回的内容不是合法 JSON，可能 Base URL 指向了一个网页而不是 API。'),
      detail: 'FormatException: ${error.message}',
    );
  }
  return ApiErrorText(
    zh: tr('未知错误：{0}', [error]),
    detail: error.toString(),
  );
}
