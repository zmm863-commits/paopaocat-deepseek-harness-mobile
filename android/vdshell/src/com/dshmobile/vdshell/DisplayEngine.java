package com.dshmobile.vdshell;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStreamReader;

/**
 * 无头虚拟屏的生命周期（跑在 shell 进程内）。
 *
 * 核心三件事：
 *  1. {@code DisplayManager.createVirtualDisplay()} 建一块**看不见**的屏 —— 因为进程是
 *     uid 2000（shell），持有 CAPTURE_VIDEO_OUTPUT，**不需要 MediaProjection 授权弹窗**；
 *  2. {@code am start --display <id>} 把目标 App 拉到这块屏上；
 *  3. 触摸/按键通过 {@link InputBridge} **定向**打进这块屏。
 */
final class DisplayEngine {
    private static final String TAG = "VdShell";

    private final Context context;
    private final InputBridge input = new InputBridge();

    private VirtualDisplay vd;
    private ImageReader reader;
    private int displayId = -1;
    private PowerManager.WakeLock wakeLock;

    DisplayEngine(Context context) {
        this.context = context;
    }

    String status() {
        return displayId >= 0 ? "OK:display=" + displayId : "OK:idle";
    }

    int displayId() {
        return displayId;
    }

    synchronized String create(int w, int h, int dpi) {
        release();

        int width = clamp(w, 320, 2160);
        int height = clamp(h, 480, 3840);
        int density = clamp(dpi, 120, 640);

        try {
            DisplayManager dm = (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
            if (dm == null) return "ERR:no DisplayManager";
            ImageReader ir = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3);

            int base = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC
                    | DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION
                    | DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY;
            int touch = hiddenFlag("VIRTUAL_DISPLAY_FLAG_SUPPORTS_TOUCH", 1 << 6);
            int focus = hiddenFlag("VIRTUAL_DISPLAY_FLAG_OWN_FOCUS", 1 << 14);
            int trust = hiddenFlag("VIRTUAL_DISPLAY_FLAG_TRUSTED", 1 << 10);

            // flags 必须逐级降级：不同 ROM 会拒绝不同 flag
            int[] candidates = new int[]{
                    base | touch | focus | trust,
                    base | touch | focus,
                    base | touch,
                    base
            };

            Throwable last = null;
            for (int flags : candidates) {
                VirtualDisplay created = null;
                try {
                    created = createVirtualDisplay(dm, "vd-shell", width, height, density,
                            ir.getSurface(), flags);
                    if (created != null && created.getDisplay() != null) {
                        vd = created;
                        reader = ir;
                        displayId = created.getDisplay().getDisplayId();
                        applyImePolicy(displayId);
                        acquireWakeLock();
                        Log.i(TAG, "display created id=" + displayId
                                + " flags=0x" + Integer.toHexString(flags));
                        return "OK:" + displayId;
                    }
                } catch (Throwable t) {
                    last = t;
                }
                if (created != null) {
                    try { created.release(); } catch (Throwable ignored) {}
                }
            }
            try { ir.close(); } catch (Throwable ignored) {}
            return "ERR:createVirtualDisplay failed: "
                    + (last == null ? "null display" : last.getMessage());
        } catch (Throwable t) {
            return "ERR:" + t.getClass().getSimpleName() + ":" + t.getMessage();
        }
    }

