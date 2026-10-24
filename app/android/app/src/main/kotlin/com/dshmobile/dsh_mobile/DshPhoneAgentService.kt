package com.dshmobile.dsh_mobile

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.Path
import android.os.Build
import android.util.Base64
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 「手机界面操作」的无障碍服务 —— **探针版**。
 *
 * ## 它做什么
 *
 * 让 DSH 的 Agent 能像人一样"看屏幕、点屏幕"：
 *   * 截图：把**当前屏幕**（可以是别的 App）抓成 PNG；
 *   * 点击 / 滑动：用手势模拟；
 *   * 节点树：把界面控件（文本 / 类型 / 坐标）导出成 JSON。
 *
 * ## 为什么用无障碍而不是别的
 *
 * * `AccessibilityService.takeScreenshot()`（**API 30+**）抓**别的 App** 的屏幕，
 *   **不需要每次弹窗授权**（MediaProjection 每次都要用户点"开始录制"）；
 * * `dispatchGesture()`（API 24+）能在任何 App 上点击/滑动，
 *   不依赖目标 App 暴露控件（剪映这类自绘界面节点树是空的，但手势照样能点）。
 *
 * ## 与其它部分的关系
 *
 * 本服务**不直接对外**。它挂在 [PhoneAgentBridge]（一个 127.0.0.1 上的小 HTTP 服务）后面，
 * 由 Node 侧（DSH 插件）调用 —— 桥只在本机 loopback，不走网络。
 *
 * ## 生命周期坑（实测要点）
 *
 * * 服务是**被系统按需绑定**的：App 进程活着 ≠ 服务已连上。
 *   必须等 [onServiceConnected] 才算可用；连上之前桥要如实报 "not connected"。
 * * 用户可以在系统设置里随时关掉它 → 要能查当前是否还连着。
 */
class DshPhoneAgentService : AccessibilityService() {

    companion object {
        private const val TAG = "DshPhoneAgent"

        /**
         * 当前连着的服务实例（没连上是 null）。
         *
         * ⚠️ **必须在 companion object 里** —— 写在类体里就成了"每个实例一份"，
         * 外部 `DshPhoneAgentService.instance` 会直接编译不过
         * （2026-10-22 第一次编译就踩了这个：报了一串
         * "Unresolved reference 'instance'/'screenshotBase64'/'tap'…"，真因只是这一处）。
         */
        @Volatile
        var instance: DshPhoneAgentService? = null
            private set
    }

    /** 被桥查询"服务是否可用"。 */
    val isReady: Boolean get() = instance != null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        // 明确要节点树（不然很多 App 的节点信息拿不到）。
        try {
            serviceInfo = serviceInfo.apply {
                flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                    AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
        } catch (e: Throwable) {
            Log.w(TAG, "设置 flags 失败：${e.message}")
        }
        Log.i(TAG, "无障碍服务已连接")
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 探针阶段不需要监听事件；留着是因为系统要求实现。
    }

    override fun onInterrupt() {
    }

    // ── 截图 ────────────────────────────────────────────────────────────

