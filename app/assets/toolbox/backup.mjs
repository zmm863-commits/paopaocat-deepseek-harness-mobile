#!/usr/bin/env node
/**
 * backup.mjs —— 换机迁移用的「备份包」打包 / 还原 / 查看。
 *
 * ## 它解决什么
 *
 * 用户换新手机时，旧手机上攒的会话、记忆、模型配置、工作区文件全带不走。
 * 这个脚本把该带的东西打成一个**加密文件**，用户随便用什么传过去，
 * 新手机上再还原。
 *
 * ## 为什么加密，而且是硬要求
 *
 * 备份包里是**用户全部聊天记录**。而它多半会经过网盘 —— 网盘不是保险箱：
 * 账号被盗、链接误分享、服务商扫描，任何一环都能让别人看到全部对话。
 * 所以这里不做「可选加密」，一律加密。
 *
 * ## 密码怎么传（**必须走 stdin**）
 *
 * 绝不走 argv：`/proc/<pid>/cmdline` 同 uid 可读，手机上一个恶意 App
 * 扫一遍进程列表就把用户的备份密码看走了。所以密码从 **stdin 第一行**读。
 *
 * ## 文件格式 `.pcbak`
 *
 * ```
 * 偏移  长度   内容
 * 0     4      Magic "PCB1"
 * 4     16     salt（scrypt 用，每次随机）
 * 20    12     iv（AES-GCM 用，每次随机）
 * 32    16     auth tag（GCM 完整性校验）
 * 48    ..     密文（里面是一个普通 zip）
 * ```
 *
 * 用 AES-256-GCM 而不是 CBC：GCM 自带完整性校验 —— 密码错、文件被改、
 * 传输截断，都会在解密那一刻就报错，不会让你拿到半个损坏的包去覆盖数据。
 *
 * ## 用法
 *
 * ```
 * echo "<密码>" | node backup.mjs pack   --root <filesDir> --out <file> [--include a,b]
 * echo "<密码>" | node backup.mjs list   --in <file>
 * echo "<密码>" | node backup.mjs unpack --in <file> --root <filesDir> [--dry-run]
 * ```
 *
 * stdout **只输出一行 JSON**（给 Dart 解析）；所有日志走 stderr。
 */

