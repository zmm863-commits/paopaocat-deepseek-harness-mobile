import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'expert_catalog.dart';
import 'atomic_file.dart';

/// 「哪些专家已开启」的状态 + 真的把效果写进 DSH 的配置。
///
/// ## 状态存在哪
/// `$DSH_HOME/experts.json` —— App 自己拥有的开关状态（`{"enabled":["slug", ...]}`）。
/// 落盘，重启 App 后仍然生效。
///
/// ## 效果是怎么"真起作用"的（这一点必须说清楚）
/// 手机运行时里**没有** `@michengai/dsh-agency-agents` 插件，所以**无法**写回插件的
/// `enabledExperts`。但 DSH 从 `dsh-base` bundle 起就默认挂载了内置插件
/// `@deepseek-ai/dsh-agent-instructions`，它会把 **`$DSH_HOME/AGENTS.md`**
/// 作为「用户全局指令」在**每个会话第一个请求之前**渲染进 agent 上下文
/// （见该插件 `lib/index.js` 里的 `USER_GLOBAL_FILE = "AGENTS.md"`，
/// 以及 `dsh-base/cordis.patch.yml` 的 `agent-instructions` 挂载项，`maxBytes: 65536`）。
///
/// 所以本类做的第二件事是：把**已开启专家**的名称 + 简介 + 核心使命摘要，
/// 写进 `$DSH_HOME/AGENTS.md` 里一段带标记的受管区块。
/// 于是：
///   - 开启 → 模型在下一轮新会话里真的会看到这名专家的角色设定；
///   - 关闭 → 该段被移除，模型看不到。
/// 这不是"只改 UI 状态"的假开关，也不是"远程召唤"，而是一条**可验证的真实链路**：
/// 文件落在设备上，DSH 的内置插件读它，模型的上下文里有它。
///
/// ## 需要在界面上讲清楚的时序
/// `AGENTS.md` 与技能目录都是在**会话开始时**读取的，所以对**已经打开的会话**不生效。
/// 界面上要提示"新建一个会话后生效"。
class ExpertStore extends ChangeNotifier {
  ExpertStore({required this.dshHome});

  /// 设备的 `DSH_HOME`（Android 上 = `<filesDir>/dshhome`）。
  final String dshHome;

  static const String _stateFile = 'experts.json';

  /// 受管区块的标记。只动这两个标记之间的内容，`AGENTS.md` 里其它内容一律保留。
  static const String blockBegin =
      '<!-- dsh-mobile:enabled-experts:begin（由 App 生成，请勿手改；开关变化会重写这一段）-->';
  static const String blockEnd = '<!-- dsh-mobile:enabled-experts:end -->';

  /// 单批上限对齐 `dsh-base` 里 `agent-instructions` 的 `maxBytes: 65536`，
  /// 留一点余量给用户自己的内容与标题。
  static const int _budgetBytes = 60000;

  final Set<String> _enabled = <String>{};
  bool _loaded = false;

  /// 已开启专家的 slug（无序；展示时按目录顺序排）。
  Set<String> get enabledSlugs => Set.unmodifiable(_enabled);

  int get enabledCount => _enabled.length;

  bool get loaded => _loaded;

  bool isEnabled(String slug) => _enabled.contains(slug);

  /// App 自己的开关状态文件。
  String get statePath => '$dshHome/$_stateFile';

  /// DSH 内置 `agent-instructions` 读的**用户全局**指令文件。
  String get agentsMdPath => '$dshHome/AGENTS.md';

