/// 定时任务 → **系统日历**。
///
/// ## 为什么做这个（对标 WorkBuddy 的 C5，见 MASTER §B.4）
///
/// App 内的调度器是**进程内**的（见 `schedule_runner.dart`）：进程被系统回收，
/// 任务就不会跑。把任务写成系统日历里的事件之后：
///   * 用户在「系统日历 / 提醒器」里**看得到**它；
///   * 到点由**系统日历自己**响 —— 不依赖我们的进程还活着。
///
/// ## 边界（如实写，别在交付里说成"一定准"）
///
/// - 要用户**授权** `WRITE_CALENDAR`；没授权就是"没同步"，不是"同步失败"。
/// - 设备上要**有可写的日历**（多数有系统日历账号的设备有；裸机没有）→ 如实报。
/// - 写进去的是**用户自己的日历**，用户可以在系统日历里把它删掉。
/// - 这里**不读**用户的日历内容（读是另一件事）。
///
/// ## 为什么把规则翻译单独拿出来
///
/// [scheduleRRule] 与 [planCalendarSync] 都是**纯逻辑**（不碰设备），
/// 所以能单测 —— 尤其是"星期几的口径"这种最容易错的地方：
/// 我们的 `weekdays` 是 `DateTime.weekday`（1=周一…7=周日），
/// 而 RFC 5545 用的是 `MO,TU,WE,TH,FR,SA,SU`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/schedule_store.dart';
import 'dsh_runtime.dart';

/// 把任务的重复规则翻译成 iCalendar 的重复规则（RFC 5545）。
///
/// 返回 null = **只发生一次**（不写 RRULE）。
String? scheduleRRule(Schedule s) {
  switch (s.repeat) {
    case ScheduleRepeat.once:
      return null;
    case ScheduleRepeat.daily:
      return 'FREQ=DAILY';
    case ScheduleRepeat.weekdays:
      // 「每个工作日」= 周一到周五（RRULE 没有"工作日"这个关键字，要写全）。
      return 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR';
    case ScheduleRepeat.weekly:
      final days = s.weekdays.where((d) => d >= 1 && d <= 7).toSet().toList()
        ..sort();
      if (days.isEmpty) return 'FREQ=WEEKLY;BYDAY=MO';
      return 'FREQ=WEEKLY;BYDAY=${days.map(_byDay).join(',')}';
  }
}

/// `DateTime.weekday`（1=周一…7=周日）→ RFC 5545 的星期缩写。
String _byDay(int weekday) {
  const names = <int, String>{
    1: 'MO',
    2: 'TU',
    3: 'WE',
    4: 'TH',
    5: 'FR',
    6: 'SA',
    7: 'SU',
  };
  return names[weekday] ?? 'MO';
}

/// 一次同步的**决定**：哪些任务要写进日历、哪些日历事件要删掉。
///
/// 纯数据（可单测）：没有设备也能验证"该写什么、该删什么"。
class CalendarSyncPlan {
  const CalendarSyncPlan({
    this.write = const <Schedule>[],
    this.removeEventIds = const <int>[],
  });

  /// 要**写/更新**的任务（有下一次运行时间、且处于启用状态）。
  final List<Schedule> write;

  /// 要**删掉**的日历事件 id。
  ///
  /// 来源：① 同步关掉了；② 任务被停用/删除；③ 「仅一次」的任务已经跑过
  /// （没有下一次运行时间了，日历里那条留着就是过期信息）。
  final List<int> removeEventIds;

  bool get isEmpty => write.isEmpty && removeEventIds.isEmpty;
}

/// 算出这次同步该做什么。**纯逻辑**（不碰设备）。
///
/// [enabled] = 用户在「定时任务」页打开的「同步到系统日历」开关。
CalendarSyncPlan planCalendarSync(
  List<Schedule> schedules, {
  required bool enabled,
}) {
  final write = <Schedule>[];
  final remove = <int>[];
  for (final s in schedules) {
    final eventId = s.calendarEventId;
    if (!enabled) {
      // 开关关掉了 → 把我们写的都撤掉（不动用户自己建的事件）。
      if (eventId != null) remove.add(eventId);
      continue;
    }
    if (!s.enabled) {
      if (eventId != null) remove.add(eventId);
      continue;
    }
    final next = s.nextRunAt;
    if (next == null) {
      // 没有下一次运行时间（例如「仅一次」已经跑过）→ 日历里那条也该撤掉。
      if (eventId != null) remove.add(eventId);
      continue;
    }
    write.add(s);
  }
  return CalendarSyncPlan(write: write, removeEventIds: remove);
}

/// 日历能力的现状。
class CalendarStatus {
  const CalendarStatus({
    required this.canRead,
    required this.canWrite,
    required this.hasWritableCalendar,
  });

