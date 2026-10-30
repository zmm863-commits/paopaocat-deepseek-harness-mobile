
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { NodeHost } from '../common/NodeHost';
import { DshNative } from '../common/DshNative';
import { SharedPrefs } from '../common/SharedPrefs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import nodehost from 'libnodehost.so';

const TAG = 'DSHNode';
const DOMAIN = 0x0001;

export default class EntryAbility extends FlutterAbility {
  /** 全局唯一的 node 宿主。node::Start 每进程只能一次，所以必须是单例语义。 */
  private nodeHost: NodeHost | null = null;

  private dshNative: DshNative | null = null;

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // dsh/native 必须在这里注册：此时 messenger 已就绪，
    // 而且 Dart 侧的第一次 invokeMethod 会紧跟着引擎初始化发生。
    // 晚一步注册就是 MissingPluginException。
    try {
      const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
      this.dshNative = new DshNative(this.context as common.UIAbilityContext, messenger);
      // shared_preferences 的原生存储层：解决设置不持久（每次启动都是全新状态）
      const prefs = new SharedPrefs(this.context as common.UIAbilityContext, messenger);
      hilog.info(DOMAIN, TAG, 'dsh/native 已注册');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'dsh/native 注册失败: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 窗口创建完再起 node：此时 filesDir / bundleCodeDir 都已就绪，
   * 而且 Flutter 的渲染已经交给独立线程，不会跟 node 抢主线程。
   */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    super.onWindowStageCreate(windowStage);
    // ⚠️ 这里**故意不启动 node**。
    //
    // 原因（2026-10-26 用户反馈"有人说闪退"）：
    //   原先在这里直接 startNode()，而它会同步 dlopen 92 MB 的 libnode.so
    //   并触发 V8 初始化。V8 初始化失败时 node 会调 abort()，那是 SIGABRT，
    //   **整个 App 进程直接死**，用户看到的就是"一打开就闪退"。
    //
    // 冷启动路径上不能有任何可能 abort 的操作。node 改成显式触发
    // （见 AppStorage 里的 dshNodeAutoStart 开关，默认关）。
    hilog.info(DOMAIN, TAG, '窗口已创建，node 保持待命（不自动启动）');
    this.probeMemory();
  }

  /** 真机内存能力探针：回答 seccomp 到底禁了哪个 mmap/mprotect。 */
  private probeMemory(): void {
    try {
      const r = nodehost.probeMemory() as string;
      hilog.info(DOMAIN, TAG, '=== seccomp 探针 ===\n%{public}s', r);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'probeMemory 异常: %{public}s', JSON.stringify(e));
    }
  }

  /** 由 UI 显式调用才启动 node。这样即使 node 起不来，App 本身也能用。 */
  startNodeManually(): void {
    if (this.nodeHost === null) {
      this.startNode();
    }
  }

  private startNode(): void {
    try {
      // FlutterAbility 的 context 是 UIAbilityContext
      this.nodeHost = new NodeHost(this.context as common.UIAbilityContext);
      const paths = this.nodeHost.paths;
      hilog.info(DOMAIN, TAG, 'paths: %{public}s', JSON.stringify(paths));

      // 先自检：这一步不启动 node，只回答 .so 能不能 dlopen、符号在不在。
      // 装机后第一眼看这条日志，能省掉大量猜测。
      const probe = this.nodeHost.probe();
      hilog.info(DOMAIN, TAG, 'probe: %{public}s', JSON.stringify(probe));
      if (!probe.ok) {
        hilog.error(DOMAIN, TAG, 'libnode.so 不可用，跳过启动: %{public}s',
          JSON.stringify(probe));
        return;
      }

      // 真正启动。解压 runtime 可能要几十秒，不能阻塞 UI 线程，
      // 所以这里不 await，让它在后台跑完。
      this.nodeHost.start('default', {})
        .then((r) => {
          if (r.ok) {
            hilog.info(DOMAIN, TAG, 'node 已启动，argc=%{public}d', r.argc ?? -1);
            for (const s of r.steps) {
              hilog.info(DOMAIN, TAG, '  %{public}s', s);
            }
          } else {
            hilog.error(DOMAIN, TAG, 'node 启动失败: %{public}s', r.error ?? '');
            for (const s of r.steps) {
              hilog.error(DOMAIN, TAG, '  %{public}s', s);
            }
          }
        })
        .catch((e: BusinessError) => {
          hilog.error(DOMAIN, TAG, 'node 启动抛异常: %{public}d %{public}s',
            e.code, e.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'NodeHost 初始化失败: %{public}s', JSON.stringify(e));
    }
  }
}
