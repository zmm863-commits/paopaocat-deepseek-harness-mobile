import 'package:flutter/material.dart';

import 'dsh_palette.dart';

export 'dsh_palette.dart' show DshPalette, DshPalettes;

/// 设计稿尺寸基准（单位：设计稿像素）。
///
/// 来源：设计稿 11 页截图按竖屏导出，机身 1215 x 2640 设计像素。
/// `pdf-images/ocr-all.txt` 里每行文字都带 y/x 坐标，本文件把那些坐标
/// 换算成"占屏比例"，这样在任何手机分辨率下布局比例都能对上设计稿。
///
///   x 换算：1215 设计像素 = 屏宽
///   y 换算：2640 设计像素 = 屏高
///   （上一版的换算基准写成了 3840，导致所有纵向位置压缩了 31%，
///     输入框、导航栏的间距明显比设计稿紧。）
const double kDesignW = 1215;
const double kDesignH = 2640;

/// 把设计稿的 x 坐标换算成屏宽比例。
double dx(double designX) => designX / kDesignW;

/// 把设计稿的 y 坐标换算成屏高比例。
double dy(double designY) => designY / kDesignH;

/// 设计稿字号换算基准。
///
/// 用「最小宽度」而不是屏宽：设计稿 1215px / 360dp ≈ 3.375，
/// 这样在 360dp 宽的手机上 1 设计像素 ≈ 0.296dp，和设计稿观感一致。
const double kDesignScale = 3.375;

/// 换算设计稿像素 → 逻辑像素（dp），并夹在合理区间避免超大屏字过大。
double dp(double designPx, {double min = 8, double max = 48}) {
  final v = designPx / kDesignScale;
  return v.clamp(min, max);
}

/// 纵向定位的语义别名：设计稿机身高度上的一个比例。
///
/// [frac] 传设计稿 y 坐标、[of] 传"可用高度"（滑动区/整屏），
/// 返回对应的逻辑像素 —— 让每个页面都写成
/// `sp(2301, h) - sp(0, h)` 这样的形式，一眼能看出出处是设计稿哪一行。
double sp(double designY, double of) => (designY / kDesignH) * of;

/// 全局配色入口：**运行时可变**的皮肤读取点。
///
/// 改造前这里是二十来个 `static const Color`，编译期定死，浅色主题做不了。
/// 现在值搬进了 [DshPalette]，这里只剩一层 getter —— 所以
/// `TextStyle(color: DshColors.textDim)` 不再能用 `const` 修饰（analyzer 会
/// 逐处指出，那些 `const` 已经删掉），换肤就是换 [applySkin] 传进来的那个引用。
///
/// ⚠️ **换肤必须配合全树重建**：`DshColors` 只是静态读点，它自己不会通知任何人。
/// 真正的重建链路在 `main.dart`：`ListenableBuilder(listenable: appSettings)`
/// → `DshColors.applySkin(...)` → 新的 `MaterialApp(theme: ...)`，
/// 于是整棵树（含推入的对话页）都会重新 build 一遍。
///
/// 还有一条容易踩的坑：**用 `const` 构造的自定义 widget 不会跟着重建**
/// （widget 实例完全相同，Flutter 会跳过 `updateChild`），所以凡是 build 里读
/// `DshColors` 的组件，调用点也不能写 `const` —— 这也是本次一并处理过的。
class DshColors {
  const DshColors._();

  static DshPalette _skin = DshPalettes.dark;

  /// 当前皮肤（色值全在这里查）。
  static DshPalette get skin => _skin;

  static Brightness get brightness => _skin.brightness;

  static bool get isLight => _skin.isLight;

  /// 换肤次数（只增）。给**保活页面**用。
  ///
  /// 为什么需要：`applySkin` 只换引用、不通知，靠 `MaterialApp` 重建带动全树。
  /// 但 Bot 页是常驻在 `IndexedStack` 里的 WebView 页面 —— 实测换肤时它的
  /// `build` 不一定跑，网页就停在旧主题：**深色 App + 浅色网页**，
  /// 用户看到的就是「切换以后文字看不见」。需要跟着换肤的组件监听这个值。
  static final ValueNotifier<int> skinRevision = ValueNotifier<int>(0);

  /// 换肤。**只改引用、不通知**：调用方负责触发全树重建（见类注释）。
  /// 保活组件另外监听 [skinRevision]。
  static void applySkin(DshPalette skin) {
    _skin = skin;
    skinRevision.value++;
  }

