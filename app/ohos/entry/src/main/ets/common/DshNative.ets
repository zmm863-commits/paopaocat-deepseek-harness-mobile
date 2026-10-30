/*
 * DshNative.ets —— `dsh/native` 通道的鸿蒙实现
 *
 * Dart 侧（lib/local/dsh_runtime.dart）通过这个通道问原生要路径、要解压、要振动。
 * Android 侧是 MainActivity.kt，这里是对应的鸿蒙版。
 *
 * 语义严格对齐 MainActivity.kt，尤其是：
 *   - 解压映射：zip 里的 app/  → filesDir/dsh/，shims/ → filesDir/shims/
 *   - 就绪判定：filesDir/.dsh-runtime-<ver> 存在 且 dsh/lib/bin.js 存在
 *   - shims 覆盖：两个文件必须拷到 DSH 树里的指定位置，否则 node 起不来
 *
 * 路径定义（与 Android 完全一致，不要改）：
 *   dshDir   = filesDir/dsh
 *   shimDir  = filesDir/shims
 *   nodeHome = filesDir/dshhome
 *   dshBin   = filesDir/dsh/lib/bin.js
 *   marker   = filesDir/.dsh-runtime-5
 */

import { MethodChannel, MethodCall, MethodResult } from '@ohos/flutter_ohos';
import { BinaryMessenger } from '@ohos/flutter_ohos';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NodeHost } from './NodeHost';
import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'DSHNative';
const DOMAIN = 0x0001;

/** 与 MainActivity.kt 的 RUNTIME_VERSION 保持一致 */
const RUNTIME_VERSION = '5';

export class DshNative {
  private ctx: common.UIAbilityContext;
  private channel: MethodChannel;
  private unpacking: boolean = false;
  /** 进程内 node 的宿主（懒创建；node::Start 每进程一次，这里 **第二次直接被 native 闸门拒绝**） */
  private nodeHost: NodeHost | null = null;

