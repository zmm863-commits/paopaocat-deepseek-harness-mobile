import 'dart:io';

/// 「最近改动了哪些文件」—— 纯本地扫描，不依赖 git。
///
/// ## 为什么不用 git
///
/// 手机上没有 git 可执行文件（我们的运行时只带 node），而重新实现一遍
/// `.git/index` 解析得不偿失。而用户真正想知道的是那句：
///
/// > **“agent 刚才把哪些文件动了？”**
///
/// 这个问题的答案**用文件修改时间就能回答**，比 git 还直接 —— git 只告诉你
/// “相对上次提交变了什么”，而用户此刻关心的是“刚刚这几分钟”。
///
/// ## 一个必须守住的边界
///
/// 扫描要**便宜**：跳过 `.git` / `node_modules` / `build` 这类目录，
/// 限制深度与条数。宁可少列几个文件，也不能让打开面板卡三秒 ——
/// 那比"看不到"更让人以为 App 死了。
class RecentChanges {
  RecentChanges._();

  /// 一律跳过的目录名（体积大、且改了也不是用户关心的"产出"）。
  static const Set<String> skipDirs = <String>{
    '.git',
    'node_modules',
    'build',
    '.dart_tool',
    '.gradle',
    '__pycache__',
    '.idea',
    '.vscode',
    'dist',
  };

  /// 扫描 [root] 下 [window] 内被修改过的文件，按时间倒序。
  ///
  /// [limit] 是硬上限：目录再大也只走这么多条目就停（防卡死）。
  static Future<List<RecentChange>> scan(
    String root, {
    Duration window = const Duration(minutes: 30),
    int limit = 4000,
    int maxDepth = 8,
  }) async {
    final dir = Directory(root);
    if (!dir.existsSync()) return const <RecentChange>[];

    final cutoff = DateTime.now().subtract(window);
    final out = <RecentChange>[];
    var visited = 0;

    try {
      final stream = dir.list(recursive: true, followLinks: false);
      await for (final entity in stream) {
        if (++visited > limit) break;
        if (entity is! File) continue;

        final p = entity.path;
        // 路径里只要有一段命中跳过名单，就整条不看了。
        final rel = p.startsWith(root) ? p.substring(root.length) : p;
        final segs = rel.split(Platform.pathSeparator);
        if (segs.any(skipDirs.contains)) continue;
        // 深度限制：`a/b/c/d/e/f/g/h` 已经很深，再深多半是缓存。
        if (segs.length > maxDepth) continue;
        // 隐藏文件多半是工具的临时产物（.DS_Store 之类），列出来只是噪音。
        final base = segs.isEmpty ? '' : segs.last;
        if (base.startsWith('.')) continue;

        final FileStat st;
        try {
          st = entity.statSync();
        } catch (_) {
          continue; // 扫的过程中被删了：跳过，不要因为一个文件让整次扫描失败
        }
        if (st.modified.isBefore(cutoff)) continue;
        if (st.size == 0) continue; // 空文件通常是原子写入的中间态

        out.add(RecentChange(
          absolutePath: p,
          // 存成不带前导分隔符的相对路径：界面上更好看，也便于复制
          relativePath: rel.startsWith(Platform.pathSeparator)
              ? rel.substring(1)
              : rel,
          modifiedAt: st.modified,
          bytes: st.size,
        ));
      }
    } catch (_) {
      // 权限不足 / 目录被移走：返回已经扫到的部分，**不要整块失败**
    }

    out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return out;
  }
}

/// 一个被改动的文件。
class RecentChange {
  const RecentChange({
    required this.absolutePath,
    required this.relativePath,
    required this.modifiedAt,
    required this.bytes,
  });

  final String absolutePath;

  /// 相对 workspace 根目录的路径（不含前导分隔符）。
  final String relativePath;

  final DateTime modifiedAt;

  final int bytes;

  /// 文件名（列表第一行）。
  String get name {
    final i = relativePath.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? relativePath : relativePath.substring(i + 1);
  }

  /// 所在目录（列表第二行；根目录下的文件为空串）。
  String get directory {
    final i = relativePath.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? '' : relativePath.substring(0, i);
  }

  /// 「12 秒前 / 3 分钟前」——复用全局的相对时间标签。
  String get ageLabel => _agoLabel(DateTime.now().difference(modifiedAt));

  /// 人类可读大小（1.2 KB / 3.4 MB）。
  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _agoLabel(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} 秒前';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}
