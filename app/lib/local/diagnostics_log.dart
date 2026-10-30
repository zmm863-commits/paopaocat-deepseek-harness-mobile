import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 运行日志：**有界环形缓冲 + 边跑边落盘 + 强制脱敏**。
///
/// 用户原话：「设置页面增加一个按钮，用户点击以后会生成一个日志并发送…这个日志主要
/// 是能看到运行中哪里出错了方便分析」。所以这里的取舍只有一条主线：
/// **把"出错时能立刻看出发生了什么"所需要的东西全部留下来，同时绝不把密钥带出去。**
///
/// ## 记了什么（每一条都是刻意接的）
///
///   1. `FlutterError.onError`（未捕获的框架异常）与 `PlatformDispatcher.onError`
///      （引擎/异步未捕获异常）—— [installPlatformErrorHook] + `main.dart` 里的钩子；
///   2. **`debugPrint` 的全部输出**（[installDebugPrintTee]）—— App 里到处是
///      `[dsh-chat]` `[dsh-settings-tab]` 这类带标签的日志，这是最有用的线索；
///   3. **DSH 子进程的 stdout / stderr**（`dsh_runtime.dart` 的 `runOnce` 里逐行 tee，
///      以及 ACP 会话的 `onLog` 回调 —— 它最终也是 `debugPrint`，见第 2 条）；
///   4. ACP 客户端的错误行（`[acp:stderr]` / 解析失败行，同样经 `debugPrint` 进来）；
///   5. 轮换代理的 stdout / stderr（`rotation_proxy.dart` 里 tee）。
///
/// ## 为什么"同时落盘"
///
/// 环形缓冲只在内存里 —— App 一旦崩溃或被系统杀掉，缓冲就没了，而那正是最需要
/// 证据的时刻。所以每一行**同时也追加**到 `<filesDir>/logs/dsh-diagnostic.log`，
/// 超过 [maxFileBytes] 轮转一份 `.1`。写入是**攒一批再写**（默认 700ms 或 32KB 一次），
/// 所以 `add()` 的开销和 `debugPrint` 同级，不会拖慢界面。
///
/// ## 线程安全
///
/// Dart 的每个 isolate 都是单线程的，`add()` 天然没有并发问题；真正需要串行化的
/// 只有文件写入，这里用 [_chain] 把每次 flush 串成一条链（前一次写完才写下一次），
/// 避免两次 `write` 交错。
///
/// ## 硬红线：脱敏
///
/// **所有**进入缓冲的文本都过一遍 [redact]：`sk-…` / `Bearer …` /
/// `api_key|apiKey|token|password|AGNES_API_KEY=…` 一律替换成 [redactedMarker]。
/// 另外调用方**不许**把 `ProviderKeys` 里的真实 Key 读出来交到这里
/// （报告头部只写"有没有 Key"的布尔值，见 `ui/widgets/send_log_button.dart`）。
class DiagnosticsLog {
  DiagnosticsLog._();

  /// 环形缓冲最多保留的行数。
  static const int maxLines = 800;

  /// 环形缓冲最多占用的字节数（先到者生效）。
  static const int maxBufferBytes = 256 * 1024;

  /// 落盘文件的上限；超过就轮转一份 `.1`（旧的 `.1` 被覆盖）。
  static const int maxFileBytes = 512 * 1024;

  /// 脱敏后的替身。**单元测试按这个字面量断言**，不要改。
  static const String redactedMarker = '***已脱敏***';

  static final List<String> _lines = <String>[];
  static int _bufferBytes = 0;

  static String? _filesDir;
  static String? _logFilePath;
  static IOSink? _sink;

  /// 外部私有目录的**镜像 sink**（见 [_openMirror]）。
  ///
  /// 为什么要它（2026-10-31）：这台真机的 `logcat` 时有时无（测了 5 次，多数 0 行），
  /// 而 App 私有目录 shell 读不到（release 包不能用 `run-as`）。结果是
  /// **任何只在 App 内部发生的问题都只能等用户手动导出报告** —— 一句日志等一天。
  /// 而 `/storage/emulated/0/Android/data/<包名>/files/` 是 **adb 能读**的，
  /// 写自己的外部私有目录又**不需要任何权限**。所以日志主文件照旧写私有目录，
  /// 同时镜像一份到外部 —— 排查时 `adb shell cat` 一条命令就能看。
  static IOSink? _mirror;
  static int _fileBytes = 0;
  static final List<String> _pending = <String>[];
  static int _pendingBytes = 0;
  static Timer? _timer;
  static Future<void> _chain = Future<void>.value();
  static bool _teeInstalled = false;