    /**
     * 抓当前屏幕（PNG 的 base64）。
     *
     * ⚠️ `takeScreenshot` 是 **API 30+**；低版本返回 null，由调用方如实告诉用户"这台机不支持"。
     * ⚠️ 截图失败最常见原因是**没有前台 App**（自己在后台时截不到别的 App），
     *    以及 `FLAG_SECURE` 的页面（银行等）会返回黑图 —— 这两种都要如实说，不能假装成功。
     */
    fun screenshotBase64(timeoutMs: Long = 6000): String? {
        // `Bitmap.wrapHardwareBuffer` 是 API 33+；30~32 没有公开的取像素途径，
        // 如实返回 null（调用方会告诉用户"这台机不支持"），不做假图。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        val bmp = takeBitmap(timeoutMs) ?: return null
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        bmp.recycle()
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    /**
     * 抓当前屏幕。
     *
     * ⚠️ `AccessibilityService.takeScreenshot` 的**真实签名是异步的**：
     * `takeScreenshot(displayId, executor, TakeScreenshotCallback)` ——
     * 它**不返回 Bitmap**，结果在回调里给。所以这里用 CountDownLatch 等回调，
     * 超时就当作失败（**如实返回 null，不假装成功**）。
     */
    /** 抓当前屏幕的 Bitmap（给 OCR 用）。失败如实返回 null。 */
    fun screenshotBitmap(timeoutMs: Long = 6000): Bitmap? = takeBitmap(timeoutMs)

    private fun takeBitmap(timeoutMs: Long): Bitmap? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        val latch = CountDownLatch(1)
        var bitmap: Bitmap? = null
        try {
            takeScreenshot(
                Display.DEFAULT_DISPLAY,
                mainExecutor,
                object : AccessibilityService.TakeScreenshotCallback {
                    override fun onSuccess(screenshot: AccessibilityService.ScreenshotResult) {
                        try {
                            // ⚠️ 这里踩过两个坑，都记下来：
                            //  ① `getHardwareBuffer()` 返回的是 **android.hardware.HardwareBuffer**
                            //     （公开 API），**不是** android.graphics.HardwareBuffer（那个是 @hide，
                            //     android.jar 里根本没有，import 会直接编译不过）；
                            //  ② 公开的 `android.hardware.HardwareBuffer` **没有 lock/unlock**，
                            //     拿不到像素。正路是 API 33+ 的
                            //     `Bitmap.wrapHardwareBuffer(hw, ColorSpace)`。
                            val hw = screenshot.hardwareBuffer
                            val bmp = Bitmap.wrapHardwareBuffer(
                                hw, ColorSpace.get(ColorSpace.Named.SRGB)
                            )
                            bitmap = bmp
                        } catch (e: Throwable) {
                            Log.w(TAG, "取像素失败：${e.message}")
                        } finally {
                            latch.countDown()
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        Log.w(TAG, "takeScreenshot 失败，错误码 $errorCode")
                        latch.countDown()
                    }
                },
            )
        } catch (e: Throwable) {
            Log.w(TAG, "takeScreenshot 抛异常：${e.message}")
            return null
        }
        return try {
            if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) bitmap else null
        } catch (e: Throwable) {
            null
        }
    }

    // ── 手势 ────────────────────────────────────────────────────────────

