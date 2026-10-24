package com.dshmobile.dsh_mobile

import android.content.Context
import android.os.SystemClock
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import java.lang.reflect.Method

/**
 * 屏幕助手「无头模式」的定向触摸/按键注入。
 *
 * 三个必须点（漏一个就是「点着点着手机自己在乱点」或「点了没反应」）：
 *  1. `InputEvent.setDisplayId(displayId)` —— 没这句事件打到**主屏**；
 *  2. `source = SOURCE_TOUCHSCREEN` —— 否则部分 App 的 View 不响应；
 *  3. `injectInputEvent(event, 2)` —— 2 = WAIT_FOR_FINISH，同步等分发完成。
 */
class InputBridge(context: Context) {

    private val inputManager: Any? = context.getSystemService(Context.INPUT_SERVICE)
    private val inject: Method? = runCatching {
        inputManager!!.javaClass.getMethod("injectInputEvent", InputEvent::class.java, Int::class.java)
    }.getOrNull()
    private val setDisplayId: Method? = runCatching {
        InputEvent::class.java.getMethod("setDisplayId", Int::class.java)
    }.getOrNull()

    fun available(): Boolean = inputManager != null && inject != null && setDisplayId != null

    private fun send(displayId: Int, event: InputEvent) {
        setDisplayId!!.invoke(event, displayId)
        inject!!.invoke(inputManager, event, 2 /* WAIT_FOR_FINISH */)
    }

    private fun motion(down: Long, when_: Long, action: Int, x: Float, y: Float): MotionEvent {
        val e = MotionEvent.obtain(
            down, when_, action, x, y,
            1f, 1f,          // pressure, size
            0,               // metaState
            1f, 1f,          // xPrecision, yPrecision
            0, 0             // deviceId, edgeFlags
        )
        e.source = InputDevice.SOURCE_TOUCHSCREEN
        return e
    }

    fun tap(displayId: Int, x: Float, y: Float) {
        val now = SystemClock.uptimeMillis()
        send(displayId, motion(now, now, MotionEvent.ACTION_DOWN, x, y))
        send(displayId, motion(now, now + 80, MotionEvent.ACTION_UP, x, y))
    }

    fun swipe(displayId: Int, x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Int) {
        val dur = durationMs.coerceAtLeast(120)
        val steps = (dur / 16).coerceAtLeast(6)
        val down = SystemClock.uptimeMillis()
        send(displayId, motion(down, down, MotionEvent.ACTION_DOWN, x1, y1))
        for (i in 1 until steps) {
            val p = i.toFloat() / steps
            val x = x1 + (x2 - x1) * p
            val y = y1 + (y2 - y1) * p
            send(displayId, motion(down, down + (dur * p).toLong(), MotionEvent.ACTION_MOVE, x, y))
            SystemClock.sleep(8)
        }
        send(displayId, motion(down, down + dur, MotionEvent.ACTION_UP, x2, y2))
    }

    fun key(displayId: Int, keyCode: Int) {
        val now = SystemClock.uptimeMillis()
        send(displayId, KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0))
        send(displayId, KeyEvent(now, now + 20, KeyEvent.ACTION_UP, keyCode, 0))
    }

    fun text(displayId: Int, s: String) {
        val events = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
            .getEvents(s.toCharArray())
        events?.forEach { send(displayId, it) }
    }
}
