import 'package:flutter/material.dart';

import '../../app_version.dart';
import '../../data/builtin_starters.dart';
import '../../state/app_settings.dart';
import '../../state/model_store.dart';
import '../theme/dsh_tokens.dart';
import '../widgets/announce_bar.dart';
import '../widgets/mascot_speech.dart';
import '../widgets/workspace_entry.dart';

import '../../i18n/dsh_i18n.dart';

/// 首页（品牌页）。
///
/// 顶部：`泡泡猫的DSH` + `● 本机 · <当前工作区名>`（纯文本、不可点、无箭头），
/// 右上角是「工作区」入口（图标 + 文字，语义标签 `工作区`）。
/// 中部：品牌区（自绘猫头 + 标语 + 推广文案）、内置会话列表（一次 6 条）、`换一换`。
/// 底部：只留一个「开始新会话」按钮（输入胶囊/箭头/模型按钮都按用户要求去掉了）。
///
/// ## 没有模型时的样子（用户实测反馈第 4 条："首次安装必须进行模型设置，
/// 否则无法点击开始准备"）
///
/// `ModelStore.hasModels == false` 时首页要**一眼看出现在不能开始**，并且点哪里
/// 都不能没反应：
///   * 顶栏下方常驻一条可点提示条「还没有可用模型 · 去设置」；
///   * 「开始新会话」按钮变成置灰色，点它弹说明层（说清"先去设置填一个厂家的
///     地址和 Key"），层里的「去设置」直接切到设置 Tab；
///   * 内置会话条目走同一道闸 —— 否则用户从「做一份幻灯片」进来，
///     一样会掉进那个没有模型的对话页。
/// 配好模型后（[ModelStore] 会通知）这一整块**立刻**恢复正常，不用退出重进。
///
/// ## 纵向节奏（历史交接记录里的坐标基准，机身 1215 x 2640 设计像素）：
///   | 元素 | 设计 y | 屏高 |
///   |---|---|---|
///   | 顶栏标题带 | 163~287 | 6.2%~10.9% |
///   | logo 品牌标 | 377~465 | 14.3%~17.6% |
///   | 标语 | 445~530 | 16.9%~20.1% |
///   | 推广文案 | 518~564 | 19.6%~21.4% |
///   | 中部提示区标题 | 1075~1173 | 40.7%~44.4% |
///   | 功能提示（设计稿 4 条；本轮起是 6 条内置会话） | 1307/1445/1588/1727（**行距 140**） | 49.5%~65.4% |
///   | `换一换` | 1901~1948 | 72.0%~73.8% |
///   | 输入框 `发消息或按住说话` | 2301~2354 | **87.2%~89.2%** |
///   | 底部导航 5 项 | 2567~2610 | 97.2%~98.9% |
///
/// 纵向排布的两条规矩（踩过坑，别改回去）：
///   * 固定层（不滚动）：底部输入区，锚在底部导航之上，胶囊底沿 ≈ 88%；
///   * 滚动层（可滚动）：标题 → 猫头 logo → 标语 → 推广文案 → 中部提示区
///     → `换一换`，所有间距按屏高比例算（见 [_ScrollBody]），会随实际可用
///     高度收缩，保证任何屏高下内容都不超一屏（没有多余滚动与回弹）。
class TaskHomeView extends StatefulWidget {
  const TaskHomeView({
    super.key,
    required this.onOpenChat,
    required this.onOpenBot,
    required this.onOpenWorkspace,
    required this.workspaceName,
    required this.models,
    required this.onOpenModelSettings,
    required this.appSettings,
  });

  /// 首页那条滚动公告读它（`AppSettings.broadcastFeed`，启动时拉一次，见 main.dart）。
  final AppSettings appSettings;

  /// 点「开始新会话」/ 点一条内置会话 → 进对话页（可带一句预填文本）
  final void Function({String? initialText}) onOpenChat;

  /// 打开工作区管理器（= 首页右上角那个入口）。
  ///
  /// 刻意**不做成第 6 个底部 Tab**：底部 5 项是硬约束（首页/专家/资料库/
  /// 定时任务/项目），加第 6 项就偏离了。所以入口放在顶栏右侧。
  final VoidCallback onOpenWorkspace;

  /// 打开「Bot 团队」页（本机 dsh web + ds-bot，用 WebView 显示）。
  ///
  /// 测试版入口：验证「把同一套 web 前端搬进手机」这条路值不值得做下去。
  final VoidCallback onOpenBot;

