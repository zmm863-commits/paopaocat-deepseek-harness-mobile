/// 定时任务的**数据层**：任务定义 + 运行历史 + 持久化 + 下次运行时间计算。
///
/// 落盘位置：`<filesDir>/schedules.json`（App 私有目录）。
///
/// 为什么调度要 App 自己写（而不是用 DSH 的自动化）：
/// 随包的运行时 zip（26,495 个条目）里搜 `automation` **命中 0** ——
/// DSH 自带的调度能力根本没有进手机包，所以这里没有现成能力可接。
///
/// 执行通道复用的是 `DshRuntime.headless(prompt)`，见 `local/schedule_runner.dart`。
library;

import 'dart:convert';
import 'dart:io';

import '../i18n/dsh_i18n.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'atomic_file.dart';

/// 重复规则。
enum ScheduleRepeat { once, daily, weekdays, weekly }

extension ScheduleRepeatX on ScheduleRepeat {
  String get id => switch (this) {
        ScheduleRepeat.once => 'once',
        ScheduleRepeat.daily => 'daily',
        ScheduleRepeat.weekdays => 'weekdays',
        ScheduleRepeat.weekly => 'weekly',
      };

  String get label => switch (this) {
        ScheduleRepeat.once => tr('仅一次'),
        ScheduleRepeat.daily => tr('每天'),
        ScheduleRepeat.weekdays => tr('每个工作日'),
        ScheduleRepeat.weekly => tr('每周'),
      };

  static ScheduleRepeat parse(String? raw) {
    for (final v in ScheduleRepeat.values) {
      if (v.id == raw) return v;
    }
    return ScheduleRepeat.daily;
  }
}

/// 一次执行记录。
class ScheduleRun {
  const ScheduleRun({
    required this.at,
    required this.ok,
    required this.summary,
    this.missed = false,
    this.taskName = '',
  });

  final DateTime at;
  final bool ok;
  final String summary;

  /// 「已错过」：App 当时没在运行 —— **如实记录，不假装跑过**。
  final bool missed;
  final String taskName;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'at': at.toIso8601String(),
        'ok': ok,
        'summary': summary,
        'missed': missed,
        'taskName': taskName,
      };

  static ScheduleRun fromJson(Map<String, dynamic> j) => ScheduleRun(
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
        ok: j['ok'] as bool? ?? false,
        summary: j['summary'] as String? ?? '',
        missed: j['missed'] as bool? ?? false,
        taskName: j['taskName'] as String? ?? '',
      );
}

