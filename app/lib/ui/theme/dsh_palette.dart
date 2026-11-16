import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';

/// 一套皮肤（skin）的完整色板。
///
/// 为什么要有这个类：改造之前配色是 `DshColors` 里的一堆 `static const Color`，
/// 编译期就定死了，运行时换不了。现在把「值」搬进 [DshPalette]（一个普通对象），
/// `DshColors.x` 变成读当前皮肤的 getter，换肤就是换一个引用 —— 见
/// `dsh_tokens.dart` 的 `DshColors.applySkin`。
///
/// 色值出处（**不是凭感觉配的**）：https://soft.zmm168.top/ 的 `site.css`，
/// 站点名「泡泡猫 · STELLAR DOCK · 星际港湾」，默认浅色、青紫渐变、玻璃面板。
/// 浅色皮肤逐条对齐它的设计令牌；深色皮肤见 [DshPalettes.dark] 的说明。
@immutable
class DshPalette {
  const DshPalette({
    required this.id,
    required this.label,
    required this.brightness,
    required this.bg,
    required this.bgSoft,
    // ── 背景柔光（顶部径向渐变的亮色）
    //    深色界面里**阴影是看不见的**（深色阴影叠在深色底上没有对比），
    //    层次只能靠亮度差 —— 这就是 Material 的 "tonal elevation" 思路。
    //    见 ui/theme/dsh_grid.dart。
    required this.bgGlow,
    // ── 面板（半透明玻璃）
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceStrong,
    required this.fieldFill,
    required this.navBg,
    // ── 描边
    required this.line,
    required this.line2,
    // ── 强调色（青 → 紫 → 粉）
    required this.accent,
    required this.accent2,
    required this.accent3,
    required this.accentDim,
    required this.onAccent,
    // ── 文字
    required this.text,
    required this.textDim,
    required this.textFaint,
    // ── 代码块（网站里浅色页也用深蓝代码块）
    required this.codeBg,
    required this.codeBg2,
    required this.codeText,
    required this.codeMuted,
    // ── 气泡与语义色
    required this.userBubble,
    required this.aiBubble,
    required this.ok,
    required this.busy,
    required this.err,
    required this.onOk,
    /// 圆角缩放（1.0 = 设计稿原样）。**像素风把它设成 0** —— 方角是像素风的一半识别度。
    ///
    /// ⚠️ 只给默认值、不加 `required`：浅色/深色两套皮肤一行都不用改。
    this.radiusScale = 1.0,
    /// 像素/终端皮肤：**换一整套视觉**，不只是换色。
    ///
    /// 用户 2026-10-15 第 6 条原话：「像素主题变化不大或者说根本没有变化，
    /// 我要的是大变样子，界面字体风格和其他两个完全不一样的」。
    /// 它一开：字体换等宽（`DshMetrics.fontFamily`）、描边加粗到 2dp、
    /// 面板改成不透明实心板、投影换成**无模糊的硬方块**、底纹加扫描线。
    this.pixelStyle = false,
    /// **玻璃拟态**皮肤：真模糊层叠 + 高光描边 + 悬浮投影 + 快速弹入。
    ///
    /// 与 [pixelStyle] 同一个位置 —— 两者都是"换一整套形态"的总闸，
    /// 由 `DshGlass` / `DshMotion` 读，**不要在页面里直接判皮肤 id**。
    ///
    /// 用户 2026-11-13 选定（原话只回了一个「3」，对应我给的三个方向里的
    /// 第三档：玻璃拟态）。他此前对"只换色"的评价是「变化不大」，
    /// 所以这一档必须做到**一眼能认出来**：能透过面看到背后的东西。
    this.glassStyle = false,
    // ── 光晕阴影
    required this.panelShadow,
    required this.accentShadow,
  });

  /// 稳定标识（用于持久化与 UI 选中判断）：`light` / `dark`。
  final String id;

  /// 给用户看的名字。
  final String label;

  final Brightness brightness;

  /// 页面底色（`--bg`）
  final Color bg;

  /// 次一级底色（`--bg-1`），弹层/空态块用
  final Color bgSoft;

