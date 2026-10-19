import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/configured_models.dart';
import '../data/schedule_store.dart';
import '../data/workspace_store.dart';
import '../local/bot_server.dart';
import '../local/diagnostics_log.dart';
import '../local/dsh_runtime.dart';
import '../local/local_model_server.dart';
import '../local/rotation_proxy.dart';
import '../local/schedule_runner.dart';
import '../local/session_index.dart';
import '../state/session_registry.dart';
import '../state/app_settings.dart';
import '../state/model_store.dart';
import 'theme/dsh_tokens.dart';
import 'chat_page.dart';
import 'pages/bot_page.dart';
import 'pages/expert_page.dart';
import 'pages/library_page.dart';
import 'pages/memory_page.dart';
import 'pages/scheduled_page.dart';
import 'pages/local_chat_page.dart';
import 'pages/media_page.dart';
import 'pages/settings_tab.dart';
import 'pages/task_home_view.dart';
import 'pages/workspace_page.dart';
import 'widgets/bottom_nav.dart';

import '../i18n/dsh_i18n.dart';

/// 主外壳：底部 5 项导航 + 各页。
///
/// 设计稿的 5 个 Tab（`首页` / `专家` / `资料库` / `定时任务` / `项目`）在这里承载。
/// 对话页是**推入的全屏页**（设计稿 `page-01`~`04`/`11` 也是全屏对话），
/// 所以在对话页里点别的 Tab 会 pop 回来并切到对应 Tab。
///
/// 「工作区」**不是第 6 个 Tab**（底部 5 项是硬约束），而是首页顶栏右侧
/// 推入的一页（原设计稿 page-10 的位置）—— 它管的是 DSH 的 cwd 与会话，
/// 和底部导航的「项目」（多人协同项目空间）是两件事。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.runtime,
    required this.models,
    required this.appSettings,
    required this.onOpenSettings,
    required this.onModelChanged,
  });

  final DshRuntime runtime;
  final ModelStore models;

  /// App 级外观设置（主题/字号），透传给「设置」Tab。
  final AppSettings appSettings;
  final VoidCallback onOpenSettings;

  /// 模型切换后重建 overlay 并重新读取 runtime
  final Future<void> Function() onModelChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// 当前底部 Tab。
  ///
  /// ⚠️ 初始值不再是 0：真机反馈「用相机/相册取图回来会跳回首页」——
  /// 不管那是 Activity 被重建还是别的，**把"上次停在哪一页"存下来**都能让用户
  /// 回到原处。恢复在 [initState] 里做（那时才有 widget.appSettings）。
  int _index = 0;

  /// 页面控制器：**滑动切页的动画**靠它。
  ///
  /// 用户反馈「左右滑动切换页面太生硬，要有翻页效果」—— 原先的做法是
  /// `GestureDetector(onHorizontalDragEnd)` + `IndexedStack`：手指拖动时页面
  /// 纹丝不动，一松手**瞬间**跳到目标页。换成 [PageView] 之后，手指拖动页面
  /// 会跟着走、松手按惯性/弹簧弹到目标页 —— 这才是"翻页"。
  late final PageController _pageController =
      PageController(initialPage: _index);

  /// 屏幕左右各留多少像素**不响应**水平拖动 —— 让给系统的边缘返回手势。
  ///
  /// 32dp 是经验值：各家 Android 的边缘返回热区通常 16~24dp，留 32 能盖住，
  /// 又不至于把可用于翻页的区域压得太窄。
  static const double _edgeGutter = 32;

  /// 按下时的像素位置（松手时据此把页面弹到最近的整数页）。
  double? _dragOriginPixels;

  void _onPageDragStart(DragStartDetails _) {
    if (!_pageController.hasClients) return;
    _dragOriginPixels = _pageController.position.pixels;
  }

  /// 跟手：手指往左划 → 看下一页 → 内容整体左移（pixels 增大）。
  void _onPageDragUpdate(DragUpdateDetails d) {
    if (_dragOriginPixels == null || !_pageController.hasClients) return;
    final pos = _pageController.position;
    pos.jumpTo((pos.pixels - d.delta.dx).clamp(0.0, pos.maxScrollExtent));
  }

  void _onPageDragEnd(DragEndDetails d) {
    _dragOriginPixels = null;
    if (!_pageController.hasClients) return;
    final pos = _pageController.position;
    final w = pos.viewportDimension;
    if (w <= 0) return;

    final current = pos.pixels / w;
    final vx = d.velocity.pixelsPerSecond.dx;

    // 用户反馈「左右滑动丝滑一点」。原来的实现有两个"发涩"的点：
    //   ① **完全忽略甩动速度** —— 快速一甩只划过去 30% 也会被弹回来，
    //      必须老老实实拖过一半才翻页（这是最明显的"不跟手"）；
    //   ② 动画时长**写死 260ms** —— 只差一点点也要等 260ms，显得拖沓。
    //
    // 现在：超过阈值就算"甩动"，按方向直接翻一页；否则按距离取最近页。
    // 时长按**剩余距离**算（越近越干脆），并保留减速曲线让停下来的感觉自然。
    const flingVelocity = 300.0;
    // 方向判据（`current` 是"第几页"的小数形式；手指**向右**拖会让它**变小**）：
    //   * 向右拖/向右甩 → **上一页**；
    //   * 向左拖/向左甩 → 下一页。
    //
    // ⚠️ 2026-10-12 用户先提「向右滑不能一下就滑到首页」，我照那句改成了"右滑回首页"；
    //    他随后更正：**「搞错了，我的意思是右滑到上一个页面」** —— 所以这里保持
    //    **一页一页**（这也是 0.71 的行为），不跳首页。
    //
    // 顺手修掉一个真边界：原来右滑算的是 `current.ceil() - 1`，
    // 而 `current` 是**手指当前位置**的小数页号 —— 比如停在第 3 页、手指只拖了 40%
    // （current=3.4）再甩一下，`ceil(3.4)-1 = 3` → **原地不动**（"甩了却没反应"）。
    // 现在按**落定的页号 `_index`** 算，一次手势就稳定地前进/后退一页。
    final swipedRight = vx > flingVelocity ||
        (vx.abs() <= flingVelocity && current < _index);
    final swipedLeft = vx < -flingVelocity ||
        (vx.abs() <= flingVelocity && current > _index);

    var target = current.round();
    if (swipedLeft) {
      target = _index + 1;
    } else if (swipedRight) {
      target = _index - 1;
    }
    target = target.clamp(0, _pageTicks.length - 1);
    // 记住停在哪一页（取图/重建后能回到原处）。
    widget.appSettings.setLastTab(target);

    final distance = (target * w - pos.pixels).abs();
    final ms = (90 + (distance / w) * 170).round().clamp(110, 260);
    // 无论有没有换页，都要**弹到整数页** —— 否则会卡在两页中间。
    _pageController.animateToPage(
      target,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
    if (target != _index) {
      debugPrint('[dsh-nav] swipe -> ${DshBottomNav.items[target].label} '
          '($target, vx=${vx.round()}, ${ms}ms)');
      setState(() {
        _index = target;
        _pageTicks[target]++;
      });
    }
  }

  /// **所有会话进程的持有者**（见 `lib/state/session_registry.dart`）。
  ///
  /// 放在壳层而不是会话页：会话页是 push 出来的全屏路由，用户点底部别的 Tab
  /// 就会把它 pop 掉 —— 进程的生命周期必须比页面长，否则正在生成的回答会被打断。
  final SessionRegistry _liveSessions = SessionRegistry();

  /// 会话入口不再靠「记住最近一次的 id」，而是直接看 [_liveSessions] ——
  /// 那是**真实活着的进程**的清单，比记一个 id 准（见 [_openLiveSession]）。

  /// 每页一个**独立**的刷新计数：切到某页时只 +1 那一页，其它页不动。
  ///
  /// 用户要求「每切换一个按钮，就相当于刷新一次」。但如果用一个全局计数，
  /// IndexedStack 里 5 个页面会**一起**刷新（连没在看的也刷）—— 浪费还慢。
  /// 所以改成按页计数，只有刚切到的那页才会在 didUpdateWidget 里重载。
  final List<int> _pageTicks = List<int>.filled(6, 0);

  /// 切 Tab：记录下标，并只 bump 目标页自己的刷新计数。
  /// 切到第 [i] 页。
  ///
  /// [animate] 为 true 时用**翻页动画**滑过去（点底部导航走这条）；
  /// 为 false 时直接定位 —— 用在「从会话页 pop 回来」那种场景：
  /// 用户刚从全屏页面返回，再播一段滑动动画会显得莫名其妙。
  ///
  /// ⚠️ 用 [_pageController.page] 判断一次当前落点，避免
  /// "点击 → 动画 → onPageChanged 又调回来"的死循环。
  void _goToTab(int i, {bool animate = true}) {
    if (i < 0 || i >= _pageTicks.length) return;
    final changed = i != _index;
    if (changed) {
      setState(() {
        _index = i;
        _pageTicks[i]++;
      });
    }
    if (!_pageController.hasClients) return;
    final at = _pageController.page?.round() ?? _index;
    if (at == i) return;
    if (animate && changed) {
      _pageController.animateToPage(
        i,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _pageController.jumpToPage(i);
    }
  }

  /// 一键回到某个**活着的**会话（注册表里已经有它的进程）。
  ///
  /// 走的是与工作区页完全相同的 `resumeSessionId` 路径 —— 会话页在 `_start()`
  /// 里会先问注册表，命中就复用进程，绝不新起一个（所以那个正在跑的回答不会断）。
  Future<void> _openLiveSession(LiveSession live) async {
    debugPrint('[dsh-nav] 回到会话 ${live.sessionId ?? live.key}');
    await _openChat(
      resumeSessionId: live.sessionId,
      workspacePath: live.workspace,
    );
  }

  // 说明：0.15 时这里是 `_handleSwipe`（GestureDetector 判速度 → 瞬间换 index）。
  // 用户反馈「太生硬、要翻页效果」，0.18 起改用 PageView + 跟手拖动，
  // 并给屏幕左右各留 32dp 死区让位给系统边缘返回手势（见 build 的 body）。

  /// 工作区 + 会话的登记表（顶栏右侧「工作区」入口的数据源）。
  ///
  /// 工作区是**真实的目录**，会话有两种真实来源（本次运行 / 磁盘索引），
  /// 详见 [WorkspaceStore] 与 `local/session_index.dart` 的注释。
  late final WorkspaceStore _ws;

  /// 定时任务：任务/历史的持久化 + **进程内**调度器。
  ///
  /// 调度器到点会调 `DshRuntime.headless()` —— 与手打消息走的是同一条执行通道。
  /// 「后台运行」靠原生前台服务（`DshSchedulerService`）把进程留住，
  /// 见 `_syncSchedulerService`；App 被回收期间不会触发，恢复后如实记为「已错过」。
  late final ScheduleStore _schedules;
  late final ScheduleRunner _runner;

  /// 「专家」页的 Tab 切换请求（对话页附件菜单的「使用技能」会用到）。
  /// 「专家」页现在是**推入的整页**（不再是底部 Tab）。
  ///
  /// [initialTab] 用来满足"从对话页的附件菜单点【使用技能】"这种请求 ——
  /// 它要落在技能那一栏（1）。**不能在 push 之前 request**：那一瞬间页面还没
  /// initState，监听器没挂上，请求会丢。所以 push 之后下一帧再发。
  /// 打开「本地对话」（简单对话）。
  ///
  /// 两处会用到：① 底部「本地大模型」页里的按钮；② **取图被中断后的现场恢复**
  /// （见 [initState]）。
  Future<void> _openLocalChat() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalChatPage(
          dshHome: _runtime.nodeHome,
          settings: widget.appSettings,
          runtime: _runtime,
          onModelChanged: widget.onModelChanged,
        ),
      ),
    );
  }

  /// 打开「记忆」整页（长期偏好 + **从会话自动提炼的候选**）。
  ///
  /// ⚠️ 工作区路径**当场取**：记忆条目可以限定"只在某个工作区生效"，而工作区能在
  /// 别的页面被切走 —— 传一个缓存的路径进去，用户切完工作区再进来就会写错作用域。
  Future<void> _openMemoryPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemoryPage(
          dshHome: _runtime.nodeHome,
          workspacePath: _ws.current.path,
          workspaceLabel: _workspaceLabelFor(_ws.current.path),
          runtime: _runtime,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openExpertsPage({int initialTab = 0}) async {
    final req = ExpertTabRequest();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExpertPage(
          dshHome: _runtime.nodeHome,
          workspacePath: _ws.current.path,
          onOpenChatWithPrompt: _openChatForSkill,
          tabRequest: req,
        ),
      ),
    );
    if (!mounted) return;
    if (initialTab > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) req.request(initialTab);
      });
    }
  }

  /// 对话页的 key 序号：每开一页对话就 +1，保证不会复用上一个会话的状态。
  int _taskSeq = 0;

  /// **当前压在栈上的那一个会话页**（没有就是 null）。
  ///
  /// ## 为什么必须记住它（用户 2026-10-15 第 2 条）
  ///
  /// 用户原话：「同时在几个会话里恢复切换，再点其他功能发现出来的是会话。」
  ///
  /// 真机日志里就是现场：`open workspace page` → `open chat page(resume=A)`
  /// → `open workspace page` → `open chat page(resume=B)` 这样来回四轮。
  /// 成因是「工作区页里点一条会话」的动作 = `pop()`（关掉工作区页）**紧接着
  /// 又 push 一个会话页**，而**底下那个旧会话页从来没被关掉** —— 于是会话页
  /// 一层层叠起来。你在最上面那层点底部导航，它 `pop(i)` 只弹掉最上面一层，
  /// **露出来的是下面那个会话页**（不是首页），所以要点好几次才回到想去的地方
  /// （日志 16:40:26/27/28 连着三次「返回：关掉当前页」）。
  ///
  /// 现在改成：`_openChat` 进来先把上一个会话页**摘掉**（[NavigatorState.removeRoute]，
  /// 不走返回动画、也不会误伤别的页面），保证任何时刻栈上**最多一个会话页**。
  /// 它只管页面，进程仍然归 [SessionRegistry]，摘掉页面不会打断正在跑的回答。
  Route<Object?>? _chatRoute;

  /// 首页顶栏状态行显示的工作区路径（用来判断要不要重建，避免无谓 setState）
  String _wsLabel = '';

  DshRuntime get _runtime => widget.runtime;

  @override
  void initState() {
    super.initState();
    _ws = WorkspaceStore(_runtime.filesDir);
    _ws.addListener(_onWorkspaceStoreChanged);
    // 只读本机的登记表（很快）。
    // **刻意不在启动时**去拉磁盘会话索引 —— 那要另起一个 node 进程，
    // 会让冷启动变慢；改由用户真正打开「工作区」页时再拉（见 WorkspacePage）。
    _ws.load();

    // 定时任务：先读盘 → 标出 App 没运行时错过的计划 → 起调度器 → 同步保活服务。
    // 顺序有讲究：必须在 start() 之前 load()，否则调度器面对的是空列表。
    _schedules = ScheduleStore(_runtime.filesDir);
    _runner =
        ScheduleRunner(store: _schedules, runtimeOf: () => widget.runtime);
    _schedules.addListener(_onSchedulesChanged);
    _schedules.load().then((_) async {
      await _runner.start();
      await _syncSchedulerService();
    });

    // 导航恢复（上次的 Tab / 取图回来该落哪页）**每个进程只做一次**。
    // 以前它挂在 `_onSchedulesChanged` 上（定时任务一变就响），会把页反复推回来 ——
    // 用户 2026-10-12 报的"跳转到本地会话"就是这么来的。
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreNavOnce());

    // 把"返回手势/返回键该不该退"接上原生通道（用户第 10 条）。
    // 原生侧在收到手势时会问这里一次（见 MainActivity.dispatchBackToDart）。
    DshHost.onSystemBack = _shouldExitOnBack;
  }

  @override
  void dispose() {
    // 摘掉原生回调：State 销毁后原生不该再调到一个已经失效的对象。
    DshHost.onSystemBack = null;
    _pageController.dispose();
    _ws.removeListener(_onWorkspaceStoreChanged);
    _ws.dispose();
    // 壳销毁 = App 退出：不留一个空转的常驻通知。
    _runner.dispose();
    _schedules.removeListener(_onSchedulesChanged);
    _schedules.dispose();
    DshHost.stopSchedulerService();
    // 壳销毁 = App 退出：把还在跑的会话进程收尸。
    // （平时切页**不会**走到这里 —— 那正是"切页不打断回答"的意思。）
    unawaited(_liveSessions.closeAll());
    super.dispose();
  }

  /// 工作区换了（载入完成 / 用户切换）→ 首页顶栏那行状态要跟着变。
  /// 只在"当前工作区真的变了"时 setState，避免会话登记也把整壳重建一遍。
  void _onWorkspaceStoreChanged() {
    final label = _ws.loaded ? _ws.current.path : '';
    if (label == _wsLabel) return;
    _wsLabel = label;
    if (mounted) setState(() {});
  }

  /// 按「是否存在已启用任务」启停保活前台服务。
  ///
  /// 为什么放在这里而不是定时任务页里：启停要跟**全局状态**一致
  /// （用户在别的页面关掉最后一个任务时，通知也必须撤掉）。
  Future<void> _syncSchedulerService() async {
    final n = _schedules.enabledCount;
    if (n > 0) {
      await DshHost.startSchedulerService(n);
      debugPrint('[dsh-nav] 保活服务已启动（$n 个已启用任务）');
    } else {
      await DshHost.stopSchedulerService();
      debugPrint('[dsh-nav] 保活服务已停止（没有已启用任务）');
    }
  }

  void _onSchedulesChanged() {
    // ⚠️ **这里以前还兼着"恢复上次停留的 Tab"和"把本地对话推回来"** ——
    //    而它是个**调度器监听器**（定时任务一变就响，真机日志里一分钟响好几次）。
    //    结果就是用户 2026-10-12 报的那条：「退出去选其他服务有的时候会跳转到
    //    本地会话这个页面」—— 每一次调度变动都重新推一次页。
    //    现在这两件事挪到 [_restoreNavOnce]（**每个进程只做一次**，见 initState）。
    _syncSchedulerService();
    if (mounted) setState(() {});
  }

  /// 冷启动/进程重建时**只做一次**的导航恢复。
  ///
  /// 两件事：
  /// 1. 恢复上次停留的 Tab（**只在同一进程内**：用户 2026-10-11 要求冷启动一律回首页）；
  /// 2. 如果刚才是"去取图"离开的，**从哪来回哪去**。
  ///
  /// 第 2 点的口径（2026-10-12 修）：以前只记了时间戳、然后**一律**推「本地对话」——
  /// 于是**在影视页选一张参考图**，回来也会被推去本地对话。现在记下出发页，
  /// 只有从本地对话出发才推本地对话；从影视出发就靠第 1 点的 lastTab 回影视
  /// （影视页选图本来就不该换页）。
  void _restoreNavOnce() {
    if (_navRestored) return;
    _navRestored = true;

    final sessions = DshBottomNav.items.length;
    final restored = widget.appSettings.lastTab;
    if (AppSettings.lastTabRestorable && restored > 0 && restored < sessions) {
      _index = restored;
      debugPrint('[dsh-nav] 恢复上次停留的 Tab：$restored');
    }

    // 只认 3 分钟内的标记，而且只认**从本地对话出发**的那次。
    final from = widget.appSettings.pickInFlightFromWithin();
    if (from == 'localchat') {
      debugPrint('[dsh-nav] 检测到“刚才在本地对话里取图” → 把「本地对话」推回来');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openLocalChat();
      });
    } else if (from.isNotEmpty) {
      // 影视页出发的取图：不换页（lastTab 已经把它带回影视了）。
      // 留一行日志，下次再有"跳页"反馈时能一眼看出是谁推的。
      debugPrint('[dsh-nav] 刚才是从「$from」去取图的 → 按 lastTab 回原页，不推本地对话');
    }

    if (mounted) setState(() {});
  }

  /// 导航恢复只做一次（`_restoreNavOnce` 的闸）。
  bool _navRestored = false;

  /// 拉一次磁盘会话索引（ACP `session/list`）。
  Future<void> _refreshSessionIndex() =>
      _ws.refreshIndex(() => listPersistedSessions(runtime: _runtime));

  /// 「用对话生成技能」：打开对话页并预填指令；回来后自动重扫技能目录。
  Future<void> _openChatForSkill(String prompt) async {
    await _openChat(initialText: prompt);
    if (!mounted) return;
    // 生成完技能 → 打开专家页的技能栏，让他直接看到新技能。
    await _openExpertsPage(initialTab: 1);
  }

  Future<void> _openChat({
    String? initialText,
    String? resumeSessionId,
    String? workspacePath,
  }) async {
    final ws = workspacePath ?? _ws.current.path;
    debugPrint(
      '[dsh-nav] open chat page (initialText=${initialText ?? '-'} '
      'resume=${resumeSessionId ?? '-'} cwd=$ws)',
    );
    _taskSeq++;
    // 栈上已经有会话页 → 先摘掉它，绝不让两层会话页叠着（见 [_chatRoute] 的注释）。
    // 用 removeRoute 而不是 pop：pop 会播返回动画、还会把"用户按了返回"的语义
    // 混进上一次 _openChat 的返回值里；这里只是把它挪走。
    final stale = _chatRoute;
    if (stale != null) {
      _chatRoute = null;
      debugPrint('[dsh-nav] 摘掉上一层会话页（只允许一个会话页在栈上）');
      Navigator.of(context).removeRoute(stale);
      if (!mounted) return;
    }
    final route = MaterialPageRoute<Object?>(
      builder: (_) => ChatPage(
        key: ValueKey('chat-$_taskSeq'),
        runtime: _runtime,
        models: widget.models,
        // 会话进程归壳层所有：会话页被 pop 掉时不再杀进程，
        // 切页不会打断正在生成的回答（用户意见①）。
        sessions: _liveSessions,
        onOpenSettings: widget.onOpenSettings,
        initialText: initialText,
        workspacePath: ws,
        workspaceLabel: _workspaceLabelFor(ws),
        resumeSessionId: resumeSessionId,
        // 会话里要不要挂联网搜索（AnySearch）。默认开 —— 匿名可用、不用填 Key。
        anysearchEnabled: widget.appSettings.anysearchEnabled,
        // 思考块怎么显示（设置 → 外观）。壳层本来就因为皮肤/字号在监听设置，
        // 所以设置一改这里就跟着重建，不需要再造一个全局镜像。
        thinkingMode: widget.appSettings.thinkingModeId,
        onModelChanged: widget.onModelChanged,
        // 会话页顶栏右上角的「工作区」入口 = 首页右上角那一个（同一个页面）。
        onOpenWorkspaces: _openWorkspace,
        onSessionUsed: ({required id, required cwd, required title}) {
          _ws.noteSession(id: id, cwd: cwd, title: title);
        },
      ),
    );
    _chatRoute = route;
    final result = await Navigator.of(context).push<Object?>(route);
    // 只有"还是我这一页"时才清空 —— 否则会把新一页的登记抹掉
    //（旧页被移除时它的 await 也会回来一次）。
    if (identical(_chatRoute, route)) _chatRoute = null;
    if (!mounted) return;
    // 对话页里点了别的 Tab → 它 pop 回的是目标下标；
    // 附件菜单的「使用技能」/「定时任务」会多带一个 expertTab 子页请求。
    if (result is int && result >= 0 && result < DshBottomNav.items.length) {
      _goToTab(result);
    } else if (result is Map) {
      final tab = result['tab'];
      if (tab is int && tab >= 0 && tab < DshBottomNav.items.length) {
        _goToTab(tab);
      }
      final sub = result['expertTab'];
      if (sub is int) await _openExpertsPage(initialTab: sub);
    }
  }

  /// 某个 cwd 的展示名：登记表里有这个名字就用它，没有就退到路径末段。
  /// **不编名字** —— 界面上的名字必须来自登记表或真实路径。
  /// 用途：会话页顶栏第二行 `本机 · <工作区名>`（右上角工作区入口的说明）。
  String _workspaceLabelFor(String path) {
    for (final w in _ws.allWorkspaces) {
      if (w.path == path) return w.name;
    }
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  // 「Bot 团队」曾经是首页顶栏推入的一页（`_openBot`）。2026-10-17 用户要求
  // 「bot 是放在底部导航栏，首页按钮的右边」→ 它现在是**底部导航的一项**，
  // 直接挂在下面的 `pages` 列表里（下标 1），不再需要单独的推入入口。

  /// 打开工作区管理器（首页顶栏右侧 + 会话页顶栏右侧，**同一个功能**）。
  Future<void> _openWorkspace() async {
    debugPrint('[dsh-nav] open workspace page (current=${_ws.current.path})');
    await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        builder: (_) => WorkspacePage(
          store: _ws,
          onNewWorkspace: _newWorkspace,
          onRefreshIndex: _refreshSessionIndex,
          onOpenSession: (session, workspace) {
            Navigator.of(context).pop();
            _openChat(
                resumeSessionId: session.id, workspacePath: workspace.path);
          },
        ),
      ),
    );
  }

  /// 新建工作区：输入名字 → **真在本机建目录** → 入列并切过去。
  Future<void> _newWorkspace() async {
    // ⚠️ 输入框控制器由对话框自己持有并释放。
    // 之前是在这里 new 一个、`showDialog` 返回后立刻 dispose —— 但对话框
    // 退场动画期间 TextField 还活着，于是抛
    // `A TextEditingController was used after being disposed`，
    // 并连锁出 RenderFlex overflow + 元素树断言失败（整页塌成空白）。
    // 现在的写法让 dispose 发生在路由真正销毁时。
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const _NewWorkspaceDialog(),
    );
    if (!mounted || name == null) return;

    final created = await _ws.createWorkspace(name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          created == null
              ? context.tr('工作区名不能为空')
              : context
                  .tr('已新建工作区「{0}」并切为当前：{1}', [created.name, created.path]),
        ),
      ),
    );
  }

  /// 上一次「系统返回」的时间戳：用来实现**再滑动一次才退出**。
  ///
  /// 用户实测反馈（第 10 条）：
  /// 「用户可以滑动屏幕切换页面，但是手机屏最边缘滑动有的时候会退到手机屏幕，
  ///   这里加一个再滑动一次退出（实际是退到后台了）」
  ///
  /// 根因：Android 的边缘侧滑返回属于**系统手势**（屏幕左右各约 20dp 的手势区），
  /// App 自己的横向滑动抢不过它 —— 用户在资料库/专家页想左右滑时，手一贴边就被判成
  /// 返回，一下就把 App 退到后台。而且 targetSdk ≥ 35 时这个手势由系统直接处理，
  /// Flutter 框架收不到（实测：Dart 侧一行日志都没有），所以原生侧注册了
  /// `OnBackInvokedCallback` 并把决定权交回这里（见 MainActivity.dispatchBackToDart）。
  ///
  /// 规则（返回 true = 可以退到后台）：
  ///   1. 还有页面可以关（对话页/设置等被 push 进来的）→ 关掉它，不退；
  ///   2. 不在「首页」→ 先切回首页，不退；
  ///   3. 在「首页」→ 第一次只提示，**2 秒内再来一次**才真的退。
  DateTime? _lastBackAt;

  /// 两次返回之间允许的最大间隔（超过就重新计数）。
  static const Duration _backTwiceWindow = Duration(seconds: 2);

  Future<bool> _shouldExitOnBack() async {
    if (!mounted) return true;

    // 1) 先关掉 push 进来的页面（对话页、资料库预览、工作区…）。
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      debugPrint('[dsh-nav] 返回：关掉当前页');
      nav.pop();
      return false;
    }

    // 2) 不在首页：先回首页，别退。
    if (_index != 0) {
      debugPrint('[dsh-nav] 返回：先切回首页（当前 $_index）');
      _goToTab(0);
      return false;
    }

    // 3) 已经在首页：需要**连续两次**才退。
    final now = DateTime.now();
    final last = _lastBackAt;
    if (last != null && now.difference(last) <= _backTwiceWindow) {
      _lastBackAt = null;
      debugPrint('[dsh-nav] 连续两次返回 → 退到后台');
      DiagnosticsLog.add('dsh-nav', '连续两次返回 → 退到后台（原生 moveTaskToBack）');
      return true;
    }
    _lastBackAt = now;
    debugPrint('[dsh-nav] 第一次返回：只提示，不退出');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(context.tr('再滑动（或按返回）一次就退出 App（会退到后台）')),
          duration: const Duration(milliseconds: 1800),
        ),
      );
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      TaskHomeView(
        models: widget.models,
        // 首页那条滚动公告读它（启动时由 main.dart 拉一次，见 local/broadcast_feed.dart）。
        appSettings: widget.appSettings,
        // 下标 5 = 底部「设置」（见 DshBottomNav.items 的顺序：加了「影视」后设置右移一位）。
        // 首页在"还没有模型"时要有一个直达设置的动作 —— 用户实测反馈第 4 条：
        // 首次安装没配模型时，首页那个「开始」按钮点了没有有效引导。
        // 这里只是把"切到设置 Tab"这个已有能力暴露出去，不动模型/overlay 逻辑。
        onOpenModelSettings: () => _goToTab(5),
        onOpenChat: ({String? initialText}) =>
            _openChat(initialText: initialText),
        onOpenWorkspace: _openWorkspace,
        workspaceName: _ws.current.name,
      ),
      // 下标 1 =「Bot 团队」（用户 2026-10-17：放在首页右边）。
      //
      // ⚠️ 2026-10-17 用户实测后的决定：**回到 WebView（网页版）方案**。
      // 原因不是原生方案"做不出来"，而是它踩在一个**极简底座**上：
      //   * 网页版跑的是**完整 dsh web**（`bottest` = dsh-base + dsh-web-app + ds-bot），
      //     与桌面版同源，会话/群聊/Bot 全在网页内 → 用户实测「网页版可以跑通」；
      //   * 原生版改走 **ACP**（`--profile acp`，bundles 只有 dsh-base + dsh-acp-app、
      //     patch 层是空数组），于是每发现一样"桌面版有它没有"的东西就得补一样：
      //     TMPDIR、cookie、Key 变量名、协议声明、权限预设、插件包……补了 13 个版本。
      // 所以这里回到 BotPage（WebView）。**其余修复全部保留**（浅色字色、模型设置、
      // OpenCode Go、探活补头、shared_preferences 钉版本…那些与页面方案无关）。
      BotPage(runtime: _runtime),
      // ⚠️ 原下标 1 =「本地大模型」**已撤下**（用户 2026-10-12：功能不够成熟，
      //    连知识库一起从界面拿掉）。页面文件与引擎都保留（可逆方案），
      //    只是不再挂进这个列表 —— 想恢复就把上面那段放回来并把下面下标全体后移。
      // 「专家」不再是底部 Tab（用户 2026-10-09：挪进设置页）。它现在是**推入的整页**
      // —— 见 [_openExpertsPage]。
      // 下标 2 = 「影视」（用户 2026-10-11：放在「本地大模型」右边）。
      MediaPage(
        runtime: _runtime,
        settings: widget.appSettings,
        // 「去设置配 Key」交给壳层做 —— 只有它知道最新下标（这次就因为它知道，
        // 才不会重演"写死下标 → 跳错页"）。
        onOpenSettings: () => _goToTab(5),
        // 「创作台 → 创作」里那些「开始…会话」按钮：带首句开一个新会话。
        // ⚠️ **不能再用 `_openChatForSkill`** —— 那个方法（见下方）在会话关闭后
        //    会**再推一个「专家 → 技能」页**，那是给「用对话生成技能」这条流程准备的
        //    （生成完技能要让人立刻看到）。创作台借用它的时候，用户在会话页按返回
        //    就会被弹到专家页，表现成"点了就跳去专家技能页、没法往下走"
        //    —— 2026-10-12 真机反馈第 6/7/8 条就是这么来的。
        onStartPrompt: (prompt) => _openChat(initialText: prompt),
        refreshTick: _pageTicks[2],
        // 右上角「这次用哪三个模型」里的**文本模型**要从这儿读（就是会话模型）。
        models: widget.models,
      ),
      LibraryPage(
        refreshTick: _pageTicks[3],
        // 「作品」从创作台入口屏挪到了资料库（用户 2026-10-12 真机反馈第 4 条）：
        // 这里推的是**同一个创作台页**，只是让它直接落在「作品库」那一格，
        // 所以九宫格视图只有一份（见 MediaPage.initialSeg）。
        onOpenWorks: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MediaPage(
              runtime: _runtime,
              settings: widget.appSettings,
              onOpenSettings: () => _goToTab(5),
              onStartPrompt: (prompt) => _openChat(initialText: prompt),
              initialSeg: 5,
              models: widget.models,
            ),
          ),
        ),
      ),
      ScheduledPage(
          store: _schedules, runner: _runner, refreshTick: _pageTicks[4]),
      // 原「项目空间」→ 用户要求改为「设置」（外观 / 模型 / 插件 / 关于）。
      // project_page.dart 已不再挂载，文件保留作设计稿参考。
      SettingsTab(
        runtime: _runtime,
        appSettings: widget.appSettings,
        onModelChanged: widget.onModelChanged,
        onOpenExperts: _openExpertsPage,
        onOpenMemory: _openMemoryPage,
        refreshTick: _pageTicks[5],
      ),
    ];

    return PopScope(
      // 这条 PopScope 是**兜底**：原生那条路（OnBackInvokedCallback）在真机上是
      // 确定会走到的（见 MainActivity），但万一某台设备/某个版本上框架这条路更快，
      // 也让它走同一套判断，别出现"两套行为不一样"。
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        unawaited(_shouldExitOnBack().then((canExit) async {
          if (!canExit) return;
          // ⚠️ 这里**不能**用 `SystemNavigator.pop()`（那是结束 Activity）：
          //    本 App 有前台服务/常驻进程，Activity 结束后从任务里回来会是一屏黑，
          //    用户只能清退。统一走原生那条：退到后台。
          DiagnosticsLog.add('dsh-nav', '返回（框架兜底路径）→ 退到后台');
          await DshHost.moveToBackground();
        }));
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // 左右滑动切页 = **跟手翻页 + 边缘让位**。
        //
        // 为什么不是直接用 PageView 自带手势（0.18 早期这么做过，翻车了）：
        // PageView 会把**屏幕最边缘**的水平滑动也吃掉，而那里本该归系统的边缘
        // 返回手势。结果是 —— 中间几页从边缘滑会变成"切页"，只有滑到最后一页
        // （没得可切了）手势才漏给系统、才触发返回。
        // 用户反馈的原话就是「只有最后一页，才能双滑退出」。
        //
        // 现在改成：
        //   * PageView 自己**不吃手势**（NeverScrollableScrollPhysics）；
        //   * 中间区域盖一层拖动手势，左右各留 [_edgeGutter] 让给系统；
        //   * 拖动时手动驱动 controller —— 所以**仍然跟手**；松手弹到最近页（有动画）。
        //
        // 另外每页都套了 [_KeepAlive]：PageView 默认只保活当前页附近，
        // 而壳层原先用 IndexedStack 是**全部**保活的（专家库、滚动位置、
        // 资料库扫描结果都靠这个）。
        body: Stack(
          children: <Widget>[
            PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) {
                // 手指/动画落位后同步状态。这里**只更新状态、不驱动 controller**，
                // 否则会和 [_goToTab] 互相触发。
                if (i == _index) return;
                debugPrint(
                    '[dsh-nav] swipe -> ${DshBottomNav.items[i].label} ($i)');
                setState(() {
                  _index = i;
                  _pageTicks[i]++;
                });
                // 滑动切页也要记住（与 [_goToTab] 一致）。
                widget.appSettings.setLastTab(i);
              },
              children: <Widget>[
                for (final p in pages) _KeepAlive(child: p),
              ],
            ),
            // 可拖动层：左右各留出 [_edgeGutter]，让系统边缘返回手势照常工作。
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: _edgeGutter),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: _onPageDragStart,
                  onHorizontalDragUpdate: _onPageDragUpdate,
                  onHorizontalDragEnd: _onPageDragEnd,
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 首页上方的「回到会话」入口（用户意见①）：
            // 直接看**壳层注册表里真实活着的**会话 —— 切换页面后一键回去，
            // 正在回答的还会标出来（切页不会打断它，见 SessionRegistry）。
            if (_index == 0)
              AnimatedBuilder(
                animation: _liveSessions,
                builder: (context, _) {
                  final live = _liveSessions.all;
                  if (live.isEmpty) return const SizedBox.shrink();
                  final top = live.first;
                  final answering = live.where((s) => s.running).length;
                  final name = top.title ??
                      (top.sessionId != null
                          ? context
                              .tr('会话 {0}', [top.sessionId!.substring(0, 8)])
                          : context.tr('会话'));
                  return _ResumeSessionBar(
                    label:
                        answering > 0 ? context.tr('{0}（正在回答）', [name]) : name,
                    onTap: () => _openLiveSession(top),
                  );
                },
              ),
            DshBottomNav(
              currentIndex: _index,
              onTap: (i) {
                // 打日志是刻意的：Flutter 是自绘引擎，自动化点击很难从截图上判断
                // 到底有没有生效，日志是唯一可靠的"交互确实发生了"的证据。
                debugPrint(
                    '[dsh-nav] tab -> ${DshBottomNav.items[i].label} ($i)');
                _goToTab(i);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 让 [PageView] 里的页面**保持存活**。
///
/// PageView 默认只保活"当前页附近"，而壳层原先用的 IndexedStack 是**全部**保活的：
/// 专家库加载结果、各页滚动位置、资料库扫描结果都依赖这一点。
/// 少了这层包装，来回切页会重新加载、滚动位置也会回到顶部。
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // AutomaticKeepAliveClientMixin 要求先调 super.build
    super.build(context);
    return widget.child;
  }
}

