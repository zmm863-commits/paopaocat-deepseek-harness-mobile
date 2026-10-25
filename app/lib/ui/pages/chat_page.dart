import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../local/diagnostics_log.dart';
import '../../local/acp_client.dart';
import '../../local/android_toolbox.dart';
import '../../local/dsh_runtime.dart';
import '../../local/local_mcp.dart';
import '../../local/local_model_server.dart';
import '../../local/rotate_log.dart';
import '../../local/session_failure_store.dart';
import '../../local/session_transcript.dart';
import '../../data/anysearch.dart';
import '../../data/api_error_text.dart';
import '../../data/configured_models.dart';
import '../../data/artifact_store.dart';
import '../../data/artifacts.dart';
import '../../data/workspace_store.dart';
import '../../local/context_budget.dart';
import '../../state/session_registry.dart';
import '../../state/model_store.dart';
import '../../state/usage_store.dart';
import '../../state/provider_keys.dart';
import '../../state/spawn_signature.dart';
import '../theme/dsh_tokens.dart';
import 'model_sheet.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/enabled_experts_sheet.dart';
import '../widgets/input_bar.dart';
import '../widgets/message_stream.dart';
import '../widgets/workspace_entry.dart';
import '../widgets/session_drawer.dart';

import '../../i18n/dsh_i18n.dart';
import '../widgets/common.dart';

