import 'package:flutter/material.dart';

import '../../data/schedule_store.dart';
import '../../local/dsh_runtime.dart';
import '../../local/schedule_runner.dart';
import '../../local/system_calendar.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/common.dart';

import '../../i18n/dsh_i18n.dart';

/// 定时任务（设计稿 `page-06`）。
///
/// 设计稿这一页只有标题 `定时任务` + 空态 `暂无定时任务`（而且**没有**「新建」
/// 按钮）。本轮按用户要求把它做成真的能用：
/// 「定时任务主要就是用户定制各种任务的执行时间，后台运行。」
///
/// 能力边界（界面上也如实写着，不糊弄）：
///   * 到点执行 = 复用 `DshRuntime.headless()`，和手打消息走同一条通道；
///   * 「后台运行」= 原生前台服务把进程留住（常驻通知）。**App 被系统回收后
///     不会触发任何东西** —— 本机没有系统级闹钟；
///   * App 没运行时错过的计划，恢复后**记为「已错过」**，不假装跑过。
class ScheduledPage extends StatefulWidget {
  const ScheduledPage({
    super.key,
    required this.store,
    required this.runner,
    this.refreshTick = 0,
  });

  final ScheduleStore store;
  final ScheduleRunner runner;

  /// 底部 Tab 切到本页时的刷新计数（见 app_shell 的 `_pageTicks`）。
  final int refreshTick;

  @override
  State<ScheduledPage> createState() => _ScheduledPageState();
}

class _ScheduledPageState extends State<ScheduledPage> {
  bool _historyOpen = false;

  /// 系统日历的能力现状（null = 还没查）。
  CalendarStatus? _calendarStatus;

  /// 正在申请权限 / 切开关：防止连点。
  bool _calendarBusy = false;

  ScheduleStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _reloadCalendarStatus();
  }

  @override
  void didUpdateWidget(covariant ScheduledPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 每切到本页一次就重读一次（用户要求「切换即刷新」）：
    // 后台服务跑完的任务、运行历史都要能立刻反映出来。
    //
    // ⚠️ 必须推迟到 build 结束后（2026-11-01 真机日志：
    // `setState() called during build`）—— `ScheduleStore.load()` 虽然标了
    // async，但函数体里没有 await，Dart 会**同步**跑完整个函数再返回；
    // 于是它在 build 阶段就 notifyListeners()，AppShell 的 _onSchedulesChanged
    // 监听器里 setState() → build 中途改树 → 异常。
    if (oldWidget.refreshTick != widget.refreshTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _store.load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable?>[
        _store,
        widget.runner.runningTask,
      ]),
      builder: (context, _) {
        final list = _store.schedules;
        final running = widget.runner.runningTask.value;
        return Column(
          children: [
            DshPageHeader(
              title: context.tr('定时任务'),
              trailing: Semantics(
                button: true,
                label: context.tr('新建定时任务'),
                child: IconButton(
                  tooltip: context.tr('新建定时任务'),
                  icon: Icon(Icons.add, size: 20, color: DshColors.textDim),
                  onPressed: () => _openEditor(null),
                ),
              ),
            ),
            if (!_store.loaded)
              const Expanded(
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (list.isEmpty)
              Expanded(
                child: DshEmptyState(
                  icon: Icons.schedule_outlined,
                  title: context.tr('暂无定时任务'),
                  hint: context.tr('点右上角 + 新建：设定时间后，到点会自动跑一次对话任务。'),
                  centerY: 0.62,
                ),
              )
            else
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    DshMetrics.pagePad,
                    4,
                    DshMetrics.pagePad,
                    24,
                  ),
                  children: [
                    if (running != null) _runningBanner(running),
                    if (_store.error != null) _errorBanner(_store.error!),
                    if (_store.enabledCount > 0) _backgroundNote(),
                    _calendarSection(),
                    for (final s in list) _card(s),
                    const SizedBox(height: 8),
                    _historySection(),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  // --------------------------------------------------------------- 顶部提示

  /// 「同步到系统日历」那块。
  ///
  /// 为什么要它：App 内的调度器是**进程内**的（`schedule_runner.dart`）——
  /// 进程被系统回收，任务就不跑。写进系统日历之后，到点由**系统日历自己**响，
  /// 不依赖这个 App 还开着（对标同类产品的 `WRITE_CALENDAR` + `device_alarm`）。
  ///
  /// 状态一律**如实**说：没授权 / 设备上没有可写的日历 / 已同步几个，
  /// 都不写成"已同步成功"。
  Widget _calendarSection() {
    final on = _store.calendarSync;
    final status = _calendarStatus;
    final synced = _store.schedules
        .where((s) => s.calendarEventId != null)
        .length;
    final String hint;
    if (!on) {
      hint = context.tr(
          '关着：任务只在这个 App 里跑，App 不在就不会触发。打开后任务会出现在系统日历里，到点由系统提醒。');
    } else if (status == null) {
      hint = context.tr('正在检查这台设备的日历能力…');
    } else if (!status.canWrite) {
      hint = context.tr(
          '还没给日历权限：授权后任务才会写进系统日历（系统会弹窗问你）。');
    } else if (!status.hasWritableCalendar) {
      hint = context.tr(
          '这台设备没有可写的日历（很多裸机没有系统日历账号），所以同步不了 —— 任务仍然只在这个 App 里跑。');
    } else {
      hint = context.tr(
          '已把 {0} 个任务写进系统日历：到点由系统提醒，不依赖这个 App 开着。',
          [synced]);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(DshMetrics.cardPad),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_outlined, size: 15, color: DshColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.tr('同步到系统日历'),
                  style: TextStyle(
                    color: DshColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Switch(
                value: on,
                onChanged: _toggleCalendarSync,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: TextStyle(color: DshColors.textDim, fontSize: 11.5, height: 1.5),
          ),
          if (on && status != null && !status.canWrite) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _calendarBusy ? null : _requestCalendarPermission,
              child: Text(context.tr('申请日历权限')),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _toggleCalendarSync(bool on) async {
    if (_calendarBusy) return;
    setState(() => _calendarBusy = true);
    try {
      if (on) {
        // 先把权限要到手：没有权限就是"没同步"，不能开着开关假装同步了。
        final st = await SystemCalendar.status();
        if (!st.canWrite) {
          await _requestCalendarPermission();
        }
      }
      await _store.setCalendarSync(on);
      await _reloadCalendarStatus();
    } finally {
      if (mounted) setState(() => _calendarBusy = false);
    }
  }

  Future<void> _requestCalendarPermission() async {
    if (_calendarBusy) return;
    setState(() => _calendarBusy = true);
    try {
      await DshHost.requestPermissions(<String>['calendar']);
      await _reloadCalendarStatus();
    } catch (e) {
      debugPrint('[dsh-calendar] 申请日历权限失败: $e');
    } finally {
      if (mounted) setState(() => _calendarBusy = false);
    }
  }

  Future<void> _reloadCalendarStatus() async {
    final st = await SystemCalendar.status();
    if (!mounted) return;
    setState(() => _calendarStatus = st);
  }

  Widget _runningBanner(String name) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: DshColors.accentDim,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.accent, width: 0.8),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: DshColors.accent),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                context.tr('正在执行：{0}', [name]),
                style: TextStyle(color: DshColors.accent, fontSize: 12.5),
              ),
            ),
          ],
        ),
      );

  Widget _errorBanner(String message) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: DshColors.err.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(
              color: DshColors.err.withValues(alpha: 0.5), width: 0.8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 15, color: DshColors.err),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                    color: DshColors.err, fontSize: 11.5, height: 1.45),
              ),
            ),
          ],
        ),
      );

  /// 后台运行的**如实**说明（有已启用任务时才显示）。
  Widget _backgroundNote() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: DshColors.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.divider, width: 0.8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 14, color: DshColors.textFaint),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                context.tr(
                    '后台运行依赖一个常驻通知把 App 留在后台。部分手机（尤其是国产 ROM 的省电策略）仍会杀掉进程，建议到系统设置里关闭本 App 的电池优化。App 被彻底杀掉期间不会触发，恢复后会把错过的记录标成「已错过」。'),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.55),
              ),
            ),
          ],
        ),
      );

  // --------------------------------------------------------------- 任务卡片

  Widget _card(Schedule s) {
    final now = DateTime.now();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(DshMetrics.cardPad),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _openEditor(s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: DshColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        s.ruleLabel,
                        style:
                            TextStyle(color: DshColors.accent, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ),
              Switch(
                value: s.enabled,
                onChanged: (v) => _store.setEnabled(s, v),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            s.prompt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: DshColors.textDim, fontSize: 11.5, height: 1.45),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                s.enabled ? Icons.schedule : Icons.pause_circle_outline,
                size: 13,
                color: DshColors.textFaint,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  s.enabled
                      ? context.tr('下次：{0}',
                          [ScheduleStore.humanize(s.nextRunAt, now: now)])
                      : context.tr('已停用'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                ),
              ),
              _statusChip(s),
            ],
          ),
          Divider(height: 18, thickness: 0.6, color: DshColors.divider),
          Row(
            children: [
              _miniAction(
                icon: Icons.play_arrow_outlined,
                label: context.tr('立即运行一次'),
                onTap: () => _runNow(s),
              ),
              const Spacer(),
              _miniAction(
                icon: Icons.edit_outlined,
                label: context.tr('编辑'),
                onTap: () => _openEditor(s),
              ),
              _miniAction(
                icon: Icons.delete_outline,
                label: context.tr('删除'),
                danger: true,
                onTap: () => _confirmDelete(s),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusChip(Schedule s) {
    if (s.lastSummary == null) return const SizedBox.shrink();
    final missed = s.lastOk == null;
    final ok = s.lastOk == true;
    final color = missed
        ? DshColors.busy
        : ok
            ? DshColors.ok
            : DshColors.err;
    final text = missed
        ? context.tr('已错过')
        : ok
            ? context.tr('成功')
            : context.tr('失败');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.7),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 10.5)),
    );
  }

  Widget _miniAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? DshColors.err : DshColors.textDim;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: color, fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------- 运行历史

  Widget _historySection() {
    final runs = _store.runs;
    return Container(
      padding: const EdgeInsets.all(DshMetrics.cardPad),
      decoration: BoxDecoration(
        color: DshColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(DshMetrics.cardRadius),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: context.tr('运行历史'),
            child: InkWell(
              onTap: () => setState(() => _historyOpen = !_historyOpen),
              child: Row(
                children: [
                  Text(
                    context.tr('运行历史'),
                    style: TextStyle(
                      color: DshColors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.tr('{0} 条', [runs.length]),
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                  ),
                  const Spacer(),
                  Icon(
                    _historyOpen ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: DshColors.textDim,
                  ),
                ],
              ),
            ),
          ),
          if (_historyOpen) ...[
            const SizedBox(height: 8),
            if (runs.isEmpty)
              Text(
                context.tr('还没有执行记录。'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11.5),
              )
            else
              for (final r in runs.take(10))
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        r.missed
                            ? Icons.error_outline
                            : r.ok
                                ? Icons.check_circle_outline
                                : Icons.cancel_outlined,
                        size: 13,
                        color: r.missed
                            ? DshColors.busy
                            : r.ok
                                ? DshColors.ok
                                : DshColors.err,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_stamp(r.at)}  ${r.taskName}',
                              style: TextStyle(
                                  color: DshColors.textDim, fontSize: 11),
                            ),
                            Text(
                              r.summary,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: DshColors.textFaint,
                                fontSize: 10.5,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  }

  // --------------------------------------------------------------- 交互动作

  Future<void> _runNow(Schedule s) async {
    final navigator = ScaffoldMessenger.of(context);
    navigator.showSnackBar(
      SnackBar(
          content: Text(context.tr('正在执行「{0}」…（一次真实模型调用，可能要几十秒）', [s.name]))),
    );
    final outcome = await widget.runner.runNow(s);
    if (!mounted) return;
    navigator.showSnackBar(SnackBar(content: Text(outcome)));
  }

  Future<void> _confirmDelete(Schedule s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DshColors.surfaceStrong,
        title: Text(context.tr('删除定时任务'), style: const TextStyle(fontSize: 16)),
        content: Text(context.tr('确定删除「{0}」？', [s.name]),
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.tr('取消'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DshColors.err),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('删除')),
          ),
        ],
      ),
    );
    if (ok == true) await _store.remove(s.id);
  }

  Future<void> _openEditor(Schedule? existing) async {
    final result = await showModalBottomSheet<Schedule>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ScheduleEditor(initial: existing),
    );
    if (result == null) return;
    if (existing == null) {
      await _store.add(result);
    } else {
      await _store.update(result);
    }
  }
}

