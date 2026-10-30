/*
 * SharedPrefs.ets —— `plugins.flutter.io/shared_preferences` 通道的原生鸿蒙实现
 *
 * 为什么不用官方插件：shared_preferences 没有发布 ohos 平台实现，Dart 侧在鸿蒙上
 * 直调这个 method channel（真机日志已证实：getAll → MissingPluginException）。
 * 所以在原生层把这套协议补齐，Dart 工程一行不用动。
 *
 * 协议（对齐 Android 的 MethodChannelSharedPreferencesStore）：
 *   getAll     → Map<String, Object>   key → 原类型值（String/bool/int/List<String>/double）
 *   setString(key, value) / setBool / setInt / setDouble / setStringList → bool
 *   remove(key) → bool ; clear() → bool
 *
 * 存储：应用私有目录下的 JSON 文件。Android 的 SharedPreferences 是 xml，
 * 这里用 JSON 等价承载；key 直接原样存（Dart 侧 key 自带 "flutter." 前缀语义）。
 */

import { MethodChannel, MethodCall, MethodResult } from '@ohos/flutter_ohos';
import { BinaryMessenger } from '@ohos/flutter_ohos';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'DshSharedPrefs';
const DOMAIN = 0x0001;

interface StoreShape {
  values: Record<string, Object>;
}

export class SharedPrefs {
  private ctx: common.UIAbilityContext;
  private storePath: string;
  private cache: Map<string, Object> = new Map<string, Object>();
  private dirty: boolean = false;

  constructor(ctx: common.UIAbilityContext, messenger: BinaryMessenger) {
    this.ctx = ctx;
    this.storePath = `${ctx.filesDir}/shared_prefs.json`;
    this.load();
    new MethodChannel(messenger, 'plugins.flutter.io/shared_preferences')
      .setMethodCallHandler({
        onMethodCall: (call: MethodCall, result: MethodResult): void => {
          this.handle(call, result);
        },
      });
    hilog.info(DOMAIN, TAG, 'shared_preferences 通道已注册（原生存储）');
  }

  private load(): void {
    try {
      const st = fileIo.statSync(this.storePath);
      if (st.size > 0) {
        const f = fileIo.openSync(this.storePath, fileIo.OpenMode.READ_ONLY);
        const buf = new ArrayBuffer(st.size);
        fileIo.readSync(f.fd, buf);
        fileIo.closeSync(f);
        const parsed: StoreShape = JSON.parse(String.fromCharCode(...new Uint8Array(buf))) as StoreShape;
        const m = new Map<string, Object>();
        const raw = parsed.values ?? {} as Record<string, Object>;
        for (const k of Object.keys(raw)) {
          m.set(k, raw[k] as Object);
        }
        this.cache = m;
      }
    } catch (e) {
      this.cache = new Map<string, Object>();
    }
    hilog.info(DOMAIN, TAG, 'load: %{public}d 条', this.cache.size);
  }

  private flush(): void {
    try {
      const out: Record<string, Object> = {};
      this.cache.forEach((v: Object, k: string) => {
        out[k] = v;
      });
      const f = fileIo.openSync(this.storePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const shape: StoreShape = { values: out };
      fileIo.writeSync(f.fd, JSON.stringify(shape));
      fileIo.closeSync(f);
      this.dirty = false;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'flush 失败: %{public}s', `${e}`);
    }
  }

  /** 复制 List 值，避免持有引用后外部改动影响缓存 */
  private sanitize(v: Object | undefined | null): Object | undefined | null {
    if (Array.isArray(v)) {
      return v.slice() as Object;
    }
    return v;
  }

  private handle(call: MethodCall, result: MethodResult): void {
    try {
      const m = call.method;
      const args = call.args as Record<string, Object> | null;
      switch (m) {
        case 'getAll': {
          const out = new Map<string, Object>();
          this.cache.forEach((v: Object, k: string) => {
            out.set(k, v);
          });
          result.success(out);
          return;
        }
        case 'setString': case 'setBool': case 'setInt': case 'setDouble': {
          const key = args?.['key'] as string;
          const val = this.sanitize(args?.['value'] as Object);
          if (key !== undefined && key !== null) {
            if (val === undefined || val === null) {
              this.cache.delete(key);
            } else {
              this.cache.set(key, val);
            }
            this.dirty = true;
            this.flush();
          }
          result.success(true);
          return;
        }
        case 'setStringList': {
          const key = args?.['key'] as string;
          const list = this.sanitize(args?.['value'] as Object);
          if (key !== undefined && key !== null) {
            if (list === undefined || list === null) {
              this.cache.delete(key);
            } else {
              this.cache.set(key, list);
            }
            this.dirty = true;
            this.flush();
          }
          result.success(true);
          return;
        }
        case 'remove': {
          const key = args?.['key'] as string;
          if (key !== undefined) {
            this.cache.delete(key);
            this.dirty = true;
            this.flush();
          }
          result.success(true);
          return;
        }
        case 'clear': {
          this.cache.clear();
          this.dirty = true;
          this.flush();
          result.success(true);
          return;
        }
        case 'reload': {
          this.load();
          result.success(true);
          return;
        }
        default:
          hilog.warn(DOMAIN, TAG, '未实现的 shared_prefs 方法: %{public}s', m);
          result.notImplemented();
          return;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '%{public}s 抛异常: %{public}s', call.method, `${e}`);
      result.error('PREFS_ERROR', `${e}`, null);
    }
  }
}
