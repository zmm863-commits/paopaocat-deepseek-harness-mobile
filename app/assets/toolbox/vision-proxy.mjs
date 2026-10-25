#!/usr/bin/env node
'use strict';
/**
 * vision-proxy.mjs —— App 内嵌的「看图代理」（免费视觉链，零第三方依赖）。
 *
 * 一句话：**视觉模型只是眼睛，文本模型是大脑**。手机上的文本模型看不懂图片
 * （ACP 实测 promptCapabilities.image = false，图片没法作为图片发过去），所以先把
 * 图片交给视觉模型转成文字，再把文字喂给文本模型。本脚本沿用本机 dsh-vision-router
 * 的免费视觉链思路：**按顺序试多个免费视觉端点，第一个成功的就用它**，
 * 失败/限流自动换下一个，客户端只看到一次成功的结果。
 *
 * 用法：
 *   node vision-proxy.mjs <图片路径> [--prompt "自定义提示词"] [--json] [--text]
 *   node vision-proxy.mjs --list
 *   node vision-proxy.mjs --help
 *
 * 渠道清单（默认顺序，可用 DSH_VISION_CHANNELS / --channels 覆盖）：
 *   zhipu     智谱 https://open.bigmodel.cn/api/paas/v4/chat/completions
 *             glm-4.6v-flash → glm-4.1v-thinking-flash → glm-4v-flash（三个都永久免费）
 *             Key: ZHIPU_API_KEY 或 GLM_API_KEY
 *   ovh       OVHcloud **匿名回退**（无需 Key，限 2 次/分/IP）
 *             https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/chat/completions
 *             Qwen2.5-VL-72B-Instruct
 *   dashscope 阿里百炼 https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions
 *             qwen3-vl-flash（限时免费）；Key: DASHSCOPE_API_KEY（可选渠道）
 *   intern    Intern AI https://chat.intern-ai.org.cn/api/v1/chat/completions
 *             internvl-latest（30 RPM / 90M tokens 每月）；Key: INTERN_API_KEY（可选渠道）
 *
 * 输出契约（stdout 只放机器可读结果，日志一律走 stderr）：
 *   成功：{"ok":true,"engine":"zhipu/glm-4.6v-flash","text":"…","elapsedMs":1234}
 *   全败：{"ok":false,"elapsedMs":…,"attempts":[{"engine":"…","error":"…"}]}  ← 退出码 1
 *
 * 参数：
 *   <图片路径>         本地 png/jpeg/webp/gif/bmp（也接受 data:image/...;base64,...）
 *   --prompt <文本>    自定义提示词；默认要求模型**用中文详细描述**（见 DEFAULT_PROMPT）
 *   --json             机器模式：stdout 只有那一行 JSON，日志压到最少
 *   --text             只把描述正文打到 stdout（方便直接管道给文本模型）；失败仍打 JSON
 *   --channels a,b     只用/按这个顺序用这些渠道（也可用 all 含可选渠道）
 *   --timeout-ms <n>   单个渠道的超时，默认 60000
 *   --budget-ms <n>    整次调用的总预算，默认 180000（超预算的渠道记成"未尝试"）
 *   --retry <n>        每个渠道失败后的重试次数，默认 1（只重试可重试的错误）
 *   --list             只打印渠道清单（JSON），不请求网络
 *   --help             显示完整说明
 *
 * 环境变量：
 *   ZHIPU_API_KEY / GLM_API_KEY · OVH_API_KEY · DASHSCOPE_API_KEY · INTERN_API_KEY
 *   DSH_VISION_CHANNELS     逗号分隔的渠道 id，决定顺序与子集（如 "ovh,zhipu"）
 *   DSH_VISION_MODELS_<ID>  覆盖某渠道的模型列表（如 DSH_VISION_MODELS_ZHIPU=glm-4v-flash）
 *   DSH_VISION_URL_<ID>     覆盖某渠道的端点地址
 *   DSH_VISION_PROMPT       默认提示词的兜底覆盖
 *   DSH_VISION_TIMEOUT_MS · DSH_VISION_BUDGET_MS · DSH_VISION_RETRY
 *
 * 依赖：只用 node 内置模块（node:fs / node:http / node:https / node:path / node:url），
 * 刻意**不使用 fetch**——要自己控制超时、请求头和"这个渠道到底哪一步失败了"。
 *
 * 退出码：0 成功；1 所有渠道都失败（stdout 里是 ok:false 的 JSON，不是异常栈）；2 参数/配置错误。
 */

