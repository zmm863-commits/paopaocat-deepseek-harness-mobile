#!/usr/bin/env node
/**
 * 手机屏幕助手 · Node 客户端。
 *
 * ## 它解决什么
 *
 * App 里有一个本机 HTTP 桥（127.0.0.1:3971x）+ 一个无障碍服务，能力是：
 * 截图 / 控件树 / 点击 / 滑动 / 列应用 / 开应用。
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
 *   node phone-agent.mjs status           # 桥在不在、无障碍连没连、当前前台包名
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
      console.error('\n✗ 无障碍服务没连上 —— 去 系统设置 → 无障碍 → DSH 屏幕助手 开启。');
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

  case 'nodes': {
    const depth = args[0] ? Number(args[0]) : 12;
    const r = await call(key, 'GET', `/nodes?depth=${depth}`);
    console.log(JSON.stringify(r.nodes, null, 2));
    break;
  }

  case 'find': {
    const needle = args[0];
    if (!needle) die('用法：phone-agent.mjs find <文字>');
    const r = await call(key, 'GET', '/nodes');
    const hits = [];
    const walk = (n) => {
      const t = `${n.text || ''} ${n.desc || ''}`;
      if (t.includes(needle) && n.bounds && n.bounds[2] > n.bounds[0]) {
        hits.push({
          text: (n.text || n.desc || '').slice(0, 40),
          cls: n.cls,
          clickable: n.clickable,
          center: [
            Math.round((n.bounds[0] + n.bounds[2]) / 2),
            Math.round((n.bounds[1] + n.bounds[3]) / 2),
          ],
          bounds: n.bounds,
        });
      }
      for (const c of n.children || []) walk(c);
    };
    for (const n of r.nodes) walk(n);
    if (!hits.length) {
      console.error(`✗ 界面上没找到含「${needle}」的控件。`);
      console.error('  （如果是游戏/自绘界面，节点树本来就没有文字 —— 用 shot 截图 + 视觉判断。）');
      process.exit(1);
    }
    // 优先给 clickable 的、靠前的
    hits.sort((a, b) => Number(b.clickable) - Number(a.clickable));
    console.log(JSON.stringify(hits.slice(0, 10), null, 2));
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

  case 'clicknode': {
    const pi = args.indexOf('--pkg');
    const ti = args.indexOf('--text');
    const pkg = pi >= 0 ? args[pi + 1] : '';
    const text = ti >= 0 ? args[ti + 1] : '';
    if (!pkg || !text) die('用法：phone-agent.mjs clicknode --pkg <包名> --text <文字>');
    const r = await call(key, 'GET',
      `/clicknode?pkg=${encodeURIComponent(pkg)}&text=${encodeURIComponent(text)}`);
    console.log(JSON.stringify(r));
    break;
  }

  case 'windows': {
    const r = await call(key, 'GET', '/windows');
    for (const w of r.windows || []) {
      console.log(`${w.active ? '*' : ' '} ${w.package}\tfocused=${w.focused}`);
    }
    break;
  }

  case 'swipe': {
    const [x1, y1, x2, y2] = args.slice(0, 4).map(Number);
    if ([x1, y1, x2, y2].some((v) => !Number.isFinite(v))) {
      die('用法：phone-agent.mjs swipe <x1> <y1> <x2> <y2> [ms]');
    }
    const ms = args[4] ? Number(args[4]) : 300;
    const r = await call(key, 'POST', '/swipe', { x1, y1, x2, y2, ms });
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
    console.log(JSON.stringify(r));
    break;
  }

  default:
    die(`不认识的子命令 "${cmd}"。支持：status / shot / nodes / find / ocr / findtext / tap / swipe / key / input / waittext / apps / launch`);
}
