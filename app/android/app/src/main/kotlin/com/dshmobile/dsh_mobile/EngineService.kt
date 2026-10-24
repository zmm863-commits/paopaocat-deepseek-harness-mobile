package com.dshmobile.dsh_mobile

import android.content.Context
import android.os.Binder
import android.os.Parcel

/**
 * 屏幕助手「无头模式」的 UserService 入口，跑在 Shizuku 拉起的 shell 进程里。
 *
 * Shizuku 按类名反射实例化它，所以：
 *   · 必须 `extends Binder`（UserService 硬性要求）；
 *   · 必须有 (Context) 或 () 构造（两个都写最稳）；
 *   · 不能是 internal / 不能被 R8 改名（见 proguard-rules.pro 的 keep）。
 */
class EngineService : Binder {

    constructor() : super()

    constructor(context: Context) : super() {
        appContext = context.applicationContext ?: context
    }

    @Volatile
    private var appContext: Context? = null

    private val engine by lazy { DisplayEngine(appContext ?: resolveContext()) }

    private fun resolveContext(): Context {
        return try {
            val at = Class.forName("android.app.ActivityThread")
            val m = at.getMethod("currentApplication")
            m.invoke(null) as Context
        } catch (e: Throwable) {
            throw IllegalStateException("no Context in shell service", e)
        }
    }

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
        val out = reply ?: return false
        if (code !in 1..10) return super.onTransact(code, data, out, flags)
        return try {
            when (code) {
                EngineProtocol.CMD_STATUS -> out.writeString(engine.status())
                EngineProtocol.CMD_CREATE -> {
                    val w = data.readInt(); val h = data.readInt(); val dpi = data.readInt()
                    out.writeString(engine.create(w, h, dpi))
                }
                EngineProtocol.CMD_RELEASE -> out.writeString(engine.release())
                EngineProtocol.CMD_LAUNCH -> {
                    val pkg = data.readString() ?: ""
                    out.writeString(engine.launch(pkg))
                }
                EngineProtocol.CMD_TAP -> {
                    val x = data.readInt(); val y = data.readInt()
                    out.writeString(engine.tap(x, y))
                }
                EngineProtocol.CMD_SWIPE -> {
                    val x1 = data.readInt(); val y1 = data.readInt()
                    val x2 = data.readInt(); val y2 = data.readInt()
                    val d = data.readInt()
                    out.writeString(engine.swipe(x1, y1, x2, y2, d))
                }
                EngineProtocol.CMD_KEY -> {
                    out.writeString(engine.key(data.readInt()))
                }
                EngineProtocol.CMD_TEXT -> {
                    out.writeString(engine.text(data.readString() ?: ""))
                }
                EngineProtocol.CMD_CAPTURE -> {
                    val timeout = data.readInt(); val q = data.readInt()
                    val jpeg = engine.captureJpeg(timeout, q)
                    out.writeInt(if (jpeg != null) 1 else 0)
                    out.writeString(if (jpeg != null) "" else "no frame")
                    out.writeByteArray(jpeg ?: ByteArray(0))
                }
                EngineProtocol.CMD_SHUTDOWN -> {
                    engine.release()
                    out.writeString("OK")
                    // 延迟退出，确保 reply 已写回
                    Thread { Thread.sleep(200); System.exit(0) }.start()
                }
                else -> out.writeString("ERR:unknown code $code")
            }
            true
        } catch (e: Throwable) {
            runCatching { out.writeString("ERR:${e.javaClass.simpleName}:${e.message}") }
            true
        }
    }
}