  /// 进程启动时刻（报告里的"本次运行时长"用它算）。
  ///
  /// ⚠️ **必须由 `main()` 调 [markProcessStart] 显式设置**：Dart 的静态字段是
  /// **首次访问时**才求值的，如果只写 `= DateTime.now()`，那真正取值的时刻就是
  /// "生成报告"的那一刻 —— 报告里的运行时长会永远显示 0 秒（已实测踩到）。
  static DateTime _startedAt = DateTime.now();

  /// 进程启动时刻（`main()` 第一件事就调它，越早越准）。
  static void markProcessStart() => _startedAt = DateTime.now();

  static DateTime get startedAt => _startedAt;

  /// 累计启动次数（存在 `<filesDir>/logs/launch-count.txt`）。
  static int launchCount = 0;

  /// 上次运行结束前的最后几行 —— **闪退/被杀的现场**。
  ///
  /// 用户 2026-10-12 报「本地大模型使用，经常性的发生闪退」。闪退 = 进程直接没了，
  /// 而 [maxLines] 那个环形缓冲**只在内存里**：最需要它的那一刻正好丢掉
  /// （文件头那句写的就是这件事）。落盘日志是**跨启动追加**的，所以在 [init] 里
  /// （还没写本次第一行之前）把上一次的尾巴截下来，报告里单独一节。
  ///
  /// ⚠️ **不断言"上次崩了"**：Android 把进程直接杀掉时**没有任何回调**，
  /// 从 App 侧分不出"正常退出"和"被系统杀掉"。所以这里只如实给出最后几行，
  /// 让读的人自己判断 —— **乱下结论比不给证据更坏**。
  static List<String> get previousRunTail => _previousTail;
  static List<String> _previousTail = <String>[];

  /// 上次运行的尾巴最多带这么多行进报告（够看出崩在哪，又不至于把报告撑爆）。
  static const int maxPreviousTailLines = 120;

