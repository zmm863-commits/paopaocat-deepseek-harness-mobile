/* ============================================================================
   泡泡猫影视工具 · 网页版 —— 交互逻辑
   零依赖、零构建。密钥存在本机 localStorage，随请求发给自己的后端转发。
   ========================================================================== */
'use strict'

// ═══════════════════════════════════════════════════════════════════════
// 配置
// ═══════════════════════════════════════════════════════════════════════

const IMAGE_MODELS = {
  'agnes-image-2.5-flash': 'Agnes Image 2.5 Flash（推荐）',
  'agnes-image-2.1-flash': 'Agnes Image 2.1 Flash',
  'agnes-image-2.0-flash': 'Agnes Image 2.0 Flash',
  'doubao-seedream-3-0': '豆包 Seedream 3.0',
  'minimax-image-01': 'MiniMax Image 01',
  'qwen-image-plus': 'Qwen Image Plus',
}

const VIDEO_MODELS = {
  'agnes-video-2.5-flash': 'Agnes Video 2.5 Flash（推荐）',
  'agnes-video-2.5': 'Agnes Video 2.5',
  'MiniMax-H3': 'MiniMax H3',
  'agnes-video-v2.0': 'Agnes Video 2.0',
  'minimax-video-01': 'MiniMax Video 01',
  'doubao-seaweed-t2v': '豆包 Seaweed T2V',
}

/** 各模型支持的尺寸（前缀匹配）。 */
const IMAGE_SIZES_BY_PREFIX = {
  'agnes-image': ['1024x1024', '1024x768', '768x1024', '1280x720', '720x1280'],
  'doubao-seedream': ['1024x1024', '864x1152', '1152x864', '1280x720', '720x1280'],
  'minimax-image': ['1024x1024', '1024x768', '768x1024', '1280x720', '720x1280'],
  'qwen-image': ['1024x1024', '1024x768', '768x1024', '1280x720', '720x1280'],
}
const DEFAULT_SIZES = ['1024x1024', '1024x768', '768x1024', '1280x720', '720x1280']

const VENDOR_PREFIXES = ['deepseek', 'qwen', 'doubao', 'minimax', 'ollama']

/** 密钥设置里的厂商清单。 */
// 分组说明（实测 2026-10-20）：
//   一个 Agnes Key 就能覆盖 写作 / 拆书 / 读图 / 画图 / 生视频 —— 实测全部 200。
//   Agnes **没有音频模型**（模型列表里 0 个音频类，agnes-tts 返回 model_not_found），
//   所以「文字转语音」必须再填一家 MiniMax（或用本地 MiMo）。
// 每个厂商：group = core（填一个就够）/ optional；site = 注册地址；hint = 怎么拿到
// 每个厂商：
//   site  = 去注册/拿 Key 的地址
//   steps = 分步开通说明（很多厂家开通很绕，光给个网址等于没说）
//   notes = 容易踩的坑
//   free  = 免费额度情况（不确定的写「以控制台为准」，不编具体数字）
const VENDORS = [
  {
    id: 'agnes', label: 'Agnes', recommended: true, group: 'core',
    site: 'https://platform.agnes-ai.cn',
    steps: ['用邮箱注册并登录', '左侧「API Keys」→ 新建', '复制那串 sk- 开头的密钥'],
    notes: ['注册后就有免费额度，够先试很久'],
    free: '注册即送免费额度',
  },
  {
    id: 'deepseek', label: 'DeepSeek', group: 'optional',
    site: 'https://platform.deepseek.com/api_keys',
    steps: ['手机号或邮箱注册', '左侧「API keys」→「创建 API key」', '复制它（只显示一次，关掉就看不到了）'],
    notes: ['账户里要有余额才能调用，新号可能得先充值', '本站能直接查出它的余额'],
  },
  {
    id: 'qwen', label: '通义千问 Qwen', group: 'optional',
    site: 'https://bailian.console.aliyun.com/',
    steps: [
      '用阿里云账号登录（没有就先注册，并完成实名认证）',
      '首次进入会提示开通「百炼大模型服务」，点开通',
      '右上角「API-KEY」→ 创建 → 复制',
    ],
    notes: ['实名认证是硬门槛，没实名用不了', '画图（万相）、视频要在百炼里单独开通对应模型'],
  },
  {
    id: 'doubao', label: '豆包 / 火山方舟', group: 'optional',
    site: 'https://console.volcengine.com/ark',
    steps: [
      '注册火山引擎账号并完成实名认证',
      '进入「火山方舟」控制台 → 左侧「开通管理」→ 把要用的模型逐个点「开通」',
      '左侧「API Key 管理」→ 创建 → 复制',
    ],
    notes: ['最容易漏第 2 步：模型不开通，填了 Key 也会报错', '每个模型单独开通、单独计费'],
  },
  {
    id: 'minimax', label: 'MiniMax', group: 'optional', forVoice: true,
    site: 'https://platform.minimaxi.com/',
    steps: ['手机号注册登录', '「账户管理」→「接口密钥」→ 创建', '复制密钥'],
    notes: ['文本 / 图像 / 视频 / 语音各自计费', '本站的「文字转语音」用它最自然'],
  },
  {
    id: 'zhipu', label: '智谱 GLM', group: 'optional',
    site: 'https://open.bigmodel.cn/',
    steps: ['手机号注册登录', '进「API Keys」→ 创建 → 复制', '文本选 glm-4-flash 系列（免费）'],
    notes: ['glm-4-flash 系列免费，但有速率限制', 'CogView（画图）/ CogVideo（视频）是收费的'],
    free: 'glm-4-flash / glm-4v-flash 等 flash 系列免费',
  },
  {
    id: 'mimo', label: 'MiMo（小米，配音专用）', group: 'optional', forVoice: true,
    site: 'https://platform.xiaomimimo.com/',
    steps: ['注册并登录', '进控制台创建 API Key', '复制密钥'],
    notes: ['tp- 开头的是套餐版密钥，会自动走对应节点', '只有「口播」这个功能用它'],
  },
  {
    id: 'ollama', label: 'Ollama（本地服务）', keyless: true, group: 'optional',
    site: 'https://ollama.com/download',
    steps: ['在自己电脑上装 Ollama 并启动', '拉一个模型（如 ollama pull llama3）', '本站在 http://localhost:11434 连它'],
    notes: ['完全免费、不联网、不用 Key', '模型越大越吃内存，速度也越慢'],
    free: '完全免费',
  },
]

/** 官方标注免费的模型（其余按量计费）。 */
const FREE_MODEL_PATTERNS = [/^glm-.*flash/i, /^glm-4v-flash/i, /^glm-z1-flash/i]

/** 这个模型是否免费。 */
function isFreeModel(id) {
  const m = String(id || '')
  return FREE_MODEL_PATTERNS.some((re) => re.test(m))
}

const STORE_KEY = 'psw_vendor_keys'
const BUILD_ID = '2026-09-30 10:20 · redesigned'

// ═══════════════════════════════════════════════════════════════════════
// 小工具
// ═══════════════════════════════════════════════════════════════════════

const $ = (id) => document.getElementById(id)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** 从模型名推断厂商（与服务端 vendors.mjs 规则一致）。 */
// 模型名前缀 → 厂商（与后端 vendors.ts 的 VENDOR_MODEL_PREFIXES 保持一致）
const MODEL_PREFIX_VENDOR = [
  [['glm', 'cogview', 'cogvideo', 'charglm'], 'zhipu'],
  [['deepseek'], 'deepseek'],
  [['qwen', 'wanx'], 'qwen'],
  [['doubao', 'seedream', 'seedance'], 'doubao'],
  [['minimax', 'abab', 'hailuo', 't2a'], 'minimax'],
  [['mimo'], 'mimo'],
]

function vendorOf(model) {
  const m = String(model || '').toLowerCase()
  if (m.startsWith('ollama:')) return 'ollama'
  for (const [prefixes, vendor] of MODEL_PREFIX_VENDOR) {
    if (prefixes.some((p) => m.startsWith(p))) return vendor
  }
  for (const p of VENDOR_PREFIXES) if (m.startsWith(p)) return p
  return 'agnes'
}

/** 取某模型可用的尺寸列表。 */
function sizesFor(model) {
  const m = String(model || '').toLowerCase()
  for (const [prefix, list] of Object.entries(IMAGE_SIZES_BY_PREFIX)) {
    if (m.startsWith(prefix)) return [...list, ...DEFAULT_SIZES.filter((s) => !list.includes(s))]
  }
  return DEFAULT_SIZES
}

/** 把 <select> 填满并选中默认项。 */

/**
 * 把某个厂商**真实可用**的模型列表填进下拉。
 *
 * 原来所有下拉都是写死的常量：用户填了什么 Key、那个账号有哪些模型，
 * 界面完全不知道，于是可能选到账号里根本没有的模型、一跑就报错。
 * 这里做成渐进增强 —— 先保留内置默认（保证下拉永不为空），拉到真实列表再替换。
 */
// ═══════════════════════════════════════════════════════════════════════
// 模型说明书
//
// 问题：模型的真实列表拉回来是一串 ID（agnes-2.5-flash、agnes-video-2.5…），
// 使用者不知道该选哪个；更糟的是**所有模型被塞进所有下拉**——生图的下拉里
// 会混进视频模型，选了就报错。
//
// 做法：按名字判定用途（text/image/video/audio），各下拉只列自己那一类，
// 并给每个模型配一句中文说明；每类标一个推荐项。
// ═══════════════════════════════════════════════════════════════════════

const MODEL_KIND_RULES = [
  [/image|flux|sdxl|dall-?e|midjourney|recraft|imagen|kolors|seedream/i, 'image'],
  [/video|kling|veo-?\d|seedance|hailuo|runway|wan-?\d|sora|pika/i, 'video'],
  [/tts|speech|audio|music|suno|voice|cosyvoice/i, 'audio'],
]

/** 模型名 → 'text' | 'image' | 'video' | 'audio'。 */
function modelKind(id) {
  const s = String(id || '')
  for (const [re, kind] of MODEL_KIND_RULES) if (re.test(s)) return kind
  return 'text'
}

/** 已知模型的中文说明：[用途, 什么时候该用它]。 */
const MODEL_NOTES = {
  'agnes-3.0-flash': ['文本 · 快', '日常写作、改写、起名，最常用'],
  'agnes-3.0-pro': ['文本 · 强', '长篇小说、复杂推理，慢一些'],
  'agnes-2.5-flash': ['文本 · 快', '轻量任务；也能读图'],
  'agnes-2.5-pro': ['文本 · 强', '复杂写作'],
  'agnes-2.5-pro-alpha': ['文本 · 实验', '尝鲜版，可能不稳定'],
  'agnes-2.5-pro-beta': ['文本 · 实验', '尝鲜版，可能不稳定'],
  'agnes-image-2.5-flash': ['图像 · 快', '出图首选'],
  'agnes-image-2.1-flash': ['图像 · 旧版', '旧版出图'],
  'agnes-video-2.5-flash': ['视频 · 快', '生视频首选'],
  'agnes-video-2.5': ['视频 · 标准', '画质更好但更慢'],
  'deepseek-chat': ['文本 · 通用', 'DeepSeek 对话模型'],
  'deepseek-reasoner': ['文本 · 推理', '擅长数学与逻辑，慢'],
  'qwen-plus': ['文本 · 通用', '通义千问'],
  'qwen-max': ['文本 · 强', '通义千问旗舰'],
  'doubao-pro-32k': ['文本 · 通用', '豆包'],
  'MiniMax-Text-01': ['文本 · 通用', 'MiniMax 文本'],
  'llama3': ['文本 · 本地', 'Ollama 本地模型，不花钱'],
}

/** 每类的推荐默认。 */
const MODEL_PICK = {
  text: 'agnes-3.0-flash',
  image: 'agnes-image-2.5-flash',
  video: 'agnes-video-2.5-flash',
  audio: 'speech-01-turbo',
}

const KIND_LABEL = { text: '文本', image: '图像', video: '视频', audio: '音频' }

/** 取某模型的说明；未知模型按类型给通用说明。 */
function modelNote(id, kind) {
  if (MODEL_NOTES[id]) return MODEL_NOTES[id]
  const k = kind || modelKind(id)
  const fallback = {
    text: ['文本', '按名字看是文本模型'],
    image: ['图像', '按名字看是图像模型'],
    video: ['视频', '按名字看是视频模型'],
    audio: ['音频', '按名字看是音频模型'],
  }
  return fallback[k]
}

/**
 * 把一串模型 ID 整理成「按用途分组 + 中文说明」的清单。
 * 设置页点「测试这些 Key」后就能看到账号里到底有什么、分别用在哪。
 */
function formatModelCatalog(models) {
  if (!models || !models.length) return '这一家没有返回可用模型'
  const groups = { text: [], image: [], video: [], audio: [] }
  for (const m of models) groups[modelKind(m)].push(m)
  const order = ['text', 'image', 'video', 'audio']
  const parts = []
  for (const k of order) {
    const list = groups[k]
    if (!list.length) continue
    const rows = list.map((m) => {
      const [, note] = modelNote(m, k)
      const star = m === MODEL_PICK[k] ? '★ ' : '· '
      return `${star}<b>${m}</b> — ${note}`
    })
    parts.push(`<div class="kt-group"><span class="kt-kind">${KIND_LABEL[k]}模型 ${list.length} 个</span><br>${rows.join('<br>')}</div>`)
  }
  return parts.join('')
}

/** 在下拉下方放一句「现在选的是什么、该选哪个」。 */
function ensureModelHint(sel) {
  const box = sel.parentElement
  if (!box) return null
  let hint = box.querySelector('.model-hint')
  if (!hint) {
    hint = document.createElement('p')
    hint.className = 'hint model-hint'
    box.appendChild(hint)
  }
  return hint
}

function paintModelHint(sel, kind) {
  const hint = ensureModelHint(sel)
  if (!hint) return
  const id = sel.value
  const [label, note] = modelNote(id, kind)
  const pick = MODEL_PICK[kind]
  const isPick = pick && id === pick
  hint.textContent = `当前：${id} —— ${label}，${note}` +
    (isPick ? '（这一类的推荐项）' : (pick ? `。拿不准就选 ${pick}` : ''))
}

/** 按类型重填下拉；label 带中文说明，推荐项标 ★。 */
function fillModelSelect(sel, models, kind) {
  if (!sel) return
  const list = (models || []).filter(m => modelKind(m) === kind)
  if (!list.length) return
  const keep = sel.value
  const pick = MODEL_PICK[kind]
  const frag = document.createDocumentFragment()
  for (const m of list) {
    const [label] = modelNote(m, kind)
    const o = document.createElement('option')
    o.value = m
    // ★ 推荐、🆓 官方免费 —— 用户最想知道的就是这两个
    o.textContent = (m === pick ? '★ ' : '') + (isFreeModel(m) ? '🆓 ' : '') + m + ' · ' + label
    frag.appendChild(o)
  }
  sel.replaceChildren(frag)
  const has = (v) => Array.from(sel.options).some((o) => o.value === v)
  if (has(keep)) sel.value = keep
  else if (pick && has(pick)) sel.value = pick
  else sel.value = list[0]
  paintModelHint(sel, kind)
}

async function refreshModelSelect(sel, vendor, preferred, kind) {
  if (!sel || !hasAnyKey()) return
  const k = kind || 'text'
  try {
    const r = await fetch(`/agnes-studio/api/models?vendor=${encodeURIComponent(vendor)}`, {
      headers: { 'x-vendor-keys': JSON.stringify(keys) },
    })
    const d = await r.json()
    const list = Array.isArray(d.models) ? d.models : []
    if (!list.length) return
    // 只把这一类的模型填进来 —— 生图下拉不该出现视频模型
    fillModelSelect(sel, list, k)
    if (preferred && Array.from(sel.options).some((o) => o.value === preferred)) {
      sel.value = preferred
    }
    paintModelHint(sel, k)
  } catch {
    /* 拉不到就保持内置默认，不打扰用户 */
  }
}

/** 给自由输入的模型名加 datalist 建议（这些位置允许填任意模型）。 */
async function attachModelSuggest(input, vendor, kind) {
  if (!input || !hasAnyKey()) return
  try {
    const r = await fetch(`/agnes-studio/api/models?vendor=${encodeURIComponent(vendor)}`, {
      headers: { 'x-vendor-keys': JSON.stringify(keys) },
    })
    const d = await r.json()
    const list = (Array.isArray(d.models) ? d.models : []).filter((m) => modelKind(m) === (kind || 'text'))
    if (!list.length) return
    const dlId = input.id + '-dl'
    let dl = document.getElementById(dlId)
    if (!dl) {
      dl = document.createElement('datalist')
      dl.id = dlId
      input.setAttribute('list', dlId)
      input.parentElement.appendChild(dl)
    }
    dl.replaceChildren()
    for (const m of list) {
      const o = document.createElement('option')
      o.value = m
      dl.appendChild(o)
    }
  } catch { /* 忽略 */ }
}

function fillSelect(el, entries, selected) {
  if (!el) return
  el.replaceChildren()
  for (const [value, label] of Object.entries(entries)) {
    const o = document.createElement('option')
    o.value = value
    o.textContent = label
    el.appendChild(o)
  }
  if (selected && entries[selected]) el.value = selected
}

