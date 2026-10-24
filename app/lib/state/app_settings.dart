import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n/app_language.dart';
import '../ui/theme/dsh_palette.dart';
// 只为一个地址校验函数（`looksLikeUpdateSource`）+ 那个"本进程内最后一次结果"的类型
// （`UpdateCheckResult`）—— 地址与检查逻辑放在 local 层，设置层不该反过来定义它们。
import '../local/update_checker.dart';
import '../local/broadcast_feed.dart';
import '../local/update_source.dart';

import '../i18n/dsh_i18n.dart';

/// 外观类设置：**主题皮肤** + 字号缩放 + **界面语言**。持久化用 `SharedPreferences`。
///
/// 为什么和模型配置分开存：模型配置（Key / 端点 / model id）是**凭据级**
/// 信息，走 `flutter_secure_storage`（Android Keystore）；主题字号是无所谓的
/// 界面偏好，放 SharedPreferences 更合适 —— 也不必每次启动都动一次 Keystore。
///
/// 主题这条链路的全貌（改造后）：
///   1. 本类持有皮肤 id，**只存 `light` / `dark` 两个真值**；
///   2. `main.dart` 在 `ListenableBuilder` 里把它喂给 `DshColors.applySkin`；
///   3. 同一层重建 `MaterialApp(theme: buildDshTheme())` —— 全树（含推入的
///      对话页）跟着重算配色，切主题立即生效。
///
/// 「自定义」在本轮是**占位**：它不是一个皮肤、不进 [skinId]、不落盘，
/// 点了只会由设置页如实说明"还没做"（见 [customPendingNote]）。
class AppSettings extends ChangeNotifier {
  AppSettings();

  static const String _kTextScale = 'dsh_text_scale';

  static const String _kSkin = 'dsh_theme_skin';
  static const String _kLanguage = 'dsh_ui_language';

  /// 本地大模型：**推理后端**与**上下文长度**。
  ///
  /// 为什么要落盘（真机 2026-10-09 用户反馈）：这两项以前只存在「本地大模型」页的
  /// State 里，而那一页是从设置页 `push` 进来的 —— 一返回就被销毁，下次进去全回默认，
  /// 用户每次调完都得重调一遍。它们本来就只影响"下次启动本地服务"，落盘零副作用。
  static const String _kLocalBackend = 'dsh_local_backend';
  static const String _kLocalContext = 'dsh_local_context';

  /// 联网搜索用哪家（`off` / `tavily` / `serper` / `bocha` / `deepseek`）。
  ///
  /// 只存**厂家 id**；Key 一律进系统安全区（`ProviderKeys`，键名 `search-<id>`），
  /// 与模型厂家的 Key 分开存，互不覆盖、也不进日志。
  static const String _kSearchProvider = 'dsh_search_provider';

  /// **允许 DSH 打开的本机应用**（包名列表，用户显式勾过的）。
  ///
  /// 为什么要白名单而不是"每次都弹确认"：请求来自模型（可能 App 在后台），
  /// 后台弹确认框用户根本看不见 —— 与其搞一个不可靠的确认，不如让**用户事先**
  /// 决定哪些应用可以被打开，模型无权自行放行。

  /// 上次停在哪个底部 Tab（换页就写一次）。
  ///
  /// 为什么要落盘：用户真机反馈「用相机/相册取图回来后会跳回首页」——
  /// 不管触发原因是 Activity 重建还是别的，**把“停在哪一页”记住**都能让他回到原处，
  /// 而不是莫名其妙掉回首页。
  static const String _kLastTab = 'dsh_last_tab';

  /// 「免费模型（无需 Key）」—— **默认关闭**，必须用户显式打开。
  ///
  /// 为什么默认关闭、且界面上要写清风险：这条通道是把请求**伪装成官方 CLI** 去用
  /// OpenCode 的匿名免费额度（上游明确只允许自家客户端用）。它随时可能失效，
  /// 也不该被当成"本 App 保证提供的免费服务"。详见 `local/zen_proxy.dart` 顶部说明。
  ///
  /// ⚠️ 但它**不用写 Key**：上游凭据是公开的字面量 `public`（本地代理自己带），
  /// 所以任何"去填一个 Key"的提示都是错的（2026-10-11 用户纠正）。
  static const String _kZenEnabled = 'dsh_zen_free_channel';

  /// 「免费模型（无需 Key）」= Pollinations 那条（见 `data/polli_channel.dart`）。
  ///
  /// ⚠️ 它和 [_kZenEnabled] 的默认值**刻意相反**：用户对外的承诺是
  /// 「**不需要填写 Key**」（2026-10-15 原话：「主要就是以前承诺过不需要填写 key」），
  /// 所以这条**默认开着** —— 装完就能聊，而不是让用户去设置里找一个开关。
  /// Zen 那条（灰色、且 2026-10-13/14 起基本已死）仍然默认关着。
  static const String _kPolliEnabled = 'dsh_polli_free_channel';

  /// 「会话里能联网搜索」（AnySearch，2026-10-15 用户选定 B 方案）。
  ///
  /// 默认**开**：匿名层可用（用户什么都不用填），这和"不用填 Key 就能用"是同一条口径。
  /// 关掉就是"会话不带联网搜索工具"。
  static const String _kAnysearchEnabled = 'dsh_anysearch_enabled';

  /// 「左右滑动切换页面」（默认**开**）。
  ///
  /// 关掉之后壳层不接横向拖动 —— 只点底部标签切页。用户 2026-10-20 反馈：
  /// 在 Bot 页上太容易误触到别的页签（网页里本来就有自己的横滑/滚动）。
  static const String _kSwipeSwitch = 'dsh_swipe_switch';