  /// 当前工作区名，显示在顶栏状态行里（`● 本机 · <名字>`）
  final String workspaceName;

  /// 模型清单。首页要读 [ModelStore.hasModels] 来判断"现在能不能开始"，
  /// 并**监听它**：用户在设置里配好模型回到首页时，界面必须立刻变成可用状态。
  final ModelStore models;

  /// 切到底部「设置」Tab（= 唯一能配模型的地方）。
  ///
  /// 单独开一个回调而不是让首页自己 push 设置页：模型配置的正式入口是
  /// 底部导航第 5 项「设置」，从首页直接 push 一份「模型设置」会让用户
  /// 以为配完就回到了原来的地方，但设置 Tab 里的「我的模型」是另一个页面。
  final VoidCallback onOpenModelSettings;

  @override
  State<TaskHomeView> createState() => _TaskHomeViewState();
}

/// 中部「内置会话」区块（[_TipBlock]）的条目池在这里：
/// `data/builtin_starters.dart`（12 条，每条绑一个随包内置技能）。
/// **不要再往这个文件里写死条目** —— 上一版那 4 条写死的样式文案就是用户第 8 条
/// 反馈的一半原因（点下去只是把标题填进输入框，换一换也只是同一批换顺序）。
///
/// 固定层（输入区）的逻辑屏高下限。
///
/// 设计稿：胶囊 2301~2354 + 模型按钮 2292~2346 都在 87%~89% 这一带，
/// 到导航顶边 2480 还剩一点留白。但**不能把这块的高度写死** ——
/// 模拟器上底部导航带手势条（24dp），留给输入区的只有 21% 屏高，
/// 写死高度会压出 RenderFlex overflow。所以给下限、让内容自己撑开。
const double _kInputAreaMinRatio = 0.088;

class _TaskHomeViewState extends State<TaskHomeView> {
  /// 「换一换」的发牌器（见 [StarterDealer]）。
  ///
  /// 为什么不是"起点 +4 绕环"：那要求池子大小正好是 4 的倍数（12 → 3 组不重叠）；
  /// 池子加到 13 条之后绕环就会重叠，用户点几次会看到"还是那几条"。
  /// 发牌器对**任意池子大小**都保证"一轮内不重复"。
  final StarterDealer _dealer = StarterDealer();

  /// 当前显示的内置会话这批（一次 [BuiltinStarters.visibleCount] 条 = **4 条**）。
  late List<BuiltinStarter> _visible = _dealer.current;

  /// 「换一换」：**换一整组**。
  ///
  /// 用户 2026-10-04 的要求：「首页的内置对话改为 4 个一组」——
  /// 一次换一整组，且**一轮之内不会重复**（13 条池子点 4 次看完 13 条）。
  void _shuffle() {
    setState(() {
      _dealer.next();
      _visible = _dealer.current;
    });
  }

  /// 「开始新会话」被点。
  ///
  /// ⚠️ **用户实测反馈第 4 条**：「用户首次安装，必须进行模型设置，否则无法
  /// 点击开始准备。」原实现是无条件 `widget.onOpenChat()`：没有模型时用户被
  /// 直接带进一个没有模型的对话页，观感就是"点了没用/进去了也不知道去哪儿配"。
  /// 所以这里分成两条路：有模型照常开，没有模型就**明确说明 + 给出唯一的下一步**，
  /// 绝不静默。
  Future<void> _onStartPressed() async {
    if (widget.models.hasModels) {
      widget.onOpenChat();
      return;
    }
    await _showNeedModelDialog();
  }

  /// 点一条内置会话：走同一道闸。
  ///
  /// 有模型 → 带的是 [BuiltinStarter.prompt]（**提示词里点名了技能**），不是标题。
  /// 只把标题填进去的话，模型看到的就是"做一份幻灯片"这五个字，它不一定知道
  /// 该走哪条流程 —— 这正是用户第 8 条反馈的另一半原因。
  /// ⚠️ 如实说明**没验证过**的部分：技能流程最终跑成什么样取决于模型，界面不能
  /// 承诺"点了就会自动执行对应技能"，这里只保证"发出去的第一句话点名了技能"。
  Future<void> _onTapStarter(BuiltinStarter starter) async {
    if (!widget.models.hasModels) {
      await _showNeedModelDialog();
      return;
    }
    debugPrint('[dsh-home] 内置会话 -> ${starter.skill}（${starter.title}）');
    // ⚠️ 首句要**按界面语言翻译**再发出去：它是这台手机拼出来、以用户身份发的话，
    //    中文原文发给英/日/韩界面下的用户，模型会顺着中文用中文回答
    //    （见 `AGENTS.md` 里"用提问时所用的语言"那条口径）。
    widget.onOpenChat(initialText: context.tr(starter.prompt));
  }

