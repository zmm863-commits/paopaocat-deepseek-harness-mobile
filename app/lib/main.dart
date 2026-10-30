import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'data/easter_egg.dart';
import 'data/builtin_skills.dart';
import 'data/configured_models.dart';
import 'data/expert_store.dart';
import 'data/memory_store.dart';
import 'i18n/dsh_i18n.dart';
import 'local/android_toolbox.dart';
import 'local/diagnostics_log.dart';
import 'data/polli_channel.dart';
import 'data/zen_channel.dart';
import 'local/dsh_runtime.dart';
import 'local/runtime_bootstrap.dart' show ensureRuntimeZip;
// 「检查更新」：启动后台查一次（结果塞进 AppSettings，设置页自己会读）。
import 'local/update_checker.dart';
import 'local/broadcast_feed.dart';
import 'state/app_settings.dart';
import 'state/model_store.dart';
import 'state/provider_keys.dart';
import 'ui/theme/dsh_grid.dart';
import 'ui/theme/dsh_tokens.dart';
import 'ui/app_shell.dart';
import 'ui/settings_page.dart';
import 'ui/setup_page.dart';

/// 语义树的持有句柄。必须保持引用，否则被回收后就失去可读性。
///
/// 它"没被引用"是刻意的：值本身不可达没关系，**持有**它才让语义树一直开着。
// 所以这里显式忽略 unused_element，而不是删掉声明（删了 uiautomator 就读不到文本）。
// ignore: unused_element
SemanticsHandle? _semanticsHandle;

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();

  // ── 诊断日志（用户要求：设置页能导出一份"看得出哪里出错"的日志）──────────
  //
  // 顺序很重要：**必须在任何业务代码之前**把 debugPrint 包住，否则启动阶段那几
  // 十行线索（版本自愈、技能安装、overlay 重写、代理起停）就白丢了 —— 而真机出
  // 问题时，最先要看的就是这些行。
  //
  // markProcessStart() 必须在这里：静态字段是首次访问才求值的，晚一步"运行时长"
  // 就会偏小（甚至显示 0 秒）。
  DiagnosticsLog.markProcessStart();
  DiagnosticsLog.installDebugPrintTee();
  // 引擎/平台层的未捕获异常（异步异常也走这里）。原有的行为不变：没有旧处理器
  // 时我们返回 false，系统照旧打印/上报。
  DiagnosticsLog.installPlatformErrorHook();

  // 布局/绘制异常必须落进 logcat。
  //
  // 为什么重要：Flutter 的 build 异常默认只在 debug console 打，装机后
  // `adb logcat -s flutter` 什么都看不到 —— 而界面出问题的表现往往是
  // **整页空白**（比如 Expanded/Spacer 被放进 unbounded 的滚动容器里）。
  // 没有这条日志就只能靠截图猜，排查成本极高。
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    // 结构化记一笔（异常 + 上下文 + 栈前 20 帧）到诊断日志；下面那些 debugPrint
    // 由 tee 跳过（`[dsh-flutter-error]` 前缀），免得同一份异常把缓冲占两遍。
    DiagnosticsLog.addFlutterError(
      'dsh-flutter-error',
      details.exception,
      details.stack,
      context: details.context,
    );
    debugPrint('[dsh-flutter-error] ${details.exception}');
    debugPrint('[dsh-flutter-error] context: ${details.context}');
    final stack = details.stack;
    if (stack != null) {
      final lines = stack.toString().split('\n');
      for (final line in lines.take(12)) {
        debugPrint('[dsh-flutter-error] $line');
      }
    }
    previousOnError?.call(details);
  };

  // 落盘：拿到私有目录立刻开文件（`<filesDir>/logs/dsh-diagnostic.log`）。
  // 失败只降级为"只在内存里"，绝不影响启动；加超时是为了万一原生通道不响应时
  // 不要卡在启动页。
  try {
    final paths = await DshHost.getPaths().timeout(const Duration(seconds: 3));
    final filesDir = paths['filesDir'] as String? ?? '';
    if (filesDir.isNotEmpty) {
      await DiagnosticsLog.init(filesDir: filesDir);
      // 全新安装就把「免费模型（无需 Key）」登记好（用户 2026-10-16 反馈：
      // 「首次安装后让配置模型，实际免费大模型是可以直接用的」—— 以前它只在用户
      // 手动打开那个开关时才写进 `models.json`，所以首启打开会话看到的是
      // "还没有可用模型，去填 API Key"，而免 Key 的那条路就在旁边）。
      // 失败不影响启动；只在配置完全空白时生效（见那个方法的说明）。
      unawaited(PolliChannel.ensureRegisteredOnFirstRun(filesDir: filesDir));
    }
  } catch (e) {
    debugPrint('[dsh-log] 初始化落盘失败（改为只在内存里保留）：$e');
  }

  // Flutter 是自绘引擎，默认情况下 uiautomator 读不到界面文本，
  // 自动化验证只能靠日志。启用语义树后界面文本可被无障碍服务读取，
  // 自动化就能直接断言"界面上出现了什么"。
  _semanticsHandle = binding.ensureSemantics();

  runApp(const DshMobileApp());
}

