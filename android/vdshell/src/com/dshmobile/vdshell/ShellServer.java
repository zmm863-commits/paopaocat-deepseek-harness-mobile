package com.dshmobile.vdshell;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ResolveInfo;
import android.os.Binder;
import android.os.Bundle;
import android.os.Looper;
import android.os.Parcel;
import android.util.Log;

import java.io.File;
import java.io.FileWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * 免装 Shizuku 的引擎入口：由 adb shell 用 {@code app_process} 拉起，
 * 跑在 **shell 身份（uid 2000）** 里。
 *
 * 起来之后做两件事：
 *  1. 反射 {@code ServiceManager.addService()} 注册一个系统级 binder（首选通道）；
 *  2. 无论 addService 成不成，都把 binder **通过广播回传**给 App —— 这是兜底通道，
 *     也是 Android 12+ 上更稳的那条（广播里可以塞 IBinder）。
 *
 * 启动命令（App 侧 AdbShellClient 发下去的那条）：
 * <pre>
 * CLASSPATH=/data/local/tmp/vdshell.dex app_process / com.dshmobile.vdshell.ShellServer
 * </pre>
 */
public final class ShellServer {
    private static final String TAG = "VdShell";

    private ShellServer() {}

    public static void main(String[] args) {
        log("ShellServer starting, version=" + EngineProtocol.SERVICE_VERSION);
        prepareMainLooper();

        Context ctx = systemContext();
        if (ctx == null) {
            log("FATAL: no Context in shell process");
            return;
        }
        log("context acquired: " + ctx.getPackageName());

        DisplayEngine engine = new DisplayEngine(ctx);
        Svc svc = new Svc(engine);

        boolean added = tryAddService(svc);
        log("addService(" + EngineProtocol.SERVICE_NAME + ") = " + added);

        broadcastBinder(ctx, svc);

        // 保活：不退出进程（binder 与广播两条通道都已建立）
        while (true) {
            try {
                Thread.sleep(3600_000L);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        log("ShellServer exited");
    }

    // ── 环境 ────────────────────────────────────────────────────────────────

    /** app_process 里没有现成的 main Looper —— 照 Shizuku/aladdin 的做法手工造一个。 */
    private static void prepareMainLooper() {
        try {
            if (Looper.myLooper() != null) return;
            try {
                // prepareMainLooper 是 @hide → 只能反射
                Method m = Looper.class.getDeclaredMethod("prepareMainLooper");
                m.setAccessible(true);
                m.invoke(null);
                return;
            } catch (Throwable ignored) {
                // 隐藏 API 在某些 ROM 上不可调 → 退回 prepare + 反射补 sMainLooper
            }
            Looper.prepare();
            try {
                Field f = Looper.class.getDeclaredField("sMainLooper");
                f.setAccessible(true);
                f.set(null, Looper.myLooper());
            } catch (Throwable t) {
                log("set sMainLooper failed: " + t.getMessage());
            }
        } catch (Throwable t) {
            log("prepareMainLooper failed: " + t.getMessage());
        }
    }

    /** 从 ActivityThread 拿系统 Context（这是 shell 进程里唯一能用的 Context）。 */
    private static Context systemContext() {
        // ① systemMain()：会顺带初始化 Looper/Application 相关的静态字段
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Method systemMain = at.getDeclaredMethod("systemMain");
            systemMain.setAccessible(true);
            Object thread = systemMain.invoke(null);
            Object ctx = at.getDeclaredMethod("getSystemContext").invoke(thread);
            if (ctx instanceof Context) return (Context) ctx;
        } catch (Throwable t) {
            log("systemMain context failed: " + t.getMessage());
        }
        // ② currentActivityThread()
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Method cur = at.getDeclaredMethod("currentActivityThread");
            cur.setAccessible(true);
            Object thread = cur.invoke(null);
            if (thread == null) {
                Method systemMain = at.getDeclaredMethod("systemMain");
                systemMain.setAccessible(true);
                thread = systemMain.invoke(null);
            }
            if (thread != null) {
                Object ctx = at.getDeclaredMethod("getSystemContext").invoke(thread);
                if (ctx instanceof Context) return (Context) ctx;
            }
        } catch (Throwable t) {
            log("currentActivityThread context failed: " + t.getMessage());
        }
        return null;
    }

    /** 反射注册系统级 binder（只有 shell/root 才做得到；失败就走广播）。 */
    private static boolean tryAddService(Svc svc) {
        try {
            Class<?> sm = Class.forName("android.os.ServiceManager");
            try {
                Method m = sm.getDeclaredMethod("addService", String.class, android.os.IBinder.class, boolean.class);
                m.setAccessible(true);
                m.invoke(null, EngineProtocol.SERVICE_NAME, svc, Boolean.TRUE);
                return true;
            } catch (NoSuchMethodException ignored) {
                Method m = sm.getDeclaredMethod("addService", String.class, android.os.IBinder.class,
                        boolean.class, int.class);
                m.setAccessible(true);
                m.invoke(null, EngineProtocol.SERVICE_NAME, svc, Boolean.TRUE, 0);
                return true;
            }
        } catch (Throwable t) {
            log("addService failed (will use broadcast): " + t.getMessage());
            return false;
        }
    }