/// 对话页（设计稿 `page-01` / `02` / `03` / `04` / `11`）。
///
/// 顶部：对话标题 + `○本机` + `内容由AI生成`
/// 中部：消息流 —— 用户长消息（可「展开」）、`已完成`、助手回复、产物卡片
/// 底部：`按住说话` 输入区 + 当前模型按钮 + 附件菜单
///
/// 与运行时（ACP）的关系 —— 这一层**刻意与改造前一致**：
/// 一个 `dsh --profile acp` 常驻子进程 + 一个 session，多轮上下文由此保证。
/// 本轮新增的能力只有两处（都不改原来的新建会话路径）：
///   * [workspacePath]：会话的 cwd（= 当前工作区，来自工作区管理器）；
///   * [resumeSessionId]：用 ACP `session/resume` 恢复一条已持久化的会话。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.runtime,
    required this.models,
    required this.onOpenSettings,
    this.initialText,
    this.workspacePath,
    this.resumeSessionId,
    this.onModelChanged,
    this.onSessionUsed,
    this.onOpenWorkspaces,
    this.workspaceLabel,
    this.sessions,
    this.thinkingMode = 'collapsed',
    this.anysearchEnabled = true,
    this.sessionListFor,
    this.onOpenSession,
    this.onNewChat,
  });

  final DshRuntime runtime;
  final ModelStore models;
  final VoidCallback onOpenSettings;

  /// 会话注册表（由壳层持有）。
  ///
  /// **进程的所有权在它手里**，不在本页 —— 所以本页被 pop 掉时不会杀进程，
  /// 正在生成的回答能继续跑完。为 null 时退化成旧行为（页面自己收尸），
  /// 便于单测与渐进迁移。
  final SessionRegistry? sessions;

  /// 会话里要不要挂联网搜索（AnySearch，见 `data/anysearch.dart`）。
  ///
  /// 默认 true（匿名可用、不用填 Key）。⚠️ 它只在**建会话那一刻**生效
  /// （`session/new` 里把 `mcpServers` 发过去），所以改了要**开新会话**才看得出来。
  final bool anysearchEnabled;

  /// 从首页点提示词进来时预填的内容
  final String? initialText;

  /// 这次会话的工作目录（= DSH 的 cwd）。为空时回落到 `${filesDir}/workspace`。
  final String? workspacePath;

  /// 要恢复的会话 id（来自工作区页）。为空就是开新会话（老路径）。
  final String? resumeSessionId;

  /// 模型切换后的回调（外层负责重新生成 overlay 并重建 runtime）
  final Future<void> Function()? onModelChanged;

  /// 本会话发出第一条消息时回调一次，用于把这条会话登记进工作区
  /// （工作区页要显示"本次运行真的聊过哪几条"）。
  /// 传的是真实 sessionId、真实 cwd、用户原话 —— 界面层不编造标题。
  final void Function({
    required String id,
    required String cwd,
    required String title,
  })? onSessionUsed;

  /// 顶栏右侧的「工作区」入口（用户要求：原来那个按钮进的是「模型设置」，
  /// 改成工作区 —— **和首页右上角那个是同一个功能**，也就是同一个
  /// `WorkspacePage`：看有哪些工作区、每个工作区下有哪些会话、切工作区、
  /// 恢复历史会话）。
  ///
  /// 回调由 `AppShell` 提供（工作区登记表 `WorkspaceStore` 是**壳**持有的：
  /// 会话页自己再建一份会变成两个真相，切换后首页状态行不会跟着变）。
  /// 为空时**不显示**这个入口 —— 不摆一个点不动的按钮。
  final VoidCallback? onOpenWorkspaces;

  /// 这条会话所在工作区的展示名（显示在顶栏第二行 `本机 · <名字>`）。
  /// 名字由 `AppShell` 从登记表里取；取不到时才退到路径末段，界面不编名字。
  final String? workspaceLabel;

  /// 思考块怎么显示（`collapsed` / `expanded` / `hidden`）。
  ///
  /// 由壳层从 `AppSettings.thinkingModeId` 传进来（默认值只对"没人传"的场景兜底，
  /// 比如测试）。之所以一路传下来而不是读全局：壳层本来就因为皮肤/字号在监听设置，
  /// 顺路把这一项也带下来即可，不必再造一个全局镜像。
  final String thinkingMode;

  /// 左侧「会话」抽屉的历史会话数据源。用户参照 WorkBuddy 的交互提的：
  /// 「左上角点击符号，左侧拉出会话列表，能看到会话，点击就能到会话页面」。
  /// 为 null 时抽屉只显示「当前运行的会话」（live），不显示历史段。
  final Future<List<DshSession>> Function()? sessionListFor;

  /// 抽屉里点一条历史会话 → 由壳层打开它。
  final void Function(DshSession session)? onOpenSession;

  /// 抽屉里的「新建会话」→ 由壳层开一个新会话。
  final VoidCallback? onNewChat;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();

  /// 打开左侧会话抽屉用的 Scaffold 句柄。
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final _scroll = ScrollController();

  /// 没有会话句柄时，页面自己拿着消息（单测 / 未传 sessions 的旧路径）。
  final List<ChatMsg> _ownMessages = <ChatMsg>[];

  /// 消息表。**正常情况下指向 [LiveSession.messages]**（壳层的注册表持有）——
  /// 这样切页回来消息不丢，且人在别的页面时收到的更新也进得来。
  List<ChatMsg> get _messages => _live?.messages ?? _ownMessages;

  /// 从磁盘恢复回来的历史（[loadSessionTranscript] 的结果折成 [ChatMsg]）。
  ///
  /// 它与 [_messages] 一起经 [_mergedMessages] 渲染 —— 历史**不是**另一个只读框，
  /// 而是这条对话的前半段（用户 2026-10-15 第 1 条）。
  final List<ChatMsg> _resumedHistory = <ChatMsg>[];

  /// 消息流真正渲染的东西 = **磁盘历史 + 本次运行的消息**，按「角色 + 正文」去重。
  ///
  /// ## 为什么必须去重（不是可有可无的细节）
  ///
  /// 磁盘上的 transcript 是**全量**的：本次进入之后聊的每一句，DSH 也会写进同一个
  /// 会话文件。所以"历史"与"活着的消息"天然重叠，直接拼接会把同一句话显示两遍。
  ///
  /// 去重键用「角色 + 正文」：极端情况下同一句一模一样的回复出现两次会少显示一条，
  /// 那远比"整段对话被复制一遍"更像 bug。
  List<ChatMsg> get _mergedMessages {
    final live = _messages;
    if (_resumedHistory.isEmpty) return live;
    final seen = <String>{for (final m in live) _msgKey(m)};
    return <ChatMsg>[
      for (final m in _resumedHistory)
        if (seen.add(_msgKey(m))) m,
      ...live,
    ];
  }

  static String _msgKey(ChatMsg m) => '${m.role.name}\u0000${m.text}';

  /// 只用来读**老键** `dsh_model_api_key`（见 [_spawnState]），与 ProviderKeys
  /// 用的是同一个安全区命名空间，互不干扰。
  static const _legacySecure = FlutterSecureStorage();

  AcpClient? _acp;

  /// 当前会话在壳层注册表里的句柄。**进程与消息状态的真相都在它身上**，
  /// 本页只是借用它来渲染（见 `lib/state/session_registry.dart`）。
  LiveSession? _live;
  String? _sessionId;
  bool _starting = true;
  bool _running = false;
  String? _startError;

  /// 这一轮是什么时候开始的（审计 P1-1）。
  ///
  /// 为什么要有它：超时是 5 分钟×重试、界面却只有一个转圈 —— 用户根本不知道
  /// "是在算还是在卡"。有了开始时刻，顶栏就能显示「已等 M:SS」，
  /// 后面还有「停止」。null 表示当前没有在跑的回合。
  DateTime? _turnStartedAt;

  /// 语音识别是否正在进行（2026-10-05：改成"按下即听、松手即停"）。
  bool _speechRunning = false;

  /// 会话重建进行中。用它防止"连续点几个模型"触发多次并发重启
  /// （并发重启会同时拉起多个 node 进程，真机上足够把内存打满）。
  bool _restarting = false;

  /// 重建期间又收到了模型变更 → 完成后补做一次。
  bool _pendingModelChange = false;

  /// 「切模型」这件事**单飞**：同一时刻只跑一次（用户实测第 2 条
  /// 「选一次不行，要选第二次」的一半原因）。
  ///
  /// 一次点击会引来**两次**通知：① `ModelStore.selectModel` 自己的
  /// `notifyListeners()`；② 会话页 `_openModelSheet` 拿到返回值后调的
  /// `onModelChanged()`（内部 `reloadQuiet` + `publish`）。原来两次都会各自跑一遍
  /// `_applyModelChange`，并发去切模型 / 起进程，谁先谁后不确定。
  bool _applyingModelChange = false;

  /// 单飞期间又来了变更 → 这一轮结束后再跑一次（以最后一次选中的模型为准）。
  bool _modelChangeQueued = false;

  /// **运行时自己报出来的**当前模型 route —— 只在"已经生效"之后才写。
  ///
  /// 为什么不用界面上的 `widget.models.selectedRoute` 当判据：那个值在用户点下去
  /// 的那一瞬间就变了（本地 store），**不代表进程真的切过去了**。
  /// DSH 的 `session/set_config_option` 只认进程启动时注册过的模型，别的组合会
  /// 失败；界面据此以为切成功，用户看到的就是"选一次不行，要选第二次"。
  /// 所以这个字段只由 `AcpClient`（session/new、session/resume、
  /// set_config_option 的返回）来写，是**证据**不是意愿。
  String? _liveRoute;

  /// 轮换池本次用的成员（用户要求：在会话里提醒用的是哪个模型）。
  /// null = 不是轮换池 / 读不到 —— 那就**什么都不显示**，不猜。
  String? _rotateNote;

  /// 用量台账（按模型 route 记次数与字符数；见 state/usage_store.dart 的说明）。
  late final UsageStore _usage =
      UsageStore(path: '${widget.runtime.nodeHome}/usage.json');

  /// 本轮助手吐了多少字符（一轮结束时落账）。
  int _turnCharsOut = 0;

  /// 正在跑"配置变了 → 先让外层重写 overlay，再重建进程"这段。
  ///
  /// 为什么需要它：那段会调 `widget.onModelChanged`，而外层重写 overlay 时会
  /// `models.load()` → `notifyListeners()` → 又打回 [_onModelStoreChanged]。
  /// 没有这个闸就会自己调自己（外层 → 本页 → 外层 …）。嵌套进来的那次直接返回，
  /// 因为外面那次正在做同一件事。
  bool _syncingConfig = false;

  /// **本次 ACP 进程启动时真正生效的配置指纹**（厂家/端点/协议/模型清单/轮换池/每厂家 Key）。
  ///
  /// 为什么必须有它：overlay 与凭据都只在**进程启动时**读一次
  /// （`--patch overlay.yml` + 子进程环境变量）。
  ///   * 只换一个"进程里已经注册过的模型" → ACP `session/set_config_option` 就够，
  ///     会话历史和工具状态都留着（用户第 11 条反馈）；
  ///   * 但 Key / Base URL / 模型清单变了 → 进程里那份**旧配置不会热更新**，
  ///     继续用 set_config_option 会"切换成功、请求却打在旧端点/旧 Key 上"。
  ///     设备实测（独立 DSH_HOME + 假端点）：进程起来后把 overlay 里的 baseURL
  ///     从 `/com/v1` 改成 `/com2/v1`，下一条消息**仍然**打到 `/com/v1`。
  /// 所以这里记下启动时的指纹，变了就重建会话，不再假装"切一下就行"。
  String? _spawnedConfigKey;

  /// 起这个进程时，**当前选中那条路由的管路**（provider 定义 + 它的 Key 值 +
  /// 它的模型条目 + 轮换组成员）—— 见 `state/spawn_signature.dart`。
  ///
  /// 与 [_spawnedConfigKey]（整份配置）的区别：这份只关心"这条路由自己的东西
  /// 变没变"。切模型时用它判要不要重建 —— 用户改别的厂家不该重启正在聊的会话
  /// （用户 2026-10-15 第 1 条）。
  String? _spawnedRoutePlumbing;

  /// 产物（设计稿 page-04 的产物列表就来自这里）。
  ///
  /// **只装核实过的真文件**：文件真的在工作区里、且是这次会话写出来的
  /// （见 `verifyProducedArtifacts`）。名字猜出来的候选进不来。
  /// 产物同样挂在会话句柄上（见 [LiveSession]），理由与消息一致。
  final List<Artifact> _ownArtifacts = <Artifact>[];
  final Set<String> _ownArtifactKeys = <String>{};

  List<Artifact> get _artifacts => _live?.artifacts ?? _ownArtifacts;
  Set<String> get _artifactKeys => _live?.artifactKeys ?? _ownArtifactKeys;

  /// 产物落盘索引（用户意见⑤）：退出会话再进来，这批产物还能看到，
  /// 并且带着「是哪个会话产生的」这个来源信息。
  late final ArtifactStore _artifactStore = ArtifactStore(
    dir: '${widget.runtime.nodeHome}/artifacts',
  );

  /// 本页会话的开始时间。产物必须是这之后写出来的文件 ——
  /// 否则"模型读旧文档时顺口提到的已有文件"也会被当成产物。
  late final DateTime _sessionStartedAt = DateTime.now();

  final Map<String, ChatMsg> _byMessageId = {};
  final Map<String, ChatMsg> _toolById = {};

  /// 当前**还没收尾**的思考块（key 形式 `t:<messageId>`）。
  ///
  /// 用来给思考块记时长：下一段思考 / 正式回答 / 工具调用来了，
  /// 或者回合结束，就把这一段的结束时刻定下来（见 [_closeOpenThought]）。
  ///
  /// 为什么单独记：ACP 里思考、正式回答、工具调用是**三条不同的流**，
  /// 但界面上它们都属于"同一轮"。要给出"思考了 N 秒"，就得知道
  /// 哪一段思考在什么时候结束 —— 回合总时长是不行的（那里面混着工具时间）。
  String? _openThoughtKey;

  /// 流式文本的**合并缓冲**：`key → 还没上屏的字`。
  ///
  /// 为什么要它：模型一个 chunk 一条通知（几十毫秒一条），旧实现是**每条都
  /// setState + 滚一次** —— 滚动动画被反复重置、正文每帧重排，长回答（尤其
  /// 思考块）读起来就是"一顿一顿的"。这里按帧合并成一次上屏，滚动也只跟一次。
  ///
  /// 顺序保护：任何**结构事件**（工具卡片、回合结束）之前先 [_flushPendingText]，
  /// 否则攒着的字会落到后到的工具卡片下面。
  final Map<String, StringBuffer> _pendingText = <String, StringBuffer>{};
  Timer? _flushTimer;

  /// 合并间隔：一帧（60fps 下一帧只画一次）。再小没有意义；
  /// 再大就会有"字是一块一块蹦出来"的观感。
  static const Duration _flushEvery = Duration(milliseconds: 16);

  /// 工具**首次**通知里的完整 `rawInput`，按 toolCallId 缓存。
  ///
  /// 为什么必须缓存：ACP 的 `tool_call`（首次通知）带 `rawInput`，而
  /// `tool_call_update`（完成通知）**通常不带** —— 可产物核实偏偏要等
  /// `status == completed` 才做。少了这份缓存，「写文件」这类工具的
  /// `path` / `file_path` 参数在完成时就拿不到了，只能指望输出文本里恰好出现
  /// 文件名 —— 于是用户看到的现象是「明明生成了 txt，产物里却没有」。
  final Map<String, Object?> _toolRawById = {};

  /// 输入区左下角 `+` 展开的附件菜单（设计稿 page-03）
  bool _showAttachMenu = false;

  /// 「按住说话」按住态（设计稿 page-02 输入框文案就是 `按住说话`）。
  ///
  /// ⚠️ 这条注释以前写着"明确是**占位交互**：本机没有语音识别链路" ——
  /// 而实现早就是真的了：`_onVoiceState` → `_startSpeech()`/`_stopSpeech()`
  /// → `DshHost.startSpeech/stopSpeech`（Android 的 SpeechRecognizer，含 12+ 的设备端
  /// 离线识别），识别结果会回填输入框。**设备没有识别服务时**才走如实提示那条路
  /// （见 `_voiceHint` 与清单里的 RECORD_AUDIO）。
  bool _voiceHeld = false;

  /// 这条会话有没有被登记进工作区列表（只在第一条消息时回调一次）
  bool _sessionRegistered = false;

  /// 当前要恢复的会话 id。初始来自 [ChatPage.resumeSessionId]；
  /// 恢复失败用户可以点「改为新建会话」，这时会被清成 null。
  ///
  /// ⚠️ 它同时还是"**本页正在用哪个会话**"的唯一记录：新建会话成功后必须写回
  /// （见 [_createSession]），否则任何一次重建都会另开一个会话（缺陷 B）。
  String? _resumeId;

  /// 正在创建会话的那一次调用（连点发送 / 建会话期间切模型时只允许一次）。
  Future<String>? _sessionCreation;

  /// 正在"建会话 + 发第一条"这段异步窗口里 —— 防连点发两条
  /// （缺陷 D `a prompt is already in flight` 的一半来源就在这里）。
  bool _sendBusy = false;

  /// 这次会话是不是"恢复来的"（用来在界面上如实标注"DSH 不回放历史消息"）
  bool _resumed = false;

  /// 恢复失败的原因（非空时界面上给一个"改为新建会话"的出口）
  String? _resumeError;

  /// 恢复会话时从会话记录文件里读回来的历史（见 local/session_transcript.dart）。
  SessionTranscript? _transcript;
  bool _transcriptLoading = false;
  String? _transcriptError;


  /// 输入框里有没有内容（决定右下角是麦克风还是发送）
  bool _hasInput = false;

  /// 这次会话的工作目录（= DSH 的 cwd）。恢复会话时它必须与持久化的 cwd 一致，
  /// 否则 DSH 会直接拒绝（`session cwd does not match`）。
  String get _cwd =>
      widget.workspacePath ?? '${widget.runtime.filesDir}/workspace';

  /// sessionId 的前 8 位（界面上的短标识；越界时原样返回）
  static String _shortId(String? id) {
    if (id == null) return '';
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  @override
  void initState() {
    super.initState();
    _resumeId = widget.resumeSessionId;
    if (widget.initialText != null && widget.initialText!.trim().isNotEmpty) {
      _input.text = widget.initialText!;
      // ⚠️ 必须在这里就把 `_hasInput` 置上。
      //
      // 原因：监听器是**下面几行**才挂的，而单纯设置 `text` 不会触发
      // `_onInputChanged`。结果是"预填了内容、右下角却还是麦克风、没有发送按钮"，
      // 用户从首页点功能提示进来后**发不出去**（本轮做发布截图时实测踩到）。
      // 这条链路还牵连「用对话生成技能」——它也是靠 initialText 预填一长段指令。
      _hasInput = true;
    }
    // 右侧按钮要在「麦克风 / 发送」之间切，所以得跟着文本变化重建。
    _input.addListener(_onInputChanged);
    widget.models.addListener(_onModelStoreChanged);
    _start();
  }

  /// 输入框内容变化 → 只关心"有没有内容"这一个布尔量，避免每次按键都整页重建。
  void _onInputChanged() {
    final has = _input.text.trim().isNotEmpty;
    if (has == _hasInput) return;
    setState(() => _hasInput = has);
  }

  @override
  void dispose() {
    _input.removeListener(_onInputChanged);
    widget.models.removeListener(_onModelStoreChanged);
    // 页面要拆了：把缓冲里剩下的字**直接写进数据**（不 setState）。
    // 消息表是壳层 [SessionRegistry] 持有的，回来还在 —— 若在这里把缓冲丢掉，
    // 那最后几十毫秒的字就永久少一截。
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingText.forEach((key, buf) {
      final add = buf.toString();
      if (add.isEmpty) return;
      final existing = _byMessageId[key];
      if (existing != null) existing.text = '${existing.text}$add';
    });
    _pendingText.clear();
    // 页面没了，但消息表还在（壳层持有）：把开着的那段思考收尾，
    // 这样回来时它显示的是"思考了 N 秒"，而不是一个没有结束时刻的孤儿。
    _closeOpenThought(DateTime.now());
    // ⚠️ 这里**不再 close()**。进程归壳层的 [SessionRegistry] 所有：
    // 用户点底部别的 Tab 会把这个页面 pop 掉，若照旧收尸，正在生成的回答会被
    // 当场打断（这正是用户意见①背后的真问题）。现在只是"人走了"——
    // detach 掉，进程继续跑，回来时 attach 会把离屏期间攒下的通知回放出来。
    final live = _live;
    if (live != null) {
      live.removeListener(_onLiveChanged);
      // ⚠️ 这里**不要**再写 `live.running = _running`：
      //    本页可能不是发起这一轮的实例，它的 _running 可能是陈旧的 true ——
      //    写回去会把已经结束的轮次"复活"成进行中（首页就会一直显示「正在回答」）。
      //    真值由发起方维护，页面只读。
      live.title ??= _transcript?.title;
      live.detach();
    } else {
      // 没托管的（例如单测）仍旧按老规矩收尸，避免进程泄漏。
      _acp?.close();
    }
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- ACP 生命周期

  /// 模型切换：**先试"会话内切换"，能不重建就不重建**。
  ///
  /// 用户实测反馈（第 11 条）：「我发现会话页面切换模型就会重建会话，修复这个问题」。
  /// 原来这里无条件 `_restartSession()` —— 那会 `_messages.clear()` 并把子进程重启，
  /// 对话历史当场消失。
  ///
  /// 正确做法：DSH 的 ACP 支持会话级配置项（`session/set_config_option`，
  /// configId=`model`，值=`["provider","model"]`），改它只影响当前 agent 的模型选择，
  /// **历史和工具状态都保留**。只有当它失败（老运行时/不支持的组合）才退回重建。
  void _onModelStoreChanged() {
    if (!mounted) return;
    debugPrint('[chat] model changed -> ${widget.models.selectedName}');
    // 正在走"配置变了 → 同步 overlay → 重建进程"：这次通知（外层重写 overlay 前
    // 的 models.load）由外面那次一并处理，重复进来会并发出两个 node 进程。
    if (_syncingConfig) return;
    if (_restarting) {
      // 重启还没结束就又改了 → 记下来，等这次结束再补一次，避免并发起进程
      _pendingModelChange = true;
      return;
    }
    unawaited(_applyModelChange());
  }

  /// 采集"这次 spawn 真正吃进去的东西"：每厂家环境变量 + 一份指纹。
  ///
  /// 指纹里**刻意不含"当前选中的那一个"**：选一个已经注册过的模型不需要重建进程
  /// （那正是会话内切换的用途）。含进去的话，每次点模型都会把会话重建，退回
  /// 用户第 11 条反馈要修掉的行为。
  ///
  /// 指纹里**必须含 Key 的值**：同一厂家只改了 Key（provider id 没变）时，
  /// overlay 文本一模一样，只有环境变量变了 —— 不含 Key 就检测不到，
  /// 于是"切一下"看起来成功、请求却带旧 Key。
  /// 当前选中路由的"管路指纹"（见 state/spawn_signature.dart 的文件头）。
  ///
  /// **必须在 spawn 之前取**：它要和这一次进程真正吃进去的东西对上。
  Future<String> _routePlumbing(String route) async {
    if (route.isEmpty) return '';
    final cfg = widget.models.config;
    final keys = await ProviderKeys.envFor(cfg);
    String legacy = '';
    try {
      legacy = (await _legacySecure.read(key: 'dsh_model_api_key')) ?? '';
    } catch (_) {}
    return selectedRoutePlumbing(
      cfg: cfg,
      keys: keys,
      route: route,
      legacyKey: legacy,
    );
  }

  /// 这次会话要挂哪些 MCP 服务器。
  ///
  /// 现在是**两个**：
  ///   1. `dsh-office` —— 我们自己的本地 MCP（模型能直接读写 xlsx/docx），
  ///      见 `local/local_mcp.dart`。**总是挂**（挂不上就少三个工具，不影响会话）；
  ///   2. `anysearch` —— 联网搜索（可关），见 `data/anysearch.dart`。
  ///
  /// 读 Key 的路径与端侧对话的 🔍 同一个命名空间（`search-anysearch`）——
  /// 将来两边共用一把 Key，不会互相"看不见"。
  Future<List<Map<String, dynamic>>> _mcpServers() async {
    final servers = <Map<String, dynamic>>[];

    // ── 本地 MCP（我们自己的 Office 工具）────────────────────────────
    // ⚠️ 顺序在前面：它是**本机**能力，不依赖网络，也不受任何设置影响。
    // 挂不上（运行时尚未就绪 / 脚本没落盘）就**跳过** —— 绝不能因为它让会话开不起来
    // （运行时对 MCP 是 `failOnStartupError: true`，起不来会连累整个会话）。
    if (widget.runtime.isUnpacked) {
      try {
        await AndroidToolbox.ensureInstalled(widget.runtime.filesDir);
        // ⚠️ **先探活再挂**（2026-10-20 真机 P0）：运行时的 MCP 是 failOnStartupError，
        //    服务器起不来会让整个 `session/new` 失败 —— 实测就是「一条消息都发不出去」。
        //    探活不过就**不挂**：少三个工具，会话照常。
        final alive = await LocalMcp.probe(runtime: widget.runtime);
        final local = alive
            ? LocalMcp.mcpServers(runtime: widget.runtime)
            : const <Map<String, dynamic>>[];
        if (local.isNotEmpty) {
          servers.addAll(local);
          debugPrint('[chat] 会话挂上本地 MCP ${LocalMcp.serverName}（${local.length} 个）');
          DiagnosticsLog.add('dsh-chat', '会话挂上本地 MCP ${LocalMcp.serverName}');
        } else if (!alive) {
          debugPrint('[chat] 本地 MCP 探活未通过 → 本次不挂（会话照常）');
          DiagnosticsLog.add('dsh-chat', '本地 MCP 探活未通过 → 本次不挂（会话照常）');
        }
      } catch (e) {
        debugPrint('[chat] 本地 MCP 挂不上（不致命，会话照开）：$e');
        DiagnosticsLog.add('dsh-chat', '本地 MCP 挂载异常（会话照开）：$e');
      }
    }

    if (!widget.anysearchEnabled) return servers;
    // ⚠️ 运行时里若已经带了 **原生** 的 AnySearch 搜索后端（overlay 会把
    //    `web.searchProvider` 钉到它），这里就**不要再挂 MCP** —— 否则会话里会同时
    //    出现"原生 web_search"和"AnySearch 的 MCP 工具"两个搜索入口，模型容易乱选。
    //    这正是"新运行包走原生、老运行包退回 MCP"的分工。
    if (widget.runtime.runtimeHasAnysearchPlugin) {
      debugPrint('[chat] 运行时自带 AnySearch 原生后端 → 不重复挂 MCP');
      return servers;
    }
    String? key;
    try {
      key = await ProviderKeys.read(AnySearch.keyStorageId);
    } catch (e) {
      debugPrint('[chat] 读联网搜索的 Key 失败（按匿名用）：$e');
    }
    servers.addAll(AnySearch.mcpServers(apiKey: key));
    debugPrint('[chat] 会话挂上联网搜索 ${AnySearch.serverName}'
        '（${(key ?? '').trim().isEmpty ? "匿名" : "带 Key"}）');
    return servers;
  }

  Future<({String sig, Map<String, String> keys})> _spawnState() async {
    final cfg = widget.models.config;
    final keys = await ProviderKeys.envFor(cfg);
    // 老键（对话页齿轮那个 v1 设置页写的是它）：它会被注入成
    // `COM_/DEEPSEEK_/OPENAI_API_KEY`，所以也算"进程启动时吃进去的配置"。
    // 只放一个"变没变"的标记 + 值（仅用于本地比较，绝不落日志）。
    String legacy = '';
    try {
      legacy = (await _legacySecure.read(key: 'dsh_model_api_key')) ?? '';
    } catch (_) {}
    final sorted = keys.keys.toList()..sort();
    final buf = StringBuffer()
      ..writeln('v${cfg.version}')
      ..writeln('providers:${cfg.providers.length}');
    for (final p in cfg.providers) {
      buf.writeln('p:${p.id}|${p.api}|${p.baseUrl}|${p.apiKeyEnv}');
    }
    for (final m in cfg.models) {
      buf.writeln('m:${m.route}|${m.context ?? 0}');
    }
    for (final g in cfg.groups) {
      buf.writeln('g:${g.route}|${g.members.join(',')}');
    }
    for (final k in sorted) {
      buf.writeln('k:$k=${keys[k]}');
    }
    buf.writeln('legacy:$legacy');
    // ⚠️ **端侧模型（local）必须算进指纹**。
    //
    // 它不在 `models.json` 里（是 App 起本地服务时动态产生的），但 DSH 进程启动时
    // 会从 overlay 里读到 `local` 这个厂家 —— 所以"进程启动时吃进去的配置"必须包含它。
    // 漏掉它的后果（用户实测）：点了「启动本地服务」→ 会话里能看到「本地大模型」→
    // **却选不动**。因为 App 认为"配置没变" → 走会话内的 `set_config_option`，
    // 而那句话只认"进程启动时注册过的模型"，本地模型不在其中 → 切换失败。
    //
    // 端口也算进去：同一台机上换了模型（或端口被占后换端口）同样需要重建会话。
    final local = LocalModelServer.instance.spec;
    buf.writeln(
        'local:${local == null ? '-' : '${local.port}|${local.modelId}'}');
    // 注：「生图走本机」这个开关**已随端侧出图引擎一起删除**（2026-10-11），
    // 所以指纹里不再有 image-local 这一项。
    return (sig: buf.toString(), keys: keys);
  }

  /// 切换模型的实际执行：**配置没变才走会话内切换；配置变了必须重建会话**。
  ///
  /// 单飞 + 合流：一次点击会来两次通知（见 [_applyingModelChange] 的注释），
  /// 这里保证同一时刻只跑一次，并把期间的请求合并成"再跑一次"。
  Future<void> _applyModelChange() async {
    if (_applyingModelChange) {
      _modelChangeQueued = true;
      return;
    }
    _applyingModelChange = true;
    try {
      do {
        _modelChangeQueued = false;
        await _applyModelChangeOnce();
      } while (_modelChangeQueued && mounted);
    } finally {
      _applyingModelChange = false;
      _modelChangeQueued = false;
    }
  }

  Future<void> _applyModelChangeOnce() async {
    final st = await _spawnState();
    final want = widget.models.selectedRoute ?? '';

    // 用户 2026-10-15 第 1 条：「切换模型不要重建会话，看看有没有这个问题发生」。
    //
    // 老口径是"整份配置指纹变了就重建会话"（`st.sig != _spawnedConfigKey`）——
    // 太粗：用户改的是**别的厂家**、或者只是勾了一个新模型，跟当前这条路由
    // 毫无关系，却会把正在聊的会话重启一遍。真机日志里那种"提示说没重建、
    // 实际换了会话"就是这么来的。
    //
    // 现在的判据是**这条路由自己的管路**（provider 定义 + 它的 Key 值 + 它的模型
    // 条目 + 轮换组成员）：没变 → 运行时的注册表和配置仍然对得上 → 直接会话内
    // 切模型，一个进程都不重启。只有**这条路由自己的**东西变了才重建
    // （Key 变了必须重建，否则进程还揣着旧 Key）。
    final plumbingNow = await _routePlumbing(want);
    final routeChanged =
        _spawnedRoutePlumbing != null && plumbingNow != _spawnedRoutePlumbing;
    // 兼容性：整份配置变了但仍与这条路由无关时，不再逼着重建；但**没记过**
    // 管路（老代码升上来的第一次）仍按老口径保守处理一次。
    final configChanged = _spawnedRoutePlumbing == null
        ? (_spawnedConfigKey != null && st.sig != _spawnedConfigKey)
        : routeChanged;

    // 运行时已经在这个模型上、配置也没变 → 什么都不用做（这就是"再点一次同一个"）。
    // 判据是 [_liveRoute]（运行时报的），不是界面上的选中名。
    if (!configChanged && want.isNotEmpty && want == _liveRoute) return;

    if (!configChanged && await _switchModelInPlace()) {
      if (!mounted) return;
      setState(() {}); // 顶栏模型名刷新
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
                context.tr('已切换到 {0}（会话没重建，上下文还在）',
                    [widget.models.selectedName])),
            duration: const Duration(milliseconds: 1600),
          ),
        );
      return;
    }

    if (!mounted) return;
    // 三种退回重建的理由要分开说：一个是"还没开始对话"（没有会话可切），
    // 一个是"进程里的旧配置不会热更新"（配置变了），
    // 一个是"这个模型/组合切不过去"（老运行时 / 没注册过）。
    final reason = _sessionId == null
        ? context.tr('还没开始对话，正在按新模型准备会话…')
        : configChanged
            ? context.tr('模型配置变了（Key / 端点 / 模型清单），进程里的旧配置不会热更新，正在重建会话…')
            : context.tr('这个模型没法在当前会话里直接切，正在重建会话…');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
            content: Text(reason),
            duration: const Duration(milliseconds: 2200)),
      );

    // ⚠️ 重建之前**必须**先把 overlay 按当前清单重写 —— **任何**重建都是，
    // 不只是"配置变了"那次。
    //
    // 为什么（用户实测第 2 条「选一次不行，要选第二次」的根因）：
    // overlay 里写着新会话默认用哪个模型（`agent-default-model`），它由
    // `main._onModelChanged` → `applyModelSelection` 从 `models.json.selected` 写入。
    // 旧代码只在 `configChanged` 时才同步它，于是"切一个没注册过的模型"这条路上：
    // 会话重建了，但 overlay 里还是**旧**默认路由 → 新进程跑的还是旧模型 →
    // 用户看到"选了没反应"。现在无论如何都先同步一次再起进程。
    if (!_syncingConfig) {
      _syncingConfig = true;
      try {
        await widget.onModelChanged?.call();
      } catch (e) {
        debugPrint('[chat] 重建前同步 overlay 失败（继续重建）：$e');
      } finally {
        _syncingConfig = false;
      }
    }
    if (!mounted) return;
    await _restartSession();
  }

  /// 在当前会话里换模型（**只有运行时确认生效**才返回 true）。
  ///
  /// route 形如 `provider/model`；轮换组是 `rotate/<组名>`，同样能这样切
  /// （对 DSH 来说它就是一个普通的 provider/model 组合，只是端点指向本地代理）。
  ///
  /// 返回值来自 `AcpClient.setSessionModel` 的**校验**：它会比对运行时回的
  /// `currentValue`，对不上就是 false（见那边的注释）—— 不能只凭"请求没报错"
  /// 就宣布切换成功。
  Future<bool> _switchModelInPlace() async {
    final acp = _acp;
    final sid = _sessionId;
    final route = widget.models.selectedRoute ?? '';
    if (acp == null || sid == null || route.isEmpty) return false;
    final slash = route.indexOf('/');
    if (slash <= 0) return false;
    final provider = route.substring(0, slash);
    final model = route.substring(slash + 1);
    try {
      final ok = await acp.setSessionModel(
        sid,
        provider: provider,
        model: model,
      );
      if (!ok) {
        debugPrint('[chat] 会话内切换模型未被运行时确认（$route），将重建会话');
        return false;
      }
      _liveRoute = acp.liveModelRoute ?? route;
      debugPrint('[chat] 会话内切换模型成功：$route（会话未重建，已由运行时确认）');
      return true;
    } catch (e) {
      debugPrint('[chat] 会话内切换模型失败，将重建会话：$e');
      return false;
    }
  }

  Future<void> _restartSession() async {
    _restarting = true;
    final old = _acp;
    final oldLive = _live;
    _acp = null;
    // 先断开句柄：下面要换进程，句柄得跟着换（否则注册表里会留一个指向
    // 已死进程的条目 —— 首页会显示一个点不回去的"会话"）。
    _live = null;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      if (oldLive != null) {
        // 进程归注册表管：注销 + 收尸都交给它。
        await widget.sessions?.closeSession(oldLive);
      } else {
        await old?.close();
      }
    } catch (_) {}
    if (!mounted) {
      _restarting = false;
      return;
    }
    setState(() {
      _sessionId = null;
      _byMessageId.clear();
      _toolById.clear();
      _toolRawById.clear();
      _messages.clear();
    });
    // 重建 = 换进程：创建中的那个 Future 作废（它的 id 属于旧进程，不能用）。
    _sessionCreation = null;
    // 进程换了，"运行时在跑哪个模型"这个已知事实作废，等新会话自己报。
    _liveRoute = null;
    await _start();
    _restarting = false;

    // 本地清单已经切过去了，但 manifest 可能还没落盘 —— 补一次重启，
    // 保证最终跑的模型和界面显示的一致。
    if (_pendingModelChange) {
      _pendingModelChange = false;
      await _restartSession();
    }
  }

  Future<void> _start() async {
    try {
      final rt = widget.runtime;
      final ws = widget.workspacePath ?? '${rt.filesDir}/workspace';

      // 0) 这个会话是不是**已经在注册表里跑着**？
      //    命中就直接接上、绝不新起进程 —— 这正是"切到别的页面再回来，
      //    刚才那个回答还在继续"能成立的关键。
      final registry = widget.sessions;
      final reusable =
          registry?.findReusable(workspace: ws, resumeId: _resumeId);
      if (reusable != null) {
        _adoptLive(reusable);
        return;
      }
      // 这一步同时拿到"每厂家环境变量"和"配置指纹"。**必须在 spawn 之前取**：
      // overlay 与凭据都是进程启动时读一次，指纹必须等于这一次真正吃进去的东西。
      final st = await _spawnState();
      // 这次 spawn 时"这条路由的管路"（spawn 之前取，才算得上"进程吃进去的那份"）。
      final plumbingAtSpawn = await _routePlumbing(
          widget.models.selectedRoute ?? '');
      final acp = await AcpClient.start(
        // ⚠️ 整份 runtime 交进去（不再自己拼一份精简 env）。会话进程必须和别人
        // 一样带上 DSH_ANDROID_* 四件套、执行环境 shim、工具箱、AGNES_* ——
        // 否则会话里 bash/node 全不可用（这就是「画图不能用」的根因）。
        runtime: rt,
        workspace: ws,
        overlayPath: rt.hasModelConfig ? rt.overlayPath : null,
        // ⚠️ 每厂家各自的 Key 必须一起注入：overlay 用 `apiKeyEnv` 点名，
        // 不传的话只有 COM_/DEEPSEEK_/OPENAI_ 三个固定名有值，
        // 别的厂家（Agnes / MiMo / 自定义）在会话里必然报 no credential。
        apiKeys: st.keys,
        onLog: (m) => debugPrint('[chat]$m'),
      );

      // 恢复已有会话 or **延后**新建会话。
      //
      // 恢复走 ACP `session/resume`（设备上实测可用：恢复后模型仍记得之前的上下文，
      // 但**不回放历史消息** —— 这是协议行为，界面要如实标注，不能假装消息还在）。
      // 任何失败都**不吞**：把原因显示出来，并给一个"改为新建会话"的出口。
      final wantResume = _resumeId;
      String? sessionId;
      if (wantResume != null && wantResume.isNotEmpty) {
        try {
          final servers = await _mcpServers();
          try {
            await acp.resumeSession(wantResume, ws, mcpServers: servers);
          } on Object catch (e) {
            // 兜底：万一 MCP 还是把会话带崩了（探活过了也可能在授权/同步阶段失败），
            // 就去掉 MCP 再试一次 —— **聊天能力优先级高于那三个工具**。
            if (!_isMcpStartupError(e) || servers.isEmpty) rethrow;
            DiagnosticsLog.add('dsh-chat', '恢复会话被 MCP 带崩 → 去掉 MCP 重试：$e');
            await acp.resumeSession(wantResume, ws, mcpServers: const []);
          }
          sessionId = wantResume;
          _resumed = true;
          _resumeError = null;
          debugPrint(
              '[chat] session resumed: $sessionId cwd=$ws（协议不回放历史，改从会话文件读）');
          // 协议不带历史消息，所以自己去读会话记录文件（node 解多帧 zstd）。
          unawaited(_loadTranscript(sessionId));
        } catch (e) {
          debugPrint('[chat] session resume failed: $e');
          await acp.close();
          if (!mounted) return;
          setState(() {
            _starting = false;
            _resumeError = '$e';
            _startError = null;
          });
          return;
        }
      } else {
        // ⚠️ 这里**刻意不建会话**（缺陷 A 的修法，2026-10-14）。
        //
        // 为什么不能在这里建：ACP `session/new` 一被调用，DSH 立刻在磁盘上写出
        // `<sessionId>/session.v4.jsonl.zstd` —— 那一行就是列表里"点开全空"的一条。
        // 设备实测（见 docs/CHANGES-2026-10-14.md §2）：48 条会话里 17 条 0 消息空壳，
        // 而诊断日志里 22 次「打开聊天页（未指定会话）」有 **12 次**在 120 秒内一句没发。
        // 用户翻列表看到一堆空白，结论就是"我的对话被删了"。
        //
        // 现在改成：进程照旧先起来（该热的身都热好），**第一条消息到达时才建会话**
        // —— 见 [_ensureSession]。没聊过的页面不再往磁盘上留任何东西。
        sessionId = null;
        debugPrint('[chat] 进程就绪；会话延后到第一条消息再创建（不再产生 0 消息空壳）');
      }
      if (!mounted) {
        await acp.close();
        return;
      }

      // 把这个进程交给壳层的注册表托管（页面只是借用）。
      // 从此"页面生死"与"进程生死"解耦：切页不再打断回答。
      LiveSession? live;
      if (registry != null) {
        live = LiveSession(
          key: '$ws|${_resumeId ?? DateTime.now().microsecondsSinceEpoch}',
          acp: acp,
          workspace: ws,
        )
          ..sessionId = sessionId
          ..spawnConfigKey = st.sig
          ..spawnRoutePlumbing = plumbingAtSpawn
          ..liveRoute = acp.liveModelRoute;
        // 本页此前先写进自己那份的消息/产物，搬进句柄 —— 从此刻起两者共享同一份。
        if (_ownMessages.isNotEmpty) {
          live.messages.addAll(_ownMessages);
          _ownMessages.clear();
        }
        if (_ownArtifacts.isNotEmpty) {
          live.artifacts.addAll(_ownArtifacts);
          live.artifactKeys.addAll(_ownArtifactKeys);
          _ownArtifacts.clear();
          _ownArtifactKeys.clear();
        }
        registry.register(live);
        _live = live;
        // 新会话也要挂同一个监听（与 _adoptLive 一致）：
        // 这一轮的 running 由本页维护，但**从别处 adopt 回来后**可能换成别的实例，
        // 两边都挂上才不会出现"一边在跑、一边显示未跑"（或反过来）。
        live.addListener(_onLiveChanged);
        live.attach(
          onNotification: _onNotification,
          onPermission: _onPermission,
        );
      } else {
        acp.notifications.listen(_onNotification);
        acp.permissionRequests.listen(_onPermission);
      }

      setState(() {
        _acp = acp;
        _sessionId = sessionId;
        _starting = false;
        // 指纹只在**真的起好了**之后才记：起失败时保持旧值，
        // 下一次变更仍会被判成"配置变了"从而重试重建。
        _spawnedConfigKey = st.sig;
        // 这条路由自己的管路也一起记（切模型时的判据，见 state/spawn_signature.dart）。
        _spawnedRoutePlumbing = plumbingAtSpawn;
        // 这个新会话**运行时实际在用**的模型（session/new / session/resume 的返回里
        // 带的 configOptions 报出来的）—— 不是界面上那个选中项。
        _liveRoute = acp.liveModelRoute;
      });
      debugPrint('[chat] ACP ready: session=${sessionId ?? '（延后创建）'} '
          'model=${widget.models.selectedName} 运行时报=$_liveRoute cwd=$ws');
    } catch (e) {
      debugPrint('[chat] ACP start failed: $e');
      if (!mounted) return;
      setState(() {
        _starting = false;
        _startError = '$e';
      });
    }
  }

  /// 第一条消息到达时才创建会话（缺陷 A/B 的修法，2026-10-14）。
  ///
  /// 两条缺陷同源，所以一起修：
  ///
  ///   * **A 空壳**：`session/new` 一调用就落盘一个会话目录。以前在 `_start()`
  ///     里无条件建，于是"点开聊天页看一眼就走"也会留下一个 0 消息会话。
  ///     现在只有**真的发消息**才建。
  ///   * **B 切模型换会话**：建完必须把 id 记进 [_resumeId]。以前只存 `_sessionId`，
  ///     而 `_start()` 判断"恢复还是新建"只看 `_resumeId` —— 本页新建的会话
  ///     `_resumeId` 一直是 null，于是**任何**一次重建都会走新建分支换个新 id。
  ///     日志实证：23:06:42.064 打印"会话未重建" → 42.185 进程退出 → 43.717
  ///     `session created: 348524f2`，旧会话 c6a74bd7 被留在列表里。
  ///
  /// 并发只允许一次（连点发送、建会话期间刚好切模型）：多次调用共享同一个 Future。
  Future<String> _ensureSession() {
    final running = _sessionCreation;
    if (running != null) return running;
    final f = _createSession();
    _sessionCreation = f;
    f.whenComplete(() {
      if (identical(_sessionCreation, f)) _sessionCreation = null;
    });
    return f;
  }

  /// 这个异常是不是「MCP 起不来」造成的会话失败。
  ///
  /// 运行时的返回长这样（2026-10-20 真机原文）：
  /// `session/new 失败：{"code":-32603,"message":"Internal error",
  ///   "data":{"details":"mcp-client(dsh-office): initial connection or tool synchronization failed"}}`
  /// 判据取 `mcp-client`（协议里 MCP 客户端的固定前缀），不绑定具体服务器名 ——
  /// 以后再加别的 MCP，这条兜底同样生效。
  static bool _isMcpStartupError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('mcp-client') ||
        s.contains('tool synchronization failed') ||
        s.contains('initial connection');
  }

  Future<String> _createSession() async {
    final acp = _acp;
    if (acp == null) throw StateError('会话进程还没起来');
    final servers = await _mcpServers();
    String id;
    try {
      id = await acp.newSession(_cwd, mcpServers: servers);
    } on Object catch (e) {
      // 兜底（同 resume）：MCP 起不来不该让用户发不出消息。
      if (!_isMcpStartupError(e) || servers.isEmpty) rethrow;
      DiagnosticsLog.add('dsh-chat', '建会话被 MCP 带崩 → 去掉 MCP 重试：$e');
      id = await acp.newSession(_cwd, mcpServers: const []);
    }
    // 期间页面重建过（进程换了）→ 这个 id 不能算数，让调用方如实报错重来，
    // 否则会把消息发到一个已经没有页面在用的会话上。
    if (_acp != acp) throw StateError('会话进程刚被重建，请再发一次');
    _resumeId = id;
    _live?.sessionId = id;
    if (mounted) {
      setState(() => _sessionId = id);
    } else {
      _sessionId = id;
    }
    debugPrint('[chat] 第一条消息到达 → 创建会话 $id'
        '（已记进 _resumeId，此后重建走 resume 不再换会话）');
    return id;
  }

  /// 句柄状态变了（running / turnStartedAt）→ 同步到界面。
  ///
  /// 只同步这两个字段：消息内容走 ACP 通知，别在这里重建，否则一次回答会重建很多次。
  void _onLiveChanged() {
    final live = _live;
    if (live == null || !mounted) return;
    final r = live.running;
    final t = live.turnStartedAt;
    if (r == _running && t == _turnStartedAt) return;
    setState(() {
      _running = r;
      _turnStartedAt = t;
    });
  }

  /// 接上一个**已经在跑**的会话（注册表里已经有它的进程与消息）。
  ///
  /// 不新起进程、不清消息 —— 只是把本页绑回去，并让句柄把"[人不在时]"攒下的
  /// 通知回放给本页（见 [LiveSession.attach]）。这是"切页不打断回答"的另一半：
  /// 前一半是 dispose 时不再杀进程，这一半是回来时能把状态接上。
  void _adoptLive(LiveSession live) {
    _live = live;
    _acp = live.acp;
    _sessionId = live.sessionId;
    _running = live.running;
    // 2026-10-20 真机 bug 的修法：句柄上的 running 一变就同步到本页。
    // 为什么必须有它：这一轮可能是**别的页面实例**发起的（切页/重进时换了实例），
    // 跑完时是那个实例在清状态；本页只抄了一次初值就再也不更新 → 永远显示「正在处理」。
    live.addListener(_onLiveChanged);
    // 切页回来时接着显示"已等了多久"，而不是归零（审计 P1-1）。
    _turnStartedAt = live.turnStartedAt;
    _spawnedConfigKey = live.spawnConfigKey;
    _spawnedRoutePlumbing = live.spawnRoutePlumbing;
    _liveRoute = live.liveRoute;
    // 历史消息仍从会话文件读（协议不回放历史）；离屏期间的新消息靠 attach 回放。
    if (live.sessionId != null) {
      unawaited(_loadTranscript(live.sessionId!));
    }
    live.attach(
      onNotification: _onNotification,
      onPermission: _onPermission,
    );
    if (mounted) {
      setState(() {
        _starting = false;
        _startError = null;
        _resumeError = null;
      });
    }
    debugPrint('[chat] 接上已在运行的会话 ${live.sessionId ?? live.key}');
  }

  /// 恢复失败后用户选择"改为新建会话"：清掉 resume 目标重来一次。
  Future<void> _startFreshInstead() async {
    setState(() {
      _resumeId = null;
      _resumeError = null;
      _starting = true;
      _startError = null;
    });
    await _start();
  }

  void _autoScroll() {
    // 顺手看看上下文是不是快满了（跨过 70%/90% 各提示一次，见 _maybePromptRollover）。
    // 放在这里是因为 `_autoScroll` 每次"消息有变化"都会被调一次，而它**总在 build 之外**。
    _maybePromptRollover();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      final gap = pos.maxScrollExtent - pos.pixels;
      // 已经贴底：不用动。
      if (gap <= 0.5) return;
      // 落后不多（流式输出的常态）：**直接跟手**。
      //
      // 旧实现是每次都 `animateTo(150ms)`：chunk 一密集（几十毫秒一条），
      // 上一个动画还没走完就被下一个重置，观感就是"一抽一抽、追不上"。
      // jumpTo 不产生新动画，只是把视口移到新底部 —— 这正是聊天流式该有的样子。
      if (gap <= 120) {
        pos.jumpTo(pos.maxScrollExtent);
        return;
      }
      // 落后很多（换会话、刚展开很长的历史）：才值得给一段平滑动画。
      _scroll.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  // ---------------------------------------------------------------- ACP → UI

  void _onNotification(Map<String, dynamic> msg) {
    if (msg['method'] != 'session/update') return;
    final params = msg['params'] as Map? ?? const {};
    final update =
        Map<String, dynamic>.from(params['update'] as Map? ?? const {});
    switch (update['sessionUpdate']) {
      case 'agent_message_chunk':
        _onTextChunk(update, isThought: false);
        break;
      case 'agent_thought_chunk':
        _onTextChunk(update, isThought: true);
        break;
      case 'tool_call':
        // 工具卡片插到消息流之前，先把攒着的字落盘：否则"思考块在前、
        // 工具卡片在后"的顺序会被缓冲打乱。
        _flushPendingText();
        _onToolCall(update);
        break;
      case 'tool_call_update':
        _flushPendingText();
        _onToolResult(update);
        break;
      default:
        // 其它结构事件（plan / usage / snapshot…）同理：先落盘再交给上层。
        _flushPendingText();
    }
  }

  /// 把缓冲里的字**一次性**写进消息表（每帧最多一次，见 [_flushEvery]）。
  ///
  /// 与旧实现的差别只在"什么时候 setState"，写入语义完全一致：
  /// key 不存在就新建一条，存在就往后追加。
  void _flushPendingText() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pendingText.isEmpty) return;

    // 先把缓冲取走再 setState：flush 期间新到的 chunk 会进新的 buffer，
    // 不会被这次一起写掉（也就不需要重入保护）。
    final batch = <String, String>{
      for (final e in _pendingText.entries) e.key: e.value.toString(),
    };
    _pendingText.clear();
    if (!mounted) return;

    setState(() {
      // 同一批里可能既有思考又有正式回答：按到达顺序处理，
      // 上一段思考到这里就收尾（见 [_closeOpenThought]）。
      final now = DateTime.now();
      batch.forEach((key, add) {
        final existing = _byMessageId[key];
        if (existing == null) {
          final isThought = key.startsWith('t:');
          // 上一段思考到此为止：模型切段了，或者开始写正式回答了。
          _closeOpenThought(now);
          if (isThought) _openThoughtKey = key;
          final m = ChatMsg(
            text: add,
            role: isThought ? ChatRole.thought : ChatRole.assistant,
            startedAt: now,
          );
          _byMessageId[key] = m;
          _messages.add(m);
        } else {
          existing.text = '${existing.text}$add';
        }
      });
    });
    _autoScroll();
  }

  /// 把当前开着的思考块收尾（记下结束时刻）。
  ///
  /// 为什么要记：回合结束后思考块会收成一行「思考了 N 秒」
  /// （对标 WorkBuddy 的 `tool_call_process_preview`）。
  /// 时长必须来自**真实的时间戳** —— 拿回合总时长来凑是不行的，
  /// 那一段时间里混着工具执行和正式回答。
  void _closeOpenThought(DateTime at) {
    final key = _openThoughtKey;
    if (key == null) return;
    final m = _byMessageId[key];
    if (m != null && m.endedAt == null) m.endedAt = at;
    _openThoughtKey = null;
  }

  void _onTextChunk(Map<String, dynamic> update, {required bool isThought}) {
    final messageId = update['messageId'] as String? ?? 'unknown';
    final text = (update['content'] as Map?)?['text'] as String? ?? '';
    if (text.isEmpty) return;
    debugPrint('[chat] ${isThought ? 'thought' : 'message'}: $text');
    if (!mounted) return;
    // 只有**正式回答**计入用量：思考过程不该算进"模型产出了多少字"。
    if (!isThought) _turnCharsOut += text.length;

    // thought 与 message 共用一个 messageId，key 必须带类型前缀
    final key = '${isThought ? 't' : 'm'}:$messageId';
    // 不再每条都 setState：先攒进缓冲，最多 16ms 后合并上屏
    // （见 [_pendingText] / [_flushPendingText] 的说明）。
    (_pendingText[key] ??= StringBuffer()).write(text);
    _flushTimer ??= Timer(_flushEvery, _flushPendingText);
  }

  /// 诊断日志里用的短串：压掉换行、截到 60 字。
  static String _shortTool(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 60 ? one : '${one.substring(0, 60)}…';
  }

  void _onToolCall(Map<String, dynamic> update) {
    // 工具调用意味着"想完了、开始动手"：这一段思考到此为止。
    _closeOpenThought(DateTime.now());
    final id = update['toolCallId'] as String? ?? 'unknown';
    final title = update['title'] as String? ?? context.tr('工具');
    final raw = update['rawInput'];
    final command = (raw as Map?)?['command'] as String?;
    if (!mounted) return;
    // 把**完整** rawInput 留一份：完成通知里基本不会再有它（见 [_toolRawById]）。
    if (raw != null) _toolRawById[id] = raw;

    // 工具调用记进**诊断日志**（用户 2026-10-16：「能不能看出来是不是使用了子代理」——
    // 以前日志只有模型的 thought/message，工具调用一条都不记，所以看不出来。
    // 记成独立 tag `[chat:tool]`，与 `print:dsh-*` 的 App 日志区分开；**不记参数正文**
    // （可能含用户内容），只记工具名/类别/命令首行。）
    DiagnosticsLog.add(
      'chat:tool',
      '开始 ${_shortTool(title)}${command == null || command.trim().isEmpty ? '' : ' · ${_shortTool(command)}'}',
    );

    setState(() {
      final m = ChatMsg(
        text: title,
        role: ChatRole.tool,
        toolId: id,
        toolTitle: title,
        toolCommand: command,
        toolStatus: update['status'] as String? ?? 'in_progress',
      );
      _toolById[id] = m;
      _messages.add(m);
    });
    _autoScroll();
  }

  /// 从一条工具完成通知里取出文本输出（拼多段）。取不到就是空串。
  static String _toolOutputOf(Map<String, dynamic> update) {
    final content = update['content'];
    if (content is! List) return '';
    return content
        .map((c) => ((c as Map?)?['content'] as Map?)?['text'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .join('\n');
  }

  void _onToolResult(Map<String, dynamic> update) {
    final id = update['toolCallId'] as String? ?? 'unknown';
    final status = update['status'] as String? ?? '';
    // 结束也记一行（成败一目了然）——与上面 `chat:tool` 成对，便于算耗时/看是否重试。
    // 输出长度一并记下（2026-10-20）：真机日志里模型为跑通 `make-pptx.mjs` 试了 17 条 bash，
    // 而日志里只有"开始/结束"，看不到任何输出 —— 只能猜。成功但**输出为 0** 恰恰是
    // "脚本跑了但什么都没干"的典型信号，这条数字就能区分出来。
    // 正文只在**失败**时记前 400 字（成功输出可能含用户文件内容，不落盘）。
    final outForLog = _toolOutputOf(update);
    if (status.isNotEmpty) {
      final n = outForLog.trim().length;
      DiagnosticsLog.add('chat:tool',
          '结束 ${_shortTool(_toolById[id]?.toolTitle ?? id)} → $status'
          '${n == 0 ? '（无输出）' : '（输出 $n 字）'}');
      if (status != 'completed' && n > 0) {
        DiagnosticsLog.add('chat:tool',
            '失败输出：${outForLog.trim().substring(0, n > 400 ? 400 : n)}');
      }
    }
    // ⚠️ 完成通知通常**不带** rawInput —— 用首次通知里缓存的那份兜底，
    // 否则「写文件」类工具的 path 参数在这里就丢了（产物会漏）。
    final rawInput = update['rawInput'] ?? _toolRawById[id];
    final output = outForLog;

    if (!mounted) return;
    // 产物：工具完成后从它的标题/入参/输出里捞**候选名**，但捞到不等于产物 ——
    // 必须再去工作区核实"文件真的存在、而且是这次会话写出来的"（用户口径：
    // 「产物这里就应该是产生的文件」）。核实在 setState 外面做（要 stat 文件），
    // 通过了的再由 _adoptProducedArtifacts 补一次 setState。
    List<Artifact> candidates = const [];
    setState(() {
      final m = _toolById[id];
      if (m != null) {
        m.toolStatus = status;
        if (output.isNotEmpty) m.toolOutput = output;
      }
      if (status == 'completed') {
        candidates = extractArtifactCandidates(
          title: m?.toolTitle,
          rawInput: rawInput,
          output: output,
        );
      }
    });
    if (candidates.isNotEmpty) {
      unawaited(_adoptProducedArtifacts(candidates));
    }
    _autoScroll();
  }

  /// 候选名 → **核实过的产物**（真存在 + 本次会话写出来的）→ 进列表。
  ///
  /// 核实用的是产物自带的真实路径（没有路径的按会话 cwd 拼），一次只 stat 一个
  /// 文件 —— 不扫整个工作区。核实不过的**直接丢**：宁可产物是空的，
  /// 也不摆一堆点不开的卡片（用户实测反馈过：图还没出来就先冒出三个点不开的"产物"）。
  Future<void> _adoptProducedArtifacts(List<Artifact> candidates) async {
    List<Artifact> verified;
    try {
      verified = await verifyProducedArtifacts(
        candidates,
        cwd: _cwd,
        since: _sessionStartedAt,
      );
    } catch (e) {
      debugPrint('[chat] 产物核实失败：$e');
      return;
    }
    if (!mounted || verified.isEmpty) return;
    // 补上来源（意见⑤：资料库里要能看出是哪个会话产生的）。
    final sid = _sessionId;
    final tagged = <Artifact>[
      for (final a in verified)
        Artifact(
          name: a.name,
          extension: a.extension,
          sizeLabel: a.sizeLabel,
          path: a.path,
          sessionId: sid ?? a.sessionId,
          sessionCwd: _cwd,
        ),
    ];
    setState(() {
      for (final a in tagged) {
        if (_artifactKeys.add(a.key)) _artifacts.add(a);
      }
    });
    // 落盘（意见⑤）：退出会话再进来还能看到这批产物。
    if (sid != null && sid.isNotEmpty) {
      unawaited(_artifactStore.save(sid, List<Artifact>.of(_artifacts)));
    }
  }

  /// 读回落盘的产物列表（用户意见⑤）。
  ///
  /// 读回来的条目**仍然只是候选**：文件可能已经被删掉或挪走，所以照样过一遍
  /// [verifyProducedArtifacts]，核实不过的如实丢掉 —— 与实时核实同一条纪律，
  /// 不摆一堆点不开的卡片。
  Future<void> _restoreArtifacts(String sessionId) async {
    if (sessionId.isEmpty) return;
    try {
      final saved = await _artifactStore.load(sessionId);
      if (!mounted || saved.isEmpty) return;
      final verified = await verifyProducedArtifacts(
        saved,
        cwd: _cwd,
        // 产物是**上一次会话**写的，用 1970 当 floor 绕过「本次会话之后」这条过滤；
        // 真正要紧的「文件现在还在不在」那一条仍然生效。
        since: DateTime.fromMillisecondsSinceEpoch(0),
      );
      if (!mounted || verified.isEmpty) return;
      setState(() {
        for (final a in verified) {
          if (_artifactKeys.add(a.key)) _artifacts.add(a);
        }
      });
      debugPrint(
        '[chat] 从落盘索引恢复 ${verified.length} 个产物（${_shortId(sessionId)}）',
      );
    } catch (e) {
      debugPrint('[chat] 恢复产物索引失败：$e');
    }
  }

  /// 「长会话助手」（用户意见④）：预算可见 + 笔记接力 + 主动换窗。
  ///
  /// 三件事都**不调模型**：估算按消息长度算、笔记是模板、换窗由用户点。
  /// 这与 `dsh-smart-compact` 的省钱思路一致（判断留给新窗口里的模型自己做）。
  Future<void> _openContextHelper() async {
    final msgs = <BudgetMessage>[
      for (final m in _mergedMessages)
        if (m.text.trim().isNotEmpty)
          BudgetMessage(role: m.role.name, text: m.text),
    ];
    final budget = estimateContextBudget(msgs);
    final artifactNames = <String>[
      for (final a in _artifacts) a.path ?? a.fullName,
    ];
    if (!mounted) return;

    final picked = await showModalBottomSheet<String>(
      context: context,
      // ⚠️ 这里必须用**不透明实色**：原先用的是 navBg（深色下只有 10% 白），
      // 面板会和背后的消息流/背景参杂在一起、字看不清（用户实测反馈：
      // 「面板是透明的和背景参杂一块看的不是太清楚」）。
      backgroundColor: DshColors.surfaceStrong,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(DshMetrics.radius(18))),
      ),
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(
          DshMetrics.pagePad,
          16,
          DshMetrics.pagePad,
          24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('长会话助手'),
              style: TextStyle(color: DshColors.text, fontSize: 15),
            ),
            const SizedBox(height: 10),
            Text(
              context.tr('上下文估算：约 {0}（{1} 条消息 · 约 {2} tokens）{3}', [
                budget.percentLabel,
                msgs.length,
                budget.estTokens,
                budget.shouldRollover ? ' —— 建议现在就换一张新窗口' : ''
              ]),
              style: TextStyle(
                color:
                    budget.shouldRollover ? DshColors.err : DshColors.textDim,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            DshRichText(
              context.tr(
                  '这是按消息长度**估算**的（ACP 目前不把真实用量推给 App），只看趋势别看小数。\n换窗三步：① 生成交接笔记 → ② 发出去 → ③ 新建一个会话继续。'),
              style: TextStyle(
                color: DshColors.textFaint,
                fontSize: 11,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(ctx).pop('note'),
                icon: const Icon(Icons.edit_note, size: 18),
                label: Text(context.tr('生成交接笔记（插进输入框）')),
              ),
            ),
          ],
        ),
      ),
    );

    if (picked != 'note' || !mounted) return;
    final note = buildHandoffNote(
      messageCount: msgs.length,
      sessionTitle: _transcript?.title,
      workspacePath: _cwd,
      artifacts: artifactNames,
    );
    _insertIntoInput(note);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('交接笔记已插进输入框：确认后发送，再新建一个会话继续')),
      ),
    );
  }

  /// 权限确认弹层。
  ///
  /// **本轮修的就是它**：原来只拿 `toolCallId` 去查工具卡，查不到就只剩一句
  /// 「这是一次需要你确认的操作：」—— 没有工具名、没有参数，用户没法判断该不该允许
  /// （HANDOFF §11.6 记的老问题）。现在把 ACP `toolCall` 里的
  /// **类别 / 标题 / 内容首段 / rawInput** 全部摊出来，拿不到就**如实说没取到**，
  /// 并提示"不确定就先拒绝"。
  void _onPermission(AcpPermissionRequest req) {
    if (!mounted) return;
    debugPrint(
      '[chat] 权限请求 kind=${req.toolKind} title=${req.toolTitle} '
      'raw=${req.rawInputPreview}',
    );

    final detail = _resolvePermissionDetail(req);
    if (detail == null && req.toolCallId != null) {
      // ⚠️ **实测结论**：DSH 的 ACP 权限请求里**不带** toolCall 详情
      // （logcat 里是 `权限请求 kind=null title=null raw=`），
      // 工具名与参数只能从 `session/update` 的工具卡里取 —— 而工具卡**常常后到**。
      // 所以这里压后 700ms 再查一次，避免用户看到一行空白的「要执行的内容」。
      debugPrint('[chat] 权限请求暂无详情，等工具卡后重试（id=${req.toolCallId}）');
      unawaited(
          Future<void>.delayed(const Duration(milliseconds: 700)).then((_) {
        if (!mounted) return;
        _showPermissionDialog(req, _resolvePermissionDetail(req));
      }));
      return;
    }
    _showPermissionDialog(req, detail);
  }

  /// 解析「这一步要执行什么」。
  ///
  /// 两个来源，按可靠性排序：
  ///   1. ACP 请求自带的 `toolCall`（title / content / rawInput）——**实测常常是空的**；
  ///   2. `session/update` 记下的工具卡（`toolTitle` + `toolCommand`）。
  ///
  /// 两个都没有就返回 null，界面**如实说"没取到详情"**，而不是给个空白框。
  ({String? title, String? body})? _resolvePermissionDetail(
      AcpPermissionRequest req) {
    final card = req.toolCallId == null ? null : _toolById[req.toolCallId];
    final acpSummary = req.actionSummary;
    final title = (req.toolTitle?.trim().isNotEmpty ?? false)
        ? req.toolTitle!.trim()
        : (card?.toolTitle?.trim().isNotEmpty ?? false)
            ? card!.toolTitle!.trim()
            : null;
    final body = (acpSummary != null && acpSummary.trim().isNotEmpty)
        ? acpSummary.trim()
        : (card?.toolCommand?.trim().isNotEmpty ?? false)
            ? card!.toolCommand!.trim()
            : null;
    if (title == null && body == null) return null;
    return (title: title, body: body);
  }

  void _showPermissionDialog(
    AcpPermissionRequest req,
    ({String? title, String? body})? detail,
  ) {
    final kindLabel = _permissionKindLabel(req.toolKind);
    final shown = detail?.body;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: DshColors.surfaceStrong,
        title: Row(
          children: [
            Icon(Icons.gpp_maybe_outlined, size: 18, color: DshColors.busy),
            const SizedBox(width: 8),
            Expanded(
              child: Text(context.tr('Agent 请求执行操作'),
                  style: const TextStyle(fontSize: 16)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (kindLabel != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: DshColors.busy.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
                  border: Border.all(
                      color: DshColors.busy.withValues(alpha: 0.5), width: 0.8),
                ),
                child: Text(
                  kindLabel,
                  style: TextStyle(color: DshColors.busy, fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (detail?.title != null) ...[
              Row(
                children: [
                  Icon(Icons.build_outlined,
                      size: 14, color: DshColors.textDim),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      detail!.title!,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Text(
              context.tr('要执行的内容：'),
              style: TextStyle(color: DshColors.textDim, fontSize: 12.5),
            ),
            const SizedBox(height: 6),
            if (shown != null)
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: DshColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                  border: Border.all(color: DshColors.divider, width: 0.8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    shown,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      height: 1.5,
                    ),
                  ),
                ),
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: DshColors.err.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                  border: Border.all(
                      color: DshColors.err.withValues(alpha: 0.5), width: 0.8),
                ),
                child: Text(
                  context.tr(
                      '没能取到这一步的详情（协议里没有 title / content / rawInput）。不清楚它要做什么时，建议先点「拒绝」。'),
                  style: TextStyle(
                      color: DshColors.err, fontSize: 11.5, height: 1.5),
                ),
              ),
            if (req.rawInputPreview.isNotEmpty) ...[
              const SizedBox(height: 8),
              Theme(
                data: Theme.of(ctx).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    context.tr('技术细节（原始参数）'),
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                  ),
                  children: [
                    SelectableText(
                      req.rawInputPreview,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                        height: 1.4,
                        color: DshColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (req.toolCallId != null) ...[
              const SizedBox(height: 6),
              Text(
                context.tr('工具调用 {0}', [req.toolCallId]),
                style: TextStyle(color: DshColors.textFaint, fontSize: 10.5),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              req.reject();
              Navigator.of(ctx).pop();
            },
            child: Text(context.tr('拒绝')),
          ),
          FilledButton(
            onPressed: () {
              req.allowOnce();
              Navigator.of(ctx).pop();
            },
            child: Text(context.tr('允许一次')),
          ),
        ],
      ),
    );
  }

  /// 把 ACP 的 `kind` 翻成中文 —— 让用户一眼知道这是哪一类操作。
  String? _permissionKindLabel(String? kind) {
    switch (kind) {
      case 'read':
        return context.tr('读取文件');
      case 'edit':
        return context.tr('修改文件');
      case 'delete':
        return context.tr('删除文件');
      case 'move':
        return context.tr('移动文件');
      case 'search':
        return context.tr('搜索');
      case 'execute':
        return context.tr('执行命令');
      case 'think':
        return context.tr('思考');
      case 'fetch':
        return context.tr('联网请求');
      case 'other':
        return context.tr('其它操作');
      default:
        return (kind == null || kind.trim().isEmpty) ? null : kind;
    }
  }

  // ---------------------------------------------------------------- 交互

  Future<void> _send() async {
    final text = _input.text.trim();
    final acp = _acp;
    if (text.isEmpty || _running || _sendBusy || acp == null) return;

    // 会话**在这一刻**才创建（缺陷 A），并且创建后记住 id（缺陷 B）——
    // 见 [_ensureSession] 的注释。建不出来就如实说，不把这条消息吞掉。
    final String sessionId;
    if (_sessionId != null) {
      sessionId = _sessionId!;
    } else {
      _sendBusy = true;
      try {
        sessionId = await _ensureSession();
      } catch (e) {
        debugPrint('[chat] 建会话失败，这条没发出去：$e');
        if (mounted) {
          setState(() => _messages.add(ChatMsg(
                text: context.tr('这条没能发出去：会话没能建起来，可以再试一次。'),
                role: ChatRole.assistant,
                failed: true,
                detail: '$e',
              )));
        }
        return;
      } finally {
        _sendBusy = false;
      }
      if (!mounted) return;
    }

    _input.clear();
    // 记下这一轮的开始时刻 —— 顶栏据此显示「已等 M:SS」（审计 P1-1）。
    // 计时器不在这里管：由 [_ElapsedLabel] 自己持有，免得每秒重建整页。
    setState(() {
      _messages.add(ChatMsg(text: text, role: ChatRole.user));
      _turnStartedAt = DateTime.now();
      _running = true;
      // 同步到会话句柄：这样即使本页被 pop 掉，壳层（首页）也知道它还在跑。
      _live?.running = true;
      _live?.turnStartedAt = _turnStartedAt;
      _showAttachMenu = false;
    });
    // 只登记第一次：这次会话的标题就取用户的第一句话（不编造标题）
    if (!_sessionRegistered) {
      _sessionRegistered = true;
      widget.onSessionUsed?.call(id: sessionId, cwd: _cwd, title: text);
    }
    _autoScroll();

    // 用户消息之后的边界：重试前要把它之后的东西清掉（半截助手输出不能留）。
    final cleanTo = _messages.length;

    debugPrint('[chat] prompt: $text');
    // 本轮开始：输出字符数清零（下面 _onTextChunk 会累加）。
    _turnCharsOut = 0;
    // 用户反馈：会话里"看到很多失败"会把人吓跑 → **失败自动二次运行**，
    // 只有两次都没成功才说话；届时也只说人话，原始报错折进"技术细节"。
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final stopReason = await acp.prompt(sessionId, text);
        debugPrint('[chat] stopReason=$stopReason（第 $attempt 次尝试成功）');
        lastError = null;
        // 这一轮结束了，顺手更新"轮换池本次用哪个成员"（不是轮换池时自己会清空）。
        unawaited(_refreshRotateNote());
        // 成功了 → 把之前那条"没回上来"的失败记录擦掉（缺陷 C 的收尾），
        // 否则重新打开会话还会挂一条过期的失败提示。
        unawaited(clearSessionFailure(
          runtime: widget.runtime,
          sessionId: sessionId,
        ));
        break;
      } catch (e) {
        lastError = e;
        debugPrint('[chat] prompt failed（第 $attempt 次）: $e');
        final msg = e.toString().toLowerCase();
        // 缺陷 D：**超时不等于运行时那边停了** —— 它的 prompt 可能还在飞。
        // 不补一发 cancel，下一次发送就会撞上
        // `Invalid params: a prompt is already in flight for this session`
        // （设备日志里这个错 4 次，其中 2 次紧跟 ACP 超时 —— 就是这条链）。
        if (e is TimeoutException ||
            msg.contains('超时') ||
            msg.contains('timeout')) {
          try {
            await acp.cancel(sessionId);
            debugPrint('[chat] 上一轮超时 → 已发 session/cancel 收尾');
          } catch (ce) {
            debugPrint('[chat] 超时后 cancel 失败（仍按超时处理）：$ce');
          }
        }
        // 这几类重试没有意义，只会再失败一次、还把界面刷花：
        //   · **超时**：重试 = 让用户再干等一遍，静默时间直接翻倍
        //     （旧代码就是这样拿到"最长静默 10 分钟"的 —— 审计 P1-1）；
        //   · 用户自己取消；· 会话/进程没了；· 页面已经不在。
        //   · **翻译层说"不值得重试"的**（2026-10-12 新增）：401 / 403 / 404 这类
        //     「配置就不对」的失败，重试一次结果一模一样。别人那份 v0.57 日志里，
        //     用户因为不知道是 Key 无效而白试了 **4 次**（App 自动一轮 + 他手动一轮）。
        //     判据直接用翻译层的 `retryable`，**不在这里另写一套状态码规则**
        //     （两套规则必然跑偏）。429 / 5xx / 连不上 仍然照常重试。
        final t = translateDshError('$e');
        final noRetry = e is TimeoutException ||
            msg.contains('cancel') ||
            msg.contains('已退出') ||
            msg.contains('process exited') ||
            _acp == null ||
            _sessionId == null ||
            (t != null && !t.retryable);
        if (attempt == 2 || noRetry || !mounted) break;
        // 清掉这次可能已经吐了一半的助手消息，避免"半截 + 完整"两份叠一起。
        setState(() {
          if (_messages.length > cleanTo) {
            _messages.removeRange(cleanTo, _messages.length);
          }
        });
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (!mounted) break;
      }
    }
    if (lastError != null && mounted) {
      final f = _failureText(lastError);
      setState(() => _messages.add(
            ChatMsg(
                text: f.friendly,
                role: ChatRole.assistant,
                failed: true,
                detail: f.detail),
          ));
      // 缺陷 C：同时记进 App 侧的失败账本。
      //
      // 为什么不能只靠界面这条气泡：它是**内存**里的，退出再进来就没了；
      // 而 DSH 的会话转录只在失败时落 `assistant/attempt` + `llm/retry*`，
      // **不落错误事件**（写入方是运行时，不在本仓库）。所以回放时会出现
      // "我发了话、没有回答、也没有任何说明"。记一份之后，
      // `session_transcript.dart` 回放时会把原因合并成一条"没有回答"。
      unawaited(recordSessionFailure(
        runtime: widget.runtime,
        sessionId: sessionId,
        friendly: f.friendly,
        detail: f.detail,
      ));
    }
    if (mounted) {
      // 回合结束：缓冲里最后那几个字必须先上屏，否则会"少一句"。
      _flushPendingText();
      // 最后一段思考到回合结束为止 —— 记下时刻，结束后才有"思考了 N 秒"。
      _closeOpenThought(DateTime.now());
      setState(() {
        _running = false;
        _turnStartedAt = null;
      });
    }
    // 无论本页还在不在，都要让壳层知道这轮结束了（否则首页会一直显示"进行中"）。
    _live?.running = false;
    _live?.turnStartedAt = null;
    // 一轮结束 → 落一笔用量账。用**运行时报出来的** route（它才是真的在用哪个），
    // 拿不到才退回界面上的选中项。
    unawaited(_usage.add(
      route: _liveRoute ?? widget.models.selectedRoute,
      charsIn: text.length,
      charsOut: _turnCharsOut,
    ));
    _turnCharsOut = 0;
  }

  /// 失败文案：拆成 **(人话, 技术细节)** 两段。
  ///
  /// 用户反馈原话：「会话的时候，看到很多失败，能不能不要显示，会把用户吓跑的」
  /// ——所以主文案**只留人话**（翻译层见 `data/api_error_text.dart`：缺 Key / 连不上 /
  /// 模型没注册 等都有具体下一步），原始报错一律折进 [ChatMsg.detail]，
  /// 界面上默认不展开。认不出来的情况也不再把英文原文糊到对话里。
  ({String friendly, String? detail}) _failureText(Object e) {
    final raw = e.toString();
    final t = translateDshError(raw);
    final friendly =
        t?.zh ?? context.tr('这条没能回上来。可以再发一次；若反复如此，去「设置 → 运行日志」看细节。');
    final detail = (t?.detail ?? raw).trim();
    return (friendly: friendly, detail: detail.isEmpty ? null : detail);
  }

  /// 读轮换代理的日志，更新"本次用哪个成员"那行提示。
  ///
  /// 只在**当前模型是轮换池**时才查：别的模型压根不经过代理，查了也没意义。
  Future<void> _refreshRotateNote() async {
    final route = widget.models.selectedRoute ?? '';
    if (!route.startsWith('${ConfiguredModels.rotateProviderId}/')) {
      if (mounted && _rotateNote != null) setState(() => _rotateNote = null);
      return;
    }
    final used = await RotateLog(
      path: RotateLog.defaultPath(widget.runtime.nodeHome),
    ).lastUsed();
    if (!mounted) return;
    setState(() {
      _rotateNote = used == null
          ? null
          : context.tr('轮换池 {0} · 本次用 {1}', [used.pool, used.member]);
    });
  }

  Future<void> _cancel() async {
    final acp = _acp;
    final sessionId = _sessionId;
    if (acp == null || sessionId == null) return;
    await acp.cancel(sessionId);
    debugPrint('[chat] cancel sent');
  }

  Future<void> _openModelSheet() async {
    final picked =
        await showModelSheet(context, store: widget.models, usage: _usage);
    if (picked == null || !mounted) return;
    // ⚠️ **必须等选中项真的落盘**（`models.json.selected` + 安全区）。
    //
    // 面板是"selectModel()（async，不 await）→ 立刻 pop"，而这里紧接着就会让
    // 外层重读 `models.json` 并重写 overlay。不等落盘的话读到的还是**旧** selected，
    // overlay 里的默认路由也就没变 —— 这正是用户实测第 2 条
    // 「选一次不行，要选第二次才可以切换模型」的直接成因。
    try {
      await widget.models.selectionSettled;
    } catch (e, st) {
      // 这个 future 的契约是"永不抛"，所以走到这里说明契约被破坏了 ——
      // 绝不能像以前那样 `catch (_) {}` 静默吞掉：那正是"选一次不行"这条
      // bug 会**无痕复现**的原因（审计点名的那个吞掉的落盘）。
      debugPrint('[chat] 等待选中项落盘时抛了（不该发生）：$e\n$st');
    }
    if (!mounted) return;
    // ⚠️ 落盘失败时**不要**继续 onModelChanged：它会去读盘重写 overlay，
    // 而盘上还是旧的 selected —— 写出去的默认路由就是错的。
    // 宁可如实告诉用户"这次只在本会话生效"，也不要写一份错的 overlay。
    final persistErr = widget.models.selectionPersistError;
    if (persistErr != null) {
      debugPrint('[chat] 选中项落盘失败，跳过 overlay 重写：$persistErr');
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: DshRichText(context.tr(
              '模型已在本会话生效，但**没能记住**（保存失败：{0}）。重启 App 后会回到原来的模型。',
              [persistErr])),
        ));
      return;
    }
    // store 已经改了 → 通知外层重写 overlay（**让新建的会话**用新模型）；
    // 当前这个会话的模型切换由 [_onModelStoreChanged] → `_applyModelChange` 走
    // "会话内切换"完成 —— 用户第 11 条反馈要的就是别再重建会话。
    await widget.onModelChanged?.call();
  }

  void _openArtifacts() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtifactListPage(
          artifacts: List.of(_artifacts),
          cwd: _cwd,
        ),
      ),
    );
  }

  /// 附件菜单的动作分发。
  ///
  /// 本轮按用户要求去掉了 `连接器`（它是 WorkBuddy 的云端能力，本地无实现）。
  /// 剩下三项里有两项是**真链路**：
  ///   - `专家中心` → 弹出「已开启开关的专家」（真数据，来自 `$DSH_HOME/experts.json`）；
  ///   - `使用技能` → 切到「专家 → 技能」页（真实技能目录，可增删改）。
  /// `定时任务` 仍然是"切过去看空态"（本地没有调度引擎，不编造）。
  /// 拍照 / 照片视频 / 添加文件 仍然是没有接入的占位，如实提示。
  void _showAttachHint(String label) {
    setState(() => _showAttachMenu = false);
    switch (label) {
      case '专家中心':
        showEnabledExpertsSheet(context, dshHome: widget.runtime.nodeHome);
        return;
      case '使用技能':
        // 「专家」已经不是底部 Tab 了（用户 2026-10-09 挪进设置页），
        // 所以这里**不带 tab**，只带 expertTab —— AppShell 收到后推入专家页并
        // 落在技能那一栏（1）。
        Navigator.of(context).pop(<String, Object>{'expertTab': 1});
        return;
      case '定时任务':
        // 下标 3 = 底部「定时任务」（顺序：首页 / 影视 / 资料库 / 定时任务 / 设置）。
        // ⚠️ 这地方改过两次：2026-10-11 插「影视」3→4；2026-10-12 撤「本地大模型」4→3。
        //    写死下标就是"增删一个 Tab 就会断"的地方 —— 改 Tab 必须搜这几个数字。
        Navigator.of(context).pop(<String, Object>{'tab': 3});
        return;
      case '长会话助手':
        Navigator.of(context).pop();
        unawaited(_openContextHelper());
        return;
      default:
        // 拍照 / 照片视频 / 添加文件 —— 本轮做成**真能用**：
        // 走原生系统 Intent 取回文件（见 MainActivity 的 pickFile/pickMedia/takePhoto），
        // 拿到 App 私有目录里的真实绝对路径后**插进输入框**，由用户确认再发送。
        //
        // 为什么不直接把内容喂给模型：DSH 在 Android 上只有 `read` 工具可用
        // （bash/glob 都不可用），文本文件模型能真读到；图片/视频是二进制，
        // 能否"看懂"取决于模型视觉能力 —— 所以插入的文本里**如实注明**这一点，
        // 不制造"已经上传/已经识别"的假象。
        if (label == '拍照' || label == '照片／视频' || label == '添加文件') {
          final kind = label == '拍照'
              ? 'photo'
              : label == '照片／视频'
                  ? 'media'
                  : 'file';
          unawaited(_pickAttachment(kind));
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('{0}：这个入口还没接入', [label]))),
        );
    }
  }

  /// 「按住说话」状态变化。
  ///
  /// 2026-10-05 修正（用户反馈「语音依然无法使用，开通了麦克风权限也不行」）：
  /// 原实现是**松手之后才启动识别** —— 用户说话的整段时间里根本没有在录音，
  /// 必然采到静音，然后 onError(6/7) 失败。这才是"权限给了也没用"的真因。
  /// 现在改成：
  ///   * 按住 → 立刻 startListening（真的在听，界面显示"正在听"）
  ///   * 松手 → stopListening（触发 onResults，把结果填进输入框）
  ///
  /// 取消、设备没有识别服务、识别结果为空，都如实提示，**不假装成功**。
  /// 按住过程的视觉反馈仍由 InputBar 自己做。
  void _onVoiceState(bool held) {
    debugPrint('[chat] voice ${held ? 'hold' : 'release'}');
    setState(() => _voiceHeld = held);
    if (held) {
      _startSpeech();
    } else {
      unawaited(_stopSpeech());
    }
  }

  /// 按住：启动识别。**不 await** —— 让它一直听到松手为止。
  ///
  /// 单飞保护：上一次还没结束时不再启动新的（否则原生会回 BUSY）。
  void _startSpeech() {
    if (_speechRunning) return;
    _speechRunning = true;
    unawaited(_speakToText().whenComplete(() => _speechRunning = false));
  }

  /// 松手：让原生停止录音；识别结果由上面那个未完成的 [_speakToText] 返回。
  ///
  /// 系统 Intent 路径（设备端识别不可用时）由系统 App 自己录音，
  /// 这里会拿到 `noop` —— 属于正常，不做提示。
  Future<void> _stopSpeech() async {
    try {
      final r = await DshHost.stopSpeech();
      debugPrint('[chat] stopSpeech -> $r');
    } catch (e) {
      debugPrint('[chat] stopSpeech failed: $e');
    }
  }

  /// 松手后：调系统语音识别 → 识别结果填进输入框。
  Future<void> _speakToText() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final text = await DshHost.recognizeSpeech();
      if (!mounted) return;
      if (text == null || text.trim().isEmpty) {
        // 识别不到时**顺带把设备能力查出来** —— 用户反复反馈「语音还是不能用」，
        // 而"没识别到"这种含糊提示分不清是【手机根本没装识别服务】还是
        // 【装了但这次没听清】。这里直接把结论说出来，省得来回猜。
        String hint = context.tr('没有识别到内容（可能没说话、或识别服务临时失败）。可以重试，或先用文字输入。');
        try {
          final support = await DshHost.speechSupport();
          final handlers = support['intentHandlers'];
          final handlerCount = handlers is int ? handlers : -1;
          final onDevice = support['onDeviceAvailable'] == true;
          final available = support['recognitionAvailable'] == true;
          if (!onDevice && !available && handlerCount <= 0) {
            hint = tr(
                '语音输入用不了：这台手机的系统里**没有**任何语音识别服务（可处理识别的应用数={0}）。装一个语音助手类应用后它才会生效；在此之前请用文字输入。',
                [handlerCount]);
          }
        } catch (_) {
          // 自检失败不影响主提示
        }
        messenger.showSnackBar(
          // hint 里可能带 `**…**`（语音那条），走 Text 会露出星号。
          SnackBar(
              content: DshRichText(hint),
              duration: const Duration(seconds: 6)),
        );
        return;
      }
      _insertIntoInput(text.trim());
      messenger.showSnackBar(
        SnackBar(content: Text(context.tr('已把识别结果填进输入框，确认后点发送'))),
      );
    } on PlatformException catch (e) {
      debugPrint('[chat] speech failed: ${e.code} ${e.message}');
      if (!mounted) return;
      messenger.showSnackBar(
          SnackBar(content: Text(e.message ?? context.tr('语音识别不可用'))));
    } catch (e) {
      debugPrint('[chat] speech threw: $e');
      if (!mounted) return;
      messenger
          .showSnackBar(SnackBar(content: Text(context.tr('语音识别失败：{0}', [e]))));
    }
  }

  /// 调内置「看图代理」把图片转成文字（用户意见②）。
  ///
  /// 为什么要它：用户的模型大多是纯文本的，图片丢过去只会得到「我看不到图」。
  /// `vision-proxy.mjs` 内置一条**免费视觉链**（智谱三个免费模型 → OVH 匿名兜底），
  /// 无需任何 Key 就能先跑通匿名那条。
  ///
  /// **失败一律返回 null** —— 让调用方退回原来的「只给路径 + 如实说明」，
  /// 不编一段假描述糊弄模型。
  Future<String?> _describeImage(String path) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(context.tr('正在看图（免费视觉链，可能要十几秒）…'))),
    );
    try {
      final r = await widget.runtime.runOnce(
        <String>[widget.runtime.visionProxyScriptPath, path, '--text'],
        timeout: const Duration(seconds: 200),
      );
      final out = r.stdout.trim();
      if (r.exitCode == 0 && out.isNotEmpty) {
        debugPrint('[chat] vision-proxy ok（${out.length} 字）');
        return out;
      }
      debugPrint(
        '[chat] vision-proxy 未成功（exit=${r.exitCode}）：'
        '${r.stderr.trim().split('\n').take(3).join(' | ')}',
      );
      return null;
    } catch (e) {
      debugPrint('[chat] vision-proxy 调用失败：$e');
      return null;
    }
  }

  /// 拍照 / 照片视频 / 添加文件：走原生系统 Intent 取回**真实路径**，插进输入框。
  ///
  /// 不做"上传"这件事：DSH 在 Android 上只有 `read` 工具可用，文本文件模型能真读到；
  /// 图片/视频是二进制，**能否理解取决于模型视觉能力** —— 所以插进去的文本里
  /// 如实写明这一点，不制造"已上传/已识别"的假象。
  Future<void> _pickAttachment(String kind) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await DshHost.pickAttachment(kind);
      if (!mounted) return;
      if (path == null || path.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(context.tr('已取消'))));
        return;
      }
      final isFile = kind == 'file';
      // 意见②：图片/视频先过一遍内置「看图代理」，把画面转成文字。
      // 手机上多半没有视觉模型 —— 只丢一个路径给文本模型，它只会回"我看不到图"。
      String? vision;
      if (!isFile) {
        vision = await _describeImage(path);
      }
      final text = isFile
          ? tr('请阅读这个文件：{0}', [path])
          : (vision != null && vision.trim().isNotEmpty)
              ? tr('我刚{0}：{1}\n\n【自动看图结果 · 由内置免费视觉链生成，供参考】\n{2}', [
                  kind == 'photo' ? '拍了一张照片' : '选了一个图片或视频',
                  path,
                  vision.trim()
                ])
              : tr('我刚{0}：{1}\n（这是二进制文件，我这边只有 read 工具，能否理解取决于模型的视觉能力）',
                  [kind == 'photo' ? '拍了一张照片' : '选了一个图片或视频', path]);
      _insertIntoInput(text);
      debugPrint('[chat] attach($kind) -> $path');
      messenger.showSnackBar(
        SnackBar(
            content: Text(tr('已插入{0}，确认后点发送', [isFile ? '文件路径' : '媒体路径']))),
      );
    } on PlatformException catch (e) {
      debugPrint('[chat] attach failed: ${e.code} ${e.message}');
      if (!mounted) return;
      messenger.showSnackBar(
          SnackBar(content: Text(e.message ?? context.tr('选择失败'))));
    } catch (e) {
      debugPrint('[chat] attach threw: $e');
      if (!mounted) return;
      messenger
          .showSnackBar(SnackBar(content: Text(context.tr('选择失败：{0}', [e]))));
    }
  }

  /// 把文本追加进输入框（空框就直接放），光标移到末尾。
  void _insertIntoInput(String text) {
    final current = _input.text.trimRight();
    _input.text = current.isEmpty ? text : '$current\n$text';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    if (mounted) setState(() {});
  }

  /// 会话标题（左上角那行）。
  ///
  /// 用户的实测反馈：「左上角一直是『最近爆火的一套抽象 AI 漫剧』，
  /// 这个不应该是当前会话的名称吗」—— 对，那串是**设计稿里的示例标题**，
  /// 早先被硬编码进来了。现在按真实来源取，优先级：
  ///   1. 恢复的会话 → 磁盘记录里的真实标题（`session/title`，DSH 自己生成的）；
  ///   2. 本次会话已经说过话 → 第一句用户消息的前 16 字；
  ///   3. 都还没有 → 「新会话」。
  String get _displayTitle {
    final t = _transcript?.title;
    if (t != null && t.trim().isNotEmpty) return t.trim();
    for (final m in _messages) {
      if (m.role == ChatRole.user && m.text.trim().isNotEmpty) {
        final s = m.text.trim().replaceAll('\n', ' ');
        return s.length <= 16 ? s : '${s.substring(0, 16)}…';
      }
    }
    return context.tr('新会话');
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      // 左侧会话抽屉（参照 WorkBuddy 的左上角 → 左侧列表）。
      drawer: _buildSessionDrawer(context),
      body: Column(
        children: [
          ChatTopBar(
            // ⚠️ 这里原来是硬编码的设计稿示例标题「最近爆火的一套抽象 AI 漫剧」。
            // 用户反馈：「左上角一直是那串，这个不应该是当前会话的名称吗」—— 对，
            // 现在改成真实标题（见 [_displayTitle]）。
            title: _displayTitle,
            running: _running,
            onCancel: _cancel,
            onOpenWorkspaces: widget.onOpenWorkspaces,
            workspaceLabel: widget.workspaceLabel,
            artifactCount: _artifacts.length,
            onOpenArtifacts: _openArtifacts,
            onOpenSessions: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          Expanded(child: _buildBody()),
          if (_showAttachMenu)
            AttachMenu(
              onPick: _showAttachHint,
              onClose: () => setState(() => _showAttachMenu = false),
            ),
          // 「按住说话」按住时上方出现的提示条。
          // 用一个固定高度占位（内容可空），按下/松开都**不会**把输入框顶动 ——
          // 否则按住时输入框会跳一下，手感很差。
          SizedBox(
            height: screenH * 0.03,
            child: _voiceHeld
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: DshColors.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          context.tr('正在聆听…松开结束'),
                          style: TextStyle(
                              color: DshColors.accent, fontSize: 12.5),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          _buildInput(),
          DshBottomNav(
            currentIndex: 0,
            onTap: (i) {
              // 对话页是从任务页推上来的全屏页；点别的 Tab 就退回外层切换。
              if (i != 0) Navigator.of(context).pop(i);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_starting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2.5),
            const SizedBox(height: 16),
            Text(context.tr('正在启动 DSH 会话…'),
                style: TextStyle(fontSize: 13, color: DshColors.textDim)),
          ],
        ),
      );
    }

    // 恢复失败：如实说明原因，并给一个出口（不要让人卡在"什么都没有的一页"）
    if (_resumeError != null) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('这条会话没能恢复'),
              style:
                  TextStyle(color: DshColors.err, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            DshRichText(
              context.tr(
                  'ACP 的 session/resume 只恢复会话本身（模型上下文仍然在），但 DSH 要求工作目录与建会话时**完全一致**才允许恢复。'),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  _resumeError!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: DshColors.textDim,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _startFreshInstead,
                  child: Text(context.tr('改为新建会话')),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(context.tr('返回')),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (_startError != null) {
      // ⚠️ 这一页以前**只有标题 + 一堆裸异常文本，一个按钮都没有**（审计 P1-2）：
      // 用户起不来的时候会卡在一页死文字上，既不能重试也不能退出去 ——
      // 而隔壁"恢复失败"那一页早就有说明和两颗按钮了。同一个界面两种口径。
      // 现在对齐：**说明"为什么会这样 / 下一步做什么" + 重试 + 返回**。
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('会话启动失败'),
              style:
                  TextStyle(color: DshColors.err, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            DshRichText(
              context.tr('没能把会话跑起来。常见原因：模型还没配好、网络不通，'
                  '或者本机模型服务已经停了。改完之后点「重试」；'
                  '下面的报文是给开发者看的原始信息。'),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  _startError!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: DshColors.textDim,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _starting ? null : _start,
                  child: Text(context.tr('重试')),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(context.tr('返回')),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 没有可用模型：先把话说清楚（现在发消息调不到模型），再给一个出口。
        //
        // 这是用户实测反馈第 4 条的同一根因 —— 界面不说明"下一步去哪"，
        // 用户只能自己猜。原来这里只有输入区旁边那个「未配置模型」小块，
        // 发送失败后拿到的是一串协议错误，看不出该去设置里做什么。
        if (!widget.models.hasModels) _noModelNotice(),
        if (_rolloverNoticeLevel > 0) _rolloverNotice(),
        // 恢复来的会话：把**历史记录回放出来**（本轮新增）。
        //
        // 以前这里只有一句"历史消息不在界面上回放"的说明 —— 因为 ACP 的
        // `session/resume` 只返回 configOptions、不带任何历史消息（实测 DSH 源码
        // dsh-acp/lib/index.js:1208-1251）。现在改成自己读会话记录文件来还原。
        if (_resumed) _historyBanner(),
        Expanded(
          child: MessageStream(
            messages: _mergedMessages,
            artifacts: _artifacts,
            running: _running,
            turnStartedAt: _turnStartedAt,
            controller: _scroll,
            onOpenArtifacts: _openArtifacts,
            cwd: _cwd,
            thinkingMode: widget.thinkingMode,
          ),
        ),
      ],
    );
  }

  /// 上下文用掉多少的**主动提示**档位（0=还没提示过，1=提示过 70%，2=提示过 90%）。
  ///
  /// 用户 2026-10-16：「是不是用户使用的会话时间长了，可以提示用户使用长会话助手」
  /// —— 可以实现，而且**判据早就有了**（`ContextBudget.shouldRollover` = 用掉 ≥70%），
  /// 以前只用在面板内部、从来不主动提醒。
  ///
  /// 刻意克制：**跨过 70% / 90% 各提示一次**；用户点开助手或直接关掉就不再纠缠
  /// （`99` = 用户已经处理过这件事）。
  int _rolloverNoticeLevel = 0;

  /// 预算缓存：按**消息条数**失效（估算要遍历全部消息，不能每帧都算）。
  ContextBudget? _budgetCache;
  int _budgetCacheFor = -1;

  /// 当前上下文预算（**按消息长度估算**：不调模型、不花钱、不上传）。
  ContextBudget? get _budget {
    final n = _messages.length;
    if (_budgetCacheFor == n) return _budgetCache;
    final msgs = <BudgetMessage>[
      for (final m in _mergedMessages)
        if (m.text.trim().isNotEmpty)
          BudgetMessage(role: m.role.name, text: m.text),
    ];
    _budgetCache = msgs.isEmpty ? null : estimateContextBudget(msgs);
    _budgetCacheFor = n;
    return _budgetCache;
  }

  /// 消息有变化时调一次：跨过新档位就把提示升起来（各档只提示一次）。
  void _maybePromptRollover() {
    if (!mounted || _rolloverNoticeLevel >= 99) return;
    final b = _budget;
    if (b == null) return;
    final level = b.ratio >= 0.9 ? 2 : (b.ratio >= 0.7 ? 1 : 0);
    if (level > _rolloverNoticeLevel) {
      setState(() => _rolloverNoticeLevel = level);
    }
  }

  /// 上下文用得差不多了 —— 提示用户去用「长会话助手」。
  ///
  /// ⚠️ 文案必须写**"估算"**：这个百分比是按消息长度算的，不是服务商给的真实用量。
  Widget _rolloverNotice() {
    final pct = _budget?.percentLabel ?? '';
    final urgent = _rolloverNoticeLevel >= 2;
    final tone = urgent ? DshColors.err : DshColors.accent;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
          DshMetrics.pagePad, 6, DshMetrics.pagePad, 0),
      padding: const EdgeInsets.fromLTRB(11, 6, 4, 6),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
        border: Border.all(color: tone.withValues(alpha: 0.45), width: 0.8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.auto_awesome_motion_outlined, size: 15, color: tone),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              context.tr(
                  '这段会话的上下文已经用掉约 {0}（估算）。用「长会话助手」可以把关键信息跟着带到新窗口，接着聊不会断。',
                  <Object?>[pct]),
              style: TextStyle(color: tone, fontSize: 11, height: 1.5),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() => _rolloverNoticeLevel = 99);
              unawaited(_openContextHelper());
            },
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(context.tr('去处理'),
                style: TextStyle(fontSize: 12, color: tone)),
          ),
          IconButton(
            onPressed: () => setState(() => _rolloverNoticeLevel = 99),
            icon: Icon(Icons.close, size: 15, color: tone),
            visualDensity: VisualDensity.compact,
            tooltip: context.tr('这次不提示'),
          ),
        ],
      ),
    );
  }

  /// 没有可用模型时的提示条（`ModelStore.hasModels == false`）。
  ///
  /// 只做两件事：**如实说明**现在发消息调不到模型、**给出口**（去设置）。
  /// 刻意不在这里做"自动跳设置"或"禁用发送"之类的改动 —— 发送链路本身不动，
  /// 用户仍然可以自己点发送去看真实报错（真话优先，但先给他正确的下一步）。
  ///
  /// ⚠️ **必须区分两种"空"**（用户实测遇到过第二种，"有厂家没模型"）：
  ///   * 没配 Key / 没配厂家 → 去设置填地址和 Key；
  ///   * 厂家在、Key 也配了，但模型清单是空的 → 让他去「获取模型」勾模型，
  ///     而不是再填一遍 Key（照原来那句做多少遍都不会好）。
  Widget _noModelNotice() {
    final noModels = widget.models.providersWithoutModels;
    final text = noModels
        ? (widget.models.hasAnyProviderKey
            ? context
                .tr('厂家和 Key 都有了，但还没有模型：去「设置 → 模型」点「获取模型」，勾好模型再保存，会话里才会出现可选模型。（想省事也可以先打开「免费模型（无需 Key）」。）')
            : context.tr('还差模型。最快的一条路：去「设置 → 模型」打开「免费模型（无需 Key）」——不用填任何 Key，打开就能用；想用自己的模型，再填地址和 API Key。'))
        : context.tr('还没有可用模型。想马上就用：去「设置 → 模型」打开「免费模型（无需 Key）」，不用填 Key 也不花钱；想用自己的模型（DeepSeek / Agnes 等），再填地址和 API Key 点「测试并保存」。');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
          DshMetrics.pagePad, 6, DshMetrics.pagePad, 0),
      padding: const EdgeInsets.fromLTRB(11, 8, 6, 8),
      decoration: BoxDecoration(
        color: DshColors.err.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
        border: Border.all(
            color: DshColors.err.withValues(alpha: 0.45), width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off_outlined, size: 15, color: DshColors.err),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: DshColors.err, fontSize: 11, height: 1.5),
            ),
          ),
          TextButton(
            onPressed: widget.onOpenSettings,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child:
                Text(context.tr('去设置'), style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 读会话记录文件，把历史存进 state。
  ///
  /// 失败**如实记原因**（`_transcriptError`），不要把"读不到"显示成"这条会话没有历史"。
  Future<void> _loadTranscript(String sessionId) async {
    if (!mounted) return;
    setState(() {
      _transcriptLoading = true;
      _transcriptError = null;
    });
    final t = await loadSessionTranscript(
      runtime: widget.runtime,
      sessionId: sessionId,
    );
    if (!mounted) return;
    setState(() {
      _transcriptLoading = false;
      _transcript = t;
      // 历史**并进消息流**（不是另开一个只读框）：用户 2026-10-15 第 1 条 ——
      // 「换厂家之后感觉保留的是摘要 / 多次进出感觉还是丢失了」。
      _resumedHistory
        ..clear()
        ..addAll(_toChatMsgs(t));
      _transcriptError = t == null
          ? context.tr('没能读到这条会话的历史记录（会话文件可能已被清理，或解码失败）。模型的上下文仍然在，直接接着问就行。')
          : null;
    });
    // 读回这条会话之前产生过的产物（意见⑤）：产物列表原本是纯内存的，
    // 退出再进来就空了，用户只能去资料库翻，还看不出是哪个会话产生的。
    unawaited(_restoreArtifacts(sessionId));
  }

  /// 恢复会话时顶部的历史回放块：只读、可展开/收起、**限高**
  /// （限高是必须的：消息可能几十条，不限高会把下面的消息区挤没）。
  /// 恢复会话时顶上那条**状态说明条**（用户 2026-10-15 第 1 条）。
  ///
  /// ## 为什么不在这里画消息了（这是那次反馈的根因）
  ///
  /// 原来这里是一个**可展开的"历史记录 · 只读回放"框**，历史消息只活在这个框里、
  /// **不进消息流**。于是用户看到的就是：「换厂家 / 退出重进之后，会话只剩一段摘要」
  /// —— 而模型的上下文其实一直都在（DSH 的 `session/resume` 会把会话的**全部**
  /// 事件读回来重建，见 `dsh-agent-loop` 的 `resumeWith()`：`persistence.open()` →
  /// `handle.read(0, undefined)` 整段当 seed）。**丢的是界面上的可见性，不是记忆。**
  ///
  /// 所以现在历史被**并进消息流**（见 [_mergedMessages]），这里只留一条说明：
  /// 从哪个文件读的、共几条、有多少条更早的没显示、读失败时到底是什么原因。
  Widget _historyBanner() {
    final t = _transcript;
    final title = t?.title;
    final text = _transcriptError != null
        ? _transcriptError!
        : _transcriptLoading || t == null
            ? context.tr('正在读取历史记录…')
            : t.messages.isEmpty
                ? context.tr('这条会话在磁盘上没有可回放的消息。')
                : context.tr('已恢复历史 · {0} · {1} 条{2} —— 直接接着问就行', [
                    title == null || title.trim().isEmpty
                        ? '会话 ${_shortId(_sessionId)}'
                        : title.trim(),
                    t.total,
                    t.capped > 0 ? '（另有 ${t.capped} 条更早的未显示）' : '',
                  ]);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
          DshMetrics.pagePad, 6, DshMetrics.pagePad, 0),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
        border: Border.all(color: DshColors.divider, width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _transcriptError != null ? Icons.error_outline : Icons.history,
            size: 14,
            color: _transcriptError != null ? DshColors.err : DshColors.accent,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color:
                    _transcriptError != null ? DshColors.err : DshColors.textDim,
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 把磁盘 transcript 折成消息流的形状（[ChatMessage] → [ChatMsg]）。
  ///
  /// `notice` 是 App 侧补的"这一轮没回上来 + 原因"（见 `session_failure_store.dart`）——
  /// 画成**失败的助手气泡**（`failed: true`），与实时失败同一种样式。
  /// 绝不许画成"模型说了这句话"的正常回答。
  static List<ChatMsg> _toChatMsgs(SessionTranscript? t) {
    if (t == null) return const <ChatMsg>[];
    return <ChatMsg>[
      for (final m in t.messages)
        ChatMsg(
          text: m.text,
          // `notice` 走 assistant（再带 failed）—— 与实时失败同一种气泡样式：
          // 它是"这一轮没有回答 + 原因"，不是用户说的话。
          role: m.isUser && !m.isNotice ? ChatRole.user : ChatRole.assistant,
          failed: m.isNotice,
          detail: m.detail,
        ),
    ];
  }

  /// 底部输入区。
  ///
  /// 设计稿（page-02 / 11）纵向次序与比例：
  ///   输入胶囊 `按住说话`  y=2138~2200 → 81.0%~83.3%
  ///   模型按钮 `Hy4preview` y=2292~2346 → 86.8%~88.9%
  ///   底部导航标签         y=2567~2610 → 97.2%~98.9%
  ///
  /// ⚠️ 高度**不写死**：模拟器底部导航带手势条，留给输入区的空间比设计稿窄，
  /// 写死高度会压出 `RenderFlex overflowed`（实测 8.9px）。这里只给下限，
  /// 内容（46dp 胶囊 + 7dp + 24dp 模型按钮）自己撑开，任何机型都不会溢出。
  Widget _buildInput() {
    final screenH = MediaQuery.sizeOf(context).height;
    // 轮换池提示：贴在输入框上方一行，不打断内容（用户要求"在会话里提醒"）。
    if (_rotateNote != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                DshMetrics.pagePad, 2, DshMetrics.pagePad, 0),
            child: Row(
              children: <Widget>[
                Icon(Icons.swap_horiz, size: 13, color: DshColors.textFaint),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(_rotateNote!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: DshColors.textFaint,
                          fontSize: 10.5,
                          height: 1.4)),
                ),
              ],
            ),
          ),
          _buildInputBox(screenH),
        ],
      );
    }
    return _buildInputBox(screenH);
  }

  Widget _buildSessionDrawer(BuildContext context) {
    final live = <DrawerSession>[];
    final reg = widget.sessions;
    if (reg != null) {
      for (final s in reg.all) {
        final sid = s.sessionId;
        if (sid == null || sid.isEmpty) continue; // 还没真正建会话的句柄不列
        live.add(DrawerSession(
          sessionId: sid,
          title: (s.title == null || s.title!.trim().isEmpty)
              ? context.tr('未命名会话')
              : s.title!,
          cwd: s.workspace,
          running: s.running,
          live: true,
        ));
      }
    }
    return SessionDrawer(
      currentSessionId: _sessionId,
      workspaceLabel: widget.workspaceLabel,
      live: live,
      loadHistory: widget.sessionListFor,
      onNewChat: () {
        final f = widget.onNewChat;
        if (f != null) {
          f();
        } else {
          Navigator.of(context).pop();
        }
      },
      onHome: () => Navigator.of(context).pop(),
      onPick: (picked) {
        if (picked.sessionId == _sessionId) return;
        final open = widget.onOpenSession;
        if (open == null) return;
        open(DshSession(
          id: picked.sessionId,
          cwd: picked.cwd,
          title: picked.title,
        ));
      },
    );
  }

  Widget _buildInputBox(double screenH) {
    return Container(
      color: Colors.transparent,
      constraints: BoxConstraints(minHeight: screenH * 0.088),
      padding: EdgeInsets.fromLTRB(
        DshMetrics.pagePad,
        // 模拟器实测：这块按 0.010 屏高留白时胶囊中心在 84.5%，
        // 设计稿是 82.15% —— 所以上留白收到 2dp 把胶囊顶上去。
        2,
        DshMetrics.pagePad,
        (screenH * 0.005).clamp(3, 9),
      ),
      child: InputBar(
        controller: _input,
        hintText: context.tr('按住说话'),
        modelName: widget.models.selectedName,
        enabled: !_running,
        running: _running,
        voiceMode: true,
        canSend: _hasInput,
        voiceHeld: _voiceHeld,
        onVoiceState: _onVoiceState,
        onSend: _send,
        onCancel: _cancel,
        onTapModel: _openModelSheet,
        onTapAttach: () => setState(() => _showAttachMenu = !_showAttachMenu),
      ),
    );
  }
}

