#!/usr/bin/env node
'use strict';
/**
 * rotate-proxy.mjs —— 本地「模型轮换」代理（OpenAI 兼容）。
 *
 * 用法：
 *   node rotate-proxy.mjs <config.json> [--port 39321] [--log <file>] [--verbose]
 *
 * 它做一件事：把一个**组名**当成模型名暴露给客户端，收到请求后按顺序去试组里的
 * 成员（DeepSeek → Qwen → …），第一个成功的就用它。429/500/连接失败这类"这个
 * 供应商不行"的情况会自动换下一个，客户端只看到一次成功的响应。
 *
 * config.json：
 *   {
 *     "port": 39321,                                   // 可被 --port 覆盖
 *     "groups": {
 *       "cat": {
 *         "members": [
 *           { "name": "deepseek", "baseUrl": "https://api.deepseek.com/v1",
 *             "apiKey": "sk-...", "model": "deepseek-chat" },
 *           { "name": "qwen", "baseUrl": "https://dashscope.aliyuncs.com/compatible-mode/v1",
 *             "apiKey": "sk-...", "model": "qwen-max" }
 *         ]
 *       }
 *     },
 *     "lastGood": { "cat": 1 }                         // 本程序自己写的"上次成功的成员下标"
 *   }
 *
 * 接口：
 *   GET  /health                  → {"ok":true,"groups":["cat"]}
 *   GET  /v1/models               → OpenAI 风格的模型列表（每组一个，id = 组名）
 *   POST /v1/chat/completions     → 核心；model 填**组名**（rotate/cat 这种带前后缀
 *                                   的写法也能匹配；退一步，填成员真实 model 名也认）
 *   其它路径                       → 404 JSON
 *
 * 鉴权（2026-10-09 加，审计 P0-3）：
 *   这个代理监听 127.0.0.1，但 **loopback 在整机上是共享的** —— 同机任何带
 *   INTERNET 权限的应用都能扫端口、POST 上来，用用户的 Key 花钱。所以：
 *     * 所有路径（**包括 /health**）都要求 `Authorization: Bearer <token>`
 *       （或 `x-api-key: <token>`），比对是等时的；
 *     * 令牌从**配置的 `token` 字段**读（App 用 `--config-stdin` 从管道给它，
 *       不进 argv、不落盘）；`--token` 只是兜底；
 *     * 既没令牌又没显式 `--no-auth` → **拒绝启动**（退出码 3），
 *       而不是"那就裸奔"——失败默认必须安全。
 *
 * 配置从哪来（2026-10-09 改，审计 P0-2）：
 *   正式路径是 `--config-stdin`：App 把配置（**含各厂家真实 Key**）写进管道。
 *   为什么不写文件：`HOME=filesDir`，模型驱动的 shell 在同一个 uid 下跑 ——
 *   它 `cat $HOME/toolbox/rotate-config.json` 就能把 Key 读走再发到网上。
 *   传 `<config.json>` 的老路子还在，但**只适合调试**（Key 会落盘）。
 *
 * 粘性（sticky）：
 *   记住每组「最近一次成功的成员下标」，内存 + 回写**状态文件**（`--state`）的
 *   顶层 lastGood。状态文件里**只有下标、没有任何凭据/配置**，所以留着没风险。
 *   写盘失败只在日志里说一声，不影响服务。
 *
 * ⚠ 流式（stream:true）的已知限制（如实写清楚）：
 *   * 只有"上游返回非 2xx"或"连接失败/超时（还没往客户端吐过任何字节）"才换下一个；
 *   * 一旦开始把上游 SSE 管道给客户端，就**不可能**再换成员了 —— HTTP 响应头和
 *     数据都已经发出去了。这种情况下如果上游中途断开，只能就此结束这次响应，
 *     并打一行日志说明"已吐过数据，无法切换"。这不是偷懒，是 HTTP 协议本身的约束。
 *
 * 依赖：只用 node 内置模块（node:http / node:https / node:fs / node:path），
 * 刻意不使用 fetch（更好地控制请求头、超时和"吐过数据没有"这个状态）。
 */

