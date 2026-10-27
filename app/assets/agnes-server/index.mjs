/**
 * 泡泡猫影视工具 · 网页版 —— 独立后端
 *
 * 设计要点：
 *  1. 零运行时依赖，只用 node:http + node:fs（便于塞进任意小容器）。
 *  2. 密钥**不落盘、不入日志**：从请求头 x-vendor-key 取，随请求生命周期结束即消失。
 *     （对照版本：插件版从 DSH 凭据读，网页版从用户浏览器读。）
 *  3. 静态文件做了容器检查，`..` 穿越在 resolve 之后会被拒——这是插件里
 *     localfiles 接口没做、我在这一个版本里必须做对的事。
 *  4. ACCESS_TOKEN 是**可选的第二层门**。有 Cloudflare Access 时不用开；
 *     直连暴露时建议开。
 *
 * 环境变量：
 *   PORT          监听端口，默认 18889
 *   ACCESS_TOKEN  可选访问口令；为空则不做额外校验
 *   TZ            时区，默认 Asia/Shanghai
 */

import { createServer } from 'node:http'
import { createServer as createTlsServer } from 'node:https'
import { readFile, readdir, stat } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import { resolve, extname, sep, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { timingSafeEqual } from 'node:crypto'

import { proxyToVendor } from './proxy.mjs'
import { VENDOR_BASE_URLS, VENDOR_KEYLESS, VENDOR_LABELS } from './vendors.mjs'
// 原插件的全部引擎（build 产物，约 173 KB）：14 个引擎 + 原版路由分发
import { createHostHandler, parseKeyHeaders, requestStore } from './engines.bundle.mjs'
// 公众号草稿推送（真推微信 draft/add；引擎里那个 /wechat 的 publish 是占位实现）
import { getToken, pushDraft } from './wechat-push.mjs'

const HERE = fileURLToPath(new URL('.', import.meta.url))
const PUBLIC_DIR = resolve(HERE, '..', 'public')

/**
 * 原插件全部功能的入口。
 *
 * createHostHandler() 用一个假的 ctx 跑原插件的 apply()，把它注册的那个
 * 1000 行路由分发取出来 —— 于是 15 个 API 分区、断点续跑、素材解析、
 * ffmpeg 调用全部原样可用，改造面只剩「密钥从哪来」这一处。
 */
const engineHandler = createHostHandler()

const PORT = Number(process.env.PORT || 18889)
const HOST = process.env.HOST || '0.0.0.0'
const ACCESS_TOKEN = (process.env.ACCESS_TOKEN || '').trim()

/** 客户端透传的只是 JSON 参数，8MB 足够宽裕。 */
const MAX_BODY = 8 * 1024 * 1024

/**
 * 手机 App 写的厂商配置（`DSH_MOBILE_MODELS_FILE`）。
 *
 * 只为 `/api/vendors` 使用 —— Key 不在这里下发，凭据兜底在
 * `engines.bundle.mjs` 的 `parseKeyHeaders()` 里（Key 不出手机）。
 */
let _deviceVendors = null
function readDeviceVendors() {
  if (_deviceVendors) return _deviceVendors
  const file = (process.env.DSH_MOBILE_MODELS_FILE || '').trim()
  if (!file) return (_deviceVendors = {})
  try {
    const raw = JSON.parse(readFileSync(file, 'utf8'))
    const out = {}
    for (const [id, v] of Object.entries(raw.vendors || {})) {
      if (!v || typeof v.baseUrl !== 'string' || !v.baseUrl) continue
      out[id] = { baseUrl: v.baseUrl, label: typeof v.label === 'string' ? v.label : id }
    }
    return (_deviceVendors = out)
  } catch {
    return (_deviceVendors = {})
  }
}

/** 静态文件的 MIME 表。 */
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
}

// ─── 工具 ───────────────────────────────────────────────────────────────────

/**
 * 发送纯文本/HTML 响应。
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {string} body
 * @param {Record<string,string>} [headers]
 */
function send(res, status, body, headers = {}) {
  const buf = Buffer.from(body, 'utf8')
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': buf.length,
    ...headers,
  })
  res.end(buf)
}

/**
 * 发送 JSON 响应。
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {unknown} data
 */
function json(res, status, data) {
  const buf = Buffer.from(JSON.stringify(data), 'utf8')
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': buf.length,
    // 面板是纯静态的，禁用缓存避免部署后拿到旧前端
    'Cache-Control': 'no-store',
  })
  res.end(buf)
}

/**
 * 读取请求体（有大小上限，防止内存被打爆）。
 * @param {import('node:http').IncomingMessage} req
 * @param {number} [limit]
 * @returns {Promise<string>}
 */