  /// 圆角缩放（像素风 = 0，见 `DshPalette.radiusScale`）。
  static double get radiusScale => _skin.radiusScale;

  /// 当前皮肤是不是**像素/终端**那一套（字体、描边、投影、底纹全换，见 `DshPalette.pixelStyle`）。
  static bool get pixelStyle => _skin.pixelStyle;

  /// 页面底色（比卡片更深，让卡片浮起来）
  static Color get bg => _skin.bg;

  /// 次一级底色（弹层、空态块）
  static Color get bgSoft => _skin.bgSoft;

  /// 背景柔光色：画在底色之上、自上而下扩散的一层径向渐变。
  /// 深色界面里阴影看不见，层次只能靠亮度差 —— 见 `ui/theme/dsh_grid.dart`。
  static Color get bgGlow => _skin.bgGlow;

  /// 卡片 / 区块底色。浅色皮肤是半透明白玻璃，深色皮肤是更亮的半透明层。
  static Color get surface => _skin.surface;

  /// 比卡片再亮一档（列表行按压、输入框）
  static Color get surfaceHigh => _skin.surfaceHigh;

  /// 最实的面板（不透明）
  static Color get surfaceStrong => _skin.surfaceStrong;

  /// 输入框填充色（**不透明**）。见 [DshPalette.fieldFill] 的说明：
  /// 深色下 `surface` 只有 7% 白，键入的字会和底版糊在一起。
  static Color get fieldFill => _skin.fieldFill;

  /// 顶栏 / 底部导航底色
  static Color get navBg => _skin.navBg;

  /// 1px 细边（卡片的描边）
  static Color get line => _skin.line;

  /// 强一档的细边（焦点 / 选中态）
  static Color get line2 => _skin.line2;

  /// 分隔线（等同 [line]，保留旧名字，调用点不用改）
  static Color get divider => _skin.line;

  /// 主强调色：青
  static Color get accent => _skin.accent;

  /// 第二强调色：紫
  static Color get accent2 => _skin.accent2;

  /// 第三强调色：粉
  static Color get accent3 => _skin.accent3;

  /// 主色淡化（用于选中项底色）
  static Color get accentDim => _skin.accentDim;

  /// 压在强调色上的前景色
  static Color get onAccent => _skin.onAccent;

  /// 正文
  static Color get text => _skin.text;

  /// 次要文字（副标题、描述、时间）
  static Color get textDim => _skin.textDim;

  /// 更弱的提示文字（「内容由AI生成」「暂无定时任务」）
  static Color get textFaint => _skin.textFaint;

  /// 代码块底色（浅色皮肤里也是深蓝，和网站一致）
  static Color get codeBg => _skin.codeBg;
  static Color get codeBg2 => _skin.codeBg2;
  static Color get codeText => _skin.codeText;
  static Color get codeMuted => _skin.codeMuted;

  /// 用户气泡底色
  static Color get userBubble => _skin.userBubble;

  /// 助手气泡底色
  static Color get aiBubble => _skin.aiBubble;

  /// 成功 / 已完成
  static Color get ok => _skin.ok;

  /// 进行中
  static Color get busy => _skin.busy;

  /// 失败
  static Color get err => _skin.err;

  /// 压在 [ok] 上的前景色
  static Color get onOk => _skin.onOk;

  /// 青 → 紫渐变（主按钮 / 当前项 / 进度）
  static LinearGradient get grad => _skin.grad;

  /// 青 → 紫 → 粉三段渐变
  static LinearGradient get grad3 => _skin.grad3;

  /// 面板光晕阴影
  static List<BoxShadow> get panelShadow => _skin.panelShadow;

  /// 强调光晕阴影
  static List<BoxShadow> get accentShadow => _skin.accentShadow;