  /// 「会话里提供子智能体工具」（出厂是提供的）。
  ///
  /// 关掉 = overlay 里把这几个 id 覆盖成 `disabled: true`（见
  /// `data/session_capabilities.dart`），**下一个会话进程**才生效。
  static const String _kSubagentEnabled = 'dsh_subagent_enabled';
  static const String _kPhoneAgentEnabled = 'dsh_phone_agent_enabled';

  /// 子会话用哪个模型（`provider/model` 路由串）。空 = 跟随父会话。
  static const String _kSubagentRoute = 'dsh_subagent_route';

  /// 「正在取图」的时间戳（epoch ms，空 = 没有）。
  ///
  /// 为什么需要它：取图会离开 App（相机/相册是系统页面），回来的路上 App 可能被
  /// 系统重建。重建后如果发现"刚才正在取图"，AppShell 会把「本地对话」页**重新推回来**
  /// —— 这样用户拍完照回来还在聊天页，而不是掉回首页。
  static const String _kPickInFlight = 'dsh_pick_in_flight';

  /// 「刚才从哪一页去取图」（见 [_pickInFlightFrom]）。
  ///
  /// ⚠️ **为什么必须记这一页**（用户 2026-10-12 报的第 1 条后半句：
  ///    「退出去选其他服务有的时候会跳转到本地会话这个页面」）：
  ///    以前只记了时间戳，AppShell 重建后**一律**把「本地对话」推回来 ——
  ///    于是**在影视页选一张参考图**，回来也会被推去本地对话。
  ///    记下出发页，才能"从哪来回哪去"。
  static const String _kPickInFlightFrom = 'dsh_pick_in_flight_from';

  /// 「检查更新」用**用户自填的**更新源地址（空 = 用内置那两条）。
  ///
  /// 为什么要能自填：国内直连 GitHub 时好时坏，用户手上有能通的镜像时，
  /// 让他自己填一个比我们猜哪个站可用靠谱得多。见 `local/update_source.dart`。
  /// 「外观 → 壁纸」：本机图片的**绝对路径**（空 = 不用壁纸）。
  ///
  /// 用户 2026-10-15 第 5 条：「外观那里建议加上一个壁纸，用户可以上传壁纸。」
  ///
  /// ⚠️ 存的是**拷进 App 私有目录之后**的路径，不是用户相册里那张的原始 URI：
  /// 相册里的图随时可能被用户删掉/移动，那时背景会突然变空。见设置页的
  /// `_pickWallpaper`（选完立刻复制一份到 `<filesDir>/wallpaper/`）。
  static const String _kWallpaperPath = 'dsh_wallpaper_path';

  /// 壁纸压暗强度（0~0.95）。**默认 0.55** —— 见 `DshGridBackground.wallpaperDim`：
  /// 正文对比度必须由我们兜住，不能由用户那张图决定。
  static const String _kWallpaperDim = 'dsh_wallpaper_dim';

  /// 壁纸模糊半径（dp，0 = 不模糊）。默认 6：让图"退到后面去"。
  static const String _kWallpaperBlur = 'dsh_wallpaper_blur';

  static const String _kUpdateSource = 'dsh_update_source';

  /// 启动后要不要**自动查一次**更新（默认开、失败静默）。
  ///
  /// 默认开是因为"有新版本却没人知道"是这类侧载 App 最大的问题；但它必须能关 ——
  /// 有人就是不想让 App 一开机就联网，这个开关要尊重。
  static const String _kUpdateAutoCheck = 'dsh_update_auto_check';

  /// 用户点了「跳过这个版本」的那个版本号（空 = 没跳过任何版本）。
  ///
  /// 存的是**版本号字符串**而不是布尔：跳过 0.75 之后，出了 0.76 还要能提示他。
  static const String _kUpdateSkippedVersion = 'dsh_update_skipped_version';

  /// 上次检查更新的时间（epoch ms，0 = 从没查过）。
  static const String _kUpdateLastCheckMs = 'dsh_update_last_check_ms';

  /// 本地推理后端的合法 id（与 `LocalModelBackend.name` 对齐）。
  /// **NPU 已按用户口径取消**（2026-10-08），所以只剩两个。
  static const Set<String> kLocalBackendIds = <String>{'cpu', 'vulkan'};

  /// 上下文档位：与模型页给的按钮一致。不认识的一律退回 [localContextSize] 默认。
  static const List<int> kLocalContextSizes = <int>[8192, 16384, 32768];

  /// 默认皮肤。**刻意保持深色**：设计稿 11 页都是深色，直接给老用户换成浅色
  /// 是一次没被要求的观感突变；浅色在设置里一键可得。
  static const String kDefaultSkin = 'dark';

  /// 「自定义」按钮的文案与如实说明（占位，不是假开关）。
  ///
  /// ⚠️ 这两个常量现在是**中文原文（i18n 的 key）**，不是最终显示文案：
  /// 渲染处一律再包一层 `context.tr(...)`（见 `settings_tab.dart`）。
  /// 这么写是为了保住 `const` —— 常量表是编译期的，塞不进运行时查表。
  static String get customLabel => tr('自定义');
  static String get customPendingNote =>
      tr('自定义配色还没做。现在有「浅色 / 深色 / 像素」三套皮肤，点「自定义」不会切主题 —— 也不会把主题切到一个不存在的状态。');

  double _textScale = 1.0;

  /// 生图/生视频是否走本机（见 [_kImageLocal]）。
  /// 「社区免费通道」是否开启（见 [_kZenEnabled]）。
  bool _zenEnabled = false;

