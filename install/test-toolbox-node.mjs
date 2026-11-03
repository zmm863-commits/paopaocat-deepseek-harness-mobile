// 工具箱（`app/assets/toolbox/*`）的 node 侧测试 —— 针对审计 P0-2 与 P0-3 的加固。
//
// 为什么单独有一个 node 测试：这两个改动都在 **node 脚本**里（`flutter test`
// 跑不到它们），而它们守的都是**凭据边界** —— 写错了不会崩，只会静默地
// "又能读到 Key 了"。这类缺陷必须被测试钉住。
//
// 跑法：node install/test-toolbox-node.mjs   （不需要设备、不需要网络）
// 退出码：0 全过；1 有失败。

import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO = resolve(HERE, '..');
const require = createRequire(import.meta.url);

let passed = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failures.push([name, e]);
    console.log(`  FAIL ${name}\n       ${e && e.message ? e.message : e}`);
  }
}

async function testAsync(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`  ok   ${name}`);
  } catch (e) {
    failures.push([name, e]);
    console.log(`  FAIL ${name}\n       ${e && e.message ? e.message : e}`);
  }
}

function section(title) {
  console.log(`\n== ${title} ==`);
}

// ─────────────────────────────────────────── P0-2a：exec shim 的凭据白名单

section('P0-2a exec shim：模型驱动的 shell 能继承哪些环境变量');
{
  const shimPath = join(REPO, 'app/assets/toolbox/android-exec-shim.cjs');
  // 这份 shim 是"给真机用的"：只有需要的环境变量都在才会真的接管 child_process。
  // 这里**故意不让它激活**（只 require 纯函数），导出里也没有副作用。
  const shim = require(shimPath);

  const ENV_BEFORE = { ...process.env };
  function withEnv(patch, fn) {
    for (const k of Object.keys(process.env)) delete process.env[k];
    Object.assign(process.env, patch);
    try {
      return fn();
    } finally {
      for (const k of Object.keys(process.env)) delete process.env[k];
      Object.assign(process.env, ENV_BEFORE);
    }
  }

  // 一份"典型的手机运行时环境"：既有该放行的，也有**绝不能**放行的。
  const RUNTIME = {
    // 该放行（随包功能真的要用）
    DSH_ANDROID_TOOLBOX: '/data/app/toolbox',
    AGNES_API_KEY: 'agnes-key',
    AGNES_BASE_URL: 'https://agnes.example',
    LOCAL_IMAGE_BASE_URL: 'http://127.0.0.1:8080',
    // 绝不能放行（这是 P0-2 的整个要点）
    DEEPSEEK_API_KEY: 'sk-deepseek-secret',
    OPENAI_API_KEY: 'sk-openai-secret',
    COM_API_KEY: 'com-secret',
    ROTATE_API_KEY: 'rotate-token',
    PATH: '/system/bin',
  };

  test('默认不再全量继承：provider 的 Key 一个都到不了子进程', () => {
    const got = withEnv(RUNTIME, () => Object.keys(shim.parentEnvBase()).sort());
    for (const k of ['DEEPSEEK_API_KEY', 'OPENAI_API_KEY', 'COM_API_KEY', 'ROTATE_API_KEY']) {
      assert.ok(!got.includes(k), `默认白名单漏了凭据 ${k} —— P0-2 回归了`);
    }
  });

  test('「打开本机应用」取消后，DSH_DEVICE_ 不该再被放行（白名单不留无用口子）', () => {
    const got = withEnv(RUNTIME, () => shim.parentEnvBase());
    // 该通道已随功能一起删除；如果哪天有人把前缀加回白名单，
    // 说明要么功能复活了（那就该连功能一起加回来），要么留了个没人用的口子。
    assert.ok(!Object.keys(got).some((k) => k.startsWith('DSH_DEVICE_')),
      'DSH_DEVICE_ 前缀还在白名单里，但那条设备通道已经删了');
  });

  test('默认放行随包功能真正需要的那几个（少一个就是把功能修坏了）', () => {
    const got = withEnv(RUNTIME, () => shim.parentEnvBase());
    // DSH_ANDROID_TOOLBOX：所有技能文件都靠它找脚本
    assert.equal(got.DSH_ANDROID_TOOLBOX, '/data/app/toolbox', '技能找不到工具箱了');
    // AGNES_*：免费生图 / 生视频
    assert.equal(got.AGNES_API_KEY, 'agnes-key', '免费生图/生视频会失效');
    assert.equal(got.AGNES_BASE_URL, 'https://agnes.example');
    // LOCAL_*：本机出图
    assert.equal(got.LOCAL_IMAGE_BASE_URL, 'http://127.0.0.1:8080');
  });

  test('ROTATE_API_KEY 必须**不在**白名单里（否则模型能自己用用户的 Key 打代理）', () => {
    const got = withEnv(RUNTIME, () => Object.keys(shim.parentEnvBase()));
    assert.ok(!got.includes('ROTATE_API_KEY'), 'ROTATE_API_KEY 不该进 shell（P0-3 的边界）');
  });

  test('none：什么都不继承', () => {
    const got = withEnv({ ...RUNTIME, DSH_ANDROID_ENV_PASSTHROUGH: 'none' }, () =>
      Object.keys(shim.parentEnvBase()),
    );
    assert.deepEqual(got, []);
  });

  test('all：显式回到全量继承（仅调试用，通路必须还在）', () => {
    const got = withEnv({ ...RUNTIME, DSH_ANDROID_ENV_PASSTHROUGH: 'all' }, () =>
      shim.parentEnvBase(),
    );
    assert.equal(got.DEEPSEEK_API_KEY, 'sk-deepseek-secret');
    assert.equal(got.AGNES_API_KEY, 'agnes-key');
  });

  test('自定义前缀仍然可用（覆盖默认表）', () => {
    const got = withEnv({ ...RUNTIME, DSH_ANDROID_ENV_PASSTHROUGH: 'AGNES_' }, () =>
      Object.keys(shim.parentEnvBase()).sort(),
    );
    assert.deepEqual(got, ['AGNES_API_KEY', 'AGNES_BASE_URL']);
  });

  test('默认表是一份**常量**，且逐条就是这几个前缀（少一条 = 把功能修坏）', () => {
    assert.ok(Array.isArray(shim.DEFAULT_ENV_PASSTHROUGH));
    // ⚠️ 这里从「length >= 4」改成**逐条列明**：
    //   * 长度不是重点，"放行了哪几个前缀"才是 —— 数字断言既挡不住少放一个
    //     必需前缀（3 个也可能 >= 3），也说不清该有哪几个；
    //   * 「打开本机应用」取消后 `DSH_DEVICE_` 已移除，所以现在是三个。
    //   改这张表时**必须一起改这条** —— 那一步就是你的确认动作。
    assert.deepEqual(
      [...shim.DEFAULT_ENV_PASSTHROUGH].sort(),
      ['AGNES_', 'DSH_ANDROID_', 'LOCAL_'],
      '默认环境白名单与预期不一致（改功能时请同步这条断言）',
    );
  });
}