import { createHash, timingSafeEqual } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import * as http from 'node:http';
import * as https from 'node:https';
import { basename, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// 兜底：任何未捕获异常/未处理的拒绝都**只记日志、不让进程死**。
//
// 为什么必须有（真机踩出来的）：DSH 发来的请求一旦触发某个未捕获的 'error' 事件，
// node 会直接以 code=1 退出 —— 表现是会话侧只看到 "Connection error"，
// 而本地用假上游（429 / 连接被拒）都复现不出来。代理是"整个轮换功能"的单点，
// 宁可这一条请求失败，也不能让进程带着整组模型一起消失。
process.on('uncaughtException', (e) => {
  process.stderr.write(`[rotate] 未捕获异常（进程继续）：${e && e.stack ? e.stack : String(e)}\n`);
});
process.on('unhandledRejection', (r) => {
  process.stderr.write(`[rotate] 未处理的 Promise 拒绝（进程继续）：${r && r.stack ? r.stack : String(r)}\n`);
});

// ─────────────────────────────────────────────────────────── 配置常量

const DEFAULT_PORT = 39321;
/** 上游多久没返回**响应头**就认定这条连接废了（返回头之后不再计时，不影响长流） */
const HEADERS_TIMEOUT_MS = 60_000;
/** 请求体上限（防止把整个内存吃光） */
const MAX_BODY_BYTES = 32 * 1024 * 1024;
/** 失败响应体最多留这么多，用于"全部失败时照原样返回上一次的错误" */
const MAX_KEEP_ERROR_BYTES = 2 * 1024 * 1024;

const HELP = `rotate-proxy.mjs —— 本地「模型轮换」代理（OpenAI 兼容，纯内置模块）

用法:
  node rotate-proxy.mjs --config-stdin [--state <file>] [--port 0] [--log <file>] [--verbose]
  node rotate-proxy.mjs <config.json> [--port 0] [--log <file>] [--verbose]

参数:
  <config.json>    配置文件（见文件头部注释）。**含各厂家真实 Key，只适合调试**：
                   正式路径用 --config-stdin，别让 Key 落盘。
  --config-stdin   从 stdin 读配置 JSON（读完即止）。App 走这条：配置里含 Key，
                   但只经过管道，**不落盘** —— 模型驱动的 shell 就算 cat 目录
                   也拿不到凭据（审计 P0-2）。
  --state <file>   把"每组上次成功的成员下标"（lastGood）持久化到这个文件。
                   stdin 模式下用；这个文件**不含任何凭据**，可以留在盘上。
  --port <n>       监听端口，默认取 config.port，再默认 ${DEFAULT_PORT}。
                   传 **0** 表示让系统挑一个空闲端口（审计 P0-3：别用固定端口）。
  --token <t>      客户端令牌。一般**不要**用这个参数 —— 命令行在
                   /proc/<pid>/cmdline 里同 uid 可读。走配置里的 "token" 字段
                   （配合 --config-stdin，令牌只经过管道）。
  --no-auth        关掉令牌校验。**只给本地调试/单测用**，会重新打开 P0-3 那个洞。
  --log <file>     把日志同时追加到这个文件
  --verbose        把每个请求（路径/组/成员）也记一行日志
  --help           显示本说明

鉴权: 除 --no-auth 外，所有请求都必须带 'Authorization: Bearer <token>'
      （也接受 'x-api-key: <token>'），比对是**等时的**（不按字节提前返回）。
接口: GET /health · GET /v1/models · POST /v1/chat/completions
退出码: 0 正常退出；1 启动/运行失败；2 参数或配置错误；3 没拿到令牌又没加 --no-auth。
`;

// ─────────────────────────────────────────────────────────── 日志

const state = {
  logFile: null,
  statePath: null,
  verbose: false,
  persistWarned: false,
};

/** 一行日志：stderr + 可选的日志文件。stdout 只留给"就绪标记"，方便 Dart 正则识别 */
function logLine(message) {
  const line = `[rotate] ${message}`;
  process.stderr.write(line + '\n');
  if (state.logFile) {
    try {
      appendFileSync(state.logFile, `${new Date().toISOString()} ${line}\n`);
    } catch {
      /* 日志文件写不进去就算了，不能因此影响代理 */
    }
  }
}

function die(message, code) {
  process.stderr.write('错误：' + message + '\n');
  process.exit(code);
}

// ─────────────────────────────────────────────────────────── 配置

function loadConfig(configPath) {
  if (!configPath) die('缺少配置文件名', 2);
  if (!existsSync(configPath)) die(`找不到配置文件：${configPath}`, 2);

  let raw;
  try {
    raw = readFileSync(configPath, 'utf8');
  } catch (e) {
    die(`读不了配置文件（${configPath}）：${e.message}`, 2);
  }
  const cfg = validateConfig(raw, `配置文件（${configPath}）`);
  cfg.path = resolve(configPath);
  // 旧路径：配置文件与 lastGood 状态同在一个文件里（它本来就没有凭据问题）。
  cfg.statePath = cfg.path;
  return cfg;
}

/**
 * 从 stdin 读配置（审计 P0-2 的修法）。
 *
 * 为什么不把 Key 写进 `toolbox/rotate-config.json`：`HOME=filesDir`，而模型驱动的
 * shell 就在同一个 uid 下跑 —— 它 `cat $HOME/toolbox/rotate-config.json` 就能把
 * 各厂家真实 Key 读走，再发到网上。管道读完就没了，`/proc/<pid>/environ` 也看不到它。
 *
 * ⚠️ 同步读 fd 0：会阻塞到 EOF，所以调用方（App）写完必须**关闭 stdin**。
 */
function loadConfigFromStdin() {
  let raw;
  try {
    raw = readFileSync(0, 'utf8');
  } catch (e) {
    die(`读不了 stdin 上的配置：${e.message}`, 2);
  }
  const cfg = validateConfig(raw, 'stdin 配置');
  cfg.path = '<stdin>';
  cfg.statePath = null; // 由 --state 指定；没有就只记内存
  return cfg;
}

/** 校验一份配置文本；返回 {port, groups, lastGood, token}（不含 path）。 */
function validateConfig(raw, label) {
  if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);

  let cfg;
  try {
    cfg = JSON.parse(raw);
  } catch (e) {
    die(`${label} 不是合法 JSON：${e.message}`, 2);
  }
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) die(`${label} 的顶层必须是一个对象`, 2);
  if (!cfg.groups || typeof cfg.groups !== 'object' || Array.isArray(cfg.groups)) {
    die(`${label} 缺少 groups 对象（形如 {"groups":{"cat":{"members":[...]}}}）`, 2);
  }

  const names = Object.keys(cfg.groups);
  if (names.length === 0) die('groups 是空的，至少要有一组', 2);

  const skipped = [];

  for (const name of names) {
    const group = cfg.groups[name];
    if (!group || typeof group !== 'object') die(`组 ${name} 不是对象`, 2);
    if (!Array.isArray(group.members)) die(`组 ${name} 的 members 必须是数组`, 2);
    // ⚠️ 空组**不是配置错误**，而是"这一组此刻没有可用成员"（成员模型被删掉、
    //    本机模型服务没在跑…）。以前这里直接 die → process.exit，于是
    //    **一个空组连坐整份配置**：用户报的「轮换池中间有一个用不了的模型，
    //    整个轮换池都不能用」正是这个形状。现在只跳过这一组，其它组照常服务。
    if (group.members.length === 0) {
      delete cfg.groups[name];
      skipped.push(name);
      continue;
    }
    group.members.forEach((m, i) => {
      if (!m || typeof m !== 'object') die(`组 ${name} 的第 ${i + 1} 个成员不是对象`, 2);
      if (typeof m.baseUrl !== 'string' || !/^https?:\/\//i.test(m.baseUrl)) {
        die(`组 ${name} 的第 ${i + 1} 个成员 baseUrl 必须是 http(s):// 开头的字符串`, 2);
      }
      if (typeof m.model !== 'string' || !m.model.trim()) {
        die(`组 ${name} 的第 ${i + 1} 个成员缺少 model`, 2);
      }
      if (m.apiKey !== undefined && typeof m.apiKey !== 'string') {
        die(`组 ${name} 的第 ${i + 1} 个成员 apiKey 必须是字符串`, 2);
      }
      if (!m.name) m.name = `member${i + 1}`;
    });
  }

  // 空组全部跳过之后，一组都不剩才是真错误 —— 这时没有服务可提供，
  // 报一句能看懂的话，而不是让调用方对着 502 猜。
  if (Object.keys(cfg.groups).length === 0) {
    die(
      `所有轮换组都没有可用成员（已跳过：${skipped.join('、')}）。` +
        '请到「模型 → 轮换组」里补一个成员，或把这一组删掉。',
      2,
    );
  }
  if (skipped.length) {
    logLine(
      `已跳过 ${skipped.length} 个没有可用成员的组：${skipped.join('、')}` +
        '（其它组不受影响）',
    );
  }

  return {
    port: Number.isInteger(cfg.port) ? cfg.port : DEFAULT_PORT,
    groups: cfg.groups,
    lastGood: cfg.lastGood && typeof cfg.lastGood === 'object' && !Array.isArray(cfg.lastGood) ? cfg.lastGood : {},
    token: typeof cfg.token === 'string' ? cfg.token : '',
  };
}

