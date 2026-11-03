// zen-proxy.mjs 的测试（本地假上游，不碰真上游）。
//
// ## 为什么用假上游
//
// 要验的是**代理的形状是否正确**：门禁要求的会话 id 形状、`stream:true`、
// **四个**门禁工具（`bash`/`glob`/`grep`/`read`）、工具名大小写规范化与回写、
// `msg_` 形状的请求 id、真流式（边收边发）、以及错误映射。
// 这些全部可以在本地断言 —— 而且**不该**拿真上游做测试（那是往人家服务上打请求）。
//
// 用法：node install/test-zen-proxy.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import http from 'node:http';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO = join(HERE, '..');
const SCRIPT = join(REPO, 'app', 'assets', 'toolbox', 'zen-proxy.mjs');
const SCRIPT_SRC = readFileSync(SCRIPT, 'utf8');

let passed = 0;
const failures = [];
function test(name, fn) {
  return Promise.resolve().then(fn).then(
    () => { passed += 1; console.log(`  ✓ ${name}`); },
    (e) => { failures.push([name, e]); console.log(`  ✗ ${name}\n      ${e.message}`); },
  );
}
function section(t) { console.log(`\n== ${t} ==`); }

const work = mkdtempSync(join(tmpdir(), 'zen-proxy-test-'));
process.on('exit', () => { try { rmSync(work, { recursive: true, force: true }); } catch {} });

/** 起一个假上游；handler(rec, res, hits) 决定怎么答。 */
async function withUpstream(handler, fn) {
  const hits = [];
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d.toString()));
    req.on('end', () => {
      const rec = {
        method: req.method,
        url: req.url,
        headers: req.headers,
        body,
        json: (() => { try { return JSON.parse(body); } catch { return null; } })(),
      };
      hits.push(rec);
      handler(rec, res, hits);
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  try {
    return await fn({ upstream: `http://127.0.0.1:${port}`, hits });
  } finally {
    await new Promise((r) => server.close(r));
  }
}

/** 起代理（指向给定上游），返回 { port, proc, stop }。 */
async function startProxy(upstream, extraArgs = []) {
  // ⚠️ 每次给**自己的** state 目录：模型列表会缓存到 state 里（ttl 12h），
  //    共用一个目录时，前一条测试的假列表会被后一条读到 —— 那样"静态兜底"
  //    那条测试其实什么都没验到（2026-10-16 自测当场踩到）。
  const state = mkdtempSync(join(tmpdir(), 'zen-proxy-state-'));
  const proc = spawn(process.execPath, [
    SCRIPT, '--port', '0', '--upstream', upstream, '--state', state, '--ttl-hours', '12',
    ...extraArgs,
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  let err = '';
  proc.stdout.on('data', (d) => { out += d.toString(); });
  proc.stderr.on('data', (d) => { err += d.toString(); });
  const port = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`代理没就绪。stdout=${out} stderr=${err}`)), 20000);
    proc.stdout.on('data', () => {
      const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
      if (m) { clearTimeout(timer); resolve(Number(m[1])); }
    });
    proc.on('error', reject);
  });
  return {
    port,
    stop: () => new Promise((r) => { proc.on('close', r); proc.kill('SIGKILL'); }),
    logs: () => ({ out, err }),
  };
}

/**
 * 只挑**对话**请求。
 * ⚠️ 代理启动时会预热模型列表（发一个 GET /v1/models），所以 `hits[0]` 往往是
 * 那个请求 —— 早期版本就是因此误判（断言 stream/tools 时拿到了 models 请求）。
 */
function chatHits(hits) {
  return hits.filter((h) => h.method === 'POST' && String(h.url).includes('/chat/completions'));
}

async function proxyFetch(port, path, init) {
  const res = await fetch(`http://127.0.0.1:${port}${path}`, init);
  const text = await res.text();
  return { status: res.status, text, json: (() => { try { return JSON.parse(text); } catch { return null; } })() };
}

/**
 * 直接走 node:http 发一次对话（**不用 fetch** —— 这里要看"首块什么时候到"，
 * fetch 会把流包一层，观测首字节的时间就不准了）。`onFirst` 在第一块到达时调一次。
 */
