package com.dshmobile.dsh_mobile

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Parcel
import android.util.Log
import rikka.shizuku.Shizuku

/**
 * 屏幕助手「无头模式」的 App 进程侧客户端：申请权限、绑定 UserService、发 Binder 命令。
 *
 * 只在 App 进程使用；真正的虚拟屏/注入跑在 Shizuku 拉起的 shell 进程里（见 EngineService）。
 */
class ShizukuEngineClient(private val context: Context) {

    @Volatile
    private var binder: IBinder? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            binder = service
            Log.i(TAG, "shell service connected")
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            binder = null
        }
    }

    private val args = Shizuku.UserServiceArgs(
        ComponentName(context, EngineService::class.java)
    )
        .processNameSuffix("shell")
        .tag(EngineProtocol.SERVICE_TAG)
        .version(EngineProtocol.SERVICE_VERSION)   // ⚠ 必须单调递增
        .daemon(false)
        .debuggable(BuildConfig.DEBUG)

    fun bind() {
        if (!hasPermission()) return
        if (binder?.pingBinder() == true) return
        Shizuku.bindUserService(args, connection)
    }

    fun unbind() {
        runCatching { Shizuku.unbindUserService(args, connection, true) }
        binder = null
    }

    fun isConnected(): Boolean = binder?.pingBinder() == true

    /** 弹 Shizuku 授权框（requestCode 要和 addRequestPermissionResultListener 对齐）。 */
    fun requestPermission(requestCode: Int = 4451) {
        try { Shizuku.requestPermission(requestCode) } catch (_: Throwable) {}
    }

    fun hasPermission(): Boolean = try {
        Shizuku.checkSelfPermission() == android.content.pm.PackageManager.PERMISSION_GRANTED
    } catch (_: Throwable) { false }

    /** 发一条普通命令，返回 "OK" 或 "ERR:..." */
    fun call(code: Int, write: ((Parcel) -> Unit)? = null): String {
        val b = binder ?: return "ERR:not connected"
        val data = Parcel.obtain(); val reply = Parcel.obtain()
        return try {
            write?.invoke(data)
            b.transact(code, data, reply, 0)
            reply.readString() ?: "ERR:empty reply"
        } catch (e: Throwable) {
            "ERR:${e.javaClass.simpleName}:${e.message}"
        } finally {
            data.recycle(); reply.recycle()
        }
    }

    /** 截图命令：int ok, String err, byte[] png */
    fun capture(timeoutMs: Int = 800): ByteArray? {
        val b = binder ?: return null
        val data = Parcel.obtain(); val reply = Parcel.obtain()
        return try {
            data.writeInt(timeoutMs); data.writeInt(0)
            b.transact(EngineProtocol.CMD_CAPTURE, data, reply, 0)
            val ok = reply.readInt()
            val err = reply.readString()
            val bytes = reply.createByteArray()
            if (ok == 1) bytes else { Log.w(TAG, "capture failed: $err"); null }
        } catch (e: Throwable) {
            null
        } finally { data.recycle(); reply.recycle() }
    }

    companion object { private const val TAG = "VdEngine" }
}