/** 参数解析：<config.json> | --config-stdin，另有 --state/--port/--log/--token/--no-auth/--verbose */
function parseArgs(argv) {
  const out = {
    config: null,
    configStdin: false,
    state: null,
    port: null,
    log: null,
    token: null,
    noAuth: false,
    verbose: false,
  };
  const expanded = [];
  for (const a of argv) {
    const m = /^--(port|log|state|token)=(.*)$/.exec(a);
    if (m) expanded.push(`--${m[1]}`, m[2]);
    else expanded.push(a);
  }
  for (let i = 0; i < expanded.length; i += 1) {
    const a = expanded[i];
    if (a === '--help' || a === '-h') {
      process.stdout.write(HELP);
      process.exit(0);
    } else if (a === '--config-stdin') {
      out.configStdin = true;
    } else if (a === '--no-auth') {
      out.noAuth = true;
    } else if (a === '--state') {
      const v = expanded[++i];
      if (!v) die('--state 需要跟一个文件名', 2);
      out.state = v;
    } else if (a === '--token') {
      const v = expanded[++i];
      if (!v) die('--token 需要跟一个值', 2);
      out.token = v;
    } else if (a === '--port' || a === '-p') {
      const v = expanded[++i];
      const n = Number(v);
      // 0 = 让系统挑端口（P0-3：不要固定端口）。
      if (!Number.isInteger(n) || n < 0 || n > 65535) die(`--port 需要一个 0..65535 的整数（0=自动挑），收到 ${JSON.stringify(v)}`, 2);
      out.port = n;
    } else if (a === '--log' || a === '-l') {
      const v = expanded[++i];
      if (!v) die('--log 需要跟一个文件名', 2);
      out.log = v;
    } else if (a === '--verbose' || a === '-v') {
      out.verbose = true;
    } else if (a.startsWith('-')) {
      die(`不认识的参数：${a}`, 2);
    } else if (out.config === null) {
      out.config = a;
    } else {
      die(`多余的参数：${a}`, 2);
    }
  }
  if (out.configStdin && out.config !== null) die('--config-stdin 与 <config.json> 只能给一个', 2);
  if (!out.configStdin && out.config === null) die('缺少配置：用 <config.json> 或 --config-stdin（用法见 --help）', 2);
  return out;
}

