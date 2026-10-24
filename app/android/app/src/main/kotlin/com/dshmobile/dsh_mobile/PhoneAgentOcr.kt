package com.dshmobile.dsh_mobile

import android.graphics.Bitmap
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 截图 → 文字块（含坐标）。给**自绘界面**用。
 *
 * ## 为什么需要这一层
 *
 * 无障碍节点树只对有控件结构的界面有效（原生 App、Flutter App 的 Semantics 树）。
 * **游戏 / 剪映 / 视频播放器控件这类自绘界面没有节点树** ——
 * `/nodes` 返回空、`find` 找不到东西，Agent 就瞎了。
 *
 * 但这类界面上**按钮往往是有字的**（"跳过""关闭""完成""导出""下一步"），
 * 所以"认字 + 给坐标"就能让 Agent 点中它。
 *
 * ## 为什么用 bundled 版 ML Kit
 *
 * `text-recognition-chinese` 把中文模型打进 APK，**不依赖 Google Play Services**。
 * 另一版要在设备上临时下载模型，国内手机无 GMS 直接不可用。
 * 代价约 +20MB，本地推理约 100ms —— 比 VLM（下载 1.5GB、2~4 秒）务实得多。
 *
 * ## 已知限制（如实写）
 *
 * * **纯图形按钮认不出来**（只有图标没有字）—— 那要 YOLO 那类目标检测；
 * * 旋转/花体字/极低对比度会掉；
 * * `FLAG_SECURE` 页面截不到图，自然也就认不出（银行/支付页）。
 */
object PhoneAgentOcr {

    private const val TAG = "DshPhoneAgent"

    /** OCR 结果里的一个文字块。 */
    data class OcrLine(
        val text: String,
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int,
    ) {
        val cx: Int get() = (left + right) / 2
        val cy: Int get() = (top + bottom) / 2
    }

    /**
     * 对一张图做识别，**同步等待**结果（最多 [timeoutMs]）。
     *
     * 失败返回 null 并打日志 —— 调用方要如实告诉用户"认不出"，不能假装空结果。
     */
    fun recognize(bitmap: Bitmap, timeoutMs: Long = 15000): List<OcrLine>? {
        // ⚠️ recognizer 复用（每次 new 一个会反复加载模型，明显变慢）
        val recognizer = ChineseTextRecognizerOptions.Builder().build().let {
            TextRecognition.getClient(it)
        }
        val latch = CountDownLatch(1)
        var out: List<OcrLine>? = null
        var err: Throwable? = null
        try {
            val image = InputImage.fromBitmap(bitmap, 0)
            recognizer.process(image)
                .addOnSuccessListener { result ->
                    val list = ArrayList<OcrLine>()
                    for (block in result.textBlocks) {
                        for (line in block.lines) {
                            val b = line.boundingBox ?: continue
                            val t = line.text.trim()
                            if (t.isEmpty()) continue
                            list.add(OcrLine(t, b.left, b.top, b.right, b.bottom))
                        }
                    }
                    out = list
                    latch.countDown()
                }
                .addOnFailureListener { e ->
                    err = e
                    latch.countDown()
                }
            if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                Log.w(TAG, "OCR 超时（${timeoutMs}ms）")
                return null
            }
        } catch (e: Throwable) {
            Log.w(TAG, "OCR 异常：${e.message}")
            return null
        } finally {
            try {
                recognizer.close()
            } catch (_: Throwable) {
            }
        }
        err?.let {
            Log.w(TAG, "OCR 失败：${it.message}")
            return null
        }
        return out
    }
}