function streamChat(port, body, onFirst) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = http.request({
      hostname: '127.0.0.1',
      port,
      path: '/v1/chat/completions',
      method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) },
    }, (res) => {
      let all = '';
      res.on('data', (c) => {
        const t = c.toString('utf8');
        if (all === '' && onFirst) onFirst(t);
        all += t;
      });
      res.on('end', () => resolve(all));
      res.on('error', reject);
    });
    req.on('error', reject);
    req.end(data);
  });
}

/** 假上游的 SSE 响应（两段增量 + 结束）。 */
function sseReply(res) {
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  res.write('data: {"choices":[{"delta":{"content":"你"}}]}\n\n');
  res.write('data: {"choices":[{"delta":{"content":"好"}}]}\n\n');
  res.end('data: [DONE]\n\n');
}

// ─────────────────────────────────────────────────────────────────────

section('按模型名自动选上游（2026-11-03 三通道合并后必需）');

// 三条上游合并成一个厂家后，App 只走 `/v1`；请求该发给谁**只能靠模型名**判断。
// 这组测试钉住的正是那条链路：起三个假上游，各自回一个可辨认的名字，
// 然后从 `/v1` 发对话，看它落到了谁手里。
await test('模型名属于 Kilo → 转发到 Kilo 上游（不是 Zen）', async () => {
  let zenHits = 0;
  await withUpstream(
    (req, res) => {
      if (String(req.url).includes('/models')) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ object: 'list', data: [{ id: 'zen-model-a' }] }));
        return;
      }
      zenHits++;
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: 'z', choices: [{ message: { content: 'from-zen' } }] }));
    },
    async ({ upstream }) => {
      await withUpstream(
        (req, res) => {
          if (String(req.url).includes('/models')) {
            res.writeHead(200, { 'content-type': 'application/json' });
            res.end(JSON.stringify({ object: 'list', data: [{ id: 'kilo-model-b', isFree: true }] }));
            return;
          }
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ id: 'k', choices: [{ message: { content: 'from-kilo' } }] }));
        },
        async ({ upstream: kiloUp }) => {
          const px = await startProxy(upstream, ['--kilo-upstream', kiloUp]);
          try {
            // 先让代理把两条上游的列表都预热一遍（laneOfModel 靠它判断）
            await proxyFetch(px.port, '/v1/models', { method: 'GET' });
            await proxyFetch(px.port, '/kilo/v1/models', { method: 'GET' });
            zenHits = 0;
            const r = await proxyFetch(px.port, '/v1/chat/completions', {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({
                model: 'kilo-model-b',
                messages: [{ role: 'user', content: 'hi' }],
                stream: false,
              }),
            });
            if (r.status !== 200) throw new Error(`期望 200，实际 ${r.status}：${r.text.slice(0, 120)}`);
            if (!r.text.includes('from-kilo')) {
              throw new Error(`没落到 Kilo 上游（zenHits=${zenHits}）`);
            }
            if (zenHits !== 0) throw new Error(`不该打到 Zen，打了 ${zenHits} 次`);
          } finally {
            await px.stop();
          }
        },
      );
    },
  );
});

await test('模型名属于 Zen → 仍然走 Zen（不能被误认成别的）', async () => {
  await withUpstream(
    (req, res) => {
      if (String(req.url).includes('/models')) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ object: 'list', data: [{ id: 'zen-model-a' }] }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: 'z', choices: [{ message: { content: 'from-zen' } }] }));
    },
    async ({ upstream }) => {
      const px = await startProxy(upstream);
      try {
        await proxyFetch(px.port, '/v1/models', { method: 'GET' });
        const r = await proxyFetch(px.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            model: 'zen-model-a',
            messages: [{ role: 'user', content: 'hi' }],
            stream: false,
          }),
        });
        if (!r.text.includes('from-zen')) throw new Error(`落错地方了：${r.text.slice(0, 120)}`);
      } finally {
        await px.stop();
      }
    },
  );
});