/// 新建 / 编辑弹层。控制器生命周期跟这个 widget 走（上一轮踩过
/// "控制器被调用方提前 dispose" 的坑）。
class _ScheduleEditor extends StatefulWidget {
  const _ScheduleEditor({this.initial});

  final Schedule? initial;

  @override
  State<_ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<_ScheduleEditor> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late ScheduleRepeat _repeat;
  late TimeOfDay _time;
  late Set<int> _weekdays;

  String? _error;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _name = TextEditingController(text: s?.name ?? '');
    _prompt = TextEditingController(text: s?.prompt ?? '');
    _repeat = s?.repeat ?? ScheduleRepeat.daily;
    _time = TimeOfDay(hour: s?.hour ?? 8, minute: s?.minute ?? 0);
    _weekdays = <int>{
      ...(s?.weekdays ?? const <int>[1])
    };
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Container(
      decoration: BoxDecoration(
        // ⚠️ 这里原来是 `Colors.transparent`，而外层 showModalBottomSheet 也传了
        //    transparent → **弹层完全没有底色**，页面的字直接从底下透上来
        //    （用户 2026-10-12 第 4 条）。弹层是盖在内容上的板子，必须不透明。
        color: DshColors.surfaceStrong,
        borderRadius: BorderRadius.vertical(top: Radius.circular(DshMetrics.radius(18))),
      ),
      padding: EdgeInsets.fromLTRB(16, 14, 16, 16 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.initial == null
                  ? context.tr('新建定时任务')
                  : context.tr('编辑定时任务'),
              style: TextStyle(
                color: DshColors.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: context.tr('任务名'),
                hintText: context.tr('例如：每天早上写一份日报'),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _prompt,
              maxLines: 4,
              minLines: 3,
              decoration: InputDecoration(
                labelText: context.tr('要执行什么（会作为一条消息发给模型）'),
                hintText: context.tr('例如：帮我总结昨天的 git 提交，写一份 200 字日报'),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            // 泡泡猫快捷任务：后台操作 App / 跑规则 / 录规则，点一下填好 prompt。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _fillChip(context, '泡泡猫后台操作',
                    '泡泡猫帮我打开 XX 并操作'),
                _fillChip(context, '泡泡猫执行规则', '泡泡猫执行 XX 规则'),
                _fillChip(context, '泡泡猫录规则', '泡泡猫帮我录一条 XX 的规则'),
              ],
            ),
            const SizedBox(height: 16),
            Text(context.tr('重复'),
                style: TextStyle(color: DshColors.textDim, fontSize: 12.5)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in ScheduleRepeat.values)
                  _chip(
                    label: r.label,
                    selected: _repeat == r,
                    onTap: () => setState(() => _repeat = r),
                  ),
              ],
            ),
            if (_repeat == ScheduleRepeat.weekly) ...[
              const SizedBox(height: 14),
              Text(context.tr('星期几'),
                  style: TextStyle(color: DshColors.textDim, fontSize: 12.5)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var d = 1; d <= 7; d++)
                    _chip(
                      label: <int, String>{
                        1: context.tr('一'),
                        2: context.tr('二'),
                        3: context.tr('三'),
                        4: context.tr('四'),
                        5: context.tr('五'),
                        6: context.tr('六'),
                        7: context.tr('日'),
                      }[d]!,
                      selected: _weekdays.contains(d),
                      onTap: () => setState(() {
                        if (_weekdays.contains(d)) {
                          if (_weekdays.length > 1) _weekdays.remove(d);
                        } else {
                          _weekdays.add(d);
                        }
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Text(context.tr('时间'),
                    style: TextStyle(color: DshColors.textDim, fontSize: 12.5)),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.access_time, size: 16),
                  label: Text(_time.format(context)),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: TextStyle(color: DshColors.err, fontSize: 12)),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(context.tr('取消')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                      onPressed: _submit, child: Text(context.tr('保存'))),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    // ⚠️ 时间选择器是 await —— 审计列的 4 处缺失 mounted 守卫之一。
    if (!mounted || picked == null) return;
    setState(() => _time = picked);
  }

  void _submit() {
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    if (name.isEmpty) {
      setState(() => _error = context.tr('任务名不能为空。'));
      return;
    }
    if (prompt.isEmpty) {
      setState(() => _error = context.tr('要执行什么不能为空 —— 到点它会作为一条消息发给模型。'));
      return;
    }
    final base = widget.initial;
    final schedule = Schedule(
      id: base?.id ??
          'sch-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: name,
      prompt: prompt,
      repeat: _repeat,
      hour: _time.hour,
      minute: _time.minute,
      weekdays: _weekdays.toList()..sort(),
      enabled: base?.enabled ?? true,
      createdAt: base?.createdAt,
      lastRunAt: base?.lastRunAt,
      lastOk: base?.lastOk,
      nextRunAt: base?.nextRunAt,
      lastSummary: base?.lastSummary,
    );
    Navigator.of(context).pop(schedule);
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DshMetrics.radius(18)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? DshColors.accentDim : DshColors.surfaceHigh,
          borderRadius: BorderRadius.circular(DshMetrics.radius(18)),
          border: Border.all(
            color: selected ? DshColors.accent : DshColors.divider,
            width: selected ? 1 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? DshColors.accent : DshColors.textDim,
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 泡泡猫快捷任务 chip：点一下把预设 prompt 填进输入框。
  Widget _fillChip(BuildContext context, String label, String prompt) {
    return InkWell(
      onTap: () => setState(() => _prompt.text = prompt),
      borderRadius: BorderRadius.circular(DshMetrics.radius(18)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: DshColors.surfaceHigh,
          borderRadius: BorderRadius.circular(DshMetrics.radius(18)),
          border: Border.all(color: DshColors.divider, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.bolt, size: 14, color: DshColors.accent),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(color: DshColors.accent, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}