// ═══════════════════════════════════════════════════════════════════════
// 密钥（只在本机浏览器里）
// ═══════════════════════════════════════════════════════════════════════

/** @type {Record<string,string>} */
let keys = {}

function loadKeys() {
  try {
    const raw = localStorage.getItem(STORE_KEY)
    keys = raw ? (JSON.parse(raw) || {}) : {}
  } catch { keys = {} }
}

function persistKeys() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(keys)) } catch { /* 隐私模式可能不可写 */ }
}

function hasAnyKey() {
  return Object.values(keys).some((v) => v && String(v).trim())
}

function updateKeyDot() {
  const dot = $('keyDot')
  if (dot) dot.dataset.ok = hasAnyKey() ? 'true' : 'false'
}

function renderKeyFields() {
  const box = $('keyFields')
  if (!box) return
  box.replaceChildren()

  // 先渲染「填一个就够」的核心厂商，再把可选的收进折叠 ——
  // 六个输入框一字排开会让小白以为必须全填。
  const core = VENDORS.filter((v) => v.group === 'core')
  const optional = VENDORS.filter((v) => v.group !== 'core')

  const makeItem = (v) => {
    const item = document.createElement('div')
    item.className = 'key-item'

    const label = document.createElement('label')
    label.textContent = v.label
    if (v.recommended) {
      const tag = document.createElement('span')
      tag.className = 'reco-tag'
      tag.textContent = '推荐先用这个'
      label.appendChild(tag)
    }
    if (v.keyless) {
      const tag = document.createElement('span')
      tag.className = 'local-tag'
      tag.textContent = '（本地服务，无需密钥）'
      label.appendChild(tag)
    }
    // 「去哪拿 Key」——小白最卡的一步，直接把地址给出来，可点击
    if (v.site) {
      const a = document.createElement('a')
      a.className = 'key-site'
      a.href = v.site
      a.target = '_blank'
      a.rel = 'noopener noreferrer'
      a.textContent = v.keyless ? '去下载 →' : '去注册 / 拿 Key →'
      label.appendChild(a)
    }

    const input = document.createElement('input')
    input.type = 'password'
    input.autocomplete = 'off'
    input.spellcheck = false
    input.placeholder = v.keyless ? '无需填写' : `粘贴你的 ${v.label} API Key`
    input.value = keys[v.id] || ''
    input.dataset.vendor = v.id
    input.disabled = v.keyless === true

    item.append(label, input)

    // 免费额度：有就明说，让用户先知道哪家不用花钱
    if (v.free) {
      const f = document.createElement('p')
      f.className = 'hint key-free'
      f.textContent = '🆓 ' + v.free
      item.appendChild(f)
    }

    // 分步开通说明 —— 很多厂家开通很绕，只给网址等于没说
    if (Array.isArray(v.steps) && v.steps.length) {
      const ol = document.createElement('ol')
      ol.className = 'key-steps'
      for (const st of v.steps) {
        const li = document.createElement('li')
        li.textContent = st
        ol.appendChild(li)
      }
      item.appendChild(ol)
    }

    // 容易踩的坑
    if (Array.isArray(v.notes) && v.notes.length) {
      const ul = document.createElement('ul')
      ul.className = 'key-notes'
      for (const n of v.notes) {
        const li = document.createElement('li')
        li.textContent = n
        ul.appendChild(li)
      }
      item.appendChild(ul)
    }
    return item
  }

  for (const v of core) box.appendChild(makeItem(v))

  if (optional.length) {
    const details = document.createElement('details')
    details.className = 'advanced key-optional'
    const summary = document.createElement('summary')
    summary.textContent = '可选 · 想换别家模型、或需要「文字转语音」时再填'
    details.appendChild(summary)
    const tip = document.createElement('p')
    tip.className = 'hint'
    tip.style.margin = '10px 12px 0'
    tip.innerHTML =
      '不填这些也能用全部功能。<br>' +
      '<b>唯一的例外是带语音的两个功能</b>，各要一家（Agnes 没有语音模型）：<br>' +
      '· <b>文字转语音</b>（工具箱）→ 填 <b>MiniMax</b><br>' +
      '· <b>口播配音</b> → 填 <b>MiMo</b><br>' +
      '不想花钱就只在本地跑 Ollama，或用已有的 Key。'
    details.appendChild(tip)
    for (const v of optional) details.appendChild(makeItem(v))
    box.appendChild(details)
  }
}

// ═══════════════════════════════════════════════════════════════════════
// 后端调用
// ═══════════════════════════════════════════════════════════════════════

/**
 * 走自己后端的透传。密钥按厂商从本机取，放请求头。
 * @param {string} endpoint 厂商端点（如 /v1/images/generations）
 * @param {unknown} params
 * @param {'POST'|'GET'} method
 * @param {{vendor?: string, model?: string}} [opts]
 */
async function callProxy(endpoint, params, method = 'POST', opts = {}) {
  // 小白最容易卡在这一步：没填 Key 时服务端会回
  // 「请在本机 .env 写入 AGNES_API_KEY=... 或在 DSH 凭据(credentials)中新增 …」，
  // 对使用者这等于天书，而且他根本不知道要去哪填。所以在发请求前就拦下来。
  if (!opts.skipKeyCheck && !hasAnyKey()) {
    const e = new Error('还没有填 API Key —— 点顶部「设置」填一个就能开始用了（去 agnes 平台免费注册即可，其他地方不用配）')
    e.needKey = true
    throw e
  }
  const vendor = opts.vendor || vendorOf(opts.model || (params && params.model) || '')
  const key = (keys[vendor] || '').trim()

  // 填了别的厂商的 Key，但这次要用的厂商没填 —— 同样说清楚缺哪个
  if (!opts.skipKeyCheck && !key && vendor !== 'ollama') {
    const e = new Error(`这次要用的「${vendor}」还没填 Key —— 去顶部「设置」补上它，或在上面的「高级设置」里换成你已经填过的厂商`)
    e.needKey = true
    throw e
  }

  const resp = await fetch('/agnes-studio/api/proxy', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(hasAnyKey() ? { 'x-vendor-keys': JSON.stringify(keys) } : {}),
    },
    body: JSON.stringify({ endpoint, params, method, vendor, model: opts.model }),
  })

  let data = {}
  try { data = await resp.json() } catch { /* 上游没回 JSON */ }

  if (!resp.ok) {
    const msg = String(data.error || `请求失败（HTTP ${resp.status}）`)
    if (!key && /未配置|no api key|401/i.test(msg)) {
      throw new Error('还没有配置 API Key —— 到「设置」里填一把你自己的。')
    }
    throw new Error(msg.slice(0, 300))
  }
  if (data.error) throw new Error(String(data.error).slice(0, 300))
  return data
}

// ═══════════════════════════════════════════════════════════════════════
// 结果卡片
// ═══════════════════════════════════════════════════════════════════════

function makePendingCard(kind) {
  const card = document.createElement('div')
  card.className = 'result pending'
  card.textContent = kind === 'video' ? '生成中…' : '绘制中…'
  return card
}


/**
 * 把生成结果静默归档进资料库。
 * 失败不打扰用户 —— 归档是加分项，不该让一次成功的生成看起来像失败。
 */
function archiveToLibrary(url, kind, name) {
  if (!url) return
  fetch('/agnes-studio/api/library/save', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url, kind, name }),
  }).catch(() => { /* 静默 */ })
}

function fillResultCard(card, kind, url, caption) {
  card.className = 'result'
  card.replaceChildren()

  const media = document.createElement(kind === 'video' ? 'video' : 'img')
  media.src = url
  if (kind === 'video') {
    media.controls = true
    media.playsInline = true
    media.preload = 'metadata'
  } else {
    media.alt = caption
    media.loading = 'lazy'
  }

  const meta = document.createElement('div')
  meta.className = 'meta'
  const text = document.createElement('p')
  text.textContent = caption
  const link = document.createElement('a')
  link.href = url
  link.target = '_blank'
  link.rel = 'noopener'
  link.textContent = kind === 'video' ? '打开成片' : '打开原图'

  meta.append(text, link)
  card.append(media, meta)
}

function fillErrorCard(card, message) {
  card.className = 'result failed'
  card.textContent = `❌ ${message}`
}

// ═══════════════════════════════════════════════════════════════════════
// 生图
// ═══════════════════════════════════════════════════════════════════════

async function generateOneImage(model, prompt, size) {
  const params = { model, prompt, size, extra_body: { response_format: 'url' } }
  const data = await callProxy('/v1/images/generations', params, 'POST', { model })
  const first = Array.isArray(data.data) ? data.data[0] : null
  if (first && first.url) return first.url
  if (first && first.b64_json) return `data:image/png;base64,${first.b64_json}`
  throw new Error('上游未返回图片地址')
}

async function onGenerateImages() {
  const model = $('imgModel').value
  const prompt = $('imgPrompt').value.trim()
  const size = $('imgSize').value
  const count = Math.min(4, Math.max(1, Number($('imgCount').textContent) || 1))
  const hint = $('imgHint')
  const btn = $('imgGenBtn')
  const results = $('imgResults')

  hint.className = 'hint'
  hint.textContent = ''
  if (!prompt) {
    hint.className = 'hint error'
    hint.textContent = '先写一句画面描述'
    return
  }

  btn.disabled = true
  btn.setAttribute('aria-busy', 'true')
  btn.textContent = '生成中…'
  hint.textContent = `正在生成 ${count} 张…`

  const cards = []
  for (let i = 0; i < count; i++) {
    const card = makePendingCard('image')
    results.prepend(card)
    cards.push(card)
  }

  let ok = 0
  await Promise.all(cards.map(async (card) => {
    try {
      const url = await generateOneImage(model, prompt, size)
      fillResultCard(card, 'image', url, prompt.slice(0, 40))
      archiveToLibrary(url, 'image', 'img-' + Date.now() + '-' + (i + 1))
      ok++
    } catch (error) {
      fillErrorCard(card, error instanceof Error ? error.message : String(error))
    }
  }))

  hint.className = ok > 0 ? 'hint ok' : 'hint error'
  hint.textContent = ok > 0 ? `完成 ${ok}/${count} 张` : '全部失败'
  btn.disabled = false
  btn.removeAttribute('aria-busy')
  btn.textContent = '生成图片'
}

// ═══════════════════════════════════════════════════════════════════════
// 生视频
// ═══════════════════════════════════════════════════════════════════════

async function submitVideo(model, prompt, opts) {
  const { seconds, aspectRatio, size } = opts

  // Agnes Video 2.5 用专用参数
  if (model.startsWith('agnes-video-2.5')) {
    const params = { model, prompt, mode: 'text', seconds, size, aspect_ratio: aspectRatio }
    return String((await callProxy('/v1/videos', params, 'POST', { model })).video_id || '')
  }

  // MiniMax H3 走 V2 接口
  if (model.toLowerCase().includes('minimax') && model.includes('H3')) {
    const params = { model, prompt, duration: parseInt(seconds, 10), resolution: size, ratio: aspectRatio }
    return String((await callProxy('/v2/video_generation', params, 'POST', { model })).task_id || '')
  }

  // 其余模型走通用参数
  const params = {
    model, prompt,
    width: 1152, height: 768,
    num_frames: parseInt(seconds, 10) * 24,
    frame_rate: 24,
  }
  return String((await callProxy('/v1/videos', params, 'POST', { model })).video_id || '')
}

/** 轮询任务直到出片。 */
async function pollVideo(videoId, model, onProgress) {
  const deadline = Date.now() + 10 * 60 * 1000
  let ticks = 0

  while (Date.now() < deadline) {
    await sleep(4000)
    ticks++
    const resp = await callProxy(
      `/agnesapi?video_id=${encodeURIComponent(videoId)}&model_name=${encodeURIComponent(model)}`,
      undefined, 'GET', { vendor: 'agnes', model },
    )

    const status = String(resp.status || '')
    const progress = Number(resp.progress || 0)

    if (status === 'completed') {
      const meta = resp.metadata || {}
      const url = String(resp.url || meta.url || '')
      if (!url) throw new Error('任务完成了但没拿到成片地址')
      onProgress(100, '已完成')
      return url
    }
    if (status === 'failed') {
      const err = resp.error
      throw new Error(typeof err === 'string' ? err : (err && err.message) || '视频生成失败')
    }

    const shown = progress > 0 ? progress : Math.min(90, ticks * 5)
    onProgress(shown, `生成中… ${shown}%`)
  }
  throw new Error('等待超时（10 分钟）')
}

async function onGenerateVideo() {
  const model = $('vidModel').value
  const prompt = $('vidPrompt').value.trim()
  const seconds = $('vidSeconds').value
  const aspectRatio = $('vidRatio').value
  const size = $('vidSize').value

  const hint = $('vidHint')
  const btn = $('vidGenBtn')
  const wrap = $('vidProgressWrap')
  const bar = $('vidProgressBar')
  const ptext = $('vidProgressText')
  const results = $('vidResults')

  hint.className = 'hint'
  hint.textContent = ''
  if (!prompt) {
    hint.className = 'hint error'
    hint.textContent = '先写一句视频描述'
    return
  }

  btn.disabled = true
  btn.setAttribute('aria-busy', 'true')
  btn.textContent = '生成中…'
  wrap.hidden = false
  bar.style.width = '0%'
  ptext.textContent = '提交任务…'

  const card = makePendingCard('video')
  results.prepend(card)

  try {
    const videoId = await submitVideo(model, prompt, { seconds, aspectRatio, size })
    if (!videoId) throw new Error('上游没返回任务 id')
    ptext.textContent = '任务已提交，等待生成…'

    const url = await pollVideo(videoId, model, (pct, label) => {
      bar.style.width = `${Math.min(100, pct)}%`
      ptext.textContent = label
    })

    fillResultCard(card, 'video', url, prompt.slice(0, 40))
    hint.className = 'hint ok'
    hint.textContent = '视频生成完成'
  } catch (error) {
    fillErrorCard(card, error instanceof Error ? error.message : String(error))
    hint.className = 'hint error'
    hint.textContent = '生成失败'
  } finally {
    btn.disabled = false
    btn.removeAttribute('aria-busy')
    btn.textContent = '生成视频'
    setTimeout(() => { wrap.hidden = true }, 2500)
  }
}

// ═══════════════════════════════════════════════════════════════════════
// 导航
// ═══════════════════════════════════════════════════════════════════════

function showPanel(id) {
  for (const tab of document.querySelectorAll('.tab')) {
    const on = tab.dataset.panel === id
    tab.classList.toggle('active', on)
    tab.setAttribute('aria-selected', on ? 'true' : 'false')
    if (on) tab.scrollIntoView({ block: 'nearest', inline: 'center', behavior: 'smooth' })
  }
  for (const panel of document.querySelectorAll('.panel')) {
    panel.classList.toggle('active', panel.dataset.panel === id)
  }
  const content = $('content')
  if (content) content.scrollTop = 0
}

// ═══════════════════════════════════════════════════════════════════════
// 初始化
// ═══════════════════════════════════════════════════════════════════════

