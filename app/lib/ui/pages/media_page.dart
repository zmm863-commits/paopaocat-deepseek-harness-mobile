import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/configured_models.dart';
import '../../data/edit_box.dart';
import '../../data/media_models.dart';
import '../../data/prompt_expert.dart';
import '../../data/relative_time.dart';
import '../../data/subtitle_frame.dart';
import '../../data/tts.dart';
import '../../i18n/dsh_i18n.dart';
import '../../local/dsh_runtime.dart';
import '../../local/media_service.dart';
import '../../state/app_settings.dart';
import 'ai_role_page.dart';
import 'clip_page.dart';
import 'studio_page.dart';
import 'creation_guide_page.dart';
import '../../state/model_store.dart';
import '../../local/local_tts.dart';
import '../../local/model_install.dart';
import '../../data/library_store.dart' show resolveWorkspaceFromFilesDir;
import '../widgets/dsh_panel.dart';
import '../theme/dsh_tokens.dart';
import '../session_start.dart';

/// 「影视」—— 泡泡猫的影视工具在**手机上的形态**。
///
/// ## 和桌面插件的关系（先说清，免得期待错位）
///
/// 桌面那个「泡泡猫的影视工具」是 DSH 的**网页插件**（React，跑在电脑上），手机里
/// 嵌不了；这里是**原生重写**的手机版。生成能力**是同一条管道** ——
/// 仍然是随包的 `make-image.mjs` / `make-video.mjs` + Agnes，
/// 所以手机上生成的图和视频，格式、质量、提示词写法都和电脑上一致，
/// 也自动继承 429 退避重试与多账号 Key 轮换。
///
/// ## 手机习惯（这一版刻意做的取舍）
///
/// * **少打字**：选项用 chips 点选（尺寸/比例/时长），不让你手打参数；
///   再配一个「✨ 写专业点」把一句话扩写成专业提示词 —— 手机上打字才是成本最高的一步。
/// * **别让人猜**：生成中显示**已等多久**，并说清"视频几十秒到几分钟是正常的"；
///   失败显示脚本的**原话**（它写得比"出错了"有用得多）。
/// * **大按钮、可中断**：生成中随时能取消；结果直接就地预览。
/// * **作品不丢**：产物落在 `<filesDir>/media/{image,video}`，"作品"页从新到旧列出来，
///   可预览、分享、用外部应用打开、删除。
/// * **离开 App 不迷路**：选参考图/首帧会跳去相机或相册，走之前打标记，
///   回来仍然停在「影视」这一页（AppShell 的 `pickInFlightWithin` 机制）。
///
/// ## 这一页**有什么、没有什么**（如实说明，别让用户以为是坏了）
///
/// 五个标签：**生图 / 生视频 / 口播 / 短剧**（4 个功能）+ **作品**（库）。
///   * ⚠️ 这 4 个功能与"会话里选了哪个模型"**无关**：生图/生视频走的是
///     「设置 → 图像 / 视频模型」里选中的那条（默认是内置的 Agnes），
///     而**请求形状按厂家换**（用户 2026-10-11 纠正过：「影视这个工具实际是
///     可以使用多个厂家」）—— 界面上的档位也按厂家给（见 [MediaVendors]）。
///     只有「✨ 写专业点」那类**写文本**的动作才会用你选的会话模型
///     （见 `prompt_expert.dart` 的 `_pickModel`）。
///   * **没有单独的「修图」入口**（2026-10-11 用户问起）：Agnes 只有
///     `POST /v1/images/generations` 一个图像接口，"图生图 / 多图合成"就是往
///     `extra_body.image` 塞参考图 —— 也就是**生图页的「参考图」**（最多 4 张）。
///     但它没写"修图"两个字，用户找不到，所以待办里记着加一个明确的「修图（图生图）」入口。
///   * 还没做：桌面的「无限画布（节点编排）」「封面」—— 手机交互要重新设计。
///   * 口播 / 短剧**已可用**（随包 ffmpeg + 手机自带 TTS）。
class MediaPage extends StatefulWidget {
  const MediaPage({
    super.key,
    required this.runtime,
    required this.settings,
    required this.onOpenSettings,
    this.onStartPrompt,
    this.refreshTick = 0,
    this.initialSeg,
    this.models,
  });

  final DshRuntime runtime;
  final AppSettings settings;

  /// 「去设置里配 Key」—— 与首页 `onOpenModelSettings` 同一套做法：
  /// 页面不自己切 Tab，而是把动作交回壳层（壳层才知道最新下标）。
  final VoidCallback onOpenSettings;

  /// **带首句开一个新会话**（交回壳层去做 —— 只有它知道怎么推会话页）。
  ///
  /// 用在哪：「创作台 → 创作 · 小说改游戏」那一页的「开始一个改编会话」按钮。
  /// 创作这条线的执行主体是**会话里的模型**，所以"开始创作"的正确做法就是
  /// 开一个带起始指令的会话，而不是我们自己写一套 UI 去驱动它。
  final void Function(String prompt)? onStartPrompt;

  /// 每次切到本页 +1，用于重扫作品库。
  final int refreshTick;

  /// **会话模型库**（文本模型）。可以为 null（测试里单独 pump 这一页时）——
  /// 那时右上角就不显示「文本模型」那一行，而不是显示一个点了没反应的。
  ///
  /// 用在哪：创作台右上角那个「模型」按钮（用户 2026-10-12 真机反馈第 9 条）。
  final ModelStore? models;

  /// 进来就停在**哪一个模式**（null = 停在"创作台"入口屏）。
  ///
  /// 用在哪：**「作品」入口搬到「资料库」之后**（用户 2026-10-12 真机反馈第 4 条），
  /// 资料库那边点「作品」就是直接推这一页、并让它落在 `5`（作品库）——
  /// 这样作品库这套视图只有一份，不用在两个页面各写一遍。
  final int? initialSeg;

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  late final MediaService _media = MediaService(widget.runtime);

  int _seg = 0; // 0 生图 / 1 生视频 / 2 修图 / 3 口播 / 4 短剧 / 5 作品（见 _modes）

  /// 是不是停在「创作台」那一屏（入口屏）。
  ///
  /// 默认 true：**一进来先看到功能入口**，而不是某个功能的长表单
  /// （用户 2026-10-12 提议的「点按钮进详情页」形态）。
  bool _launcher = true;

  // ── 生图 ──────────────────────────────────────────────
  final TextEditingController _imgCtl = TextEditingController();
  String _size = '1K';
  String _imgRatio = '1:1';
  final List<String> _refs = <String>[];
  bool _imgBusy = false;
  Process? _imgProc;
  List<String> _imgLog = <String>[];
  MediaResult? _imgResult;
  DateTime? _imgStarted;
  Timer? _tick;
  int _imgElapsed = 0;

  // ── 生视频 ────────────────────────────────────────────
  final TextEditingController _vidCtl = TextEditingController();
  String _seconds = '5';
  String _vidRatio = '16:9';
  /// 分辨率档位（`720P` / `1080P` / `480P` / `2K`…）。**按厂家换**：
  /// 豆包 Seedance 不发分辨率（界面不显示这一行）、硅基流动按比例换算 image_size。
  String _vidResolution = '720P';
  String? _firstFrame;
  bool _vidBusy = false;
  Process? _vidProc;
  List<String> _vidLog = <String>[];
  MediaResult? _vidResult;
  DateTime? _vidStarted;
  int _vidElapsed = 0;

  // ── 口播 / 短剧（共用一套"合成"状态：同一时刻只会跑一个）──────
  final TextEditingController _talkCtl = TextEditingController();
  String? _talkImage; // 形象图（可选，没选就用纯色底）
  final TextEditingController _dramaCtl = TextEditingController();
  String? _dramaImage; // 统一形象图（每镜都用它，除非开了"每镜生成"）
  bool _dramaPerShot = false; // 每镜用 Agnes 按该行文本生成一张画面
  String _narSize = '9:16'; // 竖屏是短剧/口播的主场景
  /// 配音来源：**默认系统 TTS**（人人可用、免配置）；MiMo / MiniMax 是可选升级。
  ///
  /// 初值从 `widget.settings`（落盘的偏好）取，用户改了立刻落盘 ——
  /// 原来这三项只活在 State 里，离开页面就回默认，用户每次生成都得重挑一遍。
  TtsSource _ttsSource = TtsSource.system;

  /// 当前来源选中的**音色 id**（空串 = 该家默认）。
  ///
  /// ⚠️ 这是个**镜像**：真值在 `widget.settings`（按家分开存，`ttsVoiceFor`）。
  /// 这样切走再切回来，之前挑的音色还在。
  String _ttsVoiceId = '';

  /// 配音语速倍率（1.0 = 原速）。同样镜像 `widget.settings.ttsSpeed`。
  double _ttsSpeed = 1.0;

  /// 从 MiniMax 账号**拉到的**音色表（不落盘：它是供应商侧的、随时会变；
  /// 用户选的音色 id 反而是落盘的，所以重启后下拉里仍能显示"上次那个"）。
  List<TtsVoice> _ttsVoices = const <TtsVoice>[];
  bool _ttsVoiceBusy = false;
  bool _narBusy = false;
  bool _narCancel = false;
  Process? _narProc;
  List<String> _narLog = <String>[];
  MediaResult? _narResult;

  /// 这一次**没有配音**的原因（null = 正常有配音）。
  ///
  /// 2026-10-13（用户要求「A 方案」）：以前配音一失败就**整个中断、什么都拿不到**；
  /// 现在改成"没有配音也把片子做出来"（画面 + 字幕 + 静音），并把原因记在这里，
  /// 结果卡上会**明确写出来**——绝不能让用户拿到一个静音片却以为配音成功了。
  String? _narNoVoiceReason;

  // ── 本机离线配音（B 方案）的界面状态
  //
  // 引擎是常驻的（见 local_tts.dart），但**装模型**这件事要进度、要能取消、
  // 要能失败后重试，所以状态放在页面里。
  late final TtsModelInstaller _ttsInstaller =
      TtsModelInstaller(runtime: widget.runtime);
  bool _ttsInstalling = false;
  double _ttsInstallFrac = 0;
  String _ttsInstallLabel = '';
  String? _ttsInstallError;
  TtsInstallCancel? _ttsInstallCancel;
  bool _localSampleBusy = false;
  DateTime? _narStarted;
  int _narElapsed = 0;

  /// 口播/短剧的画幅（渲染字幕帧与 ffmpeg 合成必须**用同一个尺寸**）。
  (int, int) get _narPixels => switch (_narSize) {
        '16:9' => (1920, 1080),
        '1:1' => (1080, 1080),
        _ => (1080, 1920),
      };

  // ── 修图（本机 ffmpeg 滤镜，不联网、不花额度）────────────
  //
  // 与「生图」的分工必须说清（用户 2026-10-11 两次问到这里）：
  //   * **重画 / 换风格 / 多图合成** → 「生图」+ 参考图（走 Agnes 图生图，要联网）；
  //   * **只动这一小块 / 调色 / 去水印** → 这里（本机 ffmpeg，秒级，不花额度）。
  String? _editSrc;

  /// 源图尺寸（像素）。**读不到就禁用去水印**（框要用像素算，不能瞎猜）。
  int? _editW;
  int? _editH;
  String _editPreset = 'fresh';
  double _editStrength = 60;
  bool _editDelogo = false;

  /// 水印框位置：`br/bl/tr/tl/bottom`（右下/左下/右上/左上/底条）。
  ///
  /// 它给的是"常见位置"的**起点**；用户可以在预览图上**直接拖框**微调（见 [_editDx]）。
  String _editPos = 'br';

  /// 用户拖出来的偏移（像素，正 = 往右下）。点位置 chip 时清零（那是重新选起点）。
  double _editDx = 0;
  double _editDy = 0;
  double _editBoxW = 18; // 占画面宽度 %
  double _editBoxH = 8; // 占画面高度 %

  /// **自由框选**的左上角（占画面 %）。null = 还没自由框过，走 [_editPos] 那套起点。
  ///
  /// 用户 2026-10-12：「去水印功能，只能选择固定位置，我记得以前说过把这个去水印
  /// 改成擦除，用户可以选择照片任意位置进行擦除」—— 之前只有"起点 + 拖动偏移"，
  /// 尺寸还得靠两根滑杆。现在在图上**直接按住拖就能框出一块**（任意位置、任意大小），
  /// 框的四角还能拖着重调。
  double? _boxXp;
  double? _boxYp;

  /// 正在图上拖框（`'move'` = 拖框本身 / `'draw'` = 拉出新框 / null = 没在拖）。
  String? _editDrag;

  /// 拉新框时的起点（图像像素坐标）。
  Offset? _editDragStart;
  bool _editBusy = false;
  Process? _editProc;
  List<String> _editLog = <String>[];
  MediaResult? _editResult;
  DateTime? _editStarted;
  int _editElapsed = 0;
  Timer? _editTick;

  // ── 用的图像 / 视频模型（「设置 → 图像 / 视频模型」里选，见 data/media_models.dart）
  //
  // 为什么要从盘上读、而不是写死 Agnes：用户 2026-10-11 的要求是"设置好之后在
  // 影视工具里能选"。写死的话他就没法换 —— 而这件事对"以后 Agnes 收费/下架"很关键。
  MediaModelConfig _mediaCfg = const MediaModelConfig();
  MediaModelSpec? _imageModel;
  MediaModelSpec? _videoModel;

  /// 当前选中的**厂家 id**（界面按它决定"显示哪些档位"）。
  ///
  /// 用户 2026-10-11 纠正过：「影视这个工具实际是可以使用多个厂家」——
  /// 所以档位不能写死，得跟着厂家走（见 [MediaVendors]）。
  String get _imageProvider =>
      (_imageModel?.provider ?? MediaModels.builtinProvider).trim();
  String get _videoProvider =>
      (_videoModel?.provider ?? MediaModels.builtinProvider).trim();

  /// 换厂家后自动回落时**被改掉的值**（界面在小字里如实说一句，绝不静默）。
  List<String> _imgFallback = const <String>[];
  List<String> _vidFallback = const <String>[];

  void _loadMediaModels() {
    final cfg = MediaModels.read(widget.runtime.filesDir);
    setState(() {
      _mediaCfg = cfg;
      _imageModel = MediaModels.selected(cfg, 'image');
      _videoModel = MediaModels.selected(cfg, 'video');
      _syncVendorOptions();
    });
  }

  /// 把"当前选中的档位"拉回**这家支持的集合**。
  ///
  /// 为什么必须做：用户可能先在 Agnes 下选好 `2K`，然后换成一家只认
  /// `1024x1024` 的厂家 —— 不回落就是把 Agnes 的档位发给别家，**必然失败**。
  /// 回落**不静默**：改了哪些值记进 [_imgFallback] / [_vidFallback]，界面上说一句。
  ///
  /// 这家**没有**某一档（万相没有比例、硅基流动没有时长）时把值清空 ——
  /// service 那边对空值是"不发这个参数"，而不是塞一个空串给上游。
  void _syncVendorOptions() {
    final io = MediaVendors.imageOptions(_imageProvider);
    final vo = MediaVendors.videoOptions(_videoProvider);

    final img = <String>[];
    if (io.sizes.isEmpty) {
      _size = '';
    } else if (!io.sizes.contains(_size)) {
      _size = io.sizes.first;
      img.add(_size);
    }
    if (io.ratios.isEmpty) {
      _imgRatio = '';
    } else if (!io.ratios.contains(_imgRatio)) {
      _imgRatio = io.ratios.first;
      img.add(_imgRatio);
    }
    _imgFallback = img;

    if (vo == null) {
      _vidFallback = const <String>[];
      return;
    }
    final vid = <String>[];
    if (vo.resolutions.isEmpty) {
      _vidResolution = '';
    } else if (!vo.resolutions.contains(_vidResolution)) {
      _vidResolution = vo.resolutions.first;
      vid.add(_vidResolution);
    }
    if (vo.ratios.isEmpty) {
      _vidRatio = '';
    } else if (!vo.ratios.contains(_vidRatio)) {
      _vidRatio = vo.ratios.first;
      vid.add(_vidRatio);
    }
    final secs = MediaVendors.secondsChoices(_videoProvider);
    if (secs.isEmpty) {
      _seconds = '';
    } else if (!secs.contains(_seconds)) {
      _seconds = '${vo.seconds?.def ?? 5}';
      vid.add(_seconds);
    }
    _vidFallback = vid;
  }

