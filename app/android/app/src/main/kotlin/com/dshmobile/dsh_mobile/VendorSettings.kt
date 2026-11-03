package com.dshmobile.dsh_mobile

import android.content.Intent
import android.provider.Settings

/**
 * 各家 ROM 把「后台不被杀」的开关放在**自己的**设置页里，系统 API 读不到也改不了。
 *
 * ## 为什么需要这张表
 *
 * 前台服务 + 忽略电池优化只覆盖「标准 Android」。vivo 在 OriginOS 上还会把离开屏幕的
 * App 网络直接掐断 —— 不开「允许后台高耗电」就是连不上（实测）。小米的「省电策略」、
 * 华为/荣耀的「应用启动管理」、OPPO 的「后台行为」同理。
 *
 * 这些页面是厂商自己的 activity：**不入任何 API、随 ROM 版本变动**。所以这里的策略是：
 *   1. 按 [Build.MANUFACTURER] / [Build.BRAND] 认出厂商；
 *   2. 按优先级逐个试该厂商的页面（必须 resolve 得到**且 exported**，否则跳过 ——
 *      跳一个不导出的 activity 会直接抛 SecurityException）；
 *   3. 一个都跳不进去 → 退到「本应用」的系统详情页（各 ROM 都从那儿链到同一批开关）。
 *
 * ## 为什么 UI 上不给"开关"
 *
 * 这些是**系统自己的开关**，App 既读不到也写不了。所以界面上只能写「去过设置页了」
 * —— 那是用户的陈述，不是检测结果。把它画成绿灯就是撒谎。
 *
 * ## 免责
 *
 * 下表的组件名是各厂商系统中真实存在的公开组件（属于客观事实，不是任何一方独创的
 * 表达），并且会随 ROM 版本变动 —— 所以每个都必须 resolve + exported 校验后才用，
 * 跳不进去就退到应用详情页。这不构成对任何厂商的适配承诺。
 */
object VendorSettings {

    /** 一个厂商页面：按组件（[cls]）或按 [action]（在 [pkg] 里）打开。 */
    data class Page(
        val pkg: String,
        val cls: String? = null,
        val action: String? = null,
        /** 有的页面要把"给哪个 App 开"作为 extra 传进去。 */
        val packageExtra: String? = null,
        val labelExtra: String? = null,
    )

    /** 厂商开关的种类。 */
    enum class Switch(val wire: String) {
        /** vivo 允许后台高耗电 / 小米 省电策略 / 华为·荣耀 应用启动管理 / OPPO 后台行为。 */
        BACKGROUND("background"),

        /** 自启动。 */
        AUTOSTART("autostart"),

        /** 后台弹出界面（手机操控要在任务结束后把 App 带回来时才需要）。 */
        POPUP("popup");

        companion object {
            fun parse(wire: String?): Switch? = entries.firstOrNull { it.wire == wire }
        }
    }

    const val VIVO = "vivo"
    const val XIAOMI = "xiaomi"
    const val HUAWEI = "huawei"
    const val HONOR = "honor"
    const val OPPO = "oppo"

    /** 认厂商；标准 Android / 其它牌子返回 null。 */
    fun vendorOf(manufacturer: String?, brand: String?): String? =
        match(manufacturer) ?: match(brand)

    private fun match(name: String?): String? {
        val n = name?.trim()?.lowercase() ?: return null
        fun any(vararg keys: String) = keys.any { n.startsWith(it) }
        return when {
            any("vivo", "iqoo") -> VIVO
            any("xiaomi", "redmi", "poco") -> XIAOMI
            // 老荣耀在 MANUFACTURER 里写的是 HUAWEI，跑的是华为那套管理器 → 先判。
            any("huawei") -> HUAWEI
            any("honor", "hihonor") -> HONOR
            any("oppo", "oneplus", "realme") -> OPPO
            else -> null
        }
    }

    private const val VIVO_PERMISSIONS = "com.vivo.permissionmanager"
    private const val IQOO_SECURE = "com.iqoo.secure"
    private const val MIUI_SECURITY = "com.miui.securitycenter"
    private const val HUAWEI_MANAGER = "com.huawei.systemmanager"
    private const val HONOR_MANAGER = "com.hihonor.systemmanager"

    /**
     * [switch] 对应的厂商页面，最合适的在前；**空列表 = 这个厂商没有独立页面**，
     * 直接退应用详情页（OPPO 就把全部开关放在详情页里）。
     */
    fun pages(vendor: String?, switch: Switch = Switch.BACKGROUND): List<Page> = when (vendor) {
        VIVO -> when (switch) {
            Switch.BACKGROUND -> listOf(
                // 电池 › 后台耗电管理（就是那个「允许后台高耗电」的白名单）。
                Page("com.vivo.abe",
                    "com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity"),
                Page("com.iqoo.powersaving", "com.iqoo.powersaving.PowerSavingManagerActivity"),
            )
            Switch.AUTOSTART -> listOf(
                Page(VIVO_PERMISSIONS, "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
                Page(IQOO_SECURE, "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
                Page(IQOO_SECURE, "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
            )
            Switch.POPUP -> listOf(
                Page(VIVO_PERMISSIONS,
                    "com.vivo.permissionmanager.activity.SoftPermissionDetailActivity",
                    packageExtra = "packagename"),
                Page(VIVO_PERMISSIONS,
                    action = "permission.intent.action.softPermissionDetail",
                    packageExtra = "packagename"),
                Page(VIVO_PERMISSIONS, "com.vivo.permissionmanager.activity.PurviewTabActivity"),
            )
        }
        XIAOMI -> when (switch) {
            // 本应用自己的「省电策略」页。
            Switch.BACKGROUND -> listOf(
                Page("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity",
                    packageExtra = "package_name", labelExtra = "package_label"),
            )
            Switch.AUTOSTART -> listOf(
                Page(MIUI_SECURITY, "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            )
            Switch.POPUP -> listOf(
                Page(MIUI_SECURITY,
                    "com.miui.permcenter.permissions.PermissionsEditorActivity",
                    packageExtra = "extra_pkgname"),
                Page(MIUI_SECURITY,
                    "com.miui.permcenter.permissions.AppPermissionsEditorActivity",
                    packageExtra = "extra_pkgname"),
            )
        }
        // 华为/荣耀把「自启动 + 后台运行」放在同一个「应用启动管理」里，没有单独的自启动页。
        HUAWEI -> if (switch == Switch.BACKGROUND) listOf(
            Page(HUAWEI_MANAGER, "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            Page(HUAWEI_MANAGER, "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"),
            Page(HUAWEI_MANAGER, "com.huawei.systemmanager.optimize.process.ProtectActivity"),
        ) else emptyList()
        HONOR -> if (switch == Switch.BACKGROUND) listOf(
            Page(HONOR_MANAGER, "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            Page(HUAWEI_MANAGER, "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        ) else emptyList()
        else -> emptyList()
    }

    /** 本应用的系统详情页 —— 所有 ROM 的最后兜底。 */
    fun detailsIntent(packageName: String): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:$packageName"))
}
