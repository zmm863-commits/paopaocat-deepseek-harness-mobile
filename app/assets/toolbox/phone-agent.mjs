#!/usr/bin/env node
/**
 * 手机屏幕助手 · Node 客户端。
 *
 * ## 它解决什么
 *
 * App 里有一个本机 HTTP 桥（127.0.0.1:3971x）+ 一个跑在 shell 里的无头虚拟屏引擎，能力是：
 * 截图 / OCR 认字 / 点击 / 滑动 / 列应用 / 开应用。
 * **DSH 的 Agent 跑在 Node 进程里**，所以需要一个能在 Node 侧跑、负责
 * 「读钥匙 → 发请求 → 打印结果」的小脚本。就是本文件。
 *
 * ## 钥匙从哪来
 *
 * App 启动时会把 `{port, token, enabled}` 写到 **filesDir/phone-agent.json**。
 * Node 拿得到 filesDir —— 因为宿主传了 `DSH_HOME=<filesDir>/dshhome`，
 * 所以 `dirname(DSH_HOME)` 就是 filesDir。
 *
 * ⚠️ **令牌不进日志、不进状态页**，只走这个文件 —— 别的 App 读不到。
 *
 * ## 用法（Agent 直接用）
 *
 *   node phone-agent.mjs status           # 桥在不在、引擎连没连、虚拟屏建没建
 *   node phone-agent.mjs shot [out.png]   # 截当前屏幕，存文件（默认 /tmp/pa-shot.png）
 *   node phone-agent.mjs nodes [maxDepth] # 控件树（JSON）
 *   node phone-agent.mjs find <文字>      # 在控件树里找"文字"（按 desc/text 包含），打印坐标
 *   node phone-agent.mjs ocr              # 截图 + 文字识别（**自绘界面专用**），列出所有文字块+坐标
 *   node phone-agent.mjs findtext <文字>  # 截图 + 认字 + 找"文字"，打印坐标（自绘界面用它代替 find）
 *   node phone-agent.mjs tap <x> <y> [--expect 包名]   # 手势点（带 expect 才防误点）
 *   node phone-agent.mjs clicknode --pkg <包名> --text <文字>  # 节点点击（不依赖坐标，更稳）
 *   node phone-agent.mjs windows            # 列出系统暴露给我们的窗口（诊断）
 *   node phone-agent.mjs swipe <x1> <y1> <x2> <y2> [ms]
 *   node phone-agent.mjs key <back|home|recents>   # 返回/主页/最近任务（走错路能退）
 *   node phone-agent.mjs input <文字>               # 往当前输入框写字（搜索框用）
 *   node phone-agent.mjs waittext <文字> [毫秒]     # 等界面出现这段文字（页面加载用）
 *   node phone-agent.mjs apps [关键词]     # 列手机里的应用
 *   node phone-agent.mjs launch <包名或应用名>
 *
 * 退出码：0 成功；1 失败（stderr 里有原因，**原因都是人话**）。
 */

import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';

// ── 找钥匙 ────────────────────────────────────────────────────────────
function keyFile() {
  const home = process.env.DSH_HOME || '';
  if (home) {
    // 宿主传的 DSH_HOME = <filesDir>/dshhome → filesDir 是它的父目录
    return path.join(path.dirname(home), 'phone-agent.json');
  }
  // 兜底：写死的路径（只在调试时可能命中）
  return '/data/user/0/com.dshmobile.dsh_mobile/files/phone-agent.json';
}

/** 用户录的规则目录（filesDir/rules）。filesDir = DSH_HOME 的父目录。 */
function rulesDir() {
  const home = process.env.DSH_HOME || '';
  if (home) return path.join(path.dirname(home), 'rules');
  return '/data/user/0/com.dshmobile.dsh_mobile/files/rules';
}

/** 录制状态文件（Agent 边跑边录时暂存步骤）。 */
function recordingFile() {
  const home = process.env.DSH_HOME || '';
  const dir = home ? path.dirname(home) : '/data/user/0/com.dshmobile.dsh_mobile/files';
  return path.join(dir, 'recording.json');
}