// ─────────────────────────────────────────────────────────── 组/成员解析

/** 把客户端给的 model 解析成组名；宽松匹配 + 退一步按成员真实 model 名匹配 */
function resolveTarget(groups, model) {
  const names = Object.keys(groups);
  if (model === undefined || model === null || String(model).trim() === '') return null;
  const raw = String(model).trim();
  if (groups[raw]) return { group: raw, startIndex: null };

  const lower = raw.toLowerCase();
  for (const n of names) {
    if (n.toLowerCase() === lower) return { group: n, startIndex: null };
  }
  // rotate/cat、cat-v1、openai/cat-2024 → 按"组名包含关系"取最长匹配
  let best = null;
  for (const n of names) {
    const nl = n.toLowerCase();
    if (lower.includes(nl) || nl.includes(lower)) {
      if (!best || nl.length > best.length) best = n;
    }
  }
  if (best) return { group: best, startIndex: null };

  // 退一步：客户端直接写了某个成员的真实 model 名 → 就近落到那个组、那个成员
  for (const n of names) {
    const members = groups[n].members;
    for (let i = 0; i < members.length; i += 1) {
      const m = members[i];
      if (String(m.model).toLowerCase() === lower || (m.name && String(m.name).toLowerCase() === lower)) {
        return { group: n, startIndex: i };
      }
    }
  }
  return null;
}

/** 组成员顺序：粘性成员优先，然后按原顺序轮（跳过已试过的） */
function orderMembers(group, sticky, forceStart) {
  const n = group.members.length;
  const start = Number.isInteger(forceStart) ? forceStart : Number.isInteger(sticky) ? sticky : -1;
  const out = [];
  if (start >= 0 && start < n) {
    out.push({ index: start, member: group.members[start] });
    for (let i = 0; i < n; i += 1) if (i !== start) out.push({ index: i, member: group.members[i] });
  } else {
    for (let i = 0; i < n; i += 1) out.push({ index: i, member: group.members[i] });
  }
  return out;
}

/** baseUrl 可能带 /v1、可能不带、也可能本身就是完整的 /chat/completions */
function buildChatUrl(baseUrl) {
  const base = String(baseUrl).trim().replace(/\/+$/, '');
  if (/\/chat\/completions$/i.test(base)) return base;
  if (/\/v\d+$/i.test(base)) return `${base}/chat/completions`;
  return `${base}/v1/chat/completions`;
}

// ─────────────────────────────────────────────────────────── HTTP 小工具

function sendJson(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  if (res.headersSent) return;
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(body.length),
  });
  res.end(body);
}

function sendError(res, status, message, type) {
  sendJson(res, status, { error: { message, type: type || 'invalid_request_error', code: null } });
}