  /// 「免费模型（无需 Key）」是否开启（见 [_kPolliEnabled]）。**默认开**。
  bool _polliEnabled = true;

  /// 「会话里能联网搜索」是否开启（见 [_kAnysearchEnabled]）。**默认开**。
  bool _anysearchEnabled = true;

  /// 「会话里提供子智能体工具」是否开启（见 [_kSubagentEnabled]）。**默认开**。
  bool _subagentEnabled = true;

  /// 「屏幕助手」（Agent 操作手机界面）总开关，见 [_kPhoneAgentEnabled]。
  /// 这是安全闸 —— 关了之后桥虽还在（App 启动即拉起），但 Node 侧读
  /// phone-agent.json 时会看到 enabled:false，各技能据此拒调。
  bool _phoneAgentEnabled = false;
  bool get phoneAgentEnabled => _phoneAgentEnabled;

  /// 左右滑动切换页面（见 [_kSwipeSwitch]）。**默认开**。
  bool _swipeSwitch = true;

  /// 子会话用的模型路由（`provider/model`）；null/空 = 跟随父会话。
  String? _subagentRoute;
  String _skinId = kDefaultSkin;

  /// 「外观 → 壁纸」当前状态（见 [_kWallpaperPath] 那一组常量）。
  String _wallpaperPath = '';
  double _wallpaperDim = 0.55;
  double _wallpaperBlur = 6;
  AppLanguage _language = AppLanguage.fallback;

  /// 本地推理后端 id（`cpu` / `vulkan`）。默认 CPU —— 理由见模型页里那段注释
  /// （Adreno 840 上 Vulkan 长对话段错误，稳字优先）。
  String _localBackendId = 'cpu';

  /// 本地模型上下文档位。默认 16384：DSH 每轮固定开销就约 3k~7k tokens，
  /// 8k 会一进会话就见底（见模型页的档位注释）。
  int _localContextSize = 16384;

  /// 联网搜索厂家 id。
  ///
  /// **默认 `bing`（免费・不用 Key）**：用户 2026-10-09 明确要求"两个免费源直接内置"
  /// —— 意思是打开 🔍 就能用，不该先逼人去申请 Key。Bing 在国内更容易访问，
  /// 所以它是默认；DuckDuckGo 作为备选，付费那几家留给"要更稳"的人。
  String _searchProviderId = 'bing';

  /// 上次停在哪一页（见 [_kLastTab]）。
  int _lastTab = 0;

  /// 「正在取图」的时间戳（见 [_kPickInFlight]）；null = 没有。
  DateTime? _pickInFlightAt;

  /// 「刚才从哪一页去取图」：`media`（影视）/ `localchat`（本地对话）/ ''（没有）。
  String _pickInFlightFrom = '';

  /// 口播/短剧**配音**用哪家（`system` / `mimo` / `minimax`）。
  ///
  /// 为什么要落盘：用户 2026-10-12 要求把配音做好，而配音来源/音色/语速
  /// 原来是影视页 State 里的临时变量 —— 一离开页面就回默认，
  /// 每次生成口播都得重挑一遍（与 [_kLocalBackend] 当初的问题同源）。
  static const String _kTtsSource = 'dsh_tts_source';
  static const String _kTtsVoices = 'dsh_tts_voices';
  static const String _kTtsSpeed = 'dsh_tts_speed';

  /// 允许的配音来源 id（与 `TtsSource.name` 对齐）。**这里刻意不 import
  /// `data/tts.dart`** —— 设置层是底层，不该被数据层反向依赖。
  static const Set<String> kTtsSourceIds = <String>{
    'system',
    'mimo',
    'minimax',
    // 本机离线配音（2026-10-13）：零 Key、离线。
    'local',
  };

  String _ttsSourceId = 'system';

  /// 每家各自的音色选择（`{'mimo': '冰糖', 'minimax': 'male-qn-qingse'}`）。
  ///
  /// 按家分开存：换一家再换回来，上次挑的音色还在（否则用户会以为"白挑了"）。
  /// 只存**音色 id 字符串**，不存音色表 —— 表是供应商那边的，随时可能变。
  Map<String, String> _ttsVoiceBySource = <String, String>{};

  /// 语速倍率（1.0 = 原速）。
  double _ttsSpeed = 1.0;

  /// 「思考过程」怎么显示（`dsh_thinking_mode`）。
  ///
  /// 为什么要有这一项（用户 2026-10-12：「目前手机版的思考过程都是英文的，
  /// 这个怎么回避」）：**思考用哪种语言是模型训练出来的倾向** —— 我们只能
  /// 「提高中文概率」（写进 AGENTS.md 受管区块），**不能保证**。
  /// 所以真正能"彻底不看到英文思考"的办法只有一个：**不显示它**。
  /// 这一项就是那个开关；默认「折叠」（能看、但默认收起，不抢版面）。
  static const String _kThinkingMode = 'dsh_thinking_mode';

  /// 允许的取值（与 [kThinkingModes] 的 id 一一对应）。
  ///
  /// ⚠️ 名字是**落盘字面量**：改了它 = 老用户的选择静默失效（退回默认折叠）。
  static const Set<String> kThinkingModeIds = <String>{
    'collapsed',
    'expanded',
    'hidden',
  };

  String _thinkingModeId = 'collapsed';

  /// 「检查更新」：用户自填的更新源（空串 = 用内置那两条，见 [_kUpdateSource]）。
  String _updateSource = '';

  /// 启动后自动查一次更新（默认开；见 [_kUpdateAutoCheck]）。
  bool _updateAutoCheck = true;

