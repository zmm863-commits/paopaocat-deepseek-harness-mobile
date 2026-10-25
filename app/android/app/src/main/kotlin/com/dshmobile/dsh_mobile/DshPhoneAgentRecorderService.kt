package com.dshmobile.dsh_mobile

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * 泡泡猫「前台录制」无障碍服务。
 *
 * ## 为什么重新启用无障碍（只做录制，不做操作）
 *
 * 之前的录制在「无头虚拟屏」里做：预览框小、每步还要等截图轮询 + OCR，又慢又别扭。
 * 用户反馈「录制麻烦、慢」。正解是「录制搬到前台」：用户在真实屏幕正常操作 App，
 * 无障碍直接拿到「你点的按钮是什么字」（TYPE_VIEW_CLICKED 的 source.text），天然就是
 * 规则的 OCR 锚点，还比事后 OCR 更快更准。**回放仍走后台虚拟屏**，本服务只负责记录。
 *
 * ## 记录什么
 * - TYPE_VIEW_CLICKED：点的控件的 text / contentDescription → `{action: tapText, text}`
 * - TYPE_VIEW_TEXT_CHANGED：输入框里的最终文字 → `{action: input, text}`（连续变化去重）
 *
 * 步骤是进程内静态列表，Flutter 侧通过 MainActivity 的 channel 调 start/stop/json。
 */
class DshPhoneAgentRecorderService : AccessibilityService() {
    companion object {
        private const val TAG = "DshPhoneAgentRec"
        @Volatile var recording = false
            private set

        /** 录到的步骤（进程内）。 */
        val steps = mutableListOf<Map<String, Any>>()

        private var lastInputText: String? = null

        fun start() {
            steps.clear()
            lastInputText = null
            recording = true
            Log.i(TAG, "开始录制")
        }

        /** 停止并返回规则 JSON（含 name/steps）。 */
        fun stop(name: String): String {
            recording = false
            val arr = JSONArray()
            for (st in steps) {
                arr.put(JSONObject(st))
            }
            val obj = JSONObject()
            obj.put("name", name)
            obj.put("params", JSONArray())
            obj.put("steps", arr)
            Log.i(TAG, "停止录制：${steps.size} 步")
            return obj.toString()
        }

        val stepCount: Int get() = steps.size

        /** 无障碍服务是否已在系统里开启。 */
        fun isEnabled(context: Context): Boolean {
            val expected = ComponentName(
                context, DshPhoneAgentRecorderService::class.java).flattenToString()
            val enabled = Settings.Secure.getString(
                context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            return enabled?.split(':')?.contains(expected) == true
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || !recording) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                val node: AccessibilityNodeInfo? = event.source
                if (node == null) return
                val text = (node.text?.toString() ?: "")
                    .ifBlank { node.contentDescription?.toString() ?: "" }
                    .trim()
                if (text.isNotBlank() && text.length <= 30) {
                    // 去重：连续点同一个字只记一次（列表里点商品会连点好几个同文字项，
                    // 但录制里我们只要「这一步点在什么文字上」的锚点，不需要重复）。
                    val last = steps.lastOrNull()
                    if (last?.get("action") == "tapText" && last["text"] == text) return
                    steps.add(mapOf("action" to "tapText", "text" to text))
                    Log.i(TAG, "点击 → $text")
                }
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                val node: AccessibilityNodeInfo? = event.source
                if (node == null) return
                val text = (node.text?.toString() ?: "").trim()
                if (text.isBlank()) return
                if (text == lastInputText) return
                lastInputText = text
                // 输入框变化：更新/追加一条 input 步骤（同一个输入框连续敲字，合并成最后值）
                val last = steps.lastOrNull()
                if (last?.get("action") == "input") {
                    steps[steps.size - 1] = mapOf("action" to "input", "text" to text)
                } else {
                    steps.add(mapOf("action" to "input", "text" to text))
                }
                Log.i(TAG, "输入 → $text")
            }
        }
    }

    override fun onInterrupt() {
        recording = false
    }
}