/// 首页底部的「继续上次会话」入口（用户意见①）。
///
/// 样式刻意做成一条低调的横向条：不抢首页主体（品牌区 + 输入框），
/// 只在**真的发起过会话**时才出现，不会白占地方。
class _ResumeSessionBar extends StatelessWidget {
  const _ResumeSessionBar({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.tr('继续上次会话'),
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: DshMetrics.pagePad,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            color: DshColors.surface,
            border: Border(
              bottom: BorderSide(color: DshColors.line, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.history, size: 15, color: DshColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.tr('继续上次会话：{0}', [label]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: DshColors.text, fontSize: 12),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: DshColors.textDim),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「新建工作区」输入弹层。
///
/// 做成 StatefulWidget 的唯一理由：**控制器的生命周期要跟对话框路由对齐**。
/// 由调用方 new 一个控制器再在 `showDialog` 返回后立刻 dispose 会让退场动画
/// 期间的 TextField 用到已释放的控制器（实测会连锁出一串布局异常）。
class _NewWorkspaceDialog extends StatefulWidget {
  const _NewWorkspaceDialog();

  @override
  State<_NewWorkspaceDialog> createState() => _NewWorkspaceDialogState();
}

class _NewWorkspaceDialogState extends State<_NewWorkspaceDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DshColors.surfaceStrong,
      title: Text(context.tr('新建工作区'), style: const TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('工作区就是 DSH 运行的工作目录，会在这台手机的应用私有目录下建一个真实的文件夹。'),
            style:
                TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(hintText: context.tr('工作区名称')),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(context.tr('创建')),
        ),
      ],
    );
  }
}

