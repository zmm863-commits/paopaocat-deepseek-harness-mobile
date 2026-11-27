#!/usr/bin/env node
/**
 * toolbox-entry-probe.mjs —— 验证 toolbox 里那几个脚本**不会静默退出 0**。
 *
 * ## 为什么要这个探针
 *
 * 真机现场（2026-11-27 之前的每一份 dsh-report 里都有）：
 *
 *     [dsh-mcp] 探活失败：node 提前退出 exit=0 | 脚本=25821B | stderr=(空)
 *     [acp]    … 会话照常，只是少了 Office 三件套工具
 *
 * 根因不是 node、不是环境变量、更不是脚本内容，而是每个脚本最后那句
 *
 *     const isDirectRun = process.argv[1]
 *       && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
 *
 * —— 只要 `argv[1]` 与真实路径有细微差别（realpath / 软链 / 前缀不同），
 * 就判成「被 import 进来」，于是 main()/serveStdio() **根本不执行**，
 * 进程什么都不做、exit 0、两路零输出。make-pptx 在 2026-10-20 已经改成
 * 「文件名兜底 + 判不出来就大声报错」，另外四个（mcp-office / make-docx /
 * make-xlsx / read-xlsx）一直没跟上。
 *
 * ## 这个探针怎么判
 *
 * 把 toolbox 复制到临时目录、再用**软链**去调用（复现真机那条路径差异），然后：
 *   * **不能**出现「exit 0 且 stdout/stderr 全空」——那就是这次事故的签名；
 *   * mcp-office 还必须能完整应答 MCP 的 `initialize` + `tools/list`（3 个工具）；
 *   * mcp-office `--selftest` 必须打印 `selftest ok`。
 *
 * 跑法：`node probes/toolbox-entry-probe.mjs` —— 全绿退出 0，任何一条 FAIL 退出 1。
 */

import { spawn } from 'node:child_process';
import { copyFileSync, mkdtempSync, readdirSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const toolboxDir = join(here, '..', 'app', 'assets', 'toolbox');

let failed = 0;
function check(label, ok, detail = '') {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` → ${detail}` : ''}`);
  if (!ok) failed += 1;
}

/** 跑一个脚本：返回 {code, stdout, stderr}。stdin 可选喂内容。 */
function run(scriptPath, args = [], stdinText = null, timeoutMs = 8000, cwd = process.cwd()) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [scriptPath, ...args], {
      stdio: ['pipe', 'pipe', 'pipe'],
      // cwd 固定到临时目录：mcp-office --selftest 会往当前目录写
      // `.mcp-office-selftest/selftest.docx|xlsx`，在仓库里跑会留下垃圾。
      cwd,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (b) => {
      stdout += b.toString();
    });
    child.stderr.on('data', (b) => {
      stderr += b.toString();
    });
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
    }, timeoutMs);
    if (stdinText !== null) child.stdin.write(stdinText);
    child.stdin.end();
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

const work = mkdtempSync(join(tmpdir(), 'toolbox-entry-probe-'));
try {
  // 复制整个 toolbox（脚本之间会互相 import），再用软链访问 —— 复现真机上的路径差异
  const real = join(work, 'real');
  const link = join(work, 'link');
  const { mkdirSync } = await import('node:fs');
  mkdirSync(real, { recursive: true });
  for (const f of readdirSync(toolboxDir)) {
    if (f.endsWith('.mjs')) copyFileSync(join(toolboxDir, f), join(real, f));
  }
  symlinkSync(real, link);

  // ── 1) mcp-office：完整 MCP 握手（这条是真机上唯一用得着它的路径）
  const handshake = [
    JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'probe', version: '1' },
      },
    }),
    JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
    JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }),
    '',
  ].join('\n');

  const mcp = await run(join(link, 'mcp-office.mjs'), [], handshake, 8000, work);
  const mcpTools = (mcp.stdout.match(/"name":"office_[a-z_]+"/g) || []).length;
  check(
    'mcp-office（经软链路径）能被 MCP 客户端拉起',
    mcp.code === 0 && mcpTools === 3,
    `exit=${mcp.code} 工具数=${mcpTools}`,
  );
  check(
    'mcp-office 不再「exit 0 且两路空」',
    !(mcp.code === 0 && mcp.stdout.length === 0 && mcp.stderr.length === 0),
  );

  // ── 2) mcp-office --selftest：走的是另一条入口分支
  const selftest = await run(join(link, 'mcp-office.mjs'), ['--selftest'], null, 8000, work);
  check(
    'mcp-office --selftest（经软链路径）',
    selftest.code === 0 && /selftest ok/.test(selftest.stderr + selftest.stdout),
    `exit=${selftest.code}`,
  );

  // ── 3) 另外三个：不给参数，只要**不静默**就算对（会打用法/报错，退出码非 0 也行）
  for (const script of ['make-docx.mjs', 'make-xlsx.mjs', 'read-xlsx.mjs']) {
    const r = await run(join(link, script), [], null, 8000, work);
    const silentZero = r.code === 0 && r.stdout.length === 0 && r.stderr.length === 0;
    check(`${script}（经软链路径）不会静默退出 0`, !silentZero,
      `exit=${r.code} out=${r.stdout.length}B err=${r.stderr.length}B`);
  }

  // ── 4) 对照：make-pptx 早就是新写法，必须一样不静默
  const pptx = await run(join(link, 'make-pptx.mjs'), [], null, 8000, work);
  check(
    'make-pptx（对照组）同样不静默',
    !(pptx.code === 0 && pptx.stdout.length === 0 && pptx.stderr.length === 0),
    `exit=${pptx.code}`,
  );
} finally {
  rmSync(work, { recursive: true, force: true });
}

console.log('');
if (failed > 0) {
  console.error(`${failed} 条没过 —— 真机上会表现成「探活失败：node 提前退出 exit=0、stderr 空」。`);
  process.exit(1);
}
console.log('全部通过：toolbox 脚本经软链路径也能正常跑起来，不会再静默退出 0。');
