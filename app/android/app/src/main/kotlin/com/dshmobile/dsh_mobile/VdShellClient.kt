package com.dshmobile.dsh_mobile

import android.content.Context
import android.util.Log
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.android.AdbMdns
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Security
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 免装 Shizuku 的 adb 通道：用「无线调试配对」拿到 shell，再把引擎 dex 起进去。
 *
 * ## 为什么需要它
 *
 * 虚拟屏 + 定向注入必须有 shell 身份（uid 2000）。原来的路是让用户另装 Shizuku
 * 再授权；这条路让 App **自己**跟手机的 adbd 说话：
 *
 * ```
 * 无线调试配对码 ──pair()──▶ adbd 记住我们的证书 ──connectTls()──▶ 可执行 shell 命令
 * ```
 *
 * 配对码只有 6 位，但底层是 TLS 1.3 + Spake2（不是明文密码），所以每次重装 App
 * （证书变了）都要重新配一次；升级安装不会。
 *
 * ## 证书
 *
 * adb 的认证靠「一对 RSA 密钥 + 自签名证书」——服务端第一次见到我们的公钥会弹
 * 「允许 USB 调试吗」，而无线调试是**先配对**再连接，所以配对过一次之后就不再弹。
 * 密钥存 `filesDir/vdshell_key.pem`，卸载才会丢。
 */
class VdShellClient(private val context: Context) : AbsAdbConnectionManager() {

    companion object {
        private const val TAG = "VdShellAdb"
        private const val AUTHOR = "DSH Mobile"
    }

    private val keyFile = File(context.filesDir, "vdshell_key.pem")
    private val certFile = File(context.filesDir, "vdshell_cert.pem")

    private var privateKey: PrivateKey? = null
    private var certificate: Certificate? = null

    init {
        if (Security.getProvider("BC") == null) {
            Security.addProvider(BouncyCastleProvider())
        }
        setApi(android.os.Build.VERSION.SDK_INT)
        setTimeout(15, TimeUnit.SECONDS)
        try {
            ensureKeyPair()
        } catch (e: Throwable) {
            Log.e(TAG, "ensureKeyPair failed", e)
        }
    }

    override fun getPrivateKey(): PrivateKey = privateKey
        ?: throw IllegalStateException("adb 私钥未就绪（生成失败，见日志）")

    override fun getCertificate(): Certificate = certificate
        ?: throw IllegalStateException("adb 证书未就绪（生成失败，见日志）")

    override fun getDeviceName(): String = AUTHOR

    // ── 密钥与证书 ──────────────────────────────────────────────────────────

    @Synchronized
    private fun ensureKeyPair() {
        if (privateKey != null && certificate != null) return
        if (keyFile.isFile && certFile.isFile) {
            try {
                loadKeyPair()
                return
            } catch (e: Throwable) {
                Log.w(TAG, "加载既有密钥失败，重新生成：${e.message}")
            }
        }
        val generator = KeyPairGenerator.getInstance("RSA")
        generator.initialize(2048, SecureRandom())
        val pair = generator.generateKeyPair()

        val issuer = X500Name("CN=$AUTHOR")
        val now = System.currentTimeMillis()
        val builder = JcaX509v3CertificateBuilder(
            issuer,
            BigInteger.valueOf(now),
            Date(now - 86_400_000L),
            Date(now + 10L * 365 * 86_400_000L),
            issuer,
            pair.public,
        )
        val signer = JcaContentSignerBuilder("SHA256withRSA")
            .setProvider("BC")
            .build(pair.private)
        val cert = JcaX509CertificateConverter()
            .setProvider("BC")
            .getCertificate(builder.build(signer))

        privateKey = pair.private
        certificate = cert
        keyFile.writeText(pem("PRIVATE KEY", pair.private.encoded))
        certFile.writeText(pem("CERTIFICATE", cert.encoded))
        Log.i(TAG, "adb 密钥对已生成（${keyFile.length()} / ${certFile.length()} 字节）")
    }

    private fun loadKeyPair() {
        val keyDer = derOf(keyFile.readText())
        val certDer = derOf(certFile.readText())
        privateKey = KeyFactory.getInstance("RSA")
            .generatePrivate(PKCS8EncodedKeySpec(keyDer))
        certificate = CertificateFactory.getInstance("X.509")
            .generateCertificate(certDer.inputStream()) as X509Certificate
        Log.i(TAG, "adb 密钥对已加载")
    }

    private fun pem(label: String, der: ByteArray): String {
        val b64 = Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(der)
        return "-----BEGIN $label-----\n$b64\n-----END $label-----\n"
    }

    private fun derOf(pem: String): ByteArray {
        val body = pem.lineSequence()
            .filter { !it.startsWith("-----") && it.isNotBlank() }
            .joinToString("")
        return Base64.getMimeDecoder().decode(body)
    }

    // ── 配对与连接 ──────────────────────────────────────────────────────────

    /**
     * 无线调试配对。
     *
     * @param port 配对端口；传 null 则先跑一次 mDNS 发现（`_adb-tls-pairing._tcp`）。
     * @return 是否配对成功
     */
    fun pair(code: String, port: Int?): Boolean {
        val target = port ?: discoverPort(AdbMdns.SERVICE_TYPE_TLS_PAIRING, 6000)
        if (target == null || target <= 0) {
            Log.e(TAG, "找不到配对端口（mDNS 没发现，也没手填）")
            return false
        }
        return try {
            val ok = pair("127.0.0.1", target, code)
            Log.i(TAG, "pair(port=$target) = $ok")
            ok
        } catch (e: Throwable) {
            Log.e(TAG, "pair failed: ${e.message}", e)
            false
        }
    }

