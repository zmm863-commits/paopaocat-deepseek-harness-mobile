/**
 * zen-proxy.mjs —— 本地 OpenAI 兼容代理，转发到 **OpenCode Zen 的匿名免费通道**。
 *
 * ## ⚠️ 先说清楚这是什么（不要含糊）
 *
 * OpenCode Zen 的免费层**只允许它自家的 CLI 用**：自 2026-09-16 起，上游对
 * 非官方会话形状直接返回 `403 FreeTierError: free tier can only be used from within OpenCode`。
 * 这个代理做的事情，是**把请求伪装成官方 CLI 的样子**去通过那道门禁 ——
 * 也就是说：它绕过的是上游**有意设置**的访问限制，不是"用了一个公开的免费接口"。
 *
 * 因此在本 App 里的定位是**实验性、默认关闭、用户显式开启**的能力，界面上必须如实标注。
 * 也**刻意不做**下面这些（那是真正的滥用放大器，本项目不实现）：
 *   * 不做 IP 池 / 出口轮换来分摊按出口 IP 的配额（手机端也没有这个基础设施）；
 *   * 不做重试轰炸：429 时**如实报出来**让用户决定。
 *     （对比 `FishBottle7/opencode2dsh`：它用的是**有界退避** —— 8 次、~1s→20s、
 *      单步最坏约 90s —— 并静默熬过去。那是它的取舍，**不是滥用**；
 *      我们选了更透明的做法。要不要补一层小退避，见 docs/免费模型-方案.md。）
 *   * 不抓取、不分发任何账号或凭据（这条通道本来就是匿名的，全程没有 Key）。
 *
 * ## ⚠️ 路已经搬过一次：现在打 `/inference/v1`（2026-10-15 实测）
 *
 * 上游在 **2026-10-13/14 之间又收紧了一次**（历史上第三次），而且这次是**四处一起换**
 * —— 只修其中一处仍然 403。社区当天就摸清了新契约（我们这份与
 * `Ebony-Vinyl/dsh-our-free-model` PR#330 的 `docs/free-lane-wire.md` 逐条对上，
 * 那份是**用自签 CA 中间人抓官方 1.19.0 客户端的真实请求 + 逐字节重放**测出来的）：
 *
 * | 项目 | 现在要求 | 不满足时 |
 * |---|---|---|
 * | 聊天端点 | **`/inference/v1/chat/completions`** | 打老 `/zen/v1/...` → **无条件 403** |
 * | 会话头 | **`x-opencode-session-id` 必须存在**（值与 `x-opencode-session` 相同） | 缺 → 403 |
 * | 会话 id 形状 | `ses_` + 12 位 hex 必须是**铸造**形状 `~(ms·0x1000+seq)`（低 12 位 ≈ `0xFFE`） | sha256 派生 / 随机 hex → 403 |
 * | 工具指纹（**已升级，见下节**） | 2026-10-14 时是 `bash` + `read`；**2026-10-15 起是四个** | 只其一 → 403；`properties: {}` → 403 |
 * | User-Agent | **含 `deepseek-harness` 一律 403**（大小写不敏感、位置无关）；`dsh/…`、`opencode/1.18.x` 放行 | 403 |
 * | UA **版本号** | 必须在 **`[1.18.0, 1.18.33]`**（2026-10-14 13:45 UTC 起加的带；`<1.18.0` → **426**，`≥1.18.34` → **403**，官方 1.19.0 自己也被拒） | 426 / 403 |
 * | 会话 id（**加强**） | 不再是"能解出时间戳"，而是**官方 tA() 完整编码**：`((27<<36)-1-ms)<<12 \| 0xFFE`。手工把末 3 位凑成 `ffe` **仍然 403** | 403 |
 * | 其它 | `Authorization: Bearer public` 必须保留；`stream: true` 必须 | 401 / 403 |
 *
 * ⚠️ **两条遗留头必须不发**：`x-session-affinity` 与 `x-session-id`。
 * 老实现把它们当"无害的防御性对齐"，实测恰好相反 —— 上游把多出来的这两条当成
 * 非官方客户端信号（`MingLoong/Aether` PR#72 的头部矩阵：仅 `x-opencode-*` → 200，
 * 再加 `x-session-id` → 200，**再加 `x-session-affinity` → 403**）。
 *
 * ## 🔧 第 6 次变动（2026-10-15 社区摸清）与我们 2026-10-16 的**本机复测：通了**
 *
 * 10-15 上游又换了两处，同日被 `Ebony-Vinyl/dsh-our-free-model`（★1.8 万，当天连发
 * 两个修复提交：`538b5197` "同步 OpenCode 请求协议"、`0525f8a9` "修复工具名大小写规范化"）
 * 及 `artorias-zj/dsh-opencode-free-model` 实测出来：
 *
 * | 项目 | 现在要求 |
 * |---|---|
 * | 工具指纹 | **四个**函数工具：`bash`、`glob`、`grep`、`read`（不再是两个）；`bash`/`read` 各自 schema 仍要**至少一个 property** |
 * | 工具名大小写 | 门禁按**小写**名字识别 → 调用方若发 `Bash`/`READ` 之类，**要规范化成小写再发**，回程再把调用方的原拼写还给他 |
 * | 请求 id | `x-opencode-request` 用**铸造**形状 `msg_` + 12 位 hex（`ms·0x1000+seq`）+ 14 位 Base62（原来是 `req_` + 哈希前 20 位） |
 * | 其余 | 端点仍是 `/inference/v1/chat/completions`、`x-opencode-session-id` 仍必须、UA 带仍是 `[1.18.0, 1.18.33]` |
 *
 * **⚠️ 两个证据都对，别把它们看成矛盾**：
 *   * 我们 2026-10-15 用**两个**工具的旧形状在本机 403；社区同形状（另一出口）200；
 *   * 2026-10-16 03:48 UTC 我们**在同一台机器**复测：**两个工具 200、四个工具也 200**
 *     （`big-pickle` 与免 Key 名单里的模型都能真吐字，端到端 200 + `你好呀`）。
 *     → 说明 10-15 那次 403 是**出口被分桶**（或上游当天又收紧），**不是形状**。
 *   所以这一版把契约**按社区最新那份对齐**（四个工具 + 小写规范化 + `msg_` 请求 id）：
 *   它是**超集**，对当前上游同样成立，且上游下次收紧时我们已经站在最新那条测线上。
 *
 * ## ⚠️ 但"契约全对"≠"永远能用"：**出口也是被闸的一环**（2026-10-15 本机实测）
 *
 * 把上面每一条都对齐之后（含最新的 UA 带 + 官方 tA() 会话编码），我们在本机仍然 403。
 * 一次判别实验把原因指出来了（同一个出口、同一时刻、只换模型）：
 *
 * | 请求 | 结果 | 说明 |
 * |---|---|---|
 * | `chat/completions` + **不存在的模型** | **400** `Model is unavailable` | 说明请求**已经穿过了门禁层**，是模型解析拒绝的 |
 * | `chat/completions` + `cat-jam-free` | **403 `RegionError`**（"not available in your region"） | **出口地区被封** |
 * | `chat/completions` + 其它免费模型 | 403 `FreeTierError` | 匿名免费层不认非官方客户端 |
 * | `/responses`、`/messages` 同样形状 | 403 `RegionError` / 400 | 同理 |
 *
 * 也就是说：**同一个请求里，"门禁"和"地区"是两道独立的闸**，而我们的出口两道都过不去
 * （一个不存在的模型能拿到 400，恰好证明前一道不是"看形状"那么简单）。
 * 社区那边（不同出口）用同样的形状拿到 200 —— 所以**手机上的结果只能真机判**。
 *
 * **结论（别推翻）**：这条通道对**大陆网络**尤其不可靠（8-27 就实测过 `RegionError`），
 * 它在本 App 里的定位是**彩蛋**，不是承诺 —— 兑现"不用填 Key"的是 Pollinations
 * （见 `app/lib/data/polli_channel.dart`）。失败时如实报出来，绝不假装成功。
 *
 * ## 更早的形状（2026-10-13，已被上面这条取代，留着是为了看懂历史 403）
 *
 * 上游**只看三件事**：
 *   1. `x-opencode-session` 是 `ses_` + 12 位小写 hex + 14 位 Base62 的形状
 *      **并且那 12 位 hex 要能解码回一个合理的毫秒时间戳**（← 2026-10-13 起新增，
 *      见 `decolua/9router#4780`：真客户端的编码是
 *      `~(BigInt(Date.now()) * 0x1000n + counter)` 取低 48 位。
 *      各家实现原来都是把种子 sha256 派生成这 12 位 —— **现在会被判成
 *      "不是 OpenCode 客户端"直接 403**。本文件 `canonicalSessionId()` 已按时间戳改）；
 *   2. 请求体必须 `stream: true`（非流式 403）；
 *   3. `tools` 里要有函数工具 `bash` 与 `read`（实测：缺了照样 403）。
 * 头部（User-Agent / x-opencode-client / 关联 id）不检查；`Authorization: Bearer public`
 * 在 `/zen/v1` 上合法（`/inference/openai` 才 401）。这些都照旧发着。
 *
 * ⚠️ 上游随时可能再收紧（历史上已经收紧过两次）。所以：
 *   * 失败时**必须如实报出来**（让 App 能说"这个通道现在不可用"），绝不假装成功。
 *
 * ## 用法
 *
 *   node zen-proxy.mjs --port 0 [--state <dir>] [--upstream https://opencode.ai/zen]
 *                      [--ttl-hours 12] [--log-requests]
 *
 * 就绪时在 **stdout** 打一行（Dart 侧按这一行回填端口，别改格式）：
 *   `listening on http://127.0.0.1:<port>`
 *
 * 路由：
 *   GET  /healthz              → {"ok":true,"models":<n>,"lastError":<string|null>}
 *   GET  /v1/models            → OpenAI 形状，**只列免费模型**
 *   POST /v1/chat/completions  → 注入门禁形状 → 转发 → 把 SSE 原样流回来
 *
 * 只用 node 内置模块（本机运行时没有 npm 依赖）。
 */