/// 把「界面选中的模型」翻译成「真正写进 overlay 的 model id」。
///
/// ⚠️ **本轮大幅简化（用户实测反馈驱动）**
///
/// 之前这里有"设计稿显示名 → 用户真实 model id"的一层映射：清单里写死的
/// `Hy4 preview` / `GLM-5.3` 在用户端点上并不存在，于是**不管点哪个都回落到
/// 用户配的那个模型** —— 表现就是用户反馈的「我选择任何模型都可以会话，
/// 明明没有配置」。
///
/// 现在模型清单**全部来自用户自己的配置**（设置页写的 `models.json`，
/// 见 `data/configured_models.dart`），每条 `routeId` 就是一个真实存在的
/// model id，不需要任何映射。清单为空时 `route` 为 null，
/// 调用方就不写 overlay —— 不编"能跑"的假象。
({String? route, List<String> others}) resolveActiveRoute({
  required ModelStore models,
}) {
  final route = models.selected?.routeId ?? models.activeRouteId;
  return (
    route: route,
    others: models.otherRouteIds.where((r) => r != route).toList(),
  );
}

/// 模型发生变化时：把**整份配置**（所有厂家 + 轮换组）重写成 overlay，
/// 默认路由指向选中项。
///
/// 为什么要重写而不是"发个命令切"：DSH 的模型路由由 overlay 决定，
/// overlay 在子进程启动时读入 —— 所以切换的落地方式是"改配置 + 重启会话"。
///
/// 为什么要写**整份**而不是只写选中的那个：用户实测反馈「设置完一个模型就
/// 无法再选其他厂家」。DSH 路由里没声明过的 model 会直接报未知模型，
/// 所以每个厂家的每个模型、以及每个轮换组，都必须一直待在 overlay 里。
Future<void> applyModelSelection({
  required DshRuntime runtime,
  required ModelStore models,
  required FlutterSecureStorage secure,
  /// 会话里要不要激活 AnySearch 的搜索后端（**只在运行时真有那个插件时才为 true**，
  /// 见 `DshRuntime.runtimeHasAnysearchPlugin`）。默认 false = 保守：老运行包上
  /// 引用不存在的插件会让会话起不来。
  bool nativeWebSearch = false,
  /// 子智能体是否提供（出厂提供）。
  bool subagentEnabled = true,
  String? subagentProvider,
  String? subagentModel,
}) async {
  final cfg = models.config.isEmpty
      ? ConfiguredModels.readConfig(runtime.filesDir)
      : models.config;
  final route = models.selected?.routeId ?? models.activeRouteId;
  if (route == null || route.isEmpty) {
    debugPrint('[dsh-model] 没有任何可用模型/组，跳过 overlay 重写（不编"能跑"的假象）');
    return;
  }

  // 轮换组要先把本地代理起起来、拿到它真正监听的端口，
  // overlay 里的 baseURL 才能写对（端口占用时会往后试）。
  final port =
      await RotationProxy.instance.ensureRunning(cfg: cfg, runtime: runtime);

  await runtime.writeOverlayFromConfig(
    config: cfg,
    activeRoute: route,
    rotatePort: port,
    // 端侧模型：**只在真的跑着的时候**才写进 overlay（见 local_model_server.dart）。
    localModel: LocalModelServer.instance.spec,
    nativeWebSearch: nativeWebSearch,
    subagentEnabled: subagentEnabled,
    subagentProvider: subagentProvider,
    subagentModel: subagentModel,
  );

  // 配置改了就顺手把 Bot 服务重起（否则 Bot 那边读的还是启动时那份模型清单，
  // 见 BotServer.restartIfRunning 的注释）。
  unawaited(BotServer.restartIfRunning(runtime: runtime));
  debugPrint(
    '[dsh-model] overlay 已重写：默认=$route，${cfg.providers.length} 个厂家 / '
    '${cfg.models.length} 个模型 / ${cfg.groups.length} 个轮换组'
    '${port == null ? '' : '，轮换代理端口=$port'}',
  );
}