/// 一条定时任务。
class Schedule {
  Schedule({
    required this.id,
    required this.name,
    required this.prompt,
    this.repeat = ScheduleRepeat.daily,
    this.hour = 8,
    this.minute = 0,
    this.weekdays = const <int>[1],
    this.enabled = true,
    DateTime? createdAt,
    this.lastRunAt,
    this.lastOk,
    this.nextRunAt,
    this.lastSummary,
    this.calendarEventId,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  String prompt;
  ScheduleRepeat repeat;
  int hour;
  int minute;

  /// weekly 用：1=周一 … 7=周日（DateTime.weekday 口径）
  List<int> weekdays;
  bool enabled;
  final DateTime createdAt;
  DateTime? lastRunAt;
  bool? lastOk;
  DateTime? nextRunAt;
  String? lastSummary;

  /// 这条任务在**系统日历**里的事件 id（见 `local/system_calendar.dart`）。
  ///
  /// 记它是为了两件事：① 下次同步时**更新**同一条事件，而不是每次新建一条
  /// （新建会在用户的日历里堆出一串重复项）；② 任务被删/停用时能把它撤掉。
  ///
  /// null = 还没写进日历（或者用户没授权 / 设备上没有可写日历）。
  int? calendarEventId;

  /// 中文描述，如「每个工作日 08:00」
  String get ruleLabel {
    final hh = hour.toString().padLeft(2, '0');
    final mm = minute.toString().padLeft(2, '0');
    switch (repeat) {
      case ScheduleRepeat.once:
        return tr('仅一次 · {0}:{1}', [hh, mm]);
      case ScheduleRepeat.daily:
        return tr('每天 {0}:{1}', [hh, mm]);
      case ScheduleRepeat.weekdays:
        return tr('每个工作日 {0}:{1}', [hh, mm]);
      case ScheduleRepeat.weekly:
        final names = <int, String>{
          1: tr('一'),
          2: tr('二'),
          3: tr('三'),
          4: tr('四'),
          5: tr('五'),
          6: tr('六'),
          7: tr('日'),
        };
        final w = (weekdays.isEmpty ? <int>[1] : weekdays)
            .map((d) => names[d] ?? '$d')
            .join('、');
        return tr('每周{0} {1}:{2}', [w, hh, mm]);
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'prompt': prompt,
        'repeat': repeat.id,
        'hour': hour,
        'minute': minute,
        'weekdays': weekdays,
        'enabled': enabled,
        'createdAt': createdAt.toIso8601String(),
        'lastRunAt': lastRunAt?.toIso8601String(),
        'lastOk': lastOk,
        'nextRunAt': nextRunAt?.toIso8601String(),
        'lastSummary': lastSummary,
        'calendarEventId': calendarEventId,
      };

  static Schedule fromJson(Map<String, dynamic> j) => Schedule(
        id: j['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: j['name'] as String? ?? tr('未命名任务'),
        prompt: j['prompt'] as String? ?? '',
        repeat: ScheduleRepeatX.parse(j['repeat'] as String?),
        hour: (j['hour'] as num?)?.toInt() ?? 8,
        minute: (j['minute'] as num?)?.toInt() ?? 0,
        weekdays: (j['weekdays'] as List?)
                ?.whereType<num>()
                .map((e) => e.toInt())
                .toList() ??
            const <int>[1],
        enabled: j['enabled'] as bool? ?? true,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
        lastRunAt: DateTime.tryParse(j['lastRunAt'] as String? ?? ''),
        lastOk: j['lastOk'] as bool?,
        nextRunAt: DateTime.tryParse(j['nextRunAt'] as String? ?? ''),
        lastSummary: j['lastSummary'] as String?,
        calendarEventId: (j['calendarEventId'] as num?)?.toInt(),
      );
}

/// 任务 + 历史的内存态，带落盘。
class ScheduleStore extends ChangeNotifier {
  ScheduleStore(this.filesDir);

  final String filesDir;

  /// 历史最多留这么多条（不设上限会无限膨胀）。
  static const int kMaxRuns = 50;

  List<Schedule> _schedules = <Schedule>[];
  List<ScheduleRun> _runs = <ScheduleRun>[];
  bool _loaded = false;
  String? _error;

  /// 要不要把任务**同步到系统日历**（见 `local/system_calendar.dart`）。
  ///
  /// 默认关着：往用户的日历里写东西要**用户自己点头**，不能默认就写。
  bool _calendarSync = false;

  List<Schedule> get schedules => List<Schedule>.unmodifiable(_schedules);
  List<ScheduleRun> get runs => List<ScheduleRun>.unmodifiable(_runs);
  bool get loaded => _loaded;
  String? get error => _error;
  int get enabledCount => _schedules.where((s) => s.enabled).length;

  /// 是否开着「同步到系统日历」。
  bool get calendarSync => _calendarSync;

  File get _file => File('$filesDir/schedules.json');

  Future<void> load() async {
    try {
      final f = _file;
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map) {
          final list = raw['schedules'];
          if (list is List) {
            _schedules = list
                .whereType<Map>()
                .map((e) => Schedule.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          }
          final runs = raw['runs'];
          if (runs is List) {
            _runs = runs
                .whereType<Map>()
                .map((e) => ScheduleRun.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          }
          _calendarSync = raw['calendarSync'] == true;
        }
        _error = null;
      }
    } catch (e) {
      // 读盘失败要说出来，不能静默当成"没有任务"
      _error = tr('读取 {0}/schedules.json 失败：{1}', [filesDir, e]);
      debugPrint('[dsh-schedule] load failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final dir = Directory(filesDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final payload = <String, dynamic>{
        'schedules': _schedules.map((s) => s.toJson()).toList(),
        'runs': _runs.map((r) => r.toJson()).toList(),
        'calendarSync': _calendarSync,
      };
      await writeStringAtomic(_file, jsonEncode(payload));
    } catch (e) {
      debugPrint('[dsh-schedule] persist failed: $e');
      _error = tr('保存失败：{0}', [e]);
    }
  }

  Future<void> add(Schedule s) async {
    _schedules.add(s);
    _recompute(s, from: DateTime.now());
    await _persist();
    notifyListeners();
  }

  Future<void> update(Schedule s) async {
    final i = _schedules.indexWhere((x) => x.id == s.id);
    if (i < 0) return;
    _schedules[i] = s;
    _recompute(s, from: DateTime.now());
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _schedules.removeWhere((s) => s.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> setEnabled(Schedule s, bool on) async {
    s.enabled = on;
    if (on) {
      _recompute(s, from: DateTime.now());
    } else {
      s.nextRunAt = null;
    }
    await _persist();
    notifyListeners();
  }

  Future<void> recordRun(Schedule s, ScheduleRun run) async {
    s.lastRunAt = run.at;
    s.lastOk = run.missed ? null : run.ok;
    s.lastSummary = run.summary;
    _runs.insert(0, run);
    if (_runs.length > kMaxRuns) _runs = _runs.sublist(0, kMaxRuns);
    if (s.repeat == ScheduleRepeat.once && !run.missed) {
      // 「仅一次」跑过就不再触发
      s.enabled = false;
      s.nextRunAt = null;
    } else {
      _recompute(s, from: DateTime.now());
    }
    await _persist();
    notifyListeners();
  }

  Future<void> clearRuns() async {
    _runs = <ScheduleRun>[];
    await _persist();
    notifyListeners();
  }

  /// 记下这条任务在系统日历里的事件 id。
  ///
  /// ⚠️ **刻意不 `notifyListeners()`**：同步流程是
  /// 「同步 → 落盘事件 id → 又触发一次同步 → …」，
  /// 通知一次就会自激成死循环。所以这里只落盘。
  Future<void> setCalendarEventId(Schedule s, int? id) async {
    if (s.calendarEventId == id) return;
    s.calendarEventId = id;
    await _persist();
  }

  /// 开关「同步到系统日历」。
  Future<void> setCalendarSync(bool on) async {
    if (_calendarSync == on) return;
    _calendarSync = on;
    await _persist();
    notifyListeners();
  }

  /// App 启动时把「已经过期很久」的任务如实记为「已错过」。
  ///
  /// 判定：`nextRunAt` 比现在早超过 [missedAfter]。这么长时间没触发，
  /// 只可能是 App 当时没在运行 —— **不能假装它准时跑过**。
  Future<void> markMissedIfStale(
      {Duration missedAfter = const Duration(minutes: 3)}) async {
    final now = DateTime.now();
    var changed = false;
    for (final s in _schedules) {
      final next = s.nextRunAt;
      if (!s.enabled || next == null) continue;
      if (now.difference(next) > missedAfter) {
        _runs.insert(
          0,
          ScheduleRun(
            at: next,
            ok: false,
            missed: true,
            taskName: s.name,
            summary: tr('已错过：计划时间到达时 App 未运行（本机没有系统级闹钟，关掉 App 后不会触发）。'),
          ),
        );
        s.lastRunAt = next;
        s.lastOk = null;
        s.lastSummary = tr('已错过（App 未运行）');
        _recompute(s, from: now);
        changed = true;
      }
    }
    if (_runs.length > kMaxRuns) _runs = _runs.sublist(0, kMaxRuns);
    if (changed) {
      await _persist();
      notifyListeners();
    }
  }

  void _recompute(Schedule s, {required DateTime from}) {
    s.nextRunAt = computeNextRun(
      repeat: s.repeat,
      hour: s.hour,
      minute: s.minute,
      weekdays: s.weekdays,
      from: from,
      onceAlreadyRan: s.repeat == ScheduleRepeat.once && s.lastRunAt != null,
    );
  }

  /// 纯函数：算出下次运行时间。**所有边界都在这一个函数里**，便于自测。
  ///
  /// - `once` 且已经跑过 → `null`（不再触发）
  /// - 今天该时刻已过 → 顺延到下一次符合条件的日子
  /// - `weekdays` = 周一~周五；`weekly` 用 [weekdays] 指定的集合（1=周一…7=周日）
  static DateTime? computeNextRun({
    required ScheduleRepeat repeat,
    required int hour,
    required int minute,
    required List<int> weekdays,
    required DateTime from,
    bool onceAlreadyRan = false,
  }) {
    if (repeat == ScheduleRepeat.once && onceAlreadyRan) return null;

    DateTime at(DateTime d) => DateTime(d.year, d.month, d.day, hour, minute);

    // 先把候选定在「今天该时刻」，已过就推到明天，再按规则找下一个合法日子。
    var candidate = at(from);
    if (!candidate.isAfter(from)) {
      candidate = at(from.add(const Duration(days: 1)));
    }

    switch (repeat) {
      case ScheduleRepeat.once:
      case ScheduleRepeat.daily:
        return candidate;
      case ScheduleRepeat.weekdays:
        for (var i = 0; i < 8; i++) {
          if (candidate.weekday <= 5) return candidate; // 1~5 = 周一~周五
          candidate = at(candidate.add(const Duration(days: 1)));
        }
        return candidate;
      case ScheduleRepeat.weekly:
        final set = weekdays.isEmpty ? <int>[from.weekday] : weekdays;
        for (var i = 0; i < 8; i++) {
          if (set.contains(candidate.weekday)) return candidate;
          candidate = at(candidate.add(const Duration(days: 1)));
        }
        return candidate;
    }
  }

  /// 「30 分钟后」/「明天 08:00」这种人话。
  ///
  /// **优先按日历日表述**：对定时任务来说"明天 08:00"比"23 小时后"有用得多
  /// （用户关心的是哪天几点）。同一天内才退化成"x 分钟后 / x 小时后"。
  static String humanize(DateTime? t, {DateTime? now}) {
    if (t == null) return tr('不再触发');
    final base = now ?? DateTime.now();
    if (!t.isAfter(base)) return tr('已过期');

    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final days = DateTime(t.year, t.month, t.day)
        .difference(DateTime(base.year, base.month, base.day))
        .inDays;

    if (days == 0) {
      final d = t.difference(base);
      if (d.inMinutes < 1) return tr('不到 1 分钟');
      if (d.inMinutes < 60) return tr('{0} 分钟后', [d.inMinutes]);
      return tr('{0}:{1}（{2} 小时后）', [hh, mm, d.inHours]);
    }
    if (days == 1) return tr('明天 {0}:{1}', [hh, mm]);
    if (days == 2) return tr('后天 {0}:{1}', [hh, mm]);
    return tr('{0}月{1}日 {2}:{3}', [t.month, t.day, hh, mm]);
  }
}