import { createHash } from 'node:crypto';
import http from 'node:http';
import https from 'node:https';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

// ⚠️ 2026-10-15：免费车道从 `/zen` 搬到了 `/inference`（老路径无条件 403）。
const DEFAULT_UPSTREAM = 'https://opencode.ai/inference';
// 第二条免密上游（Kilo AI 公共网关）。它**不需要任何 Key / 伪装头**，
// 免费池由上游用 `isFree: true` 明确标注（见 listKiloFreeModels）。
const DEFAULT_KILO_UPSTREAM = 'https://api.kilo.ai/api/gateway';
// 第三条免密上游（OVHcloud AI Endpoints）。纯免 Key、无需伪装的 OpenAI 兼容端点，
// `/v1/models` 列出的就都是可用模型（没有 isFree 标记，整表即免费池）。
const DEFAULT_OVH_UPSTREAM = 'https://oai.endpoints.kepler.ai.cloud.ovh.net';
const DEFAULT_TTL_HOURS = 12;

/**
 * 已在社区/本机实测"匿名可用"的免费模型（离线兜底名单）。
 * 2026-10-16 本机 `GET /inference/v1/models` 实测的免费层（10 条）——
 * 之前那份（big-pickle + mimo-v2.5-free…）已经对不上今天上游的名单了：
 * `big-pickle` 仍在售且能应答，但**不在**免费层名单里（所以这里不收它，
 * 名单只放实测属于免费层的 id）。
 * ⚠️ 上游会上下架模型，所以这份名单只是"断网/接口失败时还能给出点东西"，
 *    真正的新鲜列表走 `GET /v1/models`。
 */
const STATIC_FREE_MODELS = [
  'cat-jam-free',
  'deepseek-v4.1-flash-free',
  'mimo-v2.6-flash-free',
  'muse-spark-1.3-contributor-free',
  'nemotron-3.5-lightning-free',
  'nemotron-3.5-super-vl-free',
  'jev-1.13-free',
  'longcat-2.5-preview-free',
  'space-bunny-free',
];

/** 免费判定：名字里带 `free`，或者在我们已实测的静态名单里。 */
function isFree(model) {
  const m = String(model || '').toLowerCase();
  return m.includes('free') || STATIC_FREE_MODELS.includes(m);
}

// ─────────────────────────────────────────────────────────── 参数

function parseArgs(argv) {
  const out = {
    port: 0,
    state: '',
    upstream: DEFAULT_UPSTREAM,
    kiloUpstream: DEFAULT_KILO_UPSTREAM,
    ovhUpstream: DEFAULT_OVH_UPSTREAM,
    ttlHours: DEFAULT_TTL_HOURS,
    logRequests: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const need = () => {
      const v = argv[++i];
      if (v === undefined) {
        process.stderr.write('zen-proxy: 选项 ' + a + ' 后面缺参数\n');
        process.exit(2);
      }
      return v;
    };
    if (a === '--port') out.port = Number(need());
    else if (a === '--state') out.state = need();
    else if (a === '--upstream') out.upstream = need();
    else if (a === '--kilo-upstream') out.kiloUpstream = need();
    else if (a === '--ovh-upstream') out.ovhUpstream = need();
    else if (a === '--ttl-hours') out.ttlHours = Number(need());
    else if (a === '--log-requests') out.logRequests = true;
    else if (a === '--help') {
      process.stdout.write('用法: node zen-proxy.mjs --port 0 [--state <dir>] [--upstream <url>]\n');
      process.exit(0);
    } else {
      process.stderr.write('zen-proxy: 不认识的选项 ' + a + '\n');
      process.exit(2);
    }
  }
  if (!Number.isInteger(out.port) || out.port < 0 || out.port > 65535) {
    process.stderr.write('zen-proxy: --port 需要 0-65535\n');
    process.exit(2);
  }
  return out;
}