/// 首次进入时确保 overlay 存在。
///
/// 若用户从没进过设置页，overlay 是缺的 —— 那就用「默认端点 + 清单里选中的
/// 模型」先写一份，保证对话页能直接起来，不会卡在"未配置模型"。
Future<String?> ensureModelConfig({
  required DshRuntime runtime,
  required ModelStore models,
  required FlutterSecureStorage secure,
  bool nativeWebSearch = false,
  bool subagentEnabled = true,
  String? subagentProvider,
  String? subagentModel,
}) async {
  final baseUrl = await secure.read(key: 'dsh_model_base_url');
  final providerId = await secure.read(key: 'dsh_model_provider');

  final effectiveBase = baseUrl?.trim().isNotEmpty == true
      ? baseUrl!.trim()
      : 'https://api.commandcode.ai/provider/v1';
  final effectiveProvider =
      providerId?.trim().isNotEmpty == true ? providerId!.trim() : 'com';

  if (!models.loaded) {
    await models.load(filesDir: runtime.filesDir);
  }

  var cfg = models.config;
  var route = models.selected?.routeId ?? models.activeRouteId;

  // ── 老用户自愈：还没有 models.json 的人 ─────────────────────────────
  // 他们的真实配置在安全存储里（一把 Key + 一个 model id）。这里用那一份
  // 撑起一份临时配置去写 overlay —— 光有 Key 而没有 provider/model 声明，
  // overlay 就写不出来，对话会退回官方端点。
  if (cfg.isEmpty) {
    if (route == null || route.isEmpty) {
      debugPrint('[dsh-model] 没有任何 model id，跳过 overlay 生成');
      return null;
    }
    final pid = ConfiguredModels.sanitizeProviderId(effectiveProvider);
    final modelId = route.contains('/') ? route.split('/').last : route;
    cfg = ConfiguredConfig(
      version: ConfiguredModels.currentVersion,
      providers: <ProviderSpec>[
        ConfiguredModels.provider(id: pid, baseUrl: effectiveBase),
      ],
      models: <ModelSpec>[ModelSpec(provider: pid, id: modelId)],
      groups: const <RotationGroupSpec>[],
      selected: '$pid/$modelId',
    );
    route = '$pid/$modelId';
    debugPrint('[dsh-model] models.json 缺失，用安全存储里的配置撑起 overlay：$route');
  }

  final wanted = cfg.choices.length;
  final registered = runtime.countRegisteredModels();

  // ⚠️ 只要有轮换组，就**保证本地代理在跑** —— 这一步刻意放在 needWrite 判断之前，
  // 而且与"要不要重写 overlay"无关。
  //
  // 为什么：代理是本地进程，App 一重启就没了，而 overlay 文件还在。如果只在
  // 需要重写 overlay 时才去起代理，就会出现「昨天能用、今天打开 App 就报连不上」。
  final rotatePort = cfg.groups.isEmpty
      ? null
      : await RotationProxy.instance.ensureRunning(cfg: cfg, runtime: runtime);

  // 默认路由和"当前选中项"不一致 → 也要重写（**2026-10-04 新增**）。
  //
  // 为什么必须有这条：overlay 决定的是**进程启动时**的默认路由，而"设置里选的是
  // 哪一个"落在 `models.json.selected`。两者分叉时（会话里点过模型只写了安全区、
  // 或者 overlay 还是上一版配置留下的），新会话起来用的会是 overlay 里那个旧默认，
  // 而界面/设置页显示的是另一个 —— 用户报的"设置里配好了 A、会话却在跑 B"正是它。
  // 启动时对一次账，不一致就重写，让 overlay 跟着设置走。
  final overlayRoute = runtime.readConfiguredRoute();
  final overlayRouteId = (overlayRoute.providerId ?? '').isEmpty ||
          (overlayRoute.modelId ?? '').isEmpty
      ? null
      : '${overlayRoute.providerId}/${overlayRoute.modelId}';
  final routeMismatch = route != null &&
      route.isNotEmpty &&
      overlayRouteId != null &&
      overlayRouteId != route;

  // 端点/模型对账：同厂家只改了 Base URL 的"冷启动"场景（见 overlayLooksStale）。
  final overlayStale = runtime.hasModelConfig &&
      route != null &&
      route.isNotEmpty &&
      overlayLooksStale(runtime: runtime, cfg: cfg, activeRoute: route);

  // 触发重写的条件，都是"升级迁移"或"必须保持一致"而不是洁癖：
  //   * overlay 缺失；
  //   * 注册的模型数比要注册的少（老 overlay 里只有 1 条 → 切模型报未知模型）；
  //   * 缺 Android 沙箱修复（老 overlay 没有 danger-full-access）；
  //   * overlay 里的默认路由 ≠ 当前选中项（新增，见上）；
  //   * 当前默认那条 route 的端点/模型 id 与配置不一致（新增，见 overlayLooksStale）；
  //   * 用户已经建了轮换组，但 overlay 里没有 `rotate` 这个厂家；
  //   * overlay 里记的代理端口和这次真正起来的端口不一致（起始端口被占用时会换）。
  final overlayPort = runtime.readRotatePort();
  // 端侧模型：本地推理进程随 App 一起死，overlay 却留着上次的端口。
  // 重开 App 时如果发现"overlay 里有 local 但服务没在跑"，就得重写把它摘掉 ——
  // 否则用户选了那个模型，一发消息就是"连接被拒"，且看不出原因。
  final localPort = runtime.readLocalModelPort();
  final localSpec = LocalModelServer.instance.spec;
  final localStale = runtime.overlayHasLocalProvider &&
      (localSpec == null || (localPort != null && localPort != localSpec.port));
  final needWrite = !runtime.hasModelConfig ||
      registered < wanted ||
      !runtime.overlayHasSandboxFix ||
      routeMismatch ||
      overlayStale ||
      (cfg.groups.isNotEmpty && !runtime.overlayHasRotateProvider) ||
      (cfg.groups.isNotEmpty &&
          rotatePort != null &&
          overlayPort != rotatePort) ||
      localStale;

  if (needWrite) {
    final active = route;
    if (active == null || active.isEmpty) {
      debugPrint('[dsh-model] 没有明确的选中项，跳过 overlay 生成');
      return effectiveBase;
    }
    await runtime.writeOverlayFromConfig(
      config: cfg,
      activeRoute: active,
      rotatePort: rotatePort,
      localModel: localSpec,
      nativeWebSearch: nativeWebSearch,
      subagentEnabled: subagentEnabled,
      subagentProvider: subagentProvider,
      subagentModel: subagentModel,
    );

    // 同上：模型清单变了，Bot 服务（如果开着）需要重启才会重新读取。
    unawaited(BotServer.restartIfRunning(runtime: runtime));
    debugPrint(
      '[dsh-model] overlay 已生成/升级：默认=$active，'
      '注册 $wanted 项（写入前 $registered 项）'
      '${routeMismatch ? '，原因：overlay 里原是 $overlayRouteId' : ''}'
      '${overlayStale ? '，原因：当前路由的端点/模型与配置不一致' : ''}'
      '${rotatePort == null ? '' : '，轮换代理端口=$rotatePort（overlay 里原为 $overlayPort）'}'
      '${localStale ? '，清掉失效的本地模型端口（overlay 里原为 $localPort）' : ''}',
    );
  } else if (rotatePort != null) {
    debugPrint('[dsh-model] overlay 无需重写；轮换代理已在 127.0.0.1:$rotatePort 运行');
  }
  return effectiveBase;
}