  /// 背景柔光色：画在底色之上、从屏幕上方往下扩散的一层径向渐变。
  ///
  /// 用途是制造"上亮下沉"的空间感。**为什么不用网格线**：用户实测反馈
  /// 网格看着廉价、且线条会和正文抢注意力；而深色设计的通行做法
  /// （Linear / Arc / Raycast 等都是）是**用亮度分级与柔和渐变做层次**，
  /// 不是贴纹理。见 ui/theme/dsh_grid.dart 的说明。
  final Color bgGlow;

  /// 面板 / 卡片（浅色 = `--panel` rgba(255,255,255,.72)）
  final Color surface;

  /// 再亮一档的面板（输入框、次级卡片）
  final Color surfaceHigh;

  /// 最实的面板（不透明，用于需要绝对清晰的地方）
  final Color surfaceStrong;

  /// **输入框的填充色 —— 必须是不透明的**（用户 2026-10-15 反馈：
  /// 「面板透明度太高……比如会话的面板，目前现状是输入文字的时候和底版
  /// 混在一起看不清」）。
  ///
  /// ## 为什么单列一个令牌，而不是继续用 [surface]
  ///
  /// 深色皮肤下 `surface` 只有 **7% 白**（`0x12FFFFFF`）—— 那是"玻璃卡片"
  /// 的设计语言，卡片里透出一点页面渐变是**刻意的**。但输入框不是卡片：
  /// 它上面要**压一段用户正在键入的文字**，而 7% 白几乎等于没有底，
  /// 于是字形和页面渐变/消息流混在一起，读起来就是"看不清"。
  ///
  /// 也不能直接把 `surface` 改实：`theme_skin_test` 钉住"深色 surface 的
  /// alpha < 0.2"（面板该半透），而且全 App 的卡片都吃它 —— 改一处会把所有
  /// 玻璃卡变成实心板。
  ///
  /// 所以这里给输入框单独一个**不透明**的填充：它只用于
  /// `inputDecorationTheme` 与输入组件（见 `ui/widgets/input_bar.dart`），
  /// 不影响任何卡片的通透感。
  final Color fieldFill;

  /// 顶栏 / 底部导航
  final Color navBg;

  /// 1px 细边（浅色 = `--line` rgba(32,74,150,.15)）
  final Color line;

  /// 强一点的细边（浅色 = `--line-2` rgba(32,96,190,.32)），焦点/选中态用
  final Color line2;

  /// 主强调色（浅色 = `--accent` #0891b2 青）
  final Color accent;

  /// 第二强调色（浅色 = `--accent-2` #7c3aed 紫）
  final Color accent2;

  /// 第三强调色（浅色 = `--accent-3` #db2777 粉）
  final Color accent3;

  /// 强调色的淡化底（选中项底色，带 alpha 的半透明层）
  final Color accentDim;

  /// 压在强调色上的前景色（浅色底上用白，深色霓虹青上用深色）
  final Color onAccent;

  /// 正文
  final Color text;

  /// 次要文字（浅色 = `--muted`）
  final Color textDim;

  /// 更弱的提示文字（浅色 = `--dim`）
  final Color textFaint;

  /// 代码块底色（浅色 = `--code-bg` #0f1729，**浅色页里也是深蓝**）
  final Color codeBg;
  final Color codeBg2;
  final Color codeText;
  final Color codeMuted;

  /// 用户气泡 / 助手气泡
  final Color userBubble;
  final Color aiBubble;

  /// 成功 / 进行中 / 失败
  final Color ok;
  final Color busy;
  final Color err;

  /// 压在 [ok] 上的前景色（浅色皮肤下 ok 是深绿，得配白字）
  final Color onOk;

  /// 圆角缩放（见构造里的说明）。
  /// 是不是"像素/终端"那套视觉（总闸在 `DshMetrics.pixelStyle`，别在别处判皮肤 id）。
  final bool pixelStyle;

  /// 玻璃拟态（见构造参数说明）。`radiusScale` 之外，这一档还改模糊、描边、
  /// 投影与动效时长 —— 具体在 `DshGlass` / `DshMotion` 里体现。
  final bool glassStyle;

  final double radiusScale;

  /// 面板光晕（浅色 = `--glow-soft` 0 18px 44px -24px rgba(24,50,100,.30)）
  final List<BoxShadow> panelShadow;

