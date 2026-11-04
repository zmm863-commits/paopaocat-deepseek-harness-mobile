package com.dshmobile.dsh_mobile

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import android.util.Log
import java.util.TimeZone

/**
 * 系统日历的读写：把**定时任务**变成系统日历里的事件。
 *
 * ## 为什么做这个（对标同类产品的 C5，见 MASTER §B.4）
 *
 * App 内的调度器是**进程内**的（见 `schedule_runner.dart`）：进程被系统回收，
 * 任务就不会跑。把任务写成**系统日历里的事件**之后：
 *   * 用户在「系统日历 / 提醒器」里**看得到**它；
 *   * 到点由**系统日历自己**响 —— 不依赖我们的进程还活着。
 *
 * 这正是同类产品那边的 `READ/WRITE_CALENDAR` + `device_alarm` 干的事。
 *
 * ## 能力边界（如实写在这里，不要在交付里说成"一定准"）
 *
 * - 要用户**授予** `WRITE_CALENDAR`；没授权就是"没同步"，不是"同步失败"。
 * - 设备上要**有可写的日历**（多数有系统日历账号的设备有；裸机/无账号设备没有）
 *   → 此时如实报 `no_calendar`，不假装写成功。
 * - 写进去的是**用户自己的日历**，用户可以在系统日历里把它删掉；
 *   删了之后我们这边会退回"新建一条"（见 [writeEvent] 的回退逻辑）。
 * - 这里**不读**用户的日历内容（读是另一件事，要 READ 权限且用户同意）。
 */
object SystemCalendar {

    private const val TAG = "DshLocal"

    /** 写一条事件时，事件持续的时长（分钟）。任务本身是"跑一次模型"，不是开一整天的会。 */
    const val DEFAULT_DURATION_MINUTES = 30

    /** 权限是否已授予。 */
    fun hasPermission(context: Context, write: Boolean): Boolean {
        val p = if (write) {
            Manifest.permission.WRITE_CALENDAR
        } else {
            Manifest.permission.READ_CALENDAR
        }
        return context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * 找一个**可写**的日历：优先主日历（`IS_PRIMARY=1`），
     * 其次任意 `VISIBLE=1 且 访问级别 >= CONTRIBUTOR` 的日历。
     *
     * 找不到返回 null —— 调用方要**如实说"这台设备没有可写的日历"**，
     * 不能假装同步成功。
     */
    fun writableCalendarId(context: Context): Long? {
        if (!hasPermission(context, true)) return null
        val projection = arrayOf(CalendarContract.Calendars._ID)
        val base =
            "${CalendarContract.Calendars.VISIBLE} = 1 AND " +
            "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ?"
        val args = arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString())
        val primary = queryCalendar(
            context, projection,
            "$base AND ${CalendarContract.Calendars.IS_PRIMARY} = 1", args
        )
        if (primary != null) return primary
        return queryCalendar(context, projection, base, args)
    }