    /**
     * 连接 adbd。优先用调用方手填的连接端口（无线调试主页显示的「IP 地址和端口」），
     * 没填再退回 mDNS 发现（部分 Android 16 ROM 上 NsdManager 发现不到 adb 服务，
     * 所以手填是主力通道，mDNS 只是兜底）。
     */
    fun connectDevice(timeoutMs: Long = 12_000, connectPort: Int? = null): Boolean {
        // 连接端口优先级：手填 > 读系统设置（adb_wifi_server_port）> mDNS 发现
        val port = connectPort ?: readConnectPort()
        if (port != null && port > 0) {
            return try {
                connect("127.0.0.1", port)
            } catch (e: Throwable) {
                Log.w(TAG, "connect(port=$port) failed: ${e.message}")
                false
            }
        }
        try {
            if (connectTls(context, timeoutMs)) return true
        } catch (e: Throwable) {
            Log.w(TAG, "connectTls failed: ${e.message}")
        }
        try {
            if (connectTcp(context, timeoutMs)) return true
        } catch (e: Throwable) {
            Log.w(TAG, "connectTcp failed: ${e.message}")
        }
        return false
    }

    /**
     * 从系统设置读无线调试的连接端口（主页「IP 地址和端口」那行）。
     * 普通 App 可能读不到（SecurityException 或被隐藏），读不到就返回 null 走 mDNS。
     */
    private fun readConnectPort(): Int? {
        return try {
            val v = android.provider.Settings.Global.getInt(
                context.contentResolver, "adb_wifi_server_port", -1)
            if (v > 0) v else null
        } catch (e: Throwable) {
            Log.w(TAG, "读 adb_wifi_server_port 失败：${e.message}")
            null
        }
    }

    private fun discoverPort(serviceType: String, timeoutMs: Long): Int? {
        var port: Int? = null
        val latch = CountDownLatch(1)
        val mdns = AdbMdns(context, serviceType) { _, p ->
            if (p > 0) {
                port = p
                latch.countDown()
            }
        }
        return try {
            mdns.start()
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            port
        } catch (e: Throwable) {
            Log.w(TAG, "mDNS 发现失败（$serviceType）：${e.message}")
            null
        } finally {
            runCatching { mdns.stop() }
        }
    }

    // ── 执行命令 ────────────────────────────────────────────────────────────

    /**
     * 在 shell 里跑一条命令并取回输出。
     *
     * 做法：开一个 `shell:` 流，命令后追加 `echo __DSH_DONE__`，读到标记就收工；
     * 读是阻塞的，所以放在后台线程 + join 超时（超时就关流，避免把界面卡死）。
     */
    fun shell(command: String, timeoutMs: Long = 20_000): String {
        val marker = "__DSH_DONE_${System.nanoTime()}__"
        val full = "($command) 2>&1; echo $marker"
        var stream: io.github.muntashirakon.adb.AdbStream? = null
        val sb = StringBuilder()
        try {
            stream = openStream("shell:")
            val s = stream
            val out = s.openOutputStream()
            out.write((full + "\n").toByteArray())
            out.flush()

            val reader = Thread {
                try {
                    val input = s.openInputStream()
                    val buf = ByteArray(4096)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        val text = String(buf, 0, n)
                        synchronized(sb) { sb.append(text) }
                        if (sb.contains(marker)) break
                    }
                } catch (e: Throwable) {
                    Log.d(TAG, "shell reader ended: ${e.message}")
                }
            }
            reader.isDaemon = true
            reader.start()
            reader.join(timeoutMs)
        } catch (e: Throwable) {
            Log.e(TAG, "shell failed: ${e.message}", e)
            return "ERR:${e.javaClass.simpleName}:${e.message}"
        } finally {
            runCatching { stream?.close() }
        }
        val raw = synchronized(sb) { sb.toString() }
        return raw.replace(marker, "").trim()
    }

    /**
     * 把 assets 里的引擎 dex 部署到 /data/local/tmp 并起进程。
     *
     * 关键在**中转**：shell 读不到 App 私有目录（assets 在 APK 里更读不到），
     * 所以先由 App 自己把 dex 写到外部私有目录（`/sdcard/Android/data/<pkg>/files/`，
     * shell 有权限读），再由 shell 身份 `cp` 到 `/data/local/tmp`。
     */
    fun deployAndStart(): String {
        val dexFile = File(context.getExternalFilesDir(null) ?: context.filesDir, "vdshell.dex")
        context.assets.open("vdshell.dex").use { input ->
            dexFile.outputStream().use { output -> input.copyTo(output) }
        }
        val remote = "/data/local/tmp/vdshell.dex"
        val log = "/data/local/tmp/vdshell.log"
        val cmd = buildString {
            append("mkdir -p /data/local/tmp; ")
            append("pkill -f com.dshmobile.vdshell.ShellServer; ")
            append("cp '").append(dexFile.absolutePath).append("' ").append(remote).append("; ")
            append("chmod 644 ").append(remote).append("; ")
            append("rm -f ").append(log).append("; ")
            append("CLASSPATH=").append(remote)
                .append(" app_process / com.dshmobile.vdshell.ShellServer ")
                .append(">/dev/null 2>&1 & sleep 1; echo started")
        }
        return shell(cmd, 25_000)
    }
}
