import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/recent_changes.dart';
import '../../i18n/dsh_i18n.dart';
import '../theme/dsh_tokens.dart';

/// 「最近的改动」—— agent 刚把哪些文件动了。
///
/// ## 它解决的是哪一个具体场景
///
/// 会话里 agent 一口气改了十几个文件，然后说“已完成”。用户这时的问题是：
///
/// > **改了哪些？我该去哪儿看？**
///
/// 以前只能自己去工作区翻目录、按时间猜。这个页面按**修改时间**倒序列出来，
/// 一眼就能看到这段时间内发生了什么。
///
/// ## 为什么不做“看 diff”
///
/// 手机上没有 git 可执行文件，做不了真正的 diff。而要“假装”一个 diff,
/// 就得自己存历史副本 —— 那会占空间、还会把用户的工作区搞乱。
/// 所以这里只回答“哪些文件”，**点到为止**，不承诺做不到的事。
class RecentChangesPage extends StatefulWidget {
  const RecentChangesPage({super.key, required this.root});

  /// 要扫描的根目录（工作区路径）。
  final String root;

  @override
  State<RecentChangesPage> createState() => _RecentChangesPageState();
}

enum _Window { m15, h1, today }

class _RecentChangesPageState extends State<RecentChangesPage> {
  _Window _window = _Window.h1;
  bool _busy = true;
  List<RecentChange> _items = const <RecentChange>[];

  Duration get _duration => switch (_window) {
        _Window.m15 => const Duration(minutes: 15),
        _Window.h1 => const Duration(hours: 1),
        _Window.today => const Duration(hours: 24),
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    final items = await RecentChanges.scan(widget.root, window: _duration);
    if (!mounted) return;
    setState(() {
      _items = items;
      _busy = false;
    });
  }

  Future<void> _copy(RecentChange c) async {
    await Clipboard.setData(ClipboardData(text: c.absolutePath));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('已复制路径'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  DshMetrics.pagePad, DshMetrics.pagePad, DshMetrics.pagePad, 0),
              child: Row(
                children: [
                  Semantics(
                    button: true,
                    label: context.tr('返回'),
                    child: InkWell(
                      onTap: () => Navigator.of(context).maybePop(),
                      borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(2, 6, 8, 6),
                        child: Icon(Icons.arrow_back_ios_new,
                            size: 16, color: DshColors.text),
                      ),
                    ),
                  ),
                  Text(
                    context.tr('最近的改动'),
                    style: TextStyle(
                      color: DshColors.text,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: context.tr('重新扫描'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _busy ? null : _load,
                    icon: Icon(Icons.refresh,
                        size: 18, color: DshColors.textDim),
                  ),
                ],
              ),
            ),
            // 时间窗：三档足够。再多用户就要想"我该选哪个"了。
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  DshMetrics.pagePad, 6, DshMetrics.pagePad, 6),
              child: Wrap(
                spacing: 6,
                children: <Widget>[
                  for (final w in _Window.values)
                    _chip(
                      label: switch (w) {
                        _Window.m15 => context.tr('15 分钟'),
                        _Window.h1 => context.tr('1 小时'),
                        _Window.today => context.tr('今天'),
                      },
                      selected: _window == w,
                      onTap: () {
                        setState(() => _window = w);
                        _load();
                      },
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
              child: Text(
                _busy
                    ? context.tr('正在扫描…')
                    : context.tr('共 {0} 个文件（按修改时间倒序）', [_items.length]),
                style: TextStyle(color: DshColors.textDim, fontSize: 11.5),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: _busy
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : _items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(DshMetrics.pagePad),
                            child: Text(
                              context.tr('这段时间没有文件被改动'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: DshColors.textDim,
                                  fontSize: 12.5,
                                  height: 1.6),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(DshMetrics.pagePad, 4,
                              DshMetrics.pagePad, 24),
                          itemCount: _items.length,
                          itemBuilder: (_, i) => _row(_items[i]),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DshMetrics.radius(20)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? DshColors.accent.withValues(alpha: 0.16) : DshColors.surfaceHigh,
          borderRadius: BorderRadius.circular(DshMetrics.radius(20)),
          border: Border.all(
            color: selected ? DshColors.accent : DshColors.line,
            width: 0.9,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            color: selected ? DshColors.accent : DshColors.textDim,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _row(RecentChange c) {
    return InkWell(
      onTap: () => _copy(c),
      borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.insert_drive_file_outlined,
                  size: 15, color: DshColors.textFaint),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: DshColors.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500),
                  ),
                  if (c.directory.isNotEmpty)
                    Text(
                      c.directory,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DshFonts.code(
                          color: DshColors.textFaint, fontSize: 9.5),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(c.ageLabel,
                    style: TextStyle(
                        color: DshColors.textDim, fontSize: 10)),
                Text(c.sizeLabel,
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 9.5)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