  /// 从磁盘读回开关状态。文件不存在 = 一个都没开（不是错误）。
  Future<void> load() async {
    try {
      final f = File(statePath);
      if (f.existsSync()) {
        final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final list = map['enabled'];
        if (list is List) {
          for (final e in list) {
            if (e is String && e.trim().isNotEmpty) _enabled.add(e.trim());
          }
        }
      }
      debugPrint('[dsh-expert] 开关状态已载入：${_enabled.length} 名开启（$statePath）');
    } catch (e) {
      debugPrint('[dsh-expert] 读取开关状态失败（按"全关"处理）：$e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 启用 / 停用一名专家并立刻落盘 + 重写 AGENTS.md。
  ///
  /// ⚠️ **本轮改成单选**（用户实测反馈）：
  /// 「专家打开开关后会话页面可以看到专家，但是有个问题，五个开关就有五个专家，
  ///   这个地方不是应该是单选吗，否则会话注入五个专家是不是会乱的」
  ///
  /// 他的判断是对的：`AGENTS.md` 是**每个会话都会读**的全局指令，
  /// 把多个人设一起塞进去会互相打架（"你是医生"和"你是律师"同时生效）。
  /// 所以这里语义等同单选按钮 —— **开一个就自动关掉其它的**。
  ///
  /// 返回 `null` 表示成功，否则是给用户看的中文错误。
  Future<String?> setEnabled(String slug, bool on) async {
    // 单选语义下，一次开关可能同时影响两名专家（新开的 + 被自动关掉的），
    // 所以先拍快照；写盘失败时整体回滚，避免"界面开着、磁盘上没写"的错觉。
    final before = Set<String>.from(_enabled);
    if (on) {
      if (_enabled.length == 1 && _enabled.contains(slug)) return null;
      // 单选：先清掉别人，再放它进来
      _enabled
        ..clear()
        ..add(slug);
    } else {
      if (!_enabled.remove(slug)) return null;
    }
    notifyListeners();
    final err = await _flush();
    if (err != null) {
      _enabled
        ..clear()
        ..addAll(before);
      notifyListeners();
    }
    return err;
  }

  /// 一次性清空所有开关。
  Future<String?> clearAll() async {
    if (_enabled.isEmpty) return null;
    _enabled.clear();
    notifyListeners();
    return _flush();
  }

  Future<String?> _flush() async {
    try {
      final dir = Directory(dshHome);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await writeStringAtomic(
        File(statePath),
        '${const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
              'enabled': (_enabled.toList()..sort()),
              'updatedAt': DateTime.now().toIso8601String(),
            })}\n',
      );
    } catch (e) {
      debugPrint('[dsh-expert] 写开关状态失败：$e');
      return '写入开关状态失败：$e';
    }
    return _writeAgentsMd();
  }

  /// 把已开启专家写进 `$DSH_HOME/AGENTS.md` 的受管区块。
  ///
  /// 目录信息来自 [catalog]；拿不到目录（资产没加载）时只写名称，不编造描述。
  Future<String?> _writeAgentsMd({
    ExpertCatalog? catalog,
    List<ExpertEntry>? experts,
  }) async {
    try {
      final list = experts ?? _enabledEntries(catalog);
      final file = File(agentsMdPath);
      final existing = file.existsSync() ? await file.readAsString() : '';
      final kept = _stripBlock(existing).trimRight();
      final block = _renderBlock(list);

      final buffer = StringBuffer();
      if (kept.isNotEmpty) {
        buffer.write(kept);
        buffer.write('\n\n');
      }
      if (block.isNotEmpty) {
        buffer.write(block);
        buffer.write('\n');
      }
      final out = buffer.toString();

      if (out.trim().isEmpty) {
        // 没有任何内容（也没开专家）→ 不留下一个空文件
        if (file.existsSync()) await file.delete();
        debugPrint('[dsh-expert] AGENTS.md 已清空并删除（无开启专家）');
        return null;
      }
      await writeStringAtomic(file, out);
      debugPrint(
        '[dsh-expert] AGENTS.md 已重写：${list.length} 名专家 / ${out.length} 字符 → $agentsMdPath',
      );
      return null;
    } catch (e) {
      debugPrint('[dsh-expert] 写 AGENTS.md 失败：$e');
      return '写入 $agentsMdPath 失败：$e';
    }
  }

  List<ExpertEntry> _enabledEntries(ExpertCatalog? catalog) {
    final c = catalog ?? ExpertCatalogCache.current;
    if (c == null) return const <ExpertEntry>[];
    return [
      for (final e in c.experts)
        if (_enabled.contains(e.slug)) e,
    ];
  }

  /// 供 UI 在切换后用最新目录重写一次（保证 brief 被写进去，而不是只有名字）。
  Future<String?> flushWithCatalog(ExpertCatalog catalog) =>
      _writeAgentsMd(catalog: catalog);

