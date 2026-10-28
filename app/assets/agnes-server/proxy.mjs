/**
 * 厂商透传层 —— 服务端唯一与外部 API 打交道的地方。
 *
 * 与插件版的**唯一区别**：密钥来源。
 *   插件版：await resolveApiKeyForVendor(ctx, vendor)   ← 读 DSH 凭据 / 环境变量
 *   网页版：请求头 x-vendor-key                         ← 用户自己填，随请求来，用完即弃
 *
 * 网页版**不保存、不记录、不落盘**任何密钥。服务端只在本函数栈内存活一份。
 *
 * 错误语义（前端依赖，别改）：
 *   · 用户没填 Key        → err.code = 'NO_KEY'  → HTTP 401（前端提示去设置里填）
 *   · 上游拒绝/失败       → err.upstreamStatus   → HTTP 502（前端展示上游原文）
 *   两者必须分开，否则「Key 填错了」会被误报成「还没填 Key」。
 */

import { buildUpstreamUrl, getVendorFromModel, VENDOR_BASE_URLS } from './vendors.mjs'

/** 上游请求默认超时（与原插件一致）。 */
const DEFAULT_TIMEOUT_MS = 120_000

/** 临时性失败才值得重试的状态码。 */
const RETRYABLE_STATUS = new Set([408, 429, 500, 502, 503, 504])

/**
 * 判断本次调用该重试几次。
 *
 * 移植自插件版的策略，语义是经过实测的：
 *   - 生图：可安全重复，给 3 次（Agnes 会间歇性回 5xx）
 *   - 视频提交：**绝不重试**，重复提交会创建第二个任务并二次计费
 *   - GET（轮询）：给 2 次
 *   - 其他 POST：0 次
 *
 * @param {string} endpoint - 上游端点。
 * @param {string} method - GET / POST。
 * @returns {number} 重试次数。
 */
function retriesFor(endpoint, method) {
  const isImageGen = /\/images\/generations/.test(endpoint)
  const isVideoSubmit = /\/videos\/?$/.test(endpoint) && method === 'POST'
  if (isVideoSubmit) return 0
  if (isImageGen) return 3
  if (method === 'GET') return 2
  return 0
}

/**
 * 带超时与重试地请求上游，返回解析后的 JSON。
 *
 * @param {string} url - 完整上游 URL。
 * @param {{method: string, headers: Record<string,string>, body?: string, timeoutMs?: number, retries?: number}} opts
 * @returns {Promise<unknown>} 上游响应的 JSON。
 * @throws {Error} 网络错误、超时或非 2xx（错误信息里带上游原文，便于前端展示）。
 */
export async function vendorFetch(url, opts) {
  const { method, headers, body, timeoutMs = DEFAULT_TIMEOUT_MS, retries = 0 } = opts
  let lastError

  for (let attempt = 0; attempt <= retries; attempt++) {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    try {
      const finalHeaders = /opencode\.ai/i.test(String(url)) && !headers['x-opencode-session']
        ? { ...headers, 'x-opencode-session': opencodeSession() }
        : headers
      const resp = await fetch(url, { method, headers: finalHeaders, body, signal: controller.signal })
      const text = await resp.text()

      if (!resp.ok) {
        // 上游把错误详情放在 JSON 里时优先取出来，否则截断原文
        let detail = text.slice(0, 500)
        try {
          const parsed = JSON.parse(text)
          detail = parsed?.error?.message || parsed?.message || detail
        } catch { /* 非 JSON，保留原文 */ }

        const err = new Error(`上游 ${resp.status}：${detail}`)
        // 用 upstreamStatus 而不是 status，避免和「未提供 Key」的 401 混淆
        err.upstreamStatus = resp.status
        if (RETRYABLE_STATUS.has(resp.status) && attempt < retries) {
          lastError = err
          continue
        }
        throw err
      }

      try {
        return JSON.parse(text)
      } catch {
        throw new Error(`上游返回的不是 JSON：${text.slice(0, 200)}`)
      }
    } catch (error) {
      // 上游业务错误已经决定过要不要重试，直接透出
      if (error?.upstreamStatus !== undefined) throw error

      const isAbort = error?.name === 'AbortError'
      const err = isAbort ? new Error(`上游超时（${Math.round(timeoutMs / 1000)} 秒未响应）`) : error
      if (attempt < retries) {
        lastError = err
        continue
      }
      throw err
    } finally {
      clearTimeout(timer)
    }
  }

  throw lastError ?? new Error('上游请求失败')
}

/**
 * 解析本次请求该用的厂商与密钥。
 *
 * 优先级：请求里显式指定的 vendor > 从 model 名推断 > 默认 agnes。
 * Ollama 与任何指向本机地址的 baseUrl 都不需要密钥。
 *
 * @param {{vendor?: string, model?: string, baseUrl?: string}} parsed - 客户端入参。
 * @param {string|undefined} headerKey - 请求头 x-vendor-key。
 * @returns {{vendor: string, apiKey: string, baseUrl: string}}
 * @throws {Error} 该厂商需要密钥但没有提供时（code = NO_KEY）。
 */
export function resolveUpstream(parsed, headerKey) {
  const vendor = parsed.vendor || getVendorFromModel(parsed.model || '')
  const baseUrl = parsed.baseUrl || VENDOR_BASE_URLS[vendor] || VENDOR_BASE_URLS.agnes
  const isLocal =
    vendor === 'ollama' ||
    /^https?:\/\/(localhost|127\.0\.0\.1|host\.docker\.internal)/i.test(baseUrl)

  const apiKey = String(headerKey || '').trim()
  if (!apiKey && !isLocal) {
    const err = new Error(`未提供 ${vendor} 的 API Key —— 请在页面右上角「设置」里填入你自己的 Key。`)
    err.status = 401
    err.code = 'NO_KEY'
    throw err
  }

  return { vendor, apiKey, baseUrl }
}

/**
 * 执行一次透传。
 *
 * @param {{endpoint?: string, params?: unknown, method?: string, timeoutMs?: number, vendor?: string, model?: string, baseUrl?: string}} parsed
 * @param {string|undefined} headerKey - 请求头 x-vendor-key。
 * @returns {Promise<unknown>} 上游响应的 JSON。
 */
let _opencodeSession = ''
/** 一次进程内稳定的会话 id（OpenCode Go 用它做路由，值本身无状态）。 */
function opencodeSession() {
  if (!_opencodeSession) {
    _opencodeSession = 'studio-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10)
  }
  return _opencodeSession
}

export async function proxyToVendor(parsed, headerKey) {
  if (!parsed?.endpoint) {
    const err = new Error('缺少 endpoint')
    err.status = 400
    throw err
  }

  const { apiKey, baseUrl } = resolveUpstream(parsed, headerKey)
  const url = buildUpstreamUrl(baseUrl, parsed.endpoint)
  const method = parsed.method === 'GET' ? 'GET' : 'POST'

  const headers = { 'Content-Type': 'application/json' }
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`
  // OpenCode Go 缺这个头会直接 400 MissingSessionID（2026-10-29 真机）。
  if (parsed.vendor === 'opencode-go' || /opencode\.ai/i.test(baseUrl)) {
    headers['x-opencode-session'] = opencodeSession()
  }

  return vendorFetch(url, {
    method,
    headers,
    body: method === 'GET' ? undefined : JSON.stringify(parsed.params || {}),
    timeoutMs: parsed.timeoutMs || DEFAULT_TIMEOUT_MS,
    retries: retriesFor(parsed.endpoint, method),
  })
}
