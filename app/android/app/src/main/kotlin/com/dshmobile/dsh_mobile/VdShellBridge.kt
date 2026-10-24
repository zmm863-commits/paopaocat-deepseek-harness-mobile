package com.dshmobile.dsh_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.Parcel
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 免装 Shizuku 那条路的「App 侧」：持有 shell 进程回传的 binder，发 transact 命令。
 *
 * ## 通道
 *
 * shell 进程（[com.dshmobile.vdshell.ShellServer]，跑在 uid 2000）起来后会：
 *  1. 试着反射 `ServiceManager.addService` 注册系统级 binder；
 *  2. 无论成不成，都按 manifest 里的 [VdShellReceiver] **显式投递**一条广播，
 *     把 binder 装进 Bundle 带回来。
 *
 * 第 2 条是主力通道：普通 App 读不到别的进程注册的 ServiceManager 条目（SELinux），
 * 但广播里传 IBinder 是允许的 —— Shizuku 时代的 aladdin 也是这么干的。
 */
object VdShell {
    const val ACTION_BINDER_READY = "com.dshmobile.vdshell.BINDER_READY"
    const val EXTRA_BINDER = "binder"
    private const val TAG = "VdShellAdb"

    @Volatile
    var binder: IBinder? = null
        private set

    @Volatile
    private var waiter: CountDownLatch? = null

    /** 广播到达时调用（由 [VdShellReceiver] 触发）。 */
    fun onBinder(b: IBinder) {
        binder = b
        waiter?.countDown()
        Log.i(TAG, "shell binder received from broadcast")
    }

    fun prepareWait() {
        binder = null
        waiter = CountDownLatch(1)
    }

    fun awaitBinder(timeoutMs: Long): Boolean {
        val latch = waiter ?: return false
        val ok = try {
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        return ok && binder?.pingBinder() == true
    }

    fun isAlive(): Boolean = try {
        binder?.pingBinder() == true
    } catch (e: Throwable) {
        false
    }

    fun call(code: Int, write: ((Parcel) -> Unit)? = null): String {
        val b = binder ?: return "ERR:no binder"
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            write?.invoke(data)
            b.transact(code, data, reply, 0)
            reply.readString() ?: "ERR:empty reply"
        } catch (e: Throwable) {
            "ERR:${e.javaClass.simpleName}:${e.message}"
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    fun capture(timeoutMs: Int = 800): ByteArray? {
        val b = binder ?: return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInt(timeoutMs)
            data.writeInt(0)
            b.transact(EngineProtocol.CMD_CAPTURE, data, reply, 0)
            val ok = reply.readInt()
            val err = reply.readString()
            val bytes = reply.createByteArray()
            if (ok == 1) bytes else {
                Log.w(TAG, "capture failed: $err")
                null
            }
        } catch (e: Throwable) {
            Log.w(TAG, "capture error: ${e.message}")
            null
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    fun detached() {
        binder = null
    }
}

/**
 * 接 shell 进程投递的 binder。
 *
 * ⚠️ 必须写在 **manifest** 里（静态注册）：shell 进程 `sendBroadcast` 时 App 可能
 * 还没起，动态注册的 receiver 收不到。
 */
class VdShellReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent == null) return
        if (intent.action != VdShell.ACTION_BINDER_READY) return
        val b = try {
            intent.extras?.getBinder(VdShell.EXTRA_BINDER)
        } catch (e: Throwable) {
            Log.w("VdShellAdb", "getBinder failed: ${e.message}")
            null
        }
        if (b != null) VdShell.onBinder(b)
    }
}

/** 状态快照（给 Flutter 用）。 */
data class VdShellStatus(
    val binderAlive: Boolean,
    val dexVersion: Int,
    val canRun: Boolean,
)

/**
 * 免装 Shizuku 的总编排：配对 → 连接 → 部署 dex → 起进程 → 等 binder。
 *
 * 全部是阻塞操作，调用方（MainActivity 的 MethodChannel）必须放到后台线程。
 */
object VdShellManager {
    private const val TAG = "VdShellAdb"

    @Volatile
    private var client: VdShellClient? = null

    @Volatile
    var lastError: String = ""
        private set

    fun status(): Map<String, Any> = mapOf(
        "binderAlive" to VdShell.isAlive(),
        "dexVersion" to 2,
        "error" to lastError,
    )

    fun stop() {
        try {
            if (VdShell.isAlive()) VdShell.call(10 /* CMD_SHUTDOWN */)
        } catch (_: Throwable) {
        }
        VdShell.detached()
    }

    /** 配对（code 6 位；port 为 null 时自动 mDNS 发现）。 */
    @Synchronized
    fun pair(context: Context, code: String, port: Int?): Boolean {
        val c = ensureClient(context) ?: return false
        val ok = c.pair(code, port)
        lastError = if (ok) "" else "配对失败（配对码/端口不对，或无线调试已关闭）"
        return ok
    }

    /**
     * 配对成功之后的一步式启动：连接 → 部署 dex → 起 shell 进程 → 等 binder。
     *
     * @return 成功与否；失败原因放 [lastError]
     */
    @Synchronized
    fun bootstrap(context: Context, waitMs: Long = 20_000): Boolean {
        val c = ensureClient(context) ?: return false
        if (!c.connectDevice()) {
            lastError = "连不上 adbd（先配对，再确认「无线调试」还开着）"
            return false
        }
        VdShell.prepareWait()
        val out = try {
            c.deployAndStart()
        } catch (e: Throwable) {
            lastError = "部署失败：${e.message}"
            return false
        }
        Log.i(TAG, "deploy output=${out.take(300)}")
        if (!VdShell.awaitBinder(waitMs)) {
            val shellLog = try {
                c.shell("tail -n 40 /data/local/tmp/vdshell.log 2>/dev/null", 6000)
            } catch (e: Throwable) {
                ""
            }
            lastError = "引擎没起来（日志：${shellLog.take(400).ifBlank { "空" }}）"
            return false
        }
        lastError = ""
        return true
    }

    /** 连上 adbd 后跑任意调试命令（排障用）。 */
    @Synchronized
    fun debugShell(context: Context, command: String): String {
        val c = ensureClient(context) ?: return "ERR:no client"
        if (!c.connectDevice()) return "ERR:connect failed"
        return c.shell(command, 12_000)
    }

    private fun ensureClient(context: Context): VdShellClient? = try {
        client ?: VdShellClient(context.applicationContext).also { client = it }
    } catch (e: Throwable) {
        lastError = "adb 客户端初始化失败：${e.message}"
        Log.e(TAG, "ensureClient failed", e)
        null
    }
}