import { createDecipheriv, createCipheriv, randomBytes, scryptSync, createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync, readdirSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { zipRead, zipWrite } from './office-zip.mjs';

const MAGIC = Buffer.from('PCB1', 'ascii');
const SALT_LEN = 16;
const IV_LEN = 12;
const TAG_LEN = 16;
const HEADER_LEN = MAGIC.length + SALT_LEN + IV_LEN + TAG_LEN;

/** 备份包的格式版本。将来改结构时靠它判断「能不能读」。 */
const FORMAT_VERSION = 1;

/** 单个文件上限：超过就跳过并记一条（备份不该被一个 3GB 视频拖死）。 */
const MAX_FILE_BYTES = 64 * 1024 * 1024;

/** 整个包上限（防止用户把整个工作区塞进去后发现传不上去）。 */
const MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024;

/**
 * 默认采集什么。
 *
 * 判断标准只有一条：**这条数据在新手机上重新生成得出来吗？**
 * 能重新生成的（运行时、工具箱脚本、各种缓存）一律不迁 —— 它们占了包体的 95%，
 * 却一条都不影响用户"我的东西还在不在"。
 */
const DEFAULT_INCLUDES = [
  'sessions', // 历史对话（最值钱）
  'workspace', // 用户文件
  'models.json', // 厂家/模型/轮换池配置（**不含 Key**）
  'experts.json', // 专家开关
  'memory.json', // 记忆
  'local_chat.json', // 本机对话
  'workspaces.json', // 工作区列表
];

/** 永远不迁的（即使被 include 点名）。 */
const NEVER = new Set([
  'dsh', // 运行时 106MB，新机自己解包
  'toolbox', // 工具脚本，跟着 App 包走
  'shims', // 同上
  'tmp', // 临时文件
  'profiles', // 由运行时自己生成
  'bridge.json', // 含桌面平台访问口令，且与设备绑定
  'notice.json', // 公告已读状态
  'update.json', // 检查更新缓存
]);

function die(message, code = 2) {
  process.stderr.write(`错误：${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const out = { mode: argv[0] || '', root: '', in: '', out: '', include: null, dryRun: false };
  for (let i = 1; i < argv.length; i += 1) {
    const a = argv[i];
    const need = () => {
      const v = argv[++i];
      if (v === undefined) die(`选项 ${a} 后面缺参数`);
      return v;
    };
    if (a === '--root') out.root = need();
    else if (a === '--in') out.in = need();
    else if (a === '--out') out.out = need();
    else if (a === '--include') out.include = need().split(',').map((s) => s.trim()).filter(Boolean);
    else if (a === '--dry-run') out.dryRun = true;
    else die(`不认识的选项 ${a}`);
  }
  return out;
}

/** 从 stdin 第一行读密码。**绝不从 argv 读**（见文件头说明）。 */
function readPasswordFromStdin() {
  return new Promise((resolve, reject) => {
    let buf = '';
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      process.stdin.pause();
      // 只取第一行，去掉行尾的 \r\n
      const line = buf.split('\n')[0].replace(/\r$/, '');
      resolve(line);
    };
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => {
      buf += c;
      if (buf.includes('\n')) finish();
    });
    process.stdin.on('end', finish);
    process.stdin.on('error', reject);
    // 没有 stdin（比如被重定向成 /dev/null）时也不能卡死
    setTimeout(finish, 1500).unref?.();
  });
}

function sha256(buf) {
  return createHash('sha256').update(buf).digest('hex');
}

/** 收集要打包的文件；返回 {files:[{rel, abs, bytes}], skipped:[...]} */
function collectFiles(root, includes) {
  const files = [];
  const skipped = [];
  const wanted = includes && includes.length ? includes : DEFAULT_INCLUDES;

  for (const item of wanted) {
    if (NEVER.has(item)) {
      skipped.push({ path: item, why: '这类数据不参与迁移' });
      continue;
    }
    const abs = join(root, item);
    if (!existsSync(abs)) continue;

    const st = statSync(abs);
    if (st.isFile()) {
      files.push({ rel: item, abs, bytes: st.size });
      continue;
    }
    if (!st.isDirectory()) continue;

    // 目录：递归但要扛得住坏文件、软链、超深目录。
    const walk = (dir, depth) => {
      if (depth > 12) {
        skipped.push({ path: relative(root, dir), why: '目录太深' });
        return;
      }
      let entries = [];
      try {
        entries = readdirSync(dir, { withFileTypes: true });
      } catch (e) {
        skipped.push({ path: relative(root, dir), why: `读不了：${e.code || e.message}` });
        return;
      }
      for (const ent of entries) {
        const p = join(dir, ent.name);
        if (ent.isSymbolicLink()) {
          skipped.push({ path: relative(root, p), why: '软链（还原时可能指向不存在的地方）' });
          continue;
        }
        if (ent.isDirectory()) {
          walk(p, depth + 1);
          continue;
        }
        if (!ent.isFile()) continue;
        let s;
        try {
          s = statSync(p);
        } catch {
          continue;
        }
        if (s.size > MAX_FILE_BYTES) {
          skipped.push({ path: relative(root, p), why: `单文件超过 ${MAX_FILE_BYTES >> 20}MB` });
          continue;
        }
        files.push({ rel: relative(root, p).split(sep).join('/'), abs: p, bytes: s.size });
      }
    };
    walk(abs, 0);
  }
  return { files, skipped };
}

function pack(args, password) {
  const root = args.root;
  if (!root) die('pack 需要 --root');
  if (!args.out) die('pack 需要 --out');
  if (!existsSync(root)) die(`找不到目录：${root}`);
  if (!password) die('密码是空的 —— 备份包必须加密');

  const { files, skipped } = collectFiles(root, args.include);
  if (files.length === 0) die('没有可打包的文件（工作区是空的？）');

  let total = 0;
  const entries = [];
  const manifestFiles = [];
  for (const f of files) {
    if (total + f.bytes > MAX_TOTAL_BYTES) {
      skipped.push({ path: f.rel, why: '整包体积到上限了' });
      continue;
    }
    let data;
    try {
      data = readFileSync(f.abs);
    } catch (e) {
      skipped.push({ path: f.rel, why: `读不了：${e.code || e.message}` });
      continue;
    }
    total += data.length;
    entries.push([f.rel, data]);
    manifestFiles.push({ path: f.rel, bytes: data.length, sha256: sha256(data) });
  }

  if (entries.length === 0) die('所有文件都读不了，没有东西可打包');

  const manifest = {
    v: FORMAT_VERSION,
    kind: 'paopaocat-backup',
    createdAt: new Date().toISOString(),
    files: manifestFiles,
    skipped,
    totalBytes: total,
  };
  entries.push(['manifest.json', Buffer.from(JSON.stringify(manifest, null, 2), 'utf8')]);

  const zip = zipWrite(entries);
  const blob = encrypt(zip, password);

  mkdirSync(dirname(args.out), { recursive: true });
  writeFileSync(args.out, blob);

  return {
    ok: true,
    mode: 'pack',
    out: args.out,
    files: manifestFiles.length,
    skipped: skipped.length,
    rawBytes: total,
    packedBytes: blob.length,
    createdAt: manifest.createdAt,
  };
}

function encrypt(plain, password) {
  const salt = randomBytes(SALT_LEN);
  const iv = randomBytes(IV_LEN);
  // scrypt 参数取默认值（N=16384, r=8, p=1）：手机上约 0.1~0.3 秒，
  // 换来的暴力破解成本是值得的 —— 用户密码通常不强，靠 KDF 拖时间。
  const key = scryptSync(password, salt, 32);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const body = Buffer.concat([cipher.update(plain), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([MAGIC, salt, iv, tag, body]);
}

function decrypt(blob, password) {
  if (blob.length < HEADER_LEN + 16) die('这个文件太小，不像是备份包');
  if (!blob.subarray(0, 4).equals(MAGIC)) {
    die('这不是泡泡猫的备份包（文件头不对）—— 可能选错了文件');
  }
  const salt = blob.subarray(4, 4 + SALT_LEN);
  const iv = blob.subarray(4 + SALT_LEN, 4 + SALT_LEN + IV_LEN);
  const tag = blob.subarray(4 + SALT_LEN + IV_LEN, HEADER_LEN);
  const body = blob.subarray(HEADER_LEN);
  const key = scryptSync(password, salt, 32);
  const decipher = createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);
  try {
    return Buffer.concat([decipher.update(body), decipher.final()]);
  } catch {
    // GCM 认证失败只有两种原因：密码错，或文件被改/截断。
    // 两种情况都不能继续往下走 —— 一定要在这里拦住。
    die('密码不对，或者这个备份包已经损坏（被改过/没传完整）');
  }
}

function list(args, password) {
  if (!args.in) die('list 需要 --in');
  if (!existsSync(args.in)) die(`找不到文件：${args.in}`);
  const zip = decrypt(readFileSync(args.in), password);
  const entries = zipRead(zip);
  const mf = entries.get('manifest.json');
  if (!mf) die('备份包里没有 manifest.json（包结构坏了）');
  let manifest;
  try {
    manifest = JSON.parse(mf.toString('utf8'));
  } catch {
    die('manifest.json 不是合法 JSON');
  }
  return {
    ok: true,
    mode: 'list',
    v: manifest.v,
    createdAt: manifest.createdAt,
    files: Array.isArray(manifest.files) ? manifest.files.length : 0,
    totalBytes: manifest.totalBytes || 0,
    skipped: Array.isArray(manifest.skipped) ? manifest.skipped.length : 0,
    packedBytes: statSync(args.in).size,
  };
}

function unpack(args, password) {
  if (!args.in) die('unpack 需要 --in');
  if (!args.root) die('unpack 需要 --root');
  if (!existsSync(args.in)) die(`找不到文件：${args.in}`);

  const zip = decrypt(readFileSync(args.in), password);
  const entries = zipRead(zip);
  const mf = entries.get('manifest.json');
  if (!mf) die('备份包里没有 manifest.json（包结构坏了）');

  let manifest;
  try {
    manifest = JSON.parse(mf.toString('utf8'));
  } catch {
    die('manifest.json 不是合法 JSON');
  }
  if (manifest.kind !== 'paopaocat-backup') die('这不是泡泡猫的备份包');
  if (Number(manifest.v) > FORMAT_VERSION) {
    die(`这个备份包是更新版本的 App 做的（v${manifest.v}），当前版本读不了，请先升级 App`);
  }

  const root = args.root;
  const planned = [];
  let written = 0;
  let totalBytes = 0;

  for (const [rawName, data] of entries.entries()) {
    if (rawName === 'manifest.json') continue;
    // ⚠️ 防目录穿越：包里写 `../../evil.sh` 的话，绝不能写到 filesDir 外面去。
    //    这是解压类功能最经典的一个洞。
    const norm = rawName.split('\\').join('/');
    if (norm.startsWith('/') || norm.split('/').includes('..')) {
      process.stderr.write(`跳过可疑路径：${rawName}\n`);
      continue;
    }
    const dest = join(root, ...norm.split('/'));
    planned.push({ rel: norm, bytes: data.length, dest, data });
  }

  if (args.dryRun) {
    return {
      ok: true,
      mode: 'unpack',
      dryRun: true,
      v: manifest.v,
      createdAt: manifest.createdAt,
      files: planned.length,
      totalBytes: planned.reduce((n, x) => n + x.bytes, 0),
    };
  }

  for (const p of planned) {
    try {
      mkdirSync(dirname(p.dest), { recursive: true });
      writeFileSync(p.dest, p.data);
      written += 1;
      totalBytes += p.bytes;
    } catch (err) {
      process.stderr.write(`写不进去：${p.rel}（${err.code || err.message}）\n`);
    }
  }

  return {
    ok: true,
    mode: 'unpack',
    v: manifest.v,
    createdAt: manifest.createdAt,
    files: written,
    totalBytes,
    skipped: planned.length - written,
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const mode = args.mode;
  if (!['pack', 'list', 'unpack'].includes(mode)) {
    die('用法：node backup.mjs <pack|list|unpack> ...（详见文件头）');
  }
  if (mode === 'unpack' && args.dryRun) {
    // dry-run 也要密码（要解密才能读 manifest），照常走下面
  }
  const password = await readPasswordFromStdin();
  if (!password) die('没有从 stdin 读到密码');

  const result = mode === 'pack'
    ? pack(args, password)
    : mode === 'list'
      ? list(args, password)
      : unpack(args, password);

  // stdout 只留这一行 JSON，Dart 侧按它解析
  process.stdout.write(JSON.stringify(result) + '\n');
}

main().catch((e) => {
  process.stderr.write(`backup: 未预期错误：${(e && e.stack) || e}\n`);
  process.exit(1);
});