/// overlay 里「当前默认 route」那段，内容是不是已经等于配置里的？
///
/// 为什么需要这个对账：`ensureModelConfig` 原来的重写条件只看"条数 / 沙箱 / 轮换端口"，
/// 于是**同一个厂家只改了 Base URL**（provider id 和模型数都没变）时它会认为
/// "无需重写"，而 overlay 里还是旧端点 —— 新会话就会打到旧地址。
/// 这里只对**当前默认那一条 route**做很浅的文本核对（overlay 是本 App 自己写的，
/// 格式可控）：
///   * 那个厂家段落里的 `baseURL:` 是否就是配置里的值；
///   * 那个 model id 是否出现在该段落里。
/// 任何一项对不上 → 判定过期 → 重写。宁可多写一次，也不让会话打到旧端点。
///
/// 只查"当前默认"是刻意的：全文逐条比对会引入一堆假阳性，而这里的唯一目的
/// 就是别让用户正在用的那条 route 指向旧配置。
bool overlayLooksStale({
  required DshRuntime runtime,
  required ConfiguredConfig cfg,
  required String activeRoute,
}) {
  try {
    final f = File(runtime.overlayPath);
    if (!f.existsSync()) return true;
    final slash = activeRoute.indexOf('/');
    if (slash <= 0) return false;
    final pid = activeRoute.substring(0, slash);
    final modelId = activeRoute.substring(slash + 1);

    // 轮换组：端点永远是本地代理，端口由 readRotatePort 那条逻辑管，这里不掺和。
    if (pid == ConfiguredModels.rotateProviderId) return false;
    // 本地大模型同理：端点端口由 LocalModelServer 管（且服务没跑时会摘掉这条路由）。
    if (pid == LocalModelSpec.providerId) return false;

    final spec = cfg.providerOf(pid);
    if (spec == null) return false; // 不是配置里的厂家（自愈等路径）→ 不判过期

    final lines = f.readAsLinesSync();
    final head = RegExp('^ {6}${RegExp.escape(pid)}:\\s*\$');
    var start = -1;
    for (var i = 0; i < lines.length; i++) {
      if (head.hasMatch(lines[i])) {
        start = i;
        break;
      }
    }
    if (start < 0) return true; // 这个厂家根本没写进 overlay
    var end = lines.length;
    for (var i = start + 1; i < lines.length; i++) {
      if (RegExp(r'^ {6}\S').hasMatch(lines[i])) {
        end = i;
        break;
      }
    }
    final block = lines.sublist(start, end).join('\n');
    if (!block.contains('baseURL: ${_yamlQuote(spec.baseUrl)}')) return true;
    final modelLine = RegExp('^ {10}- id:\\s*${RegExp.escape(modelId)}\\s*\$',
        multiLine: true);
    if (!modelLine.hasMatch(block)) return true;
    return false;
  } catch (e) {
    debugPrint('[dsh-model] overlay 对账失败（按需要重写处理）：$e');
    return true;
  }
}

/// 与 `dsh_runtime.dart` 的 `_yamlStr` 保持一致的引号写法（那边是私有的）。
String _yamlQuote(String raw) {
  final s = raw.replaceAll('\\', r'\\').replaceAll('"', r'\"');
  return '"$s"';
}
