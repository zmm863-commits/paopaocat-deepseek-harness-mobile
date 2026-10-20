/// 系统日历同步（E-6 / CHG-05）的**纯逻辑**回归测试。
///
/// ## 为什么这些能单测
///
/// 同步里最容易错的两步都不碰设备：
///   1. [scheduleRRule] —— 重复规则的翻译（**星期几的口径**最容易错）；
///   2. [planCalendarSync] —— 该写哪几条、该删哪几条。
///
/// 原生那一层（`SystemCalendar.kt`）要真机才验得了，
/// 所以这一层必须**用单测钉死**，否则改坏了没人知道。
library;

import 'package:dsh_mobile/data/schedule_store.dart';
import 'package:dsh_mobile/local/system_calendar.dart';
import 'package:flutter_test/flutter_test.dart';

Schedule _task({
  String id = 's1',
  String name = '晨间简报',
  ScheduleRepeat repeat = ScheduleRepeat.daily,
  List<int> weekdays = const <int>[1],
  bool enabled = true,
  DateTime? nextRunAt,
  int? calendarEventId,
}) {
  final s = Schedule(
    id: id,
    name: name,
    prompt: '总结今天的日程',
    repeat: repeat,
    weekdays: weekdays,
    enabled: enabled,
  );
  s.nextRunAt = nextRunAt ?? DateTime(2026, 10, 21, 8, 0);
  s.calendarEventId = calendarEventId;
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('重复规则翻译（RRULE）', () {
    test('仅一次 → 不写重复规则', () {
      expect(scheduleRRule(_task(repeat: ScheduleRepeat.once)), isNull);
    });

    test('每天 → FREQ=DAILY', () {
      expect(scheduleRRule(_task(repeat: ScheduleRepeat.daily)), 'FREQ=DAILY');
    });

    test('每个工作日 → 周一到周五（RRULE 没有"工作日"关键字，要写全）', () {
      expect(
        scheduleRRule(_task(repeat: ScheduleRepeat.weekdays)),
        'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      );
    });

    test('每周几 → BYDAY（星期几的口径：1=周一 … 7=周日）', () {
      // ⚠️ 这里最容易错：DateTime.weekday 是 1=周一，而 RFC 5545 用 MO/TU/…
      expect(
        scheduleRRule(_task(
          repeat: ScheduleRepeat.weekly,
          weekdays: const <int>[1, 3, 5],
        )),
        'FREQ=WEEKLY;BYDAY=MO,WE,FR',
      );
      expect(
        scheduleRRule(_task(
          repeat: ScheduleRepeat.weekly,
          weekdays: const <int>[7],
        )),
        'FREQ=WEEKLY;BYDAY=SU',
      );
    });

    test('星期几乱序 / 越界 → 排序并丢掉越界的', () {
      expect(
        scheduleRRule(_task(
          repeat: ScheduleRepeat.weekly,
          weekdays: const <int>[5, 1, 9, 0],
        )),
        'FREQ=WEEKLY;BYDAY=MO,FR',
      );
    });

    test('一个都没选 → 退回周一（不能生成空规则）', () {
      expect(
        scheduleRRule(_task(
          repeat: ScheduleRepeat.weekly,
          weekdays: const <int>[],
        )),
        'FREQ=WEEKLY;BYDAY=MO',
      );
    });
  });

  group('同步计划（该写什么、该删什么）', () {
    test('开着开关 + 已启用 + 有下一次时间 → 写', () {
      final plan = planCalendarSync(<Schedule>[_task()], enabled: true);
      expect(plan.write.length, 1);
      expect(plan.removeEventIds, isEmpty);
    });

    test('任务被停用 → 删掉它在日历里的那条', () {
      final plan = planCalendarSync(
        <Schedule>[_task(enabled: false, calendarEventId: 42)],
        enabled: true,
      );
      expect(plan.write, isEmpty);
      expect(plan.removeEventIds, <int>[42]);
    });

    test('「仅一次」已经跑过（没有下一次时间）→ 日历里那条也该撤掉', () {
      final s = _task(repeat: ScheduleRepeat.once, calendarEventId: 7);
      s.nextRunAt = null;
      final plan = planCalendarSync(<Schedule>[s], enabled: true);
      expect(plan.write, isEmpty);
      expect(plan.removeEventIds, <int>[7]);
    });

    test('开关关掉 → 我们写的全部撤掉（不动用户自己建的事件）', () {
      final plan = planCalendarSync(
        <Schedule>[
          _task(id: 'a', calendarEventId: 1),
          _task(id: 'b', calendarEventId: 2),
          _task(id: 'c'),
        ],
        enabled: false,
      );
      expect(plan.write, isEmpty);
      expect(plan.removeEventIds, <int>[1, 2]);
    });

    test('没写进过日历的任务（没有事件 id）→ 不用去删', () {
      final plan = planCalendarSync(
        <Schedule>[_task(enabled: false)],
        enabled: true,
      );
      expect(plan.removeEventIds, isEmpty);
    });
  });

  group('持久化：事件 id 跟着任务一起落盘', () {
    test('toJson / fromJson 保留 calendarEventId', () {
      final s = _task(calendarEventId: 99);
      final back = Schedule.fromJson(s.toJson());
      expect(back.calendarEventId, 99);
    });

    test('没有事件 id 时是 null（不是 0）', () {
      final back = Schedule.fromJson(_task().toJson());
      expect(back.calendarEventId, isNull);
    });
  });
}
