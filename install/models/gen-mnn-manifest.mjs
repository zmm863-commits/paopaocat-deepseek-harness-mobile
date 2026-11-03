#!/usr/bin/env node
/**
 * 从 MNN 官方模型市场 + ModelScope API，生成 App 的模型清单条目。
 *
 * ## 为什么需要这个脚本
 *
 * MNN 官方有一个模型市场（`model_market.json`，159 个模型），但里面**只有仓库名**，
 * 没有文件清单 —— 因为不同模型的文件构成不一样：
 *
 *   Qwen3-1.7B     → llm_config.json + llm.mnn + llm.mnn.weight + tokenizer.txt
 *   Qwen2.5-Coder  → … + llm.mnn.json + tokenizer.mtok（不是 .txt）
 *   有的还有      → embeddings_bf16.bin（单独的 embedding 文件，几百 MB）
 *
 * 所以清单必须**逐个仓库问 API** 拿真实文件列表，不能写死。
 *
 * ## 用法
 *
 *   node install/models/gen-mnn-manifest.mjs [--out <文件>]
 *
 * 输出一段可以直接拼进 `app/assets/models/model_manifest.json` 的 `models` 数组。
 *
 * ## 数据源
 *
 * ModelScope（阿里官方，国内直连快且稳），不是 HuggingFace。
 * 它是 MNN 官方模型市场里登记的源之一，文件与 HF 同一份。
 */

import { writeFileSync } from 'node:fs';

const MS_API = 'https://modelscope.cn/api/v1/models';
const MS_URL = 'https://modelscope.cn/models';

/** 文档类文件，不进清单（下了也用不上，还占体积）。 */
const JUNK = new Set([
  '.gitattributes',
  'README.md',
  'export_args.json',
  'config.json', // MNN 不读它，读的是 llm_config.json
  'LICENSE',
  'LICENSE.txt',
]);

/** 挑哪几个模型 —— 覆盖「超小试水 / 主力对话 / 代码 / 推理 / 中文」。 */
const PICKS = [
  { repo: 'MiniMind2-MNN', id: 'minimind2', name: 'MiniMind2（最小・秒下）', minRamGb: 2, note: '最小的一个（约 65MB），用来先试通链路。中文能力弱，只适合验证。' },
  { repo: 'SmolLM2-135M-Instruct-MNN', id: 'smollm2-135m', name: 'SmolLM2 135M（超小）', minRamGb: 2, note: '135M 参数，英文为主。适合先跑通，别指望中文。' },
  { repo: 'Qwen2.5-0.5B-Instruct-MNN', id: 'qwen2.5-0.5b-mnn', name: 'Qwen2.5 0.5B（小・快）', minRamGb: 3, note: '0.5B 中文可用。真机实测约 130 tok/s，质量一般但够快。' },
  { repo: 'Qwen3-0.6B-MNN', id: 'qwen3-0.6b-mnn', name: 'Qwen3 0.6B（新一代・带思考）', minRamGb: 3, note: 'Qwen3 系列，支持 thinking 模式。比 Qwen2.5 同尺寸更强。' },
  { repo: 'Qwen3.5-0.8B-MNN', id: 'qwen3.5-0.8b-mnn', name: 'Qwen3.5 0.8B（新・推荐）', minRamGb: 4, note: 'Qwen3.5 世代，0.8B。同尺寸里较新，中文表现好。' },
  { repo: 'LFM2.5-1.2B-Instruct-MNN', id: 'lfm2.5-1.2b', name: 'LFM2.5 1.2B（Liquid AI）', minRamGb: 4, note: 'Liquid AI 的端侧模型，主打低内存高速度。' },
  { repo: 'Qwen2.5-1.5B-Instruct-MNN', id: 'qwen2.5-1.5b-mnn', name: 'Qwen2.5 1.5B（主力・推荐）', minRamGb: 4, note: '**主力档**。真机实测：加载<45s、内存约 963MB（稳定无泄漏）、约 50 tok/s，长请求不崩。' },
  { repo: 'Qwen3-1.7B-MNN', id: 'qwen3-1.7b-mnn', name: 'Qwen3 1.7B（带思考）', minRamGb: 5, note: '比 Qwen2.5-1.5B 新一代，支持 thinking。' },
  { repo: 'Llama-3.2-1B-Instruct-MNN', id: 'llama-3.2-1b-mnn', name: 'Llama 3.2 1B', minRamGb: 4, note: 'Meta 的端侧 1B，英文强、中文弱。' },
  { repo: 'Qwen2.5-Coder-1.5B-Instruct-MNN', id: 'qwen2.5-coder-1.5b-mnn', name: 'Qwen2.5 Coder 1.5B（代码）', minRamGb: 5, note: '代码专用，写/改脚本用它。' },
  { repo: 'DeepSeek-R1-1.5B-Qwen-MNN', id: 'deepseek-r1-1.5b-mnn', name: 'DeepSeek R1 1.5B（推理）', minRamGb: 5, note: 'R1 蒸馏版，擅长推理链。会先输出思考过程。' },
  { repo: 'Hunyuan-1.8B-Instruct-MNN', id: 'hunyuan-1.8b-mnn', name: 'Hunyuan 1.8B（腾讯）', minRamGb: 6, note: '腾讯混元端侧版，中文能力强，体积偏大。' },
];