function readBody(req, limit = MAX_BODY) {
  return new Promise((ok, fail) => {
    let size = 0
    /** @type {Buffer[]} */
    const chunks = []
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        req.destroy()
        fail(new Error('请求体过大'))
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => ok(Buffer.concat(chunks).toString('utf8')))
    req.on('error', fail)
  })
}

/**
 * 解析 Cookie 头。
 * @param {string|undefined} raw
 * @returns {Record<string,string>}
 */
function parseCookies(raw) {
  /** @type {Record<string,string>} */
  const out = {}
  for (const part of String(raw || '').split(';')) {
    const i = part.indexOf('=')
    if (i < 0) continue
    const k = part.slice(0, i).trim()
    if (k) out[k] = decodeURIComponent(part.slice(i + 1).trim())
  }
  return out
}

/**
 * 定长安全比较，避免逐字符比较泄露口令长度与内容。
 * @param {string} a
 * @param {string} b
 * @returns {boolean}
 */
function safeEqual(a, b) {
  const ba = Buffer.from(String(a))
  const bb = Buffer.from(String(b))
  if (ba.length !== bb.length) return false
  return timingSafeEqual(ba, bb)
}

/** 未通过口令门时返回的登录页。 */
const LOGIN_HTML = `<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>访问口令 · 泡泡猫影视工具</title>
<style>
  body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
       background:#0d1117;color:#e6edf3;font:15px/1.7 system-ui,-apple-system,"Segoe UI",sans-serif}
  form{background:#161b22;border:1px solid #30363d;border-radius:14px;padding:32px;width:min(88vw,340px)}
  h1{margin:0 0 6px;font-size:17px}
  p{margin:0 0 20px;color:#8b949e;font-size:13px}
  input{width:100%;box-sizing:border-box;padding:11px 13px;border-radius:9px;border:1px solid #30363d;
        background:#0d1117;color:#e6edf3;font-size:14px;margin-bottom:14px}
  button{width:100%;padding:11px;border:0;border-radius:9px;background:#238636;color:#fff;
         font-size:14px;font-weight:600;cursor:pointer}
  button:hover{background:#2ea043}
  .err{color:#f85149;font-size:13px;min-height:20px;margin-bottom:6px}
</style></head>
<body><form method="POST" action="/api/login">
  <h1>🐾 泡泡猫影视工具</h1>
  <p>本站已开启访问口令，请输入后继续。</p>
  <div class="err" id="err"></div>
  <input name="token" type="password" placeholder="访问口令" autofocus autocomplete="current-password">
  <button type="submit">进入</button>
</form>
<script>
  // 用 fetch 提交，口令错了就把错误显示在页面上而不是跳走
  document.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault()
    const token = e.target.token.value
    const resp = await fetch('/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    })
    if (resp.ok) location.reload()
    else document.getElementById('err').textContent = (await resp.json()).error || '口令不正确'
  })
</script>
</body></html>`

// ─── 静态文件 ───────────────────────────────────────────────────────────────

/**
 * 托管 public/ 下的静态文件。
 *
 * 安全要点（顺序不能反）：**先 decodeURIComponent，再 resolve**，
 * 然后检查结果仍在 PUBLIC_DIR 之内。这样 `%2e%2e%2f` 与 `../` 都会在
 * resolve 阶段被折叠，再由容器检查拦下。
 *
 * @param {import('node:http').ServerResponse} res
 * @param {string} urlPath - 原始 URL 路径。
 * @returns {Promise<boolean>} 是否已处理。
 */
async function serveStatic(res, urlPath) {
  let decoded
  try {
    decoded = decodeURIComponent(urlPath)
  } catch {
    send(res, 400, 'bad request')
    return true
  }
  if (decoded.includes('\0')) {
    send(res, 400, 'bad request')
    return true
  }

  // 以 / 结尾的请求（Next 静态导出用 trailingSlash）落到该目录的 index.html，
  // 否则 /design/ 这种子站入口会 404（readFile 打不开目录）。
  let rel = decoded === '/' ? '/index.html' : decoded
  if (rel.endsWith('/')) rel += 'index.html'
  const target = resolve(PUBLIC_DIR, '.' + rel)

  // 容器检查：resolve 之后必须仍落在 PUBLIC_DIR 内
  if (target !== PUBLIC_DIR && !target.startsWith(PUBLIC_DIR + sep)) {
    send(res, 403, 'forbidden')
    return true
  }

  try {
    const data = await readFile(target)
    const type = MIME[extname(target).toLowerCase()] || 'application/octet-stream'
    res.writeHead(200, {
      'Content-Type': type,
      'Content-Length': data.length,
      // 一律不缓存。
      // 这套应用是自部署工具，不是 CDN 分发的高流量站点；而「改了却看不到」
      // 的排查成本远高于每次多传 1.2 MB。之前给 studio.js 一小时缓存，
      // 结果就是改完代码、重建容器、刷新浏览器——跑的还是旧包。
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    })
    res.end(data)
  } catch {
    send(res, 404, 'not found')
  }
  return true
}