    private fun queryCalendar(
        context: Context,
        projection: Array<String>,
        selection: String,
        args: Array<String>,
    ): Long? {
        var id: Long? = null
        try {
            context.contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI, projection, selection, args, null
            )?.use { c ->
                if (c.moveToFirst()) id = c.getLong(0)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "查可写日历失败: ${e.message}")
        }
        return id
    }

    /**
     * 写一条事件（新建或更新）。
     *
     * @param eventId 已知的事件 id → 更新；null → 新建。
     * @param startMillis 第一次发生的时间（**用任务的下次运行时间**）。
     * @param rrule 重复规则（RFC 5545）；null = 只发生一次。
     * @param reminderMinutes 提前多少分钟提醒；<0 = 不提醒。
     * @return 事件 id；失败（没权限 / 没有可写日历 / 系统拒绝）返回 null。
     */
    fun writeEvent(
        context: Context,
        eventId: Long?,
        title: String,
        description: String,
        startMillis: Long,
        durationMinutes: Int = DEFAULT_DURATION_MINUTES,
        rrule: String? = null,
        reminderMinutes: Int = 0,
    ): Long? {
        if (!hasPermission(context, true)) return null
        val calId = writableCalendarId(context) ?: return null
        val values = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calId)
            put(CalendarContract.Events.TITLE, title)
            put(CalendarContract.Events.DESCRIPTION, description)
            put(CalendarContract.Events.DTSTART, startMillis)
            put(
                CalendarContract.Events.DTEND,
                startMillis + durationMinutes.coerceAtLeast(1) * 60_000L
            )
            put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
            put(CalendarContract.Events.HAS_ALARM, if (reminderMinutes >= 0) 1 else 0)
            if (rrule.isNullOrEmpty()) {
                putNull(CalendarContract.Events.RRULE)
            } else {
                put(CalendarContract.Events.RRULE, rrule)
            }
        }
        val resolver = context.contentResolver
        var id = eventId
        if (id != null) {
            // 更新；用户可能已经在系统日历里把它删了 → 更新返回 0，这时退回新建。
            val n = try {
                resolver.update(
                    ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id),
                    values, null, null
                )
            } catch (e: Throwable) {
                Log.w(TAG, "更新日历事件失败: ${e.message}")
                0
            }
            if (n <= 0) id = null
        }
        if (id == null) {
            id = try {
                val uri = resolver.insert(CalendarContract.Events.CONTENT_URI, values)
                uri?.lastPathSegment?.toLongOrNull()
            } catch (e: Throwable) {
                Log.w(TAG, "写日历事件失败: ${e.message}")
                null
            }
        }
        if (id == null) return null
        if (reminderMinutes >= 0) setReminder(context, id, reminderMinutes)
        return id
    }

    /** 加提醒（ALERT）。先删掉旧的再加，避免重复。 */
    private fun setReminder(context: Context, eventId: Long, minutes: Int) {
        try {
            val resolver = context.contentResolver
            resolver.delete(
                CalendarContract.Reminders.CONTENT_URI,
                "${CalendarContract.Reminders.EVENT_ID} = ?",
                arrayOf(eventId.toString())
            )
            val values = ContentValues().apply {
                put(CalendarContract.Reminders.EVENT_ID, eventId)
                put(CalendarContract.Reminders.MINUTES, minutes)
                put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
            }
            resolver.insert(CalendarContract.Reminders.CONTENT_URI, values)
        } catch (e: Throwable) {
            Log.w(TAG, "写日历提醒失败: ${e.message}")
        }
    }

    /** 删掉我们自己写的那条事件。 */
    fun removeEvent(context: Context, eventId: Long): Boolean {
        if (!hasPermission(context, true)) return false
        return try {
            context.contentResolver.delete(
                ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId),
                null, null
            ) > 0
        } catch (e: Throwable) {
            Log.w(TAG, "删日历事件失败: ${e.message}")
            false
        }
    }

    /**
     * 读未来一段时间的日历事件（要 READ 权限）。
     *
     * 用 `Instances` 视图：重复事件会按**每一次的发生**展开，
     * 这样"明早 8 点那条"能直接读出来，而不是只拿到重复规则的定义。
     */
    fun listUpcoming(context: Context, fromMillis: Long, days: Int, limit: Int): List<Map<String, Any?>> {
        if (!hasPermission(context, false)) return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        val until = fromMillis + days.coerceAtLeast(1) * 24L * 3600_000L
        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.EVENT_LOCATION,
        )
        try {
            context.contentResolver.query(
                CalendarContract.Instances.CONTENT_URI,
                projection,
                "${CalendarContract.Instances.BEGIN} >= ? AND ${CalendarContract.Instances.BEGIN} < ?",
                arrayOf(fromMillis.toString(), until.toString()),
                "${CalendarContract.Instances.BEGIN} ASC"
            )?.use { c ->
                while (c.moveToNext() && out.size < limit) {
                    out.add(
                        mapOf(
                            "eventId" to c.getLong(0),
                            "title" to (c.getString(1) ?: ""),
                            "start" to c.getLong(2),
                            "end" to c.getLong(3),
                            "allDay" to (c.getInt(4) == 1),
                            "location" to (c.getString(5) ?: "")
                        )
                    )
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "读日历失败: ${e.message}")
        }
        return out
    }
}
