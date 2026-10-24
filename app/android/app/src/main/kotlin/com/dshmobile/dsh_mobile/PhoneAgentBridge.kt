package com.dshmobile.dsh_mobile

import android.os.Build
import android.util.Base64
import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 「手机界面操作」的本地 HTTP 桥。
 *
 * ## 为什么是 HTTP 而不是 MethodChannel
 *
 * DSH 的 Agent 跑在 **Node 进程**里，而 MethodChannel 只在 Flutter 侧。
 * 让 Agent 用截图/点击，得有一条 **Node 直达 Android 原生**的路。
 * 本项目已有先例：**本地模型（LiteRT-LM）就是用同样的 127.0.0.1 HTTP 桥**（见 `LiteRtLmBridge.kt`），
 * 这里照抄那个模式，端口也从 Flutter 通过 MethodChannel 传下来。
 *
 * ## 安全性
 *
 * * 只绑 **127.0.0.1**，不出本机；
 * * 请求头带一个**随机会话令牌**，由 Flutter 侧生成并通过启动参数传进来 ——
 *   防止同机别的 App 猜到端口就乱调（虽然只在本机，仍按"能防就防"做）。
 *
 * ## 接口（全部 POST / 路径区分）
 *
 * | 路径 | 作用 | 返回 |
 * |---|---|---|
 * | `GET /ping` | 探活 | `{"ok":true,...}` |
 * | `GET /status` | 服务是否已连上 | `{"connected":bool,"sdk":int}` |
 * | `GET /screenshot` | 当前屏幕 PNG | `{"ok":true,"png":"<base64>"}` |
 * | `POST /tap` | 点击 | `{"ok":true}`，参数 `{"x":int,"y":int}` |
 * | `POST /swipe` | 滑动 | `{"ok":true}`，参数 `{"x1","y1","x2","y2","ms"}` |
 * | `GET /nodes` | 控件树 | `{"ok":true,"nodes":"<json字符串>"}` |
 */
class PhoneAgentBridge {

    companion object {
        private const val TAG = "DshPhoneAgent"
    }

    /** 拿 packageManager / startActivity 用（Application context）。 */
    @Volatile
    private var appContext: android.content.Context? = null

    /** MainActivity 在 onCreate 里调一次 —— 没有它，/apps 与 /launch 用不了。 */
    fun attach(context: android.content.Context) {
        appContext = context.applicationContext
    }

    @Volatile
    private var server: ServerSocket? = null
    @Volatile
    private var running = false
    private val stopFlag = AtomicBoolean(false)

    /** 启动；返回实际监听的端口（失败抛异常）。 */
    @Synchronized
    fun start(requestedPort: Int, token: String): Int {
        if (running) return port()
        stopFlag.set(false)
        var lastError: Throwable? = null
        for (p in requestedPort until requestedPort + 10) {
            try {
                val s = ServerSocket(p, 8, InetAddress.getByName("127.0.0.1"))
                server = s
                running = true
                Thread({ acceptLoop(s, token) }, "phone-agent-accept").apply { isDaemon = true }.start()
                Log.i(TAG, "手机操作桥已就绪：127.0.0.1:$p")
                return p
            } catch (e: Throwable) {
                lastError = e
            }
        }
        throw IllegalStateException("端口 $requestedPort 起 10 个都没成功：${lastError?.message}")
    }

    @Synchronized
    fun stop() {
        running = false
        stopFlag.set(true)
        try {
            server?.close()
        } catch (_: Throwable) {
        }
        server = null
    }

    fun port(): Int = server?.localPort ?: 0

    fun isRunning(): Boolean = running

    private fun acceptLoop(s: ServerSocket, token: String) {
        while (!stopFlag.get() && running) {
            try {
                val sock = s.accept()
                Thread({ handle(sock, token) }, "phone-agent-conn").apply { isDaemon = true }.start()
            } catch (e: Throwable) {
                if (running) Log.w(TAG, "accept 失败：${e.message}")
            }
        }
    }