/// 对话页顶栏：标题 + `○本机 · <工作区名>` + 产物入口 + 工作区入口
///
/// 右上角**原来是一个齿轮（进「模型设置」）**，用户要求改成工作区入口：
/// 「右上角有个按钮是模型设置的按钮，改成工作区选择会话，和首页右上角工作区一个功能」。
/// 用的是共用组件 `WorkspaceEntryButton` —— 和首页顶栏那个是同一个东西，
/// 点进去也是同一个 `WorkspacePage`。
///
/// **刻意不叫 `_ChatTopBar`（私有）**：顶栏最挤的时候（会话在跑 + 有产物）
/// 右边同时挂三个东西，横向会不会溢出必须能用 widget 测试钉住
/// （测试溢出在 Flutter 里是抛异常，等于一条真实的回归网）。见
/// `test/chat_top_bar_test.dart`。
class ChatTopBar extends StatelessWidget {
  const ChatTopBar({
    super.key,
    required this.title,
    required this.running,
    required this.onCancel,
    required this.onOpenWorkspaces,
    required this.artifactCount,
    required this.onOpenArtifacts,
    this.workspaceLabel,
    this.onOpenSessions,
  });

  final String title;
  final bool running;
  final VoidCallback onCancel;

  /// 左上角「会话」按钮：拉开左侧会话抽屉。为空时不显示。
  final VoidCallback? onOpenSessions;