  /// 强调光晕（浅色 = `--glow-accent` 0 10px 26px -14px rgba(8,145,178,.55)）
  final List<BoxShadow> accentShadow;

  bool get isLight => brightness == Brightness.light;

  /// `--grad`：120deg 青 → 紫。主按钮、当前项、进度用这个。
  LinearGradient get grad => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[accent, accent2],
      );

  /// `--grad-3`：accent → accent-2 55% → accent-3。
  LinearGradient get grad3 => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[accent, accent2, accent3],
        stops: const <double>[0.0, 0.55, 1.0],
      );
}

/// 两个皮肤的实例。
class DshPalettes {
  const DshPalettes._();

  /// 浅色皮肤 —— **逐条对齐网站 `site.css` 的浅色令牌**：
  ///
  /// ```
  /// --bg:#eef3fb --bg-1:#e5ecf8
  /// --panel:rgba(255,255,255,.72) --panel-strong:rgba(255,255,255,.94) --panel-solid:#fff
  /// --line:rgba(32,74,150,.15) --line-2:rgba(32,96,190,.32)
  /// --text:#0c1a33 --muted:#566a8d --dim:#6e80a3
  /// --accent:#0891b2 --accent-2:#7c3aed --accent-3:#db2777
  /// --ok:#0f9d58 --warn:#a16207
  /// --code-bg:#0f1729 --code-bg-2:#16203a --code-text:#e8eefc --code-muted:#93a2c6
  /// --glow-soft:0 18px 44px -24px rgba(24,50,100,.30)
  /// --glow-accent:0 10px 26px -14px rgba(8,145,178,.55)
  /// ```
  ///
  /// 0.72 → 0xB8、0.94 → 0xF0（alpha 字节）。面板刻意**不做到纯白**：
  /// 网站那种"半透明白玻璃 + 1px 细边"的观感靠的就是底下的 `--bg` 透上来。
  static DshPalette get light => DshPalette(
        id: 'light',
        label: tr('浅色'),
        brightness: Brightness.light,
        bg: const Color(0xFFEEF3FB),
        bgSoft: const Color(0xFFE5ECF8),
        // 浅色下的"柔光"就是纯白：让顶部比底部亮一档，思路与深色一致
        bgGlow: const Color(0xFFFFFFFF),
        surface: const Color(0xB8FFFFFF),
        surfaceHigh: const Color(0xF0FFFFFF),
        surfaceStrong: const Color(0xFFFFFFFF),
        // 输入框填充：**不透明**（浅色=纯白）。见 [DshPalette.fieldFill] 的说明。
        fieldFill: const Color(0xFFFFFFFF),
        navBg: const Color(0xF2FFFFFF),
        line: const Color(0x26204A96),
        line2: const Color(0x522060BE),
        // 审计 P1-7：#0891B2 在浅底上只有 3.30（accent 也用于小字/链接）。
        // 同色相压暗到刚好达标：4.84 / 4.54。**这是一处可见的品牌色变化**
        // （按钮填充上的白字对比度反而更好）。不接受可以只回退这一行。
        accent: const Color(0xFF06748E),
        accent2: const Color(0xFF7C3AED),
        accent3: const Color(0xFFDB2777),
        accentDim: const Color(0x240891B2),
        onAccent: const Color(0xFFFFFFFF),
        text: const Color(0xFF0C1A33),
        textDim: const Color(0xFF566A8D),
        // 审计 P1-7：原来是 #6E80A3（/bg 3.57、/bgSoft 3.35，**低于 AA 的 4.5**），
        // 而它在 lib 下有 215 处引用、大量是 10.5px 小字 —— 不是点缀色。
        // 按「同色相最浅的达标值」取（改动最小）：4.82 / 4.52。
        textFaint: const Color(0xFF5C6B88),
        codeBg: const Color(0xFF0F1729),
        codeBg2: const Color(0xFF16203A),
        codeText: const Color(0xFFE8EEFC),
        codeMuted: const Color(0xFF93A2C6),
        userBubble: const Color(0x260891B2),
        aiBubble: const Color(0xE6FFFFFF),
        ok: const Color(0xFF0F9D58),
        // 审计 P1-7：#A16207 是 4.42（略低于 AA）→ 4.80 / 4.51。
        busy: const Color(0xFF995D07),
        err: const Color(0xFFC0273C),
        onOk: const Color(0xFFFFFFFF),
        panelShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x4D183264),
            blurRadius: 44,
            offset: Offset(0, 18),
            spreadRadius: -24,
          ),
        ],
        accentShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x8C0891B2),
            blurRadius: 26,
            offset: Offset(0, 10),
            spreadRadius: -14,
          ),
        ],
      );

  /// 深色皮肤 —— **底子沿用 App 原有的深色**（#131719 / #1C2828 那一套，
  /// 因为设计稿 11 页全是深色），但强调色换成网站的 accent 系在**深色下的同一族**：
  ///
  /// | 网站浅色 | 深色皮肤 | 来历 |
  /// |---|---|---|
  /// | `#0891b2` 青 | `#38e0f5` | 网站自己的深色代码块 `--code-accent`，同一个青族（色相 187°/193°） |
  /// | `#7c3aed` 紫 | `#a78bfa` | 同族提亮（色相 259°/258°） |
  /// | `#db2777` 粉 | `#f472b6` | 同族提亮（色相 333°/330°） |
  ///
  /// 为什么不直接把 `#0891b2` 拿来当深色主色：它在 #131719 上对比度只有约 2.5:1，
  /// 小字和图标会糊。网站自己的深色块也用的是提亮版 —— 这不是"另一个 App"，
  /// 是同一套设计语言的深色面。
  ///
  /// 文字用网站深色块的 `--code-text/--code-muted/--code-dim`，
  /// 细边用 `--code-line:rgba(140,175,255,.18)`（这里稍加强到 0.24 保证看得见）。
  /// 面板是**更亮的半透明层**（白色低 alpha 叠在深底上），不是把浅色的白面板搬过来。
  static DshPalette get dark => DshPalette(
        id: 'dark',
        label: tr('深色'),
        brightness: Brightness.dark,
        // 2026-10-05 按深色设计指南重调（用户反馈「背景不要太黑」）：
        //   指南明确「纯黑 #000000 会造成长时间阅读后的眼疲劳，应使用近黑
        //   #0A0A0A~#161616 区间」。这里保持原有**青色相**、把亮度整体抬一档，
        //   并给出一档柔光色 —— 层次靠亮度差做，不靠纹理（网格已撤掉）。
        bg: const Color(0xFF171C20),
        bgSoft: const Color(0xFF1C2226),
        bgGlow: const Color(0xFF232B31),
        surface: const Color(0x12FFFFFF),
        surfaceHigh: const Color(0x1FFFFFFF),
        surfaceStrong: const Color(0xFF262E33),
        // 输入框填充：**不透明**。深色下 `surface` 只有 7% 白，键入的字会和
        // 页面渐变糊在一起（用户 2026-10-15 实测反馈）。
        //
        // ⚠️ 值不是随手挑的：`contrast_test` 要求 **textFaint（占位提示字）
        // 在 fieldFill 上也过 AA 4.5**。fieldFill 只要比 bg(#171C20) 明显亮，
        // textFaint 的对比度就掉到 4.44（实测）—— 所以取「比 bg 略亮一点点」
        // 的 #1B2126：正文 #E8EEFC 约 13:1，textFaint 约 4.71，两边都过。
        // 框的位置靠描边（`line`）交代，不靠"把底调亮"。
        fieldFill: const Color(0xFF1B2126),
        navBg: const Color(0x1AFFFFFF),
        line: const Color(0x3D8CAFFF),
        line2: const Color(0x5C8CAFFF),
        accent: const Color(0xFF38E0F5),
        accent2: const Color(0xFFA78BFA),
        accent3: const Color(0xFFF472B6),
        accentDim: const Color(0x2E38E0F5),
        onAccent: const Color(0xFF04202A),
        text: const Color(0xFFE8EEFC),
        textDim: const Color(0xFF93A2C6),
        // 审计 P1-7：深色下 /bgSoft 只有 4.48，差一点点 → 4.98 / 4.66。
        textFaint: const Color(0xFF7A8AB0),
        codeBg: const Color(0xFF0F1729),
        codeBg2: const Color(0xFF16203A),
        codeText: const Color(0xFFE8EEFC),
        codeMuted: const Color(0xFF93A2C6),
        userBubble: const Color(0x2638E0F5),
        aiBubble: const Color(0x0FFFFFFF),
        ok: const Color(0xFF3EE89A),
        busy: const Color(0xFFE0B341),
        err: const Color(0xFFE06C6C),
        onOk: const Color(0xFF04201A),
        panelShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 44,
            offset: Offset(0, 18),
            spreadRadius: -24,
          ),
        ],
        accentShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x7338E0F5),
            blurRadius: 26,
            offset: Offset(0, 10),
            spreadRadius: -14,
          ),
        ],
      );

  /// 像素风（8-bit）皮肤 —— 用户 2026-10-12 要求「增加一个像素风的主题」。
  ///
  /// 它**不只是换色**：`radiusScale = 0` 让圆角变成直角（像素风的一半识别度在这），
  /// 配色则是"有限调色板 + 高饱和强调色"的 8-bit 观感。
  ///
  /// ⚠️ 对比度必须过 `contrast_test`（它遍历 `DshPalettes.all` 查 WCAG AA）：
  /// 正文/次要/强调色在 `bg` 与 `bgSoft` 上都要 ≥ 4.5。所以底色用**近黑**而不是纯黑
  /// （纯黑反而让亮色更刺眼，也更像"没调过的默认深色"）。
  static DshPalette get pixel => DshPalette(
        id: 'pixel',
        label: tr('像素'),
        brightness: Brightness.dark,
        radiusScale: 0,
        pixelStyle: true,
        // 近黑的靛蓝底（CRT 关着的那种感觉），刻意比深色皮肤更冷、更暗。
        bg: const Color(0xFF14161F),
        bgSoft: const Color(0xFF1B1E2A),
        bgGlow: const Color(0xFF2A3050),
        surface: const Color(0x14FFFFFF),
        surfaceHigh: const Color(0x22FFFFFF),
        surfaceStrong: const Color(0xFF232741),
        // 输入框填充：**不透明**（像素风的实心板子），见 [DshPalette.fieldFill]。
        fieldFill: const Color(0xFF1C2032),
        navBg: const Color(0x1AFFFFFF),
        line: const Color(0x4D8FA8FF),
        line2: const Color(0x6E8FA8FF),
        // 8-bit 那套高饱和：薄荷 / 洋红 / 琥珀。
        accent: const Color(0xFF57F2C1),
        accent2: const Color(0xFFFF8CE0),
        accent3: const Color(0xFFFFD166),
        accentDim: const Color(0x3357F2C1),
        onAccent: const Color(0xFF08211A),
        text: const Color(0xFFEAF0FF),
        textDim: const Color(0xFFA9B6D6),
        textFaint: const Color(0xFF8A97B8),
        codeBg: const Color(0xFF0B0D14),
        codeBg2: const Color(0xFF141826),
        codeText: const Color(0xFFD8E4FF),
        codeMuted: const Color(0xFF8593B5),
        userBubble: const Color(0x2657F2C1),
        aiBubble: const Color(0x0FFFFFFF),
        ok: const Color(0xFF5BE08A),
        busy: const Color(0xFFFFC24B),
        err: const Color(0xFFFF6B7A),
        onOk: const Color(0xFF04201A),
        // ⚠️ 像素皮肤的阴影是**无模糊的硬方块**（blurRadius 0 + 纯位移）——
        //    柔和光晕是材料感的语言，属于另两套皮肤；这里要的是"贴纸/像素块"。
        panelShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0xCC000000),
            blurRadius: 0,
            offset: Offset(4, 4),
          ),
          BoxShadow(
            color: Color(0x33FFFFFF),
            blurRadius: 0,
            offset: Offset(-2, -2),
          ),
        ],
        accentShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x9957F2C1),
            blurRadius: 0,
            offset: Offset(3, 3),
          ),
        ],
      );

  /// 「泡泡白」——暖白纸感 + 紫罗兰强调（Lucian 风格的浅色面）。
  ///
  /// 色值出处：Lucian UX/UI Prompt 的 `--ux-*` 主题令牌
  /// （MIT License (c) 2026 Seokwoooo，https://lucianlabs.dev/uxui-prompt/）。
  /// 这是一处**可行性判断**：该库的元素是纯 HTML/CSS/JS，无法直接进 Flutter，
  /// 但它的色板是标准 CSS 变量，可以按名逐条映射到本类的字段上 —— 所以这里
  /// 只取色值与层级关系，组件代码全部在 Dart 里重写。
  ///
  /// 与原令牌的三处**有意偏离**（都为过 `contrast_test` 的 WCAG AA）：
  ///   * `--ux-accent:#6A57F2` → `#5F4EEB`：原值在暖白底上只有 4.41，在更实的
  ///     次级底 `bgSoft` 上更低。同色相压暗到 **4.97 / 4.80**（首轮写 `#6452EE`
  ///     时 `bgSoft` 还是更深的 `#EAE7E1`，实测 4.27 挂了测试 —— 两个值必须一起定）。
  ///   * `--ux-ink-3:#8E8A97` → `#686472`：原值 3.01，压到 **5.14 / 4.96**。
  ///     `textFaint` 是占位提示字，全 App 有两百多处 10.5px 小字在用它。
  ///   * `--ux-warn:#D6731E` → `#9A5712`：原值 2.97，压到 **5.01 / 4.84**。
  ///
  /// 页面底取 `--ux-page`；次级底原计划取 `--ux-surface-3`（`#EAE7E1`，比底实
  /// 一档），但它把上面两个色压到 4.27/4.29 直接挂测试 —— 改取 `#F1EEE8`
  /// （在 `--ux-page` 与 `--ux-surface-3` 之间，亮度差 0.032，弹层仍有层次）。
  static DshPalette get lucianLight => DshPalette(
        id: 'lucian-light',
        label: tr('泡泡白'),
        glassStyle: true,
        brightness: Brightness.light,
        bg: const Color(0xFFF4F2EE),
        bgSoft: const Color(0xFFF1EEE8),
        bgGlow: const Color(0xFFFFFFFF),
        // `--ux-glass:rgba(255,255,255,.58)`
        surface: const Color(0x94FFFFFF),
        surfaceHigh: const Color(0xF0FFFFFF),
        surfaceStrong: const Color(0xFFFFFFFF),
        fieldFill: const Color(0xFFFFFFFF),
        navBg: const Color(0xF2FFFFFF),
        // `--ux-line:rgba(22,21,27,.09)` / `--ux-line-2:…,.17)`
        line: const Color(0x1716151B),
        line2: const Color(0x2B16151B),
        // `--ux-accent`（压暗后）/ `--ux-accent-2` / `--ux-grad` 第三色
        accent: const Color(0xFF5F4EEB),
        accent2: const Color(0xFF2F8FE0),
        accent3: const Color(0xFF1FB89A),
        accentDim: const Color(0x1F5F4EEB),
        onAccent: const Color(0xFFFFFFFF),
        // `--ux-ink` / `--ux-ink-2` / `--ux-ink-3`（faint 压暗后）
        text: const Color(0xFF16151B),
        textDim: const Color(0xFF57535F),
        textFaint: const Color(0xFF686472),
        // 代码块沿用本 App 的深蓝（Lucian 令牌没给代码色，这里不改设计语言）
        codeBg: const Color(0xFF0F1729),
        codeBg2: const Color(0xFF16203A),
        codeText: const Color(0xFFE8EEFC),
        codeMuted: const Color(0xFF93A2C6),
        userBubble: const Color(0x1F5F4EEB),
        aiBubble: const Color(0xE6FFFFFF),
        // `--ux-mint` 压暗（原值 3.12）
        ok: const Color(0xFF0E8A62),
        busy: const Color(0xFF9A5712),
        // `--ux-danger` 同族压暗，与本 App 浅色皮肤的 err 口径一致
        err: const Color(0xFFC73249),
        onOk: const Color(0xFFFFFFFF),
        // `--ux-shadow:rgba(40,30,80,.14)`，几何沿用本 App 的面板光晕
        panelShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x24281E50),
            blurRadius: 44,
            offset: Offset(0, 18),
            spreadRadius: -24,
          ),
        ],
        accentShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x8C5F4EEB),
            blurRadius: 26,
            offset: Offset(0, 10),
            spreadRadius: -14,
          ),
        ],
      );

  /// 「泡泡夜」——近黑底 + 淡紫霓虹（Lucian 风格的深色面）。
  ///
  /// 色值出处同 [lucianLight]（`--ux-*` 令牌的 dark 段）。
  /// 与原令牌的两处有意偏离：
  ///   * `--ux-ink-2/.68` → `#A8A6A2`、`--ux-ink-3/.42` → `#82817F`：
  ///     原令牌是**半透明**文字（要在页面上合成），本类的对比度是按不透明色
  ///     算的（`contrast()` 忽略 alpha），所以这里给的是**合成到 `--ux-page`
  ///     之后的不透明值** —— 口径不同，数值不能照抄。faint 合成后只有 3.66，
  ///     提到 0.52 透明度再合成才到 5.14 / 4.71。
  ///   * `--ux-warn` 等语义色直接用原值：深底上它们本来就过 AA。
  static DshPalette get lucianDark => DshPalette(
        id: 'lucian-dark',
        label: tr('泡泡夜'),
        glassStyle: true,
        brightness: Brightness.dark,
        bg: const Color(0xFF07080D),
        bgSoft: const Color(0xFF13141C),
        bgGlow: const Color(0xFF1A1B25),
        // `--ux-glass:rgba(255,255,255,.07)` —— 与深色皮肤同为 7% 白，
        // `theme_skin_test` 钉的「深色 surface alpha < 0.2」这条对它同样成立。
        surface: const Color(0x12FFFFFF),
        surfaceHigh: const Color(0x1AFFFFFF),
        surfaceStrong: const Color(0xFF252632),
        // 输入框填充必须不透明：`--ux-surface` 在深色下就是它
        fieldFill: const Color(0xFF13141C),
        navBg: const Color(0x14FFFFFF),
        line: const Color(0x14FFFFFF),
        line2: const Color(0x29FFFFFF),
        // `--ux-accent` / `--ux-accent-2` / `--ux-grad` 第三色
        accent: const Color(0xFFB7A4FF),
        accent2: const Color(0xFF7DB4FF),
        accent3: const Color(0xFFA5F2D3),
        accentDim: const Color(0x26B7A4FF),
        onAccent: const Color(0xFF0B0C12),
        // `--ux-ink` 与两档合成后的不透明值（见类注释）
        text: const Color(0xFFF4F0E8),
        textDim: const Color(0xFFA8A6A2),
        textFaint: const Color(0xFF82817F),
        codeBg: const Color(0xFF0B0C12),
        codeBg2: const Color(0xFF13141C),
        codeText: const Color(0xFFF4F0E8),
        codeMuted: const Color(0xFFA8A6A2),
        userBubble: const Color(0x26B7A4FF),
        aiBubble: const Color(0x0FFFFFFF),
        ok: const Color(0xFF7EE8C0),
        busy: const Color(0xFFFFB26B),
        err: const Color(0xFFFF7D8C),
        onOk: const Color(0xFF0B0C12),
        // `--ux-shadow:rgba(0,0,0,.45)`
        panelShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 44,
            offset: Offset(0, 18),
            spreadRadius: -24,
          ),
        ],
        accentShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x8CB7A4FF),
            blurRadius: 26,
            offset: Offset(0, 10),
            spreadRadius: -14,
          ),
        ],
      );

  /// 按持久化的 id 取皮肤；认不出来就退回深色（旧版本的默认值）。
  static DshPalette byId(String? id) {
    switch (id) {
      case 'light':
        return light;
      case 'dark':
        return dark;
      case 'pixel':
        return pixel;
      case 'lucian-light':
        return lucianLight;
      case 'lucian-dark':
        return lucianDark;
      default:
        return dark;
    }
  }

  /// 全部可选皮肤（UI 里按这个顺序画按钮）。
  static List<DshPalette> get all => <DshPalette>[
        light,
        dark,
        pixel,
        lucianLight,
        lucianDark,
      ];
}