  // ── 作品 ──────────────────────────────────────────────
  List<MediaItem> _items = const <MediaItem>[];
  bool _loading = true;
  /// 作品数到上限被截断（界面要如实说，不能假装只有这些）。
  bool _truncated = false;

  @override
  void initState() {
    super.initState();
    // 直接落到指定模式（资料库点「作品」进来）：那时不显示入口屏。
    if (widget.initialSeg != null) {
      _seg = widget.initialSeg!;
      _launcher = false;
    }
    _loadTtsPrefs();
    _reloadItems();
    _loadMediaModels();
  }

  /// 把落盘的配音偏好读进（并建立与 `AppSettings` 的镜像关系）。
  ///
  /// 为什么要镜像而不是每次直读 `widget.settings`：几个 getter 要配合
  /// `_ttsSourceId`（来源）才能确定"这一家选的音色"，而来源本身也在设置里 ——
  /// 镜像一次比每处都写一遍解码逻辑清楚。设置变了只可能由本页发起，
  /// 所以不需要监听。
  void _loadTtsPrefs() {
    final s = widget.settings;
    _ttsSource = TtsSource.values.firstWhere(
      (v) => v.name == s.ttsSourceId,
      orElse: () => TtsSource.system,
    );
    _ttsVoiceId = s.ttsVoiceFor(_ttsSource.name);
    _ttsSpeed = s.ttsSpeed;
  }

  /// 切换配音来源：记忆镜像 + 落盘 + 读回**这一家**上次选的音色。
  Future<void> _pickTtsSource(TtsSource v) async {
    setState(() {
      _ttsSource = v;
      _ttsVoiceId = widget.settings.ttsVoiceFor(v.name);
    });
    await widget.settings.setTtsSource(v.name);
  }

  Future<void> _pickTtsVoice(String id) async {
    setState(() => _ttsVoiceId = id);
    await widget.settings.setTtsVoice(_ttsSource.name, id);
  }

  Future<void> _pickTtsSpeed(double v) async {
    setState(() => _ttsSpeed = v);
    await widget.settings.setTtsSpeed(v);
  }

  /// 拉取 MiniMax 账号里的音色列表（官方 `POST /v1/get_voice`）。
  ///
  /// **不编音色**：MiniMax 的音色随账号变，官方 CLI 也是现拉的，
  /// 所以这里拉不到就如实说，绝不塞一份"猜的清单"进去。
  Future<void> _fetchTtsVoices() async {
    setState(() => _ttsVoiceBusy = true);
    final r = await fetchMinimaxVoices();
    if (!mounted) return;
    setState(() {
      _ttsVoiceBusy = false;
      if (r.voices.isNotEmpty) _ttsVoices = r.voices;
    });
    if (r.error != null) {
      _toast(r.error!, long: true);
    } else {
      _toast(context.tr('拉到 {0} 个音色。', <Object?>['${r.voices.length}']));
    }
  }

  /// 当前来源下**可选**的音色列表。
  ///
  /// 兜底逻辑（重要）：用户上次选的音色 id **不在**当前列表里（比如
  /// MiniMax 刚重启、列表还没拉），也要能显示出来 —— 否则下拉会变成空白，
  /// 用户以为"我选的被吃了"。所以把镜像值补成一个条目。
  List<TtsVoice> get _voiceChoices {
    final base = _ttsSource == TtsSource.mimo
        ? kMimoVoices
        : <TtsVoice>[kMinimaxDefaultVoice, ..._ttsVoices];
    if (_ttsVoiceId.isEmpty || base.any((v) => v.id == _ttsVoiceId)) return base;
    return <TtsVoice>[TtsVoice(_ttsVoiceId, _ttsVoiceId), ...base];
  }