function isRecording() {
  try { return fs.existsSync(recordingFile()); } catch { return false; }
}

/** 录制模式下，把一步加到暂存文件（没在录制就什么都不做）。 */
function recordStep(step) {
  if (!isRecording()) return;
  try {
    const f = recordingFile();
    const cur = JSON.parse(fs.readFileSync(f, 'utf8'));
    if (!Array.isArray(cur.steps)) cur.steps = [];
    cur.steps.push(step);
    fs.writeFileSync(f, JSON.stringify(cur));
  } catch {}
}

/** 列出用户录的规则名（filesDir/rules/*.json 的文件名）。 */
function listUserRuleNames() {
  try {
    const dir = rulesDir();
    if (!fs.existsSync(dir)) return [];
    return fs.readdirSync(dir)
      .filter((f) => f.endsWith('.json'))
      .map((f) => f.slice(0, -5))
      .sort();
  } catch {
    return [];
  }
}

/** 读用户录的一条规则（filesDir/rules/<名字>.json）；没有就返回 null。 */
function loadUserRule(name) {
  try {
    const f = path.join(rulesDir(), name + '.json');
    if (!fs.existsSync(f)) return null;
    return JSON.parse(fs.readFileSync(f, 'utf8'));
  } catch {
    return null;
  }
}

function readKey() {
  const f = keyFile();
  let raw;
  try {
    raw = fs.readFileSync(f, 'utf8');
  } catch (e) {
    die(`找不到 ${f}\n这通常意味着「屏幕助手」的桥没起来 —— 去 App 的 设置 → 应用 → 屏幕助手 看一眼。`);
  }
  let j;
  try {
    j = JSON.parse(raw);
  } catch {
    die(`钥匙文件不是合法 JSON：${f}`);
  }
  if (!j.port || !j.token) die(`钥匙文件缺 port/token：${f}`);
  return j;
}