  /// 没有模型时的说明层：说清"为什么现在不能开始"和"去哪儿配"。
  ///
  /// 出口只给一个（去设置）：这一步**没有第二条正确路径**，多给选项只会让用户
  /// 再走一次弯路。文案按界面已有口径写（设置里的说法是「选一家服务商 →
  /// 填 API Key → 测试并保存」，见 settings_tab.dart）。
  Future<void> _showNeedModelDialog() async {
    debugPrint('[dsh-home] 还没有可用模型 → 弹说明层，引导去「设置 → 模型」');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DshColors.surfaceStrong,
        title:
            Text(context.tr('还没有配置模型'), style: const TextStyle(fontSize: 16)),
        content: Text(
          context.tr(
              '现在一个模型都没有，开始会话也没法回话。\n\n去「设置 → 模型」：选一家服务商（端点会自动填好），填上你的 API Key，点「测试并保存」。通过之后回到首页就能开始了。'),
          style:
              TextStyle(color: DshColors.textDim, fontSize: 12.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('知道了')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('去设置')),
          ),
        ],
      ),
    );
    // 用户点了「去设置」→ 直接切到设置 Tab（不是再弹一层说明）。
    if (go == true) widget.onOpenModelSettings();
  }

  @override
  Widget build(BuildContext context) {
    // 监听模型清单：用户在设置里配好模型回到首页时，提示条与按钮要**立刻**
    // 变成可开始的状态，而不是"只有退出重进才正常"（那种现象用户已经反馈过一次）。
    return ListenableBuilder(
      listenable: widget.models,
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    final topInset = MediaQuery.paddingOf(context).top;
    final ready = widget.models.hasModels;

    return Column(
      children: [
        // ---- 滚动层：标题 + 品牌区 + 中部提示区（内容不足一屏时不滚动、不回弹）----
        //
        // ⚠️ LayoutBuilder 必须在 SingleChildScrollView **外面**：
        // 放进 viewport 里会在 performLayout 期间触发布局，
        // 报 `!_debugDoingThisLayout': is not true`（整页空白，日志只有 assert）。
        // 所以先拿到可用高度，再把它当参数传给滚动内容。
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              // ClampingScrollPhysics：越界时只贴边不反弹（BouncingScrollPhysics
              // 在短内容上会出现"弹性跳一下"，用户明确说不要这个手感）。
              physics: const ClampingScrollPhysics(),
              child: _ScrollBody(
                avail: c.maxHeight,
                topInset: topInset,
                visible: _visible,
                workspaceName: widget.workspaceName,
                needsModel: !ready,
                onShuffle: _shuffle,
                onOpenWorkspace: widget.onOpenWorkspace,
                onOpenBot: widget.onOpenBot,
                onOpenModelSettings: widget.onOpenModelSettings,
                onTapStarter: _onTapStarter,
                settings: widget.appSettings,
              ),
            ),
          ),
        ),
        // ---- 固定层：一个「开始新会话」按钮 ----
        //
        // 用户实测反馈（原话）：「首页底部导航的上边，有个发信息或按住说话的按钮
        // 和一个向上箭头（无法使用）以及一个模型选择按钮。取掉这三个按钮，
        // 改为开始新会话。」
        //
        // 所以这里不再放 InputBar：
        //   * 「发消息或按住说话」胶囊 —— 首页上它本来只是个跳转壳，去了；
        //   * 胶囊右侧的向上箭头 —— 在首页没有输入内容，点了不会有反应，去了；
        //   * 下方的模型按钮 —— 模型切换在**会话页里面**做才有意义，去了。
        // 只留一个入口：点它就新开一条会话。
        //
        // 高度仍**不写死**：内容自己撑开，容器只给下限，避免小屏/手势条场景
        // 压出 RenderFlex overflow（这个坑踩过）。
        Container(
          color: Colors.transparent,
          constraints: BoxConstraints(minHeight: screenH * _kInputAreaMinRatio),
          padding: EdgeInsets.fromLTRB(
            DshMetrics.pagePad,
            (screenH * 0.012).clamp(4, 14),
            DshMetrics.pagePad,
            (screenH * 0.006).clamp(3, 10),
          ),
          child: SizedBox(
            height: 46,
            child: Semantics(
              button: true,
              // ⚠️ 实测（widget 测试里读语义节点）：FilledButton 自己的文字会**覆盖**
              // 这里写的 label，节点最终读到的就是「开始新会话」。所以"还没有模型"
              // 这件事**不要指望从这个 label 断言**，它由上面那条常驻提示条承担
              // （提示条的语义标签「还没有可用模型，去设置」是能读到的，已实测）。
              label: context.tr('开始新会话'),
              child: FilledButton.icon(
                // 两种情况下 onPressed 都**不为空**：没有模型时点进去是说明层，
                // 不是"点不动的灰按钮"（用户反馈原话："无法点击开始准备"）。
                onPressed: _onStartPressed,
                icon: Icon(
                  ready ? Icons.add_comment_outlined : Icons.settings_outlined,
                  size: 18,
                ),
                label: Text(context.tr('开始新会话')),
                // 没有模型：如实做成"还没准备好的样子"（置灰），别用主色骗用户
                // 说这里点了就能开始。
                style: ready
                    ? null
                    : FilledButton.styleFrom(
                        backgroundColor: DshColors.surfaceHigh,
                        foregroundColor: DshColors.textDim,
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 滚动层内容。
///
/// ## 纵向节奏是怎么定的（重要，改之前先读这段）
///
/// 设计稿（`page-08`）的 OCR 文字框在品牌区是**互相重叠**的：
/// logo 块（377~465）与标语（445~530）重叠，推广文案（518~564）又压在标语上。
/// 原因是 OCR 框抓的是**字形**，而 logo 是个图形块，旁边还有叠字效果。
///
/// 所以这一页**不能**像别的页那样纯按 y 坐标摆 —— 会把 logo 和标语叠在一起。
/// 采取的办法是：
///   1. 各块高度按 dump 语义树量出来的**真实 dp** 定（见下面的常量）；
///   2. 只剩一个自由度：块与块之间的 3 段跨块留白。把它按设计稿的
///      大留白比例分配剩余空间；
///   3. 剩余空间不够时（小屏/大字号）等比压缩，于是内容永远不超一屏 →
///      没有多余滚动、没有回弹（用户明确要求手感自然）。
///
/// 实测基准（模拟器 1080x2400 / dpr 2.625，屏高 914dp）：
///   标题中心 7.0%（设计 7.25%）｜标语中心 17.6%（设计 18.5%）
///   推广文案中心 19.8%（设计 20.5%）｜提示区标题中心 42.3%（设计 42.6%）
///   换一换中心 74.3%（设计 72.9%）
class _ScrollBody extends StatelessWidget {
  const _ScrollBody({
    required this.avail,
    required this.topInset,
    required this.visible,
    required this.workspaceName,
    required this.needsModel,
    required this.onShuffle,
    required this.onOpenWorkspace,
    required this.onOpenBot,
    required this.onOpenModelSettings,
    required this.onTapStarter,
    required this.settings,
  });

  /// 滚动层的可用高度（dp），由外层 LayoutBuilder 传入。
  /// **不能在滚动容器内部再用 LayoutBuilder 测**（会 assert，见 build 的注释）。
  final double avail;
  final double topInset;

  /// 当前要显示的那一批内置会话（由外层持有 —— `换一换` 会整批换掉）。
  final List<BuiltinStarter> visible;
  final String workspaceName;

  /// 一条真实模型/轮换组都没有 → 顶部挂一条"去设置"的常驻提示条。
  final bool needsModel;
  final VoidCallback onShuffle;
  final VoidCallback onOpenWorkspace;
  final VoidCallback onOpenBot;
  final VoidCallback onOpenModelSettings;
  final void Function(BuiltinStarter starter) onTapStarter;

  /// 首页公告栏读它（见 [AnnounceBar]）。
  final AppSettings settings;

  // ---- 各块的固定高度（dp，实测值）----
  // 这些数字是**在模拟器上 dump 语义树量出来的真实值**（1080x2400 / dpr 2.625），
  // 不是估算：标题行 [203,256] 状态行 [266,311] / 标语 [617,695] /
  // 推广文案 [711,761] / 提示区标题 [1100,1158] / 4 行提示 [1239…1712] /
  // 换一换 [1754,1838]。
  // ⚠️ 本轮起内置会话是 6 行（不是设计稿的 4 行），多出来的高度在下面按权重
  // 从 3 段跨块留白里扣 —— 所以这里的常量保持"每块自身高度"的量级即可，
  // 不用改（改的只是 [_TipBlock.totalHeight] 会变长）。
  static const double topBarBlock = 45; // 标题 21 + 4 + 状态行 16（两行，没变）
  static const double logoBlock = 70;
  static const double taglineBlock = 30;
  static const double welfareBlock = 19;
  static const double topLeadGap = 10; // 顶栏 → 猫头 logo
  static const double logoLeadGap = 4; // logo → 标语
  static const double taglineLeadGap = 6; // 标语 → 推广文案

  /// 版本号下面那条公告栏占的高度（含它与上下两块之间的间距）。
  ///
  /// ⚠️ 它**必须**计入 `fixed`：首页是"内容不足一屏、按比例分配留白"的布局，
  /// 少算这一块会让内容整体下移、把 `换一换` 顶出屏（历史上 6 行内置会话
  /// 那 +82dp 就是这么处理的，见 [_gapWeights] 的说明）。
  static const double announceBlock = AnnounceBar.height + taglineLeadGap;

  /// 设计稿里 3 段**跨块**留白的原始比例（单位：设计像素）。
  ///   顶栏底 293 → logo 377        = 84（本页修正：OCR 重叠，取 30）
  ///   推广文案底 564 → 提示区顶 1075 = 511（本页实测偏大，收成 210）
  ///   换一换底 1948 → 输入区顶 2301  = 353
  /// （另外两段大留白 -- 提示区内部标题→首行、末行提示→换一换 --
  ///   由 [_TipBlock] 的固定值承担，不进这张表。）
  ///
  /// 这三个权重是**在模拟器上量了四轮之后定下来的**：模拟器的底部导航带
  /// 手势条（24dp），留给滚动层的空间比设计稿窄，"按原比例分配"会把
  /// 品牌区与提示区一起推到设计稿目标线以下 5~6% 屏高。收窄中间那段、
  /// 把余量挪给尾段（它反正会被固定层吃掉）之后，五个基准点全部落在
  /// 设计稿 ±1.2% 以内。
  ///
  /// **内置会话从 4 行变 6 行（+82dp）、以及没有模型时多一条提示条（+52dp）之后，
  /// 落点为什么还是稳的**：这两块增加的高度都记进 `fixed`，于是 `slack` 变小，
  /// 三段留白按同一比例一起缩（新增的 82dp 里约 44% 从 `换一换` 上方的留白扣，
  /// 56% 从它下方扣）。粗算：`换一换` 的纵向位移只有个位数 dp —— 它是"吃掉留白"
  /// 而不是"把内容顶出去"。实测证据见交付报告（widget 测试在真机屏高下的
  /// overflow 断言 + 实测坐标）。
  static const List<double> _gapWeights = [2, 42, 56];

  @override
  Widget build(BuildContext context) {
    // 没有模型时多出来的那条提示条，必须计入 fixed —— 否则它会把整页顶出
    // 一屏（本页约定：内容不足一屏、不出现多余滚动与回弹，见类注释）。
    final noticeH = needsModel ? _ModelNotice.totalHeight : 0.0;
    // fixed 不重复计 _TipBlock 的内部间距（它自己带）。
    final fixed = topBarBlock +
        topLeadGap +
        logoBlock +
        logoLeadGap +
        taglineBlock +
        taglineLeadGap +
        announceBlock +
        welfareBlock +
        noticeH +
        _TipBlock.totalHeight;
    final slack = (avail - topInset - fixed).clamp(0.0, double.infinity);
    final totalW = _gapWeights.reduce((a, b) => a + b);
    final gaps = _gapWeights.map((w) => slack * (w / totalW)).toList();

    return Column(
      children: [
        _TopBar(
          workspaceName: workspaceName,
          onOpenWorkspace: onOpenWorkspace,
          onOpenBot: onOpenBot,
        ),
        // 常驻提示条放在顶栏正下方：不滚动就能看见，且**不点按钮也能看到出路**。
        if (needsModel) _ModelNotice(onOpenSettings: onOpenModelSettings),
        SizedBox(height: topLeadGap + gaps[0]),
        // 皮肤是运行时变量：这里不能 const（const 实例换肤时会被原样复用、颜色不刷新）
        // ignore: prefer_const_constructors
        _BrandBlock(settings: settings),
        SizedBox(height: gaps[1]),
        _TipBlock(
          visible: visible,
          onShuffle: onShuffle,
          onTapStarter: onTapStarter,
        ),
        SizedBox(height: gaps[2]),
      ],
    );
  }
}

/// 顶部常驻提示条：一条模型都没有时出现。
///
/// 为什么要有它（用户实测反馈第 4 条）：原来的首页只有最下面一个
/// 「开始新会话」，**没有任何地方**说明"现在还不能开始、下一步是去设置"，
/// 用户只能靠自己猜。这条提示条让出路一直挂在页面上方，用户不点按钮也能看到。
///
/// 用 `err` 色不是"报错"，而是与设置页里同一状态的措辞保持一档
/// （设置页写的是「尚未配置模型 —— 不配置的话对话调不通模型」）。
class _ModelNotice extends StatelessWidget {
  const _ModelNotice({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  /// 整块占位高度（= 内容 40 + 到底部的留白 12）。
  /// [_ScrollBody] 把它算进固定高度，所以这里和 build 里的实际结构必须一致。
  static const double totalHeight = 52;
  static const double _contentHeight = 40;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DshMetrics.pagePad,
        0,
        DshMetrics.pagePad,
        totalHeight - _contentHeight,
      ),
      child: Semantics(
        button: true,
        label: context.tr('还没有可用模型，去设置'),
        child: InkWell(
          onTap: onOpenSettings,
          borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
          child: Container(
            height: _contentHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: DshColors.err.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
              border: Border.all(
                color: DshColors.err.withValues(alpha: 0.45),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_off_outlined, size: 16, color: DshColors.err),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    context.tr('还没有可用模型 · 去设置'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: DshColors.err,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, size: 15, color: DshColors.err),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏：`泡泡猫的DSH` + `● 本机 · <当前工作区名>`；右侧是「工作区」入口。
///
/// 状态行是**纯文本**：不可点、没有箭头。
/// （原来这里写 `云端 ›`，那个箭头是假的 —— 点了没有任何反应，
///  既不是下拉也不是跳转，容易被当成"坏了的按钮"，本轮去掉。）
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.workspaceName,
    required this.onOpenWorkspace,
    required this.onOpenBot,
  });

  final String workspaceName;
  final VoidCallback onOpenWorkspace;
  final VoidCallback onOpenBot;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    // 设计稿：标题带 163~287，整块底边 ≈ 293/2640 = 11.1%。
    // 这里在 DshPageHeader 的基准上再加一点：本页顶栏是"标题 + 状态行"两行，
    // 实测按纯基准排会高 13dp 左右（标题落 7.08% 而设计稿是 7.25% 的中心线）。
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          DshMetrics.pagePad,
          h * 0.0562 - 21.3 + 13,
          DshMetrics.pagePad,
          0,
        ),
        child: SizedBox(
          height: 52,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Flexible：工作区名可能很长，标题整体必须能压缩，
              // 否则顶栏会 RenderFlex overflow（本轮验收要求 overflow 为空）。
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      // 短名（顶栏宽度有限）：应用全名在启动器里，见 AndroidManifest 的
                      // android:label = 泡泡猫的Deepseek harness
                      context.tr('泡泡猫的DSH'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: DshColors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
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
                            context.tr('本机 · {0}', [workspaceName]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: DshColors.textDim,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Bot 团队入口（测试版）：和工作区入口并排，样式沿用同一个观感。
              TextButton.icon(
                onPressed: onOpenBot,
                icon: const Icon(Icons.smart_toy_outlined, size: 15),
                label: const Text('Bot', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: DshColors.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 4),
              // 工作区入口：图标 + 文字（只用图标用户不知道是干嘛的 —— 上一版
              // 就是个列表图标 + 角标数字，用户原话"不知道是干嘛的"）。
              WorkspaceEntryButton(onTap: onOpenWorkspace),
            ],
          ),
        ),
      ),
    );
  }
}

/// 品牌区：自绘 logo + 标语 + 福利文案。
///
/// 三段高度都是**固定值**（不靠内容撑），这样 [_ScrollBody] 才能准确算出
/// 剩余留白。实测：标语文字块 30dp、推广文案 19dp。
///
/// 设计稿 y：logo 377~465 / 标语 445~530 / 福利 518~564。
/// （注意 logo 与标语的 OCR 框重叠 —— 见 [_ScrollBody] 的说明。）
class _BrandBlock extends StatelessWidget {
  const _BrandBlock({required this.settings});

  /// 公告栏读它（`AppSettings.broadcastFeed`）。
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          height: _ScrollBody.logoBlock,
          child: Center(
            // 品牌 logo：与桌面启动器图标**同一份美术**（见 widgets/brand_logo.dart），
            // 素材由 install/make-icon.py 从 design/launcher-icon-source.png 生成。
            // 2026-10-15（用户第 4 条）：点它会弹一句"对话的样子"的话 —— 见 mascot_speech.dart。
            child: MascotSpeech(size: 70),
          ),
        ),
        const SizedBox(height: _ScrollBody.logoLeadGap),
        SizedBox(
          height: _ScrollBody.taglineBlock,
          child: Center(
            child: Text(
              context.tr('欢迎来到泡泡猫的DSH'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: DshColors.text,
                fontSize: 23,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                height: 1.2,
              ),
            ),
          ),
        ),
        const SizedBox(height: _ScrollBody.taglineLeadGap),
        // 版本号：用户要求每改一版 +1，好一眼确认装的是不是新版。
        SizedBox(
          height: 18,
          child: Center(
            child: Text(
              'v$kAppVersion',
              style: TextStyle(color: DshColors.textFaint, fontSize: 11),
            ),
          ),
        ),
        const SizedBox(height: _ScrollBody.taglineLeadGap),
        // 公告 / 广告位滚动栏（用户 2026-10-15 第 3 条：**放在版本号下面**）。
        // 内容是仓库根目录 notice.json 里的 items；拉不到就什么都不显示。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
          child: AnnounceBar(settings: settings),
        ),
        // 与 `announceBlock` 的记账严格对应：这一块占 AnnounceBar.height + 这个间距。
        const SizedBox(height: _ScrollBody.taglineLeadGap),
        SizedBox(height: _ScrollBody.welfareBlock,
          child: Center(
            child: Text(
              context.tr('请帮忙推广一下我的公众号，粉丝太少没有更新动力了'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: DshColors.textDim, fontSize: 12.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// 中部「内置会话」区块。
///
/// 设计稿（page-08）：
///   * 提示区标题 y=1075~1173（原文一句被截断的问句）；
///   * 原本 4 条功能提示 y=1307/1445/1588/1727，**行距 140 设计像素 ≈ 5.3% 屏高**，
///     x 从 118 起左对齐（≈ 9.7% 屏宽）；
///   * `换一换` y=1901~1948（72.0%），x=163（≈ 13.4% 屏宽）。
///
/// ⚠️ **本轮起这里不再是 4 条写死的样式文案，而是 12 条内置会话的一个窗口**
/// （一次 [BuiltinStarters.visibleCount] = 6 条，条目池见 `data/builtin_starters.dart`）。
/// 用户第 8 条反馈：「点任意一个是不是会调用相应的技能」「点换一换也只是四个位置
/// 的不同」。现在每行点下去带的是 [BuiltinStarter.prompt]（点名技能），
/// `换一换` 走池子上的**重新抽样**（见 [_TaskHomeViewState._shuffle]）。
///
/// 行高/行距**本轮按实测收窄**（25+16 → 23+13）：6 行 + 首启那条提示条之后，
/// `换一换` 在"三键导航（底部 48dp）"的机型上底边会超出视口约 2.3dp
/// （不是 overflow，但要下滑一下才看得全）。收窄后换一换回到设计稿那一段附近，
/// 且三种屏高配置下都不出血；多出来的高度仍由 [_ScrollBody] 按比例从跨块留白里扣
/// （见该类里 `_gapWeights` 的说明）。
class _TipBlock extends StatelessWidget {
  const _TipBlock({
    required this.visible,
    required this.onShuffle,
    required this.onTapStarter,
  });

  /// 当前这一批（外层持有，`换一换` 会整批换掉）。
  final List<BuiltinStarter> visible;
  final VoidCallback onShuffle;
  final void Function(BuiltinStarter starter) onTapStarter;

  /// 单行提示的内容高与行距（按实测收窄，见类注释）。
  /// 设计稿实测是行距 131px ≈ 50dp、内容带 30dp；6 行铺下来会把
  /// `换一换` 顶出设计稿那一段，所以这里取 23 + 13 = 36dp/行
  /// （文字 13.5pt 的行盒约 16dp，23dp 仍然不挤）。
  static const double rowHeight = 23;
  static const double rowGap = 13;

  /// 区块标题带（设计稿提示区标题 1075~1173 那一段）。
  static const double titleBlock = 44;

  /// 标题下面那行小字（点一条会发生什么）。**单行**，不占两行高度。
  static const double hintBlock = 16;
  static const double hintLeadGap = 4;

  /// 小字 → 第一条内置会话的留白。
  static const double hintToRowsGap = 12;

  /// 这一块的总高（含标题、小字、N 行、换一换与之上的留白、胶囊）。
  /// [_ScrollBody] 用它算剩余空间，所以必须和 build 里的实际结构一致。
  /// N = [BuiltinStarters.visibleCount]，不是一个写死的 4。
  static double get totalHeight {
    const n = BuiltinStarters.visibleCount;
    return titleBlock +
        hintLeadGap +
        hintBlock +
        hintToRowsGap +
        (n * rowHeight + (n - 1) * rowGap) +
        16 +
        32;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DshMetrics.pagePad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: titleBlock,
            child: Align(
              // 设计稿提示区标题带 1075~1173，中心 1124/2640 = 42.6%。
              // 实测这一块比设计稿高 4~5%，所以往下压 8dp。
              alignment: const Alignment(0, 0.36),
              child: Text(
                context.tr('我帮你用泡泡猫的DSH，把想法做成成品'),
                style: TextStyle(
                  color: DshColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
            ),
          ),
          const SizedBox(height: hintLeadGap),
          // 用户看不出"点一条会发生什么"（他原话问的是"是不是会调用相应的技能"）。
          // 这里只写**验证过的事实**：点下去开新会话，第一句就是点名技能的指令
          // （见 [_TaskHomeViewState._onTapStarter]）。刻意**不写**"点了就自动执行"
          // —— 技能最终有没有被模型走通，我没在设备上验证过。
          SizedBox(
            height: hintBlock,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.tr('点一条 → 带着对应技能的指令开新会话'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: DshColors.textFaint, fontSize: 11),
              ),
            ),
          ),
          const SizedBox(height: hintToRowsGap),
          for (var i = 0; i < visible.length; i++) ...[
            Semantics(
              button: true,
              // 无障碍 / uiautomator 要能读出**标题**：把一句话说明并进同一条
              // 语义标签里，行本身仍然只有一行文字（撑成两行会把高度预算吃掉）。
              // ⚠️ 起始语的文案是**数据表字符串**（`builtin_starters.dart` 里那 13 条），
              //    必须走 `context.tr(...)` 查表 —— 直接渲染原文的话，切英/日/韩
              //    首页这 4 张卡还是中文（2026-10-12 之前的真实状态）。
              label: '${context.tr(visible[i].title)}：'
                  '${context.tr(visible[i].subtitle)}',
              child: Tooltip(
                // 说明文字的第二个出口：长按能看到（屏幕上只放标题，保证单行）。
                message: context.tr(visible[i].subtitle),
                child: InkWell(
                  onTap: () => onTapStarter(visible[i]),
                  borderRadius: BorderRadius.circular(DshMetrics.radius(10)),
                  child: SizedBox(
                    height: rowHeight,
                    child: Row(
                      children: [
                        Icon(visible[i].icon,
                            size: 15, color: DshColors.accent),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            context.tr(visible[i].title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: DshColors.textDim,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                        Icon(Icons.chevron_right,
                            size: 14, color: DshColors.textFaint),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (i != visible.length - 1) const SizedBox(height: rowGap),
          ],
          const SizedBox(height: 16),
          Semantics(
            button: true,
            label: context.tr('换一换'),
            child: InkWell(
              onTap: onShuffle,
              borderRadius: BorderRadius.circular(DshMetrics.radius(14)),
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                decoration: BoxDecoration(
                  color: DshColors.surface,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(14)),
                  border: Border.all(color: DshColors.divider, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh, size: 14, color: DshColors.textDim),
                    const SizedBox(width: 6),
                    Text(context.tr('换一换'),
                        style: TextStyle(
                            color: DshColors.textDim, fontSize: 12.5)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