  final bool canRead;
  final bool canWrite;

  /// 设备上**有可写的日历**吗（没写权限时永远是 false）。
  final bool hasWritableCalendar;

  /// 能不能真的把任务写进去。
  bool get canSync => canWrite && hasWritableCalendar;
}

/// 写一条任务的结果。
class CalendarWriteResult {
  const CalendarWriteResult({required this.ok, this.eventId, this.reason});

  final bool ok;

  /// 写成功时的事件 id（下次更新/删除靠它）。
  final int? eventId;

  /// 失败原因：`no_permission` / `no_calendar` / `error`。
  final String? reason;
}

/// 一条日历事件（读出来的）。
class CalendarEvent {
  const CalendarEvent({
    required this.eventId,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location = '',
  });

  final int eventId;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String location;
}

/// 系统日历的读写（走原生通道，见 `SystemCalendar.kt`）。
class SystemCalendar {
  const SystemCalendar._();

  static const MethodChannel _channel = DshHost.channel;

  /// 现状：能不能写、有没有可写的日历。
  static Future<CalendarStatus> status() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(
        'calendarStatus',
      );
      if (r == null) {
        return const CalendarStatus(
          canRead: false,
          canWrite: false,
          hasWritableCalendar: false,
        );
      }
      return CalendarStatus(
        canRead: r['read'] == true,
        canWrite: r['write'] == true,
        hasWritableCalendar: r['writableCalendar'] == true,
      );
    } catch (e) {
      debugPrint('[dsh-calendar] status 失败: $e');
      return const CalendarStatus(
        canRead: false,
        canWrite: false,
        hasWritableCalendar: false,
      );
    }
  }

  /// 把一条任务写进（或更新到）系统日历。
  ///
  /// [reminderMinutes] = 提前多少分钟提醒（0 = 准点提醒，-1 = 不提醒）。
  static Future<CalendarWriteResult> syncTask(
    Schedule s, {
    int reminderMinutes = 0,
    int durationMinutes = 30,
  }) async {
    final next = s.nextRunAt;
    if (next == null) {
      return const CalendarWriteResult(ok: false, reason: 'no_next_run');
    }
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(
        'calendarWriteEvent',
        <String, dynamic>{
          'eventId': s.calendarEventId,
          'title': s.name,
          'description': s.prompt,
          'start': next.millisecondsSinceEpoch,
          'durationMinutes': durationMinutes,
          'rrule': scheduleRRule(s),
          'reminderMinutes': reminderMinutes,
        },
      );
      if (r == null) {
        return const CalendarWriteResult(ok: false, reason: 'error');
      }
      if (r['ok'] == true) {
        final id = (r['eventId'] as num?)?.toInt();
        if (id == null) {
          return const CalendarWriteResult(ok: false, reason: 'error');
        }
        return CalendarWriteResult(ok: true, eventId: id);
      }
      return CalendarWriteResult(ok: false, reason: r['reason'] as String?);
    } catch (e) {
      debugPrint('[dsh-calendar] syncTask 失败: $e');
      return const CalendarWriteResult(ok: false, reason: 'error');
    }
  }

  /// 删掉我们自己写的那条事件。
  static Future<bool> removeTask(int eventId) async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(
        'calendarRemoveEvent',
        <String, dynamic>{'eventId': eventId},
      );
      return r != null && r['ok'] == true;
    } catch (e) {
      debugPrint('[dsh-calendar] removeTask 失败: $e');
      return false;
    }
  }

  /// 读未来一段时间的日历事件（要 READ 权限）。
  static Future<List<CalendarEvent>> upcoming({
    int days = 7,
    int limit = 50,
    DateTime? from,
  }) async {
    try {
      final raw = await _channel.invokeListMethod<Object?>(
        'calendarListUpcoming',
        <String, dynamic>{
          'from': (from ?? DateTime.now()).millisecondsSinceEpoch,
          'days': days,
          'limit': limit,
        },
      );
      if (raw == null) return const <CalendarEvent>[];
      final out = <CalendarEvent>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final m = Map<String, Object?>.from(item);
        final start = (m['start'] as num?)?.toInt();
        if (start == null) continue;
        out.add(
          CalendarEvent(
            eventId: (m['eventId'] as num?)?.toInt() ?? 0,
            title: m['title'] as String? ?? '',
            start: DateTime.fromMillisecondsSinceEpoch(start),
            end: DateTime.fromMillisecondsSinceEpoch(
              (m['end'] as num?)?.toInt() ?? start,
            ),
            allDay: m['allDay'] == true,
            location: m['location'] as String? ?? '',
          ),
        );
      }
      return out;
    } catch (e) {
      debugPrint('[dsh-calendar] upcoming 失败: $e');
      return const <CalendarEvent>[];
    }
  }
}