import { existsSync, readFileSync, statSync } from 'node:fs';
import * as http from 'node:http';
import * as https from 'node:https';
import { basename, extname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// ─────────────────────────────────────────────────────────── 常量

const LOG_PREFIX = '[dsh-vision]';

/** 单个渠道的超时（对"发请求 → 读完响应体"整体计时；视觉请求很慢，给足） */
const DEFAULT_TIMEOUT_MS = 60_000;
/** 每个渠道失败后额外重试几次（1 = 失败重试一次） */
const DEFAULT_RETRY = 1;
/** 整次调用的总预算：手机端不能无限等，超了就停手并如实报告 */
const DEFAULT_BUDGET_MS = 180_000;
/** 图片大小上限（base64 后约 ×1.37，别再往上加，手机内存吃不住） */
const MAX_IMAGE_BYTES = 12 * 1024 * 1024;
/** 图片大过这个值就提示一句（不是错误，只是提醒会慢） */
const LARGE_IMAGE_BYTES = 2 * 1024 * 1024;
/** 重试前的等待（429/5xx 给一点喘息时间） */
const RETRY_BACKOFF_MS = 800;
/** 失败原因截断长度：只留开头一小段，既不刷屏也不会把密钥回显进来 */
const MAX_ERROR_CHARS = 300;

/**
 * 默认提示词。下游是**文本模型**，它看不到图，所以描述越结构化越有用：
 * 主体、文字（原文照抄）、布局、颜色、可操作的要素（按钮/输入框/坐标）。
 */
const DEFAULT_PROMPT = [
  '请用中文详细描述这张图片，输出结构化 Markdown，面向一个看不到图片的文本模型，务必让它读完就能理解并据此继续操作。',
  '',
  '请依次覆盖：',
  '1. **画面主体**：这是什么类型的图（截图/照片/图表/文档…），主要对象及其位置、状态、相互关系。',
  '2. **文字内容**：图中所有可见文字**原文照抄**（标题、正文、按钮文案、菜单、报错信息），保留层级；辨识不清的标注「不确定」。',
  '3. **布局结构**：从上到下、从左到右的区域划分，各区域的作用与相对位置。',
  '4. **颜色与视觉**：主色调、背景色、强调色、整体风格（浅色/深色/极简/拟物…）。',
  '5. **可操作的要素**：所有按钮、输入框、开关、链接、可点击项，逐个给出名称、状态（可用/禁用/选中）与大致位置（例如「右上角」「画面下方居中」，有把握时给出像素坐标或百分比）。',
  '6. **其他值得注意的细节**：数据、时间、数值、异常或错误提示、水印。',
  '',
  '要求：只描述你确实看到的内容，不要推测图片之外的背景；不确定的地方明确写「不确定」，不要编造。',
].join('\n');

/**
 * 渠道表。models 是**同一个渠道内按顺序试**的模型（智谱三个免费模型就靠这个把额度翻三倍）。
 * requireKey=false 表示匿名可用（OVH 回退）；optional=true 表示没有 Key 时默认不进链，
 * 只有显式 --channels/DSH_VISION_CHANNELS 点了它、或者配了 Key，才会被尝试。
 */
const CHANNELS = [
  {
    id: 'zhipu',
    label: '智谱 GLM',
    url: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    models: ['glm-4.6v-flash', 'glm-4.1v-thinking-flash', 'glm-4v-flash'],
    keyEnv: ['ZHIPU_API_KEY', 'GLM_API_KEY'],
    requireKey: true,
    optional: false,
    note: '三个模型都是永久免费，串起来等于把免费额度翻三倍',
  },
  {
    id: 'ovh',
    label: 'OVHcloud AI Endpoints（匿名回退）',
    url: 'https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/chat/completions',
    models: ['Qwen2.5-VL-72B-Instruct'],
    keyEnv: ['OVH_API_KEY', 'OVHCLOUD_API_KEY'],
    requireKey: false,
    optional: false,
    note: '无需 Key；匿名限 2 次/分/IP，配了 OVH_API_KEY 后额度高得多',
  },
  {
    id: 'dashscope',
    label: '阿里百炼 DashScope',
    url: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    models: ['qwen3-vl-flash'],
    keyEnv: ['DASHSCOPE_API_KEY'],
    requireKey: true,
    optional: true,
    note: '新用户每个模型系列 100 万 token / 90 天（限时免费）',
  },
  {
    id: 'intern',
    label: 'Intern AI（上海人工智能实验室）',
    url: 'https://chat.intern-ai.org.cn/api/v1/chat/completions',
    models: ['internvl-latest'],
    keyEnv: ['INTERN_API_KEY'],
    requireKey: true,
    optional: true,
    note: '30 RPM / 每月 9000 万 token',
  },
];

/** 扩展名 → MIME（嗅探失败时的兜底） */
const MIME_BY_EXT = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
};