  /// 为空时不显示工作区入口（见 [ChatPage.onOpenWorkspaces]）
  final VoidCallback? onOpenWorkspaces;

  /// 会话所在工作区的展示名，拼在第二行 `本机 · ` 后面
  final String? workspaceLabel;
  final int artifactCount;
  final VoidCallback onOpenArtifacts;

  /// 顶栏右侧文字按钮的统一紧凑样式。
  ///
  /// **为什么必须压**：顶栏最挤时右边同时挂「停止 / 产物 N / 工作区」。
  /// 默认 `TextButton` 是 48dp 触控高 + 更宽的横向留白，实测三者自然宽度
  /// 81.2 / 136.6 / 72.3dp —— 加上返回键与左右留白共 350dp，
  /// **320dp 宽的机型直接溢出 30px**（`test/chat_top_bar_test.dart` 复现的
  /// 就是这条）。这里压到 32dp 高、横向 6dp、12pt 字，三者合计 ~210dp，
  /// 320dp 屏也放得下。
  static final ButtonStyle _actionStyle = TextButton.styleFrom(
    minimumSize: const Size(0, 32),
    padding: const EdgeInsets.symmetric(horizontal: 6),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
  );

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    return SafeArea(
      bottom: false,
      child: SizedBox(
        // 设计稿对话页顶栏：标题带 162~214（6.1%~8.1%）+ `○云端` 239~292（9.1%~11.1%）。
        // 整块底边落在屏高 11.1%，换算成 dp 就是 0.102*屏高 + 6（和 DshPageHeader 同源）。
        height: DshMetrics.topBarHeight(screenH),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              IconButton(
                tooltip: context.tr('返回'),
                icon: const Icon(Icons.arrow_back_ios_new, size: 17),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              // 左上角「会话」：拉开左侧抽屉（参照 WorkBuddy）。
              if (onOpenSessions != null)
                IconButton(
                  tooltip: context.tr('会话列表'),
                  icon: const Icon(Icons.view_sidebar_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: onOpenSessions,
                ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: DshColors.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            // 设计稿这里是 `○本机`；会话页再补上"在哪个工作区"——
                            // 右上角就是工作区入口，标题说明当前站在哪儿才不糊涂。
                            workspaceLabel == null || workspaceLabel!.isEmpty
                                ? context.tr('本机')
                                : context.tr('本机 · {0}', [workspaceLabel]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: DshColors.textDim,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (running)
                TextButton.icon(
                  onPressed: onCancel,
                  style: _actionStyle,
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: Text(context.tr('停止'),
                      style: const TextStyle(fontSize: 12)),
                ),
              // 「产物」入口：**常驻显示**（用户要求：会话右上角、工作区左边，
              // 每个会话产生的文件都能从这里看到）。一条产物都没有时也点得进去，
              // 里面是空态说明。
              TextButton.icon(
                onPressed: onOpenArtifacts,
                style: _actionStyle,
                icon: const Icon(Icons.inventory_2_outlined, size: 15),
                label: Text(
                  artifactCount > 0
                      ? context.tr('产物 {0}', [artifactCount])
                      : context.tr('产物'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              // 右上角：工作区入口（原来是齿轮 = 进「模型设置」）。
              // 「模型设置」没有丢：底部导航有「设置」Tab，会话页的错误提示条
              // 里也留着「去设置」。
              if (onOpenWorkspaces != null)
                WorkspaceEntryButton(compact: true, onTap: onOpenWorkspaces!),
            ],
          ),
        ),
      ),
    );
  }
}