    /**
     * 建虚拟屏：优先走 API 34+ 的 {@code VirtualDisplayConfig}（**不设 packageName**），
     * 回退旧的 6 参重载。
     *
     * ## 为什么必须这样（真机踩坑）
     *
     * 引擎跑在 shell 身份（uid 2000），拿到的 systemContext 的 packageName 是
     * {@code "android"}（uid 1000）。旧的 {@code createVirtualDisplay(name,w,h,dpi,surface,flags)}
     * 内部会用这个 context 的 packageName 做校验：发现 packageName("android") 的 uid(1000)
     * ≠ 调用者 uid(2000)，直接抛 {@code SecurityException: packageName must match the calling uid}。
     *
     * {@code VirtualDisplayConfig} 不 setPackageName 时该字段是 null，校验被跳过 —— 这就是
     * shell 进程里能建屏的正确姿势（Shizuku/aladdin 那类无头方案都要绕这一步）。
     */
    private static VirtualDisplay createVirtualDisplay(
            DisplayManager dm, String name, int w, int h, int dpi,
            android.view.Surface surface, int flags) throws Throwable {
        // ① API 34+：VirtualDisplayConfig（不设 packageName）
        try {
            Class<?> cfgCls = Class.forName("android.hardware.display.VirtualDisplayConfig");
            Class<?> bldCls = Class.forName("android.hardware.display.VirtualDisplayConfig$Builder");
            Object builder = bldCls.getConstructor(String.class, int.class, int.class, int.class)
                    .newInstance(name, w, h, dpi);
            bldCls.getMethod("setSurface", android.view.Surface.class).invoke(builder, surface);
            bldCls.getMethod("setFlags", int.class).invoke(builder, flags);
            Object config = bldCls.getMethod("build").invoke(builder);
            // 单参重载：createVirtualDisplay(VirtualDisplayConfig config)
            java.lang.reflect.Method m = DisplayManager.class.getMethod("createVirtualDisplay", cfgCls);
            Object vd = m.invoke(dm, config);
            if (vd instanceof VirtualDisplay) return (VirtualDisplay) vd;
        } catch (Throwable t) {
            java.io.StringWriter sw = new java.io.StringWriter();
            t.printStackTrace(new java.io.PrintWriter(sw));
            Log.w(TAG, "VirtualDisplayConfig path failed:\n" + sw);
        }
        // ② 旧签名兜底（部分 ROM / API < 34）
        return dm.createVirtualDisplay(name, w, h, dpi, surface, flags);
    }

    private static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    private static int hiddenFlag(String name, int fallback) {
        try {
            return DisplayManager.class.getField(name).getInt(null);
        } catch (Throwable ignored) {
            return fallback;
        }
    }

    /** 让输入法弹在虚拟屏上，而不是主屏（隐藏 API，失败不影响主流程）。 */
    private void applyImePolicy(int dispId) {
        try {
            Object wm = Class.forName("android.view.WindowManagerGlobal")
                    .getMethod("getWindowManagerService").invoke(null);
            java.lang.reflect.Method m = wm.getClass()
                    .getMethod("setDisplayImePolicy", int.class, int.class);
            m.invoke(wm, dispId, 0 /* LOCAL */);
            Log.i(TAG, "ime policy = LOCAL");
        } catch (Throwable t) {
            Log.w(TAG, "ime policy failed (non-fatal): " + t.getMessage());
        }
    }