function die(msg) {
  console.error('✗ ' + msg);
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── 规则引擎（录制回放的「回放」半边）──────────────────────────────────
// 规则 = 一段「OCR 锚定」的操作脚本：点击用 tapText（点「某文字」，OCR 实时定位），
// 不是绝对坐标，所以换手机/分辨率/App 小改版都还能用。占位符 {参数名} 执行时替换。
// 这是「用户自己写/录规则」的落点：规则就是普通 JSON，以后用户录完就存成这样。

/**
 * 通用「关弹窗」文字库 —— 来自公开去广告规则里最高频的文字（开屏广告/更新提示/青少年模式）
 * 里出现频率最高的 text 匹配。
 *
 * 分两档：EXACT 是纯按钮文案（短、准），CONTAIN 允许包含匹配但限制长度。
 * ⚠️ 黑名单：绝对不能点「更新/下载/安装/确定/确认/支付/删除」——这些一按就出事。
 */
const DISMISS_EXACT = [
  '跳过', '跳過', '跳 过', 'skip', 'Skip', 'SKIP',
  '关闭', '忽略', '不再提示', '不感兴趣', '残忍拒绝', '放弃',
  '以后再说', '下次再说', '稍后再说', '稍后再看', '下次再约',
  '我知道了', '知道了', '暂不开启', '暂不更新', '暂不', '以后',
];
const DISMISS_CONTAIN = ['跳过', '跳過', '关闭', '我知道了', '以后再说', '暂不', '忽略'];
// 注意：「开启」不能进黑名单，否则会挡掉合法按钮「暂不开启」。
const DISMISS_BLOCK = ['更新', '升级', '下载', '安装', '确定', '确认', '支付', '删除', '同意', '授权', '领取'];
// 「暂不开启」这类按钮必须放行，所以黑名单只用于含「更新/下载/确定」等危险动作的词。

/** 一行 OCR 文字是否像「关弹窗」按钮；返回安全等级（0=精确，1=包含），-1=不能点。 */
function dismissRank(text) {
  const t = (text || '').trim();
  if (!t || t.length > 12) return -1;
  // ⚠️ 顺序：精确白名单先于黑名单，否则「暂不更新/暂不开启」会被「更新」误杀。
  if (DISMISS_EXACT.includes(t)) return 0;
  if (DISMISS_BLOCK.some((k) => t.includes(k))) return -1;
  if (t.length <= 6 && DISMISS_CONTAIN.some((k) => t.includes(k))) return 1;
  return -1;
}

const BUILTIN_RULES = {
  '淘宝比价': {
    name: '淘宝比价',
    params: ['关键词'],
    steps: [
      { action: 'launch', pkg: 'com.taobao.taobao' },
      { action: 'waitText', text: '搜索', timeout: 12000 },
      { action: 'tapText', text: '搜索' },
      { action: 'waitMs', ms: 1200 },
      { action: 'input', text: '{关键词}' },
      { action: 'waitMs', ms: 1000 },
      { action: 'tapText', text: '搜索' },
      { action: 'waitMs', ms: 3500 },
      { action: 'collectPrices' },
      { action: 'release' },
    ],
  },
  '京东比价': {
    name: '京东比价',
    params: ['关键词'],
    steps: [
      { action: 'launch', pkg: 'com.jingdong.app.mall' },
      { action: 'waitText', text: '搜索', timeout: 12000 },
      { action: 'tapText', text: '搜索' },
      { action: 'waitMs', ms: 1200 },
      { action: 'input', text: '{关键词}' },
      { action: 'waitMs', ms: 1000 },
      { action: 'tapText', text: '搜索' },
      { action: 'waitMs', ms: 3500 },
      { action: 'collectPrices' },
      { action: 'release' },
    ],
  },
  '关弹窗': {
    name: '关弹窗',
    params: [],
    steps: [{ action: 'dismiss' }, { action: 'dismiss' }, { action: 'dismiss' }],
  },
  '拼多多比价': {
    name: '拼多多比价',
    params: ['关键词'],
    steps: [
      { action: 'launch', pkg: 'com.xunmeng.pinduoduo' },
      { action: 'waitText', text: '搜索', timeout: 12000 },
      { action: 'tapText', text: '搜索' },
      { action: 'waitMs', ms: 1200 },
      { action: 'input', text: '{关键词}' },
      { action: 'waitMs', ms: 1000 },
      { action: 'tapText', text: '搜索' },
      { action: 'waitMs', ms: 3500 },
      { action: 'collectPrices' },
      { action: 'release' },
    ],
  },
};

function fillParams(text, params) {
  return text.replace(/\{(\w+)\}/g, (_, k) => (params[k] ?? ''));
}

/** 执行一条规则。返回 true=跑完；false=某步失败（错误已打 stderr）。 */
/** 扫屏关弹窗：找常见弹窗文字点掉，返回关掉的个数。 */
async function dismissPopups(rounds) {
  let total = 0;
  for (let i = 0; i < rounds; i++) {
    const r = await call(key, 'GET', '/ocr');
    let hit = null;
    let best = 9;
    for (const l of (r.lines || [])) {
      const rank = dismissRank(l.text);
      if (rank >= 0 && rank < best) { hit = l; best = rank; }
      if (rank === 0) break;
    }
    if (!hit) break;
    await call(key, 'POST', '/tap', { x: hit.cx, y: hit.cy });
    total++;
    await sleep(1200);
  }
  return total;
}

async function runRule(rule, params) {
  let priceResult = null;
  let totalDismissed = 0;
  for (const st of rule.steps) {
    const a = st.action;
    if (a === 'launch') {
      await call(key, 'POST', '/launch', { pkg: st.pkg });
      // 开屏广告几乎必然出现，等界面出来一点就清掉，别等后面 waitText 超时才补救。
      if (st.autoDismiss !== false) {
        await sleep(st.settle || 2500);
        totalDismissed += await dismissPopups(2);
      }
    } else if (a === 'waitText') {
      const q = fillParams(st.text, params);
      const ms = st.timeout || 8000;
      let r = await call(key, 'GET', `/wait-text?q=${encodeURIComponent(q)}&timeout=${ms}`);
      if (r.found !== true) {
        // 没等到 → 清弹窗（开屏广告/更新弹窗是最常见主因）后再等一次。
        const n = await dismissPopups(3);
        if (n > 0) {
          console.error(`… 关掉 ${n} 个弹窗，重新等「${q}」`);
          r = await call(key, 'GET', `/wait-text?q=${encodeURIComponent(q)}&timeout=${ms}`);
        }
      }
      if (r.found !== true) {
        console.error(`✗ 等了 ${ms}ms 没等到「${q}」（步骤 waitText）。页面结构可能变了。`);
        return false;
      }
    } else if (a === 'tapText') {
      const q = fillParams(st.text, params);
      let r = await call(key, 'GET', `/find-text?q=${encodeURIComponent(q)}`);
      if (!r.count) {
        const n = await dismissPopups(3);
        if (n > 0) {
          console.error(`… 关掉 ${n} 个弹窗，重新找「${q}」`);
          r = await call(key, 'GET', `/find-text?q=${encodeURIComponent(q)}`);
        }
      }
      if (!r.count) {
        console.error(`✗ 没 OCR 到「${q}」（步骤 tapText）。可能界面还没加载，或这是个纯图标按钮。`);
        return false;
      }
      const line = r.lines[0];
      await call(key, 'POST', '/tap', { x: line.cx, y: line.cy });
      await sleep(600);
    } else if (a === 'input') {
      await call(key, 'POST', '/input', { text: fillParams(st.text, params) });
    } else if (a === 'tap') {
      await call(key, 'POST', '/tap', { x: st.x, y: st.y });
    } else if (a === 'swipe') {
      await call(key, 'POST', '/swipe', {
        x1: st.x1, y1: st.y1, x2: st.x2, y2: st.y2, ms: st.ms || 300,
      });
    } else if (a === 'waitMs') {
      await sleep(st.ms || 1000);
    } else if (a === 'key') {
      await call(key, 'GET', `/key?action=${encodeURIComponent(st.key)}`);
    } else if (a === 'collectPrices') {
      const r = await call(key, 'GET', '/ocr');
      const re = /[¥￥]\s*(\d+(?:\.\d+)?)/;
      const items = [];
      for (const l of (r.lines || [])) {
        const m = l.text.match(re);
        if (m) items.push({ price: parseFloat(m[1]), text: l.text.slice(0, 44) });
      }
      items.sort((x, y) => x.price - y.price);
      const uniq = [];
      for (const it of items) {
        if (!uniq.some((u) => Math.abs(u.price - it.price) < 0.01)) uniq.push(it);
      }
      priceResult = {
        count: uniq.length,
        lowest: uniq[0] || null,
        prices: uniq.slice(0, 12).map((i) => ({ price: i.price, text: i.text })),
      };
    } else if (a === 'dismiss') {
      totalDismissed += await dismissPopups(st.rounds || 3);
    } else if (a === 'release') {
      await call(key, 'GET', '/release');
    } else {
      console.error(`✗ 不认识的步骤动作「${a}」。`);
      return false;
    }
  }
  if (totalDismissed > 0) console.error(`… 全程关掉 ${totalDismissed} 个弹窗`);
  if (priceResult) {
    console.log(JSON.stringify(priceResult, null, 2));
    if (!priceResult.count) {
      console.error('✗ 结果页没 OCR 到带 ¥/￥ 的价格（可能关键词没输进去，或结果没加载出来）。');
      return false;
    }
  }
  return true;
}

// ── HTTP ──────────────────────────────────────────────────────────────
function req(key, method, pathAndQuery, body) {
  return new Promise((resolve, reject) => {
    const opt = {
      host: '127.0.0.1',
      port: key.port,
      method,
      path: pathAndQuery,
      headers: { 'x-dsh-token': key.token },
      timeout: 20000,
    };
    let payload = null;
    if (body !== undefined) {
      payload = Buffer.from(JSON.stringify(body), 'utf8');
      opt.headers['content-type'] = 'application/json';
      opt.headers['content-length'] = payload.length;
    }
    const r = http.request(opt, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try {
          json = JSON.parse(text);
        } catch {
          /* 保留 text，下面按需报错 */
        }
        resolve({ status: res.statusCode, json, text });
      });
    });
    r.on('timeout', () => {
      r.destroy(new Error('请求超时（20s）'));
    });
    r.on('error', reject);
    if (payload) r.write(payload);
    r.end();
  });
}