  /// 用户点过「跳过这个版本」的版本号（空串 = 没跳过任何版本）。
  String _updateSkippedVersion = '';

  /// 上次检查更新的时间；null = 从没查过。
  DateTime? _updateLastCheckAt;

  /// **本进程内**最后一次检查更新的结果。刻意**不落盘**。
  ///
  /// 为什么需要它：启动后那次自动检查是在 `main.dart` 的 shell 层跑的，
  /// 而界面在设置页里 —— 没有一个中转的地方，自动查到的结果就只能进日志，
  /// "自动检查"这个开关就等于白开。设置页建起来时读这个值，用户一进去
  /// 就能看到有没有新版，不必自己再点一次。
  ///
  /// 为什么不落盘：它描述的是"此刻远端是什么版本"，跨启动会过期；
  /// 而且启动时本来就会重查（除非用户关了自动检查，那时他会手动点）。
  UpdateCheckResult? _lastUpdateResult;

  bool _loaded = false;

  /// 全局字号缩放（1.0 = 设计稿原尺寸）
  double get textScale => _textScale;

  /// 生图/生视频走本机吗。
  /// 「社区免费通道（OpenCode Zen）」是否开启（默认 false）。
  bool get zenEnabled => _zenEnabled;

  /// 「免费模型（无需 Key）」（Pollinations）是否开启 —— **默认 true**，见 [_kPolliEnabled]。
  bool get polliEnabled => _polliEnabled;

  /// 「会话里能联网搜索」（AnySearch）是否开启 —— **默认 true**，见 [_kAnysearchEnabled]。
  bool get anysearchEnabled => _anysearchEnabled;

  /// 「会话里提供子智能体工具」是否开启 —— **默认 true**，见 [_kSubagentEnabled]。
  bool get subagentEnabled => _subagentEnabled;

  /// 左右滑动切换页面是否开启 —— **默认 true**，见 [_kSwipeSwitch]。
  bool get swipeSwitch => _swipeSwitch;

  /// 子会话用的模型路由（`provider/model`）；空 = 跟随父会话。
  String? get subagentRoute => _subagentRoute;

  /// 拆成 (provider, model) 给 overlay 用；跟随父会话时返回 (null, null)。
  (String?, String?) get subagentRouteParts {
    final r = (_subagentRoute ?? '').trim();
    final i = r.indexOf('/');
    if (r.isEmpty || i <= 0 || i == r.length - 1) return (null, null);
    return (r.substring(0, i), r.substring(i + 1));
  }

  bool get loaded => _loaded;

  /// 当前皮肤 id（`light` / `dark`）。
  String get skinId => _skinId;

  /// 当前皮肤（色值全在 [DshPalette] 里）。
  DshPalette get skin => DshPalettes.byId(_skinId);

  /// 当前界面语言。只影响 **App 自己画的界面**，不影响电脑端回传的内容
  /// （这条边界写在 [AppLanguage] 的文档里，设置页也会如实告诉用户）。
  AppLanguage get language => _language;

  /// 本地推理后端 id（`cpu` / `vulkan`）。**只影响下次启动本地服务**。
  String get localBackendId => _localBackendId;

  /// 本地模型上下文档位（8192 / 16384 / 32768）。**只影响下次启动本地服务**。
  int get localContextSize => _localContextSize;

  /// 联网搜索厂家 id（见 [_kSearchProvider]）。
  String get searchProviderId => _searchProviderId;

  /// 口播/短剧的配音来源 id（`system` / `mimo` / `minimax`）。
  String get ttsSourceId => _ttsSourceId;

  /// 某一家上次选的音色 id；没选过 = 空串（渲染处按该家默认兜底）。
  String ttsVoiceFor(String sourceId) => _ttsVoiceBySource[sourceId] ?? '';

  /// 配音语速倍率（1.0 = 原速）。
  double get ttsSpeed => _ttsSpeed;

  /// 「思考过程」显示方式 id（`collapsed` / `expanded` / `hidden`）。
  String get thinkingModeId => _thinkingModeId;

  /// 用户自填的更新源地址；空串 = 用内置那两条（见 `local/update_source.dart`）。
  String get updateSource => _updateSource;

  /// 启动后是否自动查一次更新。
  bool get updateAutoCheck => _updateAutoCheck;

  /// 用户跳过的那一版（空串 = 没跳过任何版本）。
  ///
  /// 界面上的判据是「远端版本 == 这一版」时才不提示 —— 所以跳过 0.75 之后，
  /// 0.76 出来照样会提示他。
  String get updateSkippedVersion => _updateSkippedVersion;

  /// 上次检查更新的时间；null = 从没查过（界面就不显示这一行，而不是显示"从未"）。
  DateTime? get updateLastCheckAt => _updateLastCheckAt;

  /// 本进程内最后一次检查更新的结果（见 [_lastUpdateResult]）。
  UpdateCheckResult? get lastUpdateResult => _lastUpdateResult;

  /// 首页那条滚动公告（来自仓库里的 `notice.json`）。
  ///
  /// 为什么不落盘：它描述的是"远端现在挂着什么"，跨启动会过期；落盘那份在
  /// `notice_cache.json` 里（离线兜底用，见 local/broadcast_feed.dart），
  /// 启动时会先读缓存再拉新的 —— 于是这个字段永远只代表**当前显示的这份**。
  BroadcastFeed? _broadcastFeed;

  /// 当前要显示的公告（可能来自缓存、可能来自刚拉到的；没有就是 null → 首页不画那一条）。
  BroadcastFeed? get broadcastFeed => _broadcastFeed;

