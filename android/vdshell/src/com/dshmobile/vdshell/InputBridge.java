package com.dshmobile.vdshell;

import android.os.SystemClock;
import android.util.Log;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.lang.reflect.Method;

/**
 * 定向触摸/按键注入（跑在 shell 进程里，所以有 injectInputEvent 的权限）。
 *
 * 三个必须点（漏一个就是「点着点着手机自己在乱点」或「点了没反应」）：
 *  1. {@code InputEvent.setDisplayId(displayId)} —— 没这句事件打到**主屏**；
 *  2. {@code source = SOURCE_TOUCHSCREEN} —— 否则部分 App 的 View 不响应；
 *  3. {@code injectInputEvent(event, 2)} —— 2 = WAIT_FOR_FINISH，同步等分发完成。
 */
final class InputBridge {
    private static final String TAG = "VdShell";

    private final Object inputManager;
    private final Method inject;
    private final Method setDisplayId;

    InputBridge() {
        Object im = null;
        Method inj = null;
        Method sdi = null;
        try {
            Class<?> c = Class.forName("android.hardware.input.InputManager");
            Method getInstance = c.getDeclaredMethod("getInstance");
            getInstance.setAccessible(true);
            im = getInstance.invoke(null);
            inj = c.getDeclaredMethod("injectInputEvent", InputEvent.class, int.class);
            inj.setAccessible(true);
            try {
                sdi = InputEvent.class.getMethod("setDisplayId", int.class);
                sdi.setAccessible(true);
            } catch (NoSuchMethodException ignored) {
                sdi = null;
            }
        } catch (Throwable t) {
            Log.e(TAG, "InputBridge init failed", t);
        }
        inputManager = im;
        inject = inj;
        setDisplayId = sdi;
    }

    boolean available() {
        return inputManager != null && inject != null && setDisplayId != null;
    }

    private void send(int displayId, InputEvent event) throws Exception {
        setDisplayId.invoke(event, displayId);
        inject.invoke(inputManager, event, 2 /* WAIT_FOR_FINISH */);
    }

    private static MotionEvent motion(long down, long when, int action, float x, float y) {
        MotionEvent e = MotionEvent.obtain(
                down, when, action, x, y,
                1f, 1f,       // pressure, size
                0,            // metaState
                1f, 1f,       // xPrecision, yPrecision
                0, 0);        // deviceId, edgeFlags
        e.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        return e;
    }

    void tap(int displayId, float x, float y) throws Exception {
        long now = SystemClock.uptimeMillis();
        send(displayId, motion(now, now, MotionEvent.ACTION_DOWN, x, y));
        send(displayId, motion(now, now + 80, MotionEvent.ACTION_UP, x, y));
    }

    void swipe(int displayId, float x1, float y1, float x2, float y2, int durationMs)
            throws Exception {
        int dur = Math.max(120, durationMs);
        int steps = Math.max(6, dur / 16);
        long down = SystemClock.uptimeMillis();
        send(displayId, motion(down, down, MotionEvent.ACTION_DOWN, x1, y1));
        for (int i = 1; i < steps; i++) {
            float p = (float) i / steps;
            float x = x1 + (x2 - x1) * p;
            float y = y1 + (y2 - y1) * p;
            send(displayId, motion(down, down + (long) (dur * p), MotionEvent.ACTION_MOVE, x, y));
            SystemClock.sleep(8);
        }
        send(displayId, motion(down, down + dur, MotionEvent.ACTION_UP, x2, y2));
    }

    void key(int displayId, int keyCode) throws Exception {
        long now = SystemClock.uptimeMillis();
        send(displayId, new KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0));
        send(displayId, new KeyEvent(now, now + 20, KeyEvent.ACTION_UP, keyCode, 0));
    }

    void text(int displayId, String s) throws Exception {
        KeyEvent[] events = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
                .getEvents(s.toCharArray());
        if (events == null) return;
        for (KeyEvent e : events) send(displayId, e);
    }
}