  /// 保证 `AGENTS.md` 里的受管区块**存在**（App 启动时调用一次）。
  ///
  /// 为什么必须在启动时写、而不能等用户去点专家开关：这个区块里还有一段
  /// 「本机可用的执行环境」（见 [ExpertCatalogCache.toolNotes]）—— 模型要
  /// 知道本机有 node、以及怎么生成真 .pptx，否则它会把 PPT 降级成 HTML
  /// （用户实测反馈第 3 条）。从没开过专家的用户也必须拿到这段说明。
  ///
  /// 幂等：区块内容一致时会**跳过写盘**，不产生无谓的 IO 与文件时间戳变化。
  Future<String?> ensureAgentsMd() async {
    try {
      final file = File(agentsMdPath);
      final existing = file.existsSync() ? await file.readAsString() : '';
      final desired = _renderBlock(_enabledEntries(null));
      if (existing.contains(desired.trim())) {
        debugPrint('[dsh-expert] AGENTS.md 受管区块已是最新，跳过写入');
        return null;
      }
    } catch (e) {
      debugPrint('[dsh-expert] 检查 AGENTS.md 失败，改为强制重写：$e');
    }
    return _writeAgentsMd();
  }

  static String _stripBlock(String text) {
    final b = text.indexOf(blockBegin);
    if (b < 0) return text;
    final e = text.indexOf(blockEnd, b);
    if (e < 0) return text.substring(0, b);
    return text.substring(0, b) + text.substring(e + blockEnd.length);
  }

  String _renderBlock(List<ExpertEntry> list) {
    final sb = StringBuffer()
      ..writeln(blockBegin)
      ..writeln()
      // ── 这段「执行环境说明」是无条件写入的（跟开不开专家无关）──────────
      // 为什么必须写：用户实测反馈「我明确要求生成 PPT，但无法生成」，模型
      // 自己探测后回了「这个沙箱里没有任何可执行环境（无 bash / python /
      // pandoc / node）」，然后拿 HTML 幻灯片顶替 PPT。真相是：
      //   * Android 上确实没有 python / pandoc；
      //   * bash 也不是真的 bash（是 `/system/bin/sh`，App 用 shim 顶上的）；
      //   * **但 node 是有的**（App 随包带），而且 App 还带了一个能把 JSON
      //     大纲写成真 .pptx 的脚本。
      // 模型不知道这些就会一直"降级交付"。这段话就是告诉它本机有什么、
      // 该怎么用 —— AGENTS.md 是每个会话开始都会读的全局指令。
      ..writeln('## 本机可用的执行环境（DSH 手机版）')
      ..writeln()
      ..writeln(ExpertCatalogCache.toolNotes)
      ..writeln()
      // ── 语言偏好（用户 2026-10-12：「手机版的思考过程都是英文的，这个怎么回避」
      //     + 追问「是不是随着语言来思考，因为我设了四种语言」）
      //
      // 口径：**跟"用户提问时用的语言"，而不是"界面语言"** —— 界面语言是这台设备
      // 的显示设置，用户完全可能把界面设成日语、却用中文提问（四套界面语言都在用）；
      // 跟提问语言才是"读起来顺"的那一个。
      //
      // ⚠️ 这里**刻意不把语言名写死**（既不是"用中文"，也不是"界面语言是日语"）：
      // 这份受管区块**只在启动时写一次**，用户中途切界面语言它不会自动重写 ——
      // 写死一个语言名，反而会在切换后写错。现在这种"语言无关"的写法，
      // 四套界面语言、以及"界面与提问语言不一致"的情况都不会错。
      //
      // ⚠️ 也要**如实**：思考用哪种语言是模型训练出来的倾向，这条只能"提高概率"，
      // 不能保证 —— 所以 App 侧还给了「设置 → 外观 → 思考过程 → 不显示」这个
      // 唯一能彻底看不到英文思考的办法（见 `AppSettings._kThinkingMode`）。
      // 这里绝不能说"我会用中文思考"，那是替模型打包票。
      ..writeln('## 回答与思考的语言（用户偏好）')
      ..writeln()
      ..writeln('- **用「用户提问时所用的语言」回答**，不要中途换语言。'
          '（设备界面语言是显示设置，用户可能界面设成 A 语言却用 B 语言提问 ——'
          '跟 B。）')
      ..writeln('- **思考/推理过程也请尽量用同一种语言**（用户反馈过：手机上'
          '思考过程常常是英文，读起来很别扭）。')
      ..writeln('- 说明：推理语言由模型自己决定，这条只是一个明确的偏好请求；'
          '若你确实只能用英文推理，请在正式回答里仍然用用户的语言表达。')
      ..writeln();
    if (list.isEmpty) {
      sb.writeln(blockEnd);
      return sb.toString();
    }
    sb
      ..writeln('## 已启用的专家（DSH 手机版「专家」页开启）')
      ..writeln()
      ..writeln('用户在手机上开启了以下专家角色。当任务落在其职责范围内时，'
          '请按该专家的身份与工作方式作答；一次只承担与当前任务相关的角色，'
          '并在回答里说明你正在以哪名专家身份工作。')
      ..writeln();

    var bytes = sb.length;
    var written = 0;
    for (final e in list) {
      final piece = StringBuffer()
        ..writeln('### ${e.name}')
        ..writeln()
        ..writeln('- 职责：${e.description}');
      if (e.brief.isNotEmpty) {
        piece
          ..writeln('- 工作要点：${e.brief.replaceAll('\n', ' ').trim()}')
          ..writeln();
      } else {
        piece.writeln();
      }
      if (bytes + piece.length > _budgetBytes) {
        sb
          ..writeln('（已达 DSH 用户全局指令的 64 KB 上限，其余 '
              '${list.length - written} 名专家未写入；请减少同时开启的专家数量。）')
          ..writeln();
        break;
      }
      sb.write(piece);
      bytes += piece.length;
      written++;
    }
    sb.writeln(blockEnd);
    return sb.toString();
  }
}

