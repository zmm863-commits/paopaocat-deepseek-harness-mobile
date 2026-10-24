# ─────────────────────────────────────────────────────────────────────────────
# LiteRT-LM（Google 官方端侧推理运行时，跑 Gemma 4 那批 `.litertlm` 模型）
#
# 为什么必须 keep：LiteRT-LM 的 JNI 层（`liblitertlm_jni.so`）用 **FindClass 按类名字符串**
# 去拿这些类 —— 典型的是 `LiteRtLmJniException`：native 侧创建引擎失败时，要抛这个异常把
# 原因带回 Java 层。R8 **看不到这种"字符串引用"**，于是把它当成没人用的死代码删掉，结果：
#
#   真机症状（用户 2026-10-08 日志，0.34 包）：
#     litert-lm 启动失败：java.lang.ClassNotFoundException:
#       com.google.ai.edge.litertlm.LiteRtLmJniException
#       at com.google.ai.edge.litertlm.LiteRtLmJni.nativeCreateEngine(Native Method)
#
#   —— 这个报错极具误导性：它看起来像"依赖没打进包"，真实原因却是 **R8 把异常类裁了**，
#   真正的失败原因（GPU/NPU delegate 起不来等）被这层 ClassNotFoundException 完全掩盖。
#
# 为什么会发生（三方核实过的完整因果链）：
#   1. Flutter 3.47 的 Gradle 插件 **默认**给 release 开混淆：
#      `FlutterPluginUtils.shouldShrinkResources()` 在没显式传 property 时 `return true`，
#      随后 `FlutterPlugin.kt` 执行 `releaseBuildType.isMinifyEnabled = true`；
#   2. Flutter 自带的那份 keep 规则（`flutter_proguard_rules.pro`）只照顾 `io.flutter.plugin.**`，
#      不管第三方 native 库；
#   3. LiteRT-LM 官方 AAR（0.18.0）**没有自带 consumer proguard 规则**（已解包核实
#      `META-INF/proguard/` 下为空），也没有 `-keep` 声明；
#   ⇒ 三件事叠在一起，就必须由 **App 侧** 来 keep。
#
# 覆盖面：只保留这一个包（几百 KB 的类），不影响其它优化；`{ *; }` 同时保住字段与方法名，
# 因为 native 侧除了类名还可能按方法名回调（如 `LiteRtLmJni$JniMessageCallback`）。
# ─────────────────────────────────────────────────────────────────────────────
-keep class com.google.ai.edge.litertlm.** { *; }
-dontwarn com.google.ai.edge.litertlm.**

# ── 屏幕助手 OCR：ML Kit（PhoneAgentOcr.kt）──────────────────────────────
# 真因：方法名会被 R8 混淆 —— ML Kit 内部靠反射/内部类名装配识别管线，
# 类名一改就装配出 null，于是崩在识别那一刻。debug 包不混淆所以看不出来
# （2026-10-23 在 moto 真机 release 包上实测到的）。
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text** { *; }
-keep class com.google.android.gms.internal.mlkit_common** { *; }
-keep class com.google.mlkit.vision.text.chinese.** { *; }
# ML Kit 的 native 层
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