const HELP = `vision-proxy.mjs —— App 内嵌的看图代理（免费视觉链，纯 node 内置模块）

用法:
  node vision-proxy.mjs <图片路径> [--prompt "自定义提示词"] [--json] [--text]
  node vision-proxy.mjs --list
  node vision-proxy.mjs --help

参数:
  <图片路径>       本地 png / jpeg / webp / gif / bmp；也接受 data:image/...;base64,...
  --prompt <文本>  自定义提示词（默认：要求模型用中文结构化描述图片，见文件头 DEFAULT_PROMPT）
  --json           机器模式：stdout 只有一行 JSON，日志压到最少
  --text           只把描述正文打到 stdout（适合直接管道给文本模型）；失败时仍输出 JSON 错误
  --channels a,b   只用/按此顺序用这些渠道（可选值：${CHANNELS.map((c) => c.id).join(' / ')}；all = 全部含可选）
  --timeout-ms <n> 单个渠道超时，默认 ${DEFAULT_TIMEOUT_MS}
  --budget-ms <n>  整次调用总预算，默认 ${DEFAULT_BUDGET_MS}（超预算的渠道记为"未尝试"）
  --retry <n>      每个渠道失败后的重试次数，默认 ${DEFAULT_RETRY}
  --list           只打印渠道清单（JSON），不访问网络
  --help, -h       显示本说明

渠道（默认顺序）:
${CHANNELS.map((c) => `  ${c.id.padEnd(10)} ${c.label}\n             ${c.url}\n             模型: ${c.models.join(' → ')}${c.optional ? '（可选，需 Key）' : ''}`).join('\n')}

环境变量:
  ZHIPU_API_KEY / GLM_API_KEY · OVH_API_KEY · DASHSCOPE_API_KEY · INTERN_API_KEY
  DSH_VISION_CHANNELS      逗号分隔的渠道 id（决定顺序与子集，如 "ovh,zhipu"）
  DSH_VISION_MODELS_<ID>   覆盖某渠道的模型列表
  DSH_VISION_URL_<ID>      覆盖某渠道的端点地址
  DSH_VISION_PROMPT        默认提示词的兜底覆盖
  DSH_VISION_TIMEOUT_MS · DSH_VISION_BUDGET_MS · DSH_VISION_RETRY

输出: stdout = 一行 JSON（成功 {"ok":true,"engine":"…","text":"…","elapsedMs":n}；全败 {"ok":false,"attempts":[…]}）
      所有日志走 stderr，前缀 ${LOG_PREFIX}
退出码: 0 成功；1 全部渠道失败；2 参数或配置错误。
`;

// ─────────────────────────────────────────────────────────── 日志与小工具

const state = {
  quiet: false, // --json：只记失败，不记"正在尝试…"这类过程日志
};

/** 一行日志 → stderr。stdout 只留给机器可读结果，绝不被日志污染 */
function logLine(message) {
  process.stderr.write(`${LOG_PREFIX} ${message}\n`);
}

function logVerbose(message) {
  if (!state.quiet) logLine(message);
}

/** 参数/配置错误：听人话、给退出码 2，绝不假装成功 */
function die(message, code) {
  process.stderr.write(`错误：${message}\n`);
  process.exit(code === undefined ? 2 : code);
}

/** 只留开头一小段，避免把整页 HTML 或密钥回显进日志 */
function head(text, n) {
  const s = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
  const limit = n || MAX_ERROR_CHARS;
  return s.length > limit ? `${s.slice(0, limit)}…` : s;
}

/** 密钥永不进日志：只打前 4 位 + 长度 */
function maskKey(key) {
  if (!key) return '(无)';
  const k = String(key);
  return `${k.slice(0, 4)}…(len=${k.length})`;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/** 环境变量里的整数：不在 [min,max] 或不是整数就退回默认值（手机上手写配置很容易写错，别让它把脚本搞崩） */
function envInt(env, name, fallback, min, max) {
  const raw = (env[name] || '').trim();
  if (!raw) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < min || n > max) return fallback;
  return n;
}

// ─────────────────────────────────────────────────────────── 渠道解析

/** 从环境变量里取这个渠道的 Key（多个候选变量按顺序取第一个非空的） */
function resolveKey(channel, env) {
  for (const name of channel.keyEnv) {
    const v = (env[name] || '').trim();
    if (v) return v;
  }
  return '';
}

/** 某个渠道在这个环境里是否"默认就该进链"：可选渠道没 Key 就不进 */
function isChannelReady(channel, env) {
  if (!channel.requireKey) return true;
  if (resolveKey(channel, env)) return true;
  return !channel.optional;
}