    private fun handle(sock: Socket, token: String) {
        try {
            sock.use { s ->
                s.soTimeout = 45000
                val out: OutputStream = s.getOutputStream()
                val input = java.io.BufferedInputStream(s.getInputStream())

                // ⚠️ **必须按字节读**，不能按字符读：
                //    第一版用 `CharArray` + `content-length`（那是**字节**数）去读，
                //    中文一个字符占 3 字节 → 永远凑不够长度 → 一直阻塞到超时。
                //    症状极具误导性：tap/swipe（纯 ASCII body）全好，只有
                //    `/input {"text":"电影票"}` 这种中文 body 会卡死整座桥
                //    （2026-10-23 真机实测，卡了 15 秒报 Read timed out）。
                //    这里改成：自己读字节、找 \r\n\r\n 分界、body 按字节读再按 UTF-8 解。
                val headBuf = java.io.ByteArrayOutputStream()
                var b: Int
                var matched = 0
                while (true) {
                    b = input.read()
                    if (b == -1) return
                    headBuf.write(b)
                    matched = when {
                        (matched == 0 || matched == 2) && b == '\r'.code -> matched + 1
                        (matched == 1 || matched == 3) && b == '\n'.code -> matched + 1
                        else -> if (b == '\r'.code) 1 else 0
                    }
                    if (matched == 4) break
                    if (headBuf.size() > 64 * 1024) return // header 过大，防御
                }
                val headText = String(headBuf.toByteArray(), Charsets.ISO_8859_1)
                val lines = headText.split("\r\n")
                val requestLine = lines.firstOrNull() ?: return
                val headers = HashMap<String, String>()
                for (i in 1 until lines.size) {
                    val line = lines[i]
                    if (line.isEmpty()) continue
                    val idx = line.indexOf(':')
                    if (idx > 0) headers[line.substring(0, idx).trim().lowercase()] =
                        line.substring(idx + 1).trim()
                }
                val parts = requestLine.split(" ")
                val path = if (parts.size >= 2) parts[1] else "/"
                val query = path.substringAfter('?', "")

                // body：按**字节**读满 content-length，再整体 UTF-8 解码
                val bodyLen = headers["content-length"]?.toIntOrNull() ?: 0
                val body = if (bodyLen > 0) {
                    val raw = ByteArray(bodyLen)
                    var read = 0
                    while (read < bodyLen) {
                        val r = input.read(raw, read, bodyLen - read)
                        if (r <= 0) break
                        read += r
                    }
                    String(raw, 0, read, Charsets.UTF_8)
                } else ""

                // 令牌校验（/ping 除外，方便探活）
                if (!path.startsWith("/ping") && headers["x-dsh-token"] != token) {
                    respond(out, 403, "{\"ok\":false,\"error\":\"bad token\"}")
                    return
                }
                route(out, path, query, body)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "处理请求失败：${e.message}")
        }
    }