  /// 从落后盘日志里截出"上次运行结束前"的尾巴（见 [previousRunTail]）。
  static void _capturePreviousRunTail() {
    _previousTail = <String>[];
    final path = _logFilePath;
    if (path == null) return;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final all = f
          .readAsStringSync()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (all.isEmpty) return;
      _previousTail = all.length <= maxPreviousTailLines
          ? all
          : all.sublist(all.length - maxPreviousTailLines);
    } catch (_) {
      // 读不到就当没有 —— 这条路径绝不能反过来把启动搞坏。
    }
  }

  /// 本地模型的**崩溃记录**行（`crashes.json`：`"模型|后端": 次数`）。
  ///
  /// 这份记录 0.26 起就在了（用来"崩过就自动换后端"），但**报告里一直没有它** ——
  /// 于是"经常闪退"这种反馈根本对不上账（哪个模型、哪个后端、崩了几次，
  /// 全在盘上，就是没人看得到）。这里在生成报告时读出来。
  ///
  /// 为什么自己拼路径而不是让调用方传：诊断报告这一层只拿得到 `filesDir`，
  /// 而崩溃记录在 `<DSH_HOME>/models/` 下（`DSH_HOME` 由运行时决定）。
  /// 诊断是"尽力而为"，所以两个已知位置都试一下，读不到就返回空。
  static Future<List<String>> crashRecordLines() async {
    final dir = _filesDir;
    if (dir == null) return const <String>[];
    final sep = Platform.pathSeparator;
    for (final cand in <String>[
      '$dir${sep}dshhome${sep}models${sep}crashes.json',
      '$dir${sep}models${sep}crashes.json',
    ]) {
      try {
        final f = File(cand);
        if (!f.existsSync()) continue;
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is! Map || raw.isEmpty) continue;
        final entries = raw.entries.toList()
          ..sort((a, b) => (b.value as num).compareTo(a.value as num));
        return <String>[
          for (final e in entries)
            '  - ${'${e.key}'.replaceAll('|', ' | ')}：崩过 ${e.value} 次',
        ];
      } catch (_) {
        // 读坏了不影响报告生成。
      }
    }
    return const <String>[];
  }

  /// 落盘文件路径（未初始化时为 null）。
  static String? get logFilePath => _logFilePath;

  /// 日志目录（未初始化时为 null）。
  static String? get logsDir =>
      _filesDir == null ? null : '$_filesDir${Platform.pathSeparator}logs';

  /// 本次运行已持续多久（人类可读）。
  static String get uptimeText =>
      _humanDuration(DateTime.now().difference(startedAt));

  /// 当前缓冲里有多少行。
  static int get lineCount => _lines.length;

  // ------------------------------------------------------------------ 初始化

  /// 指向 App 私有目录并打开落盘文件（幂等；失败只降级为"只在内存里"）。
  ///
  /// [filesDir] 来自 `DshHost.getPaths()['filesDir']`，由 `main.dart` 在
  /// `runApp` 之前调用 —— 越早越好，否则启动阶段那几十行线索就丢了。
  static Future<void> init({required String filesDir}) async {
    if (_filesDir == filesDir && _sink != null) return;
    _filesDir = filesDir;
    try {
      final dir = Directory('$filesDir/logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _logFilePath = '${dir.path}/dsh-diagnostic.log';
      launchCount = _bumpLaunchCount(dir);
      // ⚠️ **必须在写本次第一行之前截取**：落盘日志是跨启动追加的，
      //    此刻文件的尾巴正好就是"上次运行结束前"的现场。
      _capturePreviousRunTail();
      await _openSink();
      add('dsh-log', '诊断日志启动：第 $launchCount 次启动，落盘=$_logFilePath');
    } catch (e) {
      // 落盘失败不影响功能：内存缓冲照旧，用户在界面上仍能导出。
      add('dsh-log', '日志落盘初始化失败（改为只在内存里保留）：$e');
    }
  }

  /// 累计启动次数 +1（读不到就当 0）。
  static int _bumpLaunchCount(Directory dir) {
    final f = File('${dir.path}/launch-count.txt');
    var n = 0;
    try {
      if (f.existsSync()) n = int.tryParse(f.readAsStringSync().trim()) ?? 0;
    } catch (_) {}
    n++;
    try {
      f.writeAsStringSync('$n\n', flush: true);
    } catch (_) {}
    return n;
  }

  // -------------------------------------------------------------------- 写入

  /// 记一行。[tag] 形如 `dsh-chat` / `dsh-rotate:stderr`。
  ///
  /// 传入的文本里如果有换行，会被拆成多行（缓冲和报告都是"一行一条"）。
  /// **脱敏在这里做**（唯一入口），调用方不用自己处理。
  static void add(String tag, String line) {
    if (line.isEmpty) return;
    final safe = redact(line);
    final stamp = _timeStamp(DateTime.now());
    for (final raw in safe.split('\n')) {
      if (raw.isEmpty) continue;
      _push('$stamp [$tag] $raw');
    }
    _scheduleFlush();
  }

  /// 记录一次未捕获异常（异常 + 上下文 + 栈前 20 帧）。
  static void addFlutterError(
    String tag,
    Object error,
    StackTrace? stack, {
    Object? context,
  }) {
    add(tag, '未捕获异常：$error');
    if (context != null) add(tag, '位置/上下文：$context');
    if (stack == null) {
      add(tag, '（没有栈信息）');
      return;
    }
    var shown = 0;
    for (final line in stack.toString().split('\n')) {
      if (line.trim().isEmpty) continue;
      if (shown >= 20) {
        add(tag, '  …（栈余下部分省略）');
        break;
      }
      add(tag, '  $line');
      shown++;
    }
  }

  static void _push(String entry) {
    _lines.add(entry);
    _bufferBytes += entry.length;
    // 双重上限：行数或字节数任一超标就从最旧的一行开始丢。
    while (_lines.length > maxLines || _bufferBytes > maxBufferBytes) {
      if (_lines.isEmpty) break;
      final gone = _lines.removeAt(0);
      _bufferBytes -= gone.length;
      if (_lines.length <= 1) break; // 单行超过上限时也别把自己清空
    }
    _pending.add('$entry\n');
    _pendingBytes += entry.length + 1;
  }

  /// 环形缓冲的快照（按时间顺序，换行分隔）。**不含**报告头部。
  static String snapshot() => _lines.join('\n');

  /// 清空内存缓冲（落盘文件不动 —— 那是崩溃证据，用户没要求删就不删）。
  static void clear() {
    _lines.clear();
    _bufferBytes = 0;
  }

  // ------------------------------------------------------------------ 落盘

  /// 把攒着的行立刻写进磁盘文件。报告生成前、App 退出前调用它。
  static Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _chain = _chain.then((_) => _flushNow());
    return _chain;
  }

  static void _scheduleFlush() {
    if (_sink == null) return; // 还没初始化：只留在内存
    if (_pendingBytes >= 32 * 1024) {
      unawaited(flush());
      return;
    }
    _timer ??= Timer(const Duration(milliseconds: 700), () {
      _timer = null;
      unawaited(flush());
    });
  }

  static Future<void> _flushNow() async {
    if (_pending.isEmpty) return;
    final sink = _sink;
    if (sink == null) return;
    final chunk = _pending.join();
    _pending.clear();
    _pendingBytes = 0;
    try {
      sink.write(chunk);
      try {
        _mirror?.write(chunk);
      } catch (_) {
        // 外部目录写不进去就算了 —— 绝不能因为"方便排查"影响主日志
      }
      _fileBytes += utf8.encode(chunk).length;
      await sink.flush();
      if (_fileBytes > maxFileBytes) await _rotateAndReopen();
    } catch (_) {
      // 写盘失败不能影响 App：丢掉这一批，内存缓冲仍有。
    }
  }

  static Future<void> _openSink() async {
    final path = _logFilePath;
    if (path == null) return;
    // ⚠️ 这里**必须自己兜住**（2026-10-19 补）：
    //   ① 目录可能在 init 建好之后被清掉（真机清理、测试的临时目录回收都算）；
    //   ② 这个函数跑在**异步链**上（`await _openSink()` 在 `init` 里，而 `init` 可能
    //      没被 await），一旦抛出去就是"无人接的异常" —— 表现是测试跑完之后才报
    //      `PathNotFoundException`（本机全量并发跑时才复现，单独跑一定绿）。
    //   落盘日志是**诊断手段**，不是功能：任何一步失败都只降级为"只留内存"，不抛。
    try {
      final f = File(path);
      final parent = f.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      _fileBytes = f.existsSync() ? f.lengthSync() : 0;
      if (_fileBytes > maxFileBytes) _rotateOnce(f);
      _sink = f.openWrite(mode: FileMode.append);
      _openMirror();
    } catch (e) {
      _sink = null;
      add('dsh-log', '日志落盘不可用（改为只在内存里保留）：$e');
    }
  }

  /// 打开外部私有目录的镜像 sink（首次创建时把主日志补一份过去）。
  ///
  /// 路径 = `/storage/emulated/0/Android/data/<包名>/files/dsh-diagnostic.log`，
  /// 包名从 [_filesDir] 反推（`/data/user/0/<包名>/files`），不硬编码 —— 改包名不用改这里。
  static void _openMirror() {
    try {
      final dir = _filesDir;
      if (dir == null) return;
      final parts = dir.split(Platform.pathSeparator);
      final pkg = parts.length >= 2 ? parts[parts.length - 2] : '';
      if (pkg.isEmpty) return;
      final dstDir = Directory('/storage/emulated/0/Android/data/$pkg/files');
      if (!dstDir.existsSync()) dstDir.createSync(recursive: true);
      final dst = File('${dstDir.path}/dsh-diagnostic.log');
      if (dst.existsSync() && dst.lengthSync() > maxFileBytes) {
        try { dst.deleteSync(); } catch (_) {}
      }
      // 首次创建（或外部那份还空着）：把主日志已有内容补一份，免得只有"从今天起"的日志
      if (!dst.existsSync() || dst.lengthSync() == 0) {
        final srcPath = _logFilePath;
        if (srcPath != null) {
          final src = File(srcPath);
          if (src.existsSync() && src.lengthSync() > 0) {
            try { src.copySync(dst.path); } catch (_) {}
          }
        }
      }
      _mirror = dst.openWrite(mode: FileMode.append);
    } catch (_) {
      _mirror = null; // 外部存储不可用（少数 ROM / 权限异常）→ 静默放弃
    }
  }

  static void _rotateOnce(File f) {
    try {
      final old = File('${f.path}.1');
      if (old.existsSync()) old.deleteSync();
      f.renameSync(old.path);
    } catch (_) {}
  }

  static Future<void> _rotateAndReopen() async {
    await _closeSink();
    final path = _logFilePath;
    if (path != null) _rotateOnce(File(path));
    _fileBytes = 0;
    if (path != null) _sink = File(path).openWrite(mode: FileMode.append);
  }

  static Future<void> _closeSink() async {
    final mirror = _mirror;
    _mirror = null;
    if (mirror != null) {
      try {
        await mirror.flush();
        await mirror.close();
      } catch (_) {}
    }
    final sink = _sink;
    _sink = null;
    if (sink == null) return;
    try {
      await sink.flush();
    } catch (_) {}
    try {
      await sink.close();
    } catch (_) {}
  }

  // ------------------------------------------------- 结构化（给人和模型读）

  /// 一行的结构：`HH:MM:SS.mmm [tag] 正文`（`[tag]` 也可能是 `[[tag]]`）。
  static final RegExp _lineRe =
      RegExp(r'^(\d{2}:\d{2}:\d{2}\.\d{3})\s+\[+([^\]]+)\]+\s*(.*)$');

  /// 拆一行日志。拆不动（例如原生丢进来的裸行）就原样塞进 `msg`。
  static ({String ts, String tag, String lvl, String msg}) parseLine(
      String line) {
    final m = _lineRe.firstMatch(line);
    final ts = m?.group(1) ?? '';
    final tag = m?.group(2) ?? 'raw';
    final msg = m?.group(3) ?? line;
    return (ts: ts, tag: tag, lvl: levelOf(msg, tag: tag), msg: msg);
  }

  /// 判级别：只认**明确**的信号，不猜语气。
  ///
  /// ⚠️ [tag] 会决定**要不要扫关键词**。真机 2026-10-16 的教训：模型（在写游戏代码）
  /// 满屏 `fail` / `error` / `throws` / `异常`，按关键词判级会让报告里
  /// 「错误 10 条」有 8 条其实是**模型的原话** —— 用户看到数字就以为出了大事，
  /// 我排查时也得先把它剔掉。所以：
  ///   * `print`（裸行）= 模型/子进程的原始输出 → **不判级**，一律 I；
  ///   * `print:chat` 里以 `thought:` / `message:` / `stopReason=` / `prompt:` 开头的是
  ///     **会话正常事件** → I；其它（例如 `prompt failed`）仍然照常判级；
  ///   * App 自己的日志（`print:dsh-*`）与其余 tag 一律照旧。
  static String levelOf(String msg, {String tag = ''}) {
    if (tag == 'print') return 'I';
    if (tag == 'print:chat') {
      for (final p in const <String>[
        'thought:',
        'message:',
        'stopReason=',
        'prompt:',
        'tool:',
      ]) {
        if (msg.startsWith(p)) return 'I';
      }
    }
    final m = msg.toUpperCase();
    // "零失败"是**自证清白**，不是失败：`失败 0` / `错误: 0`。
    //
    // 为什么必须特判（真机 2026-10-09）：内置技能那一行结尾是 `/ 失败 0`，
    // 于是每次启动导出的报告里都挂着一条**假错误**（KEY 区 `[E×1]`），
    // 真正的错误反而被它淹没 —— 而导出报告正是我们排查真机问题的唯一入口。
    //
    // 收紧的边界：0 后面不能紧跟数字/字母（避免把 `失败 0x800` 这种当成零失败）。
    final zeroFail = RegExp(r'(失败|错误)\s*[:：]?\s*0(?![\dA-Za-z])').hasMatch(msg);
    if (m.contains(' ERR ') ||
        m.contains('[E]') ||
        m.contains('ERROR') ||
        // ⚠️ 必须认英文 `FAILED`：真机日志里最常见的失败行长这样
        //   `prompt failed（第 1 次）: request (6959 tokens) ...`
        // 只认中文"失败"会把它们全归成 I（测试抓到的漏判）。
        m.contains('FAILED') ||
        m.contains('FAIL ') ||
        m.contains('EXCEPTION') ||
        m.contains('未捕获异常') ||
        m.contains('异常') ||
        // 中文"失败" —— 但 `失败 0` 不算（见上）。
        (m.contains('失败') && !zeroFail) ||
        m.contains('不存在') ||
        m.contains('拒绝')) {
      return 'E';
    }
    if (m.contains('[W]') ||
        m.contains('WARN') ||
        m.contains('超时') ||
        m.contains('警告')) {
      return 'W';
    }
    return 'I';
  }

  /// 归一化：把"只有数字/路径不同"的同一类错误并成一组。
  ///
  /// 这是**报告能不能被别人一眼看懂**的关键：真机一次失败会在日志里留下十几条
  /// 长得一样、只有 token 数不同的行；不归一化，报告顶部就还是一堆重复。
  static String normalize(String msg) {
    var s = msg;
    s = s.replaceAll(RegExp(r'\b[0-9a-fA-F]{8,}\b'), '#hex');
    s = s.replaceAll(RegExp(r'\d+'), '#');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  /// 关键事件：把错误/警告按内容聚合（次数 + 首末时间）。
  static List<
      ({
        String lvl,
        int count,
        String first,
        String last,
        String tag,
        String msg
      })> keyEvents() => keyEventsFrom(_lines);

  /// 聚合逻辑的**纯函数版本**（不碰全局缓冲，便于单测）。
  static List<
      ({
        String lvl,
        int count,
        String first,
        String last,
        String tag,
        String msg
      })> keyEventsFrom(List<String> rawLines) {
    final byKey = <String,
        ({
      String lvl,
      int count,
      String first,
      String last,
      String tag,
      String msg
    })>{};
    for (final raw in rawLines) {
      final p = parseLine(raw);
      if (p.lvl == 'I') continue;
      final key = '${p.lvl}|${p.tag}|${normalize(p.msg)}';
      final old = byKey[key];
      if (old == null) {
        byKey[key] = (
          lvl: p.lvl,
          count: 1,
          first: p.ts,
          last: p.ts,
          tag: p.tag,
          msg: normalize(p.msg),
        );
      } else {
        byKey[key] = (
          lvl: old.lvl,
          count: old.count + 1,
          first: old.first,
          last: p.ts,
          tag: old.tag,
          msg: old.msg,
        );
      }
    }
    final out = byKey.values.toList()
      ..sort((a, b) => b.count == a.count
          ? a.first.compareTo(b.first)
          : b.count.compareTo(a.count));
    return out;
  }

  /// 明细行：`seq|ts|lvl|tag|msg`，并**丢掉/压缩**两类内容：
  ///   * 会话内容转储（那种几万字节的 JSON，含用户对话正文）→ 只留一句占位；
  ///   * 超长行 → 截断（长篇文档/提示词会在日志里炸开）。
  static List<String> detailLines({int maxMsg = 400}) =>
      detailLinesFrom(_lines, maxMsg: maxMsg);

  /// 明细拼装的**纯函数版本**（便于单测）。
  static List<String> detailLinesFrom(List<String> rawLines,
      {int maxMsg = 400}) {
    final out = <String>[];
    for (var i = 0; i < rawLines.length; i++) {
      final p = parseLine(rawLines[i]);
      var msg = p.msg;
      if (_looksLikeSessionDump(msg)) {
        msg = '（会话内容已省略：# 字节）';
      } else {
        msg = normalizeForDisplay(msg);
        if (msg.length > maxMsg) msg = '${msg.substring(0, maxMsg)}…（已截断）';
      }
      out.add(
          '${(i + 1).toString().padLeft(4, '0')}|${p.ts}|${p.lvl}|${p.tag}|$msg');
    }
    return out;
  }

  /// 一整行就是会话 JSON 转储（含 messages/role）→ 视为隐私内容。
  static bool _looksLikeSessionDump(String msg) {
    final t = msg.trimLeft();
    return t.startsWith('{') &&
        (t.contains('"messages"') || t.contains('"role"')) &&
        t.length > 2000;
  }

  /// 展示用的轻归一化：**只压缩空白与超长 hex**，不动数字与路径
  /// （明细是"出事现场"，不该被过度改写）。
  static String normalizeForDisplay(String msg) =>
      msg.replaceAll(RegExp(r'[ \t]{3,}'), '  ').trim();

  /// 报告顶部的统计。
  static String statsText() {
    final ev = keyEvents();
    final e = ev.where((x) => x.lvl == 'E').fold<int>(0, (a, x) => a + x.count);
    final w = ev.where((x) => x.lvl == 'W').fold<int>(0, (a, x) => a + x.count);
    return '错误 $e 条 · 警告 $w 条 · 明细 ${_lines.length} 行';
  }

  // ------------------------------------------------------------------ 报告

  /// 生成"可发给开发者"的报告文件 `<filesDir>/logs/dsh-report-<时间戳>.txt`。
  ///
  /// [headerLines] 由调用方给（App 版本、机型、系统、已配置厂家摘要、当前 route…），
  /// 这样本类保持"零业务依赖"，可以脱离平台插件做单元测试。
  /// 返回文件绝对路径；还没 [init] 就返回 null。
  static Future<String?> writeToFile({
    List<String> headerLines = const <String>[],
    String prefix = 'dsh-report',
  }) async {
    final dir = _filesDir;
    if (dir == null) return null;
    await flush();

    final logs = Directory('$dir/logs');
    if (!logs.existsSync()) logs.createSync(recursive: true);
    final file = File('${logs.path}/$prefix-${_fileStamp(DateTime.now())}.txt');

    // ── 排版说明（2026-10-07 用户提问"日志生成什么格式比较好"后重排）──
    //
    // 目标：**让"谁"都能快速看懂** ——
    //   * 人：先看头部与 KEY 段，不用在几百行里翻；
    //   * 大模型：紧凑的 `seq|ts|lvl|tag|msg`，比 JSON 省 30–50% token，
    //     且聚合后的 KEY 段让它一眼看到"什么错了、错了几次"；
    //   * 隐私：会话内容那种几十 KB 的 JSON 转储**默认不写进去**。
    final buf = StringBuffer();
    buf.writeln(
        '# dsh-report v${_reportAppVersion()} | 字段: seq|ts|lvl|tag|msg');
    buf.writeln('# 生成时间 ${_fullStamp(DateTime.now())}');
    for (final line in headerLines) {
      buf.writeln('# $line');
    }
    buf.writeln('# 本次运行时长：$uptimeText');
    buf.writeln('# 环形缓冲：${_lines.length}/$maxLines 行 · ${statsText()}');
    buf.writeln('');
    buf.writeln('--- KEY（错误与警告，按内容聚合：级别×次数 | 首→末时间 | 标签 | 内容）---');
    final events = keyEvents();
    if (events.isEmpty) {
      buf.writeln('（本次运行没有错误或警告）');
    } else {
      for (final e in events) {
        final times = e.count == 1 ? e.first : '${e.first}→${e.last}';
        buf.writeln('[${e.lvl}×${e.count}] $times | ${e.tag} | ${e.msg}');
      }
    }
    buf.writeln('');
    // ── 闪退/被杀现场（见 [previousRunTail]）────────────────────────────
    //
    // 放在 KEY 之后、DETAIL 之前：先看"这次运行错在哪"，再看"上次是怎么没的"。
    // **刻意不加"上次崩了/没崩"的结论** —— 从 App 侧分不出来，乱下结论比不给证据更坏。
    if (_previousTail.isNotEmpty) {
      buf.writeln(
          '--- 上次运行结束前（最后 ${_previousTail.length} 行；闪退/被杀的现场就在这里）---');
      for (final line in _previousTail) {
        buf.writeln(line);
      }
      buf.writeln('');
    }
    buf.writeln('--- DETAIL（最近 ${_lines.length} 行，按时间顺序）---');
    for (final line in detailLines()) {
      buf.writeln(line);
    }
    buf.writeln('');
    buf.writeln('--- 末尾 ---');
    buf.writeln('用户补充说明：__________________________________________');

    await file.writeAsString(buf.toString(), flush: true);
    add('dsh-log', '报告已生成：${file.path}（${file.lengthSync()} 字节）');
    await flush();
    return file.path;
  }

  // -------------------------------------------------------------------- 钩子

  /// 把 `debugPrint` 包一层：**原行为（logcat）保持不变**，额外把每一行喂给缓冲。
  ///
  /// 这是"能看出哪里出错"的最大来源 —— 项目里所有 `[dsh-*]` 标签日志都走它。
  static void installDebugPrintTee() {
    if (_teeInstalled) return;
    _teeInstalled = true;
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      // 先记一笔再走原处理器：万一原处理器自己抛了（或在测试环境里被替换成
      // 别的实现），我们已经把这一行留下来了 —— 这正是"崩溃时能看出发生了什么"的前提。
      if (message != null && message.isNotEmpty) {
        try {
          _teePrint(message);
        } catch (_) {
          // 日志本身绝不能把 App 搞崩。
        }
      }
      // 原行为照旧：logcat 才是真机排查的第一现场。
      original(message, wrapWidth: wrapWidth);
    };
  }

  /// `[dsh-xxx] 正文` → tag=`print:dsh-xxx`、正文=剩余部分（报告里更好扫）。
  static void _teePrint(String message) {
    for (final raw in message.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;
      // FlutterError 那条路已经由 `main.dart` 结构化记过一次（含完整栈），
      // 这里跳过它自己打印的副本，免得一份异常把半个缓冲占满。
      if (line.trimLeft().startsWith('[dsh-flutter-error]')) continue;
      final m = RegExp(r'^\s*\[([^\]]+)\]\s?(.*)$').firstMatch(line);
      if (m != null) {
        add('print:${m.group(1)}', m.group(2)!);
      } else {
        add('print', line);
      }
    }
  }

  /// 引擎/平台层未捕获异常（异步异常也走这里）。
  ///
  /// 返回值**保持原行为**：没有旧处理器时返回 `false`，让系统照旧打印/上报，
  /// 我们只是"顺手记一笔"，不静默吞掉任何东西。
  static void installPlatformErrorHook() {
    final previous = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      addFlutterError('dsh-platform-error', error, stack);
      if (previous != null) return previous(error, stack);
      return false;
    };
  }

  // ------------------------------------------------------------------ 脱敏

  /// 脱敏：把可能的凭据替换成 [redactedMarker]。
  ///
  /// 覆盖（顺序有意义，先长的先替）：
  ///   * `Bearer xxx` / `Basic xxx` 授权头；
  ///   * `sk-…`（OpenAI / DeepSeek / Agnes 那一族）、`sk_…`、Google 风格 `AIza…`；
  ///   * 键值对：`api_key` / `apiKey` / `API_KEY`（含 `AGNES_API_KEY=` 这种环境变量写法）、
  ///     `password` / `secret` / `authorization` / `access_token` / `auth_token`；
  ///   * 单独的 `token=` / `key=`（值必须≥8 字符，避免把 `max_tokens: 4096` 这种误伤）。
  ///
  /// 拿不准时**宁可多脱一点**：这是安全方向的偏差。
  static String redact(String input) {
    if (input.isEmpty) return input;
    var s = input;
    s = s.replaceAllMapped(
      _bearerRe,
      (m) => '${m[1]} $redactedMarker',
    );
    s = s.replaceAll(_skRe, redactedMarker);
    s = s.replaceAll(_skAltRe, redactedMarker);
    s = s.replaceAll(_googleKeyRe, redactedMarker);
    s = s.replaceAllMapped(
      _kvStrongRe,
      (m) => '${m[1]}${m[2]}$redactedMarker',
    );
    s = s.replaceAllMapped(
      _kvWeakRe,
      (m) => '${m[1]}${m[2]}$redactedMarker',
    );
    // URL 里内嵌的凭据：`https://user:pass@host/...`（审计 P2 指出的缺口）。
    //
    // 这一条与上面那些**不重叠**：上面的 kv 规则要求 `名字=值` 的形状，
    // 而这里根本没有"名字" —— 凭据直接写在 URL 的 authority 段里。
    // 报告里出现这种 URL（用户填的 Base URL、代理地址）就会把口令原样带出去。
    s = s.replaceAllMapped(
        _userinfoRe, (m) => '${m[1]}$redactedMarker@');
    return s;
  }

  // ⚠️ 大小写不敏感**必须**用 `caseSensitive: false`，不能在模式里写 `(?i)`：
  // Dart 的 RegExp 是 ECMAScript 语义，`(?i)` 会在**运行期**抛
  // `FormatException: Invalid group`（已实测），静态分析也会报 valid_regexps。
  static final RegExp _bearerRe = RegExp(
    r'\b(Bearer|Basic)\s+([A-Za-z0-9\-._~+/=]{6,})',
    caseSensitive: false,
  );
  static final RegExp _skRe = RegExp(r'sk-[A-Za-z0-9_\-]{4,}');
  static final RegExp _skAltRe = RegExp(r'sk_[A-Za-z0-9]{8,}');
  static final RegExp _googleKeyRe = RegExp(r'AIza[A-Za-z0-9_\-]{10,}');
  static final RegExp _kvStrongRe = RegExp(
    r'''\b([A-Za-z0-9_\-]*(?:api[_-]?key|apikey|password|passwd|secret|authorization|access[_-]?token|auth[_-]?token)[A-Za-z0-9_\-]*)(\s*["']?\s*[:=]\s*["']?)([^\s"',;)}\]]+)''',
    caseSensitive: false,
  );
  static final RegExp _kvWeakRe = RegExp(
    r'''\b([A-Za-z0-9_\-]*(?:token|key))(\s*["']?\s*[:=]\s*["']?)([^\s"',;)}\]]{8,})''',
    caseSensitive: false,
  );

  /// `https://user:pass@host` 里的 `user:pass`。
  ///
  /// 为什么不用 `(?<=://)` 这种后行断言：Dart 的 RegExp 是 ECMAScript 语义，
  /// 后行断言支持有限、静态分析也会挑；这里用捕获组把 scheme 一起吃掉再放回来。
  ///
  /// ⚠️ **故意不加**"裸的 32/64 位 hex 一律脱敏"那条（审计建议过）：
  /// 本 App 的日志里**必须**留证书指纹（配对时要让用户肉眼核对 `AA:BB:CC…`）
  /// 和文件 sha256 —— 一律脱敏会把用户唯一能自证的东西抹掉，
  /// 那是"为了安全把功能弄坏"。带 key/token/secret 字样的 hex 仍会被上面
  /// 的 kv 规则脱敏。
  static final RegExp _userinfoRe =
      RegExp(r'([A-Za-z][A-Za-z0-9+.\-]*://)[^\s/:@]+:[^\s/@]+@');

  // ------------------------------------------------------------------ 时间

  static String _two(int v) => v < 10 ? '0$v' : '$v';

  static String _timeStamp(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';

  /// 报告头部写版本号用（本类零业务依赖，所以由调用方通过 headerLines 带，
  /// 这里只做兜底：拿不到就写 `?`）。
  static String _reportAppVersion() => _appVersionHint ?? '?';
  static String? _appVersionHint;

  /// 调用方（App 层）注入版本号，避免本类去依赖 app_version。
  static void hintAppVersion(String v) => _appVersionHint = v;

  static String _fileStamp(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

  static String _fullStamp(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static String _humanDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} 秒';
    if (d.inMinutes < 60) return '${d.inMinutes} 分 ${d.inSeconds % 60} 秒';
    return '${d.inHours} 小时 ${d.inMinutes % 60} 分';
  }
}