/**
 * 算出这次要用的渠道清单（按顺序）。
 * 优先级：--channels > DSH_VISION_CHANNELS > 默认（必需渠道 + 已配 Key 的可选渠道）。
 * 用 DSH_VISION_MODELS_<ID> / DSH_VISION_URL_<ID> 做单渠道覆盖。
 */
function resolveChannels(env, requested) {
  const raw = requested !== undefined && requested !== null ? requested : env.DSH_VISION_CHANNELS || '';
  const wanted = String(raw)
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);

  let list;
  if (wanted.length === 0) {
    list = CHANNELS.filter((c) => isChannelReady(c, env));
  } else if (wanted.includes('all')) {
    list = [...CHANNELS];
  } else {
    list = [];
    for (const id of wanted) {
      const c = CHANNELS.find((x) => x.id === id);
      if (!c) die(`不认识的渠道 id：${id}；可用：${CHANNELS.map((x) => x.id).join('、')}（或 all）`, 2);
      if (!list.includes(c)) list.push(c);
    }
  }

  return list.map((c) => {
    const envModels = (env[`DSH_VISION_MODELS_${c.id.toUpperCase()}`] || '').trim();
    const models = envModels
      ? envModels.split(',').map((s) => s.trim()).filter(Boolean)
      : [...c.models];
    const url = (env[`DSH_VISION_URL_${c.id.toUpperCase()}`] || '').trim() || c.url;
    return { ...c, models, url };
  });
}

/** --list 用的清单（带"这个环境里配没配 Key"，方便用户排查） */
function describeChannels(env, requested) {
  const active = resolveChannels(env, requested).map((c) => c.id);
  return CHANNELS.map((c) => {
    const key = resolveKey(c, env);
    return {
      id: c.id,
      label: c.label,
      url: c.url,
      models: c.models,
      optional: c.optional,
      requireKey: c.requireKey,
      keyEnv: c.keyEnv,
      keyPresent: Boolean(key),
      keyHint: resolveKey(c, env) ? maskKey(key) : '(无)',
      inChain: active.includes(c.id),
      note: c.note,
    };
  });
}

// ─────────────────────────────────────────────────────────── 图片

/** 按文件头嗅探 MIME（扩展名会说谎，尤其是微信/相册导出的图） */
function sniffMime(buf) {
  if (!buf || buf.length < 4) return null;
  if (buf.length >= 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'image/png';
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf.length >= 6) {
    const magic6 = buf.toString('latin1', 0, 6);
    if (magic6 === 'GIF87a' || magic6 === 'GIF89a') return 'image/gif';
  }
  if (buf.length >= 12 && buf.toString('latin1', 0, 4) === 'RIFF' && buf.toString('latin1', 8, 12) === 'WEBP') return 'image/webp';
  if (buf[0] === 0x42 && buf[1] === 0x4d) return 'image/bmp';
  return null;
}