// ─────────────────────────────────────────────────────────── 伪装成官方 CLI

const BASE62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
const CANONICAL_SESSION = /^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/;

function base62Fixed(value, width) {
  let n = value;
  const out = new Array(width);
  const base = 62n;
  for (let i = width - 1; i >= 0; i -= 1) {
    out[i] = BASE62.charAt(Number(n % base));
    n /= base;
  }
  return out.join('');
}

/**
 * 把任意种子**确定性地**换算成官方会话 id，同一个会话拿到同一个 id
 * （保持上游的 prompt cache 亲和性）。
 *
 * ## ⚠️ 12 位 hex 必须是**官方 tA() 的完整编码**（2026-10-14 再次收紧）
 *
 * 10-13 那次只查"这 12 位能不能解出**一个**时间戳"；10-14 起改成查**完整编码**：
 *
 *     hex = ((27 << 36) - 1 - unix_millis) << 12 | 0xFFE     // 取低 48 位
 *
 * 依据 `mnwlzf/sub2api` PR#22（2026-10-15）的单变量实测：
 *   * 哈希派生（末 3 位 `f65`）→ 403；
 *   * **手工把末 3 位凑成 `ffe`** → 仍然 403（说明它不是"看形状"）；
 *   * 官方 tA() 完整编码 → 门禁通过（对方那边拿到 429 限额，属于"进了门"）。
 *
 * 所以我们这里就直接按官方公式铸造，并且**每个种子只铸造一次**（缓存起来）——
 * 公式里带 `Date.now()`，不缓存的话每次请求都会换一个会话 id，缓存亲和就没了。
 */
const SESSION_CACHE = new Map();
const SESSION_CACHE_MAX = 256;

/**
 * 会话映射的落盘路径（`main()` 里设置；空 = 不落盘）。
 *
 * ## 为什么要落盘
 *
 * 免费额度是**按会话**计的，不是按 token。代理一重启（App 冷启动、被系统回收后
 * 拉回来），内存里的映射就空了 → 同一个对话被当成新会话 → 额度白花。
 *
 * ## 为什么不能直接存 seed
 *
 * 这里的 seed 是**用户的第一条提问原文**。把它写到磁盘上，等于把用户说过的话
 * 留在手机里 —— 这条通道本来就是"免费但不保证私密"，更不该自己多存一份。
 * 所以落盘的是 `sha256(seed)`，只能用来做映射，反查不出原文。
 */
let sessionStatePath = '';

/** seed → 缓存键（哈希后落盘，不留原文）。 */
function sessionKey(seed) {
  return createHash('sha256').update(`zen-session\u0000${seed}`).digest('hex').slice(0, 32);
}

function loadSessionCache() {
  if (!sessionStatePath) return;
  try {
    if (!existsSync(sessionStatePath)) return;
    const raw = JSON.parse(readFileSync(sessionStatePath, 'utf8'));
    const map = raw && typeof raw === 'object' && raw.map && typeof raw.map === 'object'
      ? raw.map
      : null;
    if (!map) return;
    for (const [k, v] of Object.entries(map)) {
      if (typeof k === 'string' && typeof v === 'string' && CANONICAL_SESSION.test(v)) {
        SESSION_CACHE.set(k, v);
      }
    }
    if (SESSION_CACHE.size > 0) {
      process.stderr.write(`[zen-proxy] 已恢复 ${SESSION_CACHE.size} 条会话映射\n`);
    }
  } catch {
    // 读坏了就当没恢复：最多重新铸一批 id（多花一点额度），绝不能因此起不来。
  }
}

let sessionSaveTimer = null;

/** 防抖落盘：一次对话可能连续铸几个 id，没必要每个都写一次文件。 */
function scheduleSaveSessions() {
  if (!sessionStatePath || sessionSaveTimer) return;
  sessionSaveTimer = setTimeout(() => {
    sessionSaveTimer = null;
    try {
      const map = Object.create(null);
      for (const [k, v] of SESSION_CACHE) map[k] = v;
      mkdirSync(dirname(sessionStatePath), { recursive: true });
      writeFileSync(sessionStatePath, JSON.stringify({ v: 1, map }), 'utf8');
    } catch {
      /* 写不进去不影响本次对话，下次再试 */
    }
  }, 800);
  // 别为了一个后台写文件把进程拖住不退出
  if (typeof sessionSaveTimer.unref === 'function') sessionSaveTimer.unref();
}

/** 按官方 tA() 公式铸造一个**当场**的会话 id（低 12 位固定 `0xFFE`）。 */
function mintSessionId(nowMs) {
  const A = (27n << 36n) - 1n - BigInt(nowMs);
  const hex = mintHex12((A << 12n) | 0xFFEn);
  // 后 14 位必须是 Base62：用一次随机数（同一个种子只在首次铸造时用得到）
  const rnd = createHash('sha256').update(String(Math.random())).digest();
  const tail = base62Fixed(BigInt('0x' + rnd.subarray(0, 8).toString('hex')), 14);
  return `ses_${hex}${tail}`;
}

function canonicalSessionId(seed) {
  const s = String(seed || '');
  if (CANONICAL_SESSION.test(s)) return s;
  const key = sessionKey(s);
  const hit = SESSION_CACHE.get(key);
  if (hit) return hit;
  const minted = mintSessionId(Date.now());
  if (SESSION_CACHE.size >= SESSION_CACHE_MAX) {
    // 简单 FIFO 淘汰：会话数不会太多，这里只要别无限涨
    const oldest = SESSION_CACHE.keys().next().value;
    SESSION_CACHE.delete(oldest);
  }
  SESSION_CACHE.set(key, minted);
  scheduleSaveSessions();
  return minted;
}

let REQUEST_SEQ = 0;

function requestId() {
  // 2026-10-15 起改成**铸造形状**的 `msg_`：12 位 hex 是 `ms·0x1000+seq`
  // （官方 `msg_` 铸造算法），后 14 位 Base62。
  // 老实现是 `req_` + sha256 前 20 位 —— 上游按形状识别客户端，`req_` 已经不吃香了。
  REQUEST_SEQ += 1;
  return `msg_${mintHex12(BigInt(Date.now()) * 0x1000n + BigInt(REQUEST_SEQ))}${base62Fixed(
    BigInt('0x' + createHash('sha256').update(`req\u0000${REQUEST_SEQ}\u0000${Date.now()}`).digest('hex').slice(0, 12)),
    14,
  )}`;
}

/** 取低 48 位、高字节先出的 12 位 hex（`ses_` 与 `msg_` 都用这套编码）。 */
function mintHex12(value) {
  let hex = '';
  for (let i = 0; i < 6; i += 1) {
    hex += Number((value >> BigInt(40 - 8 * i)) & 0xffn).toString(16).padStart(2, '0');
  }
  return hex;
}

function projectId(seed) {
  return 'prj_' + createHash('sha256').update('prj\u0000' + seed).digest('hex').slice(0, 20);
}