// ─── 路由 ───────────────────────────────────────────────────────────────────

/**
 * 口令门。未配置 ACCESS_TOKEN 时直接放行。
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 * @param {URL} url
 * @returns {boolean} true = 已拦截，不应继续处理。
 */
function gate(req, res, url) {
  if (!ACCESS_TOKEN) return false
  // healthcheck 必须免鉴权，否则容器永远不健康
  if (url.pathname === '/healthz') return false

  const cookie = parseCookies(req.headers.cookie).psw_session
  if (cookie && safeEqual(cookie, ACCESS_TOKEN)) return false

  // 登录页与登录提交都必须放行 —— 否则「提交口令」这一步会先被自己的门拦住
  if (url.pathname === '/api/login') {
    if (req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' })
      res.end(LOGIN_HTML)
      return true
    }
    return false // POST 交给下面的登录处理
  }
  if (req.method === 'GET' && String(req.headers.accept || '').includes('text/html')) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' })
    res.end(LOGIN_HTML)
    return true
  }
  json(res, 401, { error: '未通过访问口令' })
  return true
}

/**
 * 主请求处理器。
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 */
async function handler(req, res) {
  const url = new URL(req.url || '/', 'http://localhost')

  if (gate(req, res, url)) return

  // ── 健康检查（给 docker healthcheck 用）────────────────────────────
  if (url.pathname === '/healthz') {
    json(res, 200, { status: 'ok', service: 'paopaocat-studio-web', version: '0.1.0' })
    return
  }

  // ── 开发预览：文件变更戳 ──────────────────────────────────────────
  // public/__preview.html 轮询这里；戳一变就重载 iframe。
  // 只在 DEV_RELOAD=1 时开放，生产环境这条路由根本不存在。
  if (process.env.DEV_RELOAD === '1' && url.pathname === '/__dev/stamp') {
    try {
      const parts = []
      for (const dir of [PUBLIC_DIR, join(HERE, 'engines')]) {
        const entries = await readdir(dir, { withFileTypes: true })
        for (const e of entries) {
          if (!e.isFile()) continue
          const st = await stat(join(dir, e.name))
          parts.push(`${dir}/${e.name}:${st.mtimeMs}`)
        }
      }
      send(res, 200, parts.sort().join('|'), { 'Cache-Control': 'no-store' })
    } catch (error) {
      send(res, 500, String(error))
    }
    return
  }

  // ── 厂商表 ────────────────────────────────────────────────────────
  if (url.pathname === '/api/vendors' && req.method === 'GET') {
    // 手机 App 注入的厂商（`DSH_MOBILE_MODELS_FILE`）也要出现在这里 ——
    // 否则前端下拉里选不到用户手机上配的那家，等于白配。
    const device = readDeviceVendors()
    const ids = new Set([...Object.keys(VENDOR_BASE_URLS), ...Object.keys(device)])
    json(res, 200, {
      vendors: [...ids].map((id) => ({
        id,
        label: VENDOR_LABELS[id] || (device[id] ? device[id].label || id : id),
        baseUrl: VENDOR_BASE_URLS[id] || device[id]?.baseUrl || '',
        needsKey: !VENDOR_KEYLESS.has(id),
        fromDevice: Boolean(device[id]),
      })),
    })
    return
  }

  // ── 登录（设置口令 cookie）──────────────────────────────────────────
  if (url.pathname === '/api/login' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req, 4096))
      if (!safeEqual(String(body.token || ''), ACCESS_TOKEN)) {
        json(res, 401, { error: '口令不正确' })
        return
      }
      res.writeHead(200, {
        'Content-Type': 'application/json; charset=utf-8',
        // HttpOnly：脚本读不到；SameSite=Lax：够用且不挡隧道跳转
        'Set-Cookie': `psw_session=${encodeURIComponent(ACCESS_TOKEN)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000`,
      })
      res.end('{"ok":true}')
    } catch {
      json(res, 400, { error: '请求格式错误' })
    }
    return
  }

  // ── 厂商透传（核心）─────────────────────────────────────────────────
  if (url.pathname === '/api/proxy') {
    if (req.method !== 'POST') {
      json(res, 405, { error: 'method not allowed' })
      return
    }
    try {
      const parsed = JSON.parse(await readBody(req))
      // 密钥只从这里来，且只在本次调用内有效
      const headerKey = req.headers['x-vendor-key']
      const result = await proxyToVendor(parsed, typeof headerKey === 'string' ? headerKey : undefined)
      json(res, 200, result)
    } catch (error) {
      // 只有「用户没填 Key」才是 401；上游鉴权失败属于网关错误（502），
      // 否则前端会把「Key 填错了」误报成「还没填 Key」。
      const status = error?.code === 'NO_KEY' ? 401 : Number(error?.status) || 502
      json(res, status, { error: error instanceof Error ? error.message : String(error) })
    }
    return
  }

  // ── 公众号草稿推送（真推送，走微信 draft/add）────────────────────────
  //    放在引擎分支之前：引擎里那个 /wechat 的 publish 是占位（只改内存状态），
  //    这里才是真正把文章推到公众号草稿箱的链路。
  if (url.pathname === '/agnes-studio/api/wechat/token' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req, 4096))
      await getToken(String(body.appid || ''), String(body.secret || ''))
      json(res, 200, { success: true })
    } catch (error) {
      json(res, 502, { error: error instanceof Error ? error.message : String(error) })
    }
    return
  }

  if (url.pathname === '/agnes-studio/api/wechat/draft' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req, MAX_BODY))
      const result = await pushDraft(body)
      json(res, 200, { success: true, media_id: result.media_id })
    } catch (error) {
      json(res, 502, { error: error instanceof Error ? error.message : String(error) })
    }
    return
  }

  // ── 原插件的全部 API 分区（15 个）───────────────────────────────────
  //    生图 / 生视频 / 短剧 / 口播 / 画布 / 封面 / 创作台 / 背景视频 / MTV /
  //    小说工具 / 多能宝箱 / 视频解析 / 公众号 / 提示词专家 / 媒体 / 本地文件
  //    —— 全部交给 server/engines.bundle.mjs 里**原版的路由分发**，逻辑一行未改。
  //
  //    这里只做一件事：把当前请求携带的密钥放进 AsyncLocalStorage，
  //    让引擎内部那句 ctx.credentials.resolve() 读到「使用者自己的 Key」。
  if (url.pathname.startsWith('/agnes-studio/api')) {
    const keys = parseKeyHeaders(req.headers)
    requestStore.run({ keys }, () => {
      engineHandler(req, res).catch((error) => {
        console.error('[engines] 请求处理异常：', error)
        if (!res.headersSent) json(res, 500, { error: '引擎内部错误' })
        else res.end()
      })
    })
    return
  }

  // ── 静态资源 ──────────────────────────────────────────────────────
  if (req.method === 'GET' || req.method === 'HEAD') {
    await serveStatic(res, url.pathname)
    return
  }

  send(res, 404, 'not found')
}