/** 本地图片 → OpenAI 兼容的 data URI（也接受现成的 data: 字符串） */
function loadImage(input) {
  const raw = String(input == null ? '' : input).trim();
  if (!raw) die('缺少图片路径', 2);

  if (/^data:/i.test(raw)) {
    const m = /^data:([^;,]+)(;base64)?,(.*)$/is.exec(raw);
    if (!m) die('data: URI 格式不对（形如 data:image/png;base64,<base64>）', 2);
    if (!/^image\//i.test(m[1])) die(`data: URI 的 MIME 不是图片：${m[1]}`, 2);
    const b64 = m[3] || '';
    if (!b64) die('data: URI 里没有 base64 内容', 2);
    return {
      dataUri: raw,
      mime: m[1].toLowerCase(),
      bytes: Math.floor((b64.length * 3) / 4),
      path: '(data: URI)',
    };
  }

  const abs = resolve(raw);
  if (!existsSync(abs)) die(`图片不存在：${abs}`, 2);
  let st;
  try {
    st = statSync(abs);
  } catch (e) {
    die(`读不了这个路径（${abs}）：${e.message}`, 2);
  }
  if (!st.isFile()) die(`不是文件：${abs}`, 2);
  if (st.size === 0) die(`图片是空文件：${abs}`, 2);
  if (st.size > MAX_IMAGE_BYTES) {
    die(`图片太大（${(st.size / 1048576).toFixed(1)}MB，上限 ${MAX_IMAGE_BYTES / 1048576}MB）：${abs}`, 2);
  }

  let buf;
  try {
    buf = readFileSync(abs);
  } catch (e) {
    die(`读图片失败（${abs}）：${e.message}`, 2);
  }

  const ext = extname(abs).toLowerCase();
  const mime = sniffMime(buf) || MIME_BY_EXT[ext] || null;
  if (!mime) {
    die(`认不出图片格式（扩展名 ${ext || '无'}）：${abs}；支持 ${Object.keys(MIME_BY_EXT).join(' / ')}`, 2);
  }
  if (st.size > LARGE_IMAGE_BYTES) {
    logVerbose(`图片偏大（${(st.size / 1048576).toFixed(1)}MB），base64 后约 ${(st.size / 786432).toFixed(1)}MB，可能较慢`);
  }

  return { dataUri: `data:${mime};base64,${buf.toString('base64')}`, mime, bytes: st.size, path: abs };
}

// ─────────────────────────────────────────────────────────── HTTP（不用 fetch）

/**
 * POST 一个 JSON 请求并读完响应体。
 * 只 resolve 出 { status, text }；连接失败/超时都 reject 成中文 Error，
 * 上层据此决定"换模型/换渠道"。
 */
function postJson(urlStr, { headers, body, timeoutMs }) {
  return new Promise((resolveP, rejectP) => {
    let u;
    try {
      u = new URL(urlStr);
    } catch {
      rejectP(new Error(`URL 不合法：${urlStr}`));
      return;
    }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') {
      rejectP(new Error(`不支持的协议：${u.protocol}`));
      return;
    }

    const mod = u.protocol === 'https:' ? https : http;
    let settled = false;
    let timer = null;
    let req = null;
    const secs = Math.round(timeoutMs / 1000);
    const finish = (fn, v) => {
      if (settled) return;
      settled = true;
      if (timer) {
        clearTimeout(timer);
        timer = null;
      }
      fn(v);
    };

    timer = setTimeout(() => {
      const err = new Error(`超时（${secs}s 内没有拿到完整响应）`);
      if (req) {
        try {
          req.destroy(err);
        } catch {
          /* 已经关了 */
        }
      }
      finish(rejectP, err);
    }, timeoutMs);
    if (timer.unref) timer.unref();

    try {
      req = mod.request(u, { method: 'POST', headers }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => finish(resolveP, { status: res.statusCode || 0, text: Buffer.concat(chunks).toString('utf8') }));
        res.on('error', (e) => finish(rejectP, new Error(`${e.code || 'ERR'}：${e.message}`)));
      });
    } catch (e) {
      finish(rejectP, new Error(`${e.code || 'ERR'}：${e.message}`));
      return;
    }
    req.on('error', (err) => finish(rejectP, new Error(`${err.code || 'ERR'}：${err.message}`)));
    req.end(body);
  });
}

/** 从错误响应体里尽量抠出供应商的原话（抠不出来就退回原始文本） */
function providerError(text) {
  const raw = String(text || '');
  try {
    const j = JSON.parse(raw);
    const msg = (j && j.error && (j.error.message || j.error.code)) || (j && (j.message || j.msg));
    if (msg) return String(msg);
  } catch {
    /* 不是 JSON 就算了 */
  }
  return raw;
}

/** 402/401/403/404/429 这些常见码给一句人话提示，方便用户自己修 */
function statusHint(status) {
  if (status === 401 || status === 403) return '（Key 无效/没权限，或没开通该模型）';
  if (status === 402) return '（额度已用完，需要充值）';
  if (status === 404) return '（模型名或路径不对）';
  if (status === 413) return '（图片太大，供应商拒收）';
  if (status === 429) return '（被限流了）';
  if (status >= 500) return '（供应商侧故障）';
  return '';
}

/** 这些情况值得原地重试一次；4xx（除限流）重试没意义，直接换下一个 */
function isRetryable(status) {
  if (!status) return true; // 连接失败/超时
  if (status === 408 || status === 409 || status === 425 || status === 429) return true;
  return status >= 500;
}

// ─────────────────────────────────────────────────────────── 响应解析

/** OpenAI 兼容响应 → 纯文本（content 可能是字符串，也可能是分片数组） */
function extractText(json) {
  const choices = json && json.choices;
  if (!Array.isArray(choices) || choices.length === 0) return null;
  const choice = choices[0] || {};
  const msg = choice.message || choice.delta || {};
  let content = msg.content;
  if (Array.isArray(content)) {
    content = content
      .map((p) => (typeof p === 'string' ? p : (p && (p.text || p.content)) || ''))
      .join('');
  }
  if (typeof content === 'string' && content.trim()) return content.trim();
  // 思考型模型（glm-4.1v-thinking-flash 这类）偶尔只回思考链，正文为空：聊胜于无
  const reasoning = msg.reasoning_content || msg.reasoning;
  if (typeof reasoning === 'string' && reasoning.trim()) return reasoning.trim();
  return null;
}