  constructor(ctx: common.UIAbilityContext, messenger: BinaryMessenger) {
    this.ctx = ctx;
    this.channel = new MethodChannel(messenger, 'dsh/native');
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.handle(call, result);
      },
    });
    hilog.info(DOMAIN, TAG, 'dsh/native 通道已注册');
  }

  // ── 路径（与 Android 一致）────────────────────────────────
  private get filesDir(): string {
    return this.ctx.filesDir;
  }
  private get dshDir(): string {
    return `${this.filesDir}/dsh`;
  }
  private get shimDir(): string {
    return `${this.filesDir}/shims`;
  }
  private get nodeHome(): string {
    return `${this.filesDir}/dshhome`;
  }
  private get dshBin(): string {
    return `${this.dshDir}/lib/bin.js`;
  }
  private get marker(): string {
    return `${this.filesDir}/.dsh-runtime-${RUNTIME_VERSION}`;
  }

  /** 鸿蒙的 native 库目录 */
  private get nativeLibDir(): string {
    const candidates: string[] = [
      `${this.ctx.bundleCodeDir}/libs/arm64`,
      `${this.ctx.bundleCodeDir}/libs/arm64-v8a`,
    ];
    for (const p of candidates) {
      if (this.exists(`${p}/libnode.so`)) {
        return p;
      }
    }
    return candidates[0];
  }

  private exists(p: string): boolean {
    try {
      fileIo.statSync(p);
      return true;
    } catch (e) {
      return false;
    }
  }

  private mkdirp(p: string): void {
    try {
      fileIo.mkdirSync(p, true);
    } catch (e) {
      // 已存在
    }
  }

  // ── 判定 ──────────────────────────────────────────────────
  private isRuntimeReady(): boolean {
    return this.exists(this.marker) && this.exists(this.dshBin);
  }

  private hasRuntime(): boolean {
    return this.exists(this.dshBin);
  }

  private hasRuntimeAsset(): boolean {
    try {
      const files = this.ctx.resourceManager.getRawFileListSync('');
      for (const f of files) {
        if (f === 'dsh-runtime.zip') {
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  private runtimePaths(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    m.set('nativeLibDir', this.nativeLibDir);
    m.set('filesDir', this.filesDir);
    m.set('dshDir', this.dshDir);
    m.set('dshBin', this.dshBin);
    m.set('nodeHome', this.nodeHome);
    m.set('fsShim', `${this.shimDir}/android-fs-shim.cjs`);
    m.set('nodeBinary', `${this.nativeLibDir}/libnode.so`);
    m.set('runtimeVersion', RUNTIME_VERSION);
    return m;
  }

  // ── 随包 zip 落盘 ─────────────────────────────────────────
  /**
   * 把 rawfile 里的 dsh-runtime.zip 写到 filesDir/runtime.zip。
   *
   * Dart 侧的契约（dsh_runtime.dart:148）：无参数，返回字节数；0 = 没有 asset。
   * Dart 拿到 >0 的字节数才会走“随包自带”分支，不再联网下载。
   */
  private async copyRuntimeAssetZip(): Promise<number> {
    const zipPath = `${this.filesDir}/runtime.zip`;
    if (this.exists(zipPath)) {
      try {
        const st = fileIo.statSync(zipPath);
        if (st.size > 0) {
          return st.size;
        }
      } catch (e) {
        // 边角：stat 失败就重新拷一份
      }
    }
    const raw = await this.ctx.resourceManager.getRawFileContent('dsh-runtime.zip');
    const f = fileIo.openSync(zipPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    fileIo.writeSync(f.fd, raw.buffer as ArrayBuffer);
    fileIo.closeSync(f);
    hilog.info(DOMAIN, TAG, '随包 runtime.zip 已落盘 %{public}d 字节', raw.byteLength);
    return raw.byteLength;
  }

  // ── 解压 ──────────────────────────────────────────────────
  /**
   * 把随包的 dsh-runtime.zip 解开。
   *
   * 关键：zip 里是 app/ 和 shims/ 两个顶层目录，必须映射成
   * dsh/ 和 shims/。zlib.decompressFile 只会原样解到目标目录，
   * 所以先解到临时目录，再把 app 改名成 dsh。
   */
  private async unpackRuntime(): Promise<number> {
    const zipPath = `${this.filesDir}/runtime.zip`;
    if (!this.exists(zipPath)) {
      const raw = await this.ctx.resourceManager.getRawFileContent('dsh-runtime.zip');
      const f = fileIo.openSync(zipPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(f.fd, raw.buffer as ArrayBuffer);
      fileIo.closeSync(f);
      hilog.info(DOMAIN, TAG, 'runtime.zip 已取出 %{public}d 字节', raw.byteLength);
    }

    const tmpDir = `${this.filesDir}/.unpack-tmp`;
    // 清掉上次失败的残留
    try {
      fileIo.rmdirSync(tmpDir);
    } catch (e) {
      // 不存在
    }
    this.mkdirp(tmpDir);

    const t0 = Date.now();
    await zlib.decompressFile(zipPath, tmpDir);
    hilog.info(DOMAIN, TAG, '解压完成，耗时 %{public}dms', Date.now() - t0);

    // app/ → dsh/，shims/ → shims/
    this.mkdirp(this.dshDir);
    this.mkdirp(this.shimDir);
    const appTmp = `${tmpDir}/app`;
    const shimsTmp = `${tmpDir}/shims`;

    if (this.exists(appTmp)) {
      // dsh 已存在时先删（升级场景）
      try {
        fileIo.rmdirSync(this.dshDir);
      } catch (e) {
        // 不存在
      }
      fileIo.renameSync(appTmp, this.dshDir);
    }
    if (this.exists(shimsTmp)) {
      try {
        fileIo.rmdirSync(this.shimDir);
      } catch (e) {
        // 不存在
      }
      fileIo.renameSync(shimsTmp, this.shimDir);
    }

    try {
      fileIo.rmdirSync(tmpDir);
      fileIo.unlinkSync(zipPath);
    } catch (e) {
      // 清不掉也不影响
    }

    this.applyShims();
    this.mkdirp(this.nodeHome);
    this.mkdirp(`${this.filesDir}/tmp`);

    // 写 marker —— 这是"就绪"的判定依据
    const f2 = fileIo.openSync(this.marker,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    fileIo.writeSync(f2.fd, `v${RUNTIME_VERSION} unpacked\n`);
    fileIo.closeSync(f2);

    return 1;
  }

  /**
   * 覆盖两个 shim。缺了它们 node 起不来，而且是**静默失败**：
   *  - node-addon-require-builtin：该 addon 无鸿蒙构建，用纯 JS require 替代
   *  - node-addon-system/flock：musl/bionic 无 flock()，单进程退化为 no-op
   */
  private applyShims(): void {
    const pairs: string[][] = [
      [`${this.shimDir}/android-shim-require-builtin.js`,
       `${this.dshDir}/node_modules/node-addon-require-builtin/lib/index.js`],
      [`${this.shimDir}/android-shim-flock.js`,
       `${this.dshDir}/node_modules/@deepseek-ai/node-addon-system/lib/flock.js`],
    ];
    for (const pair of pairs) {
      const src = pair[0];
      const dst = pair[1];
      if (!this.exists(src)) {
        hilog.warn(DOMAIN, TAG, 'shim 缺失，跳过: %{public}s', src);
        continue;
      }
      const idx = dst.lastIndexOf('/');
      this.mkdirp(dst.substring(0, idx));
      try {
        fileIo.copyFileSync(src, dst);
      } catch (e) {
        hilog.error(DOMAIN, TAG, '覆盖 shim 失败 %{public}s: %{public}s', dst, `${e}`);
      }
    }
  }

  // ── 分发 ──────────────────────────────────────────────────
  private handle(call: MethodCall, result: MethodResult): void {
    const method = call.method;
    hilog.info(DOMAIN, TAG, '收到调用: %{public}s', method);
    try {
      switch (method) {
        case 'getPaths':
          result.success(this.runtimePaths());
          return;
        case 'isRuntimeReady':
          result.success(this.isRuntimeReady());
          return;
        case 'hasRuntime':
          result.success(this.hasRuntime());
          return;
        case 'runtimeCurrent':
          result.success(this.exists(this.marker));
          return;
        case 'hasRuntimeAsset':
          result.success(this.hasRuntimeAsset());
          return;
        case 'copyRuntimeAsset': {
          // 无参调用：拷 rawfile → filesDir/runtime.zip，回字节数
          this.copyRuntimeAssetZip().then((n) => {
            result.success(n);
          }).catch((e: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'copyRuntimeAsset 失败: %{public}s', `${e}`);
            result.error('COPY_ASSET_FAILED', `${e.message ?? e}`, null);
          });
          return;
        }
        case 'unpackRuntime': {
          if (this.isRuntimeReady()) {
            result.success(true);
            return;
          }
          if (this.unpacking) {
            result.error('ALREADY_UNPACKING', '运行时正在解压', null);
            return;
          }
          this.unpacking = true;
          this.unpackRuntime().then(() => {
            this.unpacking = false;
            result.success(true);
          }).catch((e: BusinessError) => {
            this.unpacking = false;
            hilog.error(DOMAIN, TAG, '解压失败: %{public}s', `${e}`);
            result.error('UNPACK_FAILED', `${e.message ?? e}`, null);
          });
          return;
        }
        case 'startSchedulerService':
          // 鸿蒙上还没有对应的前台服务实现，如实回报未实现，Dart 侧会优雅降级
          hilog.warn(DOMAIN, TAG, 'startSchedulerService 未实现（鸿蒙）');
          result.notImplemented();
          return;
        case 'stopSchedulerService':
          // 鸿蒙上本来就没有在跑的保活服务，"停止"即成功
          result.success(true);
          return;
        case 'startNode': {
          // 参数：{ args: string[], env: Map, stdoutPath: string, tracePath: string }
          // Dart 侧通过 StandardMethodCodec 传的是 Map（不是 Record），
          // 必须用 Map 接，否则 opts['args'] 取不到 → 空数组 → BAD_ARGS。
          const opts = call.args as Map<string, Object>;
          const argvRaw = opts.get('args');
          const argvList: string[] = (argvRaw instanceof Array)
            ? (argvRaw as Object[]).map((e: Object): string => e as string)
            : [];
          const envRaw = opts.get('env');
          const envObj: Record<string, string> = {};
          if (envRaw instanceof Map) {
            (envRaw as Map<string, Object>).forEach((v: Object, k: string) => {
              envObj[k] = v as string;
            });
          }
          const stdoutPath = (opts.get('stdoutPath') as string) ?? '';
          const tracePath = (opts.get('tracePath') as string) ?? '';
          hilog.info(DOMAIN, TAG, 'startNode 参数：args=%{public}d 项 stdout=%{public}s', argvList.length, stdoutPath);
          if (argvList.length === 0) {
            result.error('BAD_ARGS', 'startNode 需要 args 数组', null);
            return;
          }
          if (this.nodeHost === null) {
            this.nodeHost = new NodeHost(this.ctx);
          }
          this.nodeHost.startCustom(argvList, envObj, stdoutPath, tracePath)
            .then((r) => {
              const m: Map<string, Object> = new Map<string, Object>();
              m.set('ok', r.ok);
              m.set('argc', r.argc ?? -1);
              if (r.error !== undefined && r.error.length > 0) {
                m.set('error', r.error);
              }
              for (const st of r.steps) {
                hilog.info(DOMAIN, TAG, '  [node] %{public}s', st);
              }
              result.success(m);
            }).catch((e: BusinessError) => {
              hilog.error(DOMAIN, TAG, 'startNode 异常: %{public}s', `${e}`);
              result.error('START_NODE_FAILED', `${e.message ?? e}`, null);
            });
          return;
        }
        case 'deviceInfo':
          result.success(this.deviceInfoMap());
          return;
        case 'vibrate':
          this.doVibrate();
          result.success(true);
          return;
        case 'notificationStatus':
          // 鸿蒙的通知授权模型与 Android 不同，先如实回答"未请求"
          result.success('not_determined');
          return;
        case 'moveToBackground':
          // 鸿蒙的等价动作是 moveAbilityToBackground（在 UIAbilityContext 上）
          this.ctx.moveAbilityToBackground().catch(() => {});
          result.success(true);
          return;
        case 'openAppSettings':
          result.success(true);
          return;
        default:
          // 其余（语音、TTS、APK 相关等）在鸿蒙上没有对应实现。
          // 明确回 notImplemented，让 Dart 侧走它自己的降级分支，
          // 而不是用假数据把功能骗过去。
          hilog.warn(DOMAIN, TAG, '未实现的方法: %{public}s', method);
          result.notImplemented();
          return;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '%{public}s 抛异常: %{public}s', method, `${e}`);
      result.error('NATIVE_ERROR', `${e}`, null);
    }
  }

  private deviceInfoMap(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    try {
      m.set('model', deviceInfo.productModel ?? 'unknown');
      m.set('brand', deviceInfo.brand ?? 'unknown');
      m.set('osVersion', deviceInfo.osFullName ?? 'unknown');
      m.set('sdkApi', `${deviceInfo.sdkApiVersion}`);
      m.set('platform', 'ohos');
    } catch (e) {
      m.set('platform', 'ohos');
    }
    return m;
  }

  private doVibrate(): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 30 },
        { id: 0, usage: 'touch' }).catch(() => {});
    } catch (e) {
      // 无振动马达时静默
    }
  }
}
