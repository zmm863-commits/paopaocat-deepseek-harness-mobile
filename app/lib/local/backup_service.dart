import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../i18n/dsh_i18n.dart';
import 'dsh_runtime.dart';
import 'diagnostics_log.dart';

/// 换机迁移：把 App 的数据打成一个**加密文件**，以及从它还原。
///
/// ## 为什么整件事在 node 侧做
///
/// 加密要 AES-256-GCM + scrypt，zip 要自己拼 —— 这些 `node:crypto` 和
/// `office-zip.mjs` 都已经有了。Dart 侧做同样的事要引 `cryptography` 包，
/// 而手机上没有 npm（依赖装不上），且多一个包就多一份体积和风险。
///
/// Dart 这边只负责三件事：**决定给哪些文件、传密码、把结果说成人话**。
///
/// ## 密码怎么传
///
/// 走 **stdin**，不进 argv。进 argv 的话 `/proc/<pid>/cmdline` 同 uid 可读，
/// 手机上任何一个 App 扫一遍进程列表就把用户的备份密码看走了。
class BackupService {
  BackupService._();

  /// 打包超时：大工作区（几百 MB）在手机上可能要一两分钟，给足。
  static const Duration _packTimeout = Duration(minutes: 5);

  /// 默认要打包的东西（与 `backup.mjs` 的 DEFAULT_INCLUDES 保持一致）。
  ///
  /// 判据只有一条：**这条数据在新手机上重新生成得出来吗？**
  /// 运行时（106MB）、工具箱脚本、各种缓存都能重新生成，一律不迁。
  static const List<String> defaultIncludes = <String>[
    'sessions', // 历史对话（最值钱）
    'workspace', // 用户文件
    'models.json', // 厂家/模型/轮换池配置（不含 Key）
    'experts.json',
    'memory.json',
    'local_chat.json',
    'workspaces.json',
  ];

  /// 打一个备份包到 [outPath]。
  static Future<BackupResult> pack({
    required DshRuntime runtime,
    required String password,
    required String outPath,
    List<String>? include,
  }) async {
    final r = await _run(
      runtime: runtime,
      args: <String>[
        runtime.backupScriptPath,
        'pack',
        '--root',
        runtime.filesDir,
        '--out',
        outPath,
        '--include',
        (include ?? defaultIncludes).join(','),
      ],
      password: password,
      timeout: _packTimeout,
    );
    if (!r.ok) return r;
    final files = (r.json?['files'] as num?)?.toInt() ?? 0;
    final packed = (r.json?['packedBytes'] as num?)?.toInt() ?? 0;
    return BackupResult(
      ok: true,
      files: files,
      bytes: packed,
      out: outPath,
    );
  }