    /** 点击（毫秒坐标）。返回是否成功派发。 */
    fun tap(x: Int, y: Int, durationMs: Long = 80): Boolean {
        val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs.coerceIn(1, 2000)))
            .build()
        return try {
            dispatchGesture(gesture, null, null)
            true
        } catch (e: Throwable) {
            Log.w(TAG, "dispatchGesture 失败：${e.message}")
            false
        }
    }

    /** 滑动。 */
    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long = 300): Boolean {
        val path = Path().apply {
            moveTo(x1.toFloat(), y1.toFloat())
            lineTo(x2.toFloat(), y2.toFloat())
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs.coerceIn(1, 5000)))
            .build()
        return try {
            dispatchGesture(gesture, null, null)
            true
        } catch (e: Throwable) {
            Log.w(TAG, "dispatchGesture(滑动) 失败：${e.message}")
            false
        }
    }

    // ── 全局按键（返回 / 主页 / 最近任务）────────────────────────────────
    //
    // 这是"走错路能退回来"的前提。没有它，Agent 点进一个弹窗就只能干等。
    // `performGlobalAction` 是无障碍服务原生能力，不需要额外权限。
    fun globalAction(which: String): Boolean {
        val code = when (which.lowercase()) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            else -> return false
        }
        return try {
            performGlobalAction(code)
        } catch (e: Throwable) {
            Log.w(TAG, "performGlobalAction($which) 失败：${e.message}")
            false
        }
    }

    // ── 输入文字 ────────────────────────────────────────────────────────
    //
    // 做法：在**当前界面**里找可编辑节点（`isEditable`），聚焦后 `ACTION_SET_TEXT`。
    //
    // ⚠️ 已知限制（如实写）：
    //   · **自绘界面的输入框**（游戏/部分 App 自绘搜索栏）节点树里没有 editable 节点，
    //     这条走不通 —— 那种情况只能让用户自己输入；
    //   · 有些输入框是多行/富文本，SET_TEXT 会清空原内容再写（不是追加）。
    //     需要"接着往后写"时，调用方应先把已有文字读出来、拼好再设。
    fun setText(text: String, timeoutMs: Long = 8000): Boolean {
        val root = rootInActiveWindow ?: return false
        val target = findEditable(root, 0)
        if (target == null) {
            Log.w(TAG, "没找到可编辑控件（自绘界面的输入框认不出来）")
            return false
        }
        // ⚠️ **必须带超时**：`performAction` 是跨进程同步调用，遇到重型 App（淘宝）
        //    的自定义输入框会一直阻塞 —— 实测卡 15 秒把桥的 socket 都拖到 Read timed out。
        //    所以放独立线程里跑，超时就当失败，绝不让它拽住整座桥。
        var ok = false
        val t = Thread {
            try {
                target.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                val args = android.os.Bundle()
                args.putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text
                )
                ok = target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                if (!ok) Log.w(TAG, "ACTION_SET_TEXT 被拒绝（控件可能只读或自带输入法拦截）")
            } catch (e: Throwable) {
                Log.w(TAG, "setText 异常：${e.message}")
            }
        }
        t.isDaemon = true
        t.start()
        t.join(timeoutMs)
        if (t.isAlive) {
            Log.w(TAG, "setText 超时（${timeoutMs}ms）—— 这个输入框不接受程序输入，需用户手动打字")
            return false
        }
        return ok
    }

    private fun findEditable(node: AccessibilityNodeInfo?, depth: Int): AccessibilityNodeInfo? {
        if (node == null || depth > 20) return null
        if (node.isEditable && node.isEnabled) return node
        for (i in 0 until node.childCount) {
            val c = try { node.getChild(i) } catch (e: Throwable) { null }
            val hit = findEditable(c, depth + 1)
            if (hit != null) return hit
        }
        return null
    }

    // ── 节点点击（**不依赖前台**）──────────────────────────────────────
    //
    // 与 [tap] 的区别（这是 2026-10-23 用户点出来的关键区别）：
    //   * [tap] 走 `dispatchGesture`：把**触摸坐标**注入系统输入流 ——
    //     触摸只送**前台**窗口，所以目标 App 必须在前台；
    //   * [clickNode] 走 `performAction(ACTION_CLICK)`：**直接调控件的点击回调**，
    //     不经过触摸分发 —— 对 `getWindows()` 里那些**后台窗口**也可能生效。
    //
    // 但能不能真拿到后台窗口，取决于厂商/AOSP 策略（有些系统只暴露活跃窗口），
    // 所以这条**必须实测**、且失败要如实报"拿不到后台窗口"，不能假装成功。

    /** `getWindows()` 能看到的窗口（含后台的，视系统策略）。 */
    fun listWindows(): List<String> {
        val out = ArrayList<String>()
        try {
            for (w in windows) {
                val root = try { w.root } catch (e: Throwable) { null } ?: continue
                val pkg = root.packageName?.toString() ?: ""
                val act = try { w.isActive } catch (e: Throwable) { false }
                val focus = try { w.isFocused } catch (e: Throwable) { false }
                val layer = try { w.layer } catch (e: Throwable) { 0 }
                out.add(
                    "{\"package\":\"" + pkg + "\",\"active\":" + act +
                        ",\"focused\":" + focus + ",\"layer\":" + layer + "}"
                )
            }
        } catch (e: Throwable) {
            Log.w(TAG, "getWindows 失败：${e.message}")
        }
        return out
    }

    /**
     * 在**指定包名**的窗口里找匹配文字/描述的控件并 `ACTION_CLICK`。
     *
     * 返回 null = 没找到（调用方如实报）；空串 = 找到了但点击被拒。
     * 这个**不需要目标 App 在前台**（如果系统把它的窗口暴露出来的话）。
     */
    fun clickNodeIn(pkg: String, text: String): String? {
        val roots = ArrayList<AccessibilityNodeInfo>()
        try {
            // ① 先看所有窗口（含后台）
            for (w in windows) {
                val r = try { w.root } catch (e: Throwable) { null } ?: continue
                if (r.packageName?.toString() == pkg) roots.add(r)
            }
            // ② 兜底：活动窗口
            rootInActiveWindow?.let { if (it.packageName?.toString() == pkg) roots.add(it) }
        } catch (e: Throwable) {
            Log.w(TAG, "枚举窗口失败：${e.message}")
        }
        if (roots.isEmpty()) return null
        for (root in roots) {
            val hit = findClickableByText(root, text, 0) ?: continue
            val ok = try {
                hit.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            } catch (e: Throwable) {
                Log.w(TAG, "ACTION_CLICK 异常：${e.message}")
                false
            }
            if (ok) return ""
        }
        return null
    }

    private fun findClickableByText(
        node: AccessibilityNodeInfo?,
        needle: String,
        depth: Int,
    ): AccessibilityNodeInfo? {
        if (node == null || depth > 20) return null
        val label = (node.text?.toString() ?: "") + " " + (node.contentDescription?.toString() ?: "")
        if (label.contains(needle)) {
            // 自己可点就点自己，否则往上找可点的祖先
            var cur: AccessibilityNodeInfo? = node
            var up = 0
            while (cur != null && up < 4) {
                if (cur.isClickable && cur.isEnabled) return cur
                cur = cur.parent
                up++
            }
        }
        for (i in 0 until node.childCount) {
            val c = try { node.getChild(i) } catch (e: Throwable) { null }
            val hit = findClickableByText(c, needle, depth + 1)
            if (hit != null) return hit
        }
        return null
    }

    // ── 节点树 ──────────────────────────────────────────────────────────

    /**
     * 导出当前界面的控件树（JSON 字符串）。
     *
     * 深度受限（默认 12 层、每层最多 40 个兄弟），否则某些界面会导出十几 MB。
     * ⚠️ **自绘界面（剪映、游戏、部分 WebView）这里会是空的** —— 那种情况要靠截图 + 视觉理解。
     */
    fun nodesJson(maxDepth: Int = 12, maxSiblings: Int = 40): String {
        val root = rootInActiveWindow ?: return "[]"
        // ⚠️ 递归**返回字符串、由父级 join** —— 不能像第一版那样用一个共享的 `first` 标志：
        //    那个标志跨层共用，进到子层时它已经变成 false，于是拼出 `"children":[,{...`
        //    这种非法 JSON（真机上实测到的：/nodes 返回 234 字符处解析失败）。
        fun node(obj: AccessibilityNodeInfo?, depth: Int): String? {
            if (obj == null || depth > maxDepth) return null
            val kids = ArrayList<String>(obj.childCount)
            var taken = 0
            for (i in 0 until obj.childCount) {
                if (taken >= maxSiblings) break
                val child = try { obj.getChild(i) } catch (e: Throwable) { null }
                val js = node(child, depth + 1)
                if (js != null) {
                    kids.add(js)
                    taken++
                }
            }
            val r = android.graphics.Rect()
            obj.getBoundsInScreen(r)
            return buildString {
                append("{\"depth\":").append(depth)
                append(",\"text\":").append(jsonStr(obj.text?.toString() ?: ""))
                append(",\"desc\":").append(jsonStr(obj.contentDescription?.toString() ?: ""))
                append(",\"id\":").append(jsonStr(obj.viewIdResourceName ?: ""))
                append(",\"cls\":").append(jsonStr(obj.className?.toString() ?: ""))
                append(",\"pkg\":").append(jsonStr(obj.packageName?.toString() ?: ""))
                append(",\"clickable\":").append(obj.isClickable)
                append(",\"scrollable\":").append(obj.isScrollable)
                append(",\"enabled\":").append(obj.isEnabled)
                append(",\"editable\":").append(obj.isEditable)
                append(",\"bounds\":[").append(r.left).append(',').append(r.top)
                    .append(',').append(r.right).append(',').append(r.bottom).append(']')
                append(",\"children\":[").append(kids.joinToString(",")).append("]}")
            }
        }
        return "[" + (node(root, 0) ?: "") + "]"
    }

    private fun jsonStr(s: String): String {
        val sb = StringBuilder(s.length + 8)
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c < ' ') sb.append(String.format("\\u%04x", c.code)) else sb.append(c)
            }
        }
        sb.append('"')
        return sb.toString()
    }
}