/** 按 OpenAI 兼容格式拼请求体：文字在前、图片在后 */
function buildMessages(prompt, dataUri) {
  return [
    {
      role: 'user',
      content: [
        { type: 'text', text: prompt },
        { type: 'image_url', image_url: { url: dataUri } },
      ],
    },
  ];
}

// ─────────────────────────────────────────────────────────── 核心：试一个渠道的模型

/**
 * 试一个 (渠道, 模型)。失败重试一次（只重试"值得重试"的错误）。
 * 返回 { ok:true, text, ms, retries, status } 或 { ok:false, error, retries, status, authDead }
 * authDead=true 表示 401/403 —— 同渠道剩下的模型不用试了，Key 就是无效的。
 */
async function callEngine({ channel, model, dataUri, prompt, timeoutMs, retry, env }) {
  const key = resolveKey(channel, env);
  const body = Buffer.from(
    JSON.stringify({ model, messages: buildMessages(prompt, dataUri), stream: false }),
    'utf8',
  );
  const headers = {
    'content-type': 'application/json',
    accept: 'application/json',
    'content-length': String(body.length),
  };
  if (key) headers.authorization = `Bearer ${key}`;

  let lastError = null;
  let lastStatus = 0;
  let retries = 0;
  const started = Date.now();

  for (let attempt = 0; attempt <= retry; attempt += 1) {
    if (attempt > 0) {
      retries += 1;
      logVerbose(`${channel.id}/${model} 重试（第 ${attempt + 1} 次尝试）…`);
      await sleep(RETRY_BACKOFF_MS);
    }
    try {
      const r = await postJson(channel.url, { headers, body, timeoutMs });
      lastStatus = r.status;

      if (r.status >= 200 && r.status < 300) {
        let json;
        try {
          json = JSON.parse(r.text);
        } catch (e) {
          throw Object.assign(new Error(`响应不是合法 JSON：${e.message}；响应体前 200 字符：${head(r.text, 200)}`), {
            status: r.status,
            retryable: true,
          });
        }
        const text = extractText(json);
        if (!text) {
          throw Object.assign(new Error(`响应里没有可用文本（可能被内容审核拦下）：${head(r.text, 200)}`), {
            status: r.status,
            retryable: false,
          });
        }
        return { ok: true, text, ms: Date.now() - started, retries, status: r.status };
      }

      throw Object.assign(
        new Error(`HTTP ${r.status}${statusHint(r.status)}：${head(providerError(r.text), 200)}`),
        { status: r.status, retryable: isRetryable(r.status) },
      );
    } catch (e) {
      lastError = e;
      if (e.status) lastStatus = e.status;
      const retryable = e.retryable === undefined ? true : e.retryable;
      if (!retryable || attempt >= retry) break;
      logVerbose(`${channel.id}/${model} 第 ${attempt + 1} 次失败（${e.message}）`);
    }
  }

  return {
    ok: false,
    error: lastError || new Error('未知失败'),
    ms: Date.now() - started,
    retries,
    status: lastStatus,
    authDead: lastStatus === 401 || lastStatus === 403,
  };
}

// ─────────────────────────────────────────────────────────── 参数解析

function parseArgs(argv) {
  const out = {
    image: null,
    prompt: null,
    channels: null,
    json: false,
    text: false,
    list: false,
    timeoutMs: null,
    budgetMs: null,
    retry: null,
  };
  const need = (name, i) => {
    const v = argv[i];
    if (v === undefined || (v.startsWith('--') && v !== '')) die(`${name} 后面需要跟一个值`, 2);
    return v;
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const eq = /^--([a-z-]+)=(.*)$/is.exec(a);
    if (eq) {
      argv = [...argv.slice(0, i), `--${eq[1]}`, eq[2], ...argv.slice(i + 1)];
      i -= 1;
      continue;
    }
    if (a === '--help' || a === '-h') {
      process.stdout.write(HELP);
      process.exit(0);
    } else if (a === '--list') {
      out.list = true;
    } else if (a === '--json') {
      out.json = true;
    } else if (a === '--text') {
      out.text = true;
    } else if (a === '--prompt' || a === '-p') {
      i += 1;
      out.prompt = need('--prompt', i);
    } else if (a === '--channels' || a === '-c') {
      i += 1;
      out.channels = need('--channels', i);
    } else if (a === '--timeout-ms') {
      i += 1;
      out.timeoutMs = Number(need('--timeout-ms', i));
    } else if (a === '--budget-ms') {
      i += 1;
      out.budgetMs = Number(need('--budget-ms', i));
    } else if (a === '--retry') {
      i += 1;
      out.retry = Number(need('--retry', i));
    } else if (a.startsWith('-')) {
      die(`不认识的参数：${a}（用法见 --help）`, 2);
    } else if (out.image === null) {
      out.image = a;
    } else {
      die(`多余的参数：${a}`, 2);
    }
  }
  if (!out.list && !out.image) die('缺少图片路径（用法见 --help）', 2);
  if (out.json && out.text) die('--json 和 --text 只能选一个', 2);
  for (const [name, v] of [
    ['--timeout-ms', out.timeoutMs],
    ['--budget-ms', out.budgetMs],
  ]) {
    if (v !== null && (!Number.isInteger(v) || v <= 0)) die(`${name} 需要一个正整数，收到 ${JSON.stringify(v)}`, 2);
  }
  if (out.retry !== null && (!Number.isInteger(out.retry) || out.retry < 0 || out.retry > 5)) {
    die(`--retry 需要一个 0..5 的整数，收到 ${JSON.stringify(out.retry)}`, 2);
  }
  return out;
}

