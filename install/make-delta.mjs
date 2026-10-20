#!/usr/bin/env node
/**
 * 生成「差分更新补丁」（DSHDELTA v1）——给手机版 DSH 的 APK 更新用。
 *
 * 用法：
 *   node install/make-delta.mjs <旧.apk> <新.apk> <输出.patch>
 *
 * 为什么不用 bsdiff：
 *   ① bsdiff 的补丁是 bzip2 格式，Dart 侧要额外引解压库；
 *   ② 我们自己控两端，格式简单、可校验、能用 Dart 自带的 zlib。
 * 为什么按「内容分块」（CDC）而不是固定 4KB：
 *   APK 是 ZIP，任何一处插入都会让后面所有字节**整体位移**；固定块比对会全部错位
 *   （实测 117→122 用 4KB 固定块算出"100% 都变了"）。CDC 用滚动哈希挑切点，
 *   位移不影响切点 → 只把真正变化的块算成新增。
 *
 * 补丁格式（全部小端）：
 *   magic  "DSHDELTA1"（9 字节）
 *   u32    headerLen
 *   header JSON（utf8）：{ oldSha256, newSha256, oldSize, newSize, ops }
 *   zlib   压缩后的操作流：
 *     u8 type   0 = COPY（u64 offset, u32 len） / 1 = ADD（u32 len, bytes）
 */
import { createHash } from 'node:crypto';
import { openSync, readSync, closeSync, writeFileSync, statSync } from 'node:fs';
import { deflateSync } from 'node:zlib';

const MIN_CHUNK = 4 * 1024;
const MAX_CHUNK = 64 * 1024;
const MASK_BITS = 13;            // 平均块 ≈ 8 KB
const GEAR = new BigUint64Array(256);
for (let i = 0; i < 256; i += 1) {
  // 固定的齿轮表（确定性）：用简单混合生成，避免每次跑出不同切点
  let x = BigInt(i + 1) * 0x9E3779B97F4A7C15n;
  x ^= x >> 30n; x = (x * 0xBF58476D1CE4E5B9n) & 0xFFFFFFFFFFFFFFFFn;
  x ^= x >> 27n; x = (x * 0x94D049BB133111EBn) & 0xFFFFFFFFFFFFFFFFn;
  x ^= x >> 31n;
  GEAR[i] = x;
}

function readAll(path) {
  const size = statSync(path).size;
  const fd = openSync(path, 'r');
  const buf = Buffer.allocUnsafe(size);
  let off = 0;
  while (off < size) {
    const n = readSync(fd, buf, off, size - off, off);
    if (n <= 0) break;
    off += n;
  }
  closeSync(fd);
  return buf;
}

/** CDC：把一段 buffer 切成变长块（切点由内容决定，位移不影响）。 */
function chunk(buf) {
  const out = [];
  let start = 0;
  let h = 0n;
  const mask = (1n << BigInt(MASK_BITS)) - 1n;
  for (let i = 0; i < buf.length; i += 1) {
    h = ((h << 1n) + GEAR[buf[i]]) & 0xFFFFFFFFFFFFFFFFn;
    const len = i - start + 1;
    if (len < MIN_CHUNK) continue;
    if ((h & mask) === 0n || len >= MAX_CHUNK) {
      out.push([start, len]);
      start = i + 1;
      h = 0n;
    }
  }
  if (start < buf.length) out.push([start, buf.length - start]);
  return out;
}

const hashOf = (b) => createHash('sha1').update(b).digest().subarray(0, 8).toString('hex');

function main() {
  const [oldPath, newPath, outPath] = process.argv.slice(2);
  if (!oldPath || !newPath || !outPath) {
    console.error('用法：node install/make-delta.mjs <旧.apk> <新.apk> <输出.patch>');
    process.exit(2);
  }
  const t0 = Date.now();
  const oldBuf = readAll(oldPath);
  const newBuf = readAll(newPath);

  // ① 给旧包建索引：块哈希 → 偏移
  const index = new Map();
  for (const [off, len] of chunk(oldBuf)) {
    const h = hashOf(oldBuf.subarray(off, off + len));
    if (!index.has(h)) index.set(h, [off, len]);
  }

  // ② 扫新包：命中的抄过去，没命中的当新增
  const ops = [];
  let copy = null;   // 正在累积的 COPY
  let add = null;    // 正在累积的 ADD
  const flushCopy = () => { if (copy) { ops.push(copy); copy = null; } };
  const flushAdd = () => { if (add) { ops.push(add); add = null; } };

  for (const [off, len] of chunk(newBuf)) {
    const hit = index.get(hashOf(newBuf.subarray(off, off + len)));
    if (hit) {
      flushAdd();
      const [oldOff] = hit;
      if (copy && copy.offset + copy.len === oldOff) copy.len += len;
      else { flushCopy(); copy = { type: 0, offset: oldOff, len }; }
    } else {
      flushCopy();
      const bytes = newBuf.subarray(off, off + len);
      if (add && add.buf.length < 1 << 20) add.buf = Buffer.concat([add.buf, bytes]);
      else { flushAdd(); add = { type: 1, buf: Buffer.from(bytes) }; }
    }
  }
  flushCopy();
  flushAdd();

  // ③ 编码
  const parts = [];
  for (const op of ops) {
    if (op.type === 0) {
      const b = Buffer.allocUnsafe(13);
      b.writeUInt8(0, 0); b.writeBigUInt64LE(BigInt(op.offset), 1); b.writeUInt32LE(op.len, 9);
      parts.push(b);
    } else {
      const b = Buffer.allocUnsafe(5);
      b.writeUInt8(1, 0); b.writeUInt32LE(op.buf.length, 1);
      parts.push(b, op.buf);
    }
  }
  const rawOps = Buffer.concat(parts);
  const zops = deflateSync(rawOps, { level: 9 });

  const header = {
    format: 'DSHDELTA1',
    oldSha256: createHash('sha256').update(oldBuf).digest('hex'),
    newSha256: createHash('sha256').update(newBuf).digest('hex'),
    oldSize: oldBuf.length,
    newSize: newBuf.length,
    ops: ops.length,
  };
  const hjson = Buffer.from(JSON.stringify(header), 'utf8');
  const magic = Buffer.from('DSHDELTA1', 'ascii');
  const lenBuf = Buffer.allocUnsafe(4);
  lenBuf.writeUInt32LE(hjson.length, 0);
  writeFileSync(outPath, Buffer.concat([magic, lenBuf, hjson, zops]));

  const ratio = ((zops.length + hjson.length) / newBuf.length) * 100;
  console.log(
    `[delta] ok old=${(oldBuf.length / 1048576).toFixed(1)}MB new=${(newBuf.length / 1048576).toFixed(1)}MB ` +
    `ops=${ops.length} rawOps=${(rawOps.length / 1048576).toFixed(1)}MB ` +
    `patch=${((zops.length + hjson.length) / 1048576).toFixed(2)}MB (${ratio.toFixed(1)}%) ` +
    `${Date.now() - t0}ms`,
  );
  console.log(`        header oldSha=${header.oldSha256.slice(0, 16)}… newSha=${header.newSha256.slice(0, 16)}…`);
}

main();
