package com.dshmobile.dsh_mobile

/**
 * 屏幕助手「无头模式」的 Binder 协议（客户端与服务端**必须一致**）。
 *
 * 自定义 transact 码，不写 AIDL（少一个构建配置，且已验证可行）。
 * 约定：除 CMD_CAPTURE 外，reply 第一个值是 String：
 *   成功 "OK" / "OK:<附加信息>"；失败 "ERR:<原因>"。
 */
object EngineProtocol {
    const val SERVICE_VERSION = 1   // 改动服务端接口时 +1
    const val SERVICE_TAG = "vdshell"

    const val CMD_STATUS = 1
    const val CMD_CREATE = 2
    const val CMD_RELEASE = 3
    const val CMD_LAUNCH = 4
    const val CMD_TAP = 5
    const val CMD_SWIPE = 6
    const val CMD_KEY = 7
    const val CMD_TEXT = 8
    const val CMD_CAPTURE = 9    // 返回 byte[]，特殊编解码
    const val CMD_SHUTDOWN = 10

    const val OK = "OK"
}