    /** 唤醒锁（必需，否则主屏息屏时虚拟屏一起睡眠）。 */
    private void acquireWakeLock() {
        try {
            PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
            if (pm == null) return;
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "vd:shell");
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire(30 * 60 * 1000L);
        } catch (Throwable ignored) {
        }
    }

    synchronized String launch(String pkg) {
        if (displayId < 0) return "ERR:display not created";
        if (pkg == null || pkg.isEmpty()) return "ERR:empty package";
        // 先解析 launcher activity，再用 -n 显式启动。
        // 为什么不用 `am start -p <pkg>`：-p 在部分 ROM 的 am 里不是 package，且
        // 抖音这类 launcher 是 splash/alias 的包，用 -p + MAIN/LAUNCHER 会报
        // "unable to resolve Intent"。resolve-activity 拿到的 component 直接喂 -n 最稳。
        String resolved = exec("cmd package resolve-activity --brief "
                + "-a android.intent.action.MAIN -c android.intent.category.LAUNCHER " + pkg);
        String component = null;
        for (String line : resolved.split("\n")) {
            String l = line.trim();
            if (l.contains("/") && l.contains(".")) { component = l; break; }
        }
        if (component == null) return "ERR:resolve failed: " + resolved;
        String out = exec("am start --display " + displayId + " -n " + component + " --user current");
        return out.contains("Error") ? "ERR:" + out : "OK";
    }

    /** 执行 shell 命令，返回 stdout（失败时前面带 ERR:exit=）。 */
    private static String exec(String cmd) {
        try {
            Process p = new ProcessBuilder("sh", "-c", cmd)
                    .redirectErrorStream(true).start();
            StringBuilder sb = new StringBuilder();
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append('\n');
            int code = p.waitFor();
            return code == 0 ? sb.toString().trim() : "ERR:exit=" + code + " " + sb.toString().trim();
        } catch (Throwable t) {
            return "ERR:exec " + t.getMessage();
        }
    }

    synchronized String tap(int x, int y) {
        if (displayId < 0) return "ERR:display not created";
        if (!input.available()) return "ERR:input bridge unavailable";
        try {
            input.tap(displayId, x, y);
            return "OK";
        } catch (Throwable t) {
            return "ERR:" + t.getClass().getSimpleName() + ":" + t.getMessage();
        }
    }

    synchronized String swipe(int x1, int y1, int x2, int y2, int durationMs) {
        if (displayId < 0) return "ERR:display not created";
        if (!input.available()) return "ERR:input bridge unavailable";
        try {
            input.swipe(displayId, x1, y1, x2, y2, durationMs);
            return "OK";
        } catch (Throwable t) {
            return "ERR:" + t.getClass().getSimpleName() + ":" + t.getMessage();
        }
    }

    synchronized String key(int keyCode) {
        if (displayId < 0) return "ERR:display not created";
        if (!input.available()) return "ERR:input bridge unavailable";
        try {
            input.key(displayId, keyCode);
            return "OK";
        } catch (Throwable t) {
            return "ERR:" + t.getClass().getSimpleName() + ":" + t.getMessage();
        }
    }

    synchronized String text(String s) {
        if (displayId < 0) return "ERR:display not created";
        if (!input.available()) return "ERR:input bridge unavailable";
        try {
            input.text(displayId, s);
            return "OK";
        } catch (Throwable t) {
            return "ERR:" + t.getClass().getSimpleName() + ":" + t.getMessage();
        }
    }

    synchronized byte[] capturePng(int timeoutMs) {
        ImageReader ir = reader;
        if (ir == null) return null;
        long deadline = SystemClock.uptimeMillis() + Math.max(100, timeoutMs);
        while (SystemClock.uptimeMillis() < deadline) {
            Image image = null;
            try {
                image = ir.acquireLatestImage();
            } catch (Throwable ignored) {
            }
            if (image != null) {
                try {
                    Image.Plane plane = image.getPlanes()[0];
                    int rowStride = plane.getRowStride();
                    int pixelStride = plane.getPixelStride();
                    int rowPadding = rowStride - pixelStride * image.getWidth();
                    Bitmap bmp = Bitmap.createBitmap(image.getWidth() + rowPadding / pixelStride,
                            image.getHeight(), Bitmap.Config.ARGB_8888);
                    bmp.copyPixelsFromBuffer(plane.getBuffer());
                    Bitmap cropped = Bitmap.createBitmap(bmp, 0, 0,
                            image.getWidth(), image.getHeight());
                    ByteArrayOutputStream bos = new ByteArrayOutputStream();
                    cropped.compress(Bitmap.CompressFormat.PNG, 100, bos);
                    Bitmap b1 = bmp, b2 = cropped;
                    b1.recycle();
                    b2.recycle();
                    return bos.toByteArray();
                } catch (Throwable t) {
                    Log.w(TAG, "capture failed: " + t.getMessage());
                } finally {
                    try { image.close(); } catch (Throwable ignored) {}
                }
            }
            SystemClock.sleep(50);
        }
        return null;
    }

    synchronized String release() {
        try { if (vd != null) vd.release(); } catch (Throwable ignored) {}
        vd = null;
        try { if (reader != null) reader.close(); } catch (Throwable ignored) {}
        reader = null;
        try {
            if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        } catch (Throwable ignored) {}
        wakeLock = null;
        displayId = -1;
        return "OK";
    }
}