await test('路径前缀仍然优先（/kilo/v1 明确指定时，模型名不参与判断）', async () => {
  await withUpstream(
    (req, res) => {
      if (String(req.url).includes('/models')) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ object: 'list', data: [{ id: 'zen-model-a' }] }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: 'z', choices: [{ message: { content: 'from-zen' } }] }));
    },
    async ({ upstream }) => {
      await withUpstream(
        (req, res) => {
          if (String(req.url).includes('/models')) {
            res.writeHead(200, { 'content-type': 'application/json' });
            res.end(JSON.stringify({ object: 'list', data: [{ id: 'kilo-model-b', isFree: true }] }));
            return;
          }
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ id: 'k', choices: [{ message: { content: 'from-kilo' } }] }));
        },
        async ({ upstream: kiloUp }) => {
          const px = await startProxy(upstream, ['--kilo-upstream', kiloUp]);
          try {
            // 故意用 zen 的模型名 + kilo 的路径：路径说了算
            const r = await proxyFetch(px.port, '/kilo/v1/chat/completions', {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({
                model: 'zen-model-a',
                messages: [{ role: 'user', content: 'hi' }],
                stream: false,
              }),
            });
            if (!r.text.includes('from-kilo')) {
              throw new Error(`前缀没优先：${r.text.slice(0, 120)}`);
            }
          } finally {
            await px.stop();
          }
        },
      );
    },
  );
});

