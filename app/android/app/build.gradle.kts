plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dshmobile.dsh_mobile"
    compileSdk = flutter.compileSdkVersion
    // 屏幕助手「无头模式」的 ShizukuEngineClient 用 BuildConfig.DEBUG 判断
    // 要不要在 shell 进程里开调试；AGP 8+ 默认不生成 BuildConfig，得显式开。
    buildFeatures {
        buildConfig = true
    }
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // 目标 ABI。DSH 运行时每个架构约 93 MB，混入其它 ABI 会让包体成倍增长。
    // 由构建脚本通过 ORG_GRADLE_PROJECT_dshAbi 传入（Flutter 不转发 -P 参数）。
    val dshAbi = (project.findProperty("dshAbi") as String?) ?: "arm64-v8a"
    val allAbis = listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dshmobile.dsh_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += listOf(dshAbi)
        }
    }

    packaging {
        jniLibs {
            // 必须把 .so 解压到文件系统，否则 nativeLibraryDir 是空的，
            // libnode.so 就没法作为可执行文件启动（Android 默认 useLegacyPackaging=false
            // 会直接从 APK 映射，不落盘）。
            useLegacyPackaging = true

            // abiFilters 在这个组合下不可靠：Flutter 的 Gradle 插件会按 --target-platform
            // 追加自己的 ABI，于是 150 MB 的 assets 之外又会同时打进两套原生库。
            // 这里显式排除非目标 ABI。
            excludes += allAbis.filter { it != dshAbi }.map { "lib/$it/**" }

            // ── 本地大模型那一套（LiteRT-LM）不再进包 ────────────────────────────────
            // 2026-10-14，用户明确说「本地模型那一套彻底不用了」；包因此再小 **11.2 MiB**
            // （压缩后）。这四件来自下面 `dependencies` 里的三条 LiteRT 依赖：
            //   litertlm-android:0.18.0            → liblitertlm_jni.so              9.26 MiB
            //   litert-gpu:2.3.0                   → libLiteRtClGlAccelerator.so     1.43
            //   litert-npu-runtime-qualcomm:2.3.0  → libLiteRtCompilerPlugin_Qualcomm.so
            //                                        libLiteRtDispatch_Qualcomm.so  0.55
            //
            // ⚠️ **只排除 `.so`，不动那三条 Java 依赖、也不动 `LiteRtLmBridge.kt`** —— 这是刻意的：
            //   * 它们**只在真要起本地模型时才 dlopen**，而界面入口 0.70 就撤了、
            //     Dart 侧也没有调用点 —— 正常使用根本走不到那儿；
            //   * 万一真走到了，`LiteRtLmBridge` 里**统一 catch `Throwable`**
            //     （审计 P0-10 立的规矩：native 抛的是 `Error`，不是 `Exception`），
            //     拿到的是 `UnsatisfiedLinkError` 而不是进程崩溃；
            //   * Java 类还在包里（几百 KB），意味着**要恢复只需删掉下面这几行**，不用改任何代码。
            //
            // 要恢复：把这四行注释掉重新出包即可（.so 会自动从 AAR 里再抽出来）。
            excludes += setOf(
                "lib/$dshAbi/liblitertlm_jni.so",
                "lib/$dshAbi/libLiteRtClGlAccelerator.so",
                "lib/$dshAbi/libLiteRtCompilerPlugin_Qualcomm.so",
                "lib/$dshAbi/libLiteRtDispatch_Qualcomm.so",
            )
        }
    }

    // 运行时资源不进源码目录：
    //  - assets: DSH 依赖树打成单个 zip（解压一个流远快于 2.6 万个 AssetManager.open）
    //  - jniLibs: node 二进制（libnode.so）与依赖库必须在 nativeLibraryDir，
    //    因为 Android 只允许从那里执行原生程序。
    //
    // 路径用环境变量 DSH_ANDROID_NODE 指定，默认指向本机的 ASCII 构建目录。
    //   * Windows（原开发机）：$env:DSH_ANDROID_NODE = 'D:/dev/android-node'
    //   * Linux（本机迁移后）：/tmp/dshbuild/android-node
    // ⚠️ **必须放在纯 ASCII 路径下**：实测 JVM 在中文路径下初始化 java.util.logging /
    //    FilePermission 时会直接抛 InvalidPathException（本项目在 /root/办公 下踩到过）。
    val dshNodeRoot = System.getenv("DSH_ANDROID_NODE") ?: "/tmp/dshbuild/android-node"

    // 端侧推理引擎（llama.cpp 的 llama-server + 7 个依赖 .so）。
    //
    // ⚠️ **默认不进包了**（2026-10-09，审计 P0-6）。
    //
    // 依据（不是"感觉用不到"，是有记录的决策 + 真机实证）：
    //   * 用户 2026-10-08 选定"路线 A"：放弃 llama.cpp，端侧统一走 LiteRT-LM
    //     （见 changelog 0.47）。**GGUF 全部从清单下线** ——
    //     `assets/models/model_manifest.json` 里三个模型全是 `engine: litert-lm`；
    //   * 0.44 真机日志实证：该引擎在骁龙 8 Elite（Armv9.2）上处理 DSH 的**长请求**
    //     （一轮系统提示 3.1k~7k tokens）**必然段错误 code=-11**，CPU 与 Vulkan
    //     两个后端都崩 —— 也就是说它**留在包里也跑不了**；
    //   * 界面已没有任何入口指向它。
    //
    // **stable-diffusion 已于 2026-10-11 按用户要求删除**（不再是"有意保留"）。
    //
    // 依据：它是纯死重 —— 0.45 起界面就没有任何入口指向它，而它占
    // **压缩后约 14.9 MiB / 未压缩 40.8 MiB**（比共享库版 ffmpeg 省的还多）。
    // 用户原话：「① 直接删」。
    //
    // 要恢复的话（三段都要做，缺一段都不行）：
    //   1. 重新构建 SD 引擎（install/engine-build/build-sd-android.sh）；
    //   2. 把下面那段 `dshSdRoot` / `dshSdJniLibs` 的接线加回来
    //      （git 历史里搜 `dshSdJniLibs` 就有原样的一份）；
    //   3. 把 UI 侧的过滤条件恢复（原来的说法是"去掉 ondevice_models_page 的那处过滤"）。
    //
    // 想复现 llama 那条路（例如要重新评估 Armv9.2 段错误是否已修）：
    //   设 `DSH_ANDROID_INCLUDE_LLAMA=1` 再出包，其它不用改。
    val includeLlama = (System.getenv("DSH_ANDROID_INCLUDE_LLAMA") ?: "") == "1"
    val dshLlamaRoot = System.getenv("DSH_ANDROID_LLAMA") ?: "/tmp/dshbuild/android-llama"
    val dshLlamaJniLibs = File(dshLlamaRoot, "jnilibs")

    sourceSets {
        getByName("main") {
            // ── 运行时 zip 打不打进包里：**默认不打** ────────────────────────────────
            //   * 不打（精简包，65 MiB）：**App 内更新专用** —— 老用户手机里早就
            //     有那份运行时了，再下一遍纯属浪费，这就是省下来的 32 MB；
            //   * 打（完整包，97 MiB）：**给全新安装用** —— 设
            //     `DSH_ANDROID_INCLUDE_RUNTIME=1` 再出包。
            //
            // ⚠️ **为什么必须保留完整包**（2026-10-14 用户指出的硬伤）：
            // 精简包在没有运行时的情况下**连界面都进不去** —— 用户装完、手机没网，
            // 就彻底打不开。瘦身省的是"更新时的流量"，绝不能拿"新装能不能用"去换。
            // 两个包的 versionCode 与签名**完全相同**，可以互相覆盖安装。
            //
            // 老用户完全不受影响：他们 `files/` 里早就有那个 zip（0.15~0.74 都是
            // 随包拷过去的），`isRuntimeReady()` 直接为 true、根本不进「准备运行环境」那一页。
            val includeRuntime =
                (System.getenv("DSH_ANDROID_INCLUDE_RUNTIME") ?: "") == "1"
            assets.srcDirs(
                if (includeRuntime) listOf("src/main/assets", "$dshNodeRoot/app-assets")
                else listOf("src/main/assets")
            )
            // 引擎目录不存在时**不报错**：没跑过引擎构建脚本的机器照样能出包
            // （只是没有端侧模型能力，UI 会如实提示"引擎不存在"）。
            val dirs = mutableListOf("src/main/jniLibs", "$dshNodeRoot/jnilibs")
            if (includeLlama && dshLlamaJniLibs.isDirectory) {
                dirs.add(dshLlamaJniLibs.absolutePath)
            }
            jniLibs.srcDirs(dirs)
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // LiteRT-LM：Google 官方的 Android 端推理运行时，用来跑 Gemma 4 那批 `.litertlm` 模型
    // （llama.cpp 读不了这个格式）。
    //
    // 为什么用 Maven 依赖而不是"自己编引擎"：上游有官方 AAR，我已实测拉下来验过 ——
    //   * 0.18.0，AAR 20.9 MB，里面 arm64 的 `liblitertlm_jni.so` 21.1 MB；
    //   * `readelf -d` 只有系统库依赖（libandroid/libz/libGLESv2/libEGL/liblog…），
    //     未定义 `LiteRt*` 符号 0 个 → **不需要额外随包 .so**；
    //   * API 有流式（`sendMessageAsync(msg, MessageCallback)`）与 CPU/GPU/NPU 后端选择。
    // 所以省掉了装 Bazel + 从源码编那一步（详见 docs/需求台账.md #41）。
    // 桥已经写好了（`LiteRtLmBridge.kt`：把进程内的 LiteRT-LM 包成一个
    // 本机 OpenAI 兼容 HTTP 服务），所以现在正式随包。
    // arm64 的 `liblitertlm_jni.so` 约 22.2 MB（进 APK 后约 +10 MB）。
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.0")

    // ── 屏幕助手的本机 OCR（PhoneAgentOcr.kt）────────────────────────────
    // 自绘界面（游戏/剪映这类没有控件树的）靠它认字找按钮。
    // ⚠️ 有两个版本，**必须用 bundled（带模型）这个**：
    //   · `text-recognition-chinese` ← 这个：模型打进 APK，**不需要 Google Play Services**
    //   · 不带模型的那版要在设备上临时下载，国内手机没有 GMS 直接不可用
    // 代价约 +20MB（中文识别模型），本地推理约 100ms。
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")

    // ── 屏幕助手「无头模式」：Shizuku ────────────────────────────────
    // 在 shell 进程里跑 UserService，创建看不见的虚拟屏 + 定向注入触摸，
    // 让 Agent 能操作**后台** App（前台用无障碍，后台用这套）。
    // 两个库都在 Maven Central；api 提供客户端/服务端类，provider 提供 ShizukuProvider。
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")

    // ── LiteRT 的 GPU 加速器（`libLiteRtClGlAccelerator.so`）────────────────────
    // 为什么必须单独加这一条：`litertlm-android` 的 AAR 里**只有** `liblitertlm_jni.so`，
    // 而它是**运行时 dlopen** 加速器插件的（把包内 .so 的字符串挖出来可见这些名字：
    //   libLiteRtClGlAccelerator.so / libLiteRtOpenClAccelerator.so / libLiteRtVulkanAccelerator.so …），
    // 找不到就报「Cannot find accelerator.」→ GPU 后端起不来。
    // 这些库里只有 `libLiteRtClGlAccelerator.so`（OpenCL/GL 版）由 litert-gpu 提供；
    // 已核实 `litertlm-android` 的 POM 只依赖 gson/kotlin-reflect/coroutines，**不带**任何加速器。
    // 版本选 2.3.0：它与 litertlm 0.18.0 同属 2026-10 那一批（AAR 构建时间只差 4 天）。
    // 注意：litert-gpu 只额外带 `libLiteRt.so`，**不含**重名的 `liblitertlm_jni.so`，
    //       所以不需要官方 gallery 里那种 pickFirsts 处理。
    //
    // ⚠️⚠️ **必须 `isTransitive = false`** —— 否则 App 直接打不开（2026-10-08 真机事故）！
    //
    // 事故现场：加上这条依赖后（默认带传递依赖）用户反馈「应用打不开了」。
    // 逐层追出来的传递链是这样的（`./gradlew :app:dependencyInsight` 原始输出）：
    //
    //   litert-gpu:2.3.0
    //     └── litert:2.3.0
    //          └── litert-api:2.3.0
    //               └── com.google.android.play:ai-delivery:0.1.1-alpha01   ← alpha 版
    //                    └── com.google.android.play:asset-delivery:2.3.0
    //                         └── androidx.work:work-runtime:2.9.1
    //
    // 后果（对比 0.34 与 0.41 的**合并后** manifest 看到的事实）：
    //   * 多出 15 个组件（androidx.work / androidx.room / Google Play Core assetpacks）；
    //   * **多出一条启动期初始化**：
    //       <meta-data android:name="androidx.work.WorkManagerInitializer"
    //                  android:value="androidx.startup"/>
    //     `androidx.startup.InitializationProvider` 是 ContentProvider，**在进程启动时**就被系统创建，
    //     于是 WorkManager（及 Play Core 那条链）会在**显示任何界面之前**初始化。
    //     在没有 GMS 的国行 ROM 上这一步失败 → 进程直接死在启动阶段 → 用户看到的就是「应用打不开」。
    //
    // 修法：只要 AAR 自带的那个 `.so`，不要它那一串跟 GPU 无关的下载/任务调度依赖。
    //   * `libLiteRtClGlAccelerator.so` 在 litert-gpu 这个 AAR 里 ✅（`isTransitive=false` 不影响它）；
    //   * 它**不需要** `libLiteRt.so`：`readelf -d` 显示它的 NEEDED 只有 `glDispatchCompute`
    //     （来自系统 libGLESv2）等系统库，而它给 litertlm 用的是自己导出的 `LiteRtAcceleratorImpl`。
    // 代价：APK 少 ~5.6 MB（不再随包 libLiteRt.so），并且**启动路径回到 0.34 的干净状态**。
    implementation("com.google.ai.edge.litert:litert-gpu:2.3.0") { isTransitive = false }

    // ── LiteRT 的**高通 NPU** 运行时（Hexagon / AI Engine Direct · QNN）──────────────────
    //
    // ⚠️ 这是 2026-10-08 查 Google 官方文档与产物后才补上的一块，**很可能是"速度"的关键**。
    //
    // 为什么加：Google 的 AI Edge Gallery 在骁龙机器上跑 Gemma 很快，靠的是
    // **LiteRT-LM + 该芯片的 NPU 运行时**；而高通这一档就是本依赖。它的 AAR 里有：
    //   * `libLiteRtCompilerPlugin_Qualcomm.so` —— **编译器插件**：把模型**在设备上现场编译**
    //     成 Hexagon NPU（HTP）能跑的格式（strings 里能看到 `qnn::HtpBackend`、
    //     `HtpOptimizeForInference`、`HtpDlbc` 这些 HTP 优化阶段）；
    //   * `libLiteRtDispatch_Qualcomm.so` —— 在 NPU 上执行。
    //
    // **关键含义**：因为是**现场编译**，所以**不需要**上游预先提供
    // `_qualcomm_sm8850.litertlm` 那种机型专属文件 —— 通用版 `.litertlm` 就能被编译到
    // 本机 NPU 上跑。这解释了为什么"上游没有 SM8850 专属文件"不等于"这台机不能用 NPU"
    // （我先前据此下的"到不了 NPU"结论是错的，已在文档里更正）。
    //
    // 为什么敢加（跟 litert-gpu 那次事故的区别）：**它的 POM 里 `<dependencies>` 是空的** ——
    // 零传递依赖，不会像 litert-gpu 那样把 play:ai-delivery → asset-delivery → androidx.work
    // 拖进来（那条链往合并 manifest 塞了启动期 `WorkManagerInitializer`，导致应用打不开）。
    // 它的 AAR 自带 manifest 也只声明了一条 `<uses-native-library libcdsprpc.so>` —— 而我们
    // 早就自己声明过了。
    implementation("com.google.ai.edge.litert:litert-npu-runtime-qualcomm:2.3.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