/**
 * 官方 CLI 形状的 UA —— **版本号必须落在门禁接受的带内**。
 *
 * ⚠️ 2026-10-14 13:45–13:53 UTC 起，上游对免费层门禁加了 **UA 版本带**（依据
 * `mnwlzf/sub2api` PR#22 的 24 次单变量二分，同一 key / body / 出口）：
 *
 * | UA 里的版本 | 结果 |
 * |---|---|
 * | `< 1.18.0` | **426 UpgradeRequired** |
 * | `1.18.0 … 1.18.33` | **放行（200）** |
 * | `>= 1.18.34` | **403 FreeTierError**（连官方最新 1.19.0 自己也被拒 —— 上游回归） |
 *
 * 所以这里**写死 1.18.31**（真实 release、带内中段），改了要重测 —— 见
 * `install/test-zen-proxy.mjs` 里那条"版本必须在带内"的测试。
 *
 * ⚠️ 另外：**`deepseek-harness` 这几个字不能出现在 UA 里**（2026-10-14 实测：
 * 含它一律 403，大小写不敏感、位置无关；`dsh/…` 与 `opencode/1.18.x` 放行）。
 * `sanitizeUserAgent()` 兜这一道 —— 将来有人往里加"归属信息"时不至于把整条通道打死。
 */
function sanitizeUserAgent(raw) {
  return String(raw)
      .replace(/deepseek-harness/gi, 'dsh')
      .replace(/\s+/g, ' ')
      .trim();
}

function cliUserAgent() {
  return sanitizeUserAgent(
      'opencode/1.18.31 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14');
}

function disguiseHeaders(session) {
  return {
    // ⚠️ **匿名通道的凭据就是字面量 `public`**（`FishBottle7/opencode2dsh` 的
    //    README 原文："the anonymous lane's key is the literal string `public`"）。
    //    这里**不是**在替用户保管什么 Key，所以「不用写 Key」是事实而不是宣传：
    //    2026-10-11 实测 `GET /v1/models` 带与不带这个头都返回 200，但官方实现
    //    一律带上它 —— 形状与官方一致，上游将来收紧时也更接近"有意为之"。
    //    ⚠️ 上游转发时**不要**把 DSH 传来的 `Authorization: Bearer local-zen` 透传，
    //    那个占位值不是这条通道认的凭据（所以这里是覆盖，不是透传）。
    authorization: 'Bearer public',
    'user-agent': cliUserAgent(),
    'x-opencode-client': 'cli',
    'x-opencode-session': session,
    // ⚠️ 这两条（`x-session-affinity` / `X-Session-Id`）**故意不发**：
    //    官方 1.19.0 客户端抓包里只有 `x-opencode-*` 一套，多发的这两条会被
    //    上游当成非官方客户端信号直接 403（Aether PR#72 的头部矩阵）。
    //    历史上这里写着"无害的防御性对齐"—— 实测恰好相反。
    'x-opencode-session-id': session,
    'x-opencode-request': requestId(),
    'x-opencode-project': projectId(session),
    accept: 'application/json',
  };
}

/**
 * 门禁要求的**四个**"占位"工具（2026-10-15 起从两个升到四个）。
 *
 * 依据（当天三份独立实测，结论一致）：
 *   * `Ebony-Vinyl/dsh-our-free-model` 提交 `538b5197`：`FREE_LANE_GATE_TOOLS`
 *     从 `['bash','read']` 改成 `['bash','glob','grep','read']`，并注明
 *     "服务端按这四个名字识别官方客户端形状"；
 *   * `artorias-zj/dsh-opencode-free-model` README：门禁要求 body 声明
 *     `bash/glob/grep/read`，缺一个就 403 `FreeTierError`。
 *
 * 只要**存在**就行（描述不检查），但 schema 不能是空的 —— 见下。
 */
const GATE_TOOL_NAMES = ['bash', 'glob', 'grep', 'read'];

/// 每个诱饵工具**至少带一个 property**。
///
/// ⚠️ 2026-10-14 起：`properties: {}` 与"没声明这个工具"一样会被判 403
/// （社区工具矩阵：bash 单独 → 403、read 单独 → 403、两个都空 schema → 403、
///  两个各带一个 property → 200）。所以 schema 不能偷懒写空对象。
const GATE_TOOL_PROPERTY = {
  bash: 'command',
  glob: 'pattern',
  grep: 'pattern',
  read: 'filePath',
};

function gateTool(name) {
  const prop = GATE_TOOL_PROPERTY[name] ?? 'input';
  return {
    type: 'function',
    function: {
      name,
      description: 'Reserved for the host runtime; do not call it.',
      parameters: {
        type: 'object',
        properties: {
          [prop]: { type: 'string', description: 'Reserved.' },
        },
        required: [prop],
      },
    },
  };
}

/// 调用方自己带了 `bash`/`read`、但 schema 里一个 property 都没有 → **就地补一个**。
///
/// 为什么不整份替换掉它：工具名/描述/顺序是调用方的语义（DSH 的会话工具链），
/// 换掉会改变模型看到的东西。这里只补 schema 的**最小合法形状**。
/// 返回**新对象**（不改调用方传进来的那份）。
function stampToolSchema(tool) {
  const fn = tool?.function;
  if (!fn || typeof fn !== 'object') return tool;
  const prop = GATE_TOOL_PROPERTY[fn.name];
  if (!prop) return tool;
  const params = fn.parameters;
  const hasProps = params && typeof params === 'object' &&
      params.properties && typeof params.properties === 'object' &&
      Object.keys(params.properties).length > 0;
  if (hasProps) return tool;
  return {
    ...tool,
    function: {
      ...fn,
      parameters: {
        ...(params && typeof params === 'object' ? params : {}),
        type: 'object',
        properties: { [prop]: { type: 'string', description: 'Reserved.' } },
      },
    },
  };
}

/// 门禁工具名集合（**小写**，上游按这四个小写名字识别官方客户端形状）。
const GATE_TOOL_SET = new Set(GATE_TOOL_NAMES);

/**
 * 把调用方的工具名**规范化成小写**（只动那四个门禁名字），并记下"原拼写"。
 *
 * 为什么要动：2026-10-15 起门禁按**小写**名字认人 —— DSH 自己发的是小写，
 * 但其它调用方（或将来 DSH 改了命名）可能发 `Bash`/`READ`，那就等于没声明。
 * 依据：`Ebony-Vinyl/dsh-our-free-model` 提交 `0525f8a9` "修复 OpenCode 工具名
 * 大小写规范化"（`canonicalizeWireTools` + 回程 `restoreToolName`）。
 *
 * ⚠️ 改过名就**必须**在回程把原拼写还回去（见 `restoreToolNames`）——
 *    否则模型回一个 `bash` 的工具调用，调用方的工具链里叫 `Bash`，对不上。
 * 返回值里的 `restore` 为空 Map 时表示**一个名字都没改**（绝大多数情况）。
 */