function init() {
  loadKeys()
  updateKeyDot()

  fillSelect($('imgModel'), IMAGE_MODELS, 'agnes-image-2.5-flash')
  fillSelect($('vidModel'), VIDEO_MODELS, 'agnes-video-2.5-flash')
  // 再异步换成「这家 Key 真实能用的模型」（拉不到就保留上面的内置默认）
  void refreshModelSelect($('imgModel'), 'agnes', 'agnes-image-2.5-flash', 'image')
  void refreshModelSelect($('vidModel'), 'agnes', 'agnes-video-2.5-flash', 'video')
  const sizes = sizesFor('agnes-image-2.5-flash')
  fillSelect($('imgSize'), Object.fromEntries(sizes.map((s) => [s, s])), '1024x1024')

  // 换模型 → 换尺寸选项
  $('imgModel').addEventListener('change', (e) => {
    const list = sizesFor(e.target.value)
    fillSelect($('imgSize'), Object.fromEntries(list.map((s) => [s, s])), list[0])
  })

  // Tab 切换
  for (const tab of document.querySelectorAll('.tab')) {
    tab.addEventListener('click', () => showPanel(tab.dataset.panel))
  }


  // 右上角齿轮 → 设置面板
  $('settingsBtn').addEventListener('click', () => showPanel('settings'))

  // 张数步进器
  const stepper = $('imgCountStepper')
  if (stepper) {
    stepper.addEventListener('click', (e) => {
      const btn = e.target.closest('button[data-step]')
      if (!btn) return
      const out = $('imgCount')
      const next = Math.min(4, Math.max(1, Number(out.textContent) + Number(btn.dataset.step)))
      out.textContent = String(next)
    })
  }

  // 快捷提示词
  const presets = $('imgPresets')
  if (presets) {
    presets.addEventListener('click', (e) => {
      const chip = e.target.closest('.chip')
      if (!chip) return
      const box = $('imgPrompt')
      const add = chip.dataset.fill || ''
      box.value = box.value.trim() ? `${box.value.trim()}，${add}` : add
      box.focus()
    })
  }

  // 生成
  $('imgGenBtn').addEventListener('click', onGenerateImages)
  $('vidGenBtn').addEventListener('click', onGenerateVideo)

  // Ctrl/Cmd + Enter 直接生成
  $('imgPrompt').addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); onGenerateImages() }
  })
  $('vidPrompt').addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); onGenerateVideo() }
  })


  // ── 测试 Key：告诉使用者「能不能用、能用哪些模型」 ──────────────────
  $('testKeys')?.addEventListener('click', async () => {
    const box = $('keyTestResult')
    const btn = $('testKeys')
    if (!box) return
    if (!hasAnyKey()) {
      box.hidden = false
      box.innerHTML = '<div class="key-test"><p class="note">还没填任何 Key —— 先上面填一个再测。</p></div>'
      return
    }
    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    box.hidden = false
    box.innerHTML = '<div class="key-test"><p class="hint">正在测试…（每家会先拉模型列表，拉不到就发一个最小请求验证）</p></div>'
    try {
      const r = await fetch('/agnes-studio/api/keys/test', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-vendor-keys': JSON.stringify(keys) },
        body: '{}',
      })
      const d = await r.json()
      const list = Array.isArray(d.results) ? d.results : []
      const rows = list.map((x) => {
        const badge = x.ok ? '<span class="kt-ok">能用</span>' : (x.skipped ? '<span class="kt-skip">未填</span>' : '<span class="kt-bad">失败</span>')
        const models = (x.models || []).length
        const detail = x.ok
          ? formatModelCatalog(x.models || [])
          : String(x.error || '')
        const ab = x.abilities || {}
        const cap = x.ok
          ? `<span class="cap ${ab.text ? 'on' : 'off'}">写</span>` +
            `<span class="cap ${ab.image ? 'on' : 'off'}">画</span>` +
            `<span class="cap ${ab.video ? 'on' : 'off'}">视频</span>` +
            `<span class="cap ${ab.audio ? 'on' : 'off'}">语音</span>`
          : '—'
        const bal = x.ok ? (x.balanceText || '<span class="kt-skip">去控制台看</span>') : '—'
        return `<tr><td>${x.name || x.vendor}</td><td>${badge}</td><td class="kt-cap">${cap}</td><td class="kt-bal">${bal}</td><td class="kt-detail">${detail}</td><td class="kt-ms">${x.ms || 0}ms</td></tr>`
      }).join('')
      // 顺手查余额：DeepSeek 有官方接口，其它如实说「去控制台看」
      await Promise.all(list.map(async (x) => {
        if (!x.ok) return
        try {
          const br = await fetch(`/agnes-studio/api/keys/balance?vendor=${encodeURIComponent(x.vendor)}`, {
            headers: { 'x-vendor-keys': JSON.stringify(keys) },
          })
          const bd = await br.json()
          if (bd.supported && bd.ok && (bd.balances || []).length) {
            const b = bd.balances[0]
            x.balanceText = `<b>${b.total}</b> ${b.currency}` +
              (Number(b.granted) > 0 ? `（含赠送 ${b.granted}）` : '')
          } else if (bd.supported && !bd.ok) {
            x.balanceText = '查询失败'
          }
        } catch { /* 忽略 */ }
      }))

      const good = list.filter((x) => x.ok).length
      const total = list.filter((x) => !x.skipped).length
      // 「一个 Key 全包」——按能力覆盖排，谁 4/4 就告诉他这一家够用
      const full = list.filter((x) => x.ok && (x.coverage || 0) >= 4)
      const three = list.filter((x) => x.ok && (x.coverage || 0) === 3)
      const verdict = full.length
        ? `✅ <b>${full.map((x) => x.name).join('、')}</b> 覆盖全部 4 项（写 / 画 / 视频 / 语音）——只填这一家就够了，其它都不用管。`
        : (three.length
          ? `⚠️ <b>${three.map((x) => x.name).join('、')}</b> 覆盖 3 项，<b>缺语音</b>。想「一个 Key 全包」的话，可以换 <b>MiniMax</b> 或 <b>通义千问</b>（它们文本/图像/视频/语音都有）。`
          : '')
      box.innerHTML = `<div class="key-test">
        <p class="note">${good} / ${total} 家可用${good ? '，现在可以直接去生成东西了。下面 ★ 是每一类的推荐项，拿不准就用它' : '—— 检查 Key 是否填错、或者账户额度是否用完'}</p>
        ${verdict ? `<p class="note cap-verdict">${verdict}</p>` : ''}
        <table class="kt-table"><thead><tr><th>厂商</th><th>状态</th><th>能力</th><th>额度</th><th>模型</th><th>耗时</th></tr></thead><tbody>${rows}</tbody></table>
      </div>`
    } catch (e) {
      box.innerHTML = `<div class="key-test"><p class="hint error">测试失败：${e instanceof Error ? e.message : String(e)}</p></div>`
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
    }
  })

  // 密钥表单
  renderKeyFields()
  $('saveKeys').addEventListener('click', () => {
    const next = {}
    for (const input of document.querySelectorAll('#keyFields input[data-vendor]')) {
      const val = input.value.trim()
      if (val) next[input.dataset.vendor] = val
    }
    keys = next
    persistKeys()
    updateKeyDot()
    const hint = $('keyHint')
    if (hint) { hint.className = 'hint ok'; hint.textContent = '✓ 已保存到本机浏览器' }
  })
  $('clearKeys').addEventListener('click', () => {
    keys = {}
    persistKeys()
    renderKeyFields()
    updateKeyDot()
    const hint = $('keyHint')
    if (hint) { hint.className = 'hint'; hint.textContent = '已清空' }
  })

  const tag = $('buildTag')
  if (tag) tag.textContent = BUILD_ID

  initWechat()

  // 一把密钥都没有时，直接停在设置页
  if (!hasAnyKey()) setTimeout(() => showPanel('settings'), 300)
}

// ═══════════════════════════════════════════════════════════════════════
// 公众号草稿推送（只发草稿箱，不群发）
// ═══════════════════════════════════════════════════════════════════════

function initWechat() {
  let coverData = null

  // 封面预览 + 转 base64
  $('wxCover')?.addEventListener('change', (e) => {
    const file = e.target.files?.[0]
    if (!file) return
    const reader = new FileReader()
    reader.onload = () => {
      coverData = reader.result
      const img = $('wxCoverPreview')
      if (img) { img.src = coverData; img.hidden = false }
    }
    reader.readAsDataURL(file)
  })

  // 检测凭据
  $('wxTestBtn')?.addEventListener('click', async () => {
    const hint = $('wxHint')
    hint.className = 'hint'
    hint.textContent = '正在检测凭据…'
    try {
      const resp = await fetch('/agnes-studio/api/wechat/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ appid: $('wxAppid').value.trim(), secret: $('wxSecret').value.trim() }),
      })
      const d = await resp.json()
      if (resp.ok) { hint.className = 'hint ok'; hint.textContent = '✓ 凭据有效，可以推送' }
      else { hint.className = 'hint error'; hint.textContent = d.error || '检测失败' }
    } catch (error) {
      hint.className = 'hint error'
      hint.textContent = error instanceof Error ? error.message : String(error)
    }
  })

  // 推送到草稿箱
  $('wxPushBtn')?.addEventListener('click', async () => {
    const hint = $('wxHint')
    const btn = $('wxPushBtn')
    const payload = {
      appid: $('wxAppid').value.trim(),
      secret: $('wxSecret').value.trim(),
      title: $('wxTitle').value.trim(),
      author: $('wxAuthor').value.trim(),
      digest: $('wxDigest').value.trim(),
      content: $('wxContent').value,
      cover: coverData,
    }

    hint.className = 'hint'
    if (!payload.appid || !payload.secret) { hint.className = 'hint error'; hint.textContent = '请先填写 AppID 和 AppSecret'; return }
    if (!payload.title || !payload.content.trim()) { hint.className = 'hint error'; hint.textContent = '标题和正文不能为空'; return }
    if (!payload.cover) { hint.className = 'hint error'; hint.textContent = '请先选择一张封面图'; return }

    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    btn.textContent = '推送中…'
    hint.textContent = '正在上传封面并新建草稿…'

    try {
      const resp = await fetch('/agnes-studio/api/wechat/draft', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      const d = await resp.json()
      if (resp.ok) {
        hint.className = 'hint ok'
        hint.textContent = `✓ 草稿已创建（media_id=${d.media_id}），到公众号后台「草稿箱」查看`
      } else {
        hint.className = 'hint error'
        hint.textContent = d.error || '推送失败'
      }
    } catch (error) {
      hint.className = 'hint error'
      hint.textContent = error instanceof Error ? error.message : String(error)
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      btn.textContent = '推送到草稿箱'
    }
  })
}

// ═══════════════════════════════════════════════════════════════════════
// 封面提示词（书籍信息 → 可投喂生图模型的提示词）
// ═══════════════════════════════════════════════════════════════════════

async function initCover() {
  const hint = $('cvHint')
  const btn = $('cvBtn')
  const results = $('cvResults')
  if (!btn) return

  // 风格列表来自后端，避免前后端风格名对不上
  try {
    const r = await fetch('/agnes-studio/api/cover/styles')
    const d = await r.json()
    const map = Object.fromEntries((d.styles || []).map((s) => [s.key, s.name]))
    if (Object.keys(map).length) fillSelect($('cvStyle'), map)
  } catch { /* 拿不到就不填，其余字段仍可手动输入 */ }

  btn.addEventListener('click', async () => {
    const title = $('cvTitle').value.trim()
    hint.className = 'hint'
    if (!title) {
      hint.className = 'hint error'
      hint.textContent = '先填书名'
      return
    }

    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    btn.textContent = '生成中…'

    try {
      const r = await fetch('/agnes-studio/api/cover/build', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          title,
          author: $('cvAuthor').value.trim(),
          summary: $('cvSummary').value.trim(),
          style: $('cvStyle').value,
          extra: $('cvExtra').value.trim(),
        }),
      })
      const d = await r.json()
      if (!r.ok || d.error) throw new Error(d.error || `请求失败（HTTP ${r.status}）`)
      const styleName = $('cvStyle').selectedOptions[0]?.textContent || ''
      renderPromptCard(results, d.prompt, `${title} · ${styleName}`)
      hint.className = 'hint ok'
      hint.textContent = '已生成，点「复制」拿去生图'
    } catch (error) {
      hint.className = 'hint error'
      hint.textContent = error instanceof Error ? error.message : String(error)
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      btn.textContent = '生成封面提示词'
    }
  })
}

// ═══════════════════════════════════════════════════════════════════════
// 提示词专家（一句话想法 → 专业提示词）
// ═══════════════════════════════════════════════════════════════════════

async function initExpert() {
  const typeBox = $('pxTypes')
  const fieldsBox = $('pxFields')
  const idea = $('pxIdea')
  const hint = $('pxHint')
  const btn = $('pxBtn')
  const results = $('pxResults')
  if (!btn) return

  let types = []
  try {
    const r = await fetch('/agnes-studio/api/prompt-expert/types')
    const d = await r.json()
    types = d.types || []
  } catch { types = [] }

  if (!types.length) {
    hint.className = 'hint error'
    hint.textContent = '专家类型加载失败'
    return
  }

  let current = types[0]

  // 每个专家类型自带一组参数（select），切换类型时重建
  function renderFields() {
    fieldsBox.replaceChildren()
    if (current.placeholder) idea.placeholder = current.placeholder
    for (const f of current.fields || []) {
      const label = document.createElement('label')
      label.className = 'field'
      const span = document.createElement('span')
      span.textContent = f.label
      const sel = document.createElement('select')
      sel.dataset.fieldKey = f.key
      for (const opt of f.options || []) {
        const o = document.createElement('option')
        o.value = opt
        o.textContent = opt
        sel.appendChild(o)
      }
      sel.value = f.default || (f.options || [])[0] || ''
      label.append(span, sel)
      fieldsBox.appendChild(label)
    }
  }

  function selectType(key) {
    current = types.find((t) => t.key === key) || types[0]
    for (const chip of typeBox.querySelectorAll('.chip')) {
      chip.classList.toggle('active', chip.dataset.key === current.key)
    }
    renderFields()
  }

  for (const t of types) {
    const chip = document.createElement('button')
    chip.type = 'button'
    chip.className = 'chip'
    chip.dataset.key = t.key
    chip.textContent = `${t.icon || ''} ${t.name}`.trim()
    chip.title = t.desc || ''
    chip.addEventListener('click', () => selectType(t.key))
    typeBox.appendChild(chip)
  }
  selectType(types[0].key)

  btn.addEventListener('click', async () => {
    const text = idea.value.trim()
    hint.className = 'hint'
    if (!text) {
      hint.className = 'hint error'
      hint.textContent = '先写一句你的想法'
      return
    }

    const params = {}
    for (const sel of fieldsBox.querySelectorAll('select[data-field-key]')) {
      params[sel.dataset.fieldKey] = sel.value
    }

    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    btn.textContent = '生成中…'
    hint.textContent = '正在扩写…'

    try {
      const r = await fetch('/agnes-studio/api/prompt-expert/generate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ type: current.key, idea: text, params, model: 'agnes-3.0-flash' }),
      })
      const d = await r.json()
      if (!r.ok || d.error) throw new Error(d.error || `请求失败（HTTP ${r.status}）`)
      renderPromptCard(results, d.prompt, `${current.name} · ${d.model || ''}`)
      hint.className = 'hint ok'
      hint.textContent = '生成完成'
    } catch (error) {
      hint.className = 'hint error'
      hint.textContent = error instanceof Error ? error.message : String(error)
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      btn.textContent = '生成提示词'
    }
  })
}

/** 渲染一张「提示词卡片」：等宽正文 + 复制按钮。 */
function renderPromptCard(container, text, caption) {
  container.replaceChildren()

  const card = document.createElement('div')
  card.className = 'result'

  const pre = document.createElement('pre')
  pre.className = 'prompt-out'
  pre.textContent = text

  const meta = document.createElement('div')
  meta.className = 'meta'
  const p = document.createElement('p')
  p.textContent = caption
  const copy = document.createElement('a')
  copy.href = '#'
  copy.textContent = '复制'
  copy.addEventListener('click', (e) => {
    e.preventDefault()
    navigator.clipboard?.writeText(text)
    copy.textContent = '已复制'
    setTimeout(() => { copy.textContent = '复制' }, 1500)
  })

  meta.append(p, copy)
  card.append(pre, meta)
  container.appendChild(card)
}

// ═══════════════════════════════════════════════════════════════════════
// 口播（文稿 → 分段 → 配音 → 成片）
// ═══════════════════════════════════════════════════════════════════════

async function initAnchor() {
  const btn = $('anBtn')
  const hint = $('anHint')
  const results = $('anResults')
  const wrap = $('anProgress')
  const bar = $('anBar')
  const ptext = $('anPtext')
  if (!btn) return

  btn.addEventListener('click', async () => {
    const text = $('anText').value.trim()
    hint.className = 'hint'
    if (!text) {
      hint.className = 'hint error'
      hint.textContent = '先填口播文稿'
      return
    }

    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    btn.textContent = '生成中…'
    wrap.hidden = false
    bar.style.width = '0%'
    ptext.textContent = '正在提交…'
    results.replaceChildren()

    try {
      const r = await fetch('/agnes-studio/api/anchor/start', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text,
          mode: $('anMode').value,
          voice: $('anVoice').value,
          min_seg_sec: Number($('anMinSeg').value) || 4,
          subtitles: $('anSubs').checked,
        }),
      })
      const d = await r.json()
      if (!r.ok || d.error) throw new Error(d.error || `请求失败（HTTP ${r.status}）`)
      const id = d.anchor_id
      ptext.textContent = '任务已提交，正在处理…'

      // 轮询到结束（最多 20 分钟）
      const deadline = Date.now() + 20 * 60 * 1000
      let last = null
      while (Date.now() < deadline) {
        await sleep(4000)
        const sr = await fetch(`/agnes-studio/api/anchor/${id}/status`)
        const s = await sr.json()
        const done = Number(s.done) || 0
        const total = Number(s.segments) || 0
        const pct = total ? Math.round((done / total) * 100) : (s.status === 'completed' ? 100 : 8)
        bar.style.width = `${pct}%`
        ptext.textContent = `${s.message || s.status}（${done}/${total} 段）`
        last = s
        if (s.status === 'completed' || s.status === 'failed' || s.status === 'stopped') break
      }

      if (last && last.status === 'completed' && last.final) {
        const card = document.createElement('div')
        card.className = 'result'
        const v = document.createElement('video')
        v.src = last.final
        v.controls = true
        v.playsInline = true
        v.preload = 'metadata'
        const meta = document.createElement('div')
        meta.className = 'meta'
        const p = document.createElement('p')
        p.textContent = `时长约 ${Math.round(Number(last.total_duration) || 0)} 秒`
        const a = document.createElement('a')
        a.href = last.final
        a.target = '_blank'
        a.rel = 'noopener'
        a.textContent = '打开成片'
        meta.append(p, a)
        card.append(v, meta)
        results.appendChild(card)
        hint.className = 'hint ok'
        hint.textContent = '口播生成完成'
      } else {
        hint.className = 'hint error'
        hint.textContent = (last && (last.error || last.message)) || '任务未完成（可能超时）'
      }
    } catch (error) {
      hint.className = 'hint error'
      hint.textContent = error instanceof Error ? error.message : String(error)
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      btn.textContent = '开始生成口播'
      setTimeout(() => { wrap.hidden = true }, 3000)
    }
  })
}