class DshMobileApp extends StatefulWidget {
  const DshMobileApp({super.key});

  @override
  State<DshMobileApp> createState() => _DshMobileAppState();
}

class _DshMobileAppState extends State<DshMobileApp> {
  /// App 级外观设置（主题/字号）。放在最顶层的原因：字号要影响**整棵树**，
  /// 包括之后 push 出来的对话页 —— 放在 AppShell 里就管不到那些页面了。
  final AppSettings _appSettings = AppSettings();

  @override
  void initState() {
    super.initState();
    _appSettings.load();
    // 彩蛋状态（连点首页那只猫 7 下解锁的那条实验通道）。**必须在这里读**：
    // 设置页是按需构建的，等它被打开再读就来不及"多出一块设置"了。
    EasterEggStore.instance.load();
  }

  @override
  void dispose() {
    _appSettings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _appSettings,
      builder: (context, _) {
        // ⚠️ 关键顺序：**先把当前皮肤喂给 DshColors，再建 MaterialApp**。
        // 这一层 build 之后，整棵树（含 Navigator 里推入的对话页/设置页）才会
        // 重新 build，于是它们读到的都是新皮肤的颜色 —— 换主题立即全树生效。
        final skin = _appSettings.skin;
        DshColors.applySkin(skin);
        // ── 界面语言：与皮肤同一处、同一时机喂进树里 ─────────────────────────
        //   1. setCurrent 让**拿不到 context 的 data 层**（拼错误文案、内置数据）
        //      也能按当前语言出字；
        //   2. DshI18n 这一层是给 UI 用的：语言一换，依赖它的 element 会被
        //      markNeedsBuild，于是 build() 重跑 —— **哪怕那个 widget 自己是
        //      const**。这是 `const Text('中文')` 能被刷新的唯一保证，
        //      机制说明见 i18n/dsh_i18n.dart。
        DshStrings.setCurrent(_appSettings.language);
        return DshI18n(
          language: _appSettings.language,
          child: MaterialApp(
            title: tr('泡泡猫的DSH'),
            debugShowCheckedModeBanner: false,
            // 两套皮肤：浅色逐条对齐 https://soft.zmm168.top/ 的 site.css 令牌；
            // 深色沿用 App 原有深色底 + 网站 accent 系的深色面。色值见
            // ui/theme/dsh_palette.dart，主题组装见 ui/theme/dsh_tokens.dart。
            theme: buildDshTheme(),
            // 字号设置必须在这里生效才会影响所有页面（含推入的全屏对话页）。
            //
            // ⚠️ 这里以前是 `TextScaler.linear(_appSettings.textScale)` —— 把系统的
            // textScaler **整体替换**掉。后果：用户在系统里把字体调大（需要大字的
            // 人一定会调），App **完全不跟随**（审计 P1-4）。无障碍上的硬伤：
            // 系统级设置被 App 单方面否决了。
            //
            // 现在与系统值**相乘**，两边都生效。
            // 上限 2.0 是**有意**加的：本 App 的布局按 dp 手排（顶栏、按钮、卡片
            // 高度都是写死的），倍率再往上会开始截断。与其让用户看到被切掉的文字，
            // 不如在这里封顶 —— **要抬高这个上限，必须先审一遍布局**。
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(
                  (MediaQuery.textScalerOf(context).scale(1.0) *
                          _appSettings.textScale)
                      .clamp(0.8, 2.0),
                ),
              ),
              child: Stack(
                children: [
                  // 背景层：底色 + 网格（美化，见 ui/theme/dsh_grid.dart）。
                  // 页面自己的底色是透明的（见 buildDshTheme 与各页面的 backgroundColor），
                  // 所以网格从底层透上来 —— 卡片、输入区仍是实底色，只有空白处能看见网格。
                  //
                  // ⚠️ 这里**不能**写 const：底色要随皮肤变化，const 实例在父级重建时会被
                  // 原样复用、不重新 build，导致换肤后背景层不重绘（残留上一套皮肤的颜色）。
                  // 传入 bgColor 同时起到"让这个 widget 不是 const"的作用。
                  DshGridBackground(
                    bgColor: DshColors.bg,
                    glowColor: DshColors.bgGlow,
                    // 用户自选的壁纸（外观 → 壁纸）。空 = 不用。
                    // 压暗强度与模糊也都是用户可调的（见设置页那三个控件）——
                    // 它们不是装饰：卡片是半透明的，正文的对比度靠这层压暗兜住。
                    wallpaperPath: _appSettings.wallpaperPath,
                    wallpaperDim: _appSettings.wallpaperDim,
                    wallpaperBlur: _appSettings.wallpaperBlur,
                    // 像素皮肤多一层扫描线（其余皮肤保持"干净的近黑底 + 柔光"，
                    // 用户当年明确否掉过网格线，别把它加回来）。
                    scanlines: DshMetrics.pixelStyle,
                    scanlineColor: DshColors.line,
                  ),
                  child ?? const SizedBox.shrink(),
                ],
              ),
            ),
            home: LocalShell(appSettings: _appSettings),
          ),
        );
      },
    );
  }
}