  /// 「玻璃面板」统一装饰：半透明底 + 1px 细边 + 大圆角 + 柔和光晕。
  ///
  /// 网站的卡片观感就靠这四件事，写成一个工厂方法，改一处全站一致。
  ///
  /// ⚠️ 默认底色用 [surfaceHigh]（浅色 = `--panel-strong` rgba(255,255,255,.94)），
  /// **不是** `--panel`(.72)：卡片底下还垫着那层光晕阴影，72% 的白会把阴影透上来，
  /// 实测面板会比页面底色还暗（#E8ECF1 vs #EEF3FB）—— 玻璃该比底亮，不该比底暗。
  /// 深色皮肤同理用"更亮一档的半透明层"。
  ///
  /// [gradient] 与 [color] 互斥（[BoxDecoration] 不允许同时给），给了渐变就用渐变。
  static BoxDecoration panel({
    double radius = DshMetrics.cardRadius,
    Color? color,
    Gradient? gradient,
    Color? borderColor,
    double borderWidth = 1,
    bool glow = true,
    List<BoxShadow>? shadow,
  }) {
    // 像素皮肤的两条差别（用户 2026-10-15 第 6 条要"大变样子"）：
    //   ① 底改成**不透明**的 surfaceStrong —— 玻璃半透明是另两套皮肤的质感，
    //      像素/终端风要的是"实心板子"；
    //   ② 描边 ×2 —— 1dp 的细边在方角上几乎看不出来，加粗才有"像素块"的味道。
    // 阴影不在这里改：它在色板里（`DshPalette.panelShadow`），像素皮肤那份是
    // **无模糊的硬方块位移**。
    final pixel = DshMetrics.pixelStyle;
    return BoxDecoration(
      color: gradient == null
          ? (color ?? (pixel ? surfaceStrong : surfaceHigh))
          : null,
      gradient: gradient,
      // 在这里统一缩放：调用方传的是**设计稿原值**（11 / controlRadius / panelRadius…）
      borderRadius: BorderRadius.circular(DshMetrics.radius(radius)),
      border: Border.all(
        color: borderColor ?? line,
        width: borderWidth * (pixel ? 2 : 1),
      ),
      boxShadow: glow ? (shadow ?? panelShadow) : null,
    );
  }
}

/// 字体族令牌。
///
/// 网站用系统 sans 做正文、等宽族做代码/路径/命令 —— 这里对齐：
/// 等宽优先 JetBrains Mono，逐个回落到 SF Mono / Consolas / Roboto Mono，
/// 最后一定落到 Android 自带的 `monospace`（保证真机上不会因为缺字体变回比例字体）。
class DshFonts {
  const DshFonts._();

  /// 等宽族首选
  static const String mono = 'JetBrains Mono';

  /// 等宽族回落链（顺序即优先级）
  static const List<String> monoFallback = <String>[
    'SF Mono',
    'Consolas',
    'Roboto Mono',
    'monospace',
  ];

  /// 代码/路径/命令文本样式
  static TextStyle code({
    required Color color,
    double fontSize = 12,
    double? height,
    FontWeight? fontWeight,
  }) =>
      TextStyle(
        fontFamily: mono,
        fontFamilyFallback: monoFallback,
        color: color,
        fontSize: fontSize,
        height: height,
        fontWeight: fontWeight,
      );
}

/// 圆角与间距，全部取自设计稿可测的几何关系。
///
/// 纵向的一切都**不要写死 dp**：请用 `sp(设计稿y, 可用高度)` 换算，
/// 这样任何屏高下元素占屏高的比例都和设计稿一致（见 HANDOFF §4.3）。
/// 这里只放"与屏高无关"的常量（左右边距、圆角、图标尺寸）。
class DshMetrics {
  const DshMetrics._();

  /// 页面左右安全边距。
  /// 设计稿正文 x 起点 171 / 1215 ≈ 14%，实测这一档在 360dp 宽机型上
  /// 与「专家卡内文 x=119 (9.8%)」的观感最接近，取 15dp。
  static const double pagePad = 15;

  /// 专家卡/项目卡横向间距：设计稿两列间隙 681-498=183 ≈ 15% 屏宽 ≈ 9dp
  static const double cardGap = 9;

  /// 卡片圆角。设计稿卡片转角约 28 设计像素（≈14dp），
  /// 这里对齐网站令牌 `--radius: 16px`，取 16 —— 大圆角是那套风格的一部分。
  static const double cardRadius = 16;

  /// 小控件圆角（网站 `--radius-sm: 10px`）：chip、输入框、小按钮。
  static const double controlRadius = 10;