// ═══════════════════════════════════════════════════════════════════════
// 短剧（故事 → 剧本 → 分镜 → 素材确认 → 视频 → 合成）
// ═══════════════════════════════════════════════════════════════════════

async function initDrama() {
  const btn = $('drBtn')
  const hint = $('drHint')
  const results = $('drResults')
  const wrap = $('drProgress')
  const bar = $('drBar')
  const ptext = $('drPtext')
  const actions = $('drActions')
  if (!btn) return

  fillSelect($('drImageModel'), IMAGE_MODELS, 'agnes-image-2.5-flash')
  fillSelect($('drVideoModel'), VIDEO_MODELS, 'agnes-video-2.5-flash')
  // 换成本家真实可用的模型，并按类型分开（短剧要同时用文本/图像/视频三种）
  void refreshModelSelect($('drTextModel'), 'agnes', 'agnes-3.0-flash', 'text')
  void refreshModelSelect($('drImageModel'), 'agnes', 'agnes-image-2.5-flash', 'image')
  void refreshModelSelect($('drVideoModel'), 'agnes', 'agnes-video-2.5-flash', 'video')

  let currentId = null

  function showFinal() {
    results.replaceChildren()
    const url = `/agnes-studio/api/media/drama/${currentId}/final.mp4`
    const card = document.createElement('div')
    card.className = 'result'
    const v = document.createElement('video')
    v.src = url
    v.controls = true
    v.playsInline = true
    v.preload = 'metadata'
    const meta = document.createElement('div')
    meta.className = 'meta'
    const p = document.createElement('p')
    p.textContent = '成片'
    const a = document.createElement('a')
    a.href = url
    a.target = '_blank'
    a.rel = 'noopener'
    a.textContent = '打开成片'
    meta.append(p, a)
    card.append(v, meta)
    results.appendChild(card)
  }

  // 流水线很长（几十分钟），所以轮询放在后台，按钮不锁死
  async function poll() {
    const deadline = Date.now() + 60 * 60 * 1000
    while (Date.now() < deadline && currentId) {
      await sleep(5000)
      let s
      try {
        const r = await fetch(`/agnes-studio/api/drama/${currentId}/status`)
        s = await r.json()
      } catch { continue }

      const shots = Number(s.shots) || 0
      const completed = Number(s.completed) || 0
      const pct = shots ? Math.round((completed / shots) * 100) : (s.status === 'completed' ? 100 : 10)
      bar.style.width = `${pct}%`
      ptext.textContent = `${s.message || s.status}${shots ? `（视频 ${completed}/${shots}）` : ''}`

      // 流水线会在这里停下等确认
      if (s.status === 'paused_assets') {
        actions.hidden = false
        ptext.textContent = '素材已就绪 —— 确认后继续生成视频'
        return
      }
      if (s.status === 'failed' || s.status === 'stopped') {
        hint.className = 'hint error'
        hint.textContent = s.message || '任务中断'
        return
      }
      if (s.status === 'completed' || s.final === true) {
        showFinal()
        hint.className = 'hint ok'
        hint.textContent = '短剧制作完成'
        return
      }
    }
  }

  $('drConfirmAssets').addEventListener('click', async () => {
    if (!currentId) return
    actions.hidden = true
    try {
      await fetch(`/agnes-studio/api/drama/${currentId}/confirm`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ field: 'assets', action: 'approve' }),
      })
      ptext.textContent = '已确认，开始生成视频…'
      void poll()
    } catch (error) {
      hint.className = 'hint error'
      hint.textContent = error instanceof Error ? error.message : String(error)
    }
  })

  btn.addEventListener('click', async () => {
    const prompt = $('drPrompt').value.trim()
    hint.className = 'hint'
    if (!prompt) {
      hint.className = 'hint error'
      hint.textContent = '先写一句故事想法'
      return
    }

    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    btn.textContent = '启动中…'
    wrap.hidden = false
    actions.hidden = true
    bar.style.width = '0%'
    ptext.textContent = '正在启动流水线…'
    results.replaceChildren()

    try {
      const r = await fetch('/agnes-studio/api/drama/start', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          prompt,
          text_model: $('drTextModel').value,
          image_model: $('drImageModel').value,
          video_model: $('drVideoModel').value,
          shot_duration: Number($('drShotDur').value) || 5,
        }),
      })
      const d = await r.json()
      if (!r.ok || d.error) throw new Error(d.error || `请求失败（HTTP ${r.status}）`)
      currentId = d.drama_id
      ptext.textContent = '任务已启动，正在生成故事…'
      hint.textContent = '流水线在后台跑，你可以切到别的面板，回来还在。'
      void poll()
    } catch (error) {
      hint.className = 'hint error'
      hint.textContent = error instanceof Error ? error.message : String(error)
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      btn.textContent = '开始制作短剧'
    }
  })
}

// ═══════════════════════════════════════════════════════════════════════
// 剪视频（长视频截一段 / 平均切几段）
// ═══════════════════════════════════════════════════════════════════════

async function initSlice() {
  const btn = $('slBtn')
  if (!btn) return

  const hint = $('slHint')
  const info = $('slInfo')
  const progress = $('slProgress')
  const bar = $('slBar')
  const ptext = $('slPtext')
  const resultCard = $('slResultCard')
  const parts = $('slParts')
  const player = $('slPlayer')
  const resultHint = $('slResultHint')
  const listBox = $('slList')

  const say = (t, k) => {
    hint.className = 'hint' + (k ? ' ' + k : '')
    hint.textContent = t
  }

  async function api(path, method = 'GET', body) {
    const r = await fetch(path, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
    let d = {}
    try { d = await r.json() } catch { /* 空响应 */ }
    if (!r.ok || d.error) throw new Error(String(d.error || `请求失败（HTTP ${r.status}）`))
    return d
  }

  function fmt(sec) {
    const v = Math.max(0, Number(sec) || 0)
    const m = Math.floor(v / 60)
    const s = Math.round(v % 60)
    return `${m}:${String(s).padStart(2, '0')}`
  }

  // 剪法切换：截一段 / 平均切
  $('slMode')?.addEventListener('change', (ev) => {
    const mode = ev.target.value
    $('slCountWrap').hidden = mode !== 'split'
    $('slRangeWrap').hidden = mode !== 'cut'
  })

  // 先读时长
  $('slProbe')?.addEventListener('click', async () => {
    const src = $('slSrc').value.trim()
    if (!src) { info.className = 'hint error'; info.textContent = '先填视频链接或路径'; return }
    info.className = 'hint'
    info.textContent = '正在读取…'
    try {
      const d = await api('/agnes-studio/api/slice/probe', 'POST', { video_file: src })
      const dur = Number(d.duration || 0)
      info.className = 'hint ok'
      info.textContent = `时长 ${fmt(dur)}（${dur.toFixed(1)} 秒）· ${d.width}×${d.height}` +
        (d.hasAudio ? ' · 有声音' : ' · 无声音')
      // 顺手把结束时间填上，省得小白不知道填啥
      const endEl = $('slEnd')
      if (endEl && !endEl.value) endEl.placeholder = `留空表示到结尾（${fmt(dur)}）`
    } catch (e) {
      info.className = 'hint error'
      info.textContent = e instanceof Error ? e.message : String(e)
    }
  })

  async function refreshList() {
    try {
      const d = await api('/agnes-studio/api/slice/list')
      const items = d.items || []
      listBox.replaceChildren()
      if (!items.length) { listBox.textContent = '还没有剪过片段'; return }
      for (const it of items) {
        const a = document.createElement('a')
        a.className = 'file-item'
        a.href = `/agnes-studio/api/slice/file/${it.rel.split('/').map(encodeURIComponent).join('/')}`
        a.setAttribute('download', it.name)
        a.textContent = `${it.name}${it.size ? ' · ' + (it.size / 1048576).toFixed(1) + ' MB' : ''}`
        listBox.appendChild(a)
      }
    } catch { /* 列表拿不到就算了 */ }
  }

  btn.addEventListener('click', async () => {
    const src = $('slSrc').value.trim()
    if (!src) { say('先填视频链接或路径', 'error'); return }
    const mode = $('slMode').value
    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    resultCard.hidden = true
    progress.hidden = false
    bar.style.width = '5%'
    ptext.textContent = '已提交…'
    say('正在剪切…')

    try {
      const payload = {
        video_file: src,
        precise: $('slPrecise').checked,
      }
      const started = mode === 'cut'
        ? await api('/agnes-studio/api/slice/cut', 'POST', {
            ...payload,
            start: Number($('slStart').value) || 0,
            end: Number($('slEnd').value) || 0,
          })
        : await api('/agnes-studio/api/slice/split', 'POST', {
            ...payload,
            count: Number($('slCount').value) || 4,
          })

      const deadline = Date.now() + 60 * 60 * 1000
      let task = null
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 2000))
        const st = await api(`/agnes-studio/api/slice/status?id=${encodeURIComponent(started.id)}`)
        task = st.task
        if (task) {
          ptext.textContent = task.message || '处理中…'
          bar.style.width = (task.status === 'done' ? 100 : 45) + '%'
        }
        if (task && ['done', 'failed'].includes(task.status)) break
      }
      if (!task) throw new Error('任务超时')
      if (task.status === 'failed') throw new Error(task.error || '剪切失败')

      parts.replaceChildren()
      for (const seg of task.segments || []) {
        const chip = document.createElement('button')
        chip.type = 'button'
        chip.className = 'chip'
        chip.textContent = `第${seg.index}段 ${fmt(seg.start)}→${fmt(seg.end)}` +
          (seg.size ? `（${(seg.size / 1048576).toFixed(1)}MB）` : '')
        chip.addEventListener('click', () => {
          player.src = `/agnes-studio/api/slice/file/${started.id}/${encodeURIComponent(seg.name)}`
        })
        parts.appendChild(chip)
      }
      if (task.segments && task.segments[0]) {
        player.src = `/agnes-studio/api/slice/file/${started.id}/${encodeURIComponent(task.segments[0].name)}`
      }
      resultHint.className = 'hint'
      resultHint.textContent = task.message || ''
      resultCard.hidden = false
      say('剪好了，点上面的时间段可以切换片段', 'ok')
      await refreshList()
    } catch (e) {
      say(e instanceof Error ? e.message : String(e), 'error')
      ptext.textContent = '出错'
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      setTimeout(() => { progress.hidden = true }, 1500)
    }
  })

  $('slRefresh')?.addEventListener('click', () => { void refreshList() })
  await refreshList()
}

// ═══════════════════════════════════════════════════════════════════════
// 资料库：所有模块生成的东西汇总在这里预览
//
// 各模块本来各存各的目录，用户想找刚生成的东西得挨个翻。
// 这里统一列出来：图片看大图、视频直接播、音频直接听、文本可打开。
// ═══════════════════════════════════════════════════════════════════════

const LIB_ICON = { image: '🖼', video: '🎬', audio: '🎵', text: '📄', other: '📦' }

function humanBytes(n) {
  const v = Number(n) || 0
  if (v < 1024) return v + ' B'
  if (v < 1048576) return (v / 1024).toFixed(0) + ' KB'
  if (v < 1073741824) return (v / 1048576).toFixed(1) + ' MB'
  return (v / 1073741824).toFixed(2) + ' GB'
}

function libFileUrl(rel) {
  return `/agnes-studio/api/library/file?path=${encodeURIComponent(rel)}`
}
function libThumbUrl(rel, w) {
  return `/agnes-studio/api/library/thumb?path=${encodeURIComponent(rel)}&w=${w || 240}`
}

