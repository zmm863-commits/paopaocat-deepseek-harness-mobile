#!/usr/bin/env node
/**
 * 出包时生成「差分更新补丁」并打印可直接贴进 `update.json` 的 `patches[]` 片段。
 *
 * 用法：
 *   node install/release-delta.mjs <新.apk> <补丁的下载根地址> [旧包1.apk 旧包2.apk ...]
 *
 * 例：
 *   node install/release-delta.mjs dist/…-0.78…apk \
 *     https://github.com/<user>/<repo>/releases/download/v0.78 \
 *     dist/…-0.77…apk
 *
 * 三条规矩（写死在脚本里，别在发布时临时决定）：
 *   ① **超过整包 60% 的补丁不生成** —— 省下的流量不值得"拼装+校验"那一套风险；
 *   ② 每个补丁只对它那一个旧包有效（`fromSha256` 精确匹配），所以文件名带旧包哈希前缀；
 *   ③ 同时打印整包体积做对照，方便判断值不值。
 */
import { createHash } from 'node:crypto';
import { mkdirSync, statSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, basename, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const MAX_RATIO = 0.60;

const [newApk, urlBase, ...oldApks] = process.argv.slice(2);
if (!newApk || !urlBase) {
  console.error('用法：node install/release-delta.mjs <新.apk> <补丁下载根地址> [旧包...]');
  process.exit(2);
}
if (!/^https?:\/\//.test(urlBase)) {
  console.error('第二个参数必须是 http(s) 地址（补丁将来要从这里下载）');
  process.exit(2);
}

const sha256 = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');
const newSize = statSync(newApk).size;
const newSha = sha256(newApk);
const outDir = join(dirname(resolve(newApk)), 'patches');
mkdirSync(outDir, { recursive: true });

console.log(`新包 ${basename(newApk)} ${(newSize / 1048576).toFixed(1)}MB sha=${newSha.slice(0, 16)}…\n`);

const entries = [];
for (const old of oldApks) {
  const oldSize = statSync(old).size;
  const oldSha = sha256(old);
  const name = `${basename(old, '.apk')}__to__${basename(newApk, '.apk')}.patch`;
  const out = join(outDir, name);
  process.stdout.write(`· ${basename(old)} (${(oldSize / 1048576).toFixed(1)}MB) → `);
  // ⚠️ 必须用 fileURLToPath：项目路径含中文，`new URL().pathname` 会给百分号编码 → 子进程找不到脚本。
  execFileSync(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), 'make-delta.mjs'), old, newApk, out], { stdio: 'inherit' });
  const size = statSync(out).size;
  const ratio = size / newSize;
  if (ratio > MAX_RATIO) {
    console.log(`  ✗ 补丁 ${(size / 1048576).toFixed(2)}MB = 整包 ${(ratio * 100).toFixed(0)}% > ${MAX_RATIO * 100}% → **不发布**这个补丁`);
    continue;
  }
  console.log(`  ✓ ${(size / 1048576).toFixed(2)}MB = 整包 ${(ratio * 100).toFixed(1)}%`);
  entries.push({
    fromSha256: oldSha,
    url: `${urlBase.replace(/\/$/, '')}/${name}`,
    size,
    sha256: sha256(out),
  });
}

if (entries.length === 0) {
  console.log('\n没有可发布的补丁（全部超阈值或没给旧包）→ 本次只走整包。');
  process.exit(0);
}
console.log('\n把下面这段合并进 update.json（保留其它字段）：\n');
console.log(JSON.stringify({ patches: entries }, null, 2));
console.log(`\n补丁文件在：${outDir}（记得随 Release 一起上传）`);