section('门禁形状：会话 id / stream / 四个工具 / 请求 id');
{
  await test('转发时会带上**官方形状**的会话 id 与 CLI 头', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          // ⚠️ 故意带一个假 Authorization：DSH 注入的占位值（`local-zen`）长的
          //    就是这样 —— 它**不是**这条通道认的凭据，绝不能透传到上游。
          headers: { 'content-type': 'application/json', authorization: 'Bearer local-zen' },
          body: JSON.stringify({ model: 'big-pickle', messages: [{ role: 'user', content: '你好' }] }),
        });
        const chat = chatHits(hits);
        assert.equal(chat.length, 1, `应该只有一次对话请求，实际 ${chat.length}（hits: ${hits.map((x) => x.method + ' ' + x.url).join(', ')}）`);
        const h = chat[0].headers;
        // ⚠️ 这是整件事的关键：形状必须是 ses_ + 12 位小写 hex + 14 位 Base62
        assert.match(h['x-opencode-session'], /^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/,
          `会话 id 形状不对：${h['x-opencode-session']}`);
        assert.equal(h['x-opencode-client'], 'cli');
        assert.match(h['user-agent'], /^opencode\//);
        // 2026-10-15 的新门禁：`x-opencode-session-id` 必须存在、且与 session 同值
        assert.equal(h['x-opencode-session-id'], h['x-opencode-session'],
          'x-opencode-session-id 必须与 x-opencode-session 同值（缺了 → 403）');
        // ⚠️ 两条**遗留头必须不发**：多发的 `x-session-affinity` 会被上游当成
        //    非官方客户端信号直接 403（Aether PR#72 的头部矩阵）。负向钉住防"顺手加回来"。
        assert.equal(h['x-session-affinity'], undefined,
          'x-session-affinity 不能再发（会被判成非官方客户端）');
        assert.equal(h['x-session-id'], undefined,
          'x-session-id 不能再发（只有 x-opencode-session-id 是对的）');
        // 上游路径也跟着搬家了：老 `/zen/v1/...` 现在**无条件 403**。
        // 假上游只能验后半段（它自己就是 base），车道前缀在 DEFAULT_UPSTREAM 里 ——
        // 所以这里一并钉住那个常量（改了它等于把整条通道打回 403，必须有测试拦）。
        assert.equal(chat[0].url, '/v1/chat/completions',
          `假上游收到的路径不对：${chat[0].url}`);
        assert.match(SCRIPT_SRC, /DEFAULT_UPSTREAM = 'https:\/\/opencode\.ai\/inference'/,
          'DEFAULT_UPSTREAM 必须是 https://opencode.ai/inference（老 /zen 已无条件 403）');
        assert.ok(!/deepseek-harness/i.test(h['user-agent']),
          `UA 里不能出现 deepseek-harness（上游点名拒）：${h['user-agent']}`);
        // 「不用写 Key」的凭据就是字面量 `public`（官方实现的形状），且**必须覆盖**
        // 调用方自带的头 —— 透传 `local-zen` 会让上游认不出这条匿名通道。
        assert.equal(h['authorization'], 'Bearer public',
          `上游凭据应是 Bearer public，实际 ${h['authorization']}`);
      } finally { await p.stop(); }
    });
  });

  await test('客户端没带工具 → 自动补上四个门禁工具，并强制 stream:true', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'big-pickle', stream: false, messages: [] }),
        });
        const chat = chatHits(hits);
        assert.equal(chat.length, 1);
        const body = chat[0].json;
        assert.equal(body.stream, true, '门禁要求 stream:true');
        const names = (body.tools || []).map((t) => t.function && t.function.name);
        // ⚠️ 2026-10-15 起是**四个**（不再是 bash+read 两个）—— 少一个上游按
        //    "不是官方客户端"直接 403 FreeTierError（社区两份独立实测）。
        for (const name of ['bash', 'glob', 'grep', 'read']) {
          assert.ok(names.includes(name), `缺 ${name} 工具：${JSON.stringify(names)}`);
        }
        // 2026-10-14 起：`properties: {}` 与"没声明"一样会被 403，每个诱饵工具
        // 都必须至少有一个 property（社区工具矩阵实测）。
        for (const name of ['bash', 'glob', 'grep', 'read']) {
          const t = (body.tools || []).find((x) => x.function?.name === name);
          const props = Object.keys(t?.function?.parameters?.properties ?? {});
          assert.ok(props.length > 0,
            `${name} 的 schema 至少要有一个 property，实际 ${JSON.stringify(t?.function?.parameters)}`);
        }
      } finally { await p.stop(); }
    });
  });

  await test('x-opencode-request 用 `msg_` 铸造形状（10-15 起不再吃 `req_`），且每次不同', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        for (let i = 0; i < 2; i += 1) {
          await proxyFetch(p.port, '/v1/chat/completions', {
            method: 'POST',
            headers: { 'content-type': 'application/json', 'x-zen-seed': 'same-conv' },
            body: JSON.stringify({ model: 'big-pickle', messages: [{ role: 'user', content: 'hi' }] }),
          });
        }
        const reqs = chatHits(hits).map((h) => h.headers['x-opencode-request'] || '');
        assert.equal(reqs.length, 2);
        for (const id of reqs) {
          assert.match(id, /^msg_[0-9a-f]{12}[0-9A-Za-z]{14}$/, `请求 id 形状不对：${id}`);
          // 12 位 hex 是 `(ms*0x1000 + seq)` 的**低 48 位**（官方 msg_ 铸造编码；
          // ms*0x1000 需要 53 位，所以高位在 48 位编码里本来就是被截掉的 ——
          // 这里按"与当前时刻的同余差在 2 分钟内"判定，别去直接反解毫秒）。
          const hex = BigInt('0x' + id.slice(4, 16));
          const mask = 0xFFFFFFFFFFFFn;
          const nowHex = (BigInt(Date.now()) * 0x1000n) & mask;
          const raw = (hex - nowHex + mask + 1n) % (mask + 1n);
          const delta = raw > mask / 2n ? mask + 1n - raw : raw; // 取环上的**最近**距离
          assert.ok(delta < 4096n * 120000n,
            `请求 id 里编码的时间戳要接近当前时刻（${id}，差 ${delta}）`);
        }
        assert.notEqual(reqs[0], reqs[1], '每个请求应当有自己的请求 id');
        // 同一个会话里 session 必须稳定（与每次不同的 request 成对照）
        const sessions = chatHits(hits).map((h) => h.headers['x-opencode-session']);
        assert.equal(sessions[0], sessions[1], '同一会话的 session 必须稳定');
      } finally { await p.stop(); }
    });
  });

  await test('工具名大小写：`Bash`/`READ` 发成小写，回程再改回调用方的原拼写', async () => {
    const sseWithToolCall = (res) => {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash"}}]}}]}\n\n');
      res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\":\\"ls\\"}"}}]}}]}\n\n');
      res.end('data: [DONE]\n\n');
    };
    await withUpstream(async (rec, res) => { sseWithToolCall(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            model: 'big-pickle',
            messages: [{ role: 'user', content: 'hi' }],
            tools: [
              { type: 'function', function: { name: 'Bash', description: '调用方的写法就是大写', parameters: { type: 'object', properties: { command: { type: 'string' } } } } },
              { type: 'function', function: { name: 'read', parameters: { type: 'object', properties: { filePath: { type: 'string' } } } } },
            ],
          }),
        });
        // ① 发给上游的名字必须是小写（门禁按小写识别）
        const sent = chatHits(hits)[0].json.tools.map((t) => t.function.name);
        assert.ok(sent.includes('bash'), `上游必须收到小写 bash，实际 ${JSON.stringify(sent)}`);
        assert.ok(!sent.includes('Bash'), `大写 Bash 不能出现在发给上游的 body 里：${JSON.stringify(sent)}`);
        // 调用方的描述必须原样保留（我们不覆盖他的工具语义）
        const bash = chatHits(hits)[0].json.tools.find((t) => t.function.name === 'bash');
        assert.equal(bash.function.description, '调用方的写法就是大写');
        // ② 回程必须把模型吐的 `bash` 改回调用方的 `Bash`，否则工具链对不上
        assert.match(r.text, /"name":"Bash"/,
          `回程要把工具名改回原拼写，实际：${r.text.slice(0, 200)}`);
        assert.ok(!/"name":"bash"/.test(r.text), '回程不该留下小写的 bash');
      } finally { await p.stop(); }
    });
  });

  await test('客户端已经带了自己的 bash/read → 只补缺的两个，绝不重复注入', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            model: 'big-pickle',
            stream: true,
            messages: [],
            tools: [
              { type: 'function', function: { name: 'bash', description: 'DSH 自己的 bash', parameters: { type: 'object' } } },
              { type: 'function', function: { name: 'read', description: 'DSH 自己的 read', parameters: { type: 'object' } } },
            ],
          }),
        });
        const chat = chatHits(hits);
        assert.equal(chat.length, 1);
        const body = chat[0].json;
        const names = (body.tools || []).map((t) => t.function?.name);
        // 缺的那两个补上（10-15 起门禁要四个都声明）
        assert.ok(names.includes('glob') && names.includes('grep'),
          `该补上 glob/grep，实际 ${JSON.stringify(names)}`);
        // 但已有的绝不重复
        for (const n of ['bash', 'read']) {
          assert.equal(names.filter((x) => x === n).length, 1, `不该重复注入 ${n}`);
        }
        const bashTools = (body.tools || []).filter((t) => t.function?.name === 'bash');
        assert.equal(bashTools[0].function.description, 'DSH 自己的 bash',
          '客户端自己的工具必须被保留，不能被我们的占位工具覆盖');
        // 但 schema 空着过不了门禁 → 就地补一个 property（名字/描述/数量都不动）
        const bashProps = Object.keys(bashTools[0].function.parameters?.properties ?? {});
        assert.ok(bashProps.length > 0,
          `自带的空 schema 必须被补上 property，实际 ${JSON.stringify(bashTools[0].function.parameters)}`);
      } finally { await p.stop(); }
    });
  });

  await test('同一个会话种子 → 同一个会话 id（保持上游 prompt cache 亲和）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        for (let i = 0; i < 2; i += 1) {
          await proxyFetch(p.port, '/v1/chat/completions', {
            method: 'POST',
            headers: { 'content-type': 'application/json', 'x-zen-seed': 'conv-abc' },
            body: JSON.stringify({ model: 'big-pickle', messages: [{ role: 'user', content: 'hi' }] }),
          });
        }
        const chat = chatHits(hits);
        assert.equal(chat.length, 2, `应该两次对话请求，实际 ${chat.length}`);
        assert.equal(chat[0].headers['x-opencode-session'], chat[1].headers['x-opencode-session']);
      } finally { await p.stop(); }
    });
  });
}