/// 目录缓存：`ExpertStore` 里写 AGENTS.md 时需要目录，但目录是异步加载的。
/// 这里放一个进程内引用，避免把 `Future` 传遍整条写盘路径。
class ExpertCatalogCache {
  /// ⚠️ 这个字符串是**原样字符串**（`r'''`）：里面会写 `$DSH_ANDROID_TOOLBOX`
  /// 这类 shell 变量名，不能让它被 Dart 当成字符串插值。
  static const String toolNotes = r'''
这台设备是 **Android**，执行环境跟电脑不一样，动手前先看这一段：

- **没有 bash 的 bash**：`bash -c "..."` 实际由 `/system/bin/sh`（mksh）执行。
  写脚本请用 POSIX sh 语法，**不要**用 bash 专有语法（数组、`[[ ]]`、`<<<`、`${var,,}` 等）。
- **没有 python / pandoc / libreoffice**：不要假设它们存在，也不要试图安装。
- **有 node**：在命令里直接写 `node 脚本.mjs` 就能跑（App 随包带了 node 运行时）。
  只能用 node 内置模块（`node:fs` / `node:zlib` / `node:http` / `node:path` …）；
  **不能 npm install**（这条链路上没有包管理器，也没有可用的网络出口）。
- **有 ffmpeg**（口播 / 短剧的拼接、转码、混音、加字幕都要用它）：
  命令里**直接写 `ffmpeg -i 输入.mp4 ...`** 就能跑（本机给 `ffmpeg` / `ffprobe` 都定义了同名
  shell 函数），也可以用 `$DSH_ANDROID_FFMPEG` / `$DSH_ANDROID_FFPROBE` 的绝对路径；
  桌面端影视工具插件认的变量名 `AGNES_FFMPEG` 这里也对齐了（同一个二进制）。
  编进去的关键能力：**libx264（H.264 编码）**、**aac**，常见容器（mp4 / mov / mkv / webm /
  m4v / gif）与常用滤镜（scale / crop / pad / overlay / concat / fps / format 等）都在。
  ⚠️ **但 `subtitles` / `drawtext` / `ass` 这三个滤镜没有**（精简构建没编 libass/freetype）——
  想加字就写在图片上（见下面"口播/短剧"那条）。
  * **不要**试图安装或下载 ffmpeg；也**不要**用 `ffmpeg -encoders` 之类去"探测能力"——
    直接用它，失败会给出明确报错。
  * 手机性能有限：转码/拼接比电脑慢得多，**长任务要多等**，别中途 kill 重来。
  * 文件路径**一律用绝对路径**（相对路径会随工作目录变化）。
- **要把「一段文稿 + 配音」做成视频（口播/短剧）**：用随包的合成器，不要自己拼 ffmpeg 命令：
  `node "$DSH_ANDROID_TOOLBOX/make-narration.mjs" spec.json 输出.mp4`
  `spec.json` 形状：`{"size":"1080x1920","fps":25,"shots":[{"image":"/绝对路径/0.png","audio":"/绝对路径/0.wav"}]}`
  * `image` 要**已经带字幕**（本机 ffmpeg **没有** subtitles/drawtext 滤镜，烧不了字幕；字幕由
    App 侧绘制，会话里如果非要加字，请在生成图片时就带上文字或改用「影视」页的口播/短剧）。
  * `audio` 可以省略（那一镜按 `seconds` 或默认 3 秒的静音处理）。
  * ⚠️ **你（会话里的模型）没有文字转语音的能力**：配音要么来自用户在
    「影视 → 口播/短剧」页里生成的音频（那里用手机自带的 TTS 或 MiMo），
    要么是用户给你的现成音频文件。**不要**假装能配音、也不要编一个音频链接。
  * 每镜的时长由脚本用 ffprobe 探出配音真实时长后 `-t` 精确控制（**不要**指望 `-shortest`）。
  * 单镜编码用 `veryfast`（手机要快）；长任务要有耐心。
- **要「修图 / 调色 / 去水印」（只动一张已有图，不重画）**：用随包的本机滤镜脚本，**不要**
  用 `make-image.mjs --ref` 去"重画一版"（那会连别处一起改，而且它不知道水印下面是啥）：
  `node "$DSH_ANDROID_TOOLBOX/edit-image.mjs" 原图.png 输出.png [--preset none|fresh|cinema|skin|warm|cool] [--strength 1-100] [--delogo x:y:w:h]`
  * **选哪个**：换风格/换主体/多图合成 → `make-image.mjs --ref`（联网、走 Agnes）；
    调色锐化磨皮、把水印那一块盖住 → 这个脚本（本机、秒级、不联网、不花额度）。
  * `--delogo` 是**像素**框，靠"用周围像素盖住"实现；**不是恢复原内容**，
    复杂纹理背景会留痕迹 —— 对用户要这么说，不要承诺"能还原"。
  * 先跑 `--help` 看全部档位；它自己会用 `ffmpeg -filters` 自检滤镜，缺了会如实报错。
- **要在已有的视频上"剪一刀"（剪一段 / 拼接 / 抽音频 / 抽一帧 / 压小）**：用随包的
  `clip-video.mjs`，**不要**自己拼 ffmpeg 参数（`-ss`/`-t`/concat 清单的写法很容易配错，
  而配错了会"成功"地产出一个静音或错位的片子）：
  * 剪一段：`node "$DSH_ANDROID_TOOLBOX/clip-video.mjs" trim 输入.mp4 输出.mp4 --start 0:05 [--end 1:20] [--exact]`
  * 拼接：`node "$DSH_ANDROID_TOOLBOX/clip-video.mjs" concat 输出.mp4 段1.mp4 段2.mp4 [段3.mp4 ...] [--reencode]`
  * 抽音频：`node "$DSH_ANDROID_TOOLBOX/clip-video.mjs" audio 输入.mp4 输出.m4a`
  * 抽一帧当封面：`node "$DSH_ANDROID_TOOLBOX/clip-video.mjs" frame 输入.mp4 封面.jpg [--at 0:03]`
  * 压小：`node "$DSH_ANDROID_TOOLBOX/clip-video.mjs" compress 输入.mp4 输出.mp4 [--max-width 1280] [--crf 28]`
  * 先探信息：`... probe 输入.mp4`（会多打一行 `[clip] json={…}`，带时长/分辨率/有无音轨）。
  * 时间写法：`90`（秒）、`1:30`（分:秒）、`0:01:30`（时:分:秒）。
  * **如实说明两条边界**（用户会碰到）：① 不加 `--exact` 时走 `-c copy`、几乎瞬间完成，
    但剪的位置**对齐到最近的关键帧**（可能差零点几秒到一两秒）；② 拼接要求几段参数一致，
    不一致时脚本会**直接报错**并让你加 `--reencode`（它不会硬拼 —— 硬拼的成品画面会中途变形）。
  * 输出前缀 `[clip] ok file=… bytes=… seconds=… op=…`（成功）/ `错误：…`（失败）。
- **要读写 Excel 表格（.xlsx）**：本机**没有 python / openpyxl / pandas**，
  但 xlsx 的本质就是 **ZIP + XML**，所以随包带了两个脚本（纯 node，只用内置模块）：
  * **读**：`node "$DSH_ANDROID_TOOLBOX/read-xlsx.mjs" 表.xlsx [--format csv|json] [--sheet 名字或序号] [--out 输出] [--list]`
    —— 读到之后**继续用 node/CSV 那套处理**，不要再去为难用户"请你自己另存为 CSV"。
    如实说明它的边界：**不解析公式**（读的是上次算好的值）、**日期会是序列号**（不换算）、
    不读合并单元格/图表/批注。
  * **写**：`node "$DSH_ANDROID_TOOLBOX/make-xlsx.mjs" 输入.csv|json 输出.xlsx [--sheet 名字] [--delimiter ,] [--no-header]`
    —— 用户要"能直接发出去的表格"就给 .xlsx（纯数字写成数字，`007` 这种前导零的一律保持文本）。
  * 两个脚本都只做"值"层面的事：**不做**公式、图表、条件格式、多工作表（要如实说做不到）。
  * 输出前缀是 `[xlsx] ok ...`（成功）/ `错误：…`（失败），按这个认结果。
- **要交 Word 文档（.docx）**：`node "$DSH_ANDROID_TOOLBOX/make-docx.mjs" 文档.md 输出.docx [--title "标题"]`
  —— 支持 Markdown 子集：`#`~`######` 标题、段落、`-`/`1.` 列表、`> ` 引用、
  ``` 代码块、`| a | b |` 真表格、`---` 分隔线、行内 `**粗**`/`*斜*`/`` `等宽` ``。
  **别再说"docx 做不到"**（那是 0.71 之前的限制）。标题写的是**真的标题样式**
  （Word 的导航窗格/大纲视图/自动目录都能用），列表是**真的项目符号与编号**
  （在 Word 里插一条会自动重编号 —— 所以 Markdown 里原来写的序号不保留，要如实说）。
  其它边界：不支持图片/页眉页脚/目录/公式/批注。
  输出前缀 `[docx] ok paragraphs=… tables=… bytes=… out=…`。
- **要读 Word 文档（.docx）**：`node "$DSH_ANDROID_TOOLBOX/read-docx.mjs" 文档.docx [--format md|txt|json] [--out 输出] [--extract-images 目录]`
  —— 读出**正文**（默认 Markdown），所以**不要再让用户"把正文粘贴过来"或"另存为 .txt"**。
  它能认出样式表里的标题层级、`numbering.xml` 里的项目符号与编号、超链接，
  以及表格（合并单元格按列补空）。如实说明这些边界：**只读正文**
  （页眉/页脚/脚注/批注都不读）；图片**默认只标注不抽**（给 `--extract-images` 才写出来）；
  代码块的语言标记（```sh 里的 sh）不保留；其它编号格式（罗马数字/字母）一律按顺序号输出。
  输出前缀 `[docx] ok op=read paragraphs=… tables=… images=… out=…`。
- **要做 PPT/幻灯片**：不要手写 `.pptx`（它是二进制 ZIP 包，纯文本写入工具写不出来），
  也不要用 python-pptx / pandoc（都没有）。本机自带一个转换脚本：把大纲写成 JSON，再跑
  `node "$DSH_ANDROID_TOOLBOX/make-pptx.mjs" outline.json 输出.pptx`
  `outline.json` 的形状：
  `{"title": "封面标题", "subtitle": "可选副标题", "theme": "ink", "slides": [{"layout": "bullets", "title": "小节标题", "bullets": ["要点1", "要点2"], "notes": "可选演讲者备注"}]}`
  **排版不用你算**：坐标/字号/分栏/放不下时怎么缩怎么分页都由脚本算，你不要写这些字段。
  每页用 `layout` 选版式（`section` 章节页 / `toc` 目录 / `bullets` 要点 / `cards` 并列几件事 /
  `timeline` 流程 / `compare` 两栏对比 / `metrics` 关键数字 / `chart` 数据图 / `quote` 引用 /
  `image` 配图 / `end` 结尾；不写就按内容字段自动猜），`theme` 六选一
  （`ink`/`ocean`/`forest`/`sunrise`/`berry`/`mono`）。完整字段与边界见技能 `make-slides`。
  生成后把**文件路径**告诉用户。**不要**再用 HTML 幻灯片顶替 PPT（除非用户明确要 HTML）。
- **用户要图片 / 要视频时，直接生成，别只给提示词、更不要假装已经生成**：
  * 文生图：`node "$DSH_ANDROID_TOOLBOX/make-image.mjs" "提示词" 输出.png [--size 2K] [--ratio 16:9] [--ref 参考图URL或本地文件]`
  * 文生视频：`node "$DSH_ANDROID_TOOLBOX/make-video.mjs" "提示词" 输出.mp4 [--seconds 5] [--ratio 16:9]`
  这两个走 **Agnes（免费）**：官方当前把 `agnes-image-2.5-flash`（图像）与
  `agnes-video-2.5-flash`（视频）标为免费（原价 ¥0.07–0.16/张、¥0.15/秒，现价 ¥0；
  这是**当前/限时**优惠，官方注明"免费政策如有调整，以平台最新公告为准"）。
  脚本读环境变量 `AGNES_API_KEY`。**如果没配 Key，脚本会明确报错并给出注册地址** ——
  那时把这句话原样转告用户：去 **https://platform.agnes-ai.cn** 免费注册，
  在控制台「API Keys」创建 `sk-` 开头的密钥，填到 App 的「设置 → 模型 → Agnes（免费）」
  （也可以由用户在会话里把 Key 给你，但**不要**把 Key 写进任何产物文件或日志）。
  别退化成"那我给你写个提示词吧"，也不要自己编一个图片链接糊弄。
  视频是**异步任务**：脚本会自己提交并轮询（通常几十秒到几分钟），请等它返回结果，
  **不要在轮询期间反复重新提交**（会重复排队）。
- **要改「已经存在的」xlsx / docx（不是新建）**：会话里挂着一个**本机 MCP 服务器**
  （名字 `dsh-office`，stdio，本机跑、不联网），它有三个工具，**优先用它们**：
  * `office_read_cells` —— 读单元格：`{file, sheet?, range?}`（range 形如 `A1:C10`）
  * `office_write_cell` —— 写一个单元格：`{file, cell, value, sheet?}`（cell 形如 `B7`）
  * `office_append_paragraph` —— 往 .docx 正文末尾追加一段：`{file, text, heading?}`
  * 和上面那两条命令行脚本的区别：脚本是**读整个文件 / 另存新文件**；
    这三个工具是**就地改同一个文件**（保留原样式），适合"把 B7 改成 42"这种小改。
  * 如实说明它的边界：**只做值**，不写公式、不算公式、不改样式（写单元格时保留原样式）、
    日期不换算、.docx 只支持追加段落（正文末尾），不做表格/图片/修订。
  * 工具会返回 JSON（`{sheet, cell, previous, now}` 之类）；**改完要把新文件路径告诉用户**。
  * 工具起不来时**不要**反复重试（运行时对 MCP 是 `failOnStartupError`）——
    改用上面的命令行脚本做整文件方案，并如实说明为什么没能就地改。
- 其它命令（`ls` / `cat` / `mkdir` / `rm` / `echo` …）以系统实际提供的为准；
  **不要假装某个命令存在**：执行失败就如实说明缺什么、再换一条可行路径。
- 有用的环境变量：`DSH_ANDROID_TOOLBOX`（工具箱目录）、`DSH_ANDROID_NODE_BIN`（node 可执行文件）、
  `DSH_ANDROID_FFMPEG` / `DSH_ANDROID_FFPROBE`（随包的 ffmpeg / ffprobe，同一份也导出为 `AGNES_FFMPEG`）、
  `AGNES_API_KEY` / `AGNES_BASE_URL` / `AGNES_REGISTER_URL`（内置的 Agnes 免费生图生视频）。
''';

  static ExpertCatalog? current;
}
