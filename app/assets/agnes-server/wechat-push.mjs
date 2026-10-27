/**
 * 微信公众号草稿推送 —— 网页版后端模块
 *
 * 只发草稿箱，**不群发、不发布**（不调 message/mass/send，也不调 freepublish）。
 * 调用链与你之前（2026-09-26）跑通验证的 push-draft.mjs 完全一致：
 *   token → 上传封面(拿 thumb_media_id) → 上传正文图(换 url) → draft/add
 *
 * 依赖：Node 18+ 全局 fetch / FormData / Blob（本服务跑在 Node 22）。
 */

const WX_API = 'https://api.weixin.qq.com/cgi-bin'

/** 常见错误码的人话提示。 */
const ERR_HINT = {
  40164: '调用方 IP 不在公众号 IP 白名单里——请把服务器出网 IP 加进白名单',
  40013: 'AppID 无效',
  40125: 'AppSecret 无效',
  48001: '该账号没有草稿接口权限（草稿接口需要认证服务号）',
  45009: '接口调用达到上限，稍后再试',
  40001: 'access_token 无效或已过期',
}

/**
 * 调微信接口，统一处理 errcode。
 * @param {string} label 步骤名（用于报错定位）
 * @param {string} url
 * @param {RequestInit} [init]
 */
async function call(label, url, init) {
  const res = await fetch(url, init)
  const text = await res.text()
  let data
  try {
    data = JSON.parse(text)
  } catch {
    throw new Error(`${label}：微信返回非 JSON（HTTP ${res.status}）${text.slice(0, 200)}`)
  }
  if (data.errcode) {
    const hint = ERR_HINT[data.errcode] ? `：${ERR_HINT[data.errcode]}` : ''
    throw new Error(`${label} 失败（errcode=${data.errcode}）${data.errmsg}${hint}`)
  }
  return data
}

/**
 * 用 AppID / AppSecret 换 access_token（顺带验证凭据是否有效）。
 * @returns {Promise<string>} access_token
 */
export async function getToken(appid, secret) {
  const r = await call(
    '获取 access_token',
    `${WX_API}/token?grant_type=client_credential&appid=${encodeURIComponent(appid)}&secret=${encodeURIComponent(secret)}`,
  )
  return r.access_token
}

/** base64 data URL → Blob（微信素材上传用 FormData 收文件）。 */
function dataUrlToBlob(dataUrl, fallbackName) {
  const m = /^data:([^;]+);base64,(.+)$/s.exec(String(dataUrl || ''))
  if (!m) throw new Error(`${fallbackName} 不是有效的 base64 data URL`)
  const type = m[1] || 'image/png'
  const bytes = Buffer.from(m[2], 'base64')
  return { blob: new Blob([bytes], { type }), type, size: bytes.length }
}

/**
 * 上传封面（永久图片素材），返回 thumb_media_id。
 * @param {string} token
 * @param {string} base64 图片的 data URL
 * @param {string} [filename]
 */
export async function uploadCover(token, base64, filename = 'cover.png') {
  const { blob, type } = dataUrlToBlob(base64, filename)
  const fd = new FormData()
  // 微信要求媒体类型是 image/*；按实际 MIME 传
  fd.append('media', blob, filename.replace(/\.(png|jpg|jpeg)$/i, (m) => m))
  fd.append('type', type)
  const r = await call('上传封面', `${WX_API}/material/add_material?access_token=${token}&type=image`, {
    method: 'POST',
    body: fd,
  })
  return r.media_id
}

/**
 * 把纯文本转成微信草稿可用的 HTML 片段（按空行分段）。
 * @param {string} text
 */
function textToHtml(text) {
  const esc = (s) => String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  return String(text || '')
    .split(/\n+/)
    .map((line) => (line.trim() ? `<p>${esc(line.trim())}</p>` : ''))
    .join('')
}

/**
 * 完整推一篇草稿。
 *
 * @param {{
 *   appid: string, secret: string,
 *   title: string, author: string, digest: string, content: string,
 *   cover: string,            // 封面图 data URL（必填）
 * }} input
 * @returns {Promise<{ media_id: string }>}
 */
export async function pushDraft({ appid, secret, title, author, digest, content, cover }) {
  if (!appid || !secret) throw new Error('缺少 AppID 或 AppSecret')
  if (!title || !title.trim()) throw new Error('缺少标题')
  if (!content || !content.trim()) throw new Error('缺少正文')
  if (!cover) throw new Error('缺少封面图（公众号草稿必须带封面）')

  const token = await getToken(appid, secret)

  const thumbMediaId = await uploadCover(token, cover, 'cover.png')

  const article = {
    title: title.trim(),
    author: (author || 'AI 助手').trim(),
    digest: (digest || '').trim(),
    content: textToHtml(content),
    thumb_media_id: thumbMediaId,
    need_open_comment: 0,
    only_fans_can_comment: 0,
  }

  const r = await call('新建草稿', `${WX_API}/draft/add?access_token=${token}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: Buffer.from(JSON.stringify({ articles: [article] }), 'utf8'),
  })

  return { media_id: r.media_id }
}