  /// 当前皮肤是不是**像素/终端**那一套（见 [DshPalette.pixelStyle]）。
  ///
  /// 用户 2026-10-15 第 6 条：「像素主题变化不大或者说根本没有变化，我要的是
  /// 大变样子，界面字体风格和其他两个完全不一样的」。所以像素皮肤不再是"换色 +
  /// 直角"，而是**换一整套视觉**：等宽字体、2dp 硬描边、无模糊的方块投影、
  /// 扫描线底纹。这个开关就是那套视觉的总闸 —— 所有"要不一样"的地方都读它，
  /// **不要**在别处再判断皮肤 id（`skin.id == 'pixel'` 那样会在加皮肤时漏掉）。
  static bool get pixelStyle => DshColors.pixelStyle;

  /// 描边宽度：普通皮肤 1dp（细致），像素皮肤 2dp（看得见像素点）。
  static double get borderWidth => pixelStyle ? 2.0 : 1.0;

  /// 文字用的字体族：像素皮肤走**设备自带的等宽字体**。
  ///
  /// 为什么不随包带一款像素字体：① 中文像素字体动辄 5–10 MB —— 我们刚做完
  /// 包瘦身（106 → 76 MiB），不能为了一个皮肤把它加回去；② 现成的像素字体
  /// 多数只覆盖拉丁字母，中文会掉回系统字体、变成"中英两套风格"。等宽字体
  /// 是设备自带、覆盖中文、且和"终端/像素"同一气质的最小代价方案。
  static String? get fontFamily => pixelStyle ? 'monospace' : null;

  /// 像素皮肤下字距略放开（等宽字体本来就宽，再紧就糊成一团）。
  static double get letterSpacing => pixelStyle ? 0.4 : 0.0;

  /// 把设计稿上的圆角**按当前皮肤的缩放**换算成实际值。
  ///
  /// 为什么要有这一层：圆角原来在界面上是**写死**的（`BorderRadius.circular(DshMetrics.radius(8))`），
  /// 于是一套"方角"皮肤切换过去会**半方半圆**（实测 110 处写死、只有 20 处走常量）。
  /// 现在所有圆角都过这里：像素风（`radiusScale = 0`）一开，全界面立刻变直角。
  static double radius(double base) => base * DshColors.radiusScale;

  /// 大容器圆角（网站 `--radius-lg: 24px`）：弹层、资料库大卡。
  static const double panelRadius = 24;

  /// 表单输入框圆角（网站输入框是 10 的小圆角，不是胶囊）。
  static const double fieldRadius = 10;

  /// 卡片内边距
  static const double cardPad = 13;

  /// 底部导航「内容区」高度（不含系统手势条 SafeArea），单位 dp。
  ///
  /// 设计稿：导航标签带 y=2567~2610（97.2%~98.9%），图标在标签上方，
  /// 整个导航条占 2480→2640 也就是 6.1% 屏高。
  /// 参数用逻辑屏高 dp（`MediaQuery.size.height`）。
  ///
  /// 之所以跟着屏高走：导航条在设计稿里是**按屏高比例**排的（6.1%），
  /// 写死 52dp 在高屏机上会让标签顶到 93%（设计稿是 97.2%）。
  static double navContentHeight(double screenHeight) =>
      (screenHeight * 0.061).clamp(44, 62);

  /// 顶部标题中心在设计稿里的 y（跨页一致：199~255 都是标题带）。
  static const double kTitleY = 227;

  /// 标题带上下留白（设计稿：状态栏底 72 → 标题顶 199）。
  static const double kTitleGapTop = 12;

  /// 标题带下方到内容的间距（设计稿：标题底 255 → 搜索框顶 394）。
  static const double kTitleGapBottom = 14;

  /// 输入框圆角（胶囊）。设计稿胶囊高 53 设计像素，半径取半高。
  static const double inputRadius = 22;

  /// 列表行高：资料库 / 专家卡的行距 ≈ 215 设计像素
  static const double rowHeight = 64;

  /// 顶栏总高（含系统状态栏），单位 dp。
  ///
  /// 设计稿顶栏是「状态栏 y=35~72」+「标题带 y=163~293」，标题带结束后
  /// 到 y≈370 才出正文。换算成屏高：顶栏底边 ≈ 11.1%。
  /// 参数用逻辑屏高 dp（`MediaQuery.size.height`，**不含**状态栏高度）。
  static double topBarHeight(double screenHeight) =>
      screenHeight * kTopBarRatio + 6;

  /// 设计稿里「内容首行」的 y：资料库搜索框 394 / 专家分类 520。
  static const double kContentTopY = 394;