    /** 真正的路由分发（拆出来，让 [handle] 只管 HTTP 层）。 */
    private fun route(out: OutputStream, path: String, query: String, body: String) {
        val svc = DshPhoneAgentService.instance
        when {
            path.startsWith("/ping") ->
                respond(out, 200, "{\"ok\":true,\"service\":\"phone-agent\"}")
            path.startsWith("/status") ->
                respond(
                    out, 200,
                    "{\"ok\":true,\"connected\":" + (svc != null) +
                        ",\"sdk\":" + Build.VERSION.SDK_INT +
                        ",\"package\":\"" + (svc?.rootInActiveWindow?.packageName ?: "") + "\"}"
                )
            path.startsWith("/screenshot") -> {
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接，请先在系统设置里开启\"}")
                } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    respond(out, 501, "{\"ok\":false,\"error\":\"截图需要 Android 13 (API 33+)；本机 " + Build.VERSION.SDK_INT + "\"}")
                } else {
                    val png = svc.screenshotBase64()
                    if (png == null) {
                        respond(out, 502, "{\"ok\":false,\"error\":\"截图失败（可能没有前台界面，或该页禁止截图）\"}")
                    } else {
                        respond(out, 200, "{\"ok\":true,\"png\":\"" + png + "\"}")
                    }
                }
            }
            path.startsWith("/tap") -> {
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接\"}")
                } else {
                    val x = jsonInt(body, "x")
                    val y = jsonInt(body, "y")
                    if (x == null || y == null) {
                        respond(out, 400, "{\"ok\":false,\"error\":\"需要 x 与 y\"}")
                    } else {
                        // ⚠️ 前台包名校验（2026-10-23 加）：触摸只送到**前台**窗口，
                        //    如果中途前台被切走（通知/误触 Home），这一下就会点进**别的 App**。
                        //    调用方可用 `expect=<包名>` 声明"我点的是这个 App"，
                        //    包名不符就整笔拒绝（409），绝不盲点。
                        val expect = paramOf(query, "expect") ?: jsonStrOf(body, "expect")
                        val fg = try {
                            svc.rootInActiveWindow?.packageName?.toString()
                        } catch (e: Throwable) {
                            null
                        }
                        if (!expect.isNullOrEmpty() && expect != fg) {
                            respond(out, 409,
                                "{\"ok\":false,\"error\":\"前台已经不是目标应用了（期望 " +
                                    expect + "，实际 " + (fg ?: "未知") +
                                    "）—— 已拒绝这次点击，避免误点。\"," +
                                    "\"expected\":\"" + expect + "\",\"actual\":\"" + (fg ?: "") + "\"}")
                        } else {
                            val ok = svc.tap(x, y, jsonLong(body, "ms") ?: 80)
                            respond(out, 200, "{\"ok\":" + ok + ",\"package\":\"" + (fg ?: "") + "\"}")
                        }
                    }
                }
            }
            path.startsWith("/swipe") -> {
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接\"}")
                } else {
                    val x1 = jsonInt(body, "x1"); val y1 = jsonInt(body, "y1")
                    val x2 = jsonInt(body, "x2"); val y2 = jsonInt(body, "y2")
                    if (x1 == null || y1 == null || x2 == null || y2 == null) {
                        respond(out, 400, "{\"ok\":false,\"error\":\"需要 x1,y1,x2,y2\"}")
                    } else {
                        val expect = paramOf(query, "expect") ?: jsonStrOf(body, "expect")
                        val fg = try { svc.rootInActiveWindow?.packageName?.toString() } catch (e: Throwable) { null }
                        if (!expect.isNullOrEmpty() && expect != fg) {
                            respond(out, 409,
                                "{\"ok\":false,\"error\":\"前台已不是目标应用（期望 " + expect +
                                    "，实际 " + (fg ?: "未知") + "）—— 已拒绝\"}")
                        } else {
                            val ok = svc.swipe(x1, y1, x2, y2, jsonLong(body, "ms") ?: 300)
                            respond(out, 200, "{\"ok\":" + ok + ",\"package\":\"" + (fg ?: "") + "\"}")
                        }
                    }
                }
            }
            path.startsWith("/key") -> {
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接\"}")
                } else {
                    val act = paramOf(query, "action") ?: "back"
                    val ok = svc.globalAction(act)
                    if (ok) respond(out, 200, "{\"ok\":true,\"action\":\"" + act + "\"}")
                    else respond(out, 400, "{\"ok\":false,\"error\":\"不认识的 action（back/home/recents/notifications）\"}")
                }
            }
            path.startsWith("/input") -> {
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接\"}")
                } else {
                    val t = paramOf(query, "text") ?: jsonStrOf(body, "text") ?: ""
                    if (t.isEmpty()) {
                        respond(out, 400, "{\"ok\":false,\"error\":\"需要 text\"}")
                    } else {
                        val ok = svc.setText(t)
                        if (ok) respond(out, 200, "{\"ok\":true,\"len\":" + t.length + "}")
                        else respond(out, 422, "{\"ok\":false,\"error\":\"没能写入输入框（自绘界面的输入框认不出，或该框不接受程序输入）—— 请让用户手动打字\"}")
                    }
                }
            }
            path.startsWith("/wait-text") -> {
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接\"}")
                } else {
                    val q = paramOf(query, "q") ?: ""
                    if (q.isEmpty()) {
                        respond(out, 400, "{\"ok\":false,\"error\":\"需要 q\"}")
                    } else {
                        val timeoutMs = (paramOf(query, "timeout")?.toLongOrNull() ?: 8000L)
                            .coerceIn(500L, 30000L)
                        val deadline = System.currentTimeMillis() + timeoutMs
                        var hit = false
                        while (System.currentTimeMillis() < deadline) {
                            if (svc.nodesJson().contains(q)) { hit = true; break }
                            Thread.sleep(400)
                        }
                        if (hit) respond(out, 200, "{\"ok\":true,\"found\":true}")
                        else respond(out, 200, "{\"ok\":true,\"found\":false,\"waitedMs\":" + timeoutMs + "}")
                    }
                }
            }
            path.startsWith("/ocr") || path.startsWith("/find-text") -> {
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接\"}")
                } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    respond(out, 501, "{\"ok\":false,\"error\":\"OCR 需要 Android 13 (API 33+)；本机 " + Build.VERSION.SDK_INT + "\"}")
                } else {
                    val bmp = svc.screenshotBitmap()
                    if (bmp == null) {
                        respond(out, 502, "{\"ok\":false,\"error\":\"截图失败（可能没有前台界面，或该页禁止截图）\"}")
                    } else {
                        val ocrLines = try {
                            PhoneAgentOcr.recognize(bmp)
                        } finally {
                            try { bmp.recycle() } catch (_: Throwable) {}
                        }
                        if (ocrLines == null) {
                            respond(out, 500, "{\"ok\":false,\"error\":\"OCR 失败（详见运行日志）\"}")
                        } else {
                            val q = paramOf(query, "q")
                            val arr = org.json.JSONArray()
                            var n = 0
                            for (l in ocrLines) {
                                if (q != null && !l.text.contains(q)) continue
                                if (n++ >= 60) break
                                arr.put(org.json.JSONObject().apply {
                                    put("text", l.text)
                                    put("cx", l.cx); put("cy", l.cy)
                                    put("bounds", org.json.JSONArray(listOf(l.left, l.top, l.right, l.bottom)))
                                })
                            }
                            respond(out, 200,
                                "{\"ok\":true,\"count\":" + n + ",\"lines\":" + arr.toString() + "}")
                        }
                    }
                }
            }
            path.startsWith("/windows") -> {
                // 诊断用：看 getWindows() 到底暴露了哪些窗口（含不含后台 App）。
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接\"}")
                } else {
                    respond(out, 200, "{\"ok\":true,\"windows\":[" + svc.listWindows().joinToString(",") + "]}")
                }
            }
            path.startsWith("/clicknode") -> {
                // **节点点击**：对指定包名窗口里的控件直接触发点击回调。
                // 与 /tap（手势）不同 —— 这条**不强求目标在前台**。
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接\"}")
                } else {
                    val pkg = paramOf(query, "pkg") ?: jsonStrOf(body, "pkg") ?: ""
                    val text = paramOf(query, "text") ?: jsonStrOf(body, "text") ?: ""
                    if (pkg.isEmpty() || text.isEmpty()) {
                        respond(out, 400, "{\"ok\":false,\"error\":\"需要 pkg 与 text\"}")
                    } else {
                        val r = svc.clickNodeIn(pkg, text)
                        if (r == null) {
                            respond(out, 404,
                                "{\"ok\":false,\"error\":\"在 " + pkg +
                                    " 的窗口里没找到含「" + text + "」的可点控件（或该窗口没暴露给我们）\"}")
                        } else {
                            respond(out, 200, "{\"ok\":true,\"clicked\":\"" + text + "\"}")
                        }
                    }
                }
            }
            path.startsWith("/nodes") -> {
                if (svc == null) {
                    respond(out, 409, "{\"ok\":false,\"error\":\"无障碍服务未连接\"}")
                } else {
                    respond(out, 200, "{\"ok\":true,\"nodes\":" + svc.nodesJson() + "}")
                }
            }
            path.startsWith("/apps") -> {
                val ctx = appContext
                if (ctx == null) {
                    respond(out, 503, "{\"ok\":false,\"error\":\"桥还没 attach 到 App\"}")
                } else {
                    val pm = ctx.packageManager
                    val intent = android.content.Intent(
                        android.content.Intent.ACTION_MAIN, null
                    ).addCategory(android.content.Intent.CATEGORY_LAUNCHER)
                    val arr = org.json.JSONArray()
                    for (ri in pm.queryIntentActivities(intent, 0)) {
                        val pkgName = ri.activityInfo.packageName
                        if (pkgName == ctx.packageName) continue
                        arr.put(org.json.JSONObject().apply {
                            put("label", ri.loadLabel(pm).toString())
                            put("package", pkgName)
                            put("system", (ri.activityInfo.applicationInfo.flags and
                                android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0)
                        })
                    }
                    respond(out, 200, "{\"ok\":true,\"apps\":" + arr.toString() + "}")
                }
            }
            path.startsWith("/launch") -> {
                val ctx = appContext
                if (ctx == null) {
                    respond(out, 503, "{\"ok\":false,\"error\":\"桥还没 attach 到 App\"}")
                } else {
                    val pkg = paramOf(query, "pkg") ?: jsonStrOf(body, "pkg")
                    if (pkg.isNullOrEmpty()) {
                        respond(out, 400, "{\"ok\":false,\"error\":\"需要 pkg\"}")
                    } else {
                        val li = ctx.packageManager.getLaunchIntentForPackage(pkg)
                        if (li == null) {
                            respond(out, 404, "{\"ok\":false,\"error\":\"这个应用没有可启动的主界面\"}")
                        } else {
                            li.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                            ctx.startActivity(li)
                            respond(out, 200, "{\"ok\":true,\"launched\":\"" + pkg + "\"}")
                        }
                    }
                }
            }
            else -> respond(out, 404, "{\"ok\":false,\"error\":\"no such path\"}")
        }
    }

    private fun respond(out: OutputStream, code: Int, body: String) {
        try {
            out.write(("HTTP/1.1 $code ${if (code == 200) "OK" else "ERR"}\r\n" +
                "Content-Type: application/json; charset=utf-8\r\n" +
                "Content-Length: ${body.toByteArray(Charsets.UTF_8).size}\r\n" +
                "Connection: close\r\n\r\n").toByteArray(Charsets.UTF_8))
            out.write(body.toByteArray(Charsets.UTF_8))
            out.flush()
        } catch (_: Throwable) {
        }
    }

    /**
     * 从 query 串里取参数（`a=1&b=2`），**并做 URL 解码**。
     *
     * ⚠️ 不做解码的后果（2026-10-23 真机实测踩到）：
     *    调用方按标准发的是 `?text=%E6%90%9C%E7%B4%A2`（"搜索"的 percent-encoding），
     *    拿原串去匹配控件文字自然一个也对不上 —— 表现成"找不到控件"，
     *    看着像无障碍/界面问题，**真因只是少了这一步解码**。
     *    `/wait-text` 也因此一直返回 found:false（假阴性）。
     */
    private fun paramOf(query: String, key: String): String? {
        for (kv in query.split('&')) {
            val i = kv.indexOf('=')
            if (i > 0 && kv.substring(0, i) == key) {
                val raw = kv.substring(i + 1)
                return try {
                    java.net.URLDecoder.decode(raw, "UTF-8")
                } catch (e: Throwable) {
                    raw
                }
            }
        }
        return null
    }

    /** 从 JSON body 里取字符串值。 */
    private fun jsonStrOf(body: String, key: String): String? {
        val m = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*\"([^\"]*)\"").find(body)
        return m?.groupValues?.get(1)
    }

    // 极简 JSON 取值（避免为两个字段引入整个 JSON 库）
    private fun jsonInt(body: String, key: String): Int? {
        val i = body.indexOf("\"$key\"")
        if (i < 0) return null
        val c = body.indexOf(':', i)
        if (c < 0) return null
        val rest = body.substring(c + 1).trimStart()
        var j = 0
        var v = 0L
        var neg = false
        if (rest.startsWith("-")) {
            neg = true; j = 1
        }
        while (j < rest.length && rest[j].isDigit()) {
            v = v * 10 + (rest[j] - '0'); j++
        }
        if (j == 0) return null
        return (if (neg) -v else v).toInt()
    }

    private fun jsonLong(body: String, key: String): Long? = jsonInt(body, key)?.toLong()
}
