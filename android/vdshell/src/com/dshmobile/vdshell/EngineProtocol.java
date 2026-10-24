package com.dshmobile.vdshell;

/**
 * 免装 Shizuku 的「引擎 dex」协议常量。
 *
 * 这份代码会被 d8 编成 {@code vdshell.dex}，由 adb shell 用
 * {@code app_process} 起在 shell 身份（uid 2000）里 —— 所以它**不能依赖 Flutter/AndroidX**，
 * 只用 android.jar 里的系统 API。
 *
 * 与 App 侧的 {@code EngineProtocol.kt} 必须逐位一致（transact code / 返回值约定）。
 */
public final class EngineProtocol {
    private EngineProtocol() {}

    /** 改了服务端接口就要 +1（App 侧用它判断 dex 是否需要更新）。 */
    public static final int SERVICE_VERSION = 2;

    /** 广播 action：shell 进程把 binder 回传给 App。 */
    public static final String ACTION_BINDER_READY = "com.dshmobile.vdshell.BINDER_READY";

    /** 广播 extra：Binder 本体（Bundle.putBinder）。 */
    public static final String EXTRA_BINDER = "binder";

    /** 注册到 ServiceManager 的服务名（仅 addService 成功时存在）。 */
    public static final String SERVICE_NAME = "dshmobile.vdshell";

    /** dex 在设备上的落点（由 App 侧 cp 过去）。 */
    public static final String REMOTE_DEX = "/data/local/tmp/vdshell.dex";

    /** 日志落点（排障用；不在 data/local/tmp 里放太多东西）。 */
    public static final String LOG_PATH = "/data/local/tmp/vdshell.log";

    // ---- transact code：与 App 侧 EngineProtocol.kt 一一对应 ----
    public static final int CMD_STATUS = 1;
    public static final int CMD_CREATE = 2;
    public static final int CMD_RELEASE = 3;
    public static final int CMD_LAUNCH = 4;
    public static final int CMD_TAP = 5;
    public static final int CMD_SWIPE = 6;
    public static final int CMD_KEY = 7;
    public static final int CMD_TEXT = 8;
    /** 返回 int ok, String err, byte[] png。 */
    public static final int CMD_CAPTURE = 9;
    public static final int CMD_SHUTDOWN = 10;
}