    /** 把 binder 塞进广播回传给 App（显式 component，避开 Android 12+ 隐式广播限制）。 */
    private static void broadcastBinder(Context ctx, Svc svc) {
        try {
            Intent intent = new Intent(EngineProtocol.ACTION_BINDER_READY);
            Bundle b = new Bundle();
            b.putBinder(EngineProtocol.EXTRA_BINDER, svc);
            intent.putExtras(b);
            List<ResolveInfo> receivers = null;
            try {
                receivers = ctx.getPackageManager().queryBroadcastReceivers(intent, 0);
            } catch (Throwable t) {
                log("queryBroadcastReceivers failed: " + t.getMessage());
            }
            if (receivers != null && !receivers.isEmpty()) {
                for (ResolveInfo ri : receivers) {
                    ActivityInfo ai = ri.activityInfo;
                    if (ai == null) continue;
                    Intent explicit = new Intent(intent);
                    explicit.setComponent(new ComponentName(ai.packageName, ai.name));
                    ctx.sendBroadcast(explicit);
                    log("binder broadcast -> " + ai.packageName + "/" + ai.name);
                }
                return;
            }
            ctx.sendBroadcast(intent);
            log("binder broadcast (implicit, no receiver resolved)");
        } catch (Throwable t) {
            log("broadcastBinder failed: " + t.getMessage());
        }
    }

    // ── 日志 ────────────────────────────────────────────────────────────────

    private static final SimpleDateFormat FMT =
            new SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US);

    static synchronized void log(String msg) {
        Log.i(TAG, msg);
        try {
            File f = new File(EngineProtocol.LOG_PATH);
            if (f.length() > 512 * 1024) {
                // 超过 512 KB 就重开（避免把 /data/local/tmp 写满）
                //noinspection ResultOfMethodCallIgnored
                f.delete();
            }
            FileWriter w = new FileWriter(f, true);
            try {
                w.write(FMT.format(new Date()) + " " + msg + "\n");
            } finally {
                w.close();
            }
        } catch (Throwable ignored) {
        }
    }

    // ── Binder 服务实现 ─────────────────────────────────────────────────────

    static final class Svc extends Binder {
        private final DisplayEngine engine;

        Svc(DisplayEngine engine) {
            this.engine = engine;
            attachInterface(null, "com.dshmobile.vdshell.IShellEngine");
        }

        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
            Parcel out = reply;
            if (out == null) return false;
            try {
                switch (code) {
                    case EngineProtocol.CMD_STATUS:
                        out.writeString(engine.status());
                        break;
                    case EngineProtocol.CMD_CREATE: {
                        int w = data.readInt();
                        int h = data.readInt();
                        int dpi = data.readInt();
                        log("create " + w + "x" + h + "@" + dpi);
                        out.writeString(engine.create(w, h, dpi));
                        break;
                    }
                    case EngineProtocol.CMD_RELEASE:
                        out.writeString(engine.release());
                        break;
                    case EngineProtocol.CMD_LAUNCH: {
                        String pkg = data.readString();
                        log("launch " + pkg);
                        out.writeString(engine.launch(pkg));
                        break;
                    }
                    case EngineProtocol.CMD_TAP: {
                        int x = data.readInt();
                        int y = data.readInt();
                        out.writeString(engine.tap(x, y));
                        break;
                    }
                    case EngineProtocol.CMD_SWIPE: {
                        int x1 = data.readInt();
                        int y1 = data.readInt();
                        int x2 = data.readInt();
                        int y2 = data.readInt();
                        int d = data.readInt();
                        out.writeString(engine.swipe(x1, y1, x2, y2, d));
                        break;
                    }
                    case EngineProtocol.CMD_KEY:
                        out.writeString(engine.key(data.readInt()));
                        break;
                    case EngineProtocol.CMD_TEXT:
                        out.writeString(engine.text(data.readString()));
                        break;
                    case EngineProtocol.CMD_CAPTURE: {
                        int timeout = data.readInt();
                        data.readInt(); // 保留位
                        byte[] png = engine.capturePng(timeout);
                        out.writeInt(png != null ? 1 : 0);
                        out.writeString(png != null ? "" : "no frame");
                        out.writeByteArray(png != null ? png : new byte[0]);
                        break;
                    }
                    case EngineProtocol.CMD_SHUTDOWN:
                        out.writeString(engine.release());
                        log("shutdown requested");
                        new Thread(new Runnable() {
                            @Override
                            public void run() {
                                try { Thread.sleep(200); } catch (InterruptedException ignored) {}
                                System.exit(0);
                            }
                        }).start();
                        break;
                    default:
                        out.writeString("ERR:unknown code " + code);
                        break;
                }
                return true;
            } catch (Throwable t) {
                log("transact " + code + " failed: " + t);
                try {
                    out.writeString("ERR:" + t.getClass().getSimpleName() + ":" + t.getMessage());
                } catch (Throwable ignored) {
                }
                return true;
            }
        }
    }
}
