package com.dshmobile.dsh_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * 「电脑访问」的前台服务 —— 让 DSH 与设计站的两个 node 进程**活着**。
 *
 * ## 为什么需要（2026-10-28 审计）
 *
 * 之前 manifest 里只有 `DshSchedulerService` 与 `VdShellPairingService`，
 * **没有任何服务托管这两条转发**。于是：App 切后台久了 / 内存紧张 /
 * 用户从最近任务划掉 → node 进程被杀 → 电脑那边页面突然 502、设计站打不开，
 * 而且用户完全不知道为什么（App 界面看起来一切正常）。
 *
 * Dart 侧的「30 秒健康巡检」只能救「进程还在但假死」，救不了「整个 App 被回收」。
 * 前台服务把进程提到「用户可见的正在运行」级别，系统不会随意回收。
 *
 * ## 边界
 *
 * * 本服务**不持有 socket、不碰 node** —— 那些都在 Dart 侧。它只做「让进程别死」，
 *   并在通知里如实显示当前在服务的两个地址。
 * * 开关关闭时 Dart 侧调 [stop]，通知立刻消失。
 */
class WebBridgeService : Service() {
    companion object {
        private const val TAG = "WebBridge"
        private const val CHANNEL = "web_bridge"
        private const val NOTIF_ID = 8121
        const val ACTION_START = "com.dshmobile.dsh_mobile.bridge.START"
        const val ACTION_STOP = "com.dshmobile.dsh_mobile.bridge.STOP"
        const val EXTRA_DETAIL = "detail"

        fun start(ctx: Context, detail: String) {
            val i = Intent(ctx, WebBridgeService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_DETAIL, detail)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(i)
            } else {
                ctx.startService(i)
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, WebBridgeService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val detail = intent?.getStringExtra(EXTRA_DETAIL).orEmpty()
        createChannel()
        startForeground(NOTIF_ID, build(detail))

        // START_STICKY：被系统杀掉后尽力拉起。**注意**：拉起来的只是一个空壳服务，
        // node 进程不会自己回来 —— 真正的恢复由 Dart 侧的健康巡检 + 下次进
        // 设置页时重新 ensureStarted 完成。这里只保证「通知还在、进程被提级」。
        return START_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL, "电脑访问", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
    }

    private fun build(detail: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val text = if (detail.isBlank()) {
            "电脑可以通过浏览器访问这台手机上的 DSH"
        } else {
            detail
        }

        return NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle("电脑正在访问")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setOngoing(true)
            .setContentIntent(open)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