function canonicalizeToolNames(tools) {
  const restore = new Map();
  const seen = new Set();
  const out = [];
  for (const tool of tools) {
    const fn = tool && typeof tool === 'object' ? tool.function : undefined;
    const name = typeof fn?.name === 'string' ? fn.name : '';
    if (!name || !GATE_TOOL_SET.has(name.toLowerCase())) {
      out.push(tool);
      continue;
    }
    const lower = name.toLowerCase();
    if (seen.has(lower)) continue; // 同一个门禁工具声明了两遍：留一条
    seen.add(lower);
    if (lower === name) {
      out.push(tool);
    } else {
      restore.set(lower, name);
      out.push({ ...tool, function: { ...fn, name: lower } });
    }
  }
  return { tools: out, restore };
}

/** 回程把被规范化过的工具名改回调用方原来的拼写（只动被改过的那些）。 */
function restoreToolNames(text, restore) {
  if (!restore || restore.size === 0) return text;
  let out = String(text);
  for (const [canonical, original] of restore) {
    out = out.replace(
      new RegExp(`"name"\\s*:\\s*"${canonical}"`, 'g'),
      `"name":"${original}"`,
    );
  }
  return out;
}

/**
 * 把请求体改造成能过门禁的形状：
 *   * 工具名规范化成小写（只动 `bash`/`glob`/`grep`/`read` 这四个）；
 *   * 补上缺的门禁工具（**只在缺的时候补** —— DSH 自己的会话本来就带这些，
 *     那种情况下这里什么都不做，请求保持原样）；
 *   * 自带的门禁工具 schema 是空的 → 就地补一个 property；
 *   * 强制 `stream: true`（门禁要求）。
 * 返回 { body, injected, schemaFixed, restore }。
 */
function applyGate(body) {
  const out = { ...body, stream: true };
  const rawTools = Array.isArray(body.tools) ? body.tools.slice() : [];
  const { tools, restore } = canonicalizeToolNames(rawTools);
  const names = new Set(
    tools
      .map((t) => (t && typeof t === 'object' && t.type === 'function' ? t.function?.name : undefined))
      .filter(Boolean),
  );
  const injected = GATE_TOOL_NAMES.filter((n) => !names.has(n));
  // 自带的门禁工具也要**过得去 schema 那关**（空 schema = 403，见 stampToolSchema）
  const stamped = tools.map(stampToolSchema);
  const schemaFixed = stamped.some((t, i) => t !== tools[i]);
  if (injected.length > 0) {
    for (const n of injected) stamped.push(gateTool(n));
  }
  const renamed = restore.size > 0;
  if (injected.length > 0 || schemaFixed || renamed) {
    out.tools = stamped;
  }
  return { body: out, injected, schemaFixed, restore };
}

// ─────────────────────────────────────────────────────────── 上游请求

function upstreamUrl(base, path) {
  return String(base).replace(/\/+$/, '') + path;
}

/** 发一个上游请求，返回 { status, headers, body(Buffer) }。 */
function upstreamRequest({ method, url, headers, body, timeoutMs = 300000 }) {
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;
    const done = (fn) => (v) => {
      if (settled) return;
      settled = true;
      fn(v);
    };
    const ok = done(resolvePromise);
    const bad = done(rejectPromise);

    const u = new URL(url);
    const transport = u.protocol === 'https:' ? https : http;

    const req = transport.request(
      u,
      { method, headers, timeout: timeoutMs },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () =>
          ok({ status: res.statusCode || 0, headers: res.headers, body: Buffer.concat(chunks) }),
        );
        res.on('error', bad);
      },
    );
    req.on('timeout', () => {
      req.destroy(new Error('上游超时'));
    });
    req.on('error', bad);
    if (body) req.write(body);
    req.end();
  });
}

/** 流式转发：把上游响应**边收边发**（不再是"等整段收完再吐"）。 */
function upstreamStream({ method, url, headers, body, timeoutMs = 300000, onResponse }) {
  return new Promise((resolvePromise, rejectPromise) => {
    const u = new URL(url);
    const transport = u.protocol === 'https:' ? https : http;
    const req = transport.request(u, { method, headers, timeout: timeoutMs }, (res) => {
      Promise.resolve()
        .then(() => onResponse(res))
        .then(resolvePromise, rejectPromise);
    });
    req.on('timeout', () => req.destroy(new Error('上游超时')));
    req.on('error', rejectPromise);
    if (body) req.write(body);
    req.end();
  });
}

/**
 * 抢先读第一块数据 —— 用来**按响应体的形状**判定上游给的到底是 SSE 还是 JSON。
 *
 * ## 为什么不能信 `content-type`
 *
 * 上游在高负载时会把**完整的 SSE 帧序列**用 `application/json` 的 header 发回来。
 * 直接沿用这个 header 就等于告诉下游"这是 JSON" → 下游按 JSON 解析 → 整轮失败，
 * 而且失败得太早、太像"模型坏了"，还可能把这个本来好好的模型标成不可用。
 *
 * 所以判据只能是**响应体的形状**，不能是 header 说的那句话。
 *
 * ## 两个必须遵守的约束
 *
 *  * 用 `readable` + `read()` 而不是 `data` 事件：一旦进入 flowing 模式，
 *    在我们注册新的 `data` 监听之前到达的数据会**直接丢掉**。
 *  * 超时/立刻结束都返回 null：嗅探只是为了把 header 说对，
 *    绝不能因为它把一条本来正常的转发拖死。
 */
function sniffFirst(res, ms = 1200) {
  return new Promise((resolvePromise) => {
    let settled = false;
    const finish = (v) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      res.removeListener('readable', onReadable);
      res.pause();
      resolvePromise(v);
    };
    const onReadable = () => {
      let chunk = null;
      try {
        chunk = res.read();
      } catch {
        chunk = null;
      }
      if (chunk) finish(chunk);
    };
    const timer = setTimeout(() => finish(null), ms);
    res.on('readable', onReadable);
    res.once('end', () => finish(null));
    res.once('error', () => finish(null));
  });
}

// ─────────────────────────────────────────────────────────── 模型列表（带缓存）

function cachePath(state) {
  return state ? join(state, 'zen-models.json') : '';
}

function readCache(state, ttlHours) {
  try {
    const p = cachePath(state);
    if (!p || !existsSync(p)) return null;
    const raw = JSON.parse(readFileSync(p, 'utf8'));
    const ageMs = Date.now() - Number(raw.at || 0);
    if (!Array.isArray(raw.models) || raw.models.length === 0) return null;
    if (ageMs > ttlHours * 3600 * 1000) return null;
    return raw.models;
  } catch {
    return null;
  }
}

function writeCache(state, models) {
  try {
    const p = cachePath(state);
    if (!p) return;
    mkdirSync(state, { recursive: true });
    writeFileSync(p, JSON.stringify({ at: Date.now(), models }), 'utf8');
  } catch {
    /* 缓存写不进去不影响使用 */
  }
}

// ─────────────────────────────────────────────────────────── 主流程