async function initLibrary() {
  const grid = $('libGrid')
  if (!grid) return

  const hint = $('libHint')
  const empty = $('libEmpty')
  const viewCard = $('libViewCard')
  const viewName = $('libViewName')
  const viewBody = $('libViewBody')
  const openRaw = $('libOpenRaw')
  let current = null

  async function api(path, method = 'GET', body) {
    const r = await fetch(path, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
    let d = {}
    try { d = await r.json() } catch { /* 空响应 */ }
    if (!r.ok || d.error) throw new Error(String(d.error || `HTTP ${r.status}`))
    return d
  }

  function showItem(it) {
    current = it
    viewName.textContent = `${it.name} · ${it.source}`
    viewBody.replaceChildren()
    if (it.kind === 'image') {
      const img = document.createElement('img')
      img.src = libFileUrl(it.rel)
      img.style.cssText = 'max-width:100%;border-radius:10px;border:1px solid var(--line)'
      viewBody.appendChild(img)
    } else if (it.kind === 'video') {
      const v = document.createElement('video')
      v.src = libFileUrl(it.rel)
      v.controls = true
      v.playsInline = true
      v.style.cssText = 'width:100%;border-radius:10px;background:#000'
      viewBody.appendChild(v)
    } else if (it.kind === 'audio') {
      const a = document.createElement('audio')
      a.src = libFileUrl(it.rel)
      a.controls = true
      a.style.width = '100%'
      viewBody.appendChild(a)
    } else {
      const p = document.createElement('p')
      p.className = 'hint'
      p.textContent = '这类文件不能直接预览，点下面「新窗口打开」看内容。'
      viewBody.appendChild(p)
    }
    openRaw.href = libFileUrl(it.rel)
    viewCard.hidden = false
    viewCard.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  }

  function itemEl(it) {
    const btn = document.createElement('button')
    btn.type = 'button'
    btn.className = 'asset-item'
    if (it.kind === 'image' || it.kind === 'video') {
      const img = document.createElement('img')
      img.className = 'asset-thumb'
      img.loading = 'lazy'
      img.alt = it.name
      img.src = libThumbUrl(it.rel, 240)
      if (it.kind === 'video') {
        const badge = document.createElement('span')
        badge.className = 'lib-badge'
        badge.textContent = '▶'
        img.after(badge)
      }
      btn.appendChild(img)
    } else {
      const ph = document.createElement('div')
      ph.className = 'asset-ph'
      ph.textContent = LIB_ICON[it.kind] || '📦'
      btn.appendChild(ph)
    }
    const name = document.createElement('div')
    name.className = 'asset-name'
    name.textContent = it.name
    const meta = document.createElement('div')
    meta.className = 'asset-meta'
    // 同名片段（part_01.mp4 会出现很多次）要带上来源目录才好区分
    const folder = it.rel.split('/').slice(-2)[0] || ''
    meta.textContent = `${it.source}${folder && folder !== it.source ? ' / ' + folder : ''} · ${humanBytes(it.size)}`
    btn.append(name, meta)
    btn.addEventListener('click', () => showItem(it))
    return btn
  }

  async function refresh() {
    try {
      const q = new URLSearchParams({
        kind: $('libKind').value,
        q: $('libSearch').value.trim(),
        limit: '300',
      })
      const d = await api('/agnes-studio/api/library/list?' + q.toString())
      const items = d.items || []
      grid.replaceChildren()
      for (const it of items) grid.appendChild(itemEl(it))
      empty.hidden = items.length > 0
      const c = d.counts || {}
      hint.className = 'hint'
      hint.textContent = items.length
        ? `共 ${items.length} 个 · 图片 ${c.image || 0} · 视频 ${c.video || 0} · 音频 ${c.audio || 0} · 文本 ${c.text || 0}`
        : '还没有生成过东西'
    } catch (e) {
      hint.className = 'hint error'
      hint.textContent = e instanceof Error ? e.message : String(e)
    }
  }

  $('libRefresh')?.addEventListener('click', () => { void refresh() })
  $('libKind')?.addEventListener('change', () => { void refresh() })
  $('libSearch')?.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') void refresh() })
  $('libCloseView')?.addEventListener('click', () => { viewCard.hidden = true })
  $('libDelete')?.addEventListener('click', async () => {
    if (!current) return
    if (!confirm(`确定删掉「${current.name}」？删了不能恢复。`)) return
    try {
      await api('/agnes-studio/api/library/delete', 'POST', { path: current.rel })
      viewCard.hidden = true
      await refresh()
    } catch (e) {
      hint.className = 'hint error'
      hint.textContent = '删除失败：' + (e instanceof Error ? e.message : String(e))
    }
  })

  await refresh()
}

/**
 * 首次访问引导：让用户在**自己电脑上**建/选一个文件夹。
 *
 * 为什么要这一步：本站的生成结果默认存在服务器；而「创作台」要直接读写
 * 你电脑上的稿子（服务器全程不碰）。第一次来的人不会自己去翻设置，
 * 所以在首页就给一个显眼的入口。
 * 记住已提示过（localStorage），之后不再打扰。
 */
async function initOnboard() {
  const KEY = 'psw_onboarded_v1'
  try {
    if (localStorage.getItem(KEY) === '1') return
  } catch { return }

  const hero = document.querySelector('.home-hero')
  if (!hero || !hero.parentElement) return

  const box = document.createElement('div')
  box.className = 'card onboard'
  box.innerHTML = `
    <div class="card-head"><span class="card-title">第一次来？先在自己电脑上建个文件夹</span></div>
    <p class="note">
      生成的小说、图片、视频默认存在这台服务器上。如果你想让稿子直接存在<b>自己电脑</b>里，
      选一个文件夹就行 —— 读写都在你的浏览器里完成，<b>服务器不碰这些文件</b>。
    </p>
    <div class="row-actions">
      <button class="btn primary" id="obPick" type="button">选择我电脑上的文件夹</button>
      <button class="btn ghost" id="obSkip" type="button">以后再说</button>
    </div>
    <p class="hint" id="obHint">需要 Chrome / Edge。选过一次以后会自动记住。</p>`

  hero.after(box)

  const hint = box.querySelector('#obHint')
  box.querySelector('#obSkip')?.addEventListener('click', () => {
    try { localStorage.setItem(KEY, '1') } catch { /* 隐私模式 */ }
    box.remove()
  })
  box.querySelector('#obPick')?.addEventListener('click', async (ev) => {
    const btn = ev.currentTarget
    btn.disabled = true
    hint.className = 'hint'
    hint.textContent = '正在打开选择框…'
    try {
      const FS = window.LocalFS
      if (!FS) throw new Error('浏览器还没加载完本机文件能力，稍后再试')
      const name = await FS.pick()
      try { localStorage.setItem(KEY, '1') } catch { /* 忽略 */ }
      hint.className = 'hint ok'
      hint.textContent = `已连接「${name}」。以后「创作台」和「资料库 → 本机目录」都用这个文件夹。`
      btn.textContent = '已连接 ✓'
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      // 用户自己取消不算错误
      if (/abort|cancel|取消/i.test(msg)) {
        hint.className = 'hint'
        hint.textContent = '没关系，需要时再点。'
      } else {
        hint.className = 'hint error'
        hint.textContent = '没能连接：' + msg
      }
      btn.disabled = false
    }
  })
}

/** 资料库顶部三个页签的切换。 */
function initLibTabs() {
  const tabs = $('libTabs')
  if (!tabs) return
  const panes = {
    gen: $('libGenPane'),
    asset: $('libAssetPane'),
    local: $('libLocalPane'),
  }
  tabs.addEventListener('click', (ev) => {
    const btn = ev.target.closest('.seg')
    if (!btn) return
    const key = btn.dataset.lib
    for (const b of tabs.querySelectorAll('.seg')) b.classList.toggle('on', b === btn)
    for (const [k, el] of Object.entries(panes)) if (el) el.hidden = k !== key
  })

  $('libPickDir')?.addEventListener('click', async (ev) => {
    const btn = ev.currentTarget
    const hint = $('libLocalHint')
    btn.disabled = true
    try {
      const FS = window.LocalFS
      if (!FS) throw new Error('浏览器还没加载完本机文件能力')
      const name = await FS.pick()
      hint.className = 'hint ok'
      hint.textContent = `已连接「${name}」。`
      $('libLocalNote').textContent = `当前连接的是「${name}」。`
    } catch (e) {
      hint.className = 'hint error'
      hint.textContent = '没能连接：' + (e instanceof Error ? e.message : String(e))
    } finally {
      btn.disabled = false
    }
  })
}

// ═══════════════════════════════════════════════════════════════════════
// 素材库：浏览本机下载的素材包
//
// ⚠️ 服务端默认只允许本机访问（素材来自付费素材包，公开分发属未授权）。
// 前端只负责浏览：列表 → 缩略图 → 看大图；原文件在新窗口打开。
// ═══════════════════════════════════════════════════════════════════════

const ASSET_ICON = {
  image: '🖼', archive: '🗜', design: '🎨', video: '🎬',
  audio: '🎵', font: '🔤', doc: '📄', other: '📦',
}

function humanSize(n) {
  const v = Number(n) || 0
  if (v < 1024) return v + ' B'
  if (v < 1048576) return (v / 1024).toFixed(0) + ' KB'
  if (v < 1073741824) return (v / 1048576).toFixed(1) + ' MB'
  return (v / 1073741824).toFixed(2) + ' GB'
}

async function initAssets() {
  const grid = $('asGrid')
  if (!grid) return

  const note = $('asNote')
  const pathEl = $('asPath')
  const hint = $('asHint')
  const moreBtn = $('asMore')
  const viewCard = $('asViewCard')
  const viewImg = $('asViewImg')
  const viewName = $('asViewName')
  const rawLink = $('asOpenRaw')

  let curDir = ''
  let offset = 0
  let total = 0
  const LIMIT = 60

  async function api(path) {
    const r = await fetch(path)
    let d = {}
    try { d = await r.json() } catch { /* 空响应 */ }
    if (!r.ok || d.error) {
      const err = new Error(String(d.error || ('请求失败 HTTP ' + r.status)))
      err.hint = d.hint
      err.isBlocked = r.status === 403
      throw err
    }
    return d
  }

  function thumbUrl(rel, w) {
    return `/agnes-studio/api/assets/thumb?path=${encodeURIComponent(rel)}&w=${w || 240}`
  }
  function fileUrl(rel) {
    return `/agnes-studio/api/assets/file?path=${encodeURIComponent(rel)}`
  }

  async function loadStats(force) {
    try {
      const d = await api('/agnes-studio/api/assets/stats' + (force ? '?force=1' : ''))
      // 站点不内置素材：使用者没配 ASSETS_DIR 时把「怎么配」说清楚，而不是显示一片空白
      if (d.configured === false) {
        note.className = 'note'
        note.textContent = '这个站点还没有配置素材库'
        note.style.borderColor = 'rgba(232, 160, 40, .45)'
        note.style.background = 'rgba(232, 160, 40, .10)'
        grid.replaceChildren()
        hint.className = 'hint'
        hint.textContent = '素材库交由使用者自己指定：在 .env 里写 ASSETS_DIR=你的素材目录（多个用 : 分隔）再重启服务。站点本身不附带任何素材。'
        pathEl.textContent = '当前目录：/'
        moreBtn.hidden = true
        return
      }
      const c = d.counts || {}
      const parts = ['image', 'archive', 'design', 'video', 'audio', 'font', 'doc', 'other']
        .filter(k => c[k]).map(k => `${ASSET_ICON[k] || ''} ${k} ${c[k]}`)
      note.className = 'note'
      const roots = (d.roots || []).filter(r => r.exists).map(r => r.name)
      note.textContent = `${roots.length > 1 ? roots.join(' + ') + '：' : ''}共 ${d.total?.files || 0} 个文件 · ${humanSize(d.total?.bytes || 0)}` +
        (parts.length ? ` —— ${parts.join(' · ')}` : '')
    } catch (e) {
      note.className = 'note'
      note.textContent = e.isBlocked
        ? '⛔ ' + e.message + (e.hint ? '（' + e.hint + '）' : '')
        : '读不到素材目录：' + e.message
      note.style.borderColor = 'rgba(232, 96, 96, .35)'
      note.style.background = 'rgba(232, 96, 96, .08)'
    }
  }

  function itemEl(entry) {
    const btn = document.createElement('button')
    btn.type = 'button'
    btn.className = 'asset-item'
    if (entry.type === 'dir') {
      const ph = document.createElement('div')
      ph.className = 'asset-ph'
      ph.textContent = '📁'
      const name = document.createElement('div')
      name.className = 'asset-name'
      name.textContent = entry.name
      const meta = document.createElement('div')
      meta.className = 'asset-meta'
      meta.textContent = '文件夹'
      btn.append(ph, name, meta)
      btn.addEventListener('click', () => openDir(entry.rel))
      return btn
    }
    const k = entry.kind || 'other'
    const downloading = /\.(downloading|part|crdownload|tmp)$/i.test(entry.name || '')
    if (k === 'image') {
      const img = document.createElement('img')
      img.className = 'asset-thumb'
      img.loading = 'lazy'
      img.alt = entry.name
      img.src = thumbUrl(entry.rel, 240)
      btn.appendChild(img)
    } else {
      const ph = document.createElement('div')
      ph.className = 'asset-ph'
      ph.textContent = ASSET_ICON[k] || '📦'
      btn.appendChild(ph)
    }
    const name = document.createElement('div')
    name.className = 'asset-name'
    name.textContent = entry.name
    const meta = document.createElement('div')
    meta.className = 'asset-meta'
    meta.textContent = downloading ? '⏳ 正在下载中' : `${k} · ${humanSize(entry.size)}`
    btn.append(name, meta)
    btn.addEventListener('click', () => {
      if (k === 'image') showBig(entry)
      else window.open(fileUrl(entry.rel), '_blank', 'noopener')
    })
    return btn
  }

  function showBig(entry) {
    viewName.textContent = entry.name
    viewImg.src = fileUrl(entry.rel)
    rawLink.href = fileUrl(entry.rel)
    viewCard.hidden = false
    viewCard.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    // 「复制地址」是素材真正能被用起来的入口：
    // APP界面设计站的图片部件只存 URL（上游约定：不内嵌数据），所以要能拿到这个地址。
    const copyBtn = $('asCopyUrl')
    if (copyBtn) {
      copyBtn.dataset.rel = entry.rel
      copyBtn.textContent = '复制图片地址'
    }
  }

  $('asCopyUrl')?.addEventListener('click', async (ev) => {
    const rel = ev.currentTarget.dataset.rel || ''
    if (!rel) return
    const url = new URL(fileUrl(rel), location.origin).href
    try {
      await navigator.clipboard.writeText(url)
      ev.currentTarget.textContent = '已复制 ✓'
      setTimeout(() => { ev.currentTarget.textContent = '复制图片地址' }, 1800)
    } catch {
      // 剪贴板被拒（非 https / 无权限）时退化为让用户自己复制
      window.prompt('浏览器不让自动复制，请手动复制这个地址：', url)
    }
  })

  function render(d, append) {
    if (!append) grid.replaceChildren()
    for (const dir of d.dirs || []) grid.appendChild(itemEl(dir))
    for (const f of d.files || []) grid.appendChild(itemEl(f))
    total = d.total || 0
    offset = (d.offset || 0) + (d.files || []).length
    moreBtn.hidden = !d.hasMore
    pathEl.textContent = '当前目录：/' + (curDir || '')
    hint.className = 'hint'
    hint.textContent = (d.dirs || []).length + (d.files || []).length === 0
      ? '这一层没有内容'
      : `文件夹 ${(d.dirs || []).length} 个 · 文件显示 ${(d.files || []).length}/${total} 个`
  }

  async function openDir(rel, append) {
    if (!append) {
      curDir = rel || ''
      offset = 0
      viewCard.hidden = true
    }
    try {
      const q = new URLSearchParams({
        dir: curDir, offset: String(offset), limit: String(LIMIT),
        q: $('asSearch').value.trim(), kind: $('asKind').value,
      })
      const d = await api('/agnes-studio/api/assets/list?' + q.toString())
      render(d, append)
    } catch (e) {
      hint.className = 'hint error'
      hint.textContent = e.message + (e.hint ? '（' + e.hint + '）' : '')
    }
  }

  $('asRefresh')?.addEventListener('click', () => openDir(curDir))
  $('asRescan')?.addEventListener('click', async (ev) => {
    const btn = ev.currentTarget
    btn.disabled = true
    btn.textContent = '统计中…'
    try {
      await loadStats(true)
      await openDir(curDir)
    } finally {
      btn.disabled = false
      btn.textContent = '重新统计'
    }
  })
  $('asUp')?.addEventListener('click', () => {
    const up = curDir.split('/').slice(0, -1).join('/')
    openDir(up)
  })
  moreBtn?.addEventListener('click', () => openDir(curDir, true))
  $('asSearch')?.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') openDir(curDir)
  })
  $('asKind')?.addEventListener('change', () => openDir(curDir))
  $('asCloseView')?.addEventListener('click', () => { viewCard.hidden = true })

  await loadStats()
  await openDir('')
}

// ═══════════════════════════════════════════════════════════════════════
// 首页：15 个功能入口，全部用大白话描述
// ═══════════════════════════════════════════════════════════════════════

const HOME_CARDS = [
  { icon: '🖋', name: '写作台', desc: '写小说、改稿、起书名、去 AI 味', goto: 'ohstory' },
  { icon: '📖', name: '小说工具', desc: '把整本小说拆成多集，保证不改原文', goto: 'novel-split' },
  { icon: '🖼', name: '画图', desc: '写一句画面描述就出图', goto: 'image' },
  { icon: '🏷', name: '做封面', desc: '生成一张封面的完整绘图提示词', goto: 'cover' },
  { icon: '🎬', name: '做视频', desc: '写一句镜头描述就出片', goto: 'video' },
  { icon: '🎙', name: '文稿转口播', desc: '粘一段文稿，自动配音加画面', goto: 'anchor' },
  { icon: '📺', name: '一句话短剧', desc: '自动走完剧本 → 分镜 → 画面 → 成片', goto: 'storyboard' },
  { icon: '✂️', name: '剪视频', desc: '长视频截一段，或平均切成几段', goto: 'slice' },
  { icon: '🎵', name: '歌词变 MV', desc: '粘歌词，自动配画面和配乐', goto: 'mv' },
  { icon: '🌄', name: '文稿变背景片', desc: '文稿分成几幕，逐幕画出来拼成片', goto: 'bgvideo' },
  { icon: '🔍', name: '看懂视频', desc: '丢一个视频链接，讲清里面有什么', goto: 'videoparse' },
  { icon: '🧰', name: '多能宝箱', desc: '下载视频、文字转语音', goto: 'toolbox' },
  { icon: '🎨', name: 'APP界面设计站', desc: '拖拽拼手机 App 界面，一键出 AI 提示词', goto: 'canvas' },
  { icon: '🧩', name: '提示词专家', desc: '粗糙想法扩写成专业提示词', goto: 'expert' },
  { icon: '📮', name: '公众号', desc: '写好文章推进微信草稿箱', goto: 'wechat' },
  { icon: '🗂', name: '资料库', desc: '你生成的东西都在这，也能看本机素材', goto: 'assets' },
  { icon: '🔑', name: '设置密钥', desc: '填你自己的 API Key（只在本地）', goto: 'settings' }
]

/**
 * 用户还没填 Key 时，在首页顶部给一条能直接点的引导。
 * 小白第一次打开最需要的就是这一句 —— 否则他点任何按钮都只看到一串技术报错。
 */
function initKeyGuide() {
  if (hasAnyKey()) return
  if (document.querySelector('.key-guide')) return
  const hero = document.querySelector('.home-hero')
  if (!hero || !hero.parentElement) return

  const bar = document.createElement('div')
  bar.className = 'key-guide'

  const text = document.createElement('div')
  text.className = 'key-guide-text'
  text.innerHTML =
    '<b>第一次用？</b>只填一个 Key 就够 —— 写作、画图、生视频、看懂视频全都能用：' +
    '<a href="https://platform.agnes-ai.cn" target="_blank" rel="noopener noreferrer">去 Agnes 免费注册 →</a>' +
    ' 复制那串 sk-…，粘到「设置」保存。服务器不保存你的 Key。'

  const btn = document.createElement('button')
  btn.type = 'button'
  btn.className = 'btn primary'
  btn.textContent = '去填 Key →'
  btn.addEventListener('click', () => showPanel('settings'))

  bar.append(text, btn)
  hero.parentElement.insertBefore(bar, hero.nextSibling)
}

function initHome() {
  const grid = $('homeGrid')
  if (!grid) return
  for (const c of HOME_CARDS) {
    const btn = document.createElement('button')
    btn.type = 'button'
    btn.className = 'home-card'
    const icon = document.createElement('span')
    icon.className = 'hc-icon'
    icon.textContent = c.icon
    const name = document.createElement('span')
    name.className = 'hc-name'
    name.textContent = c.name
    const desc = document.createElement('span')
    desc.className = 'hc-desc'
    desc.textContent = c.desc
    btn.append(icon, name, desc)
    btn.addEventListener('click', () => showPanel(c.goto))
    grid.appendChild(btn)
  }
}

// ═══════════════════════════════════════════════════════════════════════
// 面向小白的简化：把技术参数收进「高级设置」，并给每个面板加一句「怎么用」
// ═══════════════════════════════════════════════════════════════════════

/**
 * 把若干个控件所在的 .field 搬进一个默认折叠的 <details>。
 * @param ids - 控件 id 列表。
 * @param label - 折叠标题。
 */
function moveFieldsIntoAdvanced(ids, label) {
  const fields = []
  for (const id of ids) {
    const el = $(id)
    if (!el) continue
    const field = el.closest('.field') || el.parentElement
    if (field && fields.indexOf(field) < 0) fields.push(field)
  }
  if (!fields.length) return
  // 按文档顺序排列，搬进去以后顺序才和原来一致
  fields.sort((a, b) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1)
  const anchor = fields[0]
  const host = anchor.parentElement
  if (!host) return
  // 搬动过程中 DOM 结构可能变化：锚点必须仍是 host 的子节点，否则 insertBefore 会抛
  if (anchor.parentElement !== host) return
  const details = document.createElement('details')
  details.className = 'advanced'
  const summary = document.createElement('summary')
  summary.textContent = label || '高级设置（一般不用改）'
  details.appendChild(summary)
  // 顺序要紧：先把空的 details 插到锚点前，再往外搬字段。
  // 反过来写的话，搬第一个字段时就把锚点挪走了，insertBefore 会抛
  // 「The node before which the new node is to be inserted is not a child of this node」。
  host.insertBefore(details, anchor)
  for (const f of fields) details.appendChild(f)
}

/** 在某个面板顶部插一句人话说明。 */
function addHowto(panelKey, html) {
  const panel = document.querySelector(`.panel[data-panel="${panelKey}"]`)
  if (!panel || panel.querySelector('.howto')) return
  const box = document.createElement('div')
  box.className = 'howto'
  box.innerHTML = html
  panel.insertBefore(box, panel.firstChild)
}