  /// 音色下拉（**受控**：显示的那个值永远来自 `_ttsVoiceId`）。
  ///
  /// ⚠️ 这里刻意**不用 `DropdownButtonFormField`**：它的 `initialValue` 只是初值，
  /// 之后由 **FormField 自己的内部状态**记住选中项 —— 于是"切到另一家"时
  /// （`_ttsVoiceId` 被换成那一家上次选的音色）下拉里**还显示上一家的音色**，
  /// 而用户以为换过来了（界面与真实状态不一致，正是本项目最忌讳的那类坏法）。
  /// `DropdownButton` 的 `value:` 是受控的，不存在这个坑。
  Widget _voicePicker() {
    final choices = _voiceChoices;
    final current = _ttsVoiceId.isEmpty ? choices.first.id : _ttsVoiceId;
    return Row(children: <Widget>[
      Expanded(
        child: InputDecorator(
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: const OutlineInputBorder(),
            labelText: context.tr('音色'),
            labelStyle: TextStyle(color: DshColors.textDim, fontSize: 12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: current,
              isExpanded: true,
              isDense: true,
              style: TextStyle(color: DshColors.text, fontSize: 12.5),
              items: <DropdownMenuItem<String>>[
                for (final v in choices)
                  DropdownMenuItem<String>(
                    value: v.id,
                    child: Text(
                      v.hint.isEmpty
                          ? context.tr(v.label)
                          : '${context.tr(v.label)} · ${context.tr(v.hint)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
              ],
              onChanged: _narBusy ? null : (v) => _pickTtsVoice(v ?? ''),
            ),
          ),
        ),
      ),
      if (_ttsSource == TtsSource.minimax) ...<Widget>[
        const SizedBox(width: 8),
        TextButton(
          onPressed: (_narBusy || _ttsVoiceBusy) ? null : _fetchTtsVoices,
          child: Text(
            _ttsVoiceBusy ? context.tr('拉取中…') : context.tr('拉取音色'),
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ]);
  }

  Widget _speedPicker() {
    // MiMo 没有数值语速参数，只有"用自然语言说"（官方文档），所以这一档
    // 用**三档按钮**而不是滑杆 —— 滑到 1.07 倍对 MiMo 毫无意义，会误导人。
    if (_ttsSource == TtsSource.mimo) {
      return Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
        for (final p in kSpeedPresets)
          ChoiceChip(
            label: Text(context.tr(p.label), style: const TextStyle(fontSize: 12.5)),
            selected: (_ttsSpeed - p.speed).abs() < 0.001,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            onSelected: _narBusy ? null : (_) => _pickTtsSpeed(p.speed),
          ),
      ]);
    }
    // MiniMax / 系统：真有一个倍率参数，给连续滑杆（0.5~2.0）。
    return Row(children: <Widget>[
      Text(context.tr('语速'),
          style: TextStyle(color: DshColors.textDim, fontSize: 11.5)),
      Expanded(
        child: Slider(
          value: _ttsSpeed.clamp(0.5, 2.0),
          min: 0.5,
          max: 2.0,
          divisions: 15,
          label: '${_ttsSpeed.toStringAsFixed(2)}×',
          onChanged: _narBusy ? null : (v) => _pickTtsSpeed(v),
        ),
      ),
      Text('${_ttsSpeed.toStringAsFixed(2)}×',
          style: TextStyle(color: DshColors.textFaint, fontSize: 11.5)),
    ]);
  }

  @override
  void didUpdateWidget(covariant MediaPage old) {
    super.didUpdateWidget(old);
    if (old.refreshTick != widget.refreshTick) {
      // 也从设置页回来时重读「图像 / 视频模型」——用户可能在那边刚换过。
      _reloadItems();
      _loadMediaModels();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _editTick?.cancel();
    // 页面没了就别让 node 继续跑着（否则用户看不到任何进度，白占流量和电量）。
    _imgProc?.kill();
    _vidProc?.kill();
    _editProc?.kill();
    _imgCtl.dispose();
    _vidCtl.dispose();
    _talkCtl.dispose();
    _dramaCtl.dispose();
    _narProc?.kill();
    super.dispose();
  }

  void _reloadItems() {
    final list = _media.listItems();
    final cut = _media.listItemsTruncated;
    if (!mounted) return;
    setState(() {
      _items = list;
      _truncated = cut;
      _loading = false;
    });
  }

  void _toast(String msg, {bool long = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: Duration(seconds: long ? 8 : 4),
      ));
  }

  /// 计时器：只让"已等多久"走动（不用 StreamBuilder，省得整页重建）。
  void _startTick(bool isImage) {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (isImage) {
          _imgElapsed = DateTime.now().difference(_imgStarted!).inSeconds;
        } else {
          _vidElapsed = DateTime.now().difference(_vidStarted!).inSeconds;
        }
      });
    });
  }

  String _hms(int sec) {
    if (sec < 60) return '$sec 秒';
    final m = sec ~/ 60;
    final s = sec % 60;
    return s == 0 ? '$m 分' : '$m 分 $s 秒';
  }

  // ─────────────────────────────────────────────────── 修图

  /// 修图的计时器（同一个理由：只让"已等多久"走动）。
  void _startEditTick() {
    _editTick?.cancel();
    _editTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _editStarted == null) return;
      setState(() =>
          _editElapsed = DateTime.now().difference(_editStarted!).inSeconds);
    });
  }

  /// 读源图尺寸（用 Flutter 自己的解码器，不依赖 ffprobe；读不出就如实留空）。
  ///
  /// 为什么要它：去水印框是**像素**坐标（`delogo` 只认像素）。没有尺寸就只能瞎猜位置，
  /// 那比"这一项先不给用"糟得多 —— 所以读不出时界面上直接禁用去水印并说明原因。
  Future<void> _loadEditDims(String path) async {
    int? w;
    int? h;
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      w = frame.image.width;
      h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
    } catch (e) {
      debugPrint('[dsh-media] 读源图尺寸失败：$e');
    }
    if (!mounted) return;
    setState(() {
      _editW = w;
      _editH = h;
    });
  }

  /// 去水印框（**像素**坐标）。
  ///
  /// ⚠️ 算法只有一份（`data/edit_box.dart` 的 `computeDelogoBox`），这里只做
  /// "读不出尺寸就返回 null"这一层判断 —— 保证**预览里画的框**与
  /// **传给脚本的框**（`edit-image.mjs --delogo`）是同一个数。
  ({int x, int y, int w, int h})? _editBox() {
    final srcW = _editW;
    final srcH = _editH;
    if (srcW == null || srcH == null) return null;
    // 自由框过 → 用那一块（任意位置、任意大小）；否则用"起点 + 偏移"那套。
    if (_boxXp != null && _boxYp != null) {
      return boxFromRect(
        imgW: srcW,
        imgH: srcH,
        xPct: _boxXp!,
        yPct: _boxYp!,
        wPct: _editBoxW,
        hPct: _editBoxH,
      );
    }
    return computeDelogoBox(
      imgW: srcW,
      imgH: srcH,
      pos: _editPos,
      widthPct: _editBoxW,
      heightPct: _editBoxH,
      dx: _editDx,
      dy: _editDy,
    );
  }

  /// 把像素框写回**自由框选**状态（拖动/缩放/拉新框都走这里）。
  ///
  /// 只写百分比、不存像素 —— 因为原图尺寸在极端情况下可能被重新读到（换图），
  /// 存百分比才能跟着新尺寸走。
  void _setBoxPx({required int x, required int y, required int w, required int h}) {
    final w0 = _editW;
    final h0 = _editH;
    if (w0 == null || h0 == null || w0 <= 0 || h0 <= 0) return;
    setState(() {
      _boxXp = x / w0 * 100;
      _boxYp = y / h0 * 100;
      _editBoxW = w / w0 * 100;
      _editBoxH = h / h0 * 100;
    });
  }

  /// 选一张要修的图（相册 / 相机）。
  Future<void> _pickEditSource() async {
    // ⚠️ `from: 'media'` + **finally 里清标记** —— 这两件事缺一不可。
    //    用户 2026-10-12 报「退出去选其他服务有的时候会跳转到本地会话这个页面」：
    //    影视页这三处取图**只置位、从不清除**（本地对话那处有 finally，这三处漏了），
    //    于是标记在盘上留 3 分钟 → 期间任何一次重建/调度变动都会把「本地对话」推上来。
    await widget.settings.setPickInFlight(true, from: 'media');
    try {
      final path = await DshHost.pickAttachment('media');
      if (path == null || !mounted) return;
      const ok = <String>['.jpg', '.jpeg', '.png', '.webp', '.bmp'];
      if (!ok.any(path.toLowerCase().endsWith)) {
        _toast(context.tr('只能选图片（修图要一张图）。'));
        return;
      }
      setState(() => _editSrc = path);
      await _loadEditDims(path);
    } catch (e) {
      if (mounted) _toast(context.tr('选图失败：{0}', <Object?>['$e']));
    } finally {
      // 不管选到、取消还是报错，回来就要清 —— 否则下次启动会平白多推一页。
      await widget.settings.setPickInFlight(false);
    }
  }

  /// 从「作品」里挑一张来修（刚生成的图往往就是接着想处理的那张）。
  Future<void> _pickEditFromGallery() async {
    final images = _items.where((i) => i.kind == MediaKind.image).toList();
    if (images.isEmpty) {
      _toast(context.tr('「作品」里还没有图片 —— 先生成一张，或用上面的按钮选一张。'));
      return;
    }
    final picked = await showModalBottomSheet<MediaItem>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(context.tr('从「作品」里选一张'),
                  style: TextStyle(
                      color: DshColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            for (final item in images.take(60))
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
                  child: Image.file(File(item.path),
                      width: 44, height: 44, fit: BoxFit.cover),
                ),
                title: Text(item.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: DshColors.text, fontSize: 12.5)),
                subtitle: Text(
                  '${item.sizeLabel} · ${relativeTimeLabel(item.modified)}',
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                ),
                onTap: () => Navigator.of(ctx).pop(item),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _editSrc = picked.path);
    await _loadEditDims(picked.path);
  }

  Future<void> _runEdit() async {
    final src = _editSrc;
    if (src == null) {
      _toast(context.tr('先选一张要修的图。'));
      return;
    }
    final box = _editDelogo ? _editBox() : null;
    if (_editDelogo && box == null) {
      _toast(
          context.tr('读不出这张图的尺寸，去水印用不了（怕把框盖错地方）—— 可以只做美化。'),
          long: true);
      return;
    }
    setState(() {
      _editBusy = true;
      _editResult = null;
      _editLog = <String>[];
      _editStarted = DateTime.now();
      _editElapsed = 0;
    });
    _startEditTick();
    final r = await _media.editImage(
      source: src,
      preset: _editPreset,
      strength: _editStrength.round(),
      delogo: box == null ? null : '${box.x}:${box.y}:${box.w}:${box.h}',
      onLog: (line) {
        if (!mounted) return;
        setState(() {
          _editLog = <String>[..._editLog, line].length > 40
              ? <String>[..._editLog, line].sublist(_editLog.length + 1 - 40)
              : <String>[..._editLog, line];
        });
      },
      onProcess: (p) => _editProc = p,
    );
    _editTick?.cancel();
    _editProc = null;
    if (!mounted) return;
    setState(() {
      _editBusy = false;
      _editResult = r;
    });
    if (r.ok) {
      _reloadItems();
      _toast(context.tr('修好了，已放进「作品」。'));
    }
  }

  void _cancelEdit() {
    _editProc?.kill();
    _toast(context.tr('已取消。'));
  }

  /// 创作台入口屏列出来的模式。**下标即 [_seg] 的取值**。
  ///
  /// ⚠️ 2026-10-12（真机反馈第 4 条）：**「作品」从这张表里去掉了** ——
  ///    用户的说法是「作品改到资料库就可以了，因为可以看到资料库」。
  ///    所以现在入口屏只列 0–4；`_seg == 5`（作品库）仍然存在，但由
  ///    **资料库**那边点「作品」直接推进来（见 [MediaPage.initialSeg]）。
  ///
  /// ⚠️ 标签**不放在这张表里**，而是由 [_modeLabel] 里的字面量 `tr('…')` 给出 ——
  /// i18n 扫描器只认源码里的字面量，写在数据表里它就看不见（等于永远不翻译）。
  static const List<({int value, IconData icon})> _modes =
      <({int value, IconData icon})>[
    (value: 0, icon: Icons.image_outlined),
    (value: 1, icon: Icons.movie_outlined),
    (value: 2, icon: Icons.auto_fix_high_outlined),
    (value: 3, icon: Icons.record_voice_over_outlined),
    (value: 4, icon: Icons.theaters_outlined),
  ];

  static String _modeLabel(BuildContext context, int value) => switch (value) {
        0 => context.tr('生图'),
        1 => context.tr('生视频'),
        2 => context.tr('修图'),
        3 => context.tr('口播'),
        4 => context.tr('短剧'),
        _ => context.tr('作品'),
      };

  // ─────────────────────────────────────────── 生图 / 生视频

  Future<void> _runImage() async {
    final prompt = _imgCtl.text.trim();
    if (prompt.isEmpty) {
      _toast(context.tr('先写一句你想要的画面。'));
      return;
    }
    setState(() {
      _imgBusy = true;
      _imgResult = null;
      _imgLog = <String>[];
      _imgStarted = DateTime.now();
      _imgElapsed = 0;
    });
    _startTick(true);
    // ⚠️ 只发**这家支持的**东西：MiniMax 不吃参考图，万相没有比例参数
    //    （`_syncVendorOptions` 已经把不支持的值清空了，这里再挡一道）。
    final io = MediaVendors.imageOptions(_imageProvider);
    final r = await _media.generateImage(
      prompt: prompt,
      size: _size,
      ratio: _imgRatio.isEmpty ? null : _imgRatio,
      refs: io.refs ? List<String>.from(_refs) : const <String>[],
      model: _imageModel,
      onLog: (line) {
        if (!mounted) return;
        setState(() {
          // 只留最后 40 行：这是给用户看的进度，不是日志文件。
          _imgLog = <String>[..._imgLog, line].length > 40
              ? <String>[..._imgLog, line].sublist(_imgLog.length + 1 - 40)
              : <String>[..._imgLog, line];
        });
      },
      onProcess: (p) => _imgProc = p,
    );
    _tick?.cancel();
    _imgProc = null;
    if (!mounted) return;
    setState(() {
      _imgBusy = false;
      _imgResult = r;
    });
    if (r.ok) {
      _reloadItems();
      _toast(context.tr('生成好了，已放进「作品」。'));
    }
  }

  Future<void> _runVideo() async {
    final prompt = _vidCtl.text.trim();
    if (prompt.isEmpty) {
      _toast(context.tr('先写一句你想要的画面。'));
      return;
    }
    setState(() {
      _vidBusy = true;
      _vidResult = null;
      _vidLog = <String>[];
      _vidStarted = DateTime.now();
      _vidElapsed = 0;
    });
    _startTick(false);
    // 这家不吃首帧图（万相只有文生视频）时**不传** —— 传了也只会被上游忽略，
    // 反而让用户以为"我选了首帧却没用上"。值本身留着，换回支持的那家还在。
    final vo = MediaVendors.videoOptions(_videoProvider);
    final r = await _media.generateVideo(
      prompt: prompt,
      seconds: _seconds,
      ratio: _vidRatio,
      resolution: _vidResolution,
      firstFrame: (vo?.firstFrame ?? false) ? _firstFrame : null,
      model: _videoModel,
      onLog: (line) {
        if (!mounted) return;
        setState(() {
          _vidLog = <String>[..._vidLog, line].length > 40
              ? <String>[..._vidLog, line].sublist(_vidLog.length + 1 - 40)
              : <String>[..._vidLog, line];
        });
      },
      onProcess: (p) => _vidProc = p,
    );
    _tick?.cancel();
    _vidProc = null;
    if (!mounted) return;
    setState(() {
      _vidBusy = false;
      _vidResult = r;
    });
    if (r.ok) {
      _reloadItems();
      _toast(context.tr('生成好了，已放进「作品」。'));
    }
  }

  void _cancel(bool isImage) {
    (isImage ? _imgProc : _vidProc)?.kill();
    _toast(context.tr('已取消。'));
  }

  /// 选图（参考图 / 首帧）。走 App 现成的原生通道，拿回真实绝对路径。
  Future<void> _pick({required bool forRef}) async {
    await widget.settings.setPickInFlight(true, from: 'media');
    try {
      final path = await DshHost.pickAttachment('media');
      if (path == null || !mounted) return;
      final lower = path.toLowerCase();
      const ok = <String>['.jpg', '.jpeg', '.png', '.webp', '.bmp'];
      if (!ok.any(lower.endsWith)) {
        _toast(context.tr('只能选图片（参考图/首帧要图片）。'));
        return;
      }
      setState(() {
        if (forRef) {
          if (_refs.length >= 4) {
            _toast(context.tr('参考图最多 4 张。'));
            return;
          }
          _refs.add(path);
        } else {
          _firstFrame = path;
        }
      });
    } catch (e) {
      if (mounted) _toast(context.tr('选图失败：{0}', <Object?>['$e']));
    } finally {
      // ⚠️ 必须清：影视页这几处以前**只置位不清除**，标记会留 3 分钟，
      //    期间 App 一重建就被推去「本地对话」（用户 2026-10-12 报的那条）。
      await widget.settings.setPickInFlight(false);
    }
  }

  /// 「✨ 写专业点」：把一句话扩写成专业提示词，**直接填进输入框**。
  Future<void> _expand({required bool isImage}) async {
    final ctl = isImage ? _imgCtl : _vidCtl;
    final input = ctl.text.trim();
    if (input.isEmpty) {
      _toast(context.tr('先写一句大概的想法，我再帮你写专业。'));
      return;
    }
    // 生图页给出图类专家，生视频页给视频类 —— 别让用户在 6 个里翻。
    final experts = isImage
        ? kPromptExperts
            .where((e) => <String>['t2i', 'i2i', 'sheet'].contains(e.key))
            .toList()
        : kPromptExperts
            .where((e) => <String>['t2v', 'drama', 'anchor'].contains(e.key))
            .toList();
    final picked = await showModalBottomSheet<PromptExpert>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: <Widget>[
                Text(context.tr('让谁帮你写？'),
                    style: TextStyle(
                        color: DshColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
            for (final e in experts)
              ListTile(
                leading: Text(e.icon, style: const TextStyle(fontSize: 20)),
                // 走 tr()：专家的名字/例子是**数据**（在 prompt_expert.dart 的表里），
                // 而 i18n 扫描器只认源码字面量 —— 所以那边有一小段"锚点"保证这些
                // 字面量能被扫到、被翻译（否则切外语时这里还是中文）。
                title: Text(context.tr(e.name)),
                subtitle: Text(context.tr(e.hint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 11)),
                onTap: () => Navigator.of(ctx).pop(e),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _toast(context.tr('正在让「{0}」写…', <Object?>[picked.name]));
    final cfg = ConfiguredModels.readConfig(widget.runtime.filesDir);
    final r = await expandPrompt(expert: picked, input: input, cfg: cfg);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? context.tr('扩写失败。'), long: true);
      return;
    }
    ctl.text = r.text!;
    _toast(context.tr('写好了，可以直接改或直接生成。'));
  }

  // ─────────────────────────────────────────── 作品库

  Future<void> _shareItem(MediaItem item) async {
    try {
      final r = await DshHost.shareFile(item.path);
      // 每一种结局都留一行：SnackBar 一关掉就没证据了，而"分享不出去"这类
      // 问题只能靠报告里的这几行定位（理由同 lib/ui/pages/library_page.dart 的 _share）。
      debugPrint('[dsh-media-ui] 分享 ${item.path} -> $r');
      if (r != 'ok' && mounted) {
        _toast(context.tr('分享没成功：{0}', <Object?>[r]));
      }
    } catch (e) {
      debugPrint('[dsh-media-ui] 分享失败 ${item.path}：$e');
      if (mounted) _toast(context.tr('分享失败：{0}', <Object?>['$e']));
    }
  }

  Future<void> _openItem(MediaItem item) async {
    try {
      final r = await DshHost.openFile(item.path);
      debugPrint('[dsh-media-ui] 外部打开 ${item.path} -> $r');
      if (r != 'ok' && mounted) {
        _toast(context.tr('打开没成功：{0}', <Object?>[r]));
      }
    } catch (e) {
      debugPrint('[dsh-media-ui] 外部打开失败 ${item.path}：$e');
      if (mounted) _toast(context.tr('打开失败：{0}', <Object?>['$e']));
    }
  }

  Future<void> _deleteItem(MediaItem item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('删除这个作品？')),
        content: Text(context.tr('文件会真的从手机里删掉，不能恢复。')),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.tr('取消'))),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('删除')),
          ),
        ],
      ),
    );
    if (yes != true) return;
    // 弹窗是 async gap：回来先确认页面还在（`_toast` 内部虽然也守了，
    // 但 lint 看不到那一层，而且这里还要用 context 取文案）。
    if (!mounted) return;
    try {
      File(item.path).deleteSync();
      _reloadItems();
      _toast(context.tr('已删除。'));
    } catch (e) {
      _toast(context.tr('删不掉：{0}', <Object?>['$e']));
    }
  }

  /// 全屏预览：图片可缩放；视频这里只给信息 + 动作（App 里没有内置播放器，
  /// 与其塞一个半成品，不如老实引导到系统播放器）。
  void _preview(MediaItem item) {
    if (item.kind == MediaKind.image) {
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(8),
          child: Stack(children: <Widget>[
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Image.file(File(item.path), fit: BoxFit.contain),
            ),
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ]),
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          ListTile(
            leading: const Icon(Icons.movie_outlined),
            title: Text(item.fileName),
            subtitle: Text('${item.sizeLabel} · ${item.timeLabel}'),
          ),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: Text(context.tr('用手机上的播放器打开')),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_openItem(item));
            },
          ),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: Text(context.tr('分享 / 发送给别人')),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_shareItem(item));
            },
          ),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────── 构建

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bg,
      appBar: AppBar(
        // 2026-10-12（用户提议）：底部那一项从「影视」改名「**创作台**」。
        // 理由：这一页早就不止影视了（生图/修图/口播/短剧/作品都在这儿），
        // 叫「影视」名不副实，而"创作台"既能容纳现有的、也能容纳以后加的功能。
        title: Text(_launcher
            ? context.tr('创作台')
            : context.tr('创作台 · {0}', [_modeLabel(context, _seg)])),
        // 进到某个功能里时，左上角给「回创作台」（这是"入口/详情分离"的关键：
        // 用户永远有一条明确的路退回那一屏按钮）。
        leading: _launcher
            ? null
            : IconButton(
                tooltip: context.tr('回创作台'),
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _launcher = true),
              ),
        actions: <Widget>[
          // 原来是"小钥匙"（点了跳去设置配 Key）。用户 2026-10-12 真机反馈第 9 条
          // 要求把它换成**三个模型的选择**：「文本模型 / 图形模型 / 视频模型，
          // 都是读取设置里边的模型，但是创作台会应用这些模型」。
          // 所以这个按钮现在读写的**就是设置里那两份数据**，不另开一份配置。
          IconButton(
            tooltip: context.tr('这次用哪三个模型'),
            icon: const Icon(Icons.tune),
            onPressed: () => _showModelSheet(),
          ),
          // 「去设置配 Key」没丢：并进右侧那张菜单里（见 [_showModelSheet]），
          // 因为"模型选好了但没有 Key"正是最需要一键跳过去的时候。
        ],
      ),
      body: _launcher
          ? _launcherView()
          : Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: <Widget>[
                      Icon(_modeIcon(_seg), size: 16, color: DshColors.accent),
                      const SizedBox(width: 6),
                      Text(_modeLabel(context, _seg),
                          style: TextStyle(
                              color: DshColors.textDim,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: switch (_seg) {
                    0 => _imageTab(),
                    1 => _videoTab(),
                    2 => _editTab(),
                    3 => _talkTab(),
                    4 => _dramaTab(),
                    _ => _galleryTab(),
                  },
                ),
              ],
            ),
    );
  }

  IconData _modeIcon(int value) => switch (value) {
        0 => Icons.image_outlined,
        1 => Icons.movie_outlined,
        2 => Icons.auto_fix_high_outlined,
        3 => Icons.record_voice_over_outlined,
        4 => Icons.theaters_outlined,
        _ => Icons.grid_view_outlined,
      };

  /// 「创作台」这一屏：**功能入口列表**。
  ///
  /// 为什么要有这一屏（用户 2026-10-12 提议）：原来 6 个模式挤在同一个长表单顶上，
  /// 一进来就是一整页输入框与选项，**用户得先滚一遍才知道这儿有哪几个功能**。
  /// 现在第一眼是一屏按钮（每个都带一句"这功能干什么"），点进去才是那个功能，
  /// 而且**每个功能页只做一件事**（不再顶着 6 个 chip）。
  ///
  /// 用整行卡片而不是网格：窄屏（`narrow_layout_test` 覆盖的那些机型）上
  /// 两列网格会把标题挤成两行、还容易溢出；整行卡片横向永远不溢出。
  Widget _launcherView() {
    // ⚠️ 用户 2026-10-16：「创作台那里项目太多，是不是也分类，用下拉菜单」。
    //    之前这里有 **10 个入口平铺**（5 个生成模式 + 剪辑 / APP界面设计台 / 画图表 /
    //    小说改游戏 / AI 角色），一屏放不下也不好找。现在按**"你要做的事"**分成 4 组，
    //    组用 `DshGroupSection`（就是设置页那套折叠分组：点标题展开/收起），
    //    **默认全部收起** —— 先让用户看见"有哪几类"，要找什么再展开哪一类。
    //
    //    分组口径（按用途，不按实现）：
    //      · 生成图像与视频 = 产出一张图/一段视频（含修图）；
    //      · 口播与短剧     = 带声音/带剧情的整活；
    //      · 工具           = 处理已有素材、或画东西；
    //      · 创作           = 一条完整的创作流程。
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      children: <Widget>[
        Text(
          context.tr('选一个功能开始。做完点左上角就能回到这里。'),
          style:
              TextStyle(color: DshColors.textFaint, fontSize: 11.5, height: 1.5),
        ),
        const SizedBox(height: 10),
        DshGroupSection(
          title: context.tr('生成图像与视频'),
          children: <Widget>[
            for (final m in _modes.where((m) => m.value <= 2))
              _workbenchEntry(
                icon: m.icon,
                title: _modeLabel(context, m.value),
                hint: _modeHint(context, m.value),
                onTap: () => _openFunction(m.value),
              ),
          ],
        ),
        DshGroupSection(
          title: context.tr('口播与短剧'),
          children: <Widget>[
            for (final m in _modes.where((m) => m.value >= 3))
              _workbenchEntry(
                icon: m.icon,
                title: _modeLabel(context, m.value),
                hint: _modeHint(context, m.value),
                onTap: () => _openFunction(m.value),
              ),
          ],
        ),
        DshGroupSection(
          title: context.tr('工具'),
          children: <Widget>[
            // 2026-10-12（用户问「OpenCut 能不能搬到创作台」）：**剪辑**。
            // 那种多轨时间线剪辑器搬不动，但它的**最小可用子集**能真跑 ——
            // 用随包的 ffmpeg 剪一段/拼接/抽音频/抽一帧/压小（见 ClipPage 的说明）。
            _workbenchEntry(
              icon: Icons.content_cut_outlined,
              title: context.tr('剪辑'),
              hint: context.tr(
                  '手上已有视频：剪一段 / 拼接 / 抽音频 / 抽一帧 / 压小（本机跑，不联网）'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ClipPage(runtime: widget.runtime),
                ),
              ),
            ),
            // 2026-10-16（用户：「做好放到创作台」）：**APP界面设计台**。
            // 基于 m3e-canvas（MIT）的手机适配版；产物与字体都随包，
            // 由 App 进程内的 loopback 静态服务 + WebView 打开（不用容器）。
            _workbenchEntry(
              icon: Icons.design_services_outlined,
              title: context.tr('APP界面设计台'),
              hint: context.tr(
                  '在手机上画界面草图（Material 3），导出成给 AI 的描述（随包自带，打开即用）'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => StudioPage(runtime: widget.runtime),
                ),
              ),
            ),
            // 2026-10-16（用户问「ppt 这个功能放哪了」）：原来只有**首页内置会话**
            // 那条「做一份幻灯片」能进这条路，创作台里找不到 → 在这里补一个明确入口。
            // 与「画图表」同一个形状：先给一张说明 + 几个可点的例子，点了才开会话
            // （PPT 需要模型先写大纲，不是一键直出，所以不做成"填个框就生成"）。
            _workbenchEntry(
              icon: Icons.slideshow_outlined,
              title: context.tr('做 PPT / 幻灯片'),
              hint: context.tr('生成真正的 .pptx：12 种版式 + 自动排版（封面 / 卡片 / 时间线 / 对比 / 数据图…）'),
              onTap: () => _showSlidesSheet(),
            ),
            _workbenchEntry(
              icon: Icons.schema_outlined,
              title: context.tr('画图表'),
              hint: context.tr('架构图 / 流程图 / 时序图 / ER 图 / 时间线…（44 种，出自包含网页）'),
              onTap: () => _showDiagramSheet(),
            ),
          ],
        ),
        DshGroupSection(
          title: context.tr('创作'),
          children: <Widget>[
            // 2026-10-12（用户「也可以」）：**创作**这条线先接「小说改游戏」——
            // 它不是"生成模式"，而是一整条七阶段改编流程（点进去是说明页 + 起始指令）。
            _workbenchEntry(
              icon: Icons.auto_stories_outlined,
              title: context.tr('创作 · 小说改游戏'),
              hint: context.tr('把一本小说改编成能在浏览器里玩的游戏（七个阶段）'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CreationGuidePage(onStart: widget.onStartPrompt),
                ),
              ),
            ),
            // 2026-10-12（用户「做成创作台里的一格」）：**AI 角色（实验）**。
            _workbenchEntry(
              icon: Icons.theater_comedy_outlined,
              title: context.tr('AI 角色（实验）'),
              hint: context.tr('让模型演一个角色，你跟他打交道 —— 每局都有目标和结束条件'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AiRolePage(onStart: widget.onStartPrompt),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 「画图表」入口：给几个**可以直接点的例子**，点了就用那句开一个会话。
  ///
  /// 为什么用弹层而不是整页：这个技能不需要"填参数"，它要的是一句**你想画什么**。
  /// 所以给例子 + 一句话说明边界就够了（而边界里最重要的一条是"自检脚本要 python、
  /// 本机用不了"，不说清模型会去试 `python3 scripts/verify-geometry.py` 然后卡住）。
  Future<void> _showDiagramSheet() async {
    final prefix = context.tr('用 diagram-design 技能，');
    final examples = <String>[
      context.tr('画一张系统架构图：调用方 → 网关 → 三个后端服务 → 数据库'),
      context.tr('把这个登录流程画成时序图：用户、App、认证服务、数据库'),
      context.tr('画一张 ER 图：用户、订单、商品三张表以及它们的关系'),
      context.tr('画一张项目时间线（甘特）：需求、开发、测试、上线四段'),
    ];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(context.tr('画图表'),
                  style: TextStyle(
                      color: DshColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                context.tr('44 种图型（架构 / 流程 / 时序 / ER / 时间线 / 桑基 / 甘特…）。'
                    '产物是**自包含的网页**（HTML + 内联 SVG），画完能在「资料库」里直接打开看。'
                    '下面点一个例子就开始（会话里再改成你要的）。'),
                style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              for (final e in examples)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.chevron_right, size: 18, color: DshColors.accent),
                  title: Text(e,
                      style: TextStyle(color: DshColors.text, fontSize: 12.5, height: 1.4)),
                  onTap: widget.onStartPrompt == null
                      ? null
                      : () {
                          // ⚠️ 前缀先取出来：写成 `'${context.tr('…')}$e'` 的话，
                          //    i18n 扫描器**看不见**那个字面量（切外语会静默露中文）。
                          // ⚠️ 顺序交给 `closeThenStart`（先关自己、再开会话）——
                          //    写反了会把刚推上去的会话页弹掉（2026-10-12 真机反馈第 6 条）。
                          closeThenStart(ctx, widget.onStartPrompt!, '$prefix$e');
                        },
                ),
              const SizedBox(height: 6),
              Text(
                context.tr('如实说明：上游那几个 python 自检脚本（几何校验、drawio/mermaid '
                    '导入）**没有随包**（手机上没 python），所以那几步用不了；'
                    '上游的 211 个示例图也没随包（省 4.4 MB）。画法规范在技能里是完整的。'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「做 PPT / 幻灯片」的说明弹层：几个可点的例子 → 开新会话（点名 make-slides）。
  ///
  /// 为什么不做成"填个框就生成"：幻灯片要先由模型把材料**写成大纲**（选版式、拆页、
  /// 写要点），再交给 `make-pptx.mjs` 排版 —— 它是**会话里的技能**，不是一键工具。
  /// 所以这里给的是"从哪个例子开始"，点下去就是一条指名技能的开场白。
  Future<void> _showSlidesSheet() async {
    final prefix = context.tr('用 make-slides 技能帮我做一份幻灯片。');
    final examples = <String>[
      context.tr('把下面这些材料做成 8 页左右的工作汇报（材料我贴在后面）'),
      context.tr('做一份教学幻灯片：讲清「什么是向量数据库」，10 页以内'),
      context.tr('做一份路演稿：产品是什么 / 给谁用 / 怎么赚钱 / 要多少钱，6 页'),
      context.tr('把这两个方案做成一页对比：左边 A 方案、右边 B 方案'),
    ];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(context.tr('做 PPT / 幻灯片'),
                  style: TextStyle(
                      color: DshColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                context.tr('**排版不用你操心**：你只说讲什么、想做成哪种样子，脚本自己算字号、'
                    '分栏与分页（放不下会缩字号、再放不下会拆成「（续）」页）。'
                    '产物是真正的 .pptx —— 原生形状，在 WPS / Office 里能改颜色、改字。'
                    '下面是几个起点，点一个就开始（会话里再改成你要的）。'),
                style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              for (final e in examples)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.chevron_right, size: 18, color: DshColors.accent),
                  title: Text(e,
                      style: TextStyle(color: DshColors.text, fontSize: 12.5, height: 1.4)),
                  onTap: widget.onStartPrompt == null
                      ? null
                      : () {
                          // ⚠️ 与画图表那处同样的两个坑：前缀必须先取出来（否则 i18n
                          //    扫描器看不见那个字面量）；顺序交给 closeThenStart。
                          closeThenStart(ctx, widget.onStartPrompt!, '$prefix$e');
                        },
                ),
              const SizedBox(height: 6),
              Text(
                context.tr('如实说明：App 里**看不了** .pptx 的样子（没有 Office 组件）。'
                    '生成后在「资料库」里能找到它，用「用其它应用打开」交给手机上的 WPS / Office，'
                    '或者直接分享出去。'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开某个功能（入口 → 详情）。
  void _openFunction(int value) {
    setState(() {
      _seg = value;
      _launcher = false;
    });
    // 作品页要重新读目录（用户可能在别处刚生成了东西）。
    if (value == 5) _reloadItems();
  }

  Widget _workbenchEntry({
    required IconData icon,
    required String title,
    required String hint,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        label: '$title：$hint',
        child: Material(
          color: DshColors.surfaceStrong,
          borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
          child: InkWell(
            borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(children: <Widget>[
                Icon(icon, size: 20, color: DshColors.accent),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title,
                          style: TextStyle(
                              color: DshColors.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(hint,
                          style: TextStyle(
                              color: DshColors.textFaint,
                              fontSize: 11,
                              height: 1.35)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 18, color: DshColors.textFaint),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// 每个功能一句话说明（入口上就写清"点进去能干什么"，别让人猜）。
  static String _modeHint(BuildContext context, int value) => switch (value) {
        0 => context.tr('一句话或一张参考图，生成图片'),
        1 => context.tr('把一段动作描述生成短视频'),
        2 => context.tr('调色、锐化、擦除水印（本机处理，不联网）'),
        3 => context.tr('文稿 → 配音 + 字幕 → 成片'),
        4 => context.tr('分镜 → 每镜画面 → 合成一条短剧'),
        _ => context.tr('这里汇集了所有生成过的图片和视频'),
      };

  /// 「用的模型」一行：显示当前模型 + 点一下换掉。
  ///
  /// ⚠️ 候选来自「设置 → 图像 / 视频模型」（`data/media_models.dart`），
  /// 与会话模型**完全是两套** —— 见那个文件的类注释。
  Widget _modelRow(String kind) {
    final isImage = kind == 'image';
    final cur = isImage ? _imageModel : _videoModel;
    return Row(children: <Widget>[
      Text(isImage ? context.tr('生图模型') : context.tr('生视频模型'),
          style: TextStyle(
              color: DshColors.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w600)),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          cur?.displayName ?? context.tr('（没读到模型）'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: DshColors.text, fontSize: 12),
        ),
      ),
      TextButton(
        onPressed: (_imgBusy || _vidBusy || _narBusy)
            ? null
            : () => _pickMediaModel(kind),
        child: Text(context.tr('换一个')),
      ),
    ]);
  }

  /// 右上角「模型」：**文本 / 图形 / 视频**三个槽位。
  ///
  /// ## 为什么不另存一份配置（用户 2026-10-12 真机反馈第 9 条）
  ///
  /// 他那句话是「都是读取设置里边的模型，但是创作台会应用这些模型」—— 关键在
  /// **"读取设置里边的"**：所以三个槽位直接读写设置里那两份数据
  /// （文本 = 会话模型 `ModelStore`；图形/视频 = `media-models.json`），
  /// 在这里改等于在设置里改。否则会出现"设置页显示 A、创作台生成用 B"这种
  /// 用户永远查不出来的错位。
  Future<void> _showModelSheet() async {
    final text = widget.models?.selected;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(context.tr('这次创作台用哪三个模型'),
                    style: TextStyle(
                        color: DshColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            if (widget.models != null)
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline, size: 18),
                title: Text(context.tr('文本模型'),
                    style: TextStyle(color: DshColors.text, fontSize: 12.5)),
                subtitle: Text(
                    text?.name ?? context.tr('（还没选 —— 去设置里选一个）'),
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                // ⚠️ 先关掉这一层再去开下一个选择层（同 `closeThenStart` 的教训：
                //    先 push 再 pop 会把新开的那一层弹掉）。
                onTap: () {
                  Navigator.of(ctx).pop();
                  _pickTextModel();
                },
              ),
            ListTile(
              leading: const Icon(Icons.image_outlined, size: 18),
              title: Text(context.tr('图形模型'),
                  style: TextStyle(color: DshColors.text, fontSize: 12.5)),
              subtitle: Text(
                  _imageModel?.displayName ?? context.tr('（还没选）'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickMediaModel('image');
              },
            ),
            ListTile(
              leading: const Icon(Icons.movie_outlined, size: 18),
              title: Text(context.tr('视频模型'),
                  style: TextStyle(color: DshColors.text, fontSize: 12.5)),
              subtitle: Text(
                  _videoModel?.displayName ?? context.tr('（还没选）'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickMediaModel('video');
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.key_outlined, size: 18),
              title: Text(context.tr('去设置里配 Key'),
                  style: TextStyle(color: DshColors.text, fontSize: 12.5)),
              subtitle: Text(context.tr('模型选好了但还没填 Key 的话，从这里过去'),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onOpenSettings();
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: Text(
                context.tr('这三个就是设置里那几个模型（文本模型 = 首页新会话用的那个；'
                    '图形/视频 = 「设置 → 图像 / 视频模型」），在这儿改等于在设置里改 —— '
                    '创作台生成时会**直接用**这里选的。'),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 换**文本模型**（会写进 `models.json` 的 selected，与首页/设置是同一个选中）。
  Future<void> _pickTextModel() async {
    final store = widget.models;
    if (store == null) return;
    final cur = store.selected?.routeId;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(context.tr('用哪个文本模型？'),
                  style: TextStyle(
                      color: DshColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            for (final m in store.catalog)
              ListTile(
                leading: Icon(
                  m.routeId == cur
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: m.routeId == cur ? DshColors.accent : DshColors.textDim,
                ),
                title: Text(m.name,
                    style: TextStyle(color: DshColors.text, fontSize: 12.5)),
                subtitle: Text(m.routeId,
                    style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
                onTap: () => Navigator.of(ctx).pop(m.routeId),
              ),
            if (store.catalog.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(context.tr('还没有任何模型 —— 先去「设置 → 模型」加一个。'),
                    style: TextStyle(color: DshColors.textDim, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final hit = store.catalog.where((m) => m.routeId == picked).toList();
    if (hit.isEmpty) return;
    await store.selectModel(hit.first);
    if (!mounted) return;
    _toast(context.tr('换好了：{0}', <Object?>[hit.first.name]));
  }

  /// 换图像/视频模型（写进 `media-models.json`，下次进来还是它）。
  Future<void> _pickMediaModel(String kind) async {
    final isImage = kind == 'image';
    final list = MediaModels.choices(_mediaCfg, kind);
    final curRoute = (isImage ? _imageModel : _videoModel)?.route;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                  isImage ? context.tr('用哪个图像模型？') : context.tr('用哪个视频模型？'),
                  style: TextStyle(
                      color: DshColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            for (final m in list)
              ListTile(
                leading: Icon(
                  m.route == curRoute
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: m.route == curRoute
                      ? DshColors.accent
                      : DshColors.textDim,
                ),
                title: Text(m.displayName,
                    style: TextStyle(color: DshColors.text, fontSize: 12.5)),
                subtitle: Text(
                  '${m.route}${m.builtin ? context.tr(' · 内置') : ''}',
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11),
                ),
                onTap: () => Navigator.of(ctx).pop(m.route),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                context.tr('在「设置 → 图像 / 视频模型」里可以添加别的模型。'
                    '⚠️ 请求形状按各家的文档写（生图 / 生视频各一套：端点、参数名、'
                    '轮询都不一样），**能不能通要试** —— 失败会把上游原话显示出来。'),
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await MediaModels.select(
        filesDir: widget.runtime.filesDir, kind: kind, route: picked);
    if (!mounted) return;
    _loadMediaModels();
    _toast(context.tr('换好了。'));
  }

  Widget _imageTab() {
    final provider = _imageProvider;
    final opts = MediaVendors.imageOptions(provider);
    // 尺寸标签跟着档位性质走：Agnes 是"清晰度档位"，别家是像素尺寸。
    final sizeLabel = opts.sizes.any((s) => s.contains('x'))
        ? context.tr('尺寸')
        : context.tr('清晰度');
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
      children: <Widget>[
        _modelRow('image'),
        const SizedBox(height: 10),
        if (!MediaVendors.supportsImage(provider)) ...<Widget>[
          Text(
            context.tr('这家在本 App 里没接图像：点上面的「换一个」选一家支持图像的厂家。'),
            style: _optHint,
          ),
        ] else ...<Widget>[
          _promptField(
            controller: _imgCtl,
            hint: context.tr('想画什么？例如：一只橘猫坐在窗台上看雨'),
            onExpand: () => _expand(isImage: true),
          ),
          const SizedBox(height: 10),
          // ⚠️ 档位**从厂家矩阵取**，不再写死 —— 这家没有的那一项直接不显示
          //    （比如万相没有比例参数、MiniMax 没有 size）。
          if (opts.sizes.isNotEmpty)
            _chips(
              label: sizeLabel,
              choices: opts.sizes,
              selected: _size,
              onSelect: (v) => setState(() => _size = v),
            ),
          if (opts.sizes.isNotEmpty && opts.ratios.isNotEmpty)
            const SizedBox(height: 8),
          if (opts.ratios.isNotEmpty)
            _chips(
              label: context.tr('画面比例'),
              choices: opts.ratios,
              selected: _imgRatio,
              onSelect: (v) => setState(() => _imgRatio = v),
            ),
          const SizedBox(height: 8),
          Text(context.tr(opts.note), style: _optHint),
          if (_imgFallback.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              context.tr('已按这家支持的档位改成 {0}',
                  <Object?>[_imgFallback.join(' / ')]),
              style: _optHint.copyWith(color: DshColors.accent),
            ),
          ],
          if (opts.refs) ...<Widget>[
            const SizedBox(height: 10),
            _refRow(),
          ],
          const SizedBox(height: 14),
          _bigButton(
            busy: _imgBusy,
            label: context.tr('生成图片'),
            onTap: _runImage,
            onCancel: () => _cancel(true),
          ),
          if (_imgBusy || _imgResult != null) ...<Widget>[
            const SizedBox(height: 12),
            _progressOrResult(
              busy: _imgBusy,
              elapsed: _imgElapsed,
              log: _imgLog,
              result: _imgResult,
              patientNote: null,
              onCancel: () => _cancel(true),
              onRetry: _runImage,
            ),
          ],
        ],
      ],
    );
  }

  Widget _videoTab() {
    final provider = _videoProvider;
    final opts = MediaVendors.videoOptions(provider);
    // 这家在本 App 里没接视频（OpenAI / 用户自己填的厂家）：
    // **不给一个必然失败的按钮**，直接说清楚，并指回"换一个"。
    if (opts == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
        children: <Widget>[
          _modelRow('video'),
          const SizedBox(height: 10),
          Text(
            context.tr('这家在本 App 里没接视频：点上面的「换一个」选一家支持视频的厂家'
                '（Agnes / 豆包 Seedance / MiniMax / 通义万相 / 硅基流动）。'),
            style: _optHint,
          ),
        ],
      );
    }
    final secs = MediaVendors.secondsChoices(provider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
      children: <Widget>[
        _modelRow('video'),
        const SizedBox(height: 10),
        _promptField(
          controller: _vidCtl,
          hint: context.tr('想拍什么？例如：一只橘猫在木桌上伸懒腰然后跳下桌面，镜头缓慢右移'),
          onExpand: () => _expand(isImage: false),
        ),
        const SizedBox(height: 10),
        // ⚠️ 分辨率 / 时长 / 画幅都**从厂家矩阵取**：这家没有的那一项直接不显示
        //    （豆包 Seedance 不发分辨率、硅基流动没有时长参数），并在下面的小字里
        //    如实写一句为什么 —— 而不是给一个必然被忽略的选项。
        if (opts.resolutions.isNotEmpty)
          _chips(
            label: context.tr('分辨率'),
            choices: opts.resolutions,
            selected: _vidResolution,
            onSelect: (v) => setState(() => _vidResolution = v),
          ),
        if (opts.resolutions.isNotEmpty && secs.isNotEmpty)
          const SizedBox(height: 8),
        if (secs.isNotEmpty)
          _chips(
            label: context.tr('时长（秒）'),
            choices: secs,
            selected: _seconds,
            onSelect: (v) => setState(() => _seconds = v),
          ),
        if ((opts.resolutions.isNotEmpty || secs.isNotEmpty) &&
            opts.ratios.isNotEmpty)
          const SizedBox(height: 8),
        if (opts.ratios.isNotEmpty)
          _chips(
            label: context.tr('画幅'),
            choices: opts.ratios,
            selected: _vidRatio,
            onSelect: (v) => setState(() => _vidRatio = v),
          ),
        const SizedBox(height: 8),
        Text(context.tr(opts.note), style: _optHint),
        if (_vidFallback.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            context.tr('已按这家支持的档位改成 {0}',
                <Object?>[_vidFallback.join(' / ')]),
            style: _optHint.copyWith(color: DshColors.accent),
          ),
        ],
        if (opts.firstFrame) ...<Widget>[
          const SizedBox(height: 10),
          _firstFrameRow(),
        ],
        const SizedBox(height: 6),
        Text(
          context.tr('⚠️ 请求形状按各家的文档写（端点、参数名、轮询都不一样）—— '
              '**能不能通要试**；失败会把上游原话显示出来。'),
          style: _optHint,
        ),
        const SizedBox(height: 14),
        _bigButton(
          busy: _vidBusy,
          label: context.tr('生成视频'),
          onTap: _runVideo,
          onCancel: () => _cancel(false),
        ),
        if (_vidBusy || _vidResult != null) ...<Widget>[
          const SizedBox(height: 12),
          _progressOrResult(
            busy: _vidBusy,
            elapsed: _vidElapsed,
            log: _vidLog,
            result: _vidResult,
            // 视频要等几分钟是**正常**的，必须提前说，否则用户会以为卡死。
            patientNote: context.tr('视频是异步任务：几十秒到几分钟都正常，期间不会重复提交。'),
            onCancel: () => _cancel(false),
            onRetry: _runVideo,
          ),
        ],
      ],
    );
  }

  // ─────────────────────────────────────────── 修图

  /// 美化档位：**界面上的字 → 脚本认的 preset**（见 `assets/toolbox/edit-image.mjs`）。
  /// ⚠️ 键是界面字面量，i18n 扫描器靠 `tr('通透')` 之类的写法把译文表填上。
  static const Map<String, String> _editPresets = <String, String>{
    '通透': 'fresh',
    '电影感': 'cinema',
    '人像': 'skin',
    '暖调': 'warm',
    '冷调': 'cool',
    '不美化': 'none',
  };

  /// 水印框位置：**界面上的字 → 脚本认的位置码**。
  static const Map<String, String> _editPositions = <String, String>{
    '右下': 'br',
    '左下': 'bl',
    '右上': 'tr',
    '左上': 'tl',
    '底条': 'bottom',
  };

  /// ⚠️ **i18n 扫描器的锚点**（不要删）。
  ///
  /// 上面两张表的**键就是界面文案**，而扫描器只收集源码里字面量形式的 `tr('…')`
  /// —— 写在数据表里的字符串它看不见，于是切到英/日/韩时这些 chip 还是中文。
  /// 界面上真正取用的是 `context.tr(label)`，这一段只负责"让扫描器看得到"。
  /// （同一个坑 `prompt_expert.dart` 踩过，那边也有同样的锚点。）
  // ignore: unused_element
  static void _i18nAnchors() {
    tr('通透');
    tr('电影感');
    tr('人像');
    tr('暖调');
    tr('冷调');
    tr('不美化');
    tr('右下');
    tr('左下');
    tr('右上');
    tr('左上');
    tr('底条');
  }

  TextStyle get _editHint =>
      TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5);

  /// 生图 / 生视频里"这一家的档位说明"用的小字（比 [_editHint] 名字更通用）。
  TextStyle get _optHint => _editHint;

  /// 界面标签（**已经被 tr 翻译过**）→ 档位码。找不到给 null，调用方回退默认。
  ///
  /// 为什么不能用 `_editPresets[label]` 直接查：chip 传回来的是**译文**
  /// （切到日语就是日文），拿它查中文键必然查不到，于是"点一下档位就跳回通透"。
  String? _labelToPreset(String label) {
    for (final e in _editPresets.entries) {
      if (context.tr(e.key) == label) return e.value;
    }
    return null;
  }

  /// 界面标签（译文）→ 位置码。
  String? _labelToPos(String label) {
    for (final e in _editPositions.entries) {
      if (context.tr(e.key) == label) return e.value;
    }
    return null;
  }

  Widget _editSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required void Function(double) onChanged,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text('$label：$display',
          style: TextStyle(
              color: DshColors.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w600)),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: _editBusy ? null : onChanged,
        ),
      ),
    ]);
  }

  /// 源图预览 + （开了去水印时）**框的示意**。
  ///
  /// 框的位置必须与脚本算的一致 —— 用的是同一个 `_editBox()`（像素）按比例画上来，
  /// 所以"看到框住的那块"就是"真被盖住的那块"。
  Widget _editPreview(String src, ({int x, int y, int w, int h})? box) {
    final w0 = _editW;
    final h0 = _editH;
    final hasDims = w0 != null && h0 != null && w0 > 0 && h0 > 0;
    return SizedBox(
      height: 220,
      width: double.infinity,
      child: Center(
        child: AspectRatio(
          aspectRatio: hasDims ? w0 / h0 : 4 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
            // 用 LayoutBuilder 拿到**实际显示尺寸**，把像素框按比例画上来 ——
            // 与脚本的像素框是同一个 `_editBox()`，所以"看到框住的那块"就是"真被盖住的那块"。
            child: LayoutBuilder(builder: (ctx, c) {
              final shownW = c.maxWidth;
              final shownH = c.maxHeight;
              // 开着擦除时，图上**直接操作**（用户 2026-10-12 第 3 条：
              //   「只能选择固定位置……用户可以选择照片任意位置进行擦除」）：
              //   · 按在**框外** → 从按下那点拉出一个**新框**（任意位置、任意大小）；
              //   · 按在**框内** → 整块拖动；
              //   · 拖**框的四角** → 改大小。
              //   换算一律按"图像像素 / 显示像素"，拖完立刻按真实像素框回写，
              //   所以拖到边界后反向拖是即时响应的，不会"空拖"。
              return GestureDetector(
                onPanStart: (_editDelogo && hasDims && box != null)
                    ? (d) {
                        final sx = w0 / shownW;
                        final sy = h0 / shownH;
                        final px = d.localPosition.dx * sx;
                        final py = d.localPosition.dy * sy;
                        final inside = px >= box.x &&
                            px <= box.x + box.w &&
                            py >= box.y &&
                            py <= box.y + box.h;
                        setState(() {
                          _editDrag = inside ? 'move' : 'draw';
                          _editDragStart = inside ? null : Offset(px, py);
                        });
                      }
                    : null,
                onPanUpdate: (_editDelogo && hasDims && box != null)
                    ? (d) {
                        // 护栏：抓的是四角把手时，这一层**不许**再动一次
                        //（把手与这一层都是 Pan 手势，万一两个都收到事件，
                        //  会同时"移动 + 缩放"，框会跳）。
                        if (_editDrag == null || _editDrag == 'resize') return;
                        final sx = w0 / shownW;
                        final sy = h0 / shownH;
                        final dxPx = d.delta.dx * sx;
                        final dyPx = d.delta.dy * sy;
                        if (_editDrag == 'draw') {
                          final a = _editDragStart!;
                          final b = Offset(a.dx + dxPx, a.dy + dyPx);
                          // 从起点拉到当前点（两个方向都行）→ 直接定框。
                          final left = math.min(a.dx, b.dx);
                          final top = math.min(a.dy, b.dy);
                          final wpx = (a.dx - b.dx).abs();
                          final hpx = (a.dy - b.dy).abs();
                          _setBoxPx(
                            x: left.round().clamp(1, w0 - 2),
                            y: top.round().clamp(1, h0 - 2),
                            w: wpx.round().clamp(8, w0 - 2),
                            h: hpx.round().clamp(6, h0 - 2),
                          );
                          _editDragStart = b;
                          return;
                        }
                        // 整块移动：直接按像素框走（不再依赖"起点 + 偏移"那套，
                        // 所以从任意位置拖出来的框都能继续拖）。
                        _setBoxPx(
                          x: (box.x + dxPx).round(),
                          y: (box.y + dyPx).round(),
                          w: box.w,
                          h: box.h,
                        );
                      }
                    : null,
                onPanEnd: (_editDelogo && hasDims)
                    ? (_) => setState(() {
                          _editDrag = null;
                          _editDragStart = null;
                        })
                    : null,
                child: Stack(fit: StackFit.expand, children: <Widget>[
                Image.file(File(src), fit: BoxFit.fill),
                if (_editDelogo && box != null && hasDims) ...<Widget>[
                  Positioned(
                    left: box.x / w0 * shownW,
                    top: box.y / h0 * shownH,
                    width: box.w / w0 * shownW,
                    height: box.h / h0 * shownH,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: DshColors.err.withValues(alpha: 0.28),
                        border: Border.all(color: DshColors.err, width: 1.5),
                      ),
                    ),
                  ),
                  // 四角的拖拽把手 —— 让"这个框可以拖、可以缩放"一眼可见。
                  for (final c in const <String>['tl', 'tr', 'bl', 'br'])
                    Positioned(
                      left: (c == 'tl' || c == 'bl'
                              ? box.x / w0 * shownW
                              : (box.x + box.w) / w0 * shownW) -
                          11,
                      top: (c == 'tl' || c == 'tr'
                              ? box.y / h0 * shownH
                              : (box.y + box.h) / h0 * shownH) -
                          11,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        // 标记"这一拖是缩放"，父层看到就放手（见父层 onPanUpdate 的护栏）。
                        onPanStart: (_) => setState(() => _editDrag = 'resize'),
                        onPanUpdate: (d) {
                          final sx = w0 / shownW;
                          final sy = h0 / shownH;
                          final dxPx = d.delta.dx * sx;
                          final dyPx = d.delta.dy * sy;
                          var x = box.x.toDouble();
                          var y = box.y.toDouble();
                          var w = box.w.toDouble();
                          var h = box.h.toDouble();
                          if (c == 'tl' || c == 'bl') {
                            x += dxPx;
                            w -= dxPx;
                          } else {
                            w += dxPx;
                          }
                          if (c == 'tl' || c == 'tr') {
                            y += dyPx;
                            h -= dyPx;
                          } else {
                            h += dyPx;
                          }
                          // 最小尺寸：拉到太小就没意义了（且脚本侧也有下限）。
                          const minW = 12.0;
                          const minH = 12.0;
                          if (w < minW) {
                            if (c == 'tl' || c == 'bl') x -= minW - w;
                            w = minW;
                          }
                          if (h < minH) {
                            if (c == 'tl' || c == 'tr') y -= minH - h;
                            h = minH;
                          }
                          _setBoxPx(
                            x: x.round(),
                            y: y.round(),
                            w: w.round(),
                            h: h.round(),
                          );
                        },
                        child: Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: DshColors.err,
                              border: Border.all(color: Colors.white, width: 2),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
                ]),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _editTab() {
    final src = _editSrc;
    final box = _editDelogo ? _editBox() : null;
    final hasDims = _editW != null && _editH != null;
    final presetLabel = _editPresets.keys
        .firstWhere((k) => _editPresets[k] == _editPreset, orElse: () => '通透');
    final posLabel = _editPositions.keys
        .firstWhere((k) => _editPositions[k] == _editPos, orElse: () => '右下');
    final r = _editResult;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
      children: <Widget>[
        Text(context.tr('要修的图'),
            style: TextStyle(
                color: DshColors.textDim,
                fontSize: 11.5,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (src == null)
          Text(
            context.tr('还没选图。可以从相册选，也可以直接用「作品」里已经生成的那张。'),
            style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
          )
        else
          _editPreview(src, box),
        const SizedBox(height: 8),
        Row(children: <Widget>[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _editBusy ? null : _pickEditSource,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: Text(context.tr('选一张图')),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _editBusy ? null : _pickEditFromGallery,
              icon: const Icon(Icons.grid_view_outlined, size: 18),
              label: Text(context.tr('从「作品」里选')),
            ),
          ),
        ]),
        if (hasDims) ...<Widget>[
          const SizedBox(height: 4),
          Text(context.tr('原图尺寸：{0}×{1} 像素', <Object?>['$_editW', '$_editH']),
              style: _editHint),
        ],
        const SizedBox(height: 12),

        // ① 一键美化
        _chips(
          label: context.tr('一键美化'),
          choices: _editPresets.keys.map((k) => context.tr(k)).toList(),
          selected: context.tr(presetLabel),
          onSelect: (v) =>
              setState(() => _editPreset = _labelToPreset(v) ?? 'fresh'),
        ),
        if (_editPreset != 'none') ...<Widget>[
          const SizedBox(height: 4),
          _editSlider(
            label: context.tr('强度'),
            value: _editStrength,
            min: 10,
            max: 100,
            display: context.tr('{0}', <Object?>['${_editStrength.round()}']),
            onChanged: (v) => setState(() => _editStrength = v),
          ),
        ],
        Text(
          context.tr('美化是**本机 ffmpeg 滤镜**做的（调色 / 锐化 / 磨皮 / 暗角）：不联网、不花额度、秒级完成。'),
          style: _editHint,
        ),
        const SizedBox(height: 12),

        // ② 去水印
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _editDelogo,
          onChanged: (_editBusy || !hasDims)
              ? null
              : (v) => setState(() => _editDelogo = v),
          title: Text(context.tr('擦除（去水印 / 去杂物）'),
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            hasDims
                ? context.tr('用周围像素把它盖住 —— **不是恢复原内容**。纯色、平滑背景效果好；复杂纹理背景会看出痕迹。')
                : context.tr('先选一张图（要按原图尺寸算框的位置，读不出尺寸就不给用）'),
            style: _editHint,
          ),
        ),
        if (_editDelogo && hasDims) ...<Widget>[
          Text(
            context.tr('**在图上直接选**：按在空白处拖动 = 拉出一个新框（放哪、多大都随你）；'
                '按在框里拖动 = 整块移动；拖**四个角**的圆点 = 改大小。'
                '下面这几个只是"一键放好"的快捷起点。'),
            style: _editHint,
          ),
          const SizedBox(height: 6),
          _chips(
            label: context.tr('快捷起点（也可以直接在图上框）'),
            choices: _editPositions.keys.map((k) => context.tr(k)).toList(),
            selected: _boxXp == null ? context.tr(posLabel) : '',
            onSelect: (v) => setState(() {
              _editPos = _labelToPos(v) ?? 'br';
              // 换起点时把拖动偏移清零（否则"点右下"却停在上次拖的位置，会让人困惑），
              // 并**放弃自由框**——否则点了"右下"看起来没反应（自由框优先）。
              _editDx = 0;
              _editDy = 0;
              _boxXp = null;
              _boxYp = null;
            }),
          ),
          const SizedBox(height: 4),
          // 这两根滑杆是"精确微调"用的（拖动只有手指精度）；
          // 自由框选之后它们改的是**当前这块**的宽高，左上角不动。
          _editSlider(
            label: context.tr('框的宽（微调）'),
            value: _editBoxW,
            min: 2,
            max: 100,
            display: context.tr('{0}%', <Object?>['${_editBoxW.round()}']),
            onChanged: (v) => setState(() {
              _editBoxW = v;
              // 没有自由框时也要能生效：给一个左上角起点，否则拖出来的框会被忽略。
              _boxXp ??= 0;
              _boxYp ??= 0;
            }),
          ),
          _editSlider(
            label: context.tr('框的高（微调）'),
            value: _editBoxH,
            min: 2,
            max: 100,
            display: context.tr('{0}%', <Object?>['${_editBoxH.round()}']),
            onChanged: (v) => setState(() {
              _editBoxH = v;
              _boxXp ??= 0;
              _boxYp ??= 0;
            }),
          ),
          if (box != null)
            Text(
              context.tr('框：x={0} y={1} 宽 {2} 高 {3}（像素）—— 上面预览里那块就是真会被盖住的地方。',
                  <Object?>['${box.x}', '${box.y}', '${box.w}', '${box.h}']),
              style: _editHint,
            ),
          Text(
            context.tr('⚠️ 只提示、不替你判断：去掉**别人版权作品**上的水印有侵权风险（尤其发布或商用时）。'),
            style: _editHint.copyWith(color: DshColors.err.withValues(alpha: 0.8)),
          ),
        ],
        const SizedBox(height: 12),

        // ③ 开始
        _bigButton(
          busy: _editBusy,
          label: context.tr('开始修图'),
          onTap: _runEdit,
          onCancel: _cancelEdit,
        ),
        if (_editBusy || r != null) ...<Widget>[
          const SizedBox(height: 12),
          _progressOrResult(
            busy: _editBusy,
            elapsed: _editElapsed,
            log: _editLog,
            result: r,
            patientNote: null,
            onCancel: _cancelEdit,
            onRetry: _runEdit,
          ),
        ],
        // 修图必须能"前后对照"：只看新图，用户分不清"修了什么"。
        if (r != null && r.ok && src != null) ...<Widget>[
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Expanded(child: _editCompare(context.tr('原图'), src)),
            const SizedBox(width: 8),
            Expanded(child: _editCompare(context.tr('新图'), r.file!)),
          ]),
        ],
      ],
    );
  }

  Widget _editCompare(String label, String path) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(label,
          style: TextStyle(color: DshColors.textDim, fontSize: 11.5)),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
        child: Image.file(File(path),
            height: 130, width: double.infinity, fit: BoxFit.cover),
      ),
    ]);
  }

  // ─────────────────────────────────────────── 口播 / 短剧

  Widget _talkTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
      children: <Widget>[
        _narIntro(
          context.tr('把一段**文稿**变成一条带配音和字幕的视频：自动分段 → 每段配音 → '
              '字幕画在画面上 → 合成。适合口播、解说、知识分享。'),
        ),
        const SizedBox(height: 10),
        _promptField(
          controller: _talkCtl,
          hint: context.tr('把要念的稿子贴进来。例如：\n大家好，今天讲三个提高效率的小习惯……'),
          onExpand: () => _expandExpert(kPromptExperts.firstWhere((e) => e.key == 'anchor')),
        ),
        const SizedBox(height: 8),
        _narOptions(),
        const SizedBox(height: 10),
        _singleImageRow(
          label: context.tr('形象图（可选：没选就用纯色底）'),
          path: _talkImage,
          onPick: () => _pickInto(forTalk: true),
          onClear: () => setState(() => _talkImage = null),
        ),
        const SizedBox(height: 14),
        _bigButton(
          busy: _narBusy,
          label: context.tr('生成口播视频'),
          onTap: () => _runNarration(drama: false),
          onCancel: _cancelNarration,
        ),
        if (_narBusy || _narResult != null) ...<Widget>[
          const SizedBox(height: 12),
          _narrationProgress(),
        ],
      ],
    );
  }

  Widget _dramaTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
      children: <Widget>[
        _narIntro(
          context.tr('把**每行一句话**当成一个镜头，拼成一条短剧：每镜一句配音、一张画面、'
              '一行字幕。想要每镜不同画面就打开下面那个开关（会用生图按该行文本画一张）。'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _dramaCtl,
          minLines: 4,
          maxLines: 12,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: context.tr('一行一个镜头。例如：\n'
                '深夜的办公室只剩一盏灯\n'
                '他盯着屏幕上的数字，笑了一下\n'
                '门开了，站着他的老板'),
            hintStyle: TextStyle(color: DshColors.textFaint, fontSize: 13),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _expandExpert(
                kPromptExperts.firstWhere((e) => e.key == 'drama')),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: Text(context.tr('让「短剧剧本专家」写一版')),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _dramaPerShot,
          onChanged: _narBusy ? null : (v) => setState(() => _dramaPerShot = v),
          title: Text(context.tr('每镜生成一张新画面（按该行文本用生图）'),
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            context.tr('关掉的话，所有镜头共用下面这张形象图（更快、更省）。'),
            style: TextStyle(color: DshColors.textFaint, fontSize: 11),
          ),
        ),
        _narOptions(),
        const SizedBox(height: 10),
        _singleImageRow(
          label: context.tr('统一形象图（可选）'),
          path: _dramaImage,
          onPick: () => _pickInto(forTalk: false),
          onClear: () => setState(() => _dramaImage = null),
        ),
        const SizedBox(height: 14),
        _bigButton(
          busy: _narBusy,
          label: context.tr('生成短剧视频'),
          onTap: () => _runNarration(drama: true),
          onCancel: _cancelNarration,
        ),
        if (_narBusy || _narResult != null) ...<Widget>[
          const SizedBox(height: 12),
          _narrationProgress(),
        ],
      ],
    );
  }

  Widget _narIntro(String text) => Text(text,
      style: TextStyle(color: DshColors.textFaint, fontSize: 11.5, height: 1.5));

  // ───────────────────────────────── 本机离线配音（B 方案）

  /// 「配音 → 本机离线」那一块：模型状态 + 下载 + 说话人 + 试听。
  ///
  /// 为什么把"装模型"做进这一块、而不是新开一个设置页：
  /// 用户是在**要配音的时候**才发现"这台手机没引擎"，那就该在这条路径上
  /// 一步解决掉，而不是让他再去别处找一个入口（本地大模型那次撤入口的教训）。
  Widget _localTtsBlock() {
    final tts = LocalTts(widget.runtime.filesDir);
    final installed = tts.installed;
    final have = _ttsInstaller.downloadedBytes();
    final err = _ttsInstallError;
    final speakers = tts.speakers();
    final sid = int.tryParse(_ttsVoiceId.trim()) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: installed
                ? DshColors.accent.withValues(alpha: 0.08)
                : DshColors.text.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
            border: Border.all(
                color: installed
                    ? DshColors.accent.withValues(alpha: 0.35)
                    : DshColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(installed ? Icons.check_circle_outline : Icons.download_outlined,
                      size: 16,
                      color: installed ? DshColors.accent : DshColors.textDim),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        installed
                            ? context.tr('本机离线配音的模型**已经装好**了（占约 32 MB，离线可用）。')
                            : context.tr('还没装模型：要下 **31.5 MB**（装好后占约 32 MB），下完自动解包。'),
                        style: TextStyle(
                            color: installed ? DshColors.accent : DshColors.text,
                            fontSize: 12,
                            height: 1.4)),
                  ),
                ],
              ),
              if (!installed) ...<Widget>[
                const SizedBox(height: 8),
                if (_ttsInstalling) ...<Widget>[
                  LinearProgressIndicator(
                    value: _ttsInstallFrac <= 0 ? null : _ttsInstallFrac,
                    minHeight: 3,
                    backgroundColor: DshColors.line,
                    color: DshColors.accent,
                  ),
                  const SizedBox(height: 4),
                  Text(_ttsInstallLabel,
                      style: TextStyle(color: DshColors.textDim, fontSize: 11)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => _ttsInstallCancel?.cancel(),
                      child: Text(context.tr('取消'), style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ] else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: _installLocalTts,
                      icon: const Icon(Icons.download_outlined, size: 16),
                      label: Text(
                          have > 0
                              ? context.tr('继续下载（已下 {0} MB）',
                                  <Object?>[(have / 1048576).toStringAsFixed(1)])
                              : context.tr('下载模型（31.5 MB）'),
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  ),
                if (err != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(err,
                      style: TextStyle(color: DshColors.err, fontSize: 11.5, height: 1.4)),
                ],
                const SizedBox(height: 6),
                Text(
                  context.tr('装不动也不要紧：这个模型包里 172 MB 的规则文件**不会解出来**'
                      '（实测对我们没用），所以只占约 32 MB。也可以手动装 —— 把这几个文件'
                      '放进下面这个目录：\n{0}',
                      <Object?>[tts.modelDir]),
                  style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.5),
                ),
              ],
              if (installed) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                          context.tr('说话人：{0}（共 {1} 个，试听一下挑一个）', <Object?>[
                            sid < speakers.length ? speakers[sid] : '#$sid',
                            '${speakers.length}',
                          ]),
                          style: TextStyle(color: DshColors.textDim, fontSize: 11.5)),
                    ),
                    TextButton(
                      onPressed: () => _pickLocalSpeaker(tts, speakers),
                      child: Text(context.tr('换一个'), style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _localSampleBusy ? null : () => _previewLocalTts(tts, sid),
                    icon: const Icon(Icons.hearing_outlined, size: 16),
                    label: Text(
                        _localSampleBusy
                            ? context.tr('正在合成…')
                            : context.tr('试听这一句'),
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 下载 + 校验 + 解包（可取消；已下载的部分会留着续传）。
  Future<void> _installLocalTts() async {
    final cancel = TtsInstallCancel();
    setState(() {
      _ttsInstalling = true;
      _ttsInstallError = null;
      _ttsInstallCancel = cancel;
      _ttsInstallFrac = 0;
      _ttsInstallLabel = context.tr('准备中…');
    });
    final r = await _ttsInstaller.install(
      cancel: cancel,
      onProgress: (frac, label) {
        if (!mounted) return;
        setState(() {
          _ttsInstallFrac = frac;
          _ttsInstallLabel = label;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _ttsInstalling = false;
      _ttsInstallCancel = null;
      _ttsInstallError = r.ok ? null : (r.error ?? context.tr('安装失败（没有更多信息）'));
    });
    _toast(r.ok
        ? context.tr('装好了：本机离线配音现在可以用了（离线、零 Key）。')
        : context.tr('没装上：{0}', <Object?>[r.error ?? '']));
  }

  /// 选说话人：这个模型有 174 个（aishell3 数据集编号）。
  ///
  /// ⚠️ **不许编"男声/女声"** —— 编号里没有这个信息，编了就是骗人。
  /// 所以只给编号 + 一个「试听这一句」，让他自己挑。
  Future<void> _pickLocalSpeaker(LocalTts tts, List<String> speakers) async {
    final cur = int.tryParse(_ttsVoiceId.trim()) ?? 0;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: speakers.length,
          itemBuilder: (c, i) => ListTile(
            dense: true,
            leading: Icon(
              i == cur ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: i == cur ? DshColors.accent : DshColors.textDim,
            ),
            title: Text(speakers[i],
                style: TextStyle(color: DshColors.text, fontSize: 12.5)),
            subtitle: Text(context.tr('第 {0} 号', <Object?>['$i']),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
            onTap: () => Navigator.of(ctx).pop(i),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _ttsVoiceId = '$picked');
    await widget.settings.setTtsVoice(TtsSource.local.name, '$picked');
  }

  /// 试听：合成一句话到**当前工作区**，这样「资料库」里点一下就能听
  /// （不自己造播放器；App 内播放那条路已经在资料库里了）。
  Future<void> _previewLocalTts(LocalTts tts, int sid) async {
    setState(() => _localSampleBusy = true);
    try {
      final paths = await DshHost.getPaths();
      final filesDir = (paths['filesDir'] as String?) ?? '';
      final ws = resolveWorkspaceFromFilesDir(filesDir).path;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final out = '$ws/本机离线配音-试听-$stamp.wav';
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final file = tts.synthesizeToWav(
        text: '这是本机离线配音的试听，声音完全在这台手机上算出来。',
        outPath: out,
        sid: sid,
        speed: _ttsSpeed,
      );
      if (!mounted) return;
      _toast(context.tr('样音已生成：{0}（去「资料库」里点一下就能听）',
          <Object?>[file.split('/').last]));
    } on LocalTtsException catch (e) {
      if (mounted) _toast(context.tr('试听失败：{0}', <Object?>[e.message]));
    } catch (e) {
      if (mounted) _toast(context.tr('试听失败：{0}', <Object?>['$e']));
    } finally {
      if (mounted) setState(() => _localSampleBusy = false);
    }
  }

  /// 口播/短剧共用的选项：画幅 + **配音**（来源 / 音色 / 语速）。
  ///
  /// ⚠️ 配音来源**默认是系统 TTS** —— 这个 App 是给网友用的，不能假设他们注册过
  /// 某家云 TTS。系统配音零配置、免费、可离线；MiMo / MiniMax 只是"想要更自然
  /// 音色"时的可选升级，而且界面上必须**写清它需要 Key**，
  /// 不能让用户选了才发现用不了。
  ///
  /// 三家的差异如实写在界面上（不是营销话术）：
  ///   * 系统 —— 输出 wav，语速走原生参数；
  ///   * MiMo —— 输出 **wav**（官方文档的非流式格式；没看到 mp3 的写法，不编），
  ///     语速**没有数值参数**、只能拼成自然语言指令，所以只给三档；
  ///   * MiniMax —— 输出 **mp3**，语速是真正的倍率（滑杆），音色可现拉。
  Widget _narOptions() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _chips(
            label: context.tr('画幅'),
            choices: const <String>['9:16', '16:9', '1:1'],
            selected: _narSize,
            onSelect: _narBusy ? (_) {} : (v) => setState(() => _narSize = v),
          ),
          const SizedBox(height: 8),
          Text(context.tr('配音'),
              style: TextStyle(
                  color: DshColors.textDim,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
            // 「本机离线」放最前：它**零 Key、离线**，是这台手机唯一"一定能出声"的路
            // （用户 2026-10-13 要求；他那台手机没有系统 TTS 引擎）。
            ChoiceChip(
              label: Text(context.tr('本机离线（零 Key）'),
                  style: const TextStyle(fontSize: 12.5)),
              selected: _ttsSource == TtsSource.local,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: _narBusy ? null : (_) => _pickTtsSource(TtsSource.local),
            ),
            ChoiceChip(
              label: Text(context.tr('系统配音（零配置）'),
                  style: const TextStyle(fontSize: 12.5)),
              selected: _ttsSource == TtsSource.system,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: _narBusy ? null : (_) => _pickTtsSource(TtsSource.system),
            ),
            ChoiceChip(
              label: Text(context.tr('MiMo（更自然·需 Key）'),
                  style: const TextStyle(fontSize: 12.5)),
              selected: _ttsSource == TtsSource.mimo,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: _narBusy ? null : (_) => _pickTtsSource(TtsSource.mimo),
            ),
            ChoiceChip(
              label: Text(context.tr('MiniMax（多音色·需 Key）'),
                  style: const TextStyle(fontSize: 12.5)),
              selected: _ttsSource == TtsSource.minimax,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: _narBusy ? null : (_) => _pickTtsSource(TtsSource.minimax),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            switch (_ttsSource) {
              // 如实说明：这是唯一"零 Key"的云端替代，但要下一次模型，而且音色偏机械。
              TtsSource.local => context.tr('完全在本机算出来的配音：**不用联网、不用任何 Key、免费**。'
                  '代价要说清：① 第一次要**下一次模型**（31.5 MB，装好后占约 32 MB 磁盘）；'
                  '② 音色**比云端机械**（多说话人离线模型就是这样）；'
                  '③ 手机上的实际速度**还没在真机上量过**。'),
              // ⚠️ 这里**不能**写"任何设备都能用"：2026-10-12 真机反馈第 2/3 条 ——
              //    用户的手机（nubia NX809J / Android 16）**一个 TTS 引擎都没有**，
              //    于是口播和短剧的配音"完全无法使用"。系统配音确实是零配置，但
              //    "零配置"≠"一定有"。如实说清 + 给两条能走通的路。
              TtsSource.system => context.tr('用手机自带的语音朗读：零配置、免费、可离线。'
                  '⚠️ **但不是每台手机都装了语音引擎或中文语音包** —— 遇到"没有可用的文字转语音引擎"时，'
                  '下面两条路任选：① 去系统设置里装一个引擎并下载中文语音包；'
                  '② 改用 MiMo 或 MiniMax（都要一个 API Key，见下）。'),
              TtsSource.mimo => context.tr('MiMo 的音色更自然，但**需要**你在「设置 → 云端大模型 → MiMo」里'
                  '先填一个 API Key（`tp-` 开头的套餐 Key 会自动走套餐端点）。'
                  '它出的是 wav（官方文档的格式），语速只能靠指令描述、所以只给三档。'),
              TtsSource.minimax => context.tr('MiniMax 出 mp3、语速是真正的倍率，音色可以**从你的账号里拉取**'
                  '（官方接口现拉，不是我们编的清单）。**需要**你在「设置 → 云端大模型 → MiniMax」里先填 API Key。'),
            },
            style: TextStyle(
                color: DshColors.textFaint, fontSize: 11, height: 1.45),
          ),
          if (_ttsSource == TtsSource.system)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _narBusy
                    ? null
                    : () => setState(() => _ttsSource = TtsSource.mimo),
                child: Text(context.tr('这台手机没有语音引擎？改用 MiMo（需 Key）'),
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          if (_ttsSource == TtsSource.local) ...<Widget>[
            const SizedBox(height: 10),
            _localTtsBlock(),
          ],
          if (_ttsSource != TtsSource.system && _ttsSource != TtsSource.local) ...<Widget>[
            const SizedBox(height: 10),
            _voicePicker(),
            const SizedBox(height: 6),
            _speedPicker(),
            const SizedBox(height: 4),
            Text(
              _ttsSource == TtsSource.mimo
                  ? context.tr('MiMo 的官方接口没有数值语速参数，所以这三档是拼进风格指令里的'
                      '（「语速放慢一些」这类），效果由模型理解。')
                  : context.tr('语速是发给 MiniMax 的倍率（1.00× 为原速）。'
                      '音色列表拉不到也不影响用：默认音色照样能配。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 10.5, height: 1.45),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _narBusy ? null : widget.onOpenSettings,
                child: Text(context.tr('去设置里填 Key'),
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ],
      );

  /// 单张图的行（形象图）。
  Widget _singleImageRow({
    required String label,
    required String? path,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(label,
          style: TextStyle(
              color: DshColors.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Row(children: <Widget>[
        if (path != null)
          Stack(children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
              child: Image.file(File(path),
                  width: 56, height: 56, fit: BoxFit.cover),
            ),
            Positioned(
              right: -6,
              top: -6,
              child: IconButton(
                iconSize: 16,
                icon: const Icon(Icons.cancel, color: Colors.white70),
                onPressed: _narBusy ? null : onClear,
              ),
            ),
          ])
        else
          OutlinedButton.icon(
            onPressed: _narBusy ? null : onPick,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: Text(context.tr('选一张图')),
          ),
      ]),
    ]);
  }

  /// 把一句话交给某个「专家」扩写，然后**填进当前正在编辑的那个框**。
  Future<void> _expandExpert(PromptExpert expert) async {
    final ctl = _seg == 4 ? _dramaCtl : (_seg == 3 ? _talkCtl : _imgCtl);
    final input = ctl.text.trim();
    if (input.isEmpty) {
      _toast(context.tr('先写一句大概的想法，我再帮你写专业。'));
      return;
    }
    _toast(context.tr('正在让「{0}」写…', <Object?>[expert.name]));
    final cfg = ConfiguredModels.readConfig(widget.runtime.filesDir);
    final r = await expandPrompt(expert: expert, input: input, cfg: cfg);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? context.tr('扩写失败。'), long: true);
      return;
    }
    ctl.text = r.text!;
    _toast(context.tr('写好了，可以直接改或直接生成。'));
  }

  void _cancelNarration() {
    _narCancel = true;
    _narProc?.kill();
    _toast(context.tr('已取消。'));
  }

  /// 口播 / 短剧的**同一条流水线**（只差"镜从哪来"）。
  ///
  /// 逐镜：配音（MiMo TTS）→ 画面（形象图 / 或按该行用生图）→ 字幕画在画面上 →
  /// 最后交给 `make-narration.mjs` 合成。字幕**必须**在 App 侧画（见
  /// `data/subtitle_frame.dart` 的说明：随包 ffmpeg 没有 subtitles/drawtext 滤镜）。
  Future<void> _runNarration({required bool drama}) async {
    final ctl = drama ? _dramaCtl : _talkCtl;
    final raw = ctl.text.trim();
    if (raw.isEmpty) {
      _toast(context.tr(drama ? '先写几个镜头（一行一个）。' : '先把要念的稿子写进来。'));
      return;
    }
    // 口播：自动分段；短剧：一行一镜（空行跳过）
    final segments = drama
        ? raw
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList()
        : NarrationSegmenter.split(raw);
    if (segments.isEmpty) {
      _toast(context.tr('没有可用的内容。'));
      return;
    }
    final (w, h) = _narPixels;
    final baseImage = drama ? _dramaImage : _talkImage;
    // ⚠️ 下面要连续 await（配音/生图/渲染/合成），而每一镜都要报进度文案。
    //    这里**先把文案取出来**：既避开"await 之后用 context"的问题，
    //    也避免"页面已经被回收还去读 context"。
    final tDubbing = context.tr('配音 {0}/{1}：{2}');
    final tPicture = context.tr('画第 {0}/{1} 镜的画面…');
    final tSubtitle = context.tr('画字幕 {0}/{1}');
    final tCompose = context.tr('合成中…（{0} 镜）');
    final tPicFail = context.tr('第 {0} 镜的画面没生成出来。');
    final tFrameFail = context.tr('第 {0} 镜的字幕帧没渲染出来。');
    final tGeneric = context.tr('生成失败（没有更多信息）。');
    final tNoVoice = context.tr('第 {0} 镜起**跳过配音**（{1}）—— 改成"画面 + 字幕"的静音片继续做完，'
        '后面每一镜都不再尝试配音。');

    setState(() {
      _narBusy = true;
      _narCancel = false;
      _narResult = null;
      _narNoVoiceReason = null;
      _narLog = <String>[];
      _narStarted = DateTime.now();
      _narElapsed = 0;
    });
    _startNarTick();

    final work = Directory('${_media.rootDir.path}/narration/'
        'run-${DateTime.now().millisecondsSinceEpoch}')
      ..createSync(recursive: true);
    final shots = <Map<String, Object>>[];

    String? failReason;
    // 「这一次没有配音」的原因（一旦置上，后面每一镜都不再尝试配音）。
    String? noVoiceReason;
    for (var i = 0; i < segments.length; i += 1) {
      if (_narCancel) {
        failReason = null;
        break;
      }
      final text = segments[i];
      final n = segments.length;
      // ① 配音
      //
      // ⚠️ 2026-10-13（用户要求「A 方案」）：**配音失败不再中断整条流程** ——
      //    以前这里是 `failReason = tts.error; break;`，于是"手机没有 TTS 引擎"
      //    这种环境问题会让口播/短剧**彻底不能用**（画面和字幕其实都已经能做了）。
      //    现在第一次失败就记原因，之后每一镜都跳过配音，照样出"画面 + 字幕"的静音片，
      //    并在结果卡上明确写出原因（`_narNoVoiceReason`）。
      //    合成器本来就支持静音镜：`make-narration.mjs` 里 `audio` 可省，
      //    缺的时候就按 `shot.seconds` 走（见那个脚本的注释）。
      String? audio;
      if (noVoiceReason == null) {
        _narLogAdd(_fill(tDubbing, <Object?>['${i + 1}', '$n', _short(text)]));
        // 后缀按**这一家真实输出的格式**走：MiniMax 出 mp3，系统/MiMo 出 wav。
        // 写死 `.wav` 会让 mp3 顶着 wav 后缀进合成（ffprobe 一般认内容，但不干净，
        // 而且真出问题时排查会先怀疑编码而不是文件名）。
        final audioPath = '${work.path}/seg$i${ttsExtensionFor(_ttsSource)}';
        final tts = await synthesizeSpeech(
          text: text,
          outPath: audioPath,
          source: _ttsSource,
          voice: _ttsVoiceId.isEmpty ? null : _ttsVoiceId,
          speed: _ttsSpeed,
        );
        if (tts.ok) {
          audio = audioPath;
        } else {
          noVoiceReason = tts.error;
          _narLogAdd(_fill(tNoVoice, <Object?>['${i + 1}', tts.error ?? tGeneric]));
        }
      }
      // 这一镜的时长：有配音时合成器会用音频的真实长度（忽略这个值），
      // 没配音时就靠它 —— 所以**总是**带上，别再让静音镜一律 3 秒。
      final seconds = estimateSpeechSeconds(text);
      // ② 画面（短剧 + 开了"每镜生成" → 用生图按该行文本画一张）
      String? picture = baseImage;
      if (drama && _dramaPerShot) {
        _narLogAdd(_fill(tPicture, <Object?>['${i + 1}', '$n']));
        final gen = await _media.generateImage(
          prompt: text,
          size: '1K',
          ratio: _narSize,
          outPath: '${work.path}/pic$i.png',
          model: _imageModel,
        );
        if (!gen.ok) {
          failReason = gen.error ?? _fill(tPicFail, <Object?>['${i + 1}']);
          break;
        }
        picture = gen.file;
      }
      if (_narCancel) {
        failReason = null;
        break;
      }
      // ③ 字幕画在画面上（App 侧，用手机自带中文字体）
      _narLogAdd(_fill(tSubtitle, <Object?>['${i + 1}', '$n']));
      final frame = await SubtitleFrameRenderer.render(
        imagePath: picture,
        text: text,
        width: w,
        height: h,
        outPath: '${work.path}/frame$i.png',
      );
      if (frame == null) {
        failReason = _fill(tFrameFail, <Object?>['${i + 1}']);
        break;
      }
      shots.add(<String, Object>{
        'image': frame,
        if (audio != null) 'audio': audio,
        'seconds': seconds,
      });
    }

    if (failReason == null && !_narCancel && shots.isNotEmpty) {
      // ④ 合成
      _narLogAdd(_fill(tCompose, <Object?>['${shots.length}']));
      final spec = jsonEncode(<String, Object>{
        'size': '${w}x$h',
        'fps': 25,
        'shots': shots,
      });
      final r = await _media.composeNarration(
        specJson: spec,
        onLog: (line) => _narLogAdd(line),
        onProcess: (p) => _narProc = p,
      );
      _narProc = null;
      if (!mounted) return;
      setState(() {
        _narBusy = false;
        _narResult = r;
        _narNoVoiceReason = noVoiceReason;
      });
      if (r.ok) {
        _reloadItems();
        _toast(context.tr('生成好了，已放进「作品」。'));
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _narBusy = false;
      _narResult = _narCancel
          ? null
          : MediaResult(
              ok: false,
              exitCode: 1,
              log: '错误：${failReason ?? tGeneric}',
            );
    });
  }

  void _startNarTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _narElapsed = DateTime.now().difference(_narStarted!).inSeconds;
      });
    });
  }

  void _narLogAdd(String line) {
    if (!mounted) return;
    setState(() {
      final next = <String>[..._narLog, line];
      _narLog = next.length > 40 ? next.sublist(next.length - 40) : next;
    });
  }

  static String _short(String s) => s.length <= 18 ? s : '${s.substring(0, 18)}…';

  /// 把已经取好的译文模板里的 `{0}`/`{1}`… 填上（与 i18n 的占位符规则一致）。
  static String _fill(String template, List<Object?> args) {
    var out = template;
    for (var i = 0; i < args.length; i++) {
      out = out.replaceAll('{$i}', '${args[i]}');
    }
    return out;
  }

  Widget _narrationProgress() {
    if (_narBusy) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.line, width: 0.8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text(context.tr('已等 {0}', <Object?>[_hms(_narElapsed)]),
                style: TextStyle(color: DshColors.text, fontSize: 12.5)),
            const Spacer(),
            TextButton(onPressed: _cancelNarration, child: Text(context.tr('取消'))),
          ]),
          const SizedBox(height: 4),
          Text(
            context.tr('配音 + 画字幕 + 合成都在手机上做，镜数多会比较慢，别急。'),
            style: TextStyle(color: DshColors.textFaint, fontSize: 11, height: 1.4),
          ),
          if (_narLog.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            // 让人看见"卡在哪一步"：最近三行
            for (final line in _narLog.length <= 3
                ? _narLog
                : _narLog.sublist(_narLog.length - 3))
              Text(line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: DshColors.textDim, fontSize: 11)),
          ],
        ]),
      );
    }
    final r = _narResult;
    if (r == null) return const SizedBox.shrink();
    // ⚠️ 没有配音时，**结果卡上方必须有一条明确的横幅**（2026-10-13 A 方案）：
    //    我们选择"没有配音也把片子做出来"，那就有义务让用户一眼看出"这条是静音片"，
    //    而不是拿到一个不出声的视频还以为配音坏了。横幅里同时给出**下一步怎么办**。
    final noVoice = _narNoVoiceReason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (r.ok && noVoice != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: DshColors.err.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
              border: Border.all(color: DshColors.err.withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.volume_off_outlined, size: 16, color: DshColors.err),
                    const SizedBox(width: 6),
                    Text(context.tr('这一条**没有配音**'),
                        style: TextStyle(
                            color: DshColors.err,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  context.tr('原因：{0}\n画面和字幕都在；每一镜的时长是按文字长度**估**的。'
                      '想要声音就改用 MiMo 或 MiniMax（各填一个 Key）再生成一次。',
                      <Object?>[noVoice]),
                  style: TextStyle(
                      color: DshColors.textDim, fontSize: 11.5, height: 1.5),
                ),
              ],
            ),
          ),
        // 复用生图/生视频那个结果卡片（它按后缀判断是图还是视频）
        _progressOrResult(
          busy: false,
          elapsed: _narElapsed,
          log: _narLog,
          result: r,
          patientNote: null,
          onCancel: _cancelNarration,
          onRetry: () => _runNarration(drama: _seg == 4),
        ),
      ],
    );
  }

  /// 选图 → 填到"形象图"（口播/短剧各一个）。
  Future<void> _pickInto({required bool forTalk}) async {
    await widget.settings.setPickInFlight(true, from: 'media');
    try {
      final path = await DshHost.pickAttachment('media');
      if (path == null || !mounted) return;
      final lower = path.toLowerCase();
      const ok = <String>['.jpg', '.jpeg', '.png', '.webp', '.bmp'];
      if (!ok.any(lower.endsWith)) {
        _toast(context.tr('只能选图片。'));
        return;
      }
      setState(() {
        if (forTalk) {
          _talkImage = path;
        } else {
          _dramaImage = path;
        }
      });
    } catch (e) {
      if (mounted) _toast(context.tr('选图失败：{0}', <Object?>['$e']));
    } finally {
      // 同上：回来就清，别让它留到下一次重建。
      await widget.settings.setPickInFlight(false);
    }
  }

  Widget _galleryTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return _empty(
        icon: Icons.photo_library_outlined,
        title: context.tr('还没有作品'),
        desc: context.tr('在「生图」或「生视频」里生成一个，它会自动出现在这里。'),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _reloadItems(),
      child: CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    context.tr('这里汇集了**所有生成过的图片和视频**：「影视」页生成的、'
                        '以及会话里生成的一起收在这里，不用记是谁生成的。'),
                    style: TextStyle(
                        color: DshColors.textFaint, fontSize: 11, height: 1.45),
                  ),
                  if (_truncated) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      context.tr('太多了，只显示最新的 {0} 个；更早的可在「资料库」里按文件看。',
                          <Object?>['${MediaService.maxItems}']),
                      style: TextStyle(
                          color: DshColors.accent, fontSize: 11, height: 1.45),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.82,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final item = _items[i];
                return GestureDetector(
                  onTap: () => _preview(item),
                  onLongPress: () => _itemSheet(item),
                  child: Container(
                    decoration: BoxDecoration(
                      color: DshColors.surface,
                      borderRadius: BorderRadius.circular(DshMetrics.radius(12)),
                      border: Border.all(color: DshColors.line, width: 0.8),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(children: <Widget>[
                      Expanded(
                        child: Stack(fit: StackFit.expand, children: <Widget>[
                          item.kind == MediaKind.image
                              ? Image.file(File(item.path),
                                  fit: BoxFit.cover, width: double.infinity)
                              : Container(
                                  width: double.infinity,
                                  color: Colors.black26,
                                  child: const Center(
                                      child: Icon(Icons.movie,
                                          size: 34, color: Colors.white70)),
                                ),
                          // 来源角标：统一总库之后，"这张是哪来的"是用户第一个疑问。
                          Positioned(
                            left: 6,
                            top: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(DshMetrics.radius(6)),
                              ),
                              child: Text(
                                item.source == MediaSource.studio
                                    ? context.tr('来自影视')
                                    : context.tr('来自会话'),
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 10),
                              ),
                            ),
                          ),
                        ]),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                        child: Row(children: <Widget>[
                          Expanded(
                            child: Text(item.timeLabel,
                                style: TextStyle(
                                    color: DshColors.textDim, fontSize: 11)),
                          ),
                          Text(item.sizeLabel,
                              style: TextStyle(
                                  color: DshColors.textFaint, fontSize: 10)),
                        ]),
                      ),
                    ]),
                  ),
                );
              },
              childCount: _items.length,
            ),
          ),
        ],
      ),
    );
  }

  void _itemSheet(MediaItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          ListTile(
            leading: Icon(item.kind == MediaKind.image
                ? Icons.image_outlined
                : Icons.movie_outlined),
            title: Text(item.fileName),
            subtitle: Text(
                '${item.sizeLabel} · ${item.timeLabel} · '
                '${item.source == MediaSource.studio ? context.tr('来自影视') : context.tr('来自会话')}'),
          ),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: Text(context.tr('分享 / 保存到相册')),
            subtitle: Text(context.tr('选「保存图片/视频」即可存进相册'),
                style: TextStyle(color: DshColors.textFaint, fontSize: 11)),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_shareItem(item));
            },
          ),
          if (item.kind == MediaKind.video)
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text(context.tr('用手机上的播放器打开')),
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(_openItem(item));
              },
            ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: DshColors.err),
            title: Text(context.tr('删除'),
                style: TextStyle(color: DshColors.err)),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_deleteItem(item));
            },
          ),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────── 小组件

  Widget _promptField({
    required TextEditingController controller,
    required String hint,
    required VoidCallback onExpand,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      TextField(
        controller: controller,
        minLines: 3,
        maxLines: 6,
        textInputAction: TextInputAction.newline,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: DshColors.textFaint, fontSize: 13),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onExpand,
          icon: const Icon(Icons.auto_awesome, size: 16),
          label: Text(context.tr('写专业点（一句话也行）')),
        ),
      ),
    ]);
  }

  Widget _chips({
    required String label,
    required List<String> choices,
    required String selected,
    required void Function(String) onSelect,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(label,
          style: TextStyle(
              color: DshColors.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: <Widget>[
          for (final c in choices)
            ChoiceChip(
              label: Text(c, style: const TextStyle(fontSize: 12.5)),
              selected: c == selected,
              // 手机上的 chip 要够大才好点（默认最小 32 高，这里给 40）。
              materialTapTargetSize: MaterialTapTargetSize.padded,
              visualDensity: VisualDensity.comfortable,
              onSelected: (_) => onSelect(c),
            ),
        ],
      ),
    ]);
  }

  Widget _refRow() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(context.tr('参考图（可选，最多 4 张）'),
          style: TextStyle(
              color: DshColors.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      SizedBox(
        height: 62,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: <Widget>[
            for (var i = 0; i < _refs.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                    child: Image.file(File(_refs[i]),
                        width: 56, height: 56, fit: BoxFit.cover),
                  ),
                  Positioned(
                    right: -6,
                    top: -6,
                    child: IconButton(
                      iconSize: 16,
                      icon: const Icon(Icons.cancel, color: Colors.white70),
                      onPressed: () => setState(() => _refs.removeAt(i)),
                    ),
                  ),
                ]),
              ),
            if (_refs.length < 4)
              OutlinedButton(
                onPressed: () => _pick(forRef: true),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(56, 56),
                    padding: EdgeInsets.zero),
                child: const Icon(Icons.add_photo_alternate_outlined),
              ),
          ],
        ),
      ),
    ]);
  }

  Widget _firstFrameRow() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(context.tr('首帧图（可选：给了就是图生视频）'),
          style: TextStyle(
              color: DshColors.textDim,
              fontSize: 11.5,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Row(children: <Widget>[
        if (_firstFrame != null)
          Stack(children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
              child: Image.file(File(_firstFrame!),
                  width: 56, height: 56, fit: BoxFit.cover),
            ),
            Positioned(
              right: -6,
              top: -6,
              child: IconButton(
                iconSize: 16,
                icon: const Icon(Icons.cancel, color: Colors.white70),
                onPressed: () => setState(() => _firstFrame = null),
              ),
            ),
          ])
        else
          OutlinedButton.icon(
            onPressed: () => _pick(forRef: false),
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: Text(context.tr('选首帧图')),
          ),
      ]),
    ]);
  }

  Widget _bigButton({
    required bool busy,
    required String label,
    required VoidCallback onTap,
    required VoidCallback onCancel,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: busy
          ? OutlinedButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: Text(context.tr('取消生成')),
            )
          : FilledButton.icon(
              onPressed: onTap,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(label),
            ),
    );
  }

  Widget _progressOrResult({
    required bool busy,
    required int elapsed,
    required List<String> log,
    required MediaResult? result,
    required String? patientNote,
    required VoidCallback onCancel,
    required VoidCallback onRetry,
  }) {
    if (busy) {
      // 生成中：已等多久 + 最近一行（脚本原话，比"处理中"有用）。
      final last = log.isEmpty ? '' : log.last;
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.line, width: 0.8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text(context.tr('已等 {0}', <Object?>[_hms(elapsed)]),
                style: TextStyle(color: DshColors.text, fontSize: 12.5)),
            const Spacer(),
            TextButton(
                onPressed: onCancel, child: Text(context.tr('取消'))),
          ]),
          if (patientNote != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(patientNote,
                style: TextStyle(
                    color: DshColors.textFaint, fontSize: 11, height: 1.4)),
          ],
          if (last.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(last,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: DshColors.textDim, fontSize: 11)),
          ],
        ]),
      );
    }
    final r = result;
    if (r == null) return const SizedBox.shrink();
    if (r.ok) {
      final f = File(r.file!);
      final isImage = r.file!.toLowerCase().endsWith('.png') ||
          r.file!.toLowerCase().endsWith('.jpg') ||
          r.file!.toLowerCase().endsWith('.webp');
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: DshColors.surface,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          border: Border.all(color: DshColors.line, width: 0.8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(context.tr('生成好了'),
              style: TextStyle(
                  color: DshColors.accent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
              child: Image.file(f, fit: BoxFit.contain),
            )
          else
            Row(children: <Widget>[
              const Icon(Icons.movie, size: 20, color: Colors.white70),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    context.tr('视频已生成：{0}', <Object?>[
                      '${((r.bytes ?? f.lengthSync()) / 1024 / 1024).toStringAsFixed(1)} MB'
                    ]),
                    style: TextStyle(color: DshColors.text, fontSize: 12.5)),
              ),
            ]),
          const SizedBox(height: 10),
          Row(children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => DshHost.shareFile(r.file!),
                icon: const Icon(Icons.ios_share, size: 17),
                label: Text(context.tr('分享 / 保存')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 17),
                label: Text(context.tr('再来一次')),
              ),
            ),
          ]),
        ]),
      );
    }
    // 失败：显示脚本的**原话**（它通常已经说清了怎么办），并给一个重试。
    final err = r.cancelled
        ? context.tr('已取消。')
        : (r.error ?? context.tr('生成失败（没有更多信息）。'));
    final needKey = err.contains('Key') || err.contains('密钥');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DshColors.surface,
        borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
        border: Border.all(color: DshColors.err.withValues(alpha: 0.5), width: 0.8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(context.tr('没成功'),
            style: TextStyle(
                color: DshColors.err,
                fontSize: 12.5,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(err,
            style: TextStyle(color: DshColors.textDim, fontSize: 11.5, height: 1.45)),
        if (needKey) ...<Widget>[
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: widget.onOpenSettings,
            icon: const Icon(Icons.key_outlined, size: 16),
            label: Text(context.tr('去「设置 → 模型」填 Key')),
          ),
        ],
        const SizedBox(height: 8),
        Row(children: <Widget>[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 17),
              label: Text(context.tr('再试一次')),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _empty({
    required IconData icon,
    required String title,
    required String desc,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Icon(icon, size: 42, color: DshColors.textFaint),
          const SizedBox(height: 12),
          Text(title,
              style: TextStyle(
                  color: DshColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(desc,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 12, height: 1.5)),
        ]),
      ),
    );
  }
}
