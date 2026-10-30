/*
 * NodeHost.ets —— 在鸿蒙 App 里把 node 跑起来
 *
 * 流程：
 *   1. 把随包的 dsh-runtime.zip 解压到应用私有目录（只需一次）
 *   2. 组装 node 的 argv 与 env（对齐 Android 版的语义）
 *   3. 调 native 的 startNode：dlopen libnode.so → dlsym node::Start → 起线程
 *
 * 用 node 而不是起一个 node 可执行文件，是因为鸿蒙的 seccomp 不让 exec 任意二进制。
 * 所以 libnode.so 是**共享库**，必须在宿主进程里跑。
 */

import nodehost from 'libnodehost.so';
import { zlib, BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** native startNode 的入参（ArkTS 不允许匿名对象字面量，必须声明类型） */
interface NodeStartOptions {
  libPath: string;
  args: string[];
  env: Record<string, string>;
  /** node 的 stdout 重定向到这里，Dart 侧轮询抓 "dsh web: http://..." 就绪行 */
  stdoutPath?: string;
  /** 崩溃笔迹（native 各步追加写，Dart 端轮询读） */
  tracePath?: string;
}

/** 暴露给 UI 的路径集合 */
export interface NodePaths {
  bundleCodeDir: string;
  filesDir: string;
  libnode: string;
  runtime: string;
}

export interface StartResult {
  ok: boolean;
  error?: string;
  argc?: number;
  /** 每个步骤的时间与结果，出问题时要靠它定位 */
  steps: string[];
}

interface ProbeResult {
  ok: boolean;
  path?: string;
  exists?: boolean;
  hasStart?: boolean;
  dlopenError?: string;
  dlsymError?: string;
}

export class NodeHost {
  private ctx: common.UIAbilityContext;
  /** libnode.so 所在的目录。鸿蒙把 native 库装到 bundle 下的 libs/<abi>/ */
  private libDir: string = '';
  /** node 的工作目录与 DSH_HOME 的父目录 */
  private filesDir: string = '';
  /** runtime 解压目标 */
  private runtimeDir: string = '';
  private started: boolean = false;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
    this.filesDir = ctx.filesDir;
    this.runtimeDir = `${ctx.filesDir}/dsh`;
    // 鸿蒙的 native 库路径：<bundleCodeDir>/libs/<abi>
    // abi 目录名在不同版本里可能是 arm64 或 arm64-v8a，两个都试。
    this.libDir = `${ctx.bundleCodeDir}/libs/arm64`;
  }

  /** 找出 libnode.so 的真实路径（不同鸿蒙版本的 abi 目录名不一样） */
  private findLib(name: string): string {
    const candidates: string[] = [
      `${this.ctx.bundleCodeDir}/libs/arm64/${name}`,
      `${this.ctx.bundleCodeDir}/libs/arm64-v8a/${name}`,
      `${this.ctx.bundleCodeDir}/libs/${name}`,
    ];
    for (const p of candidates) {
      try {
        if (fileIo.accessSync(p)) {
          return p;
        }
      } catch (e) {
        // accessSync 不存在时退回 statSync
      }
      try {
        fileIo.statSync(p);
        return p;
      } catch (e) {
        // 继续试下一个
      }
    }
    return candidates[0];
  }

  /** 自检：不启动 node，只确认 .so 能不能 dlopen、符号在不在 */
  probe(): ProbeResult {
    const libPath = this.findLib('libnode.so');
    try {
      const r = nodehost.probe(libPath) as ProbeResult;
      return r;
    } catch (e) {
      return { ok: false, path: libPath, dlopenError: `${e}` };
    }
  }

  /** 解压 runtime（幂等：已解压过就跳过） */
  private async ensureRuntime(steps: string[]): Promise<boolean> {
    // 判定"已解压"的标志：node_modules 目录存在
    const marker = `${this.runtimeDir}/node_modules`;
    try {
      fileIo.statSync(marker);
      steps.push('runtime 已存在，跳过解压');
      return true;
    } catch (e) {
      // 需要解压
    }

    try {
      fileIo.mkdirSync(this.runtimeDir, true);
    } catch (e) {
      // 已存在
    }

    // 把 rawfile 里的 zip 复制到可写目录（rawfile 不能直接被 zlib 读）
    const zipPath = `${this.ctx.filesDir}/dsh-runtime.zip`;
    try {
      fileIo.statSync(zipPath);
      steps.push('zip 已在可写目录');
    } catch (e) {
      const t0 = Date.now();
      const raw = await this.ctx.resourceManager.getRawFileContent('dsh-runtime.zip');
      const file = fileIo.openSync(zipPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(file.fd, raw.buffer as ArrayBuffer);
      fileIo.closeSync(file);
      steps.push(`复制 zip 完成（${raw.byteLength} 字节，${Date.now() - t0}ms）`);
    }

    const t1 = Date.now();
    try {
      await zlib.decompressFile(zipPath, this.runtimeDir);
      steps.push(`解压完成（${Date.now() - t1}ms）`);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      steps.push(`解压失败: ${err.code} ${err.message}`);
      return false;
    }
  }

  /**
   * 启动 node。
   * @param profile dsh 的 profile 名（默认 default）
   * @param extraEnv 追加的环境变量（模型 Key 等）
   */
  async start(profile: string, extraEnv: Record<string, string>): Promise<StartResult> {
    const steps: string[] = [];

    if (this.started) {
      return { ok: false, error: 'node 已启动过（每进程只能一次）', steps };
    }

    // ── 1. 解压 runtime ────────────────────────────────────
    const ready = await this.ensureRuntime(steps);
    if (!ready) {
      return { ok: false, error: 'runtime 解压失败', steps };
    }

    // ── 2. 自检 ────────────────────────────────────────────
    const probe = this.probe();
    steps.push(`probe: exists=${probe.exists} hasStart=${probe.hasStart}`);
    if (!probe.ok) {
      return {
        ok: false,
        error: `libnode.so 不可用: ${probe.dlopenError ?? probe.dlsymError ?? '未知'}`,
        steps,
      };
    }

    // ── 3. 组装环境变量（对齐 Android 版 dsh_runtime.dart 的 environment）──
    const tmpDir = `${this.ctx.filesDir}/tmp`;
    try {
      fileIo.mkdirSync(tmpDir, true);
    } catch (e) {
      // 已存在
    }

    const nodeBin = this.findLib('libnode.so');
    hilog.info(0x0001, 'NodeHost', 'nodeBin=%{public}s', nodeBin);
    const libDir = nodeBin.substring(0, nodeBin.lastIndexOf('/'));

    // ArkTS 不允许 Record 字面量（arkts-no-untyped-obj-literals），
    // 所以先建空对象再逐个赋值。
    const env: Record<string, string> = {};
    env['LD_LIBRARY_PATH'] = libDir;
    env['DSH_HOME'] = `${this.ctx.filesDir}/dshhome`;
    env['HOME'] = this.ctx.filesDir;
    env['PATH'] = `${this.ctx.bundleCodeDir}/bin:/system/bin`;
    env['TMPDIR'] = tmpDir;
    for (const k of Object.keys(extraEnv)) {
      env[k] = extraEnv[k];
    }
    steps.push(`env 准备了 ${Object.keys(env).length} 项`);

    // ── 4. 组装 argv ───────────────────────────────────────
    // 对齐 Android：node --expose-internals <dsh 入口> --profile <name> --no-open
    // ⚠️ argv 里不要放 nullptr 哨兵，native 侧只按长度算 argc。
    // ⚠️ dsh 的入口是 <dshDir>/lib/bin.js，不是 node_modules 里的 dsh.js
    //    （对齐 MainActivity.kt 的 dshBin）
    const dshBin = `${this.runtimeDir}/lib/bin.js`;
    const args: string[] = [
      '--expose-internals',
      dshBin,
      '--profile', profile,
      '--no-open',
    ];
    steps.push(`argv: ${args.join(' ')}`);

    // ── 5. 启动 ────────────────────────────────────────────
    try {
      const opts: NodeStartOptions = {
        libPath: nodeBin,
        args: args,
        env: env,
      };
      const r = nodehost.startNode(opts) as StartResult;
      steps.push(`startNode: ok=${r.ok} argc=${r.argc}`);
      if (r.ok) {
        this.started = true;
      }
      return { ok: r.ok, error: r.error, argc: r.argc, steps };
    } catch (e) {
      return { ok: false, error: `调用 startNode 抛异常: ${e}`, steps };
    }
  }

  /**
   * 以**调用方给的完整 argv** 启动 node（Bot 场景：--expose-internals --require shim
   * ... --profile bottest --patch ... --no-open --port N，与 Android 的拼法同源）。
   * 返回后 Dart 轮询 stdoutPath 抓就绪行。
   */
  async startCustom(args: string[], extraEnv: Record<string, string>,
    stdoutPath: string, tracePath: string): Promise<StartResult> {
    const steps: string[] = [];
    hilog.info(0x0001, 'NodeHost', 'startCustom 进入，args=%{public}d 项，stdout=%{public}s', args.length, stdoutPath);
    if (this.started) {
      return { ok: false, error: 'node 已启动过（每进程只能一次）', steps };
    }
    // ⚠️ 不再在这里调 probe()：probe 是同步 dlopen（92MB），会卡主线程
    //    触发 ANR（2026-10-28 真机：点了 Bot 后整个应用被杀重启）。
    //    加载全部挪到 native 后台线程；失败只写 hilog（tag=node_host）。
    const nodeBin = this.findLib('libnode.so');
    hilog.info(0x0001, 'NodeHost', 'nodeBin=%{public}s', nodeBin);
    const libDir = nodeBin.substring(0, nodeBin.lastIndexOf('/'));
    const tmpDir = `${this.ctx.filesDir}/tmp`;
    try {
      fileIo.mkdirSync(tmpDir, true);
    } catch (e) {
      // 已存在
    }
    const env: Record<string, string> = {};
    env['LD_LIBRARY_PATH'] = libDir;
    // ⚠️ DSH_HOME 是**数据目录**（files/dshhome），不是代码树（files/dsh）——
    //    对齐 MainActivity.kt 的 nodeHome()；写错会让 dsh 把会话/Bot 状态写到代码树里。
    env['DSH_HOME'] = `${this.ctx.filesDir}/dshhome`;
    env['HOME'] = this.ctx.filesDir;
    env['PATH'] = `${this.ctx.bundleCodeDir}/bin:/system/bin`;
    env['TMPDIR'] = tmpDir;
    for (const k of Object.keys(extraEnv)) {
      env[k] = extraEnv[k];
    }

    const opts: NodeStartOptions = {
      libPath: nodeBin,
      args: args,
      env: env,
      stdoutPath: stdoutPath,
      tracePath: tracePath,
    };
    hilog.info(0x0001, 'NodeHost', '调用 native startNode…（libPath=%{public}s trace=%{public}s）', opts.libPath, opts.tracePath ?? '');
    try {
      const r = nodehost.startNode(opts) as StartResult;
      hilog.info(0x0001, 'NodeHost', 'native 已返回 ok=%{public}s argc=%{public}d', String(r.ok), r.argc ?? -1);
      steps.push(`startCustom: ok=${r.ok} argc=${r.argc}`);
      if (r.ok) {
        this.started = true;
      }
      return { ok: r.ok, error: r.error, argc: r.argc, steps };
    } catch (e) {
      return { ok: false, error: `startCustom 抛异常: ${e}`, steps };
    }
  }

  /** 供 UI 展示的当前状态 */
  get isStarted(): boolean {
    return this.started;
  }

  get paths(): NodePaths {
    const p: NodePaths = {
      bundleCodeDir: this.ctx.bundleCodeDir,
      filesDir: this.ctx.filesDir,
      libnode: this.findLib('libnode.so'),
      runtime: this.runtimeDir,
    };
    return p;
  }
}