  /// 只看包里有什么（要密码：不解密读不到 manifest）。
  static Future<BackupInspect> inspect({
    required DshRuntime runtime,
    required String inPath,
    required String password,
  }) async {
    final r = await _run(
      runtime: runtime,
      args: <String>[
        runtime.backupScriptPath,
        'list',
        '--in',
        inPath,
      ],
      password: password,
      timeout: const Duration(seconds: 90),
    );
    if (!r.ok) return BackupInspect(ok: false, error: r.error);
    final j = r.json ?? const <String, dynamic>{};
    return BackupInspect(
      ok: true,
      files: (j['files'] as num?)?.toInt() ?? 0,
      totalBytes: (j['totalBytes'] as num?)?.toInt() ?? 0,
      packedBytes: (j['packedBytes'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse('${j['createdAt'] ?? ''}'),
    );
  }

  /// 真正覆盖还原（**调用方必须先做安全备份**，见 [restoreWithSafety]）。
  static Future<BackupResult> unpack({
    required DshRuntime runtime,
    required String inPath,
    required String password,
    bool dryRun = false,
  }) async {
    final r = await _run(
      runtime: runtime,
      args: <String>[
        runtime.backupScriptPath,
        'unpack',
        '--in',
        inPath,
        '--root',
        runtime.filesDir,
        if (dryRun) '--dry-run',
      ],
      password: password,
      timeout: _packTimeout,
    );
    if (!r.ok) return r;
    return BackupResult(
      ok: true,
      files: (r.json?['files'] as num?)?.toInt() ?? 0,
      bytes: (r.json?['totalBytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// 带**安全退路**的还原：先把当前数据打一份 `导入前-*.pcbak`，再覆盖。
  ///
  /// 为什么必须有这一步：导入是破坏性操作，而最惨的场景是用户选错了包
  /// （比如半年前那份）—— 当前的数据会被直接盖掉，找不回来。
  ///
  /// 安全备份失败就**不继续**：宁可这次导入不成，也不能让用户在没有退路的情况下覆盖。
  static Future<BackupResult> restoreWithSafety({
    required DshRuntime runtime,
    required String inPath,
    required String password,
  }) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    final safetyPath = '${runtime.filesDir}/导入前-$stamp.pcbak';

    final safety = await pack(
      runtime: runtime,
      password: password,
      outPath: safetyPath,
    );
    if (!safety.ok) {
      return BackupResult(
        ok: false,
        error: tr('为了安全，导入前要先给当前数据做一份备份，但那一步失败了：{0}',
            <Object?>[safety.error ?? '']),
      );
    }
    debugPrint('[dsh-backup] 已留退路：$safetyPath（${safety.files} 个文件）');
    DiagnosticsLog.add('[dsh-backup]', '导入前安全备份：$safetyPath');

    final r = await unpack(
      runtime: runtime,
      inPath: inPath,
      password: password,
    );
    if (!r.ok) {
      return BackupResult(
        ok: false,
        error: tr('导入失败：{0}（当前数据还在，导入前的备份在「{1}」）',
            <Object?>[r.error ?? '', safetyPath]),
      );
    }
    return BackupResult(
      ok: true,
      files: r.files,
      bytes: r.bytes,
      safetyPath: safetyPath,
    );
  }

  // ── 内部：起 node、喂密码、收 JSON ──────────────────────────────

  static Future<BackupResult> _run({
    required DshRuntime runtime,
    required List<String> args,
    required String password,
    required Duration timeout,
  }) async {
    if (password.isEmpty) {
      return BackupResult(ok: false, error: tr('密码不能为空'));
    }
    final script = runtime.backupScriptPath;
    if (!File(script).existsSync()) {
      return BackupResult(
          ok: false, error: tr('备份脚本没落盘（{0}），请重启 App 再试', <Object?>[script]));
    }

    Process? proc;
    try {
      proc = await runtime.spawn(args, withShims: false);
    } catch (e) {
      return BackupResult(ok: false, error: tr('起不了 node 进程：{0}', <Object?>['$e']));
    }

    // ⚠️ 必须**先读输出、后等退出**：node 退出事件常常比 stdout 的
    //    数据事件先到，先 cancel 会把还没读到的 JSON 丢掉
    //    （`dsh_runtime.runOnce` 的注释里记过同一个坑）。
    final outFuture = proc.stdout.transform(utf8.decoder).join();
    final errFuture = proc.stderr.transform(utf8.decoder).join();

    try {
      proc.stdin.writeln(password);
      await proc.stdin.close();
    } catch (_) {
      // 进程可能已经死了，下面靠 exitCode 判断
    }

    final int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
      await outFuture.catchError((_) => '');
      await errFuture.catchError((_) => '');
      return BackupResult(
          ok: false, error: tr('操作超时（{0} 分钟），数据量可能太大', <Object?>[timeout.inMinutes]));
    }

    final out = await outFuture.catchError((_) => '');
    final err = await errFuture.catchError((_) => '');
    if (err.trim().isNotEmpty) {
      debugPrint('[dsh-backup] stderr：${err.trim().split('\n').take(6).join(' | ')}');
    }

    if (code != 0) {
      return BackupResult(ok: false, error: _explain(err));
    }
    // stdout 只该有一行 JSON
    final line = out
        .split('\n')
        .map((s) => s.trim())
        .firstWhere((s) => s.startsWith('{'), orElse: () => '');
    if (line.isEmpty) {
      return BackupResult(
          ok: false, error: tr('脚本没有返回结果（退出码 {0}）', <Object?>[code]));
    }
    try {
      final j = jsonDecode(line);
      if (j is! Map) {
        return BackupResult(ok: false, error: tr('脚本返回的结果看不懂'));
      }
      final ok = j['ok'] == true;
      return BackupResult(
        ok: ok,
        error: ok ? null : tr('操作失败（脚本说：{0}）', <Object?>['${j['error'] ?? '未知'}']),
        json: j.cast<String, dynamic>(),
      );
    } catch (e) {
      return BackupResult(ok: false, error: tr('脚本返回的不是合法 JSON：{0}', <Object?>['$e']));
    }
  }

  /// 把脚本的中文报错原样带出来 —— 它已经写得够清楚了，别再包一层废话。
  static String _explain(String stderr) {
    for (final line in stderr.split('\n')) {
      final t = line.trim();
      if (t.startsWith('错误：')) return t.substring(3).trim();
    }
    final t = stderr.trim();
    if (t.isEmpty) return tr('操作失败（没有更多信息）');
    return t.split('\n').first;
  }
}

/// 一次备份/还原的结果。
class BackupResult {
  const BackupResult({
    required this.ok,
    this.error,
    this.files = 0,
    this.bytes = 0,
    this.out,
    this.safetyPath,
    this.json,
  });

  final bool ok;
  final String? error;
  final int files;
  final int bytes;

  /// 打包时产出的文件路径。
  final String? out;

  /// 还原前自动留下的退路（`导入前-*.pcbak`）。
  final String? safetyPath;

  final Map<String, dynamic>? json;
}

/// 打开一个备份包看到的概况。
class BackupInspect {
  const BackupInspect({
    required this.ok,
    this.error,
    this.files = 0,
    this.totalBytes = 0,
    this.packedBytes = 0,
    this.createdAt,
  });

  final bool ok;
  final String? error;
  final int files;
  final int totalBytes;
  final int packedBytes;
  final DateTime? createdAt;
}
