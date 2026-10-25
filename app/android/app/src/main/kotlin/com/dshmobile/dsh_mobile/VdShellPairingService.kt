package com.dshmobile.dsh_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.github.muntashirakon.adb.android.AdbMdns

/**
 * 泡泡猫免装配对的前台服务。
 *
 * ## 为什么要有它（对标 aladdin 的 Authorization Service）
 *
 * Android 无线调试的**配对端口只在「使用配对码配对设备」界面开着时才监听**，一关就失效。
 * 所以不能像普通输入那样「切回 App 填码」（切走 = 配对界面关 = 端口废，ECONNREFUSED）。
 *
 * 解法（照 aladdin）：
 *   1. **mDNS 自动发现配对端口** —— 用户不用看端口、不用手填；
 *   2. **通知栏 RemoteInput 输入配对码** —— 用户看配对界面时，下拉通知栏输码，
 *      通知栏是覆盖层、不会关掉配对界面，所以端口一直活着。
 *
 * 流程：点「配对并启动」→ 起本服务 → mDNS 搜配对服务 → 用户开配对界面 → 发现端口
 *   → 通知提示「下拉输码」→ 用户下拉输 6 位码 → 配对 → 起引擎 → 通知报「就绪」→ 收工。
 */
class VdShellPairingService : Service() {
    companion object {
        private const val TAG = "VdShellPairing"
        private const val CHANNEL = "vd_shell_pairing"
        private const val NOTIF_ID = 8101
        const val ACTION_START = "com.dshmobile.dsh_mobile.pairing.START"
        const val ACTION_CODE = "com.dshmobile.dsh_mobile.pairing.CODE"
        const val KEY_REMOTE_INPUT = "pairing_code"
    }

    private var discoveredPort: Int? = null
    private var mdns: AdbMdns? = null
    private var busy = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CODE) {
            val code = RemoteInput.getResultsFromIntent(intent)
                ?.getCharSequence(KEY_REMOTE_INPUT)?.toString()?.trim() ?: ""
            handleCode(code)
        } else {
            startFlow()
        }
        return START_NOT_STICKY
    }

    private fun startFlow() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "泡泡猫配对", NotificationManager.IMPORTANCE_LOW)
            )
        }
        startForeground(
            NOTIF_ID,
            build("正在搜索配对服务…\n请打开：开发者选项 → 无线调试 → 使用配对码配对设备", true)
        )
        startMdns()
    }

    private fun startMdns() {
        mdns = AdbMdns(this, AdbMdns.SERVICE_TYPE_TLS_PAIRING) { _, port ->
            if (port > 0 && !busy && discoveredPort == null) {
                discoveredPort = port
                Log.i(TAG, "发现配对端口 $port")
                update("找到配对服务（端口 $port）。下拉这条通知，在输入框填 6 位配对码")
            }
        }
        mdns?.start()
    }

    private fun handleCode(code: String) {
        if (code.length != 6) {
            update("配对码是 6 位数字，请下拉重新输入")
            return
        }
        if (busy) return
        val port = discoveredPort
        if (port == null) {
            update("还没找到配对服务，请确认「使用配对码配对设备」界面开着")
            return
        }
        busy = true
        update("正在配对…")
        Thread {
            val ok = VdShellManager.pair(this, code, port)
            if (!ok) {
                busy = false
                update("配对失败（码或端口不对），请下拉输入最新码")
                return@Thread
            }
            update("配对成功，正在起引擎…")
            val boot = VdShellManager.bootstrap(this)
            if (boot) {
                update("✅ 引擎已就绪！去会话里喊「泡泡猫」就能用了", false)
                runCatching { mdns?.stop() }
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            } else {
                busy = false
                update("启动失败：${VdShellManager.lastError}")
            }
        }.start()
    }

    private fun update(text: String, withInput: Boolean = true) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, build(text, withInput))
    }

    private fun build(text: String, withInput: Boolean): Notification {
        val contentIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val b = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle("泡泡猫 · 免装配对")
            .setContentText(text)
            .setContentIntent(contentIntent)
            .setOnlyAlertOnce(true)
        if (withInput) {
            val remoteInput = RemoteInput.Builder(KEY_REMOTE_INPUT)
                .setLabel("6 位配对码")
                .build()
            val codeIntent = PendingIntent.getService(
                this, 1,
                Intent(this, VdShellPairingService::class.java).setAction(ACTION_CODE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )
            val action = Notification.Action.Builder(
                android.R.drawable.ic_menu_edit, "输入配对码", codeIntent
            ).addRemoteInput(remoteInput).build()
            b.addAction(action)
        }
        return b.build()
    }

    override fun onDestroy() {
        runCatching { mdns?.stop() }
        super.onDestroy()
    }
}