  /// 设计稿里「分段 Tab 行」的 y（资料库 `最近/我的资料/团队空间` 589~647）。
  static const double kSegTabY = 618;

  /// 设计稿里「底部导航」内容区顶边 y（标签 2567 往上留出图标空间）。
  static const double kNavTopY = 2480;

  /// 设计稿里「输入胶囊」的下沿（`发消息或按住说话` y=2301~2354）。
  static const double kInputBottomY = 2354;
}

/// 顶栏占"逻辑屏高"的比例。
///
/// 推导（以 1080x2400、dp=360x800 的机型为例）：
///   * `MediaQuery.size.height` = 800（**不含**状态栏），设计稿总高按 2640 像素计，
///     状态栏在其中占 72 像素 → 设计稿"可用高"≈ 800 * (2640-72)/2640 = 778 dp。
///   * 顶栏底边在设计稿里是 y=293 → 778 * 293/2640 = 86.4 dp
///     → 86.4 / 800 = 10.8%。
/// 所以 0.102 这个系数在任何屏高下都能让顶栏底边落在设计稿的 11.1% 附近。
const double kTopBarRatio = 0.102;

/// 全局主题。**跟着当前皮肤走**：换肤时上层先 `DshColors.applySkin(...)`
/// 再重建 `MaterialApp`，这里每次都现算一份 ThemeData。
///
/// 刻意只用 Flutter 原生组件 + 自定义绘制，不引入第三方 UI 库 ——
/// arm64 release 包已经 186 MB，UI 库会让它继续膨胀。
ThemeData buildDshTheme() {
  final skin = DshColors.skin;
  final scheme = skin.isLight
      ? ColorScheme.light(
          primary: skin.accent,
          onPrimary: skin.onAccent,
          secondary: skin.accent2,
          onSecondary: skin.onAccent,
          surface: skin.surfaceStrong,
          onSurface: skin.text,
          error: skin.err,
        )
      : ColorScheme.dark(
          primary: skin.accent,
          onPrimary: skin.onAccent,
          secondary: skin.accent2,
          onSecondary: skin.onAccent,
          surface: skin.surfaceStrong,
          onSurface: skin.text,
          error: skin.err,
        );

  final base = ThemeData(
    brightness: skin.brightness,
    useMaterial3: true,
    // 像素皮肤换成等宽字体（其余皮肤用系统默认）—— 这是"大变样子"里最明显的一条，
    // 比换色显眼得多。为什么用系统等宽而不是随包像素字体：见 DshMetrics.fontFamily。
    fontFamily: DshMetrics.fontFamily,
    // 像素皮肤去掉水波纹（方块 UI 上那种圆形扩散很出戏）
    splashFactory: DshMetrics.pixelStyle ? NoSplash.splashFactory : null,
    // 背景交给最底层的「底色 + 网格」画（见 ui/theme/dsh_grid.dart）：
    // 页面与 AppBar 都透明，网格才能从底层透上来。
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: scheme,
  );

  // 像素皮肤：把我们**自己声明过的**那些文字样式也补上等宽字体。
  //
  // ⚠️ 为什么需要这一步：`ThemeData(fontFamily:)` 只影响"由主题推导出来的"
  // 那些样式；下面 `copyWith(textTheme: …)` / `appBarTheme.titleTextStyle` 是我们
  // 自己写的，不带 fontFamily 就会**盖掉**全局字体族 —— 像素皮肤于是只变颜色、
  // 字体没变（这正是用户说的"变化不大"的成因之一，自测当场抓到）。
  TextStyle skinFont(TextStyle s) =>
      DshMetrics.fontFamily == null ? s : s.copyWith(fontFamily: DshMetrics.fontFamily);

  return base.copyWith(
    dividerColor: skin.line,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: skinFont(TextStyle(
        color: skin.text,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      )),
      iconTheme: IconThemeData(color: skin.text),
    ),
    cardTheme: CardThemeData(
      color: skin.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      // 网站的卡片是「1px 细边 + 柔和光晕」，不是 Material 的投影
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.cardRadius)),
        side: BorderSide(color: skin.line, width: DshMetrics.borderWidth),
      ),
    ),
    textTheme: TextTheme(
      // ⚠️ **bodyLarge 必须给**（2026-10-17 用户反馈「浅色主题下改工作区名看不清字」）：
      //    Material 的 `TextField` 默认就取 `textTheme.bodyLarge` 当输入文字样式。
      //    这里原来是**一张只声明了 4 个样式的 TextTheme**，bodyLarge 为 null ——
      //    于是 `EditableText.style.color` 实测就是 `null`，颜色只能靠层层继承兜底，
      //    浅色皮肤下最终落成次要灰（实测像素 #566A8D，即 textDim），在白底上就"看不清"。
      //    补上正文色后，所有输入框（对话输入条、新建工作区、搜索…）一次性都对。
      bodyLarge: skinFont(TextStyle(
          color: skin.text,
          fontSize: 16,
          height: 1.5,
          letterSpacing: DshMetrics.letterSpacing)),
      bodyMedium: skinFont(TextStyle(
          color: skin.text,
          fontSize: 14,
          height: 1.5,
          letterSpacing: DshMetrics.letterSpacing)),
      bodySmall: skinFont(TextStyle(
          color: skin.textDim,
          fontSize: 12,
          height: 1.45,
          letterSpacing: DshMetrics.letterSpacing)),
      titleMedium: skinFont(TextStyle(
        color: skin.text,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: DshMetrics.letterSpacing,
      )),
      labelSmall: skinFont(TextStyle(
          color: skin.textFaint,
          fontSize: 11,
          letterSpacing: DshMetrics.letterSpacing)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // ⚠️ **输入框必须用不透明的 [DshPalette.fieldFill]**（用户 2026-10-15 反馈）。
      //
      // 原来这里是「浅色用 surfaceHigh、深色用 surface」—— 深色下 `surface`
      // 只有 **7% 白**，等于没有底：用户一边打字一边看到字形和页面渐变/消息流
      // 混在一起，反馈原话是「输入文字的时候和底版混在一起看不清」。
      //
      // 这里不动 `surface` 本身（它是玻璃卡的设计语言，测试也钉住了"深色
      // surface 必须 < 0.2 alpha"），只把**输入框**这一类换成实色。
      fillColor: skin.fieldFill,
      hintStyle: TextStyle(color: skin.textFaint, fontSize: 13.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.fieldRadius)),
        borderSide: BorderSide(color: skin.line, width: DshMetrics.borderWidth),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.fieldRadius)),
        borderSide: BorderSide(color: skin.line, width: DshMetrics.borderWidth),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.fieldRadius)),
        borderSide: BorderSide(color: skin.accent, width: DshMetrics.borderWidth),
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: skin.accent,
        foregroundColor: skin.onAccent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        ),
        textStyle: skinFont(
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: skin.accent),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: skin.text,
      unselectedLabelColor: skin.textDim,
      indicatorColor: skin.accent,
      dividerColor: Colors.transparent,
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 14),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: skin.accent),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: skin.surfaceStrong,
      contentTextStyle: TextStyle(color: skin.text, fontSize: 13),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.controlRadius)),
        side: BorderSide(color: skin.line, width: DshMetrics.borderWidth),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: skin.surfaceStrong,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DshMetrics.radius(DshMetrics.panelRadius)),
        side: BorderSide(color: skin.line, width: DshMetrics.borderWidth),
      ),
      titleTextStyle: TextStyle(
        color: skin.text,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle:
          TextStyle(color: skin.textDim, fontSize: 13, height: 1.5),
    ),
    // ⚠️ **弹层底色必须不透明**（用户 2026-10-12 第 4 条：
    //    「有些弹出的面板透明度太高，能背景的字体，降低透明度」）。
    //
    //    这里原来是 `Colors.transparent` —— 而 `showModalBottomSheet` 不传
    //    backgroundColor 时就用主题这个值，于是**页面的文字直接从弹层底下透上来**。
    //    深色下尤其明显：`surfaceHigh` / `navBg` 都只有 10~12% 白。
    //    弹层是"盖在内容上的板子"，不是磨砂玻璃 —— 用**完全不透明**的 surfaceStrong
    //    （浅色 #FFFFFF / 深色 #262E33），文字对比度立刻回到可读区间。
    //
    //    注意：**没有**动 `panel()` 的默认色 —— 页面内那些卡片本来就该透出一点底
    //    （"半透明白玻璃"是这套皮肤的设计语言）。只改"弹出来盖住内容"的那些。
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: skin.surfaceStrong,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
