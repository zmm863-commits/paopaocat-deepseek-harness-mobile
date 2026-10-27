/**
 * 厂商端点表 —— 唯一来源。
 *
 * 移植自 dsh-agnes-studio/src/vendors.ts（原表在插件里是同一个文件，
 * 因为曾有三份副本导致 Qwen 域名笔误被复制两遍）。
 * 网页版把这份表放在服务端，前端通过 GET /api/vendors 取。
 */

/** 厂商 → OpenAI 兼容端点基址。 */
export const VENDOR_BASE_URLS = {
  agnes: 'https://api.agnes-ai.cn/v1',
  deepseek: 'https://api.deepseek.com/v1',
  qwen: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  doubao: 'https://ark.cn-beijing.volces.com/api/v3',
  minimax: 'https://api.minimaxi.com/v1',
  ollama: 'http://localhost:11434/v1',
}

/** 厂商展示名（前端下拉用）。 */
export const VENDOR_LABELS = {
  agnes: 'Agnes',
  deepseek: 'DeepSeek',
  qwen: '通义千问 Qwen',
  doubao: '豆包 / 火山方舟',
  minimax: 'MiniMax',
  ollama: 'Ollama（本地）',
}

/** 哪些厂商不需要 API Key。 */
export const VENDOR_KEYLESS = new Set(['ollama'])

/**
 * 从模型名推断厂商。
 * @param {string} model - 模型 id，如 `deepseek-v4-flash`、`ollama:llama3`。
 * @returns {string} 厂商键；无法识别时回落 agnes。
 */
export function getVendorFromModel(model) {
  if (!model) return 'agnes'
  const m = String(model).toLowerCase()
  if (m.startsWith('ollama:')) return 'ollama'
  for (const prefix of Object.keys(VENDOR_BASE_URLS)) {
    if (prefix !== 'agnes' && m.startsWith(prefix)) return prefix
  }
  return 'agnes'
}

/**
 * 拼接厂商基址与客户端端点，避免版本段重复。
 *
 * 规则（移植自原插件的 buildUpstreamUrl，勿简化）：
 *   base .../v1 + /v1/images/...   → .../v1/images/...   （版本段去重）
 *   base .../v1 + /images/...      → .../v1/images/...
 *   base .../v1 + /v2/video_gen    → .../v2/video_gen    （以端点的版本为准）
 *   base .../v1 + /agnesapi?...    → .../v1/agnesapi?...
 *
 * 朴素的字符串拼接会产出 `.../v1/v1/...`，Agnes 会回 404——
 * 那正是插件早期「面板里每一次生图/生视频都失败」的根因。
 *
 * @param {string} baseUrl - 厂商基址。
 * @param {string} endpoint - 客户端传来的端点或查询串。
 * @returns {string} 可直接请求的 URL。
 */
export function buildUpstreamUrl(baseUrl, endpoint) {
  const base = String(baseUrl || '').replace(/\/+$/, '')
  const ep = '/' + String(endpoint || '').replace(/^\/+/, '')
  const baseVersion = base.match(/\/(v\d+[a-z0-9]*)$/i)
  const endpointVersion = ep.match(/^\/(v\d+[a-z0-9]*)(\/|$)/i)
  if (baseVersion && endpointVersion) {
    // 端点自带版本段：丢掉基址的版本段
    return base.slice(0, base.length - baseVersion[0].length) + ep
  }
  return base + ep
}