section('流式透传与模型列表');
{
  await test('上游的 SSE 原样流回来（客户端能拿到两段内容 + [DONE]）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'big-pickle', messages: [{ role: 'user', content: '你好' }] }),
        });
        assert.equal(r.status, 200);
        assert.match(r.text, /"content":"你"/);
        assert.match(r.text, /"content":"好"/);
        assert.match(r.text, /\[DONE\]/);
      } finally { await p.stop(); }
    });
  });

  await test('**真流式**：第一段先到，不等上游结束（这是"边收边发"的判据）', async () => {
    // 假上游：先写一段，停 400ms，再写第二段并结束。
    // 老实现是 `res.end(r.body)`（整段收完再吐）→ 首字节要等 400ms 以上；
    // 新实现应当**马上**把第一段交出去。用"首字节耗时 < 200ms"钉住它。
    await withUpstream(async (rec, res) => {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write('data: {"choices":[{"delta":{"content":"第一段"}}]}\n\n');
      setTimeout(() => {
        res.write('data: {"choices":[{"delta":{"content":"第二段"}}]}\n\n');
        res.end('data: [DONE]\n\n');
      }, 400);
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const started = Date.now();
        let firstAt = 0;
        const full = await streamChat(
          p.port,
          { model: 'big-pickle', messages: [{ role: 'user', content: 'hi' }] },
          () => { firstAt = Date.now(); },
        );
        const elapsed = firstAt - started;
        assert.ok(firstAt > 0, '一块都没收到');
        assert.ok(elapsed < 200,
          `首字节用了 ${elapsed}ms —— 说明还在"整段收完再吐"（假上游故意在第二段前停 400ms）`);
        assert.match(full, /第一段/);
        assert.match(full, /第二段/, '尾巴不能丢');
        assert.match(full, /\[DONE\]/, '流结束标记不能丢');
      } finally { await p.stop(); }
    });
  });

  await test('模型列表只列**免费**的（付费模型不许出现在里面）', async () => {
    await withUpstream(async (rec, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: [
        { id: 'big-pickle' },
        { id: 'gpt-5.9-paid' },
        { id: 'nemotron-3.5-lightning-free' },
        { id: 'claude-x-free' },
      ] }));
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/models');
        assert.equal(r.status, 200);
        const ids = r.json.data.map((m) => m.id);
        // ⚠️ 判据是"名字里带 free"（或落在我们静态实测名单里）。`big-pickle`
        //    虽然在售且能应答，但**不在**上游免费层名单里 —— 2026-10-16 实测
        //    免费层是另外 10 个 id，所以它不该出现在这条通道的列表里（列表是
        //    "免费层"，不是"任何能用的模型"）。
        assert.deepEqual(ids.sort(), ['claude-x-free', 'nemotron-3.5-lightning-free']);
        assert.ok(!ids.includes('gpt-5.9-paid'), '付费模型不该出现在免费通道的列表里');
        assert.ok(!ids.includes('big-pickle'), '不在免费层名单里的模型不该被列成免费');
      } finally { await p.stop(); }
    });
  });

  await test('上游列表取不到 → 退回静态已验证名单，且代理照常可用', async () => {
    await withUpstream(async (rec, res) => {
      res.writeHead(503, { 'content-type': 'application/json' });
      res.end('{"error":"nope"}');
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/models');
        assert.equal(r.status, 200);
        assert.ok(r.json.data.length >= 3, `静态兜底名单不该是空的：${r.text}`);
        // 2026-10-16 复测后的名单（big-pickle 不在免费层，已从兜底名单移出）
        assert.ok(r.json.data.some((m) => m.id === 'cat-jam-free'),
          `静态兜底名单要跟上今天的免费层：${r.text}`);
      } finally { await p.stop(); }
    });
  });

  await test('健康检查能报告状态（App 用它显示"在跑/上次错误"）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/healthz');
        assert.equal(r.status, 200);
        assert.equal(r.json.ok, true);
        assert.ok('lastError' in r.json);
      } finally { await p.stop(); }
    });
  });
}

