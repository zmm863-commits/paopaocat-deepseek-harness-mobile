package com.dshmobile.dsh_mobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * 屏幕助手「无头模式」的虚拟屏生命周期，跑在 shell 进程内。
 *
 * 核心三件事：
 *  1. `DisplayManager.createVirtualDisplay()` 建一块**看不见**的屏；
 *  2. `am start --display <id>` 把目标 App 拉到这块屏上；
 *  3. 触摸/按键通过 [InputBridge] **定向**打进这块屏。
 */
class DisplayEngine(private val context: Context) {

    private var vd: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var displayId: Int = -1
    private var wakeLock: PowerManager.WakeLock? = null
    private val input = InputBridge(context)

    fun status(): String =
        if (displayId >= 0) "OK:display=$displayId" else "OK:idle"

    fun create(w: Int, h: Int, dpi: Int): String {
        release()   // 幂等：先释放旧屏

        val width = w.coerceIn(320, 2160)
        val height = h.coerceIn(480, 3840)
        val density = dpi.coerceIn(120, 640)

        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val ir = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
        val surface = ir.surface

        // ---- flags 必须逐级降级：不同 ROM 会拒绝不同 flag ----
        val PUBLIC = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC            // 1
        val PRESENTATION = DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION // 2
        val OWN_CONTENT = DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY // 8
        val base = PUBLIC or PRESENTATION or OWN_CONTENT

        val TOUCH = hiddenFlag("VIRTUAL_DISPLAY_FLAG_SUPPORTS_TOUCH", 1 shl 6)   // 64
        val FOCUS = hiddenFlag("VIRTUAL_DISPLAY_FLAG_OWN_FOCUS", 1 shl 14)       // 16384
        val TRUST = hiddenFlag("VIRTUAL_DISPLAY_FLAG_TRUSTED", 1 shl 10)         // 1024

        val candidates = intArrayOf(
            base or TOUCH or FOCUS or TRUST,
            base or TOUCH or FOCUS,
            base or TOUCH,
            base
        )

        var lastError: Throwable? = null
        for (flagsAttempt in candidates) {
            var created: VirtualDisplay? = null
            try {
                created = dm.createVirtualDisplay(
                    "vd-engine", width, height, density, surface, flagsAttempt
                )
                val d = created?.display
                if (d != null) {
                    vd = created
                    reader = ir
                    displayId = d.displayId
                    applyImePolicy(displayId)
                    acquireWakeLock()
                    Log.i(TAG, "display created id=$displayId flags=0x${flagsAttempt.toString(16)}")
                    return "OK:$displayId"
                }
            } catch (e: Throwable) {
                lastError = e
            }
            runCatching { created?.release() }
        }

        ir.close()
        return "ERR:createVirtualDisplay failed: ${lastError?.message ?: "null display"}"
    }

    private fun hiddenFlag(name: String, fallback: Int): Int = try {
        DisplayManager::class.java.getField(name).getInt(null)
    } catch (_: Throwable) { fallback }

    /** 让输入法弹在虚拟屏上，而不是主屏（隐藏 API，失败不影响主流程）。 */
    private fun applyImePolicy(dispId: Int) {
        try {
            val wm = Class.forName("android.view.WindowManagerGlobal")
                .getMethod("getWindowManagerService").invoke(null)
            val m = wm.javaClass.getMethod("setDisplayImePolicy", Int::class.java, Int::class.java)
            m.invoke(wm, dispId, 0 /* LOCAL */)
            Log.i(TAG, "ime policy = LOCAL")
        } catch (e: Throwable) {
            Log.w(TAG, "ime policy failed (non-fatal): ${e.message}")
        }
    }

    /** 唤醒锁（必需，否则主屏息屏时虚拟屏一起睡眠）。 */
    private fun acquireWakeLock() {
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "vd:engine").apply {
                setReferenceCounted(false)
                acquire(10 * 60 * 1000L)   // 最长 10 分钟，按需调整
            }
        } catch (_: Throwable) { }
    }

    fun launch(pkg: String): String {
        val id = displayId
        if (id < 0) return "ERR:display not created"

        // shell 进程可以直接 exec am，最稳、兼容性最好
        val cmd = buildString {
            append("am start --display ").append(id)
            append(" -a android.intent.action.MAIN")
            append(" -c android.intent.category.LAUNCHER")
            append(" -p ").append(pkg)
            append(" --user current")
        }
        return exec(cmd)
    }

    private fun exec(cmd: String): String = try {
        val p = ProcessBuilder("sh", "-c", cmd)
            .redirectErrorStream(true)
            .start()
        val out = p.inputStream.bufferedReader().readText()
        val code = p.waitFor()
        if (code == 0) "OK" else "ERR:exit=$code $out"
    } catch (e: Throwable) {
        "ERR:exec ${e.message}"
    }

    fun tap(x: Int, y: Int): String {
        val id = displayId
        if (id < 0) return "ERR:display not created"
        if (!input.available()) return "ERR:input bridge unavailable"
        input.tap(id, x.toFloat(), y.toFloat())
        return "OK"
    }

    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int): String {
        val id = displayId
        if (id < 0) return "ERR:display not created"
        if (!input.available()) return "ERR:input bridge unavailable"
        input.swipe(id, x1.toFloat(), y1.toFloat(), x2.toFloat(), y2.toFloat(), durationMs)
        return "OK"
    }

    fun key(keyCode: Int): String {
        val id = displayId
        if (id < 0) return "ERR:display not created"
        if (!input.available()) return "ERR:input bridge unavailable"
        input.key(id, keyCode)
        return "OK"
    }

    fun text(s: String): String {
        val id = displayId
        if (id < 0) return "ERR:display not created"
        if (!input.available()) return "ERR:input bridge unavailable"
        input.text(id, s)
        return "OK"
    }

    fun captureJpeg(timeoutMs: Int, quality: Int): ByteArray? {
        val ir = reader ?: return null
        val deadline = SystemClock.uptimeMillis() + timeoutMs.coerceAtLeast(100)
        while (SystemClock.uptimeMillis() < deadline) {
            val image = try { ir.acquireLatestImage() } catch (_: Throwable) { null }
            if (image != null) {
                image.use {
                    val plane = it.planes[0]
                    val rowStride = plane.rowStride
                    val pixelStride = plane.pixelStride
                    val rowPadding = rowStride - pixelStride * it.width
                    val bmp = Bitmap.createBitmap(
                        it.width + rowPadding / pixelStride, it.height, Bitmap.Config.ARGB_8888
                    )
                    bmp.copyPixelsFromBuffer(plane.buffer)
                    val cropped = Bitmap.createBitmap(bmp, 0, 0, it.width, it.height)
                    return ByteArrayOutputStream().use { bos ->
                        cropped.compress(Bitmap.CompressFormat.JPEG, quality, bos)
                        bos.toByteArray()
                    }
                }
            }
            SystemClock.sleep(50)
        }
        return null
    }

    fun release(): String {
        runCatching { vd?.release() }
        vd = null
        runCatching { reader?.close() }
        reader = null
        runCatching { if (wakeLock?.isHeld == true) wakeLock?.release() }
        wakeLock = null
        displayId = -1
        return "OK"
    }

    companion object { private const val TAG = "VdEngine" }
}
