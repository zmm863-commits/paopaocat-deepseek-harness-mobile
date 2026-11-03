#!/usr/bin/env node
/**
 * 出包前校验 `dsh-runtime.zip` —— 别把桌面版 runtime 打进 Android 包。
 *
 * ## 为什么要有这个脚本（2026-11-01 真实事故）
 *
 * 完整包曾从 118MB 涨到 238MB。根因：拷构建依赖时，把
 * `__migr/03-build-deps/android-node/app-assets/dsh-runtime.zip`（**151MB 桌面完整
 * 安装**，含 730 条 Windows LibreOffice + win32 版 node-pty/sharp/sherpa）当成了
 * Android 包用。桌面包和 slim 包**内核版本一样**（都是 0.1.7-rc.2），差别只在那些
 * Windows 死重 —— 光看版本号拦不住，所以要按下面三条硬判。
 *
 * 正确的包：`dsh-runtime-0.57-slim-anysearch.zip`（32MB，含 anysearch 插件）。
 * 判据来源：RELEASE-0.80.md 明确记着 0.80 的 `dsh-runtime.zip` 是 32.9MB。
 *
 * ## 三条规矩（写死在脚本里，别在出包时临时决定）
 *
 *   ① **体积 < 50MB** —— slim 是 32MB，桌面包 151MB，一比就露馅；
 *   ② **0 条 win32 libreoffice** —— Android 包里塞 Windows 办公软件毫无意义；
 *   ③ **必须含 anysearch 插件** —— 裸 slim 包没有它，App 的联网搜索会失效。
 *
 * 三条里任一不过就 `exit 1`，并打印"正确的是哪个包、怎么修"。
 *
 * ## 用法
 *
 *   node install/verify-runtime.mjs <dsh-runtime.zip>
 *
 * 出包脚本（build-full.sh 等）在编译前先跑它 —— 当场失败，好过编几分钟再回头查。
 */
import { statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

// 体积上限：slim 包 32MB；桌面包 151MB。取 50MB 做阈值，两头都留了余地。
const MAX_BYTES = 50 * 1024 * 1024;
const RIGHT_PKG = 'dsh-runtime-0.57-slim-anysearch.zip';

function die(msg, hint) {
  process.stderr.write(`✗ ${msg}\n`);
  if (hint) process.stderr.write(`  ${hint}\n`);
  process.exit(1);
}

/** 用 python 读 zip 条目（不落盘），返回匹配某子串的条目数。 */
function countEntries(zipPath, needle) {
  const code = `
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        print(sum(1 for x in z.namelist() if ${JSON.stringify(needle)} in x))
except Exception:
    print(0)
`;
  try {
    const out = execFileSync('python3', ['-c', code, zipPath], {
      encoding: 'utf8',
    }).trim();
    return Number(out) || 0;
  } catch {
    return -1; // 读不了 zip
  }
}

const zipPath = process.argv[2];
if (!zipPath) {
  process.stderr.write('用法：node install/verify-runtime.mjs <dsh-runtime.zip>\n');
  process.exit(2);
}

let size;
try {
  size = statSync(zipPath).size;
} catch {
  die(`找不到 runtime：${zipPath}`);
}
const mb = (size / 1024 / 1024).toFixed(1);

// ── ① 体积 ────────────────────────────────────────────────────────
if (size > MAX_BYTES) {
  die(
    `runtime.zip 体积 ${mb}MB 超过 50MB 上限 —— 拷错包了。`,
    `正确的是 ${RIGHT_PKG}（~32MB）。你现在这份多半是 __migr 里的桌面完整安装` +
      `（151MB，含 Windows LibreOffice）。修：cp ${RIGHT_PKG} <目标路径> 后重跑。`,
  );
}

// ── ② win32 libreoffice ──────────────────────────────────────────
const win32 = countEntries(zipPath, 'libreoffice-kit-win32');
if (win32 < 0) {
  die(`读不了 zip（python zipfile 失败）：${zipPath}`, '确认文件没损坏、且本机有 python3。');
}
if (win32 > 0) {
  die(
    `runtime.zip 里有 ${win32} 条 win32 libreoffice —— 这是 Windows 桌面版，Android 用不了。`,
    `正确的是 ${RIGHT_PKG}（不含这些）。修：cp ${RIGHT_PKG} <目标路径> 后重跑。`,
  );
}

// ── ③ anysearch 插件 ─────────────────────────────────────────────
const any = countEntries(zipPath, 'dsh-web-search-anysearch');
if (any === 0) {
  die(
    'runtime.zip 里没有 anysearch 插件 —— App 的联网搜索会失效。',
    `用 ${RIGHT_PKG}（含插件），别用裸 slim 包。`,
  );
}

process.stdout.write(
  `✓ runtime 体检通过：${mb}MB · 0 条 win32 · anysearch 在位（${any} 条）\n`,
);