/// 本地运行的两种状态：
///   未解压 → [SetupPage]（一步引导，讲清楚必须先准备运行时）
///   已就绪 → [AppShell]（设计稿形态：5 项底部导航 + 各页）
///
/// DSH 编在 App 内，不存在"启动服务"这一步 —— 发一句话就直接执行。
class LocalShell extends StatefulWidget {
  const LocalShell({super.key, required this.appSettings});

  /// 顶层持有的外观设置（主题/字号），透传给「设置」页。
  final AppSettings appSettings;

  @override
  State<LocalShell> createState() => _LocalShellState();
}

class _LocalShellState extends State<LocalShell> {
  static const _secure = FlutterSecureStorage();
  static const _kApiKey = 'dsh_model_api_key';
  static const _kModel = 'dsh_model_id';
  static const _kBaseUrl = 'dsh_model_base_url';
  static const _kProvider = 'dsh_model_provider';

  final ModelStore _models = ModelStore();

  DshRuntime? _runtime;
  bool _ready = false;

  /// 当前是否跑在鸿蒙（flutter_ohos）上。
  ///
  /// 2026-10-28 真机实测：flutter_ohos 的 Platform.operatingSystem 返回 'ohos'，
  /// isAndroid 等 getter 全 false。直接正判 operatingSystem：
  /// Android 上返回 'android'，恒 false，行为完全不变。
  bool get _onOhos {
    if (kIsWeb) return false;
    try {
      return Platform.operatingSystem == 'ohos';
    } catch (_) {
      return false;
    }
  }