/** 输出一个 JSON 信封到 stdout（stdout 永远只有这一行是机器可读的） */
function emit(envelope) {
  process.stdout.write(`${JSON.stringify(envelope)}\n`);
}

// ─────────────────────────────────────────────────────────── 主流程

async function main(argv) {
  const args = parseArgs(argv);

  if (args.json) state.quiet = true;

  const env = process.env;
  const timeoutMs = args.timeoutMs || envInt(env, 'DSH_VISION_TIMEOUT_MS', DEFAULT_TIMEOUT_MS, 1000, 600_000);
  const budgetMs = args.budgetMs || envInt(env, 'DSH_VISION_BUDGET_MS', DEFAULT_BUDGET_MS, 1000, 3_600_000);
  const retry = args.retry !== null ? args.retry : envInt(env, 'DSH_VISION_RETRY', DEFAULT_RETRY, 0, 5);

  if (args.list) {
    process.stdout.write(`${JSON.stringify({ ok: true, channels: describeChannels(env, args.channels) }, null, 2)}\n`);
    return 0;
  }

  const prompt = (args.prompt !== null ? args.prompt : env.DSH_VISION_PROMPT || '').trim() || DEFAULT_PROMPT;
  if (args.prompt !== null && args.prompt.trim() === '') die('--prompt 不能是空白', 2);

  const image = loadImage(args.image);
  const channels = resolveChannels(env, args.channels);
  const startedAt = Date.now();

  logVerbose(`图片：${image.path}（${(image.bytes / 1024).toFixed(1)}KB，${image.mime}）`);
  logVerbose(
    `渠道链：${channels.map((c) => `${c.id}[${c.models.join('→')}]`).join(' → ') || '(空)'} | 超时=${Math.round(timeoutMs / 1000)}s/渠道 | 重试=${retry} | 总预算=${Math.round(budgetMs / 1000)}s`,
  );

  const attempts = [];

  for (const channel of channels) {
    const key = resolveKey(channel, env);

    if (channel.requireKey && !key) {
      const engine = `${channel.id}/${channel.models[0] || '?'}`;
      const error = `没有配置 ${channel.keyEnv.join(' 或 ')}，跳过这个渠道`;
      attempts.push({ engine, channel: channel.id, error });
      logLine(`${engine} 跳过：${error}`);
      continue;
    }
    if (key) logVerbose(`${channel.id}：使用 Key ${maskKey(key)}（${channel.keyEnv.join('/')}）`);

    let stopChannel = false;
    for (const model of channel.models) {
      const engine = `${channel.id}/${model}`;

      const used = Date.now() - startedAt;
      if (used > budgetMs) {
        attempts.push({
          engine,
          channel: channel.id,
          error: `总预算 ${budgetMs}ms 已用完（已用 ${used}ms），未尝试`,
          skipped: true,
        });
        logLine(`${engine} 未尝试：总预算已用完（已用 ${Math.round(used / 1000)}s / ${Math.round(budgetMs / 1000)}s）`);
        stopChannel = true;
        break;
      }

      logVerbose(`${engine} 请求中…（${channel.url}）`);
      let r;
      try {
        r = await callEngine({ channel, model, dataUri: image.dataUri, prompt, timeoutMs, retry, env });
      } catch (e) {
        // callEngine 内部已经吞掉预期的失败；走到这里说明是没预料到的错误，也算这个渠道失败
        r = { ok: false, error: e, status: 0, retries: 0 };
      }

      if (r.ok) {
        const envelope = {
          ok: true,
          engine,
          text: r.text,
          elapsedMs: Date.now() - startedAt,
          channelMs: r.ms,
          retries: r.retries,
          mime: image.mime,
          bytes: image.bytes,
        };
        logLine(`${engine} 成功（${Math.round(r.ms / 1000)}s${r.retries ? `，重试 ${r.retries} 次` : ''}，正文 ${r.text.length} 字）`);
        if (args.text) {
          process.stdout.write(r.text.endsWith('\n') ? r.text : `${r.text}\n`);
        } else {
          emit(envelope);
        }
        return 0;
      }

      const why = head(r.error && r.error.message ? r.error.message : String(r.error), MAX_ERROR_CHARS);
      attempts.push({
        engine,
        channel: channel.id,
        error: why,
        status: r.status || 0,
        ms: r.ms || 0,
        retries: r.retries || 0,
      });
      logLine(`${engine} 失败：${why}`);

      if (r.authDead) {
        stopChannel = true;
        logLine(`${channel.id}：返回 ${r.status}，判断这个渠道的 Key 无效/无权限，跳过它剩下的 ${channel.models.length - channel.models.indexOf(model) - 1} 个模型`);
        break;
      }
    }

    if (stopChannel) {
      const rest = channel.models.filter((m) => !attempts.some((a) => a.engine === `${channel.id}/${m}`));
      for (const m of rest) {
        attempts.push({
          engine: `${channel.id}/${m}`,
          channel: channel.id,
          error: '跳过（同渠道已停止尝试：Key 无效或总预算用完）',
          skipped: true,
        });
      }
      continue;
    }
  }

  // 全部失败：如实报告每个渠道/模型的原因，绝不抛异常栈
  const envelope = {
    ok: false,
    elapsedMs: Date.now() - startedAt,
    attempts,
  };
  if (channels.length === 0) {
    envelope.hint = '没有任何渠道可用：请检查 DSH_VISION_CHANNELS / --channels 配置';
  } else if (attempts.every((a) => /没有配置/.test(a.error))) {
    envelope.hint = '所有渠道都缺少 API Key；OVHcloud 匿名回退本该无需 Key，如果它也没试，说明渠道链被环境变量裁剪过';
  } else if (attempts.some((a) => /超时|ENOTFOUND|EAI_AGAIN|ECONNREFUSED|socket hang up|fetch failed|超时/.test(a.error))) {
    envelope.hint = '多数失败像是网络不可达；请确认手机能访问这些域名（部分渠道在境内直连）';
  }
  // 说明白"真正发出去的请求"和"被跳过的条目"不是一回事，免得日志误导排查
  const realAttempts = attempts.filter((a) => !a.skipped).length;
  logLine(
    `全部渠道都失败了（实际发出请求 ${realAttempts} 次，共 ${attempts.length} 条记录，耗时 ${Math.round((Date.now() - startedAt) / 1000)}s）`,
  );
  emit(envelope);
  return 1;
}