  /// 换一份公告（传 null = 清掉）。
  void setBroadcastFeed(BroadcastFeed? feed) {
    _broadcastFeed = feed;
    notifyListeners();
  }

  /// 存下"刚查过"的结果（内存 + 通知界面）。
  ///
  /// 传 null = 清掉（界面上就回到"还没查过"）。
  void setLastUpdateResult(UpdateCheckResult? r) {
    _lastUpdateResult = r;
    notifyListeners();
  }

  /// 三档的文案与依据。
  ///
  /// ⚠️ `label` / `note` 是**中文原文（i18n key）**，渲染处包 `context.tr`。
  /// `note` 里那句"唯一能彻底不看到英文思考的办法"是**如实说明**，
  /// 不是营销话：中文思考只能提高概率（写进 AGENTS.md），不能保证。
  static List<({String id, String label, String note})> get kThinkingModes =>
      <({String id, String label, String note})>[
        (id: 'collapsed', label: tr('折叠'), note: tr('默认收起，想看点一下')),
        (id: 'expanded', label: tr('展开'), note: tr('全文铺开，思考很长时会占版面')),
        (
          id: 'hidden',
          label: tr('不显示'),
          note: tr('完全不渲染 —— 唯一能彻底不看到英文思考的办法')
        ),
      ];

  /// 允许被打开的应用包名（只读视图）。
  /// 上次停在哪一页。
  int get lastTab => _lastTab;

  /// 刚才是不是在取图、且离现在不超过 [within]（默认 3 分钟）。
  bool pickInFlightWithin([Duration within = const Duration(minutes: 3)]) {
    final at = _pickInFlightAt;
    if (at == null) return false;
    return DateTime.now().difference(at) <= within;
  }

  /// 刚才**从哪一页**去取图、且离现在不超过 [within]。
  ///
  /// 返回 `'media'` / `'localchat'` / `''`（没有在取图）。
  /// AppShell 重建后据此**从哪来回哪去** —— 在影视页选图就不该被推去本地对话
  ///（用户 2026-10-12：「退出去选其他服务有的时候会跳转到本地会话这个页面」）。
  String pickInFlightFromWithin([Duration within = const Duration(minutes: 3)]) {
    if (!pickInFlightWithin(within)) return '';
    return _pickInFlightFrom;
  }

  /// 壁纸图片的绝对路径（空 = 没用壁纸）。**能不能用**由背景层再判一次
  /// （文件可能被清理工具删了），这里不做 IO。
  String get wallpaperPath => _wallpaperPath;

  /// 有没有设置壁纸（只看是否设过路径，不看文件在不在）。
  bool get hasWallpaper => _wallpaperPath.trim().isNotEmpty;

  /// 壁纸压暗强度 0~0.95（默认 0.55）。
  double get wallpaperDim => _wallpaperDim;

  /// 壁纸模糊半径 dp（默认 6，0 = 不模糊）。
  double get wallpaperBlur => _wallpaperBlur;

  /// 给 `MaterialApp.themeMode` 用的等价表达（现在只喂一份 theme，留着更直观）。
  ThemeMode get themeMode => skin.isLight ? ThemeMode.light : ThemeMode.dark;