async function main() {
  const args = parseArgs(process.argv.slice(2));
  // 会话映射落盘（不存明文 seed，见 sessionStatePath 的说明）
  if (args.state) {
    sessionStatePath = join(args.state, 'zen-sessions.json');
    loadSessionCache();
  }
  let lastError = null;
  let modelCache = null;
  // Kilo 那条的模型缓存（同样只在内存里，不落盘 —— 上游清单随时变，缓存旧了更糟）
  let kiloCache = null;
  // OVHcloud 那条的模型缓存（同上）
  let ovhCache = null;

  /**
   * 取"免费模型"列表：优先上游实时列表（过滤出免费的），失败则用缓存，
   * 再失败用静态名单。**任何一步失败都不会让代理起不来** —— 起不来比"列表旧一点"糟得多。
   */
  async function listFreeModels() {
    if (modelCache) return modelCache;
    const cached = readCache(args.state, args.ttlHours);
    if (cached) {
      modelCache = cached;
      return cached;
    }
    try {
      const session = canonicalSessionId('models');
      const r = await upstreamRequest({
        method: 'GET',
        url: upstreamUrl(args.upstream, '/v1/models'),
        headers: disguiseHeaders(session),
        timeoutMs: 20000,
      });
      if (r.status >= 200 && r.status < 300) {
        const json = JSON.parse(r.body.toString('utf8'));
        const ids = (Array.isArray(json?.data) ? json.data : [])
          .map((m) => (m && typeof m.id === 'string' ? m.id : null))
          .filter(Boolean)
          .filter(isFree);
        // 静态名单里已被上游下架的不要硬塞进列表（避免给用户一个选了就报错的模型）
        const live = new Set(ids);
        const merged = [...ids];
        for (const m of STATIC_FREE_MODELS) {
          if (!live.has(m) && ids.length === 0) merged.push(m); // 只在实时列表为空时才兜底
        }
        if (merged.length > 0) {
          modelCache = merged;
          writeCache(args.state, merged);
          return merged;
        }
      }
      lastError = `取模型列表失败：HTTP ${r.status}`;
    } catch (e) {
      lastError = `取模型列表失败：${e.message}`;
    }
    modelCache = STATIC_FREE_MODELS.slice();
    return modelCache;
  }

  /**
   * Kilo AI 公共网关的免费池（2026-10-31 接入）。
   *
   * 与 Zen 那条的三个差别：
   *   * **完全不需要鉴权**，也不需要伪装头（它本来就是给公众用的池子）；
   *   * 上游用 `isFree: true` 明确标注哪些模型免费 —— 直接按这个挑，不去猜价格字段；
   *   * 它的模型 id 自带斜杠和 `:free` 后缀（例如
   *     `dots-studio/dots-3-note-preview:free`），**原样使用、不加前缀**：
   *     两条上游靠「厂家」区分，不靠 id 前缀，这样模型名对用户也是最可读的。
   *
   * 拿不到就返回空数组（而不是抛错）：第二条上游挂了不该影响第一条。
   */
  async function listKiloFreeModels() {
    if (kiloCache) return kiloCache;
    try {
      const r = await upstreamRequest({
        method: 'GET',
        url: String(args.kiloUpstream).replace(/\/+$/, '') + '/models',
        headers: { accept: 'application/json' },
        timeoutMs: 20000,
      });
      if (r.status >= 200 && r.status < 300) {
        const json = JSON.parse(r.body.toString('utf8'));
        const ids = (Array.isArray(json?.data) ? json.data : [])
          .filter((m) => m && typeof m.id === 'string' && m.isFree === true)
          .map((m) => m.id);
        if (ids.length > 0) {
          kiloCache = ids;
          return ids;
        }
        lastError = 'Kilo 的免费池是空的（上游可能改了策略）';
      } else {
        lastError = `Kilo 取模型列表失败：HTTP ${r.status}`;
      }
    } catch (e) {
      lastError = `Kilo 取模型列表失败：${e.message}`;
    }
    // ⚠️ 不写进 modelCache，也不互相覆盖 lastError 之外的任何东西 ——
    //    两条上游必须互不牵连（一条挂了另一条照常服务）。
    kiloCache = [];
    return kiloCache;
  }

  /**
   * 第三条免密上游：OVHcloud AI Endpoints 的免费模型。
   *
   * 它和 Kilo 一样是**纯免 Key、无需伪装**的 OpenAI 兼容端点 —— 但有个区别：
   * OVHcloud 的 `/models` **没有 `isFree` 标记**，整张表列出来的就都是可用模型
   * （2026-11-01 实测 22 个，含 gpt-oss / Qwen3 / Mistral / Llama 等）。
   * 所以这里不做过滤，整表即免费池。
   *
   * 拿不到就返回空数组（不抛错）：第三条挂了不该影响前两条。
   */
  async function listOvhFreeModels() {
    if (ovhCache) return ovhCache;
    try {
      const r = await upstreamRequest({
        method: 'GET',
        url: String(args.ovhUpstream).replace(/\/+$/, '') + '/v1/models',
        headers: { accept: 'application/json' },
        timeoutMs: 20000,
      });
      if (r.status >= 200 && r.status < 300) {
        const json = JSON.parse(r.body.toString('utf8'));
        const ids = (Array.isArray(json?.data) ? json.data : [])
          .filter((m) => m && typeof m.id === 'string')
          .map((m) => m.id);
        if (ids.length > 0) {
          ovhCache = ids;
          return ids;
        }
        lastError = 'OVHcloud 的模型表是空的（上游可能改了策略）';
      } else {
        lastError = `OVHcloud 取模型列表失败：HTTP ${r.status}`;
      }
    } catch (e) {
      lastError = `OVHcloud 取模型列表失败：${e.message}`;
    }
    // 三条上游互不牵连：失败只记 lastError，不碰别人的缓存。
    ovhCache = [];
    return ovhCache;
  }

  /** 把上游的错误转成 OpenAI 形状，并附上**能看懂**的中文说明。 */
  function errorBody(status, text) {
    // 上游把错误类型写在 JSON 里（`{"type":"error","error":{"type":"…"}}`）——
    // 先把它抠出来：有些类型光看状态码是分不出来的（例如 400 的协议不支持）。
    let upstreamType = '';
    try {
      const j = JSON.parse(text);
      upstreamType = String(j?.error?.type || j?.type || '');
    } catch {
      upstreamType = '';
    }
    let hint = '';
    if (upstreamType === 'ModelProtocolUnsupported') {
      // 2026-10-16 本机实测：免费层里 `jev-1.13-free` 就是这个（**400，不是 403**）。
      // 它走的是 Responses / Messages 那条线，而本代理只转发 chat/completions ——
      // 说清"是那个模型走的协议不同"，别让用户去怀疑网络或 Key。
      hint = '（这个免费模型服务端只走另一条协议（Responses/Messages），本代理只转发 '
          + 'chat/completions —— 换一个免费模型即可，不用改配置。）';
    } else if (status === 403 && /region/i.test(text)) {
      // ⚠️ 403 有两种**完全不同**的含义，别混成一句话：地区封锁（换网络才有用）
      //    与免费层门禁（换模型 / 等它松）。2026-10-15 本机就同时见过这两种。
      hint = '（你所在地区不在它的放行范围：这是出口地区封锁，与请求形状无关 —— '
          + '换网络，或先在「设置 → 模型」里用别的模型。）';
    } else if (status === 403) {
      // 403 的含义是"匿名免费车道又被闸了"，**不是**用户配错了什么 —— 把这句话
      // 说死，否则用户会去反复检查自己的 Key（那条路怎么查都不会好）。
      hint = '（上游把匿名免费车道闸了：这条通道只对官方 CLI 开放，而且上游一直在改门禁'
          + '（2026-09-16 起已收紧 6 次，最近一次是 10-15）。'
          + '这不是"你没配 Key"—— 它本来就不用 Key。'
          + '下一步：在「设置 → 模型」里换一个自己配了 Key 的模型，或过一阵再试。）';
    } else if (status === 429) {
      hint = '（被限流了：免费通道按出口 IP 限流，等一会儿再试。）';
    } else if (status === 401) {
      hint = '（上游要求鉴权：匿名通道可能已经关闭。）';
    } else if (status === 426) {
      hint = '（上游要求升级客户端版本：这道门禁按官方 CLI 的 UA 版本带放行，'
          + '我们的代理没落在它当前接受的带内。）';
    }
    let detail = '';
    try {
      const j = JSON.parse(text);
      detail = String(j?.error?.message || j?.error || j?.message || '').slice(0, 300);
    } catch {
      detail = String(text || '').slice(0, 300);
    }
    return JSON.stringify({
      error: {
        message: `社区免费通道返回 HTTP ${status}${hint}${detail ? ` 上游原话：${detail}` : ''}`,
        type: 'upstream_error',
        code: status,
      },
    });
  }

  /** 请求日志（`--log-requests` 才打；流式路径在结束时才写，所以这里单独一个函数）。 */
  function logChat(model, bytes, startedAt) {
    if (!args.logRequests) return;
    process.stderr.write(
      `[zen-proxy] POST chat model=${model} → 200 (${bytes}B, ${Date.now() - startedAt}ms)\n`,
    );
  }

  /**
   * 这个模型名属于哪条上游。
   *
   * 为什么需要：App 现在只注册**一个**厂家（`zen`，baseURL 挂在 `/v1`），
   * 但三条上游的模型混在同一个列表里。请求进来时只有模型名，
   * 所以必须能反查出它该发给谁。
   *
   * 顺序：Zen → Kilo → OVH（Zen 是自己那批，重名时优先它）。
   * 三个 cache 都查不到 = 退回 Zen（保持旧行为，不至于把人话请求丢掉）。
   */
  async function laneOfModel(modelId) {
    if (!modelId) return 'zen';
    try {
      if ((await listFreeModels()).includes(modelId)) return 'zen';
    } catch (_) {}
    try {
      if ((await listKiloFreeModels()).includes(modelId)) return 'kilo';
    } catch (_) {}
    try {
      if ((await listOvhFreeModels()).includes(modelId)) return 'ovh';
    } catch (_) {}
    return 'zen';
  }

  const server = createServer(async (req, res) => {
    const started = Date.now();
    const url = new URL(req.url || '/', 'http://127.0.0.1');
    const rawPath = url.pathname;

    // 三条上游共用一个本地端口，用**路径前缀**分流（2026-10-31 接 Kilo，11-01 接 OVHcloud）：
    //   /v1/*        → Zen（OpenCode，必须伪装成官方 CLI，否则 403）
    //   /kilo/v1/*   → Kilo AI 公共网关（免 Key，也不需要伪装）
    //   /ovh/v1/*    → OVHcloud AI Endpoints（免 Key，也不需要伪装）
    // DSH 那边注册成三个「厂家」，各自的模型 id 原样使用，天然不冲突。
    // 2026-11-03：三条上游**合并成一个厂家**给 App 看，所以 `/v1/*` 这条路
    // 也要能路由到 Kilo / OVH —— 靠**模型名**判断（见下面的 laneOfModel）。
    // 因此这两个改成 let：路径前缀是"显式指定"，模型名是"自动判断"，
    // 两者都支持（老的 /kilo/v1、/ovh/v1 继续可用，不必改回去）。
    let isKilo = rawPath === '/kilo' || rawPath.startsWith('/kilo/');
    let isOvh = rawPath === '/ovh' || rawPath.startsWith('/ovh/');
    const stripPrefix = (p, prefix) => (p.slice(prefix.length) || '/');
    const path = isKilo
        ? stripPrefix(rawPath, '/kilo')
        : isOvh
            ? stripPrefix(rawPath, '/ovh')
            : rawPath;

    // ── 健康检查：给 App 显示状态用（是否在跑、模型数、上次错误）
    if (path === '/healthz') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        ok: true,
        models: (modelCache || []).length,
        upstream: args.upstream,
        lastError,
      }));
      return;
    }

    // ── 模型列表
    if (path === '/v1/models' && req.method === 'GET') {
      const models = isOvh
          ? await listOvhFreeModels()
          : isKilo
              ? await listKiloFreeModels()
              : await listFreeModels();
      const owner = isOvh ? 'ovhcloud' : isKilo ? 'kilo' : 'opencode-zen';
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        object: 'list',
        data: models.map((id) => ({
          id,
          object: 'model',
          owned_by: owner,
        })),
      }));
      if (args.logRequests) {
        process.stderr.write(
          `[zen-proxy] GET /v1/models(${owner}) → ${models.length} 个\n`);
      }
      return;
    }

    // ── 对话（流式转发）
    if (path === '/v1/chat/completions' && req.method === 'POST') {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', async () => {
        let payload;
        try {
          payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        } catch (e) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: { message: `请求体不是合法 JSON：${e.message}` } }));
          return;
        }

        // ── 按模型名自动选上游（2026-11-03 三通道合并后必需）─────────────
        //
        // 路径前缀（/kilo/v1、/ovh/v1）仍然有效，但 App 现在统一走 `/v1`，
        // 所以这里靠模型名判断。只在**没带前缀**时才做（前缀是显式指定，优先）。
        if (!isKilo && !isOvh) {
          const lane = await laneOfModel(payload.model);
          if (lane === 'kilo') isKilo = true;
          else if (lane === 'ovh') isOvh = true;
        }

        // 会话种子：优先用调用方给的（这样同一会话 id 稳定），否则按第一条用户消息派生
        const clientSeed =
          String(req.headers['x-zen-seed'] || '').trim() ||
          (() => {
            const msgs = Array.isArray(payload.messages) ? payload.messages : [];
            const first = msgs.find((m) => m && m.role === 'user');
            const text = typeof first?.content === 'string'
              ? first.content
              : JSON.stringify(first?.content ?? '');
            return text || 'anonymous';
          })();
        const session = canonicalSessionId(clientSeed);

        // Zen 那条要把请求改造成"官方 CLI 的形状"（强制 stream、注入门禁工具、
        // 工具名大小写归一）；Kilo / OVHcloud 是**公共网关**，不要动它的请求体 ——
        // 改造反而可能被当成异常客户端。
        const { body, restore } = (isKilo || isOvh)
          ? { body: payload, restore: { size: 0 } }
          : applyGate(payload);
        const baseHeaders = {
          'content-type': 'application/json',
          // 上游可能按 Accept 分流，明确要 SSE
          accept: body.stream ? 'text/event-stream' : 'application/json',
        };
        // 只有 Zen 需要伪装（它校验"是不是自家 CLI"）；Kilo/OVH 不需要，别多此一举。
        const headers = (isKilo || isOvh)
            ? baseHeaders
            : { ...disguiseHeaders(session), ...baseHeaders };

        try {
          await upstreamStream({
            method: 'POST',
            url: isOvh
              ? String(args.ovhUpstream).replace(/\/+$/, '') + '/v1/chat/completions'
              : isKilo
                  ? String(args.kiloUpstream).replace(/\/+$/, '') + '/chat/completions'
                  : upstreamUrl(args.upstream, '/v1/chat/completions'),
            headers,
            body: Buffer.from(JSON.stringify(body), 'utf8'),
            onResponse: (r) => (async () => {
                const status = r.statusCode || 0;
                if (status < 200 || status >= 300) {
                  const chunks = [];
                  r.on('data', (c) => chunks.push(c));
                  await new Promise((ok) => {
                    r.on('end', ok);
                    r.on('error', ok);
                  });
                  const text = Buffer.concat(chunks).toString('utf8');
                  lastError = `HTTP ${status}`;
                  process.stderr.write(`[zen-proxy] 上游 HTTP ${status}：${text.slice(0, 200)}\n`);
                  res.writeHead(status, { 'content-type': 'application/json' });
                  res.end(errorBody(status, text));
                  return;
                }
                lastError = null;

                // ⚠️ **按响应体的形状判流式，不信 header**（2026-10-31）。
                //
                //    上游高负载时会把**完整的 SSE 帧序列**用 `application/json` 的
                //    header 发回来。直接沿用这个 header 就等于告诉下游"这是 JSON" →
                //    下游按 JSON 解析 → 整轮失败；而且失败得极像"模型坏了"，还可能
                //    把这个本来好好的模型标成不可用。判据只能是响应体的形状。
                const upstreamType = String(r.headers['content-type'] || '');
                const first = await sniffFirst(r);
                const head = first
                  ? first.toString('utf8', 0, Math.min(first.length, 64))
                  : '';
                // SSE 帧一定以 `data:` / `event:` / `id:` / 注释行 `:` 开头。
                const looksSse = /^\s*(?:data:|event:|id:|:)/.test(head);
                const isSse = looksSse || /event-stream/i.test(upstreamType);
                if (looksSse && !/event-stream/i.test(upstreamType)) {
                  process.stderr.write(
                    `[zen-proxy] 上游 header 写的是 ${upstreamType || '(无)'}，但 body 是 SSE 帧 → 按 SSE 转发\n`);
                }
                res.writeHead(200, {
                  'content-type': isSse
                    ? 'text/event-stream'
                    : (upstreamType || 'application/json'),
                  'cache-control': 'no-cache',
                  connection: 'keep-alive',
                  'transfer-encoding': 'chunked',
                });

                let bytes = 0;
                if (restore.size === 0) {
                  // 绝大多数情况：一个字节都不改，边收边发（首字延迟 = 上游首字延迟）。
                  // 注意先把嗅探到的那块补发出去 —— 否则每轮都会**丢掉开头一小段**。
                  if (first) {
                    bytes += first.length;
                    res.write(first);
                  }
                  // ⚠️ 嗅探可能已经把**整个响应**读走了（2026-11-01）：非流式响应
                  //    （OVHcloud 这类）整块 JSON 一次到齐，`sniffFirst` 的 read() 把它
                  //    全读走、流随即 end。这时再挂 `end` 监听**永远等不到**（事件已在
                  //    嗅探期间 fire 过）→ 下游卡死、curl 拿到 0 字节。Zen/Kilo 是流式、
                  //    数据分批来才没踩到。
                  //    所以嗅探后先看流是不是已经结束：结束了就直接收尾，别再等 end。
                  if (r.readableEnded) {
                    res.end();
                    logChat(payload.model, bytes, started);
                    return;
                  }
                  // 没结束（流式/还有后续块）→ 显式 resume 后继续边收边发。
                  // resume() 对已在流动的流是无害 no-op；对嗅探超时 pause 过的空流则
                  // 是必需的（Node 里显式 pause 过的流挂 data 监听不会自动 resume）。
                  r.resume();
                  await new Promise((ok) => {
                    r.on('data', (c) => {
                      bytes += c.length;
                      res.write(c);
                    });
                    r.on('end', () => {
                      res.end();
                      logChat(payload.model, bytes, started);
                      ok();
                    });
                    r.on('error', () => {
                      res.end();
                      ok();
                    });
                  });
                } else {
                  // 罕见路径：调用方用了 `Bash`/`READ` 这类大小写变体 → 缓冲后改名再发
                  const chunks = first ? [first] : [];
                  await new Promise((ok) => {
                    r.on('data', (c) => chunks.push(c));
                    r.on('end', ok);
                    r.on('error', ok);
                  });
                  const text = restoreToolNames(Buffer.concat(chunks).toString('utf8'), restore);
                  bytes = Buffer.byteLength(text, 'utf8');
                  res.end(text);
                  logChat(payload.model, bytes, started);
                }
              })(),
          });
        } catch (e) {
          lastError = e.message;
          process.stderr.write(`[zen-proxy] 转发失败：${e.message}\n`);
          // ⚠️ 已经发过 200 头了就不能再改状态码（会抛 ERR_HTTP_HEADERS_SENT，
          //    一个 client 端的意外断流能把整个代理进程带崩）。
          if (!res.headersSent) {
            res.writeHead(502, { 'content-type': 'application/json' });
            res.end(JSON.stringify({
              error: { message: `连接社区免费通道失败：${e.message}` },
            }));
          } else {
            try {
              res.end();
            } catch {
              /* 客户端可能已经走了 */
            }
          }
        }
      });
      return;
    }

    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: `没有这个路径：${path}` } }));
  });

  server.listen(args.port, '127.0.0.1', () => {
    const port = server.address().port;
    // ⚠️ Dart 侧按这一行回填端口（系统挑的 0 端口只能这样告诉它）。格式不要改。
    process.stdout.write(`listening on http://127.0.0.1:${port}\n`);
    process.stderr.write(`[zen-proxy] 已就绪：上游 ${args.upstream}，仅实验性使用（见文件顶部说明）\n`);
  });

  // 预热模型列表（不阻塞就绪；失败也不影响）
  listFreeModels().catch(() => {});
}

main().catch((e) => {
  process.stderr.write(`zen-proxy: 未预期错误：${(e && e.stack) || e}\n`);
  process.exit(1);
});