/** 问 ModelScope 要这个仓库的真实文件列表。 */
async function listFiles(repo) {
  const url = `${MS_API}/MNN/${repo}/repo/files?Recursive=true`;
  const res = await fetch(url, { signal: AbortSignal.timeout(30000) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const j = await res.json();
  const files = j?.Data?.Files;
  if (!Array.isArray(files) || files.length === 0) {
    throw new Error('API 没返回文件列表');
  }
  return files;
}

/** 按用途把模型归到 App 的三个 kind 之一。 */
function kindOf(repo) {
  if (/Coder|Math/i.test(repo)) return 'text';
  return 'text'; // 这一批全是文本模型（视觉/生图那批单列）
}

function buildEntry(pick, files) {
  // 只留真正的模型文件（按扩展名白名单比按 JUNK 黑名单更稳 —— 上游偶尔加 README_zh 之类）
  const keep = files.filter((f) => {
    const p = String(f.Path || '');
    if (!p || JUNK.has(p)) return false;
    if (p.includes('/')) return false; // 子目录里的不要（这一批模型都是平铺的）
    if (f.Type && f.Type !== 'blob') return false;
    return true;
  });
  if (keep.length === 0) throw new Error('过滤后没有文件');

  // 主文件 = 最大的那个（权重）。App 的下载器按它算总进度。
  const sorted = [...keep].sort((a, b) => (b.Size || 0) - (a.Size || 0));
  const main = sorted[0];
  const rest = sorted.slice(1);
  const total = keep.reduce((n, f) => n + (f.Size || 0), 0);

  const src = (path) => [
    {
      label: 'ModelScope（国内主源）',
      url: `${MS_URL}/MNN/${pick.repo}/resolve/master/${path}`,
      priority: 0,
    },
  ];

  return {
    id: pick.id,
    family: pick.id.split('-')[0],
    name: pick.name,
    kind: kindOf(pick.repo),
    engine: 'mnn',
    format: 'mnn',
    quant: 'fp16',
    fileName: main.Path,
    bytes: main.Size || 0,
    sha256: main.Sha256 || null,
    license: 'Apache-2.0',
    minRamGb: pick.minRamGb,
    socMatch: [],
    abi: 'arm64-v8a',
    note: `${pick.note} 合计 ${(total / 1024 ** 3).toFixed(2)}GB，${keep.length} 个文件。`,
    sources: src(main.Path),
    companions: rest.map((f) => ({
      fileName: f.Path,
      bytes: f.Size || 0,
      sha256: f.Sha256 || null,
      sources: src(f.Path),
    })),
  };
}

async function main() {
  const outIdx = process.argv.indexOf('--out');
  const out = outIdx > 0 ? process.argv[outIdx + 1] : null;

  const entries = [];
  const failed = [];
  for (const pick of PICKS) {
    process.stderr.write(`  ${pick.repo} … `);
    try {
      const files = await listFiles(pick.repo);
      const e = buildEntry(pick, files);
      entries.push(e);
      process.stderr.write(
        `OK ${(e.bytes / 1024 ** 3).toFixed(2)}GB 权重 + ${e.companions.length} 伴生\n`,
      );
    } catch (err) {
      failed.push({ repo: pick.repo, why: String(err?.message || err) });
      process.stderr.write(`失败：${err?.message || err}\n`);
    }
  }

  process.stderr.write(
    `\n成功 ${entries.length} 个 · 失败 ${failed.length} 个\n`,
  );
  if (failed.length) {
    for (const f of failed) process.stderr.write(`  ✗ ${f.repo}: ${f.why}\n`);
  }

  const json = JSON.stringify(entries, null, 2);
  if (out) {
    writeFileSync(out, json + '\n');
    process.stderr.write(`已写入 ${out}\n`);
  } else {
    process.stdout.write(json + '\n');
  }
}

main().catch((e) => {
  process.stderr.write(`致命：${e?.message || e}\n`);
  process.exit(1);
});
