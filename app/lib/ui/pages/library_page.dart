import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// HTML 预览：官方 WebView 插件，把这个 App **私有目录里的 .html 真正当网页渲染**，
// 而不是把源码当纯文本铺出来（用户反馈 2 就是这个）。
// 为什么敢引它：`WebViewController.loadFile` 在 Android 侧会**先**
// `setAllowFileAccess(true)` 再加载（webview_flutter_android 的
// `loadFileWithParams` 里做的），否则 targetSdk 30+ 的默认值是禁止 file 访问，
// 加载会直接失败 —— 这正是"WebView 打不开本地文件"最常见的坑。
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/library_store.dart';
import '../../local/dsh_runtime.dart';
import '../../local/media_preview_server.dart';
import 'game_run_page.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';

import '../../i18n/dsh_i18n.dart';

/// 资料库（设计稿 `page-05`）。
///
/// 设计稿结构（y / 屏高，源：`pdf-images/ocr-all.txt` page-05 节）：
///   | 元素 | y | 屏高 |
///   |---|---|---|
///   | 标题 `资料库` | 199~255 | 7.5%~9.7% |
///   | 搜索框 `搜索资料库` | 394~441 | 14.9%~16.7% |
///   | Tab `最近` / `我的资料` / `团队空间` | 589~647 | 22.3%~24.5% |
///   | 首行文件（设计稿样例） | 772~893 | 29.2%~33.8% |
///
/// **本轮改动（用户原话「资料库取消团队空间，仅有最近和我的资料。
/// 里面都是DSH对话生成的各种文件」）**：
///   * Tab 从三个减到两个：`最近` / `我的资料`。
///     「团队空间」是 WorkBuddy 的**云端**能力（本地 DSH 没有账号/协同），
///     UI、代码、文案整条删除 —— 本文件里搜不到任何 `团队空间` 字样。
///   * 文件列表从"空态占位"换成**真实扫描当前工作区**（见 [LibraryScanner]）。
///   * 搜索框接真实过滤；点行可预览（文本读前 64 KB / 图片缩略图 /
///     其它类型如实提示不支持）。
///
/// **数据口径（交付里同样要写清）**：
///   * 目录：当前工作区 = `workspaces.json` 的 `current`（读不到才退到
///     `$filesDir/workspace`，即 `WorkspaceStore._defaultPath`）。
///     解析逻辑在 [resolveWorkspaceFromFilesDir]，界面上会显示这个真实路径。
///   * 范围：深度 ≤ 4 层目录、最多 500 个文件；跳过隐藏目录与
///     `node_modules` / `build` 等噪音目录（见 [kLibrarySkipDirs]）。
///   * `最近`：**全部扫到的文件按 mtime 倒序**（最新改动的在最前），
///     只列最近 [kLibraryRecentLimit]（100）个，页脚如实说明"共 N 个"。
///   * `我的资料`：**按所在目录分组**（工作区根目录那组最前，其余目录按路径
///     升序；组内按文件名升序），扫描上限内的**全量**列出。
///   * 两个 Tab 都受搜索框过滤（文件名 / 相对路径，大小写不敏感子串匹配）。
///
/// **不伪造数据**：扫不到就是 `暂无文件`；扫描出错就把错误原文显示出来，
/// 决不会退回设计稿里的示例文件名。
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    this.refreshTick = 0,
    this.onOpenWorks,
  });

  /// 底部 Tab 切到本页时的刷新计数（见 app_shell 的 `_pageTicks`）。
  final int refreshTick;

  /// 打开**作品库**（图片/视频的九宫格）。
  ///
  /// 2026-10-12 真机反馈第 4 条：用户要求「作品改到资料库就可以了」——
  /// 所以在资料库右上角给一个入口。视图本身还是创作台那一套（不复制代码），
  /// 由壳层推入 `MediaPage(initialSeg: 5)`（见 app_shell 的接线）。
  final VoidCallback? onOpenWorks;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  /// 只有两个 Tab —— 「团队空间」已按用户要求整条删除。
  List<String> get _tabs => [context.tr('最近'), context.tr('我的资料')];

  int _tab = 0;
  final _search = TextEditingController();

  LibraryScan? _result;
  bool _loading = true;
  String? _error;
  String _workspacePath = '';

  /// 工作区目录没建出来时只自动重试一次（避免无限重试）。
  bool _retriedMissingRoot = false;

  @override
  void initState() {
    super.initState();
    // 本页在 `app_shell.dart` 里是 `const LibraryPage()`，没有参数可传 ——
    // 工作区目录在这里自己解析（见 library_store.resolveWorkspaceFromFilesDir）。
    _rescan();
  }

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 每切到本页一次就重扫一次（用户要求「切换即刷新」）。
    if (oldWidget.refreshTick != widget.refreshTick) _rescan();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 重新解析工作区 + 重新扫描（右上角刷新按钮 / 下拉刷新 / 首帧都走这里）。
  Future<void> _rescan() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final paths = await DshHost.getPaths();
      final filesDir = (paths['filesDir'] as String?) ?? '';
      final resolved = resolveWorkspaceFromFilesDir(filesDir);
      // ⚠️ **同时扫 Bot 团队自己的历史工作区**（2026-10-19 用户报「Bot 生成的文件资料库看不到」）。
      //
      // ds-bot 的工作区由它自己维护：`state.json` 里一旦记了 `workspaceId`，它就**只认那个**
      // （`roster.js` 的 ensureWorkspace：`if (state.workspaceId && registry.get(...)) return ...`），
      // 完全不看我们 overlay 里配的 `config.workspace`。所以光改配置救不了**已经跑过的设备**。
      // 与其和它抢工作区，不如在资料库这边**把它的目录也一并列出来**（加 `Bot/` 前缀区分）。
      final botRoot = '$filesDir/dshhome/bot/workspace';
      final primary = await LibraryScanner.scan(resolved.path);
      final botScan = await LibraryScanner.scan(botRoot);
      final merged = <LibraryEntry>[
        ...primary.entries,
        for (final e in botScan.entries)
          LibraryEntry(
            name: e.name,
            relativePath: 'Bot/${e.relativePath}',
            absolutePath: e.absolutePath,
            size: e.size,
            modified: e.modified,
          ),
      ];
      final scan = LibraryScan(
        root: primary.root,
        rootExists: primary.rootExists,
        entries: merged,
        truncated: primary.truncated || botScan.truncated,
        dirsVisited: primary.dirsVisited + botScan.dirsVisited,
        dirsSkipped: primary.dirsSkipped + botScan.dirsSkipped,
        errors: <String>[...primary.errors, ...botScan.errors],
        elapsed: primary.elapsed + botScan.elapsed,
      );
      if (botScan.entries.isNotEmpty) {
        debugPrint('[dsh-library] 另从 Bot 工作区并入 ${botScan.entries.length} 个文件（$botRoot）');
      }
      debugPrint(
        '[dsh-library] 工作区=${resolved.path}（${resolved.source}）'
        ' 文件=${scan.total} 目录=${scan.dirsVisited} 跳过=${scan.dirsSkipped} '
        '截断=${scan.truncated} 错误=${scan.errors.length} 耗时=${scan.elapsed.inMilliseconds}ms',
      );
      for (final e in scan.errors.take(5)) {
        debugPrint('[dsh-library] 扫描错误：$e');
      }
      if (!mounted) return;
      setState(() {
        _result = scan;
        _workspacePath = resolved.path;
        // 注意：`resolved.source`（来源说明）只用于上面的日志，没有对应的 UI 字段 ——
        // 之前留过一个 `_workspaceSource` 字段但从未被读，属于死状态，已删。
        _loading = false;
      });

      // 冷启动时 `WorkspaceStore.load()` 与本页在同一帧启动，工作区目录可能
      // 还没被创建出来（它会 `createSync`）。只自动补扫一次，之后交给用户刷新。
      if (!scan.rootExists && !_retriedMissingRoot) {
        _retriedMissingRoot = true;
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if (mounted) await _rescan();
      }
    } catch (e) {
      debugPrint('[dsh-library] 扫描失败：$e');
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _open(LibraryEntry entry) {
    debugPrint('[dsh-library] 打开文件 ${entry.relativePath}（${entry.sizeLabel}）');
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => FilePreviewPage(entry: entry)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    return Column(
      children: [
        DshPageHeader(
          title: context.tr('资料库'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 「作品」入口（用户 2026-10-12 真机反馈第 4 条）：
              // 「作品我认为改到资料库就可以了，因为可以看到资料库」——
              // 所以它从创作台的入口屏挪到了这里。
              // 视图本身没搬：由壳层推入创作台那一页并让它直接落在「作品库」
              // （`MediaPage(initialSeg: 5)`），这样九宫格只有一份实现。
              if (widget.onOpenWorks != null)
                IconButton(
                  onPressed: widget.onOpenWorks,
                  tooltip: context.tr('作品（图片/视频）'),
                  icon: const Icon(Icons.grid_view_outlined, size: 20),
                ),
              IconButton(
                onPressed: _loading ? null : _rescan,
                tooltip: context.tr('重新扫描工作区'),
                icon: Icon(
                  Icons.refresh,
                  size: 20,
                  color: _loading ? DshColors.textFaint : DshColors.textDim,
                ),
              ),
            ],
          ),
        ),
        // 设计稿：标题底 255 → 搜索框顶 394，留白 139 设计像素 = 5.3% 屏高，
        // 再扣掉标题带自身的高度，落到 8dp 附近。
        SizedBox(height: screenH * 0.009),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
          child: SizedBox(
            height: 44,
            child: TextField(
              controller: _search,
              style: TextStyle(color: DshColors.text, fontSize: 13.5),
              cursorColor: DshColors.accent,
              // 真实过滤：文件名 / 相对路径，大小写不敏感（见 filterEntries）
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: context.tr('搜索资料库'),
                prefixIcon:
                    Icon(Icons.search, size: 18, color: DshColors.textFaint),
                prefixIconConstraints: const BoxConstraints(minWidth: 40),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () => setState(() => _search.clear()),
                        tooltip: context.tr('清空搜索'),
                        icon: Icon(Icons.close,
                            size: 16, color: DshColors.textFaint),
                      ),
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
          ),
        ),
        // 搜索框底 441 → Tab 带 589：148 设计像素 = 5.6% 屏高。
        // 模拟器实测 Tab 带偏高 0.2%（[511,585] vs 设计 [589,647] 的中心 618），
        // 补 6dp 后落到 617。
        SizedBox(height: screenH * 0.035 + 6),
        // Tab：设计稿是左对齐的文字项 + 选中下划线（设计稿有三个，本轮减到两个）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
          child: Row(
            children: [
              for (var i = 0; i < _tabs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 22),
                  child: Semantics(
                    button: true,
                    selected: i == _tab,
                    child: InkWell(
                      onTap: () => setState(() => _tab = i),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _tabs[i],
                            style: TextStyle(
                              fontSize: 14,
                              color: i == _tab
                                  ? DshColors.text
                                  : DshColors.textDim,
                              fontWeight:
                                  i == _tab ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Container(
                            width: 20,
                            height: 2,
                            decoration: BoxDecoration(
                              color: i == _tab
                                  ? DshColors.accent
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(DshMetrics.radius(1)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // Tab 带底 647 → 首行文件顶 772：125 设计像素 = 4.7% 屏高
        SizedBox(height: screenH * 0.047),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    final err = _error;
    if (err != null) {
      // 扫描失败 = 如实报错，**不是**空态、更不是假数据
      return DshEmptyState(
        icon: Icons.error_outline,
        centerY: 0.42,
        title: context.tr('扫描失败'),
        hint: context.tr('没能读到工作区目录里的文件。\n{0}\n\n点右上角刷新重试。', [err]),
      );
    }

    final scan = _result;
    if (scan == null) {
      // 只有"第一次还没扫完"才会走到这里；之后重新扫描时继续显示上一份
      // 真实结果（不闪成空白），右上角的刷新按钮在扫描期间是禁用的。
      return Center(
        child: CircularProgressIndicator(
            strokeWidth: 2.5, color: DshColors.accent),
      );
    }

    final filtered = filterEntries(scan.entries, _search.text);

    if (scan.entries.isEmpty) {
      return DshEmptyState(
        icon: Icons.folder_open_outlined,
        centerY: 0.42,
        title: context.tr('暂无文件'),
        hint: scan.rootExists
            ? context.tr('在工作区里生成的文件会出现在这里。\n{0}工作区：{1}', [
                scan.errors.isEmpty
                    ? ''
                    : '（有 ${scan.errors.length} 个目录没读成功，见日志）\n',
                _workspacePath
              ])
            : context.tr(
                '工作区目录还不存在：{0}\n（工作区由 App 启动时创建；点右上角刷新重试）', [_workspacePath]),
      );
    }

    if (filtered.isEmpty) {
      // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
      // ignore: prefer_const_constructors
      return DshEmptyState(
        icon: Icons.search_off,
        centerY: 0.42,
        title: context.tr('没有匹配的文件'),
        hint: context.tr('换个关键词试试（匹配文件名和相对路径，大小写不敏感）。'),
      );
    }

    final rows = _buildRows(filtered);
    return RefreshIndicator(
      color: DshColors.accent,
      backgroundColor: DshColors.surface,
      onRefresh: _rescan,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          DshMetrics.pagePad,
          0,
          DshMetrics.pagePad,
          DshMetrics.pagePad,
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final item = rows[i];
          // ⚠️ 这里**不能**假设"不是分组头就一定是 LibraryEntry"。
          // `_buildRows` 往同一个 `List<Object>` 里塞了三种东西：
          // 直接就是组件的页脚说明（`_footNote()` 返回 Padding）、分组头、文件条目。
          // 之前写成 `item as LibraryEntry`，结果是**一进资料库页就抛
          //   type 'Padding' is not a subtype of type 'LibraryEntry'
          // 并且整页空白**。静态分析抓不到（`Object` 上的显式强转是运行期的），
          // 是模拟器冒烟测出来的。所以这里按类型分流。
          if (item is _GroupHeader) return _groupHeader(item);
          if (item is LibraryEntry) {
            return _FileRow(entry: item, onTap: () => _open(item));
          }
          if (item is Widget) return item; // 页脚等直插组件
          return const SizedBox.shrink();
        },
      ),
    );
  }

  /// 把「页脚说明 + 分组头 + 文件行」摊平成一维列表，交给 `ListView.builder`
  /// 惰性构建（500 个文件时不会一次性把所有 Row 都建出来）。
  List<Object> _buildRows(List<LibraryEntry> filtered) {
    final rows = <Object>[_footNote()];
    if (_tab == 0) {
      final recent = sortByModifiedDesc(filtered);
      final shown = recent.take(kLibraryRecentLimit).toList();
      rows.addAll(shown);
      if (recent.length > shown.length) {
        rows.add(_GroupHeader(
          label: context.tr('只列了最近 {0} 个（共 {1} 个，按修改时间倒序；要看全部请用搜索或「我的资料」）',
              [shown.length, recent.length]),
          count: 0,
        ));
      }
      return rows;
    }
    for (final group in groupByDirectory(filtered)) {
      rows.add(_GroupHeader(
        label: group.dir.isEmpty ? context.tr('工作区根目录') : group.dir,
        count: group.items.length,
      ));
      rows.addAll(group.items);
    }
    return rows;
  }

  /// 页脚说明：这一条是**如实交代口径**用的 —— 扫了哪个目录、共多少、
  /// 有没有被上限截断、有没有读失败的目录。
  ///
  /// 注意：它虽然叫"页脚"，但 `_buildRows` 把它放在**列表最前面**
  /// （一进来就先交代扫描口径）。名字保留是为了不改动已有代码。
  Widget _footNote() {
    final scan = _result!;
    final parts = <String>[
      context.tr('工作区 {0} 个文件', [scan.total])
    ];
    if (scan.truncated) {
      parts.add(context.tr('已达扫描上限，仅显示前 {0} 个', [scan.entries.length]));
    }
    if (scan.dirsSkipped > 0) {
      parts.add(context.tr('跳过 {0} 个噪音目录', [scan.dirsSkipped]));
    }
    if (scan.errors.isNotEmpty) {
      parts.add(context.tr('{0} 个目录读取失败', [scan.errors.length]));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 13, color: DshColors.textFaint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _workspacePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            parts.join(' · '),
            style: TextStyle(
              color: scan.truncated ? DshColors.busy : DshColors.textFaint,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(_GroupHeader header) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Row(
        children: [
          if (header.count > 0) ...[
            Icon(Icons.folder_open, size: 14, color: DshColors.accent),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(
              header.label,
              maxLines: 2,
              style: TextStyle(
                color: header.count > 0 ? DshColors.text : DshColors.textFaint,
                fontSize: header.count > 0 ? 12.5 : 11,
                fontWeight:
                    header.count > 0 ? FontWeight.w600 : FontWeight.w400,
                height: 1.45,
              ),
            ),
          ),
          if (header.count > 0)
            Text(
              '${header.count}',
              style: TextStyle(color: DshColors.textFaint, fontSize: 11.5),
            ),
        ],
      ),
    );
  }
}

/// 列表里的分组标题（`我的资料` 按目录分组时用）。
class _GroupHeader {
  const _GroupHeader({required this.label, required this.count});

  final String label;

  /// 分组内的文件数；0 表示这是一条"说明文字"而不是真实目录分组。
  final int count;
}

/// 按扩展名区分的图标（资料库行首）。
///
/// 颜色复用 [DshFileTypeBadge.colorFor]，保证**同一扩展名在产物页与资料库
/// 是同一个颜色**，扫读时不会打架。
IconData _iconForExtension(String ext) {
  switch (ext) {
    case 'pdf':
      return Icons.picture_as_pdf_outlined;
    case 'doc':
    case 'docx':
    case 'rtf':
      return Icons.description_outlined;
    case 'xls':
    case 'xlsx':
    case 'csv':
    case 'tsv':
      return Icons.table_chart_outlined;
    case 'ppt':
    case 'pptx':
      return Icons.slideshow_outlined;
    case 'md':
    case 'markdown':
    case 'txt':
    case 'text':
    case 'log':
    case 'srt':
    case 'vtt':
      return Icons.article_outlined;
    case 'json':
    case 'jsonl':
    case 'ndjson':
    case 'yaml':
    case 'yml':
    case 'toml':
    case 'xml':
    case 'ini':
    case 'conf':
    case 'cfg':
      return Icons.data_object_outlined;
    // 网页文件单独给"浏览器"图标：点开是**渲染页面**，和 .css/.js 这类源码区分开。
    case 'html':
    case 'htm':
      return Icons.language;
    case 'css':
    case 'scss':
    case 'js':
    case 'mjs':
    case 'cjs':
    case 'ts':
    case 'tsx':
    case 'jsx':
    case 'dart':
    case 'py':
    case 'sh':
    case 'ps1':
    case 'java':
    case 'kt':
    case 'go':
    case 'rs':
    case 'rb':
    case 'php':
    case 'sql':
      return Icons.code;
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'webp':
    case 'gif':
    case 'bmp':
      return Icons.image_outlined;
    case 'zip':
    case 'gz':
    case 'tar':
    case '7z':
    case 'rar':
      return Icons.folder_zip_outlined;
    case 'mp3':
    case 'wav':
    case 'm4a':
    case 'aac':
    case 'ogg':
    case 'opus':
    case 'flac':
    case 'amr':
      return Icons.audiotrack_outlined;
    case 'mp4':
    case 'm4v':
    case 'mov':
    case 'mkv':
    case 'webm':
    case 'ogv':
    case '3gp':
      return Icons.movie_outlined;
    default:
      return Icons.insert_drive_file_outlined;
  }
}

/// 一行文件：图标 + 文件名 + 相对路径 + 体积 + 相对时间。
class _FileRow extends StatelessWidget {
  const _FileRow({required this.entry, required this.onTap});

  final LibraryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = DshFileTypeBadge.colorFor(entry.extension);
    final extLabel =
        entry.extension.isEmpty ? '?' : entry.extension.toUpperCase();
    return Semantics(
      button: true,
      label: context.tr('文件 {0} {1} {2}',
          [entry.relativePath, entry.sizeLabel, relativeTime(entry.modified)]),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: DshColors.surface,
            borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
            border: Border.all(color: DshColors.divider, width: 0.8),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                  border: Border.all(
                      color: color.withValues(alpha: 0.5), width: 0.8),
                ),
                child: Icon(_iconForExtension(entry.extension),
                    size: 17, color: color),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 13.5,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.relativePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: DshColors.textDim, fontSize: 11.5),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$extLabel · ${entry.sizeLabel} · ${relativeTime(entry.modified)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: DshColors.textFaint, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: DshColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// 文件预览页。
///
/// 四条路径，**都不伪造内容**：
///   * HTML（.html/.htm）→ App 内 WebView **渲染页面**（源码用工具栏「查看源码」切换看，
///     「浏览器打开」是保底路径）；
///   * 文本类（.md/.txt/.json/.csv/.yaml/.log 等，见 [kLibraryTextExtensions]）
///     → 读前 64 KB 原样展示，被截断/疑似二进制都如实标注；
///   * 图片类（.png/.jpg/.jpeg/.webp/.gif/.bmp）→ `Image.file` 直接显示；
///   * 其它 → 「该类型暂不支持预览」+ 文件类型 / 体积 / 路径，不做任何解码尝试，
///     但给「用其它应用打开」和「分享」两个真实入口。
/// 工作区文件的预览页。
///
/// 公开（不是下划线）是刻意的：**对话里的产物卡片也跳到这里** ——
/// 同一个文件，不管从资料库点还是从产物点，行为必须一致
/// （文本/图片在 App 内预览；其它格式给系统"打开方式"）。
class FilePreviewPage extends StatefulWidget {
  const FilePreviewPage({super.key, required this.entry});

  final LibraryEntry entry;

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  bool _loading = true;
  String? _error;
  bool _missing = false;
  LibraryPreview? _preview;

  /// HTML 用的 WebView 控制器。建不起来时为 null（原因记在 [_webError]）。
  WebViewController? _webController;
  String? _webError;

  /// 视频/音频预览用的**本机播放服务**（见 `local/media_preview_server.dart`）。
  ///
  /// 为什么不是"直接把文件交给 WebView"：`<video>` 从 `file://` 取媒体在不同
  /// WebView 版本上行为不一致，而本机没有真机可验；换成 127.0.0.1 的 http 之后
  /// 它就是一个普通资源（还能支持 Range 拖进度条），而且**单测能覆盖**。
  MediaPreviewServer? _mediaServer;
  String? _mediaError;

  /// 播放器回报的状态（来自页面里的 JS 通道 `DshPreview`）：
  /// null = 还没回执 / 'ok' = 能放 / 'error' = 这个容器 WebView 放不出来。
  String? _mediaState;

  /// 视频或音频（两者除了 `<video>`/`<audio>` 标签，其余一模一样）。
  bool get _isVideo => _entry.kind == LibraryFileKind.video;
  bool get _isAudio => _entry.kind == LibraryFileKind.audio;
  bool get _isMedia => _isVideo || _isAudio;

  /// HTML 默认**渲染页面**；「查看源码」切到纯文本预览（原来的行为保留成次要入口）。
  bool _htmlSourceMode = false;

  LibraryEntry get _entry => widget.entry;

  /// 这个文件是不是网页。
  ///
  /// 判定写在这里、**不往** `library_store.dart` 的 `LibraryFileKind` 里加枚举值：
  /// 那是资料库和产物共用的类型，动它要牵到本文件之外的代码。
  /// 注意 HTML 在 `LibraryFileKind` 里**仍然算 text** —— 源码预览正需要走那条路
  /// （`readTextPreview` 读前 64 KB）。所以这里只是"另外判一次扩展名"。
  bool get _isHtml => _entry.extension == 'html' || _entry.extension == 'htm';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // 播放服务要显式关掉：它是一个真实占着端口与连接的本机 HTTP 服务，
    // 页面销毁后不该继续活着（反复预览会积一堆端口）。
    // 不 await：dispose 是同步的，关服务在后台完成即可。
    final s = _mediaServer;
    if (s != null) unawaited(s.stop());
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final exists = await File(_entry.absolutePath).exists();
      if (!exists) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _missing = true;
        });
        return;
      }
      LibraryPreview? preview;
      if (_entry.kind == LibraryFileKind.text) {
        preview = await readTextPreview(_entry.absolutePath);
      }
      // HTML：另外准备一个 WebView 控制器。建不起来不是致命错误 ——
      // 预览页会退回「文本源码 + 浏览器打开」，并把失败原因**如实**显示出来。
      WebViewController? web;
      String? webError;
      MediaPreviewServer? media;
      String? mediaError;
      if (_isHtml) {
        try {
          final c = WebViewController();
          // 单文件 HTML 常常靠 JS 渲染内容（模板/图表），禁 JS 会发现"页面是白的"。
          // 这里加载的是用户自己产物里的本地文件，不开外网导航，风险可控。
          await c.setJavaScriptMode(JavaScriptMode.unrestricted);
          await c.setNavigationDelegate(
            NavigationDelegate(
              onWebResourceError: (WebResourceError e) {
                // 只报**主文档**的失败：同目录的图片/CSS 拉不到也会走这个回调，
                // 那属于资源缺失、不是页面打不开；拿它当"页面失败"会误导用户。
                if (e.isForMainFrame != true) return;
                debugPrint(
                    '[dsh-library] HTML 主文档加载失败：${e.errorCode} ${e.description}');
                if (!mounted) return;
                setState(() {
                  _webError = context
                      .tr('页面加载失败：{0}（错误码 {1}）', [e.description, e.errorCode]);
                });
              },
            ),
          );
          // 用 loadFile 传**绝对路径**（Android 侧会先打开 file 访问权限再加载）。
          await c.loadFile(_entry.absolutePath);
          web = c;
        } catch (e) {
          // 例如设备 WebView 被禁用 / 插件没注册。如实记下，不假装渲染成功。
          webError = '$e';
          debugPrint('[dsh-library] 建立 WebView 失败 ${_entry.relativePath}：$e');
        }
      }
      // 视频/音频：起一个**只服务这一个文件**的本机 http 服务，交给 WebView 播放。
      // 起不来不是致命错误 —— 页面会退回「用其它应用打开」并**如实**给出原因。
      if (_isMedia) {
        try {
          final s = await MediaPreviewServer.start(
            File(_entry.absolutePath),
            audio: _isAudio,
          );
          final c = WebViewController();
          await c.setJavaScriptMode(JavaScriptMode.unrestricted);
          // 播放器把"能不能放得动"回报给 App：放不出来时界面要说实话，
          // 而不是留一个黑框让用户以为卡住了。
          await c.addJavaScriptChannel(
            'DshPreview',
            onMessageReceived: (JavaScriptMessage m) {
              final msg = m.message.trim();
              debugPrint('[dsh-library] 媒体回执：$msg');
              if (!mounted) return;
              if (msg.startsWith('error')) {
                setState(() => _mediaState = 'error');
              } else if (msg.startsWith('ok')) {
                setState(() => _mediaState = 'ok');
              }
            },
          );
          await c.setNavigationDelegate(
            NavigationDelegate(
              onWebResourceError: (WebResourceError e) {
                if (e.isForMainFrame != true) return;
                if (!mounted) return;
                setState(() {
                  _mediaError =
                      context.tr('播放页加载失败：{0}', [e.description]);
                });
              },
            ),
          );
          await c.loadRequest(Uri.parse(s.url));
          if (!mounted) {
            await s.stop();
            return;
          }
          web = c;
          media = s;
        } catch (e) {
          mediaError = '$e';
          debugPrint('[dsh-library] 起播放服务/WebView 失败 ${_entry.relativePath}：$e');
        }
      }

      if (!mounted) return;
      setState(() {
        _preview = preview;
        _webController = web;
        _webError = webError;
        _mediaServer = media;
        _mediaError = mediaError;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[dsh-library] 预览失败 ${_entry.relativePath}：$e');
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 把当前 HTML 当"网页游戏"跑起来并记录（`GameRunPage`）。
  ///
  /// 只对 `.html` / `.htm` 有意义 —— 但**不做格式检查**：用户把游戏写成别的扩展名
  /// 也能进去试（进不去会如实报加载失败）。少一道自以为是的判断。
  void _openGameRun() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GameRunPage(
          htmlPath: _entry.absolutePath,
          fileName: _entry.name,
        ),
      ),
    );
  }

  /// 用系统的"打开方式"打开这个文件（App 内预览不了的格式走这条路）。
  ///
  /// 原生侧约定：返回 `'no_app'` 表示系统里没有能打开它的应用 ——
  /// 那是环境事实，要**如实告诉用户**并给出文件位置，不能假装打开了。
  Future<void> _openExternally() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await DshHost.openFile(_entry.absolutePath);
      debugPrint('[dsh-library] 外部打开 ${_entry.relativePath} -> $r');
      if (r == 'no_app') {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('系统里没有能打开这种文件的应用'))),
        );
      }
    } catch (e) {
      // 失败也要留一行（理由同 [_share]）：SnackBar 一关掉就没证据了。
      debugPrint('[dsh-library] 外部打开失败 ${_entry.relativePath}：$e');
      messenger.showSnackBar(SnackBar(content: Text(tr('打开失败：{0}', [e]))));
    }
  }

  /// 分享这个文件（系统分享面板，原生 ACTION_SEND + FileProvider）。
  ///
  /// 与 [_openExternally] 同一套约定：`'no_app'` 表示系统里**没有任何**能接收分享的
  /// 应用 —— 那是环境事实，要如实告诉用户，不能假装分享出去了。
  /// 分享面板是系统弹的，我们只知道"拉起来了"，最终用户选了谁不归我们管，
  /// 所以成功路径**不弹**任何提示（避免"已分享给 XX"这种没有依据的话）。
  Future<void> _share() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r =
          await DshHost.shareFile(_entry.absolutePath, subject: _entry.name);
      debugPrint('[dsh-library] 分享 ${_entry.relativePath} -> $r');
      if (r == 'no_app') {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('这台设备没有能接收分享的应用'))),
        );
      }
    } on PlatformException catch (e) {
      // 原生侧的 message 已是中文（缺参数 / 文件不存在 / 分享失败）。
      // ⚠️ **失败也必须留一行日志**。以前这里只弹 SnackBar、什么都不记，
      // 于是"用户点了分享、报错一闪而过"在诊断报告里**一个字都没有**，
      // 报告只会写"错误 0 条"，排查全靠猜（真踩过：2026-10-12 用户说
      // "刚做了一个游戏分享不出去，不知道你有没有看到日志"）。
      debugPrint('[dsh-library] 分享失败 ${_entry.relativePath}'
          '（${e.code}）：${e.message}');
      messenger.showSnackBar(
        SnackBar(content: Text(tr('分享失败：{0}', [e.message ?? e.code]))),
      );
    } catch (e) {
      debugPrint('[dsh-library] 分享异常 ${_entry.relativePath}：$e');
      messenger.showSnackBar(SnackBar(content: Text(tr('分享失败：{0}', [e]))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(_entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.transparent,
        actions: [
          // 「分享」放在 AppBar 上：**任何类型**的文件都该能分享出去
          // （原来只能"打开"，用户反馈 1 就是产物没法发出去）。
          IconButton(
            onPressed: _share,
            tooltip: context.tr('分享'),
            icon: const Icon(Icons.ios_share, size: 20),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
            strokeWidth: 2.5, color: DshColors.accent),
      );
    }
    if (_missing) {
      return DshEmptyState(
        icon: Icons.report_gmailerrorred_outlined,
        centerY: 0.42,
        title: context.tr('文件已不存在'),
        hint: context.tr('扫描之后这个文件被移动或删除了。\n{0}', [_entry.absolutePath]),
      );
    }
    final err = _error;
    if (err != null) {
      return DshEmptyState(
        icon: Icons.error_outline,
        centerY: 0.42,
        title: context.tr('读取失败'),
        hint: err,
      );
    }

    // HTML 单独走一条路径（在 switch 之前分流）：渲染页面为主、源码为辅。
    // 为什么不能只靠 `LibraryFileKind`：HTML 在那张表里算 text
    // （源码预览需要它），"要渲染成网页"是本页额外需要知道的事。
    if (_isHtml) return _buildHtmlPreview();

    // 视频/音频也单独走一条（和 HTML 一样：它们要的是"渲染/播放"，不是读字节）。
    if (_isMedia) return _buildMediaPreview();

    switch (_entry.kind) {
      case LibraryFileKind.text:
        return _buildTextPreview();
      case LibraryFileKind.image:
        return _buildImagePreview();
      case LibraryFileKind.video:
      case LibraryFileKind.audio:
        // 上面已经分流了，这里只是让 switch 保持穷尽（加新类型时编译器会提醒）。
        return _buildMediaPreview();
      case LibraryFileKind.other:
        // App 内预览不了 → 交给系统里能打开它的应用（原生 ACTION_VIEW）。
        // 用户反馈「产物无法点击」的一部分就是这里：以前只显示一句
        // "该类型暂不支持预览"，没有任何打开入口。
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(DshMetrics.pagePad),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.description_outlined,
                    size: 34, color: DshColors.textFaint),
                const SizedBox(height: 12),
                Text(
                  context.tr('这个格式 App 内不能预览'),
                  style: TextStyle(color: DshColors.text, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Text(
                  context.tr('{0} 类型（{1}）\n交给系统里能打开它的应用试试：', [
                    _entry.extension.isEmpty ? '无扩展名' : '.${_entry.extension}',
                    _entry.sizeLabel
                  ]),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: DshColors.textDim, fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _openExternally,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(context.tr('用其它应用打开')),
                ),
                const SizedBox(height: 10),
                // 这个格式 App 内预览不了，但**照样要能分享出去**（比如 .zip / .docx）。
                OutlinedButton.icon(
                  onPressed: _share,
                  icon: const Icon(Icons.ios_share, size: 16),
                  label: Text(context.tr('分享')),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  _entry.absolutePath,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
                ),
              ],
            ),
          ),
        );
    }
  }

  /// HTML 预览：**App 内 WebView 渲染页面**，另给「查看源码」和「浏览器打开」两个入口。
  ///
  /// 已知限制（**实测待确认，代码里先写清**）：
  ///   * 单文件自包含的 HTML（样式/脚本都内联）能正常渲染，这是主目标；
  ///   * 同目录的相对资源（`./img/a.png`、`style.css`）走 `file://` 相对路径，
  ///     Android WebView 对它的放行程度跟 ROM/WebView 版本有关，**不保证**能加载出来。
  ///     真要 100% 保真，用工具栏上的「浏览器打开」丢给 Chrome —— 那条路一定正常。
  ///   * WebView 建不起来（设备禁用/插件缺失）时不显示空白页：退回源码预览，
  ///     并在顶部把失败原因原文显示出来。
  Widget _buildHtmlPreview() {
    final web = _webController;
    final webError = _webError;
    // 源码模式、或 WebView 没建起来：都退回文本预览（源码仍然看得到）。
    if (_htmlSourceMode || web == null) {
      return Column(
        children: [
          _htmlToolbar(),
          Divider(height: 1, color: DshColors.divider),
          if (webError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(
                DshMetrics.pagePad,
                8,
                DshMetrics.pagePad,
                8,
              ),
              color: DshColors.busy.withValues(alpha: 0.12),
              child: Text(
                context.tr('App 内没能渲染这个网页，原因：{0}\n下面是源码；要按网页看，请用右上角「浏览器打开」。',
                    [webError]),
                style: TextStyle(
                    color: DshColors.textDim, fontSize: 11, height: 1.5),
              ),
            ),
          Expanded(child: _buildTextPreview()),
        ],
      );
    }
    return Column(
      children: [
        _htmlToolbar(),
        Divider(height: 1, color: DshColors.divider),
        Expanded(child: WebViewWidget(controller: web)),
      ],
    );
  }

  /// 视频/音频预览：App 内播放 + 如实的边界说明。
  ///
  /// 三条路都有出口，**都不假装**：
  ///   * 服务/WebView 起不来 → 说清原因 + 「用其它应用打开」/「分享」；
  ///   * 起得来但播放器回执 `error`（容器/编码不被 WebView 支持，例如部分 .mkv）
  ///     → 明确说"App 内放不出来"并给外部打开入口，**不留一个黑框**；
  ///   * 能放 → 正常播，底部保留外部打开/分享（用户可能仍想投屏或换播放器）。
  Widget _buildMediaPreview() {
    // 扩展名的显示文本（空扩展名如实说，别显示一个空的「.」）。
    final ext = _entry.extension.isEmpty
        ? context.tr('无扩展名')
        : '.${_entry.extension}';
    final web = _webController;
    final server = _mediaServer;
    final err = _mediaError;
    final failed = _mediaState == 'error';

    if (web == null || server == null) {
      return _mediaFallback(
        title: context.tr('App 内没法播放这个文件'),
        detail: err ??
            context.tr('本机播放服务或 WebView 没建起来（原因见运行日志）。'),
      );
    }
    if (failed) {
      return _mediaFallback(
        title: context.tr('这个文件 App 内放不出来'),
        detail: context.tr('WebView 不支持它的容器或编码（比如部分 .mkv / .avi）。'
            '文件本身没问题 —— 用系统里能放它的应用打开即可。'),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ColoredBox(
            // 视频预览用纯黑底：画面以外的东西都是干扰。
            color: Colors.black,
            child: WebViewWidget(controller: web),
          ),
        ),
        Divider(height: 1, color: DshColors.divider),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              DshMetrics.pagePad, 6, DshMetrics.pagePad, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    // ⚠️ **不要**写成 `context.tr(条件 ? 'A' : 'B')`：扫描器只认
                    //     `tr('字面量')`，三元里的字面量它**看不见** —— 切英/日/韩会
                    //     静默露中文，而 check-tables 仍报 0 漂移。
                    child: Text(
                      _isAudio
                          ? context.tr('App 内播放：音频（{0}）', [ext])
                          : context.tr('App 内播放：可拖进度条（{0}）', [ext]),
                      style: TextStyle(
                          color: DshColors.textDim, fontSize: 11, height: 1.4),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _openExternally,
                    icon: const Icon(Icons.open_in_new, size: 15),
                    label: Text(context.tr('用其它应用打开'),
                        style: const TextStyle(fontSize: 12)),
                  ),
                  TextButton.icon(
                    onPressed: _share,
                    icon: const Icon(Icons.ios_share, size: 15),
                    label: Text(context.tr('分享'),
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              Text(
                // 如实写明：能不能放取决于 WebView，不是我们"保证支持"。
                context.tr('能不能放取决于手机上的 WebView 解码器；'
                    '放不出来时会在这里说明，并可以改用其它应用打开。'),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 10.5, height: 1.4),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 播放不了时的统一出口（两种原因共用一套观感与两个真实入口）。
  Widget _mediaFallback({required String title, required String detail}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(DshMetrics.pagePad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_isAudio ? Icons.music_off_outlined : Icons.videocam_off_outlined,
                size: 34, color: DshColors.textFaint),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(color: DshColors.text, fontSize: 14)),
            const SizedBox(height: 8),
            Text(detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: DshColors.textDim, fontSize: 12, height: 1.6)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openExternally,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(context.tr('用其它应用打开')),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _share,
              icon: const Icon(Icons.ios_share, size: 16),
              label: Text(context.tr('分享')),
            ),
            const SizedBox(height: 12),
            SelectableText(
              _entry.absolutePath,
              textAlign: TextAlign.center,
              style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }

  /// HTML 预览的工具条：状态说明 + 「预览页面/查看源码」切换 + 「浏览器打开」。
  Widget _htmlToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          DshMetrics.pagePad, 2, DshMetrics.pagePad, 2),
      child: Row(
        children: [
          Icon(
            _htmlSourceMode ? Icons.code : Icons.language,
            size: 13,
            color: DshColors.textFaint,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _htmlSourceMode
                  ? context.tr('源码模式 · {0}', [_entry.sizeLabel])
                  : context.tr('App 内网页预览 · {0}', [_entry.sizeLabel]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: DshColors.textFaint, fontSize: 11),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _htmlSourceMode = !_htmlSourceMode),
            child:
                Text(_htmlSourceMode ? context.tr('预览页面') : context.tr('查看源码')),
          ),
          // 2026-10-12（A2）：**运行记录** —— 把 .html 当"网页游戏"跑起来，
          // 并按 game-qa 的口径让用户逐项确认、落成一份 Markdown 交给模型。
          // 为什么单独一页（而不是工具栏里弹个框）：它要**占满屏幕**给你玩
          // （游戏画面 + 下方的记录面板），弹框会把它挤成一条缝。
          TextButton(
            onPressed: _openGameRun,
            child: Text(context.tr('运行记录')),
          ),
          // 保底路径：系统浏览器（Chrome）渲染网页一定能滚动、一定保真。
          TextButton(
              onPressed: _openExternally, child: Text(context.tr('浏览器打开'))),
        ],
      ),
    );
  }

  Widget _buildTextPreview() {
    final preview = _preview;
    if (preview == null) {
      // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
      // ignore: prefer_const_constructors
      return DshEmptyState(
        icon: Icons.text_snippet_outlined,
        centerY: 0.42,
        title: context.tr('没有读到内容'),
        hint: context.tr('文件是空的，或者这次读取没有返回字节。'),
      );
    }
    if (preview.looksBinary) {
      return DshEmptyState(
        icon: Icons.warning_amber_outlined,
        centerY: 0.42,
        title: context.tr('这个文件看起来是二进制'),
        hint: context.tr(
            '扩展名是 .{0}，但内容里有 NUL 字节 —— 按文本渲染会是乱码，所以这里如实告诉你而不是硬渲染。\n（{1}）\n\n{2}',
            [_entry.extension, _entry.sizeLabel, _entry.absolutePath]),
      );
    }
    final note = preview.truncated
        ? context.tr('仅预览前 {0}（全文 {1}）',
            [humanSize(kLibraryPreviewMaxBytes), humanSize(preview.totalBytes)])
        : context.tr('全文 {0}', [humanSize(preview.totalBytes)]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              DshMetrics.pagePad, 8, DshMetrics.pagePad, 8),
          child: Row(
            children: [
              Icon(
                preview.truncated
                    ? Icons.content_cut
                    : Icons.check_circle_outline,
                size: 13,
                color: preview.truncated ? DshColors.busy : DshColors.ok,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  note,
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: DshColors.divider),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(DshMetrics.pagePad),
            child: SelectableText(
              preview.text,
              style: TextStyle(
                color: DshColors.text,
                fontSize: 12,
                height: 1.5,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImagePreview() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              DshMetrics.pagePad, 8, DshMetrics.pagePad, 8),
          child: Text(
            '${_entry.sizeLabel} · ${relativeTime(_entry.modified)}',
            style: TextStyle(color: DshColors.textFaint, fontSize: 11),
          ),
        ),
        Expanded(
          child: InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: Image.file(
                File(_entry.absolutePath),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    context.tr('这张图打不开（Flutter 解码失败）：{0}\n\n{1}',
                        [error, _entry.absolutePath]),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: DshColors.textDim, fontSize: 12.5, height: 1.5),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