async function call(key, method, p, body) {
  let r;
  try {
    r = await req(key, method, p, body);
  } catch (e) {
    die(`连不上桥（127.0.0.1:${key.port}）：${e.message}\n` +
        '如果 App 刚重启过，桥可能还没起来；隔几秒再试。');
  }
  if (r.status !== 200) {
    const why = r.json?.error || r.text?.slice(0, 200) || `HTTP ${r.status}`;
    die(why);
  }
  if (r.json === null) die(`返回的不是 JSON：${r.text.slice(0, 200)}`);
  return r.json;
}

// ── 子命令 ────────────────────────────────────────────────────────────
const [, , cmd, ...args] = process.argv;

if (!cmd) {
  console.log(fs.readFileSync(new URL(import.meta.url), 'utf8').split('## 用法')[1]
    ?.split('## 退出码')[0] || '');
  process.exit(0);
}

const key = readKey();

// 总开关：关着就别让 Agent 乱动
if (key.enabled === false) {
  die('「屏幕助手」的总开关是关的 —— 去 App 的 设置 → 应用 → 屏幕助手 打开它。');
}

switch (cmd) {
  case 'status': {
    const s = await call(key, 'GET', '/status');
    console.log(JSON.stringify(s, null, 2));
    if (!s.connected) {
      console.error('\n✗ 后台引擎没连上 —— 去 App 的 设置 → 应用 → 屏幕助手，用「免装 Shizuku」配对启动（或已装 Shizuku 则授权）。');
      process.exit(1);
    }
    break;
  }

  case 'shot': {
    const out = args[0] || '/tmp/pa-shot.png';
    const r = await call(key, 'GET', '/screenshot');
    const buf = Buffer.from(r.png, 'base64');
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, buf);
    console.log(out);
    console.error(`✓ 截图 ${(buf.length / 1024).toFixed(0)} KB → ${out}`);
    break;
  }

  case 'ocr': {
    const r = await call(key, 'GET', '/ocr');
    for (const l of r.lines || []) {
      console.log(`${l.cx},${l.cy}\t${l.text}`);
    }
    if (!r.count) {
      console.error('✗ 这一屏没认出任何文字（可能是纯图形界面）。');
      process.exit(1);
    }
    break;
  }

  case 'findtext': {
    const needle = args[0];
    if (!needle) die('用法：phone-agent.mjs findtext <文字>');
    const r = await call(key, 'GET', `/find-text?q=${encodeURIComponent(needle)}`);
    if (!r.count) {
      console.error(`✗ 截图里没认出含「${needle}」的文字。`);
      console.error('  （纯图形按钮没有字 —— 只能你自己看 shot 的图目测坐标。）');
      process.exit(1);
    }
    console.log(JSON.stringify(r.lines, null, 2));
    break;
  }

  case 'tap': {
    const x = Number(args[0]);
    const y = Number(args[1]);
    if (!Number.isFinite(x) || !Number.isFinite(y)) die('用法：phone-agent.mjs tap <x> <y> [--expect 包名]');
    const body = { x, y };
    // `--expect <包名>`：前台不是这个 App 就不点（防"中途被切走点到别处"）
    const ei = args.indexOf('--expect');
    if (ei >= 0 && args[ei + 1]) body.expect = args[ei + 1];
    const r = await call(key, 'POST', '/tap', body);
    console.log(JSON.stringify(r));
    break;
  }

  case 'swipe': {
    const [x1, y1, x2, y2] = args.slice(0, 4).map(Number);
    if ([x1, y1, x2, y2].some((v) => !Number.isFinite(v))) {
      die('用法：phone-agent.mjs swipe <x1> <y1> <x2> <y2> [ms]');
    }
    const ms = args[4] ? Number(args[4]) : 300;
    const r = await call(key, 'POST', '/swipe', { x1, y1, x2, y2, ms });
    recordStep({ action: 'swipe', x1, y1, x2, y2 });
    console.log(JSON.stringify(r));
    break;
  }

  case 'key': {
    const act = args[0] || 'back';
    const r = await call(key, 'GET', `/key?action=${encodeURIComponent(act)}`);
    console.log(JSON.stringify(r));
    break;
  }

  case 'input': {
    const t = args.join(' ');
    if (!t) die('用法：phone-agent.mjs input <文字>');
    const r = await call(key, 'POST', '/input', { text: t });
    recordStep({ action: 'input', text: t });
    console.log(JSON.stringify(r));
    break;
  }

  case 'waittext': {
    const q = args[0];
    if (!q) die('用法：phone-agent.mjs waittext <文字> [毫秒]');
    const ms = args[1] ? Number(args[1]) : 8000;
    const r = await call(key, 'GET',
      `/wait-text?q=${encodeURIComponent(q)}&timeout=${ms}`);
    console.log(JSON.stringify(r));
    if (r.found !== true) process.exit(1);
    break;
  }

  case 'apps': {
    const kw = (args[0] || '').toLowerCase();
    const r = await call(key, 'GET', '/apps');
    let list = r.apps || [];
    if (kw) list = list.filter((a) => a.label.toLowerCase().includes(kw) || a.package.includes(kw));
    for (const a of list) {
      console.log(`${a.system ? '[系统] ' : ''}${a.label}\t${a.package}`);
    }
    if (!list.length) {
      console.error(`✗ 没找到匹配「${args[0] || ''}」的应用。`);
      process.exit(1);
    }
    break;
  }

  case 'launch': {
    const want = args.join(' ');
    if (!want) die('用法：phone-agent.mjs launch <包名或应用名>');
    // 先当包名试；失败再按名字模糊匹配（Agent 说"打开头条"更自然，不该逼它记包名）
    let pkg = want;
    if (!want.includes('.')) {
      const r = await call(key, 'GET', '/apps');
      const kw = want.toLowerCase();
      const hit = (r.apps || []).find(
        (a) => a.label.toLowerCase() === kw || a.label.toLowerCase().includes(kw),
      );
      if (!hit) {
        console.error(`✗ 没有名字含「${want}」的应用。先跑 \`node phone-agent.mjs apps <关键词>\` 看看有哪些。`);
        process.exit(1);
      }
      pkg = hit.package;
      console.error(`（按名字匹配到：${hit.label} · ${hit.package}）`);
    }
    const r = await call(key, 'POST', '/launch', { pkg });
    recordStep({ action: 'launch', pkg });
    console.log(JSON.stringify(r));
    break;
  }

  case 'create': {
    const w = args[0] ? Number(args[0]) : 1080;
    const h = args[1] ? Number(args[1]) : 1920;
    const dpi = args[2] ? Number(args[2]) : 320;
    const r = await call(key, 'POST', '/create', { w, h, dpi });
    console.log(JSON.stringify(r));
    break;
  }

  case 'release': {
    const r = await call(key, 'GET', '/release');
    console.log(JSON.stringify(r));
    break;
  }

  case 'record-start': {
    // Agent 开始边跑边录：之后 launch / tap-text / input / swipe 都会被记下来。
    fs.writeFileSync(recordingFile(), JSON.stringify({ steps: [] }));
    console.log('录制开始：之后的操作会记成规则步骤，做完用 record-stop <名字> 保存。');
    break;
  }

  case 'record-stop': {
    const name = args[0];
    if (!name) die('用法：phone-agent.mjs record-stop <规则名>');
    let steps = [];
    try {
      const cur = JSON.parse(fs.readFileSync(recordingFile(), 'utf8'));
      steps = Array.isArray(cur.steps) ? cur.steps : [];
    } catch {
      die('当前没有在录制（找不到录制暂存）。先 record-start。');
    }
    const rule = { name, params: [], steps };
    const dir = rulesDir();
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, name + '.json'), JSON.stringify(rule, null, 2));
    try { fs.unlinkSync(recordingFile()); } catch {}
    console.log(`已保存规则「${name}」：${steps.length} 步 → ${path.join(dir, name + '.json')}`);
    break;
  }

  case 'tap-text': {
    // 点「某文字」：OCR 找文字 → 点它的中心。录制时记成 tapText（比坐标跨屏）。
    const t = args[0];
    if (!t) die('用法：phone-agent.mjs tap-text <文字>');
    const r = await call(key, 'GET', `/find-text?q=${encodeURIComponent(t)}`);
    if (!r.count) {
      console.error(`✗ 没 OCR 到「${t}」。`);
      process.exit(1);
    }
    const line = r.lines[0];
    await call(key, 'POST', '/tap', { x: line.cx, y: line.cy });
    recordStep({ action: 'tapText', text: t });
    console.log('已点：' + t);
    break;
  }

  case 'dismiss': {
    const total = await dismissPopups(Number(args[0]) || 3);
    console.log(JSON.stringify({ dismissed: total }));
    break;
  }

  case 'rules': {
    // 列出用户录的规则（filesDir/rules/*.json）。
    const names = listUserRuleNames();
    if (!names.length) {
      console.error('你还没录规则。去 App：设置 → 应用 → 泡泡猫助手 → 打开后台操作台，'
        + '在虚拟屏里点「开始录制」录一条；或在这里用 record-start 边跑边录。');
      process.exit(1);
    }
    for (const n of names) {
      const r = loadUserRule(n);
      const steps = Array.isArray(r?.steps) ? r.steps.length : 0;
      console.log(`${n}\t${steps} 步`);
    }
    break;
  }

  case 'run': {
    // 执行一条规则（内置或以后用户录的）。参数：位置参数按规则 params 顺序填，
    // 或 key=value 显式填。
    const name = args[0];
    if (!name) die('用法：phone-agent.mjs run <规则名> [参数=值 ...]');
    // 先查内置规则，再查用户录的规则（filesDir/rules/<名字>.json）。
    const rule = BUILTIN_RULES[name] || loadUserRule(name);
    if (!rule) {
      const mine = listUserRuleNames();
      die(`不认识的规则「${name}」。内置：${Object.keys(BUILTIN_RULES).join(' / ')}` +
          (mine.length ? `；你录的：${mine.join(' / ')}` : '；你还没录规则'));
    }
    const params = {};
    let pi = 0;
    for (const a of args.slice(1)) {
      const i = a.indexOf('=');
      if (i > 0) params[a.slice(0, i)] = a.slice(i + 1);
      else { const k = rule.params[pi++]; if (k) params[k] = a; }
    }
    const ok = await runRule(rule, params);
    if (!ok) process.exit(1);
    break;
  }

  case 'price': {
    // 快速比价 = 执行「平台+比价」这条内置规则（固定脚本，秒级，不走 LLM）。
    const keyword = args[0];
    if (!keyword) die('用法：phone-agent.mjs price <关键词> [淘宝|京东|拼多多]');
    const platform = args[1] || '淘宝';
    const rule = BUILTIN_RULES[platform + '比价'];
    if (!rule) die(`不认识的平台「${platform}」，支持：淘宝 / 京东 / 拼多多`);
    console.error(`（执行内置规则：${rule.name}，关键词「${keyword}」）`);
    const ok = await runRule(rule, { 关键词: keyword });
    if (!ok) process.exit(1);
    break;
  }

  default:
    die(`不认识的子命令 "${cmd}"。支持：status / shot / create / release / ocr / findtext / tap / swipe / key / input / waittext / apps / launch / run / rules / price / tap-text / record-start / record-stop / dismiss`);
}