/// 逐行 tee 的小工具：把**任意切分的 chunk**（子进程管道就是这种）还原成整行，
/// 再交给 [DiagnosticsLog]，而**不影响调用方自己的解析**。
///
/// 为什么需要它：`Process.stdout` 一次给的是半行或几十行都有可能，直接 add 会把
/// 一行拆成好几条、报告里读不成句。这里只攒"还没等到换行的那一截"。
class DiagnosticsLineTee {
  DiagnosticsLineTee(this.tag);

  final String tag;
  String _partial = '';

  /// 单行上限：没有换行的超长输出（例如一整份 JSON）不该把内存撑大。
  static const int maxLineChars = 8192;

  void feed(String chunk) {
    if (chunk.isEmpty) return;
    _partial += chunk;
    var idx = _partial.indexOf('\n');
    while (idx >= 0) {
      final line = _partial.substring(0, idx);
      _partial = _partial.substring(idx + 1);
      if (line.trim().isNotEmpty) DiagnosticsLog.add(tag, line);
      idx = _partial.indexOf('\n');
    }
    if (_partial.length > maxLineChars) {
      DiagnosticsLog.add(
          tag, '${_partial.substring(0, maxLineChars)}…（超长行已截断）');
      _partial = '';
    }
  }

  /// 收尾：把最后没有换行的那一截也记下来。
  void finish() {
    final tail = _partial;
    _partial = '';
    if (tail.trim().isNotEmpty) DiagnosticsLog.add(tag, tail);
  }
}