  /// 启动画面上的补充说明（运行环境换新时用；不是错误、也不是让人点按钮的页面）。
  String _bootNote = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _models.dispose();
    super.dispose();
  }

  Future<String?> _loadKey(Map<String, dynamic> paths) async {
    try {
      final stored = await _secure.read(key: _kApiKey);
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (_) {}

    // 开发/自动化入口：便于用 adb run-as 经 stdin 注入，避免 Key 出现在命令行里。
    try {
      final dev = File('${paths['filesDir']}/dev-api-key.txt');
      if (dev.existsSync()) return dev.readAsStringSync().trim();
    } catch (_) {}
    return null;
  }

  /// 建运行时对象：把**每个厂家各自的 Key** 读出来注入 node 进程的环境变量
  /// （overlay 里用 `apiKeyEnv` 引用变量名，所以凭据不会出现在命令行/进程列表）。
  ///
  /// 多厂家并存后，只注入一把 Key 是不够的 —— 用户的第 5、6 条反馈都依赖这里：
  /// 设了 A 厂家的 Key 之后还能用 B 厂家，以及轮换组里的成员各自带自己的 Key。
  Future<DshRuntime> _buildRuntime(Map<String, dynamic> paths) async {
    final env = await ProviderKeys.envFor(_models.config);
    final legacy = await _loadKey(paths);
    return DshRuntime(paths, apiKey: legacy, apiKeys: env);
  }

  /// 运行环境「能用但不是最新」时的**静默换新**（2026-10-19）。
  ///
  /// 为什么必须在 AppShell 之前：解包会整目录覆盖 `files/dsh`，而 ACP / Bot 的 node
  /// 进程正跑在里面 —— 边跑边换不安全。这里也不需要用户点任何按钮，只是让启动画面
  /// 多转一会儿；**失败了也不拦人**（旧运行环境照样能用，下次启动再试）。
  Future<void> _refreshRuntimeQuietly(DshRuntime rt) async {
    try {
      setState(() => _bootNote = context.tr('正在更新运行环境（一次性，约半分钟）…'));
      final r = await ensureRuntimeZip(
        filesDir: rt.filesDir,
        onProgress: (pg) {
          if (!mounted) return;
          final mb = (pg.received / 1048576).toStringAsFixed(1);
          final total = pg.total > 0 ? (pg.total / 1048576).toStringAsFixed(1) : '?';
          setState(() => _bootNote = context.tr('正在更新运行环境：{0} / {1} MB', [mb, total]));
        },
      );
      if (!r.ok) {
        DiagnosticsLog.add('dsh-boot', '运行环境静默更新：取压缩包失败（继续用旧版）= ${r.errorZh}');
        return;
      }
      if (!mounted) return;
      setState(() => _bootNote = context.tr('正在更新运行环境：解开文件（约 2.6 万个）…'));
      final ok = await DshHost.unpackRuntime();
      DiagnosticsLog.add(
          'dsh-boot', ok ? '运行环境已静默更新到最新内容版本' : '运行环境静默更新：解包失败（继续用旧版）');
    } catch (e) {
      DiagnosticsLog.add('dsh-boot', '运行环境静默更新失败（继续用旧版）：$e');
    }
  }

  Future<void> _init() async {
    try {
      // 先接上"返回手势/返回键"这条宿主通道（用户第 10 条：边缘侧滑不该一下退出）。
      // 必须尽早注册：它是原生 → Dart 的回调，晚注册就会漏掉前面几次返回。
      DshHost.bindBackHandler();

      final paths = await DshHost.getPaths();
      // ⚠️ 2026-10-19（用户两次反馈）：**进门只看「能不能用」**（运行环境已解开），
      //    不看「是不是最新」。运行环境有内容版本，一升版本那个标记就变 —— 拿它当门禁，
      //    升级的人会被拦进准备页，看着像被重装（用户原话：「装精简包不是应该直接进页面吗」）。
      //    换新改在启动画面里静默做（见下面的 _refreshRuntimeQuietly）。
      var ready = await DshHost.hasRuntime();
      var rtCurrent = await DshHost.runtimeCurrent();

      // ── 鸿蒙补偿（省略欢迎页后必须自己 bootstrap）────────────────────
      // SetupPage（欢迎页）在正常流程里**同时是自动 bootstrap 的触发点**
      // （用户点「开始准备」→ copyRuntimeAsset + unpackRuntime）。鸿蒙版按
      // 要求省掉欢迎页，bootstrap 就没人跑了 —— 症状：files/dsh 整个不存在
      // → Bot 报「没有 Bot 种子」、node 没脚本可跑。这里补上等价流程。
      if (!ready && _onOhos) {
        try {
          debugPrint('[dsh-boot:ohos] 运行环境随包准备中（欢迎页已省略，自动补跑）');
          final r = await ensureRuntimeZip(
            filesDir: paths['filesDir'] as String? ?? '',
            onProgress: (pg) {},
          );
          if (r.ok) {
            await DshHost.unpackRuntime();
          } else {
            debugPrint('[dsh-boot:ohos] 取随包运行环境失败: ${r.errorZh ?? ''}');
          }
          ready = await DshHost.hasRuntime();
          rtCurrent = await DshHost.runtimeCurrent();
          debugPrint('[dsh-boot:ohos] 解压完成 ready=$ready current=$rtCurrent');
        } catch (e, st) {
          debugPrint('[dsh-boot:ohos] 自动 bootstrap 失败: $e');
          debugPrint('[dsh-boot:ohos] 堆栈:\n${st.toString().split('\n').take(8).join('\n')}');
        }
      }

      // 先载入模型清单。真实来源是设置页写的 `<filesDir>/models.json`
      // （见 data/configured_models.dart）：没配过就是空的，
      // 界面会如实说"还没有可用模型"，而不是拿设计稿的假名字充数。
      // 注意：这一步必须在 runtime 之前完成 —— 没有 runtime 就没法写 overlay。
      final filesDir = paths['filesDir'] as String? ?? '';
      await _models.load(filesDir: filesDir);

      // ---- 老配置用户自愈（**很重要，不然升级后会"看不到模型"**）----
      //
      // 本版本之前配过模型的人，凭据与 model id 都在安全存储里，但**没有**
      // 新的 models.json（这个机制是刚加的）。不补的话，他们进对话页会看到
      // 「还没有可用模型」——明明配置还在、对话也能用，却选不到模型。
      //
      // 自愈方式：用安全存储里的那条配置补一个只有 1 个模型的 models.json。
      // 用户之后点「获取模型」就会换成真实列表。
      //
      // ⚠️ 触发条件里**必须**包含"文件不存在"这一条：`ModelStore.load` 现在会
      // 从安全存储/overlay 兜底，于是 `hasModels` 可能已经是 true，但磁盘上的
      // `models.json` 仍然是缺的 —— 只看 `hasModels` 会跳过自愈，结果
      // **设置页的「我的模型」永远是空的**（它只读这个文件）。
      final modelsJsonExists = File('$filesDir/models.json').existsSync();
      if (!_models.hasModels || !modelsJsonExists) {
        try {
          final storedModel = await _secure.read(key: _kModel);
          if (storedModel != null && storedModel.trim().isNotEmpty) {
            final storedBase = await _secure.read(key: _kBaseUrl) ?? '';
            final storedProvider = await _secure.read(key: _kProvider) ?? 'com';
            await ConfiguredModels.save(
              filesDir: filesDir,
              provider: storedProvider,
              baseUrl: storedBase,
              selectedId: storedModel.trim(),
              models: <({String id, String? name, int? context})>[
                (
                  id: storedModel.trim(),
                  name: storedModel.trim(),
                  context: null
                ),
              ],
            );
            await _models.load(filesDir: filesDir);
            debugPrint('[dsh-shell] 老配置自愈：已用安全存储里的 model id 补齐 models.json '
                '（${storedModel.trim()}）');
          }
        } catch (e) {
          debugPrint('[dsh-shell] 补齐 models.json 失败: $e');
        }
      }

      if (!mounted) return;

      // 先建运行时对象（拿到 DSH_HOME 等路径）。
      var runtime = await _buildRuntime(paths);

      // 随包工具箱（执行环境 shim + pptx 生成脚本 + 轮换代理脚本）先落到私有
      // 目录：shim 是靠 node `--require` 预加载的，必须早于任何 node 进程。
      await AndroidToolbox.ensureInstalled(filesDir);

      // 诊断开关（**默认关闭，零开销**）：私有目录里存在 `diag-spawn.txt` 且内容
      // 为 `on` 时，启动时跑一次 `node --version` 并把 exit/输出打进日志。
      // 为什么需要它：`adb shell run-as` 跑得起来的命令，从 App 进程里 spawn 未必
      // 起得来（SELinux 域不同）。真机排查"App 起 node 失败"时这条日志是第一个
      // 要看的证据（模型轮换代理就是这么翻车的）。
      if (File('$filesDir/diag-spawn.txt').existsSync() &&
          File('$filesDir/diag-spawn.txt').readAsStringSync().trim() == 'on') {
        try {
          final v = await runtime.nodeVersion();
          debugPrint('[dsh-diag] node --version → exit=${v.exitCode} '
              'stdout="${v.stdout.trim()}" stderr="${v.stderr.trim()}"');
        } catch (e) {
          debugPrint('[dsh-diag] node --version 抛异常：$e');
        }
      }

      // 内置技能装到 `<DSH_HOME>/skills`：技能不在设备上的话，模型手边就没有
      // "幻灯片 / 数据分析（/ 界面设计 / 值得再看一眼）"这类流程可用
      // （用户第 8 条反馈的根因）。首页那 12 条内置会话各绑其中一个 ——
      // 但列表里有几个技能**没有**首页入口，那是正常的，见 `data/builtin_skills.dart`。
      try {
        await BuiltinSkills.install(runtime.nodeHome);
      } catch (e) {
        debugPrint('[dsh-shell] 安装内置技能失败（不影响启动）: $e');
      }

      // `$DSH_HOME/AGENTS.md` 的受管区块：包含「本机可用的执行环境」说明
      // （有 node、怎么做真 .pptx）与已开启专家的角色设定。会话开始时才读，
      // 所以必须在任何会话之前确保它存在 —— 从没开过专家的用户也要有那一段，
      // 否则模型会以为"没有任何可执行环境"，把 PPT 降级成 HTML（用户第 3 条反馈）。
      try {
        final experts = ExpertStore(dshHome: runtime.nodeHome);
        await experts.load();
        await experts.ensureAgentsMd();
      } catch (e) {
        debugPrint('[dsh-shell] 写 AGENTS.md 失败（不影响启动）: $e');
      }

      // 「用户记忆」同样落在 `AGENTS.md`，但**是另一段带标记的受管区块**
      // （两边各自只剥自己的块，互不覆盖）。必须在任何会话之前确保一致 ——
      // 用户删掉一条记忆后如果这里不跑，AGENTS.md 里会一直留着已经删掉的内容
      // 并被注入，那是"界面说删了、模型还看得到"。
      try {
        final memory = MemoryStore(dshHome: runtime.nodeHome);
        await memory.load();
        await memory.ensureAgentsMd();
      } catch (e) {
        debugPrint('[dsh-shell] 写记忆块失败（不影响启动）: $e');
      }

      // 「免费模型（无需 Key）」：只有用户在设置里显式打开时才起代理并刷新模型
      // （默认关着 → 这里什么都不做、不花任何启动时间）。
      //
      // ⚠️ 顺序**必须**在这里：它会写 `models.json`，而下面 `ensureModelConfig`
      //    是照着那份配置去写 overlay 的。放到后面就等于"这轮 overlay 里没有免费模型"。
      // ⚠️ 代理端口每次启动都会变，所以这件事每次启动都要做一遍（见 ZenChannel 的注释）。
      try {
        await ZenChannel.refreshIfEnabled(
          enabled: widget.appSettings.zenEnabled,
          runtime: runtime,
        );
      } catch (e) {
        debugPrint('[dsh-shell] 社区免费通道刷新失败（不影响启动）: $e');
      }

      // 「免费模型（无需 Key）」= Pollinations 那条：**默认开着**，所以这里要真的
      // 拉一次模型清单写进配置 —— 这就是"装完不用填任何 Key 就能聊"的实现。
      //
      // ⚠️ 与 zen 那条同一个道理：必须**在 ensureModelConfig 之前**（它按这份配置写 overlay）。
      // ⚠️ 只有"配置里还没有它"时才等这一次网络（首次安装/被关过再打开）；已经有了就
      //    不等 —— 不然每次启动都被一次公网请求拖住（见 refreshIfEnabled 的注释）。
      try {
        await PolliChannel.refreshIfEnabled(
          enabled: widget.appSettings.polliEnabled,
          runtime: runtime,
        );
      } catch (e) {
        debugPrint('[dsh-shell] 免 Key 免费通道刷新失败（不影响启动）: $e');
      }

      // 运行时已就绪时立刻保证 overlay 存在：否则用户不进设置页就发消息，
      // 会退回官方端点并因凭据无效而失败（改造前就是这个行为）。
      if (ready) {
        await ensureModelConfig(
          runtime: runtime,
          models: _models,
          secure: _secure,
          // 联网搜索走原生后端：**只在运行时真带了那个插件、且用户开着**时才写进
          // overlay（老运行包上引用不存在的插件会让会话起不来 —— 那时改走 MCP，
          // 见 chat_page 的 _mcpServers）。
          nativeWebSearch:
              runtime.runtimeHasAnysearchPlugin && widget.appSettings.anysearchEnabled,
          subagentEnabled: widget.appSettings.subagentEnabled,
          subagentProvider: widget.appSettings.subagentRouteParts.$1,
          subagentModel: widget.appSettings.subagentRouteParts.$2,
        );
        runtime = await _buildRuntime(paths);
      }

      if (!mounted) return;

      // 能用但不是最新 → 在启动画面里静默换新（不弹页面、不要用户点按钮）。
      if (ready && !rtCurrent) {
        await _refreshRuntimeQuietly(runtime);
        if (!mounted) return;
      }

      setState(() {
        _runtime = runtime;
        _ready = ready;
        _loading = false;
      });

      // 「检查更新」：**启动后后台查一次**（不 await、失败静默、可在设置里关掉）。
      //
      // 放在这里而不是设置页里的原因：用户不进设置页也该知道有新版本 ——
      // 而"结果放哪儿"是这里唯一要操心的（塞进 AppSettings 的内存槽，
      // 设置页建起来时自己读，见 `_UpdateSectionState.initState`）。
      //
      // ⚠️ 必须**在启动流程的最后**、且**不 await**：网络不通时这次请求要等满
      // 超时，绝不能让它拖慢"App 能不能打开"。
      unawaited(_autoCheckUpdate());
      // 首页那条滚动公告：同样**启动后后台拉一次**（不 await、失败静默、不卡启动）。
      // 先读本地缓存再拉新的，所以断网也能看到上次那份（见 local/broadcast_feed.dart）。
      unawaited(_autoFetchBroadcast(runtime.filesDir));
    } catch (e) {
      debugPrint('[dsh-shell] init failed: $e');
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 启动后的那次自动检查更新。
  ///
  /// 三条纪律（都不是可选项）：
  ///   ① **不 await** —— 调用处已经 `unawaited`，这里也不能让任何异常冒出去；
  ///   ② **失败静默** —— 国内访问 GitHub 时好时坏，一次连不上不该弹窗；
  ///   ③ **尊重开关** —— 用户在设置里关掉「启动后自动检查」时，一个包也不发。
  ///
  /// 结果统一塞进 `AppSettings.lastUpdateResult`（内存态），设置页读它。
  /// 时间戳**成败都记**，这样设置页里那句"上次检查：刚刚"说的是"试过"，
  /// 而不是"成功过" —— 把失败的尝试藏起来会让用户以为 App 没在查。
  Future<void> _autoCheckUpdate() async {
    final s = widget.appSettings;
    if (!s.updateAutoCheck) {
      debugPrint('[dsh-update] 用户关掉了自动检查，这次一个包也不发');
      return;
    }
    try {
      // 自动那次**不绕缓存**：它是后台行为、不急，让 CDN 缓存正常发挥作用
      // （手动点「检查更新」才会挂 `?t=` 绕过去，见设置页）。
      final r = await checkForUpdate(customSource: s.updateSource);
      await s.noteUpdateChecked();
      if (!mounted) return;
      s.setLastUpdateResult(r);
      debugPrint('[dsh-update] 自动检查完成：${r.summary}');
    } catch (e) {
      // `checkForUpdate` 本身不抛（见它的文件头），这里只是最后一道保险。
      debugPrint('[dsh-update] 自动检查异常（已忽略）: $e');
    }
  }

  /// 启动后拉一次首页公告（`notice.json`）。
  ///
  /// 三条纪律与更新检查完全一致：不 await、失败静默、拉不到就不显示
  /// （首页那条栏宁可空着，也不写假话）。
  ///
  /// 顺序有讲究：**先摆缓存、再拉新的** —— 用户一进首页就有东西看，
  /// 网络慢也不会让那条栏先空一下再跳出来。
  Future<void> _autoFetchBroadcast(String filesDir) async {
    final s = widget.appSettings;
    try {
      final cached = loadCachedBroadcast(filesDir);
      if (cached != null && !cached.isEmpty) {
        s.setBroadcastFeed(cached);
        debugPrint('[dsh-notice] 先摆出缓存里的 ${cached.items.length} 条公告');
      }
      final fresh = await fetchBroadcastFeed();
      if (fresh == null || fresh.isEmpty) return;
      saveCachedBroadcast(filesDir, fresh);
      if (!mounted) return;
      s.setBroadcastFeed(fresh);
      debugPrint('[dsh-notice] 公告已更新：${fresh.items.length} 条');
    } catch (e) {
      // `fetchBroadcastFeed` 本身不抛（见它的文件头），这里只是最后一道保险。
      debugPrint('[dsh-notice] 拉公告异常（已忽略）: $e');
    }
  }

  /// 模型切换：重写 overlay → 重建 runtime 对象（overlay 路径不变，
  /// 但重建能保证 `hasModelConfig` 等状态被重新求值）。
  /// 对话页自己会监听 [ModelStore] 并重启 ACP 会话。
  Future<void> _onModelChanged() async {
    final rt = _runtime;
    if (rt == null) return;
    try {
      final paths = await DshHost.getPaths();
      final filesDir = paths['filesDir'] as String? ?? '';
      // ⚠️ **必须先把清单从磁盘读回来**。
      //
      // 底部「设置」Tab 的「测试并保存」会把模型写进 `models.json`，但它**不会**
      // 动内存里的 [ModelStore]。不重读的话，会话页拿到的还是启动时那份
      // （可能是空的）清单 → 界面显示「未配置模型」，**只有退出重进才正常**。
      // 这正是用户实测反馈的现象（「只有退出程序再进来打开会话，才能看见模型」）。
      await _models.reloadQuiet(filesDir: filesDir);
      await applyModelSelection(
        runtime: rt,
        models: _models,
        secure: _secure,
        nativeWebSearch:
            rt.runtimeHasAnysearchPlugin && widget.appSettings.anysearchEnabled,
        subagentEnabled: widget.appSettings.subagentEnabled,
        subagentProvider: widget.appSettings.subagentRouteParts.$1,
        subagentModel: widget.appSettings.subagentRouteParts.$2,
      );
      // ⚠️ 顺序在这里很重要（用户实测第 2 条「选一次不行，要选第二次」）：
      // **先把新清单落进 overlay，再让界面（会话页）看到新选中项**。反过来
      // （旧写法 `load()` 先 notify）会让监听者在这一瞬间按**还没重写的** overlay
      // 决定重建会话 —— 新进程读到的仍是旧默认路由，于是"看起来切了、实际没切"。
      _models.publish();
      final next = await _buildRuntime(paths);
      if (!mounted) return;
      setState(() => _runtime = next);
    } catch (e) {
      debugPrint('[dsh-shell] applyModelSelection failed: $e');
    }
  }

  Future<void> _openSettings() async {
    final rt = _runtime;
    if (rt == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SettingsPage(runtime: rt)),
    );
    // 返回后重新加载（Key / overlay / model id 都可能变了）
    try {
      final paths = await DshHost.getPaths();
      // 设置页可能改了模型清单（测试并保存会写 models.json）→ 重新读一次。
      // 用 reloadQuiet（不在这里发通知）：overlay 还没重写，这时候通知会话页
      // 会让它按旧 overlay 决定重建。下面 `_onModelChanged()` 里会按正确顺序
      // （重读 → 写 overlay → publish）发一次。
      await _models.reloadQuiet(filesDir: paths['filesDir'] as String? ?? '');
      await _onModelChanged();
      final next = await _buildRuntime(paths);
      if (!mounted) return;
      setState(() => _runtime = next);
    } catch (e) {
      debugPrint('[dsh-shell] reload after settings failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(strokeWidth: 2.5),
              if (_bootNote.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(_bootNote,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, color: DshColors.textDim)),
              ],
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(tr('泡泡猫的DSH'))),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: SelectableText(
            tr('初始化失败：{0}\n\n（这个界面只在 Android 上可用）', [_error]),
            style: TextStyle(color: DshColors.textDim, fontSize: 12.5),
          ),
        ),
      );
    }

    final rt = _runtime!;
    if (!_ready && !_onOhos) {
      return SetupPage(
        runtime: rt,
        onReady: () => setState(() => _ready = true),
      );
    }

    return AppShell(
      runtime: rt,
      models: _models,
      appSettings: widget.appSettings,
      onOpenSettings: _openSettings,
      onModelChanged: _onModelChanged,
    );
  }
}