// 只有被直接 `node vision-proxy.mjs` 调用时才跑主流程（被 import 时不自动跑，方便单测）
//
// ⚠️ 兜底那一分支是真机上踩出来的：App 用 `Process.start` 直接 spawn 本脚本时
// （不经过 sh），URL 相等有时对不上——表现是 node 启动、什么都没干、exit 0。
// 所以再加一条按文件名认的兜底判断。
const isDirectRun = (() => {
  if (!process.argv[1]) return false;
  try {
    if (pathToFileURL(resolve(process.argv[1])).href === import.meta.url) return true;
  } catch {
    /* 落到下面的兜底 */
  }
  try {
    return basename(process.argv[1]) === basename(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();

if (isDirectRun) {
  // 顶层兜底：任何没预料到的异常也**只输出 JSON 错误信封 + 非零退出**，
  // 绝不把异常栈丢到 stdout（App 侧只认 stdout 那一行 JSON）。
  main(process.argv.slice(2))
    .then((code) => process.exit(code || 0))
    .catch((e) => {
      process.stderr.write(`${LOG_PREFIX} 未预期错误：${(e && e.stack) || e}\n`);
      try {
        process.stdout.write(`${JSON.stringify({ ok: false, attempts: [{ engine: '(internal)', error: head((e && e.message) || String(e), MAX_ERROR_CHARS) }] })}\n`);
      } catch {
        /* stdout 都写不进去就没辙了 */
      }
      process.exit(1);
    });
}

export {
  CHANNELS,
  DEFAULT_PROMPT,
  buildMessages,
  callEngine,
  describeChannels,
  envInt,
  extractText,
  isRetryable,
  loadImage,
  main,
  parseArgs,
  resolveChannels,
  resolveKey,
  sniffMime,
};