/** 设置页顶部的「三步开始」卡：小白进来先看到这几句，再往下填。 */
function initSettingsGuide() {
  const panel = document.querySelector('.panel[data-panel="settings"]')
  if (!panel || panel.querySelector('.start-steps')) return
  const box = document.createElement('div')
  box.className = 'card start-steps'
  box.innerHTML = `
    <div class="card-head"><span class="card-title">只要一个 Key，三步就能用</span></div>
    <p class="note">
      一个 <b>Agnes</b> 的 Key 就够用<b>写作、画图、生视频、看懂视频</b>这一整套（已实测）。
      只有「文字转语音」需要再补一家，见下方「可选」。
    </p>
    <ol class="steps">
      <li><b>拿一个 Agnes Key。</b>打开
        <a href="https://platform.agnes-ai.cn" target="_blank" rel="noopener noreferrer">Agnes 平台</a>
        注册（免费，有额度），进「API Keys」新建一个，复制那串 sk-…。
      </li>
      <li><b>粘到下面第一行，点「保存」。</b>只有这一行是必须的，其它都在「可选」里。</li>
      <li><b>点「测试这些 Key」。</b>看到 agnes 那行 ✅ 和模型清单，就可以去创作了。</li>
    </ol>
    <p class="hint">Key 只保存在你这一台设备的浏览器里，服务器不保存、不写日志。换电脑要重新填。</p>`
  panel.insertBefore(box, panel.firstChild)
}

function initSimpleUI() {
  // 每个面板独立 try：简化是锦上添花，一个面板失败不该影响其它面板，
  // 更不该中断后面的初始化（曾经因此让首页 15 张卡片整批不出现）。
  const safe = (fn) => { try { fn() } catch (e) { /* 静默：纯展示层优化 */ } }

  // 生图：模型进高级
  safe(() => moveFieldsIntoAdvanced(['imgModel'], '高级设置 · 换模型'))
  safe(() => addHowto('image', '写一句你想要的画面 → 点 <b>生成图片</b>。不知道怎么写就点下面的风格小标签。'))

  // 生视频：模型进高级
  safe(() => moveFieldsIntoAdvanced(['vidModel'], '高级设置 · 换模型'))
  safe(() => addHowto('video', '写一句你想要的镜头 → 点 <b>生成视频</b>。通常要等 1–3 分钟。'))

  // 视频解析：厂商与模型进高级
  safe(() => moveFieldsIntoAdvanced(['vpVendor', 'vpModel'], '高级设置 · 换读图模型'))
  safe(() => addHowto('videoparse', '把视频链接粘进来 → 点 <b>开始解析</b>。它会自动抽几帧画面并逐帧讲清内容，最后还能生成视频提示词。'))

  // 小说工具：模型进高级
  safe(() => moveFieldsIntoAdvanced(['nsModel', 'deModel'], '高级设置 · 换模型'))
  safe(() => addHowto('novel-split', '把整本小说粘进来（或选个文件）→ 填<b>要拆成几集</b> → 点 <b>开始拆分</b>。它只切原文、不改写内容。'))

  // 多能宝箱：清晰度进高级
  safe(() => moveFieldsIntoAdvanced(['tbQuality'], '高级设置 · 清晰度'))
  safe(() => addHowto('toolbox', '上面填视频链接就能<b>下载视频</b>（B 站、YouTube 都行）；下面粘一段文字就能<b>合成语音</b>——音色选「本地离线配音」就不用填任何 Key（音质机械但免费），选其他音色需要 MiniMax 的 Key。'))

  // MTV：两个模型进高级
  safe(() => moveFieldsIntoAdvanced(['mvTextModel', 'mvImageModel'], '高级设置 · 换模型'))
  safe(() => addHowto('mv', '把歌词或一句主题粘进来 → 点 <b>开始生成 MTV</b>。想配乐就在上面填一首歌的链接或路径。'))

  // 背景视频：两个模型进高级
  safe(() => moveFieldsIntoAdvanced(['bgTextModel', 'bgImageModel'], '高级设置 · 换模型'))
  safe(() => addHowto('bgvideo', '把要配画面的文稿粘进来 → 点 <b>开始生成背景视频</b>。它会按文稿分成几幕，逐幕画出来再拼成片。'))

  // 短剧：三个模型进高级
  safe(() => moveFieldsIntoAdvanced(['drTextModel', 'drImageModel', 'drVideoModel'], '高级设置 · 换模型'))
  safe(() => addHowto('storyboard', '写一句故事想法 → 点 <b>开始制作短剧</b>。它会自动走完「故事 → 剧本 → 分镜 → 画面 → 视频」，中途停下来问你一次素材满不满意。'))

  // 创作台：模型进高级
  safe(() => moveFieldsIntoAdvanced(['aiModel'], '高级设置 · 换模型'))

  // 口播：音色以外的参数进高级
  safe(() => moveFieldsIntoAdvanced(['anMode'], '高级设置 · 生成方式'))
  safe(() => addHowto('anchor', '把文稿粘进来 → 点 <b>开始生成口播</b>。它会自动分段、配音、配上画面。<br>⚠️ 配音需要 <b>MiMo</b> 的 Key（Agnes 没有语音模型），去「设置」的可选区填 MiMo 即可。'))

  // 创作台：第一次要选文件夹，这句最要紧
  safe(() => addHowto('ohstory',
    '第一次用：点 <b>选择本机文件夹</b>，挑一个你电脑上的文件夹（比如「我的小说」）。' +
    '之后稿子都存在你自己的电脑里，服务器全程不碰。'))

  // 剪视频
  safe(() => addHowto('slice', '填视频链接 → 点 <b>先读一下时长</b> → 选「截取一段」填起止秒数，或选「平均切成几段」 → 点 <b>开始剪切</b>。默认不重新编码，几秒就完成。'))

  // 素材库
  safe(() => addHowto('assets',
    '「我的生成」汇总所有模块做出来的图片、视频、音频；「我的素材」读你本机目录里的素材；「本机目录」把网页连到你电脑上的文件夹。' +
    '要在「APP界面设计站」里用某张图，点开后按 <b>复制图片地址</b>，再到那边的图片部件里粘贴。'))

  // 设置：小白进入这里时，最需要知道「填哪个、去哪拿」
  safe(() => initSettingsGuide())
  safe(() => addHowto('settings',
    '这里是填 API Key 的地方。<b>最少填一个 agnes 的</b>（去 platform.agnes-ai.cn 免费注册就能拿到），' +
    '其它厂商想用哪个再填哪个。Key 只存在你这个浏览器里，服务器不保存。'))

  // 封面 / 提示词：给一句说明
  safe(() => addHowto('cover', '填书名和简介 → 它会帮你生成一张封面的完整绘图提示词，拿去「生图」就能出图。'))
  safe(() => addHowto('expert', '选一个专家类型，写下粗糙的想法 → 它会扩写成专业提示词。'))
  safe(() => addHowto('wechat', '填公众号的 AppID 和 Secret，写好标题正文 → 点推送，文章会进草稿箱（不会直接群发）。'))
  safe(() => addHowto('canvas', '这是一个手机 App 界面设计工具：左侧选部件、拖到画布上拼出界面 → 一键生成给 AI 编程工具（Claude Code / Codex / Cursor）的提示词。'))
}

// ═══════════════════════════════════════════════════════════════════════
// 背景视频（文稿 → 分幕 → 逐幕生图 → 拼接 → 配乐）—— 真实现
//
// 上游那套设计依赖 ASR 把音频转写后再分幕，而本机没有 ASR —— 所以这里改成
// 文案驱动：给一段文稿就能跑，音频只作为可选配乐。这是功能取舍，不是降级。
// ═══════════════════════════════════════════════════════════════════════

async function initBgVideo() {
  const btn = $('bgBtn')
  if (!btn) return

  const hint = $('bgHint')
  const progress = $('bgProgress')
  const bar = $('bgBar')
  const ptext = $('bgPtext')
  const segCard = $('bgSegCard')
  const segList = $('bgSegList')
  const segHint = $('bgSegHint')
  const resultCard = $('bgResultCard')
  const video = $('bgVideo')
  const resultHint = $('bgResultHint')

  for (const m of ['agnes-3.0-flash', 'agnes-2.5-flash', 'deepseek-chat', 'qwen-plus', 'doubao-pro-32k', 'MiniMax-Text-01']) {
    const o = document.createElement('option')
    o.value = m
    o.textContent = m
    $('bgTextModel').appendChild(o)
  }
  void refreshModelSelect($('bgTextModel'), 'agnes', 'agnes-3.0-flash', 'text')
  void attachModelSuggest($('bgImageModel'), 'agnes', 'image')

  const say = (t, k) => {
    hint.className = 'hint' + (k ? ' ' + k : '')
    hint.textContent = t
  }

  async function api(path, method = 'GET', body) {
    const r = await fetch(path, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
    let d = {}
    try { d = await r.json() } catch { /* 空响应 */ }
    if (!r.ok || d.error) throw new Error(String(d.error || `请求失败（HTTP ${r.status}）`))
    return d
  }

  btn.addEventListener('click', async () => {
    const scriptText = $('bgScript').value.trim()
    const scriptFile = $('bgScriptFile').value.trim()
    if (!scriptText && !scriptFile) {
      say('至少要在「文稿」里写点内容，或给一个文稿文件', 'error')
      return
    }
    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    resultCard.hidden = true
    segCard.hidden = true
    progress.hidden = false
    bar.style.width = '5%'
    ptext.textContent = '已提交…'
    say('正在生成…')

    try {
      const started = await api('/agnes-studio/api/bgvideo/generate', 'POST', {
        script_text: scriptText,
        script_file: scriptFile,
        scenes_count: parseInt($('bgScenes').value, 10) || 8,
        text_model: $('bgTextModel').value,
        image_model: $('bgImageModel').value.trim() || 'agnes-image-2.5-flash',
        audio_file: $('bgAudio').value.trim(),
        plan_only: false,
      })
      const tid = started.task_id
      const deadline = Date.now() + 60 * 60 * 1000
      let task = null
      while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 3000))
        const st = await api(`/agnes-studio/api/bgvideo/status?task_id=${encodeURIComponent(tid)}`)
        task = st.task
        if (task) {
          ptext.textContent = task.message || '处理中…'
          bar.style.width = (task.status === 'completed' ? 100 : 40) + '%'
        }
        if (task && ['completed', 'failed', 'stopped'].includes(task.status)) break
      }
      if (!task) throw new Error('任务超时')
      if (task.status === 'failed') throw new Error(task.error || task.message || '生成失败')

      // 分幕一览
      const segs = task.segments || []
      segList.replaceChildren()
      segs.forEach((sg) => {
        const chip = document.createElement('button')
        chip.type = 'button'
        chip.className = 'chip'
        chip.textContent = `第 ${sg.index} 幕 · ${String(sg.scene || sg.text || '').slice(0, 24)}`
        chip.addEventListener('click', () => {
          segHint.className = 'hint'
          segHint.textContent = `${String(sg.text || '')} ｜ 画面：${String(sg.scene || '')}`
        })
        segList.appendChild(chip)
      })
      segCard.hidden = segs.length === 0
      if (segs.length) segHint.textContent = '点任一幕看它对应的文稿与画面描述。'

      const src = `/agnes-studio/api/bgvideo/file/${encodeURIComponent(tid)}/${encodeURIComponent(task.video_id || 'final.mp4')}`
      video.src = src
      resultHint.textContent = task.message || ''
      resultCard.hidden = false
      bar.style.width = '100%'
      say('成片已出，下面可直接播放', 'ok')
    } catch (error) {
      say(error instanceof Error ? error.message : String(error), 'error')
      ptext.textContent = '出错'
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      setTimeout(() => { progress.hidden = true }, 1500)
    }
  })
}

// ═══════════════════════════════════════════════════════════════════════
// MTV（歌词 → 分镜 → 生图 → 片段 → 拼接 → 配乐）—— 真实现
// ═══════════════════════════════════════════════════════════════════════

async function initMv() {
  const btn = $('mvBtn')
  if (!btn) return

  const hint = $('mvHint')
  const progress = $('mvProgress')
  const bar = $('mvBar')
  const ptext = $('mvPtext')
  const resultCard = $('mvResultCard')
  const video = $('mvVideo')
  const scenesBox = $('mvScenes')
  const resultHint = $('mvResultHint')

  for (const m of ['agnes-3.0-flash', 'agnes-2.5-flash', 'deepseek-chat', 'qwen-plus', 'doubao-pro-32k', 'MiniMax-Text-01']) {
    const o = document.createElement('option')
    o.value = m
    o.textContent = m
    $('mvTextModel').appendChild(o)
  }
  void refreshModelSelect($('mvTextModel'), 'agnes', 'agnes-3.0-flash', 'text')
  void attachModelSuggest($('mvImageModel'), 'agnes', 'image')

  const say = (t, k) => {
    hint.className = 'hint' + (k ? ' ' + k : '')
    hint.textContent = t
  }

  async function api(path, method = 'GET', body) {
    const r = await fetch(path, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
    let d = {}
    try { d = await r.json() } catch { /* 空响应 */ }
    if (!r.ok || d.error) throw new Error(String(d.error || `请求失败（HTTP ${r.status}）`))
    return d
  }

  btn.addEventListener('click', async () => {
    const lyrics = $('mvLyrics').value.trim()
    if (!lyrics && !$('mvAudio').value.trim()) {
      say('至少要给歌词/主题或一首音乐', 'error')
      return
    }
    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    resultCard.hidden = true
    progress.hidden = false
    bar.style.width = '5%'
    ptext.textContent = '已提交…'
    say('正在生成…')

    try {
      const started = await api('/agnes-studio/api/mv/start', 'POST', {
        audio_file: $('mvAudio').value.trim(),
        lyrics,
        segments: parseInt($('mvSegments').value, 10) || 6,
        text_model: $('mvTextModel').value,
        image_model: $('mvImageModel').value.trim() || 'agnes-image-2.5-flash',
      })
      const tid = started.task_id
      const deadline = Date.now() + 60 * 60 * 1000
      let task = null
      const STAGE = { music: '准备音乐', design: '拆分镜', image: '生图', video: '合成', completed: '完成' }
      while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 3000))
        const st = await api(`/agnes-studio/api/mv/status/${encodeURIComponent(tid)}`)
        task = st.task
        if (task) {
          ptext.textContent = task.message || '处理中…'
          bar.style.width = (task.status === 'completed' ? 100 : 40) + '%'
        }
        if (task && ['completed', 'failed', 'stopped'].includes(task.status)) break
      }
      if (!task) throw new Error('任务超时')
      if (task.status === 'failed') throw new Error(task.error || task.message || '生成失败')

      const src = `/agnes-studio/api/mv/file/${encodeURIComponent(tid)}/${encodeURIComponent(task.video_id || 'final.mp4')}`
      video.src = src
      scenesBox.replaceChildren()
      ;(task.scenes || []).forEach((sc, i) => {
        const chip = document.createElement('span')
        chip.className = 'chip'
        chip.textContent = `${i + 1}. ${String(sc).slice(0, 26)}`
        scenesBox.appendChild(chip)
      })
      resultHint.textContent = task.message || ''
      resultCard.hidden = false
      bar.style.width = '100%'
      say('成片已出，下面可直接播放', 'ok')
    } catch (error) {
      say(error instanceof Error ? error.message : String(error), 'error')
      ptext.textContent = '出错'
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      setTimeout(() => { progress.hidden = true }, 1500)
    }
  })
}

// ═══════════════════════════════════════════════════════════════════════
// 画布 —— 内嵌「泡泡猫设计工作站」（纯静态子站，产物在 public/design/）
//
// 上游是 lnkiai/m3e-canvas（MIT），二次开发见 /root/软件/m3e-canvas。
// 这里只做嵌入与重载，不重写它——它有 5000 行的编辑器主体，重写没有意义。
// ═══════════════════════════════════════════════════════════════════════

function initCanvas() {
  const frame = $('cvFrame')
  if (!frame) return

  $('cvReload')?.addEventListener('click', () => {
    const src = frame.getAttribute('src') || '/design/'
    frame.setAttribute('src', src)
  })

  $('cvOpen')?.addEventListener('click', () => {
    window.open('/design/', '_blank', 'noopener')
  })
}

// ═══════════════════════════════════════════════════════════════════════
// 多能宝箱（视频下载 + 文本转语音）—— 真实现
// ═══════════════════════════════════════════════════════════════════════