// ─────────────────────────────────────────── P0-3：轮换代理的客户端鉴权

section('P0-3 轮换代理：必须有客户端令牌，且比对是等时的');
const PROXY = join(REPO, 'app/assets/toolbox/rotate-proxy.mjs');
const ZEN = join(REPO, 'app/assets/toolbox/zen-proxy.mjs');
const BACKUP = join(REPO, 'app/assets/toolbox/backup.mjs');
const VERIFY_RT = join(REPO, 'install/verify-runtime.mjs');
{
  const proxy = await import(PROXY);

  test('constantTimeEqual：相同为真、不同为假、长度无关不抛', () => {
    assert.equal(proxy.constantTimeEqual('abc', 'abc'), true);
    assert.equal(proxy.constantTimeEqual('abc', 'abd'), false);
    assert.equal(proxy.constantTimeEqual('abc', 'abcdefgh'), false);
    assert.equal(proxy.constantTimeEqual('', ''), true);
    assert.equal(proxy.constantTimeEqual('x', ''), false);
  });

  test('clientToken：认 Authorization: Bearer 与 x-api-key', () => {
    assert.equal(proxy.clientToken({ headers: { authorization: 'Bearer t0k' } }), 't0k');
    assert.equal(proxy.clientToken({ headers: { authorization: 'bearer t0k' } }), 't0k');
    assert.equal(proxy.clientToken({ headers: { 'x-api-key': 't0k' } }), 't0k');
    assert.equal(proxy.clientToken({ headers: { authorization: 'Basic zzz' } }), '');
    assert.equal(proxy.clientToken({ headers: {} }), '');
  });

  test('parseArgs：--config-stdin 与 --port 0 的解析', () => {
    const a = proxy.parseArgsForTest(['--config-stdin', '--port', '0']);
    assert.equal(a.configStdin, true);
    assert.equal(a.port, 0);
    const b = proxy.parseArgsForTest(['c.json', '--state', 's.json', '--port=8080']);
    assert.equal(b.config, 'c.json');
    assert.equal(b.state, 's.json');
    assert.equal(b.port, 8080);
  });

  // ⚠️ 参数错误不能在**进程内**测：`die()` 会 `process.exit()`，会把测试进程自己
  // 杀掉（第一版就是这么把整套测试截断的）。所以走子进程，顺便把真实退出码也钉住。
  await testAsync('参数/配置错误的退出码：2（参数）、3（没令牌）', async () => {
    const run = (args, stdin) =>
      new Promise((res) => {
        const c = spawn(process.execPath, [PROXY, ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
        let err = '';
        c.stderr.on('data', (d) => { err += d.toString(); });
        if (stdin !== undefined) c.stdin.write(stdin);
        c.stdin.end();
        c.on('exit', (code) => res({ code, err }));
      });

    assert.equal((await run(['--config-stdin', 'x.json'])).code, 2, '既给 stdin 又给文件名');
    assert.equal((await run([])).code, 2, '什么都没给');
    assert.equal((await run(['c.json', '--port', '-1'])).code, 2, '端口为负');
    assert.equal((await run(['/nonexistent/nope.json'])).code, 2, '配置文件不存在');
    // 配置给了但没有 token、也没 --no-auth → 3（失败安全）
    const noTok = await run(
      ['--config-stdin', '--port', '0'],
      JSON.stringify({ groups: { cat: { members: [{ baseUrl: 'https://x/v1', model: 'm' }] } } }),
    );
    assert.equal(noTok.code, 3, `没令牌应该以 3 退出；stderr=${noTok.err}`);
  });

  test('validateConfig：token 从配置里读出来', () => {
    const cfg = proxy.validateConfig(
      JSON.stringify({
        token: 'the-token',
        groups: { cat: { members: [{ baseUrl: 'https://x/v1', model: 'm' }] } },
      }),
      '测试配置',
    );
    assert.equal(cfg.token, 'the-token');
    assert.equal(cfg.groups.cat.members[0].name, 'member1');
  });

  await testAsync('端到端：带对令牌 200 且能转发；不带/带错令牌 401', async () => {
    // 一个假的"上游"：只要被调到就回 200 + 固定 JSON。
    const https = await import('node:http');
    let upstreamHits = 0;
    const upstream = https.createServer((req, res) => {
      upstreamHits += 1;
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, model: 'upstream' }));
    });
    await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
    const upPort = upstream.address().port;

    const TOKEN = 'tok-' + Math.random().toString(16).slice(2);
    const dir = mkdtempSync(join(tmpdir(), 'rotate-'));
    const statePath = join(dir, 'state.json');
    const cfgJson = JSON.stringify({
      token: TOKEN,
      groups: {
        cat: {
          members: [
            { name: 'a', baseUrl: `http://127.0.0.1:${upPort}/v1`, apiKey: 'up-key', model: 'm' },
          ],
        },
      },
    });

    const child = spawn(
      process.execPath,
      [PROXY, '--config-stdin', '--state', statePath, '--port', '0'],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    );
    child.stdin.write(cfgJson);
    child.stdin.end();

    let out = '';
    let err = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    child.stderr.on('data', (d) => { err += d.toString(); });

    // 等就绪行里的真实端口（这就是 Dart 侧做的事）
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error(`代理没就绪；stdout=${out} stderr=${err}`)), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); }
        else setTimeout(check, 50);
      };
      check();
    });

    assert.ok(port > 0, '真实端口应该是系统挑的（不是 argv 里的 0）');

    const call = (headers) =>
      fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...headers },
        body: JSON.stringify({ model: 'cat', messages: [{ role: 'user', content: 'hi' }] }),
      });

    try {
      const noTok = await call({});
      assert.equal(noTok.status, 401, '不带令牌必须是 401');
      assert.equal(upstreamHits, 0, '未授权请求绝不能打到上游（那是花用户的 Key）');

      const badTok = await call({ authorization: 'Bearer wrong-token' });
      assert.equal(badTok.status, 401, '错令牌必须是 401');
      assert.equal(upstreamHits, 0);

      const ok = await call({ authorization: `Bearer ${TOKEN}` });
      assert.equal(ok.status, 200, `带对令牌应该 200；body=${await ok.text()}`);
      assert.equal(upstreamHits, 1, '带对令牌必须真的转发');

      // x-api-key 这条也要通（DSH 万一用那个头）
      const ok2 = await call({ 'x-api-key': TOKEN });
      assert.equal(ok2.status, 200);
      assert.equal(upstreamHits, 2);

      // /health 也要令牌 —— 否则它就是一个"免费探测这个端口是不是轮换代理"的信号
      const health = await fetch(`http://127.0.0.1:${port}/health`);
      assert.equal(health.status, 401, '/health 也必须鉴权');
    } finally {
      child.kill('SIGKILL');
      upstream.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  await testAsync('没有令牌又没 --no-auth：拒绝启动（失败安全，不能静默裸奔）', async () => {
    const child = spawn(process.execPath, [PROXY, '--config-stdin', '--port', '0'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.stdin.write(JSON.stringify({
      groups: { cat: { members: [{ baseUrl: 'https://x/v1', model: 'm' }] } },
    }));
    child.stdin.end();
    let err = '';
    child.stderr.on('data', (d) => { err += d.toString(); });
    const code = await new Promise((r) => child.on('exit', r));
    assert.equal(code, 3, `应该以 3 退出；stderr=${err}`);
    assert.match(err, /令牌/, '错误信息要讲清"没令牌"这件事');
  });

  await testAsync('--token 作为兜底通路仍然可用（虽然不推荐：会进 cmdline）', async () => {
    const child = spawn(process.execPath, [PROXY, '--config-stdin', '--token', 'from-argv', '--port', '0'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.stdin.write(JSON.stringify({
      groups: { cat: { members: [{ baseUrl: 'https://x/v1', model: 'm' }] } },
    }));
    child.stdin.end();
    let out = '';
    child.stderr.on('data', () => {});
    child.stdout.on('data', (d) => { out += d.toString(); });
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('没就绪')), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); } else setTimeout(check, 50);
      };
      check();
    });
    try {
      const bad = await fetch(`http://127.0.0.1:${port}/health`);
      assert.equal(bad.status, 401);
      const good = await fetch(`http://127.0.0.1:${port}/health`, {
        headers: { authorization: 'Bearer from-argv' },
      });
      assert.equal(good.status, 200);
    } finally {
      child.kill('SIGKILL');
    }
  });

  await testAsync('--no-auth：显式关掉鉴权（调试通路），请求能通', async () => {
    const http = await import('node:http');
    const upstream = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
    await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
    const upPort = upstream.address().port;

    const child = spawn(process.execPath, [PROXY, '--config-stdin', '--no-auth', '--port', '0'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.stdin.write(JSON.stringify({
      groups: { cat: { members: [{ name: 'a', baseUrl: `http://127.0.0.1:${upPort}/v1`, model: 'm' }] } },
    }));
    child.stdin.end();
    let out = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('没就绪')), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); } else setTimeout(check, 50);
      };
      check();
    });
    try {
      const r = await fetch(`http://127.0.0.1:${port}/health`);
      assert.equal(r.status, 200);
    } finally {
      child.kill('SIGKILL');
      upstream.close();
    }
  });

  // ── 空组不能连坐（2026-10-31 用户报：「轮换池中间有无法使用的模型会造成
  //    整个轮换池无法使用」）。
  //
  //    根因：Dart 侧把"所有成员都不可用"的组以 `members: []` 下发（成员模型被
  //    上游收回、厂家被删、本机服务没在跑…），而代理以前对空组直接
  //    `die()` → `process.exit(2)` → **整份配置被拒、所有组一起挂**。
  //    换句话说：坏的那一组不是自己坏，它把好的也带走了。
  //
  //    这两条测试分别钉「跳过而不是退出」和「好的那组真的还能用」——
  //    后者是关键：只断言进程不退出不够，得证明它还能服务。
  test('validateConfig：空组被跳过，其它组原样保留', () => {
    const cfg = proxy.validateConfig(
      JSON.stringify({
        token: 't',
        groups: {
          empty: { members: [] },
          ok: { members: [{ name: 'a', baseUrl: 'https://x/v1', model: 'm' }] },
        },
      }),
      '测试配置',
    );
    assert.equal(cfg.groups.empty, undefined, '空组应该被剔除，而不是让整个进程退出');
    assert.ok(cfg.groups.ok && cfg.groups.ok.members.length === 1, '其它组必须原样保留');
  });

  await testAsync('空组存在时，其它组仍能正常对话（整池不再连坐）', async () => {
    const http = await import('node:http');
    const upstream = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, from: 'upstream' }));
    });
    await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
    const upPort = upstream.address().port;

    const child = spawn(process.execPath, [PROXY, '--config-stdin', '--no-auth', '--port', '0'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.stdin.write(JSON.stringify({
      groups: {
        // ← 那个"无法使用的模型"留下的空组
        empty: { members: [] },
        ok: { members: [{ name: 'a', baseUrl: `http://127.0.0.1:${upPort}/v1`, model: 'm' }] },
      },
    }));
    child.stdin.end();
    let out = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('代理没就绪 —— 空组大概又把进程带崩了')), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); } else setTimeout(check, 50);
      };
      check();
    });
    try {
      const r = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ model: 'ok', messages: [{ role: 'user', content: 'hi' }] }),
      });
      assert.equal(r.status, 200, '好的那个组必须仍能成功（这才叫不连坐）');
      assert.equal(child.exitCode, null, '代理进程必须还活着');
    } finally {
      child.kill('SIGKILL');
      upstream.close();
    }
  });

  // ── 按 body 形状判流式（2026-10-31）──
  //
  // 上游高负载时会用 `application/json` 的 header 回一整个 SSE 帧序列。
  // 照抄 header 就会让下游按 JSON 解析 → 整轮失败，而且失败得极像"模型坏了"，
  // 还可能把这个本来好好的模型标成不可用。
  //
  // 这条测试故意起一个**说谎**的假上游，验证两件事：
  //   ① 代理把 content-type 纠正成 text/event-stream；
  //   ② **首块没丢** —— 嗅探读走的那一块必须补发出去（这是最容易写错的地方）。
  await testAsync('上游把 SSE 说成 application/json 时，代理按形状纠正且首块不丢', async () => {
    const http = await import('node:http');
    const frames = [
      'data: {"id":"1","choices":[{"delta":{"content":"你好"}}]}\n\n',
      'data: {"id":"1","choices":[{"delta":{"content":"世界"}}]}\n\n',
      'data: [DONE]\n\n',
    ].join('');
    const upstream = http.createServer((req, res) => {
      req.on('data', () => {});
      req.on('end', () => {
        // ⚠️ 关键：header 故意写错成 application/json
        res.writeHead(200, { 'content-type': 'application/json' });
        // 分两次写 —— 第一块正好是嗅探会读走的那块
        res.write(frames.slice(0, 24));
        setTimeout(() => {
          res.write(frames.slice(24));
          res.end();
        }, 30);
      });
    });
    await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
    const upPort = upstream.address().port;

    const child = spawn(process.execPath,
      [ZEN, '--port', '0', '--upstream', `http://127.0.0.1:${upPort}`],
      { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('zen-proxy 没就绪')), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); } else setTimeout(check, 50);
      };
      check();
    });
    try {
      const r = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ model: 'x', messages: [{ role: 'user', content: 'hi' }] }),
      });
      const ct = r.headers.get('content-type') || '';
      const text = await r.text();
      assert.match(ct, /event-stream/,
          `content-type 应该被纠正成 SSE，实际：${ct}`);
      assert.equal(text, frames,
          'body 必须完整 —— 嗅探读走的那块要补发，否则每轮都会丢掉开头');
    } finally {
      child.kill('SIGKILL');
      upstream.close();
    }
  });

  // ── 两条上游靠路径分流（2026-10-31 接入 Kilo）──
  //
  // 两个上游共用一个本地端口：`/v1/*` 走 Zen、`/kilo/v1/*` 走 Kilo。
  // 这条测试用两个**行为不同**的假上游，验证：路径真的分开了、
  // 各自的过滤规则各自生效、一条出错不会串到另一条。
  await testAsync('两条上游靠路径分流：/v1 与 /kilo/v1 互不串台', async () => {
    const http = await import('node:http');
    // Zen 上游：它的免费判定是"名字里含 free"
    const zenUp = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: [
        { id: 'mimo-v2.6-flash-free' },
        { id: 'some-paid-model' },
      ] }));
    });
    await new Promise((r) => zenUp.listen(0, '127.0.0.1', r));
    // Kilo 上游：它的免费判定是 `isFree === true`
    const kiloUp = http.createServer((req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: [
        { id: 'dots-studio/dots-3-note-preview:free', isFree: true },
        { id: 'expensive/model', isFree: false },
      ] }));
    });
    await new Promise((r) => kiloUp.listen(0, '127.0.0.1', r));

    const child = spawn(process.execPath, [
      ZEN, '--port', '0',
      '--upstream', `http://127.0.0.1:${zenUp.address().port}`,
      '--kilo-upstream', `http://127.0.0.1:${kiloUp.address().port}`,
    ], { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('zen-proxy 没就绪')), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); } else setTimeout(check, 50);
      };
      check();
    });
    try {
      const z = await (await fetch(`http://127.0.0.1:${port}/v1/models`)).json();
      const k = await (await fetch(`http://127.0.0.1:${port}/kilo/v1/models`)).json();
      assert.deepEqual(z.data.map((m) => m.id), ['mimo-v2.6-flash-free'],
          'Zen 那条只该列名字含 free 的');
      assert.deepEqual(k.data.map((m) => m.id), ['dots-studio/dots-3-note-preview:free'],
          'Kilo 那条只该列 isFree=true 的（而且 id 原样保留）');
      assert.equal(k.data[0].owned_by, 'kilo', 'kilo 组的 owned_by 要能区分出来');
    } finally {
      child.kill('SIGKILL');
      zenUp.close();
      kiloUp.close();
    }
  });

  // ── 非流式整块响应不能卡死（2026-11-01 真机抓到的坑）──
  //
  // OVHcloud 这类非流式上游：模型要几秒才吐第一块，然后**整个 JSON 一次到齐**。
  // 嗅探（sniffFirst）的 read() 会把这一整块读走、流随即 end；若之后还去等 `end`
  // 事件，它已经在嗅探期间 fire 过了 → 新监听永远等不到 → 下游 curl 拿到 0 字节
  // 且挂死。修法是嗅探后检查 `r.readableEnded`，已结束就直接收尾。
  //
  // 这条测试用一个"延迟后一次性回整块 JSON"的假上游钉住它：修之前会挂到超时，
  // 修之后必须拿到完整 body。
  await testAsync('非流式整块响应：嗅探读走后不能卡死（readableEnded 收尾）', async () => {
    const http = await import('node:http');
    const payload = JSON.stringify({
      id: 'chatcmpl-x', object: 'chat.completion',
      choices: [{ index: 0, message: { role: 'assistant', content: '通了' }, finish_reason: 'stop' }],
    });
    // 延迟 1.5 秒（超过嗅探窗口 1200ms）后一次性回整块 —— 复刻 OVH 的形状。
    const up = http.createServer((req, res) => {
      req.on('data', () => {});
      req.on('end', () => {
        setTimeout(() => {
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end(payload);
        }, 1500);
      });
    });
    await new Promise((r) => up.listen(0, '127.0.0.1', r));

    const child = spawn(process.execPath,
      [ZEN, '--port', '0', '--ovh-upstream', `http://127.0.0.1:${up.address().port}`],
      { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('zen-proxy 没就绪')), 10000);
      const check = () => {
        const m = /listening on http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
        if (m) { clearTimeout(t); res(Number(m[1])); } else setTimeout(check, 50);
      };
      check();
    });
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 8000);
      const r = await fetch(`http://127.0.0.1:${port}/ovh/v1/chat/completions`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ model: 'm', messages: [{ role: 'user', content: 'hi' }] }),
        signal: ctrl.signal,
      });
      const text = await r.text();
      clearTimeout(timer);
      assert.equal(text, payload,
          '整块响应必须完整转发 —— 修之前这里会挂到 8 秒超时（拿到空 body）');
      const j = JSON.parse(text);
      assert.equal(j.choices[0].message.content, '通了');
    } finally {
      child.kill('SIGKILL');
      up.close();
    }
  });

  // ── 换机迁移的备份包（2026-10-31）──
  //
  // 这套东西的责任比看起来重：它要把用户的**全部聊天记录**变成一个文件，
  // 而这个文件会经过网盘、微信、数据线 —— 任何一环都可能被人看到。
  // 所以下面五条守的是"别人拿不到 / 拿不到半份 / 写不到别处去"。
  const runBackup = (args, password) => new Promise((resolve) => {
    const child = spawn(process.execPath, [BACKUP, ...args], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    child.stderr.on('data', (d) => { err += d.toString(); });
    child.stdin.write(password + '\n');
    child.stdin.end();
    child.on('close', (code) => resolve({ code, out, err }));
  });

  const seedBackupRoot = () => {
    const dir = mkdtempSync(join(tmpdir(), 'pcbak-'));
    mkdirSync(join(dir, 'sessions', 's1'), { recursive: true });
    mkdirSync(join(dir, 'workspace'), { recursive: true });
    mkdirSync(join(dir, 'dsh'), { recursive: true });
    writeFileSync(join(dir, 'sessions', 's1', 'session.v4.jsonl'), 'hello session');
    writeFileSync(join(dir, 'workspace', 'report.md'), '我的文档');
    writeFileSync(join(dir, 'models.json'), '{"v":1}');
    // 这两个**必须不被迁移**
    writeFileSync(join(dir, 'dsh', 'runtime.bin'), 'x'.repeat(100));
    writeFileSync(join(dir, 'bridge.json'), '{"token":"secret"}');
    return dir;
  };

  await testAsync('备份包：打包 → 查看 → 还原，内容逐字节一致', async () => {
    const src = seedBackupRoot();
    const out = join(src, 'out.pcbak');
    const packed = await runBackup(['pack', '--root', src, '--out', out], 'pass12345');
    assert.equal(packed.code, 0, `打包失败：${packed.err}`);

    const info = await runBackup(['list', '--in', out], 'pass12345');
    assert.equal(info.code, 0, `读取失败：${info.err}`);
    const m = JSON.parse(info.out.trim());
    // sessions 下 1 个 + workspace 下 1 个 + models.json = 3（dsh/ 与 bridge.json 不迁）
    assert.equal(m.files, 3, `应该只打 3 个文件，实际 ${m.files}`);

    const dst = mkdtempSync(join(tmpdir(), 'pcbak-dst-'));
    const un = await runBackup(['unpack', '--in', out, '--root', dst], 'pass12345');
    assert.equal(un.code, 0, `还原失败：${un.err}`);
    assert.equal(readFileSync(join(dst, 'workspace', 'report.md'), 'utf8'), '我的文档');
    assert.equal(readFileSync(join(dst, 'sessions', 's1', 'session.v4.jsonl'), 'utf8'), 'hello session');
    // 不该被还原出来的东西
    assert.equal(existsSync(join(dst, 'dsh', 'runtime.bin')), false, '运行时文件不该进备份包');
    assert.equal(existsSync(join(dst, 'bridge.json')), false, '桌面平台口令不该进备份包');
  });

  await testAsync('备份包：密码不对拒绝打开', async () => {
    const src = seedBackupRoot();
    const out = join(src, 'out.pcbak');
    await runBackup(['pack', '--root', src, '--out', out], 'pass12345');
    const bad = await runBackup(['list', '--in', out], 'wrongpass');
    assert.equal(bad.code, 2, '错密码必须以非 0 退出');
    assert.match(bad.err, /密码不对|损坏/, `报错要说得清楚，实际：${bad.err}`);
  });

  await testAsync('备份包：被改一个字节就拒绝（GCM 完整性校验）', async () => {
    const src = seedBackupRoot();
    const out = join(src, 'out.pcbak');
    await runBackup(['pack', '--root', src, '--out', out], 'pass12345');
    const buf = readFileSync(out);
    buf[60] ^= 0xff; // 改动密文区一个字节
    const tampered = join(src, 'tampered.pcbak');
    writeFileSync(tampered, buf);
    const r = await runBackup(['list', '--in', tampered], 'pass12345');
    assert.equal(r.code, 2, '篡改过的包不能通过');
    assert.match(r.err, /密码不对|损坏/);
  });

  await testAsync('备份包：拒绝目录穿越（包内写 ../ 不能逃出目标目录）', async () => {
    // 手工造一个恶意包：名字里带 ../
    const { randomBytes, scryptSync, createCipheriv } = await import('node:crypto');
    const oz = await import(join(REPO, 'app/assets/toolbox/office-zip.mjs'));
    const manifest = { v: 1, kind: 'paopaocat-backup', createdAt: new Date().toISOString(), files: [], skipped: [] };
    const zip = oz.zipWrite([
      ['manifest.json', Buffer.from(JSON.stringify(manifest))],
      ['../evil.txt', Buffer.from('pwned')],
      ['ok.txt', Buffer.from('legit')],
    ]);
    const salt = randomBytes(16);
    const iv = randomBytes(12);
    const key = scryptSync('pass12345', salt, 32);
    const c = createCipheriv('aes-256-gcm', key, iv);
    const body = Buffer.concat([c.update(zip), c.final()]);
    const dir = mkdtempSync(join(tmpdir(), 'pcbak-evil-'));
    const evil = join(dir, 'evil.pcbak');
    writeFileSync(evil, Buffer.concat([Buffer.from('PCB1'), salt, iv, c.getAuthTag(), body]));

    const dst = mkdtempSync(join(tmpdir(), 'pcbak-safe-'));
    const r = await runBackup(['unpack', '--in', evil, '--root', dst], 'pass12345');
    assert.equal(r.code, 0);
    assert.equal(existsSync(join(dir, 'evil.txt')), false,
        '绝不能写到目标目录外面去（这是解压类功能最经典的洞）');
    assert.equal(existsSync(join(dst, 'ok.txt')), true, '正常文件仍要能还原');
  });

  await testAsync('备份包：选错文件时报错说人话', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'pcbak-not-'));
    const notOurs = join(dir, 'random.bin');
    writeFileSync(notOurs, Buffer.from('this is not a backup file at all'));
    const r = await runBackup(['list', '--in', notOurs], 'pass12345');
    assert.equal(r.code, 2);
    assert.match(r.err, /不是泡泡猫的备份包|太小/, `报错要能指导用户，实际：${r.err}`);
  });

  // ── 出包前的 runtime 体检（2026-11-01 加，防再把桌面版打进 Android 包）──
  //
  // 曾把 __migr 里那份 151MB 桌面完整安装（含 730 条 Windows LibreOffice）当
  // Android runtime 用，编出 238MB 的包（正确 ~118MB）。桌面包和 slim 包内核版本
  // 一样，光看版本号拦不住 —— 所以脚本按「体积 / win32 / anysearch」三条硬判。
  // 这条测试用 Python 现造三种 zip（正确 / 含 win32 / 缺 anysearch），钉住判定。
  await testAsync('verify-runtime：正确包通过，含 win32 / 缺 anysearch 的被拦', async () => {
    const { execFileSync } = await import('node:child_process');
    const makeZip = (path, entries) => {
      // 用 python 的 zipfile 造（Node 侧没有现成 zip 写库，见 backup.mjs 同理，但这里
      // 只为造测试夹具，直接借 python 最省事）。
      const py = `
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    for name in ${JSON.stringify(entries)}:
        z.writestr(name, b'x')
`;
      execFileSync('python3', ['-c', py, path], { stdio: 'ignore' });
    };
    const run = (zip) => {
      try {
        const out = execFileSync(process.execPath, [VERIFY_RT, zip], {
          encoding: 'utf8',
        });
        return { code: 0, out };
      } catch (e) {
        return { code: e.status, out: (e.stderr || '') + (e.stdout || '') };
      }
    };
    const dir = mkdtempSync(join(tmpdir(), 'vrt-'));

    // ① 正确：含 anysearch、无 win32、体积小 → 通过
    const good = join(dir, 'good.zip');
    makeZip(good, ['app/x.js', 'app/node_modules/@deepseek-ai/dsh-web-search-anysearch/lib/index.js']);
    const g = run(good);
    assert.equal(g.code, 0, `正确包应该通过，实际：${g.out}`);

    // ② 含 win32 libreoffice → 拦
    const bad = join(dir, 'bad.zip');
    makeZip(bad, ['app/node_modules/@deepseek-ai/libreoffice-kit-win32-x64/bin/soffice.exe',
                  'app/node_modules/@deepseek-ai/dsh-web-search-anysearch/lib/index.js']);
    const b = run(bad);
    assert.notEqual(b.code, 0, '含 win32 libreoffice 的包应该被拦');
    assert.match(b.out, /win32 libreoffice/, `报错要点名 win32，实际：${b.out}`);

    // ③ 缺 anysearch → 拦
    const noAny = join(dir, 'noany.zip');
    makeZip(noAny, ['app/x.js']);
    const n = run(noAny);
    assert.notEqual(n.code, 0, '缺 anysearch 的包应该被拦');
    assert.match(n.out, /anysearch/, `报错要提 anysearch，实际：${n.out}`);
  });

  await testAsync('lastGood 只写状态文件，且**不含任何凭据**', async () => {
    const cfg = proxy.validateConfig(
      JSON.stringify({
        token: 't',
        groups: { cat: { members: [{ name: 'a', baseUrl: 'https://x/v1', model: 'm', apiKey: 'SECRET' }] } },
      }),
      '测试配置',
    );
    const dir = mkdtempSync(join(tmpdir(), 'rotate-state-'));
    cfg.statePath = join(dir, 'state.json');
    try {
      const sticky = proxy.makeSticky(cfg);
      sticky.set('cat', 0);
      const raw = readFileSync(cfg.statePath, 'utf8');
      assert.ok(!raw.includes('SECRET'), 'lastGood 状态文件里不该出现凭据');
      assert.ok(!raw.includes('https://x/v1'), 'lastGood 状态文件里不该出现配置');
      assert.deepEqual(JSON.parse(raw), { lastGood: { cat: 0 } });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // 守住"凭据不落盘"这条。注意**不能**简单搜 "rotate-config.json" ——
  // 那个名字还留着（注释里在解释"为什么不能写它"），搜它只会误报。
  // 这里断言的是**那次回归的精确形状**：旧的回写逻辑是把**整份 config**
  // （含各厂家真实 Key）读出来改个字段再写回去（`JSON.stringify(raw, ...)`）。
  test('代理源码不再把整份 config 回写（那次凭据落盘的形状）', () => {
    const src = readFileSync(PROXY, 'utf8');
    assert.ok(
      !/JSON\.stringify\(raw/.test(src),
      '又把整份配置写回磁盘了？Key 会落盘（P0-2 回归）',
    );
    assert.ok(/createHash|timingSafeEqual/.test(src), '等时比对不见了？（P0-3 回归）');
    assert.ok(/statePath/.test(src), 'lastGood 应该写到不含凭据的 statePath');
  });
}

// ─────────────────────────────── ffmpeg：prelude 里的 shell 函数（可选能力）

section('ffmpeg / ffprobe：shim 的 prelude 与"缺了不许拖累别的"');
{
  const shimPath = join(REPO, 'app/assets/toolbox/android-exec-shim.cjs');
  const SHIM_ENV = {
    DSH_ANDROID_NODE_BIN: '/data/app/lib/libnode.so',
    DSH_ANDROID_FS_SHIM: '/data/files/shims/android-fs-shim.cjs',
    DSH_ANDROID_EXEC_SHIM: '/data/files/toolbox/android-exec-shim.cjs',
    DSH_ANDROID_TMPDIR: '/data/files/tmp',
  };

  /** CFG 是"require 时"从 process.env 抓的，所以换环境必须清缓存重 require。 */
  function shimWith(env) {
    const saved = { ...process.env };
    for (const k of Object.keys(process.env)) delete process.env[k];
    Object.assign(process.env, env);
    try {
      delete require.cache[require.resolve(shimPath)];
      return require(shimPath);
    } finally {
      for (const k of Object.keys(process.env)) delete process.env[k];
      Object.assign(process.env, saved);
    }
  }

  await test('打进包了：prelude 定义 ffmpeg()/ffprobe() 并导出变量', () => {
    const shim = shimWith({
      ...SHIM_ENV,
      DSH_ANDROID_FFMPEG: '/data/app/lib/libffmpeg.so',
      DSH_ANDROID_FFPROBE: '/data/app/lib/libffprobe.so',
    });
    const pre = shim.buildPrelude();
    assert.match(pre, /ffmpeg\(\) \{ "\$DSH_ANDROID_FFMPEG" "\$@"; \}/,
      'prelude 必须定义 ffmpeg 函数 —— 技能脚本里直接写 `ffmpeg -i` 就走它');
    assert.match(pre, /ffprobe\(\) \{ "\$DSH_ANDROID_FFPROBE" "\$@"; \}/);
    assert.ok(pre.includes("DSH_ANDROID_FFMPEG='/data/app/lib/libffmpeg.so'"),
      '要导出绝对路径（认变量的代码用它）');
    assert.ok(pre.includes("AGNES_FFMPEG='/data/app/lib/libffmpeg.so'"),
      'AGNES_FFMPEG 是桌面插件认的名字，两边对齐');
  });

  await test('⚠️ 没打进包时：变量导出成空串，运行时不定义函数 —— 且**绝不许**把 shim 关掉', () => {
    const shim = shimWith(SHIM_ENV); // 故意不给 ffmpeg 变量
    assert.equal(shim.isActive(), true,
      'ffmpeg 是可选能力，缺了绝不能让 node 的改写也失效（那是最糟的连锁反应）');
    const pre = shim.buildPrelude();
    // 函数那行**带 `-n` 守卫**（`if [ -n "$DSH_ANDROID_FFMPEG" ]; then ffmpeg() …`）：
    // 文本总在，运行时才决定是否真的定义 —— 与 prelude 里 TMPDIR 那条同一个写法。
    assert.ok(pre.includes("DSH_ANDROID_FFMPEG=''"),
      '没打进包时变量必须是空串，守卫才不会定义函数（否则等于给一个指向空气的命令）');
    assert.match(pre, /if \[ -n "\$DSH_ANDROID_FFMPEG" \]; then ffmpeg\(\)/,
      '必须是"有才定义"的守卫形式，不是无条件定义');
  });

  await test('ffmpeg 变量随「改写后的命令 env」传下去（嵌套 shell 里函数还在）', () => {
    const shim = shimWith({
      ...SHIM_ENV,
      DSH_ANDROID_FFMPEG: '/data/app/lib/libffmpeg.so',
      DSH_ANDROID_FFPROBE: '/data/app/lib/libffprobe.so',
    });
    // shell:true 形态（DSH 的 bash 工具就是这条）会把 prelude + dshEnv 一起给出去
    const r = shim.rewriteCommand('bash -c "ffmpeg -version"', [], { shell: true });
    assert.ok(r, '应该被改写');
    assert.equal(r.env.DSH_ANDROID_FFMPEG, '/data/app/lib/libffmpeg.so');
    assert.equal(r.env.DSH_ANDROID_FFPROBE, '/data/app/lib/libffprobe.so');
  });
}

// ═══════════════════════════════════════════════════════════ 每个脚本的语法都得是好的

section('工具箱脚本：语法自检（node --check）');
{
  // ## 为什么要这一条（2026-10-11 的真实事故）
  //
  // 我给 `make-video.mjs` 的 `--help` 文本里加了一句带**反引号**的说明 ——
  // 而那段 help 本身就是**模板字符串**（反引号包的），于是反引号提前把字符串
  // 截断，整个脚本语法坏掉：手机上"生视频"会直接起不来。
  //
  // ⚠️ 当时 `flutter analyze` 全绿、**所有 Dart 测试全绿**（它们跑不到 node 脚本），
  // 只有 `install/test-agnes-429.mjs` 因为恰好 import 了这个脚本才炸出来。
  // 所以这里对**目录里每一个 .mjs** 都做一次 `node --check`：
  // 语法错在上手机之前就当场红，而不是等用户点了"生成视频"。
  const dir = join(REPO, 'app', 'assets', 'toolbox');
  const scripts = readdirSync(dir).filter((f) => f.endsWith('.mjs')).sort();
  assert.ok(scripts.length >= 6,
      `工具箱里应该有不少脚本，只找到 ${scripts.length} 个 —— 路径可能不对：${dir}`);
  for (const f of scripts) {
    test(`${f} 语法正确（node --check）`, () => {
      const r = spawnSync(process.execPath, ['--check', join(dir, f)], { encoding: 'utf8' });
      assert.equal(r.status, 0,
          `${f} 语法坏了：\n${(r.stderr || '').split('\n').slice(0, 6).join('\n')}`);
    });
  }
}

// ──────────────────────────────────────────────────────────────── 汇总

console.log(`\n${'='.repeat(64)}`);
if (failures.length) {
  console.log(`失败 ${failures.length} 项 / 通过 ${passed} 项`);
  for (const [name] of failures) console.log(`  · ${name}`);
  process.exit(1);
}
console.log(`全部通过（${passed} 项）`);