section('错误呈现：不许假装成功，要说清"怎么办"');
{
  await test('上游 403 → 原样 403，并给出中文说明（说清"不是缺 Key"）', async () => {
    await withUpstream(async (rec, res) => {
      res.writeHead(403, { 'content-type': 'application/json' });
      res.end('{"error":{"message":"FreeTierError: free tier can only be used from within OpenCode"}}');
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'big-pickle', messages: [] }),
        });
        assert.equal(r.status, 403);
        assert.match(r.json.error.message, /HTTP 403/);
        assert.match(r.json.error.message, /只对官方 CLI 开放|收紧/, '要说明这是上游的限制');
        // ⚠️ 2026-10-11 用户纠正："这个项目的特点就是不用写key" —— 403 时必须
        //    说清"不是你没配 Key"，而不是把用户打发去填一个根本不需要的 Key。
        assert.match(r.json.error.message, /不是"你没配 Key"|本来就不用 Key/,
          '要主动澄清：这不是"缺 Key"');
        assert.match(r.json.error.message, /FreeTierError/, '要带出上游原话，便于排查');
      } finally { await p.stop(); }
    });
  });

  await test('上游 403 RegionError → 说清是**地区封锁**（与"门禁"是两码事）', async () => {
    // 2026-10-15 本机实测：同一个出口、同一时刻，403 有两种完全不同的含义
    // （FreeTierError = 门禁；RegionError = 地区）。混成一句话会把用户
    // 引去"反复换模型"或者"反复换网络"里错的那一条。
    await withUpstream(async (rec, res) => {
      res.writeHead(403, { 'content-type': 'application/json' });
      res.end('{"error":{"message":"RegionError: model is not available in your region"}}');
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'cat-jam-free', messages: [] }),
        });
        assert.equal(r.status, 403);
        assert.match(r.json.error.message, /地区/, '要说清这是地区封锁');
        assert.match(r.json.error.message, /RegionError/, '要带出上游原话');
      } finally { await p.stop(); }
    });
  });

  await test('上游 400 ModelProtocolUnsupported → 说清"这个模型走另一条协议"', async () => {
    // 2026-10-16 本机实测：免费层里 `jev-1.13-free` 回的是 **400** 而不是 403
    // （`ModelProtocolUnsupported`）—— 光看状态码会把它归成"未知"，用户只能瞎猜。
    await withUpstream(async (rec, res) => {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end('{"type":"error","error":{"type":"ModelProtocolUnsupported","message":"Model does not support this protocol."}}');
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'jev-1.13-free', messages: [] }),
        });
        assert.equal(r.status, 400);
        assert.match(r.json.error.message, /另一条协议/,
          '要说清是这个模型的协议不同，别让人去查网络/Key');
        assert.match(r.json.error.message, /换一个免费模型/, '要给出能照做的下一步');
      } finally { await p.stop(); }
    });
  });

  await test('上游 429 → 说明"免费通道按 IP 限流，等一会儿"', async () => {
    await withUpstream(async (rec, res) => {
      res.writeHead(429, { 'content-type': 'text/plain' });
      res.end('rate limited');
    }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ model: 'big-pickle', messages: [] }),
        });
        assert.equal(r.status, 429);
        assert.match(r.json.error.message, /限流/);
        assert.match(r.json.error.message, /按出口 IP/);
      } finally { await p.stop(); }
    });
  });

  await test('请求体不是 JSON → 400 且说明原因（不是 500）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: '{ not json',
        });
        assert.equal(r.status, 400);
        assert.match(r.json.error.message, /不是合法 JSON/);
      } finally { await p.stop(); }
    });
  });

  await test('未知路径 → 404（而不是把它转发到上游）', async () => {
    await withUpstream(async (rec, res, hits) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        const r = await proxyFetch(p.port, '/v1/embeddings', { method: 'POST', body: '{}' });
        assert.equal(r.status, 404);
        // ⚠️ 只看**这个路径**有没有被转发：代理启动时会自己预热一次
        //    `GET /v1/models`（那是它该做的），不能把它算成"转发了未知路径"。
        const forwarded = hits.filter((h) => String(h.url).includes('embeddings'));
        assert.equal(forwarded.length, 0, '不该把不认识的路径转发给上游');
      } finally { await p.stop(); }
    });
  });
}

  await test('UA 里的版本号必须落在门禁接受的带内 [1.18.0, 1.18.33]（2026-10-14 新带）', async () => {
    // 上游 2026-10-14 13:45 UTC 起对免费层加了 UA 版本带：<1.18.0 → 426，
    // [1.18.0, 1.18.33] → 放行，>=1.18.34 → 403（连官方 1.19.0 自己也被拒，属上游回归）。
    // 这条测试**直接咬住源码里的常量**：有人把它"顺手升到最新"时立刻变红。
    const m = /opencode\/(\d+)\.(\d+)\.(\d+)/.exec(SCRIPT_SRC);
    assert.ok(m, '源码里没找到 opencode/<version> 形状的 UA');
    const v = [Number(m[1]), Number(m[2]), Number(m[3])];
    const cmp = (a, b) => (a[0] - b[0]) || (a[1] - b[1]) || (a[2] - b[2]);
    assert.ok(cmp(v, [1, 18, 0]) >= 0 && cmp(v, [1, 18, 33]) <= 0,
      `UA 版本 ${v.join('.')} 在门禁带外（必须落在 1.18.0 ~ 1.18.33）`);
    // 自证这条判据真的会拒掉带外的（否则它是个永远绿的断言）
    assert.ok(cmp([1, 19, 0], [1, 18, 33]) > 0, '1.19.0 必须被判成带外');
    assert.ok(cmp([1, 18, 34], [1, 18, 33]) > 0, '1.18.34 必须被判成带外');
    assert.ok(cmp([1, 17, 9], [1, 18, 0]) < 0, '1.17.9 必须被判成带外');
  });

  await test('会话 id 必须是官方 tA() 完整编码（2026-10-14 上游加强：光"能解出时间戳"不够）', async () => {
    await withUpstream(async (rec, res) => { sseReply(res); }, async ({ upstream, hits }) => {
      const p = await startProxy(upstream);
      try {
        const send = (seed) => proxyFetch(p.port, '/v1/chat/completions', {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'x-zen-seed': seed },
          body: JSON.stringify({ model: 'big-pickle', messages: [{ role: 'user', content: 'hi' }], stream: true }),
        });
        await send('sess-A'); await send('sess-A'); await send('sess-B');
        const ids = chatHits(hits).map((h) => h.headers['x-opencode-session'] || '');
        assert.equal(ids.length, 3, `应当有 3 个 chat 请求，实际 ${ids.length}`);
        for (const id of ids) assert.match(id, /^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/, `形状不对：${id}`);
        assert.equal(ids[0], ids[1], '同一个 x-zen-seed 两次必须拿到同一个会话 id（缓存亲和）');
        assert.notEqual(ids[0], ids[2], '不同种子应当拿到不同的会话 id');

        // 官方 tA() 公式：hex = ((27<<36) - 1 - unix_millis) << 12 | 0xFFE （取低 48 位）
        // 两条性质一起验，缺一条都不算"完整编码"：
        //   ① 低 12 位**恰好** 0xFFE（社区实测：手工把末 3 位凑成 ffe 仍会被拒，
        //      因为上游是拿整个编码**反解时间戳**的）；
        //   ② 反解出来的毫秒数**就是刚才**（这条最容易退化 —— 旧实现是"30 天里
        //      随机挑一天"，能过 10-13 的旧门禁，过不了 10-14 的新门禁）。
        for (const id of ids) {
          const hex = BigInt('0x' + id.slice(4, 16));
          assert.equal(Number(hex & 0xFFFn), 0xFFE,
            `低 12 位必须是 0xFFE（${id}）`);
          const ms = Number((27n << 36n) - 1n - (hex >> 12n));
          const skew = Math.abs(Date.now() - ms);
          assert.ok(skew < 120000,
            `会话 id 里编码的时间戳必须接近当前时刻，偏差 ${Math.round(skew / 1000)} 秒（${id}）`);
        }
      } finally { await p.stop(); }
    });
  });

// ─────────────────────────────────────────────────────────────────────
console.log(`\n${'='.repeat(60)}`);
if (failures.length === 0) {
  console.log(`全部通过（${passed} 项）—— 全程只用了本地假上游，没有碰真上游`);
  process.exit(0);
}
console.log(`失败 ${failures.length} 项 / 通过 ${passed} 项`);
for (const [n] of failures) console.log(`  · ${n}`);
process.exit(1);