async function initToolbox() {
  const dlBtn = $('tbDlBtn')
  if (!dlBtn) return

  const hint = $('tbHint')
  const logBox = $('tbLog')
  const listBox = $('tbList')
  const ttsHint = $('tbTtsHint')

  const say = (t, k) => {
    hint.className = 'hint' + (k ? ' ' + k : '')
    hint.textContent = t
  }
  const ttsSay = (t, k) => {
    ttsHint.className = 'hint' + (k ? ' ' + k : '')
    ttsHint.textContent = t
  }

  async function api(path, method = 'GET', body) {
    const r = await fetch(path, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
    let d = {}
    try { d = await r.json() } catch { /* 空响应 */ }
    if (!r.ok || d.error) throw new Error(String(d.error || `请求失败（HTTP ${r.status}）`))
    return d
  }

  async function refreshList() {
    try {
      const d = await api('/agnes-studio/api/toolbox/vidbee/list')
      const items = d.items || []
      listBox.replaceChildren()
      if (!items.length) {
        listBox.textContent = '还没有下载过文件'
        return
      }
      for (const it of items) {
        const row = document.createElement('a')
        row.className = 'file-item'
        row.href = `/agnes-studio/api/toolbox/file/${encodeURIComponent(it.name || '')}`
        row.setAttribute('download', it.name || '')
        row.textContent = `${it.name || '(未命名)'}${it.size ? ' · ' + (it.size / 1048576).toFixed(1) + ' MB' : ''}`
        listBox.appendChild(row)
      }
    } catch { /* 列表拿不到就算了 */ }
  }

  dlBtn.addEventListener('click', async () => {
    const url = $('tbUrl').value.trim()
    if (!url) { say('先填视频链接', 'error'); return }
    dlBtn.disabled = true
    dlBtn.setAttribute('aria-busy', 'true')
    logBox.hidden = false
    logBox.textContent = '提交中…'
    say('正在下载…')
    try {
      const started = await api('/agnes-studio/api/toolbox/vidbee/download', 'POST', {
        url,
        quality: $('tbQuality').value,
      })
      const tid = started.task_id
      const deadline = Date.now() + 30 * 60 * 1000
      let st = null
      while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 2500))
        st = await api(`/agnes-studio/api/toolbox/vidbee/status?task_id=${encodeURIComponent(tid)}`)
        logBox.textContent = (st.log || []).join('\n')
        if (st.status === 'done' || st.status === 'failed') break
      }
      if (!st) throw new Error('任务超时')
      if (st.status === 'failed') {
        throw new Error((st.log || []).slice(-1)[0] || '下载失败')
      }
      say('下载完成', 'ok')
      await refreshList()
    } catch (error) {
      say(error instanceof Error ? error.message : String(error), 'error')
    } finally {
      dlBtn.disabled = false
      dlBtn.removeAttribute('aria-busy')
    }
  })

  $('tbRefresh')?.addEventListener('click', () => { void refreshList() })

  $('tbTtsBtn')?.addEventListener('click', async () => {
    const text = $('tbText').value.trim()
    const btn = $('tbTtsBtn')
    if (!text) { ttsSay('先粘贴要朗读的文字', 'error'); return }
    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    ttsSay('合成中…（文字多时要等几十秒）')
    try {
      const d = await api('/agnes-studio/api/toolbox/tts', 'POST', {
        text,
        voice: $('tbVoice').value,
      })
      const audio = $('tbAudio')
      audio.src = d.dataUri
      const dl = $('tbDownload')
      dl.href = d.dataUri
      dl.download = d.file || 'tts.mp3'
      $('tbTtsResult').hidden = false
      ttsSay(`合成完成（${(d.bytes / 1024).toFixed(0)} KB）`, 'ok')
    } catch (error) {
      ttsSay(error instanceof Error ? error.message : String(error), 'error')
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
    }
  })

  await refreshList()
}

// ═══════════════════════════════════════════════════════════════════════
// 视频解析（本机 ffmpeg 抽帧 + 多模态模型读图）—— 真实现
// ═══════════════════════════════════════════════════════════════════════

async function initVideoparse() {
  const btn = $('vpBtn')
  if (!btn) return

  const hint = $('vpHint')
  const progress = $('vpProgress')
  const bar = $('vpBar')
  const ptext = $('vpPtext')
  const resultCard = $('vpResultCard')
  const summaryBox = $('vpSummary')
  const framesList = $('vpFramesList')
  const frameView = $('vpFrameView')
  const frameImg = $('vpFrameImg')
  const frameDesc = $('vpFrameDesc')

  const vsel = $('vpVendor')
  if (vsel) {
    for (const v of ['agnes', 'qwen', 'doubao', 'minimax', 'deepseek', 'ollama']) {
      const o = document.createElement('option')
      o.value = v
      o.textContent = v
      vsel.appendChild(o)
    }
  }

  const say = (t, k) => {
    hint.className = 'hint' + (k ? ' ' + k : '')
    hint.textContent = t
  }

  async function api(path, method = 'GET', body) {
    const r = await fetch(path, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
    let d = {}
    try { d = await r.json() } catch { /* 空响应 */ }
    if (!r.ok || d.error) throw new Error(String(d.error || `请求失败（HTTP ${r.status}）`))
    return d
  }

  let lastFrames = []
  let framesData = []
  let lastId = ''

  function showFrame(i) {
    const f = lastFrames[i]
    if (!f) return
    frameView.hidden = false
    frameImg.src = framesData[i] || ''
    frameDesc.textContent = `第 ${f.index} 帧 · 约 ${f.start} 秒 —— ${f.description}`
  }

  btn.addEventListener('click', async () => {
    const url = $('vpUrl').value.trim()
    if (!url) { say('先填视频链接或服务器上的本地路径', 'error'); return }
    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    resultCard.hidden = true
    frameView.hidden = true
    progress.hidden = false
    bar.style.width = '5%'
    ptext.textContent = '已提交…'
    say('正在解析…')
    try {
      const started = await api('/agnes-studio/api/video/parse', 'POST', {
        video_file: url,
        frames: parseInt($('vpFrames').value, 10) || 6,
        vendor: $('vpVendor').value,
        model: $('vpModel').value.trim() || 'agnes-2.5-flash',
      })
      lastId = started.id
      const deadline = Date.now() + 30 * 60 * 1000
      let task = null
      while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 3000))
        const st = await api(`/agnes-studio/api/video/parse/status/${encodeURIComponent(lastId)}`)
        task = st.task
        if (task) {
          ptext.textContent = task.message || '处理中…'
          bar.style.width = '40%'
        }
        if (task && ['completed', 'failed'].includes(task.status)) break
      }
      if (!task) throw new Error('任务超时')
      if (task.status === 'failed') throw new Error(task.message || '解析失败')

      lastFrames = Array.isArray(task.scenes) ? task.scenes : []
      framesData = Array.isArray(task.framesData) ? task.framesData : []
      summaryBox.value = task.summary || ''
      framesList.replaceChildren()
      lastFrames.forEach((f, i) => {
        const chip = document.createElement('button')
        chip.type = 'button'
        chip.className = 'chip'
        chip.textContent = `第${f.index}帧 · ${f.start}s`
        chip.addEventListener('click', () => showFrame(i))
        framesList.appendChild(chip)
      })
      resultCard.hidden = false
      bar.style.width = '100%'
      if (lastFrames.length) showFrame(0)
      say(`解析完成：${lastFrames.length} 帧`, 'ok')
    } catch (error) {
      say(error instanceof Error ? error.message : String(error), 'error')
      ptext.textContent = '出错'
    } finally {
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      setTimeout(() => { progress.hidden = true }, 1200)
    }
  })

  $('vptBtn')?.addEventListener('click', async () => {
    const h = $('vptHint')
    const s = (t, k) => {
      h.className = 'hint' + (k ? ' ' + k : '')
      h.textContent = t
    }
    if (!lastId) { s('先跑一次解析，再生成提示词', 'error'); return }
    s('正在生成…')
    try {
      const started = await api('/agnes-studio/api/vpt/generate', 'POST', {
        video_file: lastId,
        vendor: $('vpVendor').value,
        model: $('vpModel').value.trim() || 'agnes-2.5-flash',
      })
      const deadline = Date.now() + 10 * 60 * 1000
      let task = null
      while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 2500))
        const st = await api(`/agnes-studio/api/vpt/status/${encodeURIComponent(started.id)}`)
        task = st.task
        if (task && ['completed', 'failed'].includes(task.status)) break
        s((task && task.message) || '生成中…')
      }
      if (!task) throw new Error('任务超时')
      if (task.status === 'failed') throw new Error(task.message || '生成失败')
      $('vptResult').textContent = task.prompt || ''
      $('vptResultWrap').hidden = false
      s('已生成，可直接复制', 'ok')
    } catch (error) {
      s(error instanceof Error ? error.message : String(error), 'error')
    }
  })

  $('vptCopy')?.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText($('vptResult').textContent || '') } catch { /* 忽略 */ }
  })
}

// ═══════════════════════════════════════════════════════════════════════
// 小说工具（长文拆分 + 去 AI 味）—— 全部走真实模型与真实读写盘
// ═══════════════════════════════════════════════════════════════════════

async function initNovelTools() {
  const btn = $('nsBtn')
  if (!btn) return

  const hint = $('nsHint')
  const epsList = $('nsEpsList')
  const epsCard = $('nsEpsCard')
  const viewCard = $('nsViewCard')
  const viewBox = $('nsView')
  const viewTitle = $('nsViewTitle')
  const viewHint = $('nsViewHint')
  const progress = $('nsProgress')
  const bar = $('nsBar')
  const ptext = $('nsPtext')

  const MODELS = ['agnes-3.0-flash', 'agnes-2.5-flash', 'agnes-2.0-flash', 'deepseek-chat', 'qwen-plus', 'doubao-pro-32k', 'MiniMax-Text-01', 'ollama:llama3']
  for (const sel of [$('nsModel'), $('deModel')]) {
    if (!sel) continue
    for (const m of MODELS) {
      const o = document.createElement('option')
      o.value = m
      o.textContent = m
      sel.appendChild(o)
    }
  }
  void refreshModelSelect($('nsModel'), 'agnes', 'agnes-3.0-flash', 'text')
  void refreshModelSelect($('deModel'), 'agnes', 'agnes-3.0-flash', 'text')

  const say = (text, kind) => {
    hint.className = 'hint' + (kind ? ' ' + kind : '')
    hint.textContent = text
  }

  async function api(path, method = 'GET', body) {
    const r = await fetch(path, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
    let d = {}
    try { d = await r.json() } catch { /* 空响应 */ }
    if (!r.ok || d.error) throw new Error(String(d.error || `请求失败（HTTP ${r.status}）`))
    return d
  }

  const fileInput = $('nsFile')
  $('nsPickFile')?.addEventListener('click', () => fileInput?.click())
  fileInput?.addEventListener('change', async (e) => {
    const f = e.target.files && e.target.files[0]
    if (!f) return
    const fh = $('nsFileHint')
    try {
      const text = await f.text()
      $('nsText').value = text
      if (!$('nsTitle').value) $('nsTitle').value = f.name.replace(/\.(txt|md)$/i, '')
      fh.className = 'hint ok'
      fh.textContent = `已读入 ${f.name}（${text.length} 字）`
    } catch (error) {
      fh.className = 'hint error'
      fh.textContent = '读取失败：' + (error instanceof Error ? error.message : String(error))
    }
  })

  let episodes = []
  let running = false

  function renderEpisodes() {
    epsList.replaceChildren()
    if (!episodes.length) { epsCard.hidden = true; return }
    for (const ep of episodes) {
      const chip = document.createElement('button')
      chip.type = 'button'
      chip.className = 'chip'
      chip.textContent = `EP${String(ep.ep).padStart(3, '0')} ${ep.title}（${ep.content.length} 字）`
      chip.addEventListener('click', () => showEpisode(ep))
      epsList.appendChild(chip)
    }
    epsCard.hidden = false
  }

  function showEpisode(ep) {
    viewTitle.textContent = `EP${String(ep.ep).padStart(3, '0')} · ${ep.title}`
    viewBox.value = ep.content
    viewCard.hidden = false
    viewHint.className = 'hint'
    viewHint.textContent = ''
    viewCard.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  }

  btn.addEventListener('click', async () => {
    const source = $('nsText').value.trim()
    if (!source) { say('先把小说全文粘贴进来，或选一个文件', 'error'); return }
    if (running) { say('上一个任务还在跑，等它结束', 'error'); return }
    const n_eps = Math.max(1, Math.min(200, parseInt($('nsEps').value, 10) || 10))
    running = true
    btn.disabled = true
    btn.setAttribute('aria-busy', 'true')
    epsList.replaceChildren()
    epsCard.hidden = true
    viewCard.hidden = true
    progress.hidden = false
    bar.style.width = '5%'
    ptext.textContent = '已提交，等待模型…'
    say(`正在拆分 ${source.length} 字…`)

    try {
      const started = await api('/agnes-studio/api/novel-split/start', 'POST', {
        source,
        n_eps,
        model: $('nsModel').value,
        title: $('nsTitle').value.trim(),
      })
      const id = started.id
      const deadline = Date.now() + 30 * 60 * 1000
      let task = null
      while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 2500))
        const st = await api(`/agnes-studio/api/novel-split/status/${encodeURIComponent(id)}`)
        task = st.task
        if (task) {
          ptext.textContent = task.message || '处理中…'
          if (task.n_eps) bar.style.width = Math.min(95, 5 + (task.eps / task.n_eps) * 90) + '%'
        }
        if (task && ['completed', 'failed', 'stopped'].includes(task.status)) break
      }
      if (!task) throw new Error('任务超时没返回结果')
      if (task.status === 'failed') throw new Error(task.error || task.message || '拆分失败')

      episodes = Array.isArray(task.episodes) ? task.episodes : []
      renderEpisodes()
      bar.style.width = '100%'
      ptext.textContent = task.message || '完成'
      say(`拆分完成：${episodes.length} 集，共 ${task.words || source.length} 字`, 'ok')
      if (episodes.length) showEpisode(episodes[0])
    } catch (error) {
      say(error instanceof Error ? error.message : String(error), 'error')
      ptext.textContent = '出错'
    } finally {
      running = false
      btn.disabled = false
      btn.removeAttribute('aria-busy')
      setTimeout(() => { progress.hidden = true }, 1200)
    }
  })

  $('nsCopyEp')?.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(viewBox.value)
      viewHint.className = 'hint ok'
      viewHint.textContent = '已复制'
    } catch {
      viewHint.className = 'hint error'
      viewHint.textContent = '浏览器不让自动复制，请手动全选'
    }
  })

  $('nsSaveEp')?.addEventListener('click', async () => {
    if (!viewBox.value.trim()) return
    viewHint.className = 'hint'
    viewHint.textContent = '保存中…'
    try {
      const d = await api('/agnes-studio/api/novel-split/save', 'POST', {
        text: viewBox.value,
        name: viewTitle.textContent.replace(/[·\s]+/g, '-'),
      })
      viewHint.className = 'hint ok'
      viewHint.textContent = `✓ 已保存：${d.file}（${d.words} 字）`
    } catch (error) {
      viewHint.className = 'hint error'
      viewHint.textContent = error instanceof Error ? error.message : String(error)
    }
  })

  // ── 去 AI 味 ────────────────────────────────────────────────────────
  const deBtn = $('deBtn')
  const deHint = $('deHint')
  const deSay = (t, k) => {
    deHint.className = 'hint' + (k ? ' ' + k : '')
    deHint.textContent = t
  }

  deBtn?.addEventListener('click', async () => {
    const text = $('deText').value.trim()
    if (!text) { deSay('先粘贴要处理的正文', 'error'); return }
    deBtn.disabled = true
    deBtn.setAttribute('aria-busy', 'true')
    $('deResultCard').hidden = true
    deSay('正在处理…')
    try {
      const started = await api('/agnes-studio/api/deai/process', 'POST', {
        text,
        op: $('deOp').value,
        model: $('deModel').value,
      })
      const tid = started.tid
      const deadline = Date.now() + 20 * 60 * 1000
      let st = null
      while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 2500))
        st = await api(`/agnes-studio/api/deai/status/${encodeURIComponent(tid)}`)
        if (st.status === 'completed' || st.status === 'failed') break
        deSay(st.message || '处理中…')
      }
      if (!st) throw new Error('任务超时')
      if (st.status === 'failed') throw new Error(st.message || '处理失败')
      $('deResult').value = st.text || ''
      $('deResultCard').hidden = false
      deSay(`处理完成（${(st.text || '').length} 字）`, 'ok')
    } catch (error) {
      deSay(error instanceof Error ? error.message : String(error), 'error')
    } finally {
      deBtn.disabled = false
      deBtn.removeAttribute('aria-busy')
    }
  })

  $('deCopy')?.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText($('deResult').value) } catch { /* 忽略 */ }
  })

  $('deSave')?.addEventListener('click', async () => {
    const h = $('deSaveHint')
    if (!$('deResult').value.trim()) return
    h.className = 'hint'
    h.textContent = '保存中…'
    try {
      const d = await api('/agnes-studio/api/novel-split/save', 'POST', {
        text: $('deResult').value,
        name: '去AI味-' + Date.now(),
      })
      h.className = 'hint ok'
      h.textContent = `✓ 已保存：${d.file}（${d.words} 字）`
    } catch (error) {
      h.className = 'hint error'
      h.textContent = error instanceof Error ? error.message : String(error)
    }
  })
}

// ═══════════════════════════════════════════════════════════════════════
// 创作台（直接读写用户自己电脑上的目录；服务器全程不参与文件操作）
// ═══════════════════════════════════════════════════════════════════════