function readBody(req) {
  return new Promise((resolvePromise, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        reject(Object.assign(new Error('请求体过大'), { code: 'E_TOO_LARGE' }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolvePromise(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/** 透传给上游的请求头：去掉 host/content-length/authorization（这三个我们自己定） */
function upstreamHeaders(clientReq, member, contentLength) {
  const skip = new Set(['host', 'content-length', 'authorization', 'connection', 'transfer-encoding']);
  const out = {};
  for (const [k, v] of Object.entries(clientReq.headers)) {
    if (skip.has(k.toLowerCase())) continue;
    out[k] = v;
  }
  out['content-type'] = out['content-type'] || 'application/json';
  out['content-length'] = String(contentLength);
  if (member.apiKey) out.authorization = `Bearer ${member.apiKey}`;
  return out;
}

/** 回给客户端的响应头：去掉逐跳头与长度（长度我们自己算） */
function dropHopByHop(headers) {
  const out = {};
  for (const [k, v] of Object.entries(headers || {})) {
    const lk = k.toLowerCase();
    if (lk === 'transfer-encoding' || lk === 'connection' || lk === 'content-length') continue;
    out[k] = v;
  }
  return out;
}

// ─────────────────────────────────────────────────────────── 核心：试一个成员

/**
 * 尝试一个成员。
 * 返回：
 *   { outcome: 'done' }                        已经完整响应给客户端（或流已跑完）
 *   { outcome: 'switch', status?, body?, headers?, reason }  可以换下一个
 *   { outcome: 'aborted' }                     客户端自己断开了，别再往下试
 */
function attempt(member, groupName, payload, clientReq, clientRes) {
  return new Promise((settleOnce) => {
    let settled = false;
    let clientStarted = false;
    let clientGone = false;
    let upstream = null;
    let timer = null;

    const cleanup = () => {
      if (timer) {
        clearTimeout(timer);
        timer = null;
      }
      clientRes.removeListener('close', onClientClose);
    };
    const settle = (v) => {
      if (settled) return;
      settled = true;
      cleanup();
      settleOnce(v);
    };
    const onClientClose = () => {
      // writableEnded 为 false 且 close 了 = 客户端提前断开（不是我们正常结束的）
      if (!clientRes.writableEnded) {
        clientGone = true;
        if (upstream) upstream.destroy();
      }
    };
    clientRes.on('close', onClientClose);

    let target;
    try {
      target = new URL(buildChatUrl(member.baseUrl));
    } catch (e) {
      settle({ outcome: 'switch', reason: `baseUrl 不合法(${member.baseUrl})` });
      return;
    }
    if (target.protocol !== 'http:' && target.protocol !== 'https:') {
      settle({ outcome: 'switch', reason: `不支持的协议 ${target.protocol}` });
      return;
    }

    const mod = target.protocol === 'https:' ? https : http;
    const isStream = payload.stream === true;
    const body = Buffer.from(JSON.stringify(payload), 'utf8');
    const headers = upstreamHeaders(clientReq, member, body.length);

    const onResponse = (ur) => {
      if (timer) {
        clearTimeout(timer);
        timer = null;
      }
      const status = ur.statusCode || 0;

      if (status >= 200 && status < 300) {
        if (isStream) {
          // 流式：原样管道。写头这一刻起就不能再换成员了。
          const outHeaders = dropHopByHop(ur.headers);
          outHeaders['content-type'] = 'text/event-stream';
          outHeaders['cache-control'] = 'no-cache';
          outHeaders.connection = 'keep-alive';
          clientStarted = true;
          try {
            clientRes.writeHead(status, outHeaders);
          } catch (e) {
            ur.destroy();
            settle({ outcome: 'aborted' });
            return;
          }
          ur.pipe(clientRes);
          ur.on('end', () => settle({ outcome: 'done' }));
          ur.on('error', (err) => {
            logLine(
              `${groupName}: ${member.name} 流式传输中断(${err.code || err.message})，` +
                '已经向客户端吐过数据 → 无法再切换成员',
            );
            try {
              clientRes.end();
            } catch {
              /* 客户端可能已经走了 */
            }
            settle({ outcome: 'done' });
          });
          return;
        }
        // 非流式：先收全，再一次性回（这时还没写客户端，失败仍可切换）
        const chunks = [];
        let size = 0;
        ur.on('data', (c) => {
          chunks.push(c);
          size += c.length;
        });
        ur.on('end', () => {
          const buf = Buffer.concat(chunks);
          if (clientGone || clientRes.headersSent) {
            settle({ outcome: 'aborted' });
            return;
          }
          const outHeaders = dropHopByHop(ur.headers);
          outHeaders['content-length'] = String(buf.length);
          try {
            clientRes.writeHead(status, outHeaders);
            clientRes.end(buf);
          } catch (e) {
            settle({ outcome: 'aborted' });
            return;
          }
          settle({ outcome: 'done' });
        });
        ur.on('error', (err) => {
          settle({ outcome: 'switch', reason: `${err.code || err.message}（读上游响应体失败，已收 ${size} 字节）` });
        });
        return;
      }

      // 非 2xx：读掉响应体（不然上游连接不会释放），然后交给调用方决定换谁
      const chunks = [];
      let size = 0;
      ur.on('data', (c) => {
        if (size < MAX_KEEP_ERROR_BYTES) chunks.push(c);
        size += c.length;
      });
      ur.on('end', () => {
        settle({
          outcome: 'switch',
          status,
          body: Buffer.concat(chunks),
          headers: dropHopByHop(ur.headers),
          reason: `HTTP ${status}`,
        });
      });
      ur.on('error', (err) => {
        settle({
          outcome: 'switch',
          status,
          body: Buffer.concat(chunks),
          headers: dropHopByHop(ur.headers),
          reason: `HTTP ${status} 且读体失败(${err.code || err.message})`,
        });
      });
    };

    try {
      upstream = mod.request(target, { method: 'POST', headers }, onResponse);
    } catch (e) {
      settle({ outcome: 'switch', reason: `${e.code || e.message}` });
      return;
    }

    upstream.on('error', (err) => {
      if (clientGone) {
        settle({ outcome: 'aborted' });
        return;
      }
      const why = err.code || err.message;
      if (clientStarted) {
        logLine(`${groupName}: ${member.name} 上游连接出错(${why})，已经向客户端吐过数据 → 无法再切换成员`);
        try {
          clientRes.end();
        } catch {
          /* ignore */
        }
        settle({ outcome: 'done' });
        return;
      }
      settle({ outcome: 'switch', reason: why });
    });

    // 只对"等响应头"计时；收到头就清掉，所以不会掐断长流
    timer = setTimeout(() => {
      timer = null;
      if (upstream) upstream.destroy(Object.assign(new Error(`上游 ${HEADERS_TIMEOUT_MS / 1000}s 内没返回响应头`), { code: 'ETIMEDOUT' }));
    }, HEADERS_TIMEOUT_MS);

    upstream.end(body);
  });
}

// ─────────────────────────────────────────────────────────── 粘性：回写 config.json

/**
 * 粘性：记住"每组最近一次成功的成员"，变了才写盘。
 *
 * ⚠️ 落盘的是**状态**（只有下标），**不是配置**。P0-2 之前这里是把整份
 * config.json（含各厂家真实 Key）读出来、改一个字段、再写回去 ——
 * 于是凭据一直躺在 `$HOME/toolbox/` 下，模型驱动的 shell 一条 `cat` 就能读走。
 * 现在只写 `{"lastGood":{...}}`，这份文件**不含任何凭据**，留着也没有风险。
 */
function makeSticky(cfg) {
  const lastGood = {};
  for (const name of Object.keys(cfg.groups)) {
    const v = cfg.lastGood[name];
    if (Number.isInteger(v) && v >= 0 && v < cfg.groups[name].members.length) lastGood[name] = v;
  }
  return {
    get(name) {
      return Object.prototype.hasOwnProperty.call(lastGood, name) ? lastGood[name] : null;
    },
    /** 记住"最近一次成功的成员"，变了才写盘 */
    set(name, index) {
      if (lastGood[name] === index) return;
      lastGood[name] = index;
      if (!cfg.statePath) return; // stdin 模式且没给 --state：只记内存
      try {
        // 合并盘上已有的 lastGood（别的组可能已经写过）。
        const disk = {};
        try {
          const raw = JSON.parse(readFileSync(cfg.statePath, 'utf8'));
          if (raw && typeof raw === 'object' && raw.lastGood && typeof raw.lastGood === 'object') {
            Object.assign(disk, raw.lastGood);
          }
        } catch {
          /* 读不回来就只写内存里的这份 */
        }
        Object.assign(disk, lastGood);
        const tmp = `${cfg.statePath}.tmp`;
        writeFileSync(tmp, JSON.stringify({ lastGood: disk }, null, 2) + '\n', 'utf8');
        renameSync(tmp, cfg.statePath);
      } catch (e) {
        // 写盘失败不影响服务；只提示一次，避免日志刷屏
        if (!state.persistWarned) {
          state.persistWarned = true;
          logLine(`写回 lastGood 状态失败（不影响服务）：${e.message}`);
        }
      }
    },
    snapshot() {
      return { ...lastGood };
    },
  };
}

// ─────────────────────────────────────────────────────────── 请求处理

/**
 * 等时比对（审计 P0-3）。
 *
 * 为什么不能用 `===`：那样一旦前缀对上就继续、对不上就立刻返回，比较耗时随
 * "猜对了几个字节"变化 —— 理论上可以被逐字节爆破。这里用 `timingSafeEqual`
 * 且**先比较长度无关的摘要**，让耗时与输入内容无关。
 *
 * 做法：两边各自算 sha256，再对**定长摘要**做等时比较 —— 这样长度不同也不会
 * 提前返回，也不用担心 `timingSafeEqual` 对不等长输入直接抛异常。
 */
function constantTimeEqual(a, b) {
  const ha = createHash('sha256').update(String(a), 'utf8').digest();
  const hb = createHash('sha256').update(String(b), 'utf8').digest();
  return timingSafeEqual(ha, hb);
}

/** 从请求里取出客户端令牌：优先 Authorization: Bearer，其次 x-api-key。 */
function clientToken(req) {
  const auth = req.headers && req.headers.authorization;
  if (typeof auth === 'string') {
    const m = /^Bearer\s+(.+)$/i.exec(auth.trim());
    if (m) return m[1].trim();
  }
  const xk = req.headers && req.headers['x-api-key'];
  if (typeof xk === 'string') return xk.trim();
  if (Array.isArray(xk) && xk.length) return String(xk[0]).trim();
  return '';
}

function makeHandler(cfg, sticky) {
  return async function handle(req, res) {
    let path = '/';
    try {
      path = new URL(req.url, 'http://127.0.0.1').pathname;
    } catch {
      sendError(res, 400, '请求路径不合法', 'invalid_request_error');
      return;
    }

    // ── 客户端鉴权（审计 P0-3）──────────────────────────────────────────────
    // 这个代理监听 127.0.0.1，而 **loopback 在整机上共享**：同机任何带 INTERNET
    // 权限的应用都能扫到端口并 POST /v1/chat/completions —— 用用户的 Key 花钱。
    // 而同类的本机端点（如曾经的设备通道 device_bridge）早就加了随机令牌，
    // 代理这里一直没有。（设备通道已于 2026-10-10 随「打开应用」功能删除。）
    if (cfg.token) {
      const got = clientToken(req);
      if (!got || !constantTimeEqual(got, cfg.token)) {
        logLine(`拒绝未授权的请求：${req.method} ${path}（客户端令牌不匹配）`);
        // 不回显令牌、也不说"差在哪"，避免变成爆破的反馈信号。
        res.setHeader('www-authenticate', 'Bearer');
        sendError(res, 401, '缺少或错误的客户端令牌', 'invalid_api_key');
        return;
      }
    }

    if (req.method === 'GET' && path === '/health') {
      sendJson(res, 200, { ok: true, groups: Object.keys(cfg.groups) });
      return;
    }

    if (req.method === 'GET' && path === '/v1/models') {
      sendJson(res, 200, {
        object: 'list',
        data: Object.keys(cfg.groups).map((name) => ({ id: name, object: 'model', owned_by: 'rotate' })),
      });
      return;
    }

    if (req.method === 'POST' && path === '/v1/chat/completions') {
      await handleChat(cfg, sticky, req, res);
      return;
    }

    sendError(res, 404, `未知路径：${req.method} ${path}（可用：GET /health、GET /v1/models、POST /v1/chat/completions）`, 'not_found');
  };
}

async function handleChat(cfg, sticky, req, res) {
  let raw;
  try {
    raw = await readBody(req);
  } catch (e) {
    if (e && e.code === 'E_TOO_LARGE') sendError(res, 413, `请求体超过 ${MAX_BODY_BYTES} 字节上限`, 'invalid_request_error');
    else sendError(res, 400, `读请求体失败：${e.message}`, 'invalid_request_error');
    return;
  }

  let payload;
  try {
    payload = JSON.parse(raw.toString('utf8'));
  } catch (e) {
    sendError(res, 400, `请求体不是合法 JSON：${e.message}`, 'invalid_request_error');
    return;
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    sendError(res, 400, '请求体必须是一个 JSON 对象', 'invalid_request_error');
    return;
  }

  const requested = payload.model;
  const target = resolveTarget(cfg.groups, requested);
  if (!target) {
    sendError(
      res,
      404,
      `找不到与 model=${JSON.stringify(requested)} 匹配的组。可用组：${Object.keys(cfg.groups).join('、')}`,
      'model_not_found',
    );
    return;
  }

  const groupName = target.group;
  const group = cfg.groups[groupName];
  const stickyIndex = target.startIndex === null ? sticky.get(groupName) : target.startIndex;
  const order = orderMembers(group, stickyIndex, target.startIndex);
  const isStream = payload.stream === true;

  if (state.verbose) {
    logLine(`→ ${groupName}: model=${JSON.stringify(requested)} stream=${isStream} 起始成员=${order[0].member.name}${stickyIndex !== null ? '(粘性)' : ''}`);
  }

  const failures = [];
  let last = null;

  for (let i = 0; i < order.length; i += 1) {
    const { index, member } = order[i];
    const next = order[i + 1] || null;

    // 每个成员试着用**它自己的**模型名，其它字段原样透传
    const outbound = { ...payload, model: member.model };
    const r = await attempt(member, groupName, outbound, req, res);

    if (r.outcome === 'aborted') {
      if (state.verbose) logLine(`${groupName}: 客户端已断开，停止尝试`);
      return;
    }
    if (r.outcome === 'done') {
      sticky.set(groupName, index);
      if (i > 0) logLine(`${groupName}: ${member.name} 成功（第 ${i + 1} 个成员顶上）`);
      else if (state.verbose) logLine(`${groupName}: ${member.name} 成功`);
      return;
    }

    // outcome === 'switch'
    const why = r.status ? String(r.status) : r.reason || '连接失败';
    failures.push(`${member.name}(${why})`);
    last = r;
    if (next) logLine(`${groupName}: ${member.name} 失败(${why})，改用 ${next.member.name}`);
    else logLine(`${groupName}: ${member.name} 失败(${why})，没有更多成员可用`);
  }

  // 全部失败：原样返回最后一次的上游状态码与响应体；连响应体都没有（连接错误）就 502
  if (res.headersSent || res.writableEnded) return;
  if (last && last.status && last.body) {
    const headers = { ...(last.headers || {}) };
    headers['content-length'] = String(last.body.length);
    try {
      res.writeHead(last.status, headers);
      res.end(last.body);
    } catch {
      /* 客户端可能已经走了 */
    }
    return;
  }
  sendError(res, 502, `所有成员都失败了：${failures.join('、')}（组 ${groupName}）`, 'proxy_error');
}

// ─────────────────────────────────────────────────────────── 启动

function main() {
  const cli = parseArgs(process.argv.slice(2));
  const cfg = cli.configStdin ? loadConfigFromStdin() : loadConfig(cli.config);

  // 状态文件：stdin 模式下只有它落盘，而且**不含凭据**。
  if (cli.state) cfg.statePath = cli.state;
  if (cfg.statePath) state.statePath = cfg.statePath;

  // 令牌：配置里的优先（只经过管道），--token 只作兜底（会在 cmdline 里露出来）。
  if (!cfg.token && cli.token) cfg.token = cli.token;
  if (cli.noAuth) {
    cfg.token = '';
    logLine('⚠️ --no-auth：客户端鉴权已关闭（只该用于本地调试）');
  } else if (!cfg.token) {
    // 失败安全：不给令牌又没显式关鉴权 = 拒绝启动，而不是"那就裸奔"。
    // 否则一旦 Dart 侧忘了传，就会**静默**回到"谁都能用用户的 Key"。
    die(
      '没有客户端令牌：请在配置里给 "token"，或用 --token 传，或显式 --no-auth（仅调试）。\n' +
        '  （这个代理监听 loopback，同机任何应用都能访问；没有令牌就是用你的 Key 给别人花钱）',
      3,
    );
  }

  const port = cli.port === null ? cfg.port : cli.port;
  if (!Number.isInteger(port) || port < 0 || port > 65535) die(`端口不合法：${port}`, 2);

  state.logFile = cli.log ? resolve(cli.log) : null;
  state.verbose = cli.verbose;

  const sticky = makeSticky(cfg);
  const sockets = new Set();
  const server = http.createServer(makeHandler(cfg, sticky));

  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });

  server.on('error', (err) => {
    if (err && err.code === 'EADDRINUSE') {
      die(
        `端口 ${port} 已被占用，无法启动。请先结束占用该端口的进程，` +
          '或用 --port 0 让系统自己挑一个空闲端口。',
        1,
      );
    }
    die(`HTTP 服务启动失败：${err && err.message ? err.message : err}`, 1);
  });

  server.listen(port, '127.0.0.1', () => {
    const addr = server.address();
    const actualPort = addr && typeof addr === 'object' ? addr.port : port;
    const names = Object.keys(cfg.groups);
    logLine(
      `配置：${cfg.path} | 组=${names.map((n) => `${n}(${cfg.groups[n].members.length} 个成员)`).join(', ')} | ` +
        `lastGood=${JSON.stringify(sticky.snapshot())} | 鉴权=${cfg.token ? '开' : '关'}` +
        ` | 状态文件=${cfg.statePath || '(仅内存)'}${state.logFile ? ` | 日志文件=${state.logFile}` : ''}`,
    );
    // ⚠ 这一行是 Dart 侧识别"就绪"的标记，格式不要改
    process.stdout.write(`[rotate-proxy] listening on http://127.0.0.1:${actualPort} groups=${names.join(',')}\n`);
  });

  let shuttingDown = false;
  const shutdown = (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    logLine(`收到 ${signal}，正在优雅关闭…`);
    server.close(() => {
      logLine('已关闭');
      process.exit(0);
    });
    for (const s of sockets) {
      try {
        s.destroy();
      } catch {
        /* ignore */
      }
    }
    // 兜底：某些连接卡住时 1.5s 后强制退出
    setTimeout(() => process.exit(0), 1500).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

export {
  buildChatUrl,
  resolveTarget,
  orderMembers,
  loadConfig,
  loadConfigFromStdin,
  validateConfig,
  constantTimeEqual,
  clientToken,
  makeHandler,
  makeSticky,
  parseArgs as parseArgsForTest,
  main,
};

// 只有被直接 `node rotate-proxy.mjs` 调用时才启动（被 import 时不自动跑，方便单测）
//
// ⚠️ 兜底那一分支是真机上踩出来的：App 用 `Process.start` 直接 spawn 本脚本时
// （不是经过 sh 的 bash 工具），URL 相等有时对不上 —— 表现是 node **启动、什么都不
// 打印、exit 0**（main 没跑，事件循环空转后正常退出），看起来像"代理起不来但没报错"，
// 极难排查。所以再加一条按文件名认的兜底判断。
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

if (isDirectRun) main();