  /// 字号档位。设计稿正文 14dp 按 1.0 算。
  ///
  /// ⚠️ `label` / `note` 同样是**中文原文（i18n key）**，渲染处包 `context.tr`。
  static List<({double scale, String label, String note})> get kTextScales =>
      <({double scale, String label, String note})>[
        (scale: 0.90, label: tr('小'), note: tr('一屏能看更多内容')),
        (scale: 1.00, label: tr('标准'), note: tr('与设计稿一致')),
        (scale: 1.15, label: tr('大'), note: tr('更省眼力')),
        (scale: 1.30, label: tr('特大'), note: tr('适合老花/小屏')),
      ];

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getDouble(_kTextScale);
      if (stored != null && stored > 0.5 && stored < 2.0) {
        _textScale = stored;
      }
      final skin = prefs.getString(_kSkin);
      // 只认真实存在的皮肤 id：老版本没有这个键、或磁盘上写了个不认识的值，
      // 都退回默认深色，绝不把主题留在一个"空"的状态上。
      if (skin != null && DshPalettes.all.any((p) => p.id == skin)) {
        _skinId = skin;
      }
      // 语言同理：磁盘上是个不认识的 id 就退回默认中文（[AppLanguage.byId] 兜底），
      // 不让界面停在一个"没有语言"的状态上。
      _language = AppLanguage.byId(prefs.getString(_kLanguage));
      _zenEnabled = prefs.getBool(_kZenEnabled) ?? false;
      // 默认 **true**：装完就能聊（"不用填 Key"这句承诺的实现）。
      // 用户主动关掉过就尊重他存下来的值。
      _polliEnabled = prefs.getBool(_kPolliEnabled) ?? true;
      // 同上：默认开（匿名可用，不用填任何东西）。
      _anysearchEnabled = prefs.getBool(_kAnysearchEnabled) ?? true;
      _swipeSwitch = prefs.getBool(_kSwipeSwitch) ?? true;
      // 出厂就是提供子智能体的，所以默认 true。
      _subagentEnabled = prefs.getBool(_kSubagentEnabled) ?? true;
      _phoneAgentEnabled = prefs.getBool(_kPhoneAgentEnabled) ?? false;
      final sub = prefs.getString(_kSubagentRoute);
      _subagentRoute = (sub == null || sub.trim().isEmpty) ? null : sub.trim();
      // 本地模型那两项：只认白名单里的值，磁盘上有脏值就退回默认
      // （绝不把后端留在一个"不认识"的状态上）。
      final lb = prefs.getString(_kLocalBackend);
      if (lb != null && kLocalBackendIds.contains(lb)) _localBackendId = lb;
      final lc = prefs.getInt(_kLocalContext);
      if (lc != null && kLocalContextSizes.contains(lc)) _localContextSize = lc;
      _searchProviderId = prefs.getString(_kSearchProvider) ?? 'bing';
      _lastTab = prefs.getInt(_kLastTab) ?? 0;
      final pickAt = prefs.getInt(_kPickInFlight) ?? 0;
      _pickInFlightAt = pickAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(pickAt)
          : null;
      _pickInFlightFrom = prefs.getString(_kPickInFlightFrom) ?? '';
      // 壁纸：路径直接读（图在不在由背景层自己判断 —— 文件被清了就退回无壁纸，
      // 不要把设置清空，用户重新放一张同名图还能用）。两个数值夹在合法区间。
      _wallpaperPath = (prefs.getString(_kWallpaperPath) ?? '').trim();
      _wallpaperDim = (prefs.getDouble(_kWallpaperDim) ?? 0.55).clamp(0.0, 0.95);
      _wallpaperBlur = (prefs.getDouble(_kWallpaperBlur) ?? 6).clamp(0.0, 30.0);
      // 配音三项：来源只认白名单（磁盘上有脏值就退回系统配音）；
      // 音色表只认"字典里的字符串键值"，坏 JSON 就当没存过 —— 绝不把界面
      // 停在一个"不认识"的音色上。
      final ttsSrc = prefs.getString(_kTtsSource);
      if (ttsSrc != null && kTtsSourceIds.contains(ttsSrc)) _ttsSourceId = ttsSrc;
      final ttsSpeed = prefs.getDouble(_kTtsSpeed);
      if (ttsSpeed != null && ttsSpeed >= 0.5 && ttsSpeed <= 2.0) {
        _ttsSpeed = ttsSpeed;
      }
      final ttsVoices = prefs.getString(_kTtsVoices);
      if (ttsVoices != null && ttsVoices.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(ttsVoices);
          if (decoded is Map) {
            _ttsVoiceBySource = <String, String>{
              for (final e in decoded.entries)
                if (e.key is String && e.value is String)
                  e.key as String: (e.value as String).trim(),
            };
          }
        } catch (e) {
          debugPrint('[dsh-app-settings] 配音音色表读不出来，按没存过处理：$e');
        }
      }
      // 同步给「进程环境 / 配置指纹」读的那个静态镜像（见 LocalImageServer.localPreferred）。
      // 「思考过程」：只认白名单（磁盘上有脏值就退回默认「折叠」）。
      final think = prefs.getString(_kThinkingMode);
      if (think != null && kThinkingModeIds.contains(think)) {
        _thinkingModeId = think;
      }
      // 「检查更新」四项。自填的源只收"看起来像个 http(s) 地址"的值 ——
      // 磁盘上写了半截地址的话，宁可退回内置源，也别让用户对着一个必然失败的
      // 源点半天"检查更新"还不知道为什么。
      final upSrc = (prefs.getString(_kUpdateSource) ?? '').trim();
      _updateSource = looksLikeUpdateSource(upSrc) ? upSrc : '';
      _updateAutoCheck = prefs.getBool(_kUpdateAutoCheck) ?? true;
      _updateSkippedVersion =
          (prefs.getString(_kUpdateSkippedVersion) ?? '').trim();
      final upAt = prefs.getInt(_kUpdateLastCheckMs) ?? 0;
      _updateLastCheckAt =
          upAt > 0 ? DateTime.fromMillisecondsSinceEpoch(upAt) : null;
    } catch (e) {
      debugPrint('[dsh-app-settings] load failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 「外观 → 壁纸」：设成某张本机图片（**已经在 App 私有目录里的**绝对路径），
  /// 传空串 = 不要壁纸。
  Future<void> setWallpaper(String path) async {
    final p = path.trim();
    if (p == _wallpaperPath) return;
    _wallpaperPath = p;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kWallpaperPath, p);
      debugPrint('[dsh-app-settings] 壁纸 = ${p.isEmpty ? "（无）" : p}');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 壁纸压暗强度（0~0.95）。这一项直接决定"图上的字看不看得清"，所以夹死区间。
  Future<void> setWallpaperDim(double v) async {
    final next = v.clamp(0.0, 0.95).toDouble();
    if (next == _wallpaperDim) return;
    _wallpaperDim = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kWallpaperDim, next);
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 壁纸模糊半径（dp，0~30）。
  Future<void> setWallpaperBlur(double v) async {
    final next = v.clamp(0.0, 30.0).toDouble();
    if (next == _wallpaperBlur) return;
    _wallpaperBlur = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kWallpaperBlur, next);
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 切换界面语言。落盘；落盘失败只影响"下次启动记不记得"，本次切换照常生效
  /// （与皮肤、字号的处理一致）。
  Future<void> setLanguage(AppLanguage language) async {
    if (language == _language) return;
    _language = language;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLanguage, language.id);
      debugPrint('[dsh-app-settings] 语言 = ${language.id}（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 切换皮肤。传进来的 id 必须是真实皮肤，否则忽略（不写坏值）。
  Future<void> setSkin(String id) async {
    if (!DshPalettes.all.any((p) => p.id == id)) {
      debugPrint('[dsh-app-settings] 忽略不存在的皮肤 id：$id');
      return;
    }
    if (id == _skinId) return;
    _skinId = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSkin, id);
      debugPrint('[dsh-app-settings] 主题 = $id（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 开/关「会话里提供子智能体工具」。
  ///
  /// ⚠️ 与联网搜索一样，**下一个会话进程**才生效（overlay 在进程启动时读）。
  Future<void> setSubagentEnabled(bool v) async {
    if (v == _subagentEnabled) return;
    _subagentEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSubagentEnabled, v);
      debugPrint('[dsh-app-settings] 子智能体 = $v');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 指定子会话用哪个模型（`provider/model`）；传空 = 跟随父会话。
  Future<void> setSubagentRoute(String? route) async {
    final v = (route ?? '').trim();
    final next = v.isEmpty ? null : v;
    if (next == _subagentRoute) return;
    _subagentRoute = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (next == null) {
        await prefs.remove(_kSubagentRoute);
      } else {
        await prefs.setString(_kSubagentRoute, next);
      }
      debugPrint('[dsh-app-settings] 子智能体模型 = ${next ?? "（跟随会话）"}');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 开/关「会话里能联网搜索」（AnySearch）。
  ///
  /// ⚠️ 真正的生效点是**下一个会话进程**（`session/new` 时才把 mcpServers 发过去），
  /// 与模型/皮肤那类"立刻生效"的设置不同 —— 界面上的说明要如实写。
  /// 开关「左右滑动切换页面」。
  Future<void> setSwipeSwitch(bool v) async {
    if (v == _swipeSwitch) return;
    _swipeSwitch = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSwipeSwitch, v);
    } catch (e) {
      debugPrint('[dsh-settings] 保存滑动开关失败：$e');
    }
  }

  /// 「屏幕助手」总开关（见 [_phoneAgentEnabled]）。
  Future<void> setPhoneAgentEnabled(bool v) async {
    if (v == _phoneAgentEnabled) return;
    _phoneAgentEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPhoneAgentEnabled, v);
    } catch (e) {
      debugPrint('[dsh-settings] 保存屏幕助手开关失败：$e');
    }
  }

  Future<void> setAnysearchEnabled(bool v) async {
    if (v == _anysearchEnabled) return;
    _anysearchEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAnysearchEnabled, v);
      debugPrint('[dsh-app-settings] 会话联网搜索 = $v');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 开/关「免费模型（无需 Key）」（Pollinations）。
  ///
  /// ⚠️ 与 zen 那条一样：真正的启停（往模型配置里加/删模型）由调用方负责 ——
  /// 见 `data/polli_channel.dart`。这里只记住用户的选择。
  Future<void> setPolliEnabled(bool v) async {
    if (v == _polliEnabled) return;
    _polliEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPolliEnabled, v);
      debugPrint('[dsh-app-settings] 免 Key 免费通道 = $v');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 开/关「社区免费通道（实验性）」。
  ///
  /// ⚠️ 真正的启停（起代理、往模型配置里加/删那批免费模型）由调用方负责 ——
  /// 见 `data/zen_channel.dart`。这里只记住用户的选择。
  Future<void> setZenEnabled(bool v) async {
    if (v == _zenEnabled) return;
    _zenEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kZenEnabled, v);
      debugPrint('[dsh-app-settings] 社区免费通道 = $v');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 记住本地推理后端。**只影响下次启动本地服务**（正在跑的服务不受影响，
  /// 所以模型页在服务运行中会把按钮置灰）。
  Future<void> setLocalBackend(String id) async {
    if (!kLocalBackendIds.contains(id)) {
      debugPrint('[dsh-app-settings] 忽略不认识的推理后端 id：$id');
      return;
    }
    if (id == _localBackendId) return;
    _localBackendId = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLocalBackend, id);
      debugPrint('[dsh-app-settings] 本地推理后端 = $id（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 记住本地模型上下文档位。**只影响下次启动本地服务**。
  Future<void> setLocalContextSize(int size) async {
    if (!kLocalContextSizes.contains(size)) {
      debugPrint('[dsh-app-settings] 忽略不支持的上下文档位：$size');
      return;
    }
    if (size == _localContextSize) return;
    _localContextSize = size;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLocalContext, size);
      debugPrint('[dsh-app-settings] 本地上下文 = $size（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// `lastTab` 是不是**本次进程**里被改过的。
  ///
  /// 用户 2026-10-11 口径：「安装以后打开的页面是影视页面，正常应该打开首页」——
  /// `lastTab` 是**跨启动持久化**的，于是覆盖安装/重启后会落回上次那一页（例如影视）。
  /// 现在：**冷启动（进程新建）一律回首页**；只有**同进程内**的页面重建
  /// （Activity 被系统重建、从相机/相册回来）才恢复 —— 那正是这个机制原本的理由。
  static bool _tabTouchedInThisProcess = false;

  /// 现在可不可以拿 [lastTab] 去恢复页面（见 [_tabTouchedInThisProcess]）。
  static bool get lastTabRestorable => _tabTouchedInThisProcess;

  /// 记住上次停在哪一页。
  Future<void> setLastTab(int index) async {
    if (index == _lastTab) return;
    _lastTab = index;
    _tabTouchedInThisProcess = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastTab, index);
    } catch (_) {}
  }

  /// 标记「开始取图 / 取图结束」。
  ///
  /// 取图期间 App 会离开前台（相机/相册是系统页面），回来的路上可能被系统重建 ——
  /// 落这个时间戳，重建后 AppShell 才能判断"该把哪一页推回来"。
  Future<void> setPickInFlight(bool inFlight, {String from = ''}) async {
    _pickInFlightAt = inFlight ? DateTime.now() : null;
    // 清除时把出发页一起清掉 —— 否则下一次"没有取图"却还留着上一页的名字。
    _pickInFlightFrom = inFlight ? from : '';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kPickInFlight,
          inFlight ? DateTime.now().millisecondsSinceEpoch : 0);
      await prefs.setString(_kPickInFlightFrom, _pickInFlightFrom);
    } catch (_) {}
  }

  /// 记住联网搜索用哪家。
  Future<void> setSearchProvider(String id) async {
    if (id == _searchProviderId) return;
    _searchProviderId = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSearchProvider, id);
      debugPrint('[dsh-app-settings] 联网搜索 = $id（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 记住口播/短剧的配音来源。只认 [kTtsSourceIds] 里的值，不写坏数据。
  Future<void> setTtsSource(String id) async {
    if (!kTtsSourceIds.contains(id)) {
      debugPrint('[dsh-app-settings] 忽略不认识的配音来源 id：$id');
      return;
    }
    if (id == _ttsSourceId) return;
    _ttsSourceId = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTtsSource, id);
      debugPrint('[dsh-app-settings] 配音来源 = $id（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 记住某一家选的音色 id（空串 = 回到该家默认音色）。
  Future<void> setTtsVoice(String sourceId, String voiceId) async {
    if (!kTtsSourceIds.contains(sourceId)) return;
    final v = voiceId.trim();
    if (v.isEmpty) {
      _ttsVoiceBySource.remove(sourceId);
    } else {
      if (_ttsVoiceBySource[sourceId] == v) return;
      _ttsVoiceBySource = <String, String>{..._ttsVoiceBySource, sourceId: v};
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTtsVoices, jsonEncode(_ttsVoiceBySource));
      debugPrint('[dsh-app-settings] 配音音色($sourceId) = $v（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 记住配音语速倍率。超出 0.5~2.0 的一律忽略（不写坏值）。
  /// 记住「思考过程」的显示方式。只认 [kThinkingModeIds] 里的值。
  ///
  /// 为什么它不是一个"纯界面开关"：它决定**要不要把模型吐出来的思考文本渲染到屏幕上**，
  /// 而思考的语言不可控（见 [_kThinkingMode] 的说明）—— 所以"不显示"是唯一的硬保证。
  Future<void> setThinkingMode(String id) async {
    if (!kThinkingModeIds.contains(id)) {
      debugPrint('[dsh-app-settings] 忽略不认识的思考显示方式：$id');
      return;
    }
    if (id == _thinkingModeId) return;
    _thinkingModeId = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThinkingMode, id);
      debugPrint('[dsh-app-settings] 思考过程 = $id（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  Future<void> setTtsSpeed(double speed) async {
    if (speed < 0.5 || speed > 2.0) {
      debugPrint('[dsh-app-settings] 忽略越界的语速：$speed');
      return;
    }
    if (speed == _ttsSpeed) return;
    _ttsSpeed = speed;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kTtsSpeed, speed);
      debugPrint('[dsh-app-settings] 配音语速 = $speed（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────── 检查更新（L1）

  /// 记住用户自填的更新源。传空串 = 恢复内置源。
  ///
  /// 非空但不长得像 http(s) 地址时**直接忽略**（保持原值），只写一条日志：
  /// 界面上那个输入框旁边本来就会提示"要填完整地址"，这里做二次把关是为了
  /// 防住"存进去一个必然失败的地址、下次启动还在用它"。
  Future<void> setUpdateSource(String raw) async {
    final v = raw.trim();
    if (v.isNotEmpty && !looksLikeUpdateSource(v)) {
      debugPrint('[dsh-app-settings] 忽略不像更新源的地址：$v');
      return;
    }
    if (v == _updateSource) return;
    _updateSource = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUpdateSource, v);
      debugPrint('[dsh-app-settings] 更新源 = ${v.isEmpty ? '(内置)' : v}（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 开/关"启动后自动查一次更新"。
  Future<void> setUpdateAutoCheck(bool v) async {
    if (v == _updateAutoCheck) return;
    _updateAutoCheck = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kUpdateAutoCheck, v);
      debugPrint('[dsh-app-settings] 自动检查更新 = $v（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 记下"用户跳过了这一版"（传空串 = 取消跳过）。
  Future<void> setUpdateSkippedVersion(String version) async {
    final v = version.trim();
    if (v == _updateSkippedVersion) return;
    _updateSkippedVersion = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUpdateSkippedVersion, v);
      debugPrint('[dsh-app-settings] 跳过版本 = ${v.isEmpty ? '(清空)' : v}（已落盘）');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 记一次"刚查过更新"的时间戳。
  ///
  /// ⚠️ 检查**成败都记**：界面那行"上次检查：刚刚"说的是"什么时候试过"，
  /// 不是"什么时候成功过" —— 把失败的尝试藏起来会让用户以为 App 没在查。
  Future<void> noteUpdateChecked([DateTime? at]) async {
    final when = at ?? DateTime.now();
    _updateLastCheckAt = when;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kUpdateLastCheckMs, when.millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  Future<void> setTextScale(double scale) async {
    if (scale == _textScale) return;
    _textScale = scale;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kTextScale, scale);
      debugPrint('[dsh-app-settings] 字号 = $scale');
    } catch (e) {
      debugPrint('[dsh-app-settings] persist failed: $e');
    }
  }

  /// 当前档位的显示名（找不到就按数值显示）。
  String get textScaleLabel {
    for (final o in kTextScales) {
      if ((o.scale - _textScale).abs() < 0.001) return o.label;
    }
    return '${(_textScale * 100).round()}%';
  }
}