async function initOhstory() {
  const pickBtn = $('ohPick')
  if (!pickBtn) return

  const FS = window.LocalFS
  const envNote = $('ohEnvNote')
  const reconnectBtn = $('ohReconnect')
  const forgetBtn = $('ohForget')
  const hint = $('ohHint')
  const projectsCard = $('ohProjectsCard')
  const projectsBox = $('ohProjects')
  const filesCard = $('ohFilesCard')
  const filesBox = $('ohFiles')
  const editCard = $('ohEditCard')
  const contentBox = $('ohContent')
  const nameLabel = $('ohFileName')
  const editHint = $('ohEditHint')
  const saveBtn = $('ohSave')
  const newName = $('ohNewName')

  if (!FS) {
    envNote.className = 'note'
    envNote.textContent = '❌ 本机目录模块没加载成功（public/localfs.js）'
    pickBtn.disabled = true
    return
  }

  const aiCard = $('aiCard')
  let currentRel = ''
  let readOnly = false
  /** 当前打开的创作项目（点项目胶囊时记录），给 AI 创作当上下文用。 */
  let currentProject = ''
  let currentKind = ''

  const say = (text, kind) => {
    hint.className = 'hint' + (kind ? ' ' + kind : '')
    hint.textContent = text
  }
  const why = (error) => (error instanceof Error ? error.message : String(error))

  function renderEnv() {
    const cap = FS.capability()
    readOnly = cap === 'ro'
    if (cap === 'rw') {
      envNote.className = 'note'
      envNote.innerHTML = '✅ 直接读写<strong>你电脑上</strong>的文件夹。文件不经过服务器，也不需要任何访问口令。'
      pickBtn.disabled = false
      pickBtn.textContent = FS.mode === 'rw' ? `换一个文件夹（当前：${FS.rootName}）` : '选择本机文件夹'
      return
    }
    if (cap === 'ro') {
      envNote.className = 'note'
      envNote.innerHTML = `⚠️ 当前浏览器只能<strong>只读</strong>浏览本机目录，改了存不回去。原因：${FS.whyNoReadWrite()}。要能编辑请用 <strong>Chrome 或 Edge</strong> 打开。`
      pickBtn.disabled = false
      pickBtn.textContent = '选择本机文件夹（只读）'
      return
    }
    envNote.className = 'note'
    envNote.textContent = `❌ 当前环境拿不到本机目录能力：${FS.whyNoReadWrite()}`
    pickBtn.disabled = true
  }

  function showConnected(on) {
    forgetBtn.hidden = !on
    if (aiCard) aiCard.hidden = !on
    if (!on) {
      projectsCard.hidden = true
      filesCard.hidden = true
      editCard.hidden = true
    }
  }

  async function loadDir(rel) {
    const entries = await FS.list(rel)
    filesBox.replaceChildren()
    if (rel) {
      const up = document.createElement('button')
      up.type = 'button'
      up.className = 'file-item file-up'
      up.textContent = '⬆ 返回上级'
      up.addEventListener('click', () => {
        void loadDir(rel.split('/').slice(0, -1).join('/')).catch((err) => say(why(err), 'error'))
      })
      filesBox.appendChild(up)
    }
    for (const e of entries) {
      const item = document.createElement('button')
      item.type = 'button'
      item.className = 'file-item' + (e.type === 'dir' ? ' file-dir' : '')
      item.textContent = (e.type === 'dir' ? '📁 ' : '📄 ') + e.name
      item.addEventListener('click', () => {
        const next = rel ? `${rel}/${e.name}` : e.name
        if (e.type === 'dir') void loadDir(next).catch((err) => say(why(err), 'error'))
        else void openFile(next)
      })
      filesBox.appendChild(item)
    }
    filesCard.hidden = false
  }

  async function openFile(rel) {
    const d = await FS.read(rel)
    currentRel = rel
    nameLabel.textContent = rel
    contentBox.value = d.content || ''
    contentBox.readOnly = readOnly
    saveBtn.disabled = readOnly
    editCard.hidden = false
    editHint.className = 'hint'
    editHint.textContent = readOnly ? '只读模式：不能保存回本机' : ''
    editCard.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  }

  async function refreshProjects() {
    const projects = await FS.detectProjects()
    projectsBox.replaceChildren()
    for (const p of projects) {
      const chip = document.createElement('button')
      chip.type = 'button'
      chip.className = 'chip'
      const icon = p.kind === 'analysis' ? '📚 ' : p.kind === 'short' ? '📄 ' : '📖 '
      chip.textContent = icon + (p.name || p.dir)
      chip.addEventListener('click', () => {
        currentProject = p.name || p.dir
        currentKind = p.kind || ''
        void loadDir(p.dir).catch((err) => say(why(err), 'error'))
      })
      projectsBox.appendChild(chip)
    }
    projectsCard.hidden = false
    if (!projects.length) say('没找到创作项目（识别 正文/大纲/设定/追踪 这类结构）；下面直接列目录。')
  }

  async function enterWorkspace(label) {
    showConnected(true)
    await refreshProjects()
    await loadDir('')
    say(label, 'ok')
  }

  // 按钮也跟着上锁：直接禁用并改文案，比让用户撞到浏览器的英文报错好
  let picking = false
  /**
   * 通知外层页面：文件选择器要开了 / 关掉了。
   *
   * 为什么必须通知：开发预览页（/__preview.html）每 1.2 秒轮询文件变更戳，
   * 一变就重载 iframe。若它在系统文件夹选择框开着的期间重载，那个对话框会
   * 变成“幽灵”——浏览器仍认为有 picker 活跃，此后每次点击都报
   * `File picker already active`，而且刷新页面也没用。
   * 所以这里让它知道「先别刷新」，等选完再补一次刷新。
   */
  const notifyPicker = (open) => {
    try {
      if (window.parent && window.parent !== window) {
        window.parent.postMessage({ type: 'studio-picker', open: open }, '*')
      }
    } catch (error) { /* 顶层页面或跨域拿不到，装饰性通知，静默 */ }
  }
  pickBtn.addEventListener('click', async () => {
    if (picking) {
      say('正在等上一个文件夹选择窗口，先把它处理掉', 'error')
      return
    }
    picking = true
    notifyPicker(true)
    pickBtn.disabled = true
    const idleLabel = pickBtn.textContent
    pickBtn.textContent = '等待选择…'
    try {
      say('正在打开系统文件夹选择窗口…没看到的话，把浏览器窗口挪开找一找')
      const name = readOnly ? await FS.pickReadOnly() : await FS.pick()
      reconnectBtn.hidden = true
      await enterWorkspace(`已连接本机文件夹「${name}」`)
    } catch (error) {
      say(why(error), 'error')
      pickBtn.textContent = idleLabel
    } finally {
      picking = false
      notifyPicker(false)
      renderEnv()
    }
  })

  reconnectBtn.addEventListener('click', async () => {
    if (picking) {
      say('正在等上一个窗口，先把它处理掉', 'error')
      return
    }
    picking = true
    reconnectBtn.disabled = true
    try {
      const name = await FS.grant()
      reconnectBtn.hidden = true
      await enterWorkspace(`已重新连接「${name}」`)
    } catch (error) {
      say(why(error), 'error')
    } finally {
      picking = false
      reconnectBtn.disabled = false
      renderEnv()
    }
  })

  forgetBtn.addEventListener('click', async () => {
    try { await FS.forget() } catch (error) { /* ignore */ }
    renderEnv()
    reconnectBtn.hidden = true
    showConnected(false)
    say('已断开。选一个文件夹重新开始。')
  })

  saveBtn.addEventListener('click', async () => {
    if (!currentRel) return
    editHint.className = 'hint'
    editHint.textContent = '保存中…'
    try {
      const bytes = await FS.write(currentRel, contentBox.value)
      editHint.className = 'hint ok'
      editHint.textContent = `✓ 已保存到本机（${bytes} 字节）`
    } catch (error) {
      editHint.className = 'hint error'
      editHint.textContent = why(error)
    }
  })

  async function createNew(kind) {
    const name = (newName.value || '').trim()
    if (!name) { say('先填一个项目名', 'error'); return }
    try {
      const dir = await FS.createProject(kind, name)
      newName.value = ''
      await refreshProjects()
      await loadDir(dir)
      say(`已新建「${dir}」`, 'ok')
    } catch (error) {
      say(why(error), 'error')
    }
  }
  $('ohNewLong').addEventListener('click', () => void createNew('long'))
  $('ohNewShort').addEventListener('click', () => void createNew('short'))

  // 启动：先把 UI 立起来。AI 卡片是同步渲染的，绝不排在 IndexedDB 后面
  // （IndexedDB 首次打开可能要几百毫秒，放它后面会让整块界面迟迟不出现）
  renderEnv()
  showConnected(false)

  // ── AI 创作：7 类任务（任务定义与提示词都在 public/studio-ai.js）──────
  const AI = window.StudioAI
  if (!AI || !aiCard) return

  let aiTask = null
  let aiValues = {}
  let aiTarget = ''

  const aiSay = (text, kind) => {
    const el = $('aiHint')
    el.className = 'hint' + (kind ? ' ' + kind : '')
    el.textContent = text
  }

  function renderAiChips() {
    const box = $('aiTaskChips')
    box.replaceChildren()
    for (const t of AI.TASKS) {
      const chip = document.createElement('button')
      chip.type = 'button'
      chip.className = 'chip' + (aiTask && aiTask.key === t.key ? ' active' : '')
      chip.textContent = t.icon + ' ' + t.name
      chip.addEventListener('click', () => selectAiTask(t.key))
      box.appendChild(chip)
    }
  }

  function selectAiTask(key) {
    aiTask = AI.findTask(key)
    if (!aiTask) return
    aiValues = {}
    aiTarget = ''
    renderAiChips()
    $('aiTaskDesc').textContent = aiTask.desc
    const box = $('aiFields')
    box.replaceChildren()
    for (const f of aiTask.fields) {
      const wrap = document.createElement('div')
      wrap.className = 'field'
      const label = document.createElement('span')
      label.textContent = f.label
      wrap.appendChild(label)
      let input
      if (f.type === 'textarea') {
        input = document.createElement('textarea')
        input.rows = f.rows || 3
      } else if (f.type === 'select') {
        input = document.createElement('select')
        for (const opt of (f.options || [])) {
          const o = document.createElement('option')
          o.value = opt
          o.textContent = opt
          input.appendChild(o)
        }
      } else {
        input = document.createElement('input')
        input.type = 'text'
      }
      if (f.placeholder) input.placeholder = f.placeholder
      const initial = f.type === 'select' ? (f.default || (f.options || [])[0] || '') : (f.default || '')
      input.value = initial
      const sync = () => { aiValues[f.key] = input.value }
      input.addEventListener('input', sync)
      input.addEventListener('change', sync)
      aiValues[f.key] = initial
      wrap.appendChild(input)
      box.appendChild(wrap)
    }
    $('aiResultWrap').hidden = true
    aiSay('填好上面的项，点「生成」。会用你自己的 Key 调模型。')
  }

  $('aiRun').addEventListener('click', async () => {
    if (!aiTask) { aiSay('先选一个任务', 'error'); return }
    const btn = $('aiRun')
    btn.disabled = true
    $('aiResultWrap').hidden = true
    aiSay('生成中…（长文可能要一到两分钟，别关页面）')
    try {
      const out = await AI.generate(aiTask.key, aiValues, {
        FS: FS,
        projectDir: FS.rootName,
        bookName: currentProject || FS.rootName,
        projectKind: currentKind,
        model: ($('aiModel').value || '').trim() || 'agnes-2.5-flash',
        callProxy: callProxy
      })
      $('aiResult').value = out.text
      aiTarget = out.target || ''
      $('aiWrite').textContent = aiTarget ? ('写入 ' + aiTarget) : '写入文件'
      $('aiWriteHint').className = 'hint'
      $('aiWriteHint').textContent = aiTarget ? ('默认落点：' + aiTarget) : '这个任务没有默认落点，请用「复制」自己贴进文件'
      $('aiResultWrap').hidden = false
      aiSay('生成完成，共 ' + out.text.length + ' 字。可以先改再写盘。', 'ok')
    } catch (error) {
      aiSay(why(error), 'error')
    } finally {
      btn.disabled = false
    }
  })

  $('aiWrite').addEventListener('click', async () => {
    const wh = $('aiWriteHint')
    if (!aiTarget) {
      wh.className = 'hint error'
      wh.textContent = '这个任务没有默认落点，请用「复制」自己贴进文件'
      return
    }
    wh.className = 'hint'
    wh.textContent = '写入中…'
    try {
      const bytes = await FS.write(aiTarget, $('aiResult').value)
      wh.className = 'hint ok'
      wh.textContent = '✓ 已写入你电脑：' + aiTarget + '（' + bytes + ' 字节）'
      await loadDir('')
    } catch (error) {
      wh.className = 'hint error'
      wh.textContent = why(error)
    }
  })

  $('aiCopy').addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText($('aiResult').value)
      aiSay('已复制到剪贴板', 'ok')
    } catch (error) {
      aiSay('浏览器不让自动复制，请手动全选复制', 'error')
    }
  })

  renderAiChips()
  if (AI.TASKS.length) selectAiTask(AI.TASKS[0].key)

  // 恢复上次的文件夹：IndexedDB 可能慢，所以排在 UI 就绪之后，不拖累渲染
  if (FS.supportsReadWrite()) {
    try {
      const r = await FS.restore()
      if (r.status === 'ok') {
        renderEnv()
        await enterWorkspace(`已恢复上次的文件夹「${r.name}」`)
      } else if (r.status === 'need-permission') {
        reconnectBtn.hidden = false
        reconnectBtn.textContent = `重新连接「${r.name}」`
        say('浏览器要求你点一下按钮，才能恢复上次的文件夹。')
      }
    } catch (error) { /* 恢复失败就不打扰用户 */ }
  }
}

init()
initCover()
initExpert()
initAnchor()
initDrama()
initOhstory()
initNovelTools()
initVideoparse()
initToolbox()
initCanvas()
initMv()
initBgVideo()
initHome()
initKeyGuide()
initAssets()
initLibrary()
initLibTabs()
initOnboard()
initSlice()
initSimpleUI()

/* ══════════════════════════════════════════════════════════════════════
   鼠标拖尾（纯装饰）：一串光点依次追随光标，形成青→靛→紫→粉的尾巴。
   · 只在指针移动时出现，停手 0.7s 后整体淡出，并停止 rAF（静止零开销）
   · 触屏（pointerType = touch）不启用；prefers-reduced-motion 不启用
   · 与上方功能逻辑完全解耦，异常静默吞掉，不影响任何模块
   ── 想再调长度，只动下面两个常量 ──
     COUNT     光点数，越多尾巴越长（16 → 约 580px；32 → 约 3500px）
     EASE_TAIL 后续点的跟随系数，越小拖得越长（0.30 → 约 580px；0.125 → 约 3500px）
   （尾巴稳态长度 ≈ COUNT × 每帧位移 × (1-k)/k，鼠标快时自动更长）
   ══════════════════════════════════════════════════════════════════════ */
;(() => {
  try {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const wrap = document.querySelector('.trail')
    if (!wrap) return
    const COUNT = 32
    const EASE_HEAD = 0.42
    const EASE_TAIL = 0.125
    const dots = []
    for (let i = 0; i < COUNT; i++) {
      const s = document.createElement('span')
      const t = COUNT > 1 ? i / (COUNT - 1) : 0
      const size = 9 - 7 * t                              // 9px → 2px
      const hue = Math.round(187 + 118 * t)               // 187 青 → 305 粉
      s.style.cssText =
        `width:${size.toFixed(1)}px;height:${size.toFixed(1)}px;` +
        `background:hsl(${hue} 92% ${Math.round(68 + 16 * t)}%);` +
        `box-shadow:0 0 ${(11 - 6 * t).toFixed(1)}px hsl(${hue} 90% 68% / .85);` +
        `opacity:${(1 - 0.78 * t).toFixed(2)}`
      wrap.appendChild(s)
      dots.push(s)
    }
    const xs = dots.map(() => -200)
    const ys = dots.map(() => -200)
    let tx = -200, ty = -200, raf = 0, idle = 0, snap = 0, armed = false
    const frame = () => {
      let px = tx, py = ty, busy = false
      for (let i = 0; i < dots.length; i++) {
        const k = i ? EASE_TAIL : EASE_HEAD
        xs[i] += (px - xs[i]) * k
        ys[i] += (py - ys[i]) * k
        dots[i].style.transform =
          `translate3d(${xs[i].toFixed(1)}px, ${ys[i].toFixed(1)}px, 0) translate(-50%, -50%)`
        px = xs[i]
        py = ys[i]
        if (Math.abs(tx - xs[i]) > 0.4 || Math.abs(ty - ys[i]) > 0.4) busy = true
      }
      raf = busy ? requestAnimationFrame(frame) : 0
    }
    window.addEventListener('pointermove', (e) => {
      if (!armed) {
        if (e.pointerType === 'touch') return
        armed = true
      }
      tx = e.clientX
      ty = e.clientY
      wrap.classList.add('on')
      clearTimeout(idle)
      clearTimeout(snap)
      idle = setTimeout(() => wrap.classList.remove('on'), 700)
      // 长尾完全收敛要 4s 以上：等淡出结束后直接吸附到位，不空跑 rAF
      snap = setTimeout(() => {
        for (let i = 0; i < dots.length; i++) {
          xs[i] = tx
          ys[i] = ty
        }
      }, 1500)
      if (!raf) raf = requestAnimationFrame(frame)
    }, { passive: true })
  } catch { /* 装饰性功能，静默失败 */ }
})()