/**
 * 可选 TLS：用自签证书让局域网地址也进入「安全上下文」。
 *
 * 为什么需要：浏览器的 File System Access API（showDirectoryPicker）只在安全上下文
 * 暴露，而 http://192.168.3.6:xxxx 这类局域网 IP 不是安全上下文——API 会是 undefined。
 * 设 TLS_CERT + TLS_KEY 两个路径即启用；没设或读不到就回落明文 HTTP（生产交给反代/隧道）。
 */
async function loadTls() {
  const certPath = process.env.TLS_CERT
  const keyPath = process.env.TLS_KEY
  if (!certPath || !keyPath) return null
  try {
    const [cert, key] = await Promise.all([readFile(certPath), readFile(keyPath)])
    return { cert, key }
  } catch (error) {
    console.warn('[studio-web] TLS 证书读取失败，回落 HTTP：', error instanceof Error ? error.message : error)
    return null
  }
}

const onRequest = (req, res) => {
  handler(req, res).catch((error) => {
    // 兜底：任何未捕获异常都不应该让进程挂掉
    console.error('[studio-web] 未捕获错误：', error)
    if (!res.headersSent) json(res, 500, { error: '服务器内部错误' })
    else res.end()
  })
}

const tls = await loadTls()
const server = tls ? createTlsServer(tls, onRequest) : createServer(onRequest)

server.listen(PORT, HOST, () => {
  console.log(`[studio-web] 泡泡猫影视工具 · 网页版`)
  console.log(`[studio-web] 监听 ${tls ? 'https' : 'http'}://${HOST}:${PORT}`)
  console.log(`[studio-web] 访问口令：${ACCESS_TOKEN ? '已开启' : '未开启（建议用 Cloudflare Access 或设 ACCESS_TOKEN）'}`)
  console.log(`[studio-web] 密钥来源：使用者自己的浏览器（x-vendor-keys 请求头），服务端不保存`)
  console.log(`[studio-web] 数据目录：${process.env.AGNES_DATA_DIR || '(系统临时目录)'}`)
})

// 优雅退出：容器收到 SIGTERM 时先停止接收新连接
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    console.log(`[studio-web] 收到 ${sig}，正在退出…`)
    server.close(() => process.exit(0))
    // 兜底强制退出，避免长连接把容器卡住
    setTimeout(() => process.exit(0), 5000).unref()
  })
}
