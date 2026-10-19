allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// ⚠️ 2026-10-19：`file_picker` 插件自己按 **android-34** 编译，而它依赖的
// `flutter_plugin_android_lifecycle` 要求 compileSdk **>= 36** → 构建直接挂在
// `:file_picker:checkReleaseAarMetadata`（"requires ... compile against version 36"）。
// 这是插件源码里 build.gradle 定的，改不了；标准解法是在根 Gradle 里把所有
// Android 子项目的 compileSdk 统一抬高。
//
// ⚠️ 位置很重要：**必须在 `evaluationDependsOn(":app")` 之前**注册 afterEvaluate，
//    否则报 `Cannot run Project.afterEvaluate(Action) when the project is already evaluated`。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.gradle.BaseExtension) {
            androidExt.compileSdkVersion(36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
