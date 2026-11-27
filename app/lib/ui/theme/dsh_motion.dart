import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'dsh_tokens.dart';

/// 动效与玻璃质感的统一参数（会话页 / 首页高频组件共用）。
///
/// ## 这一层是什么、不是什么
///
/// 它只提供**曲线、时长、按压反馈、玻璃装饰**四样，不含任何页面逻辑。
/// 页面组件照这些参数写自己的动画，于是整个 App 的"手感"是同一套 ——
/// 而不是每个按钮自己挑一个时长。
///
/// 曲线与时长取自 Lucian UX/UI Prompt 的主题令牌（MIT License (c) 2026
/// Seokwoooo，https://lucianlabs.dev/uxui-prompt/）：该库的元素是纯 HTML/CSS/JS，
/// 无法直接进 Flutter，但 `cubic-bezier()` 是标准曲线定义，可以**按坐标原样
/// 换算**成 Flutter 的 [Cubic] —— 这是一处可行性判断（能换算 / 为什么能），
/// 不涉及任何代码取用。
///
/// 两根曲线的分工（照原库语义）：
///   * [ease]：常规过渡（透明度、位移、尺寸）—— 出去快、收尾稳，不回弹；
///   * [spring]：**会"过冲再回来"**的那类（按压反馈、状态弹入、加载收拢）。
///
/// ⚠️ 像素皮肤（[DshMetrics.pixelStyle]）是"硬方块"的视觉语言，动效要**更短
/// 更硬**（见 [of]：它把时长压到 60% 并换成线性出弯）——否则方角配上软弹簧
/// 会像两个 App。
class DshMotion {
  const DshMotion._();

  /// 常规过渡曲线：`cubic-bezier(.2,.8,.2,1)`。
  static const Curve ease = Cubic(0.2, 0.8, 0.2, 1);

  /// 带过冲的弹簧曲线：`cubic-bezier(.34,1.45,.64,1)`。
  ///
  /// y 值超过 1 是**刻意的**（这就是"过冲"），Flutter 的 [Cubic] 允许 y 出界。
  static const Curve spring = Cubic(0.34, 1.45, 0.64, 1);

  /// 微反馈（按压、hover 光斑、提示浮现）。
  static const Duration fast = Duration(milliseconds: 180);

  /// 常规状态切换（边框聚焦、颜色过渡、展开收起）。
  static const Duration base = Duration(milliseconds: 350);

  /// 弹入 / 收拢（加载态 ↔ 完成态）。
  static const Duration state = Duration(milliseconds: 550);

  /// 大形变（胶囊收成方块那类宽度变化）。
  static const Duration expand = Duration(milliseconds: 700);

  /// 按下时的形变（等比压到 0.92，回弹走 [spring]）。
  ///
  /// 原设计是非等比 `scale(1.03, .92)`（横胀纵扁，像水滴被按住）—— 那是给
  /// 252×78 的**大胶囊**用的；本 App 的按钮是 46dp 圆钮，非等比会压成椭圆，
  /// 所以这里统一等比。大胶囊将来若要用非等比，走 `Transform` +
  /// `Matrix4.diagonal3Values`（`AnimatedScale` 只接受等比 double）。
  static const double pressRound = 0.92;

  /// 取当前皮肤下的动效参数：像素皮肤更短更硬。
  ///
  /// 返回的时长已按皮肤折算，调用方直接用，不要在这里再乘系数。
  static ({Duration fast, Duration base, Duration state, Duration expand})
      of() {
    // 玻璃拟态：**快速弹入**（用户 2026-11-13 选题里的第四点）。
    //
    // 为什么比默认更快：玻璃面本身有厚度感，动效如果按默认 350ms 慢慢飘，
    // 观感是"沉重的水";压到 220ms 才像"弹了一片玻璃出来"。
    // 弹簧曲线（[spring]，y 过冲 1.45）配短时长 = 弹一下就位。
    if (DshMetrics.glassStyle) {
      return (
        fast: const Duration(milliseconds: 120),
        base: const Duration(milliseconds: 220),
        state: const Duration(milliseconds: 320),
        expand: const Duration(milliseconds: 380),
      );
    }
    if (!DshMetrics.pixelStyle) {
      return (fast: fast, base: base, state: state, expand: expand);
    }
    // 像素风：时长压到 60%，曲线用线性出弯（方角 + 软弹簧会露馅）。
    return (
      fast: const Duration(milliseconds: 110),
      base: const Duration(milliseconds: 210),
      state: const Duration(milliseconds: 330),
      expand: const Duration(milliseconds: 420),
    );
  }
}

/// 玻璃质感的装饰构造（面板 / 胶囊按钮共用）。
///
/// ## 为什么玻璃渐变只给"不压正文"的部件用
///
/// 输入框的底必须**不透明**（[DshColors.fieldFill]，`contrast_test` 钉死了
/// 「文字压在 fieldFill 上要过 AA」）—— 半透明白玻璃会让键入的字重新和页面
/// 渐变糊在一起，那是用户 2026-10-15 明确反馈过的问题。
///
/// 所以分工是：
///   * **输入框**：实底 + [rim] 描边（顶部高光那条也走描边），**不用**玻璃渐变；
///   * **按钮 / 消息卡片**：可以 [capsule] / [panel]（上面压的是高对比文字）。
class DshGlass {
  const DshGlass._();

  // ── 玻璃拟态（glassStyle 皮肤专用）────────────────────────────────
  //
  // 用户 2026-11-13 选题「玻璃拟态」：真模糊层叠 + 高光边 + 悬浮卡片 + 快速弹入。
  //
  // ## 性能边界（手机上必须克制）
  //
  // `BackdropFilter` 每帧要对**背后已绘制的像素**做一次高斯模糊，代价随面积
  // 线性上涨。实测经验：满屏一张 ≈ 3–5ms，列表里滚动的十几张卡会直接掉帧。
  // 所以这里**分级**：
  //   * [surface]（真模糊）：只给"长期可见的少数面" —— 底部导航、面板、弹层、
  //     输入条外壳。这些同一屏内通常 1–3 个。
  //   * [panel] / [capsule]（伪玻璃）：给列表里的卡片与按钮 —— 高光边 +
  //     半透明渐变 + 悬浮投影造出玻璃感，**不**逐帧模糊。
  // 这个取舍写在代码里，免得下一个人"顺手给卡片也加个 blur"然后把帧率打穿。

  /// 玻璃拟态是否生效（只有泡泡白 / 泡泡夜两套皮肤打开）。
  static bool get enabled => DshColors.skin.glassStyle;

  /// 真模糊的 sigma。18 是"能看出透光、又不会糊成一片"的档位。
  ///
  /// 浅色下给 22（白玻璃更透才像玻璃）、深色下给 18（再高会发灰）。
  static double get blurSigma => DshColors.isLight ? 22 : 18;

  /// **真模糊的玻璃面**（玻璃拟态皮肤专用薄层）。
  ///
  /// 参数是「背后要透过什么」——调用方只需把内容放进来，其余交给这层。
  /// 非玻璃皮肤下退化成 [panel]（同一个外观契约，调用方不用分支）。
  ///
  /// [radius] 走 [DshMetrics.radius]，像素皮肤自动变方角。
  static Widget surface({
    required Widget child,
    double radius = 18,
    double sigma = -1,
    Color? tint,
    EdgeInsetsGeometry? padding,
  }) {
    final r = DshMetrics.radius(radius);
    if (!enabled) {
      return Container(
        decoration: panel(radius: radius),
        padding: padding,
        child: child,
      );
    }
    // 玻璃体：填充色压得很淡（真正的"色"由背后的模糊承担），
    // 只留一点点 tint 让面有归属感。
    final fill = tint ??
        (DshColors.isLight
            ? const Color(0x59FFFFFF) // 35% 白
            : const Color(0x14FFFFFF)); // 8% 白 —— 深色下再多就发灰
    final content = Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(r),
      ),
      padding: padding,
      child: child,
    );
    return _GlassShell(
      radius: r,
      sigma: sigma < 0 ? blurSigma : sigma,
      child: content,
    );
  }

  /// 玻璃底的三段白渐变（150° 方向）。
  ///
  /// 浅色下白玻璃要"亮"（`.66 → .16 → .4`），深色下要"淡"（`.2 → .03 → .1`），
  /// 否则深色界面会出现一块发灰的白斑。
  static List<Color> _sheen() {
    if (DshColors.isLight) {
      return const <Color>[
        Color(0xA8FFFFFF), // rgba(255,255,255,.66)
        Color(0x29FFFFFF), // rgba(255,255,255,.16)
        Color(0x66FFFFFF), // rgba(255,255,255,.40)
      ];
    }
    return const <Color>[
      Color(0x33FFFFFF), // rgba(255,255,255,.20)
      Color(0x08FFFFFF), // rgba(255,255,255,.03)
      Color(0x1AFFFFFF), // rgba(255,255,255,.10)
    ];
  }

  /// 玻璃描边：1px 同色一圈（受光面那条 1.5px 亮线**做不了**，见下）。
  ///
  /// ## 为什么不是"顶亮边暗"的分边描边
  ///
  /// 原设计是两条 `inset box-shadow`（顶 1.5px 高光 + 1px 玻璃边）。我第一版
  /// 按 `Border(top: 1.5px 亮, 其余 1px 暗)` 实现 —— **渲染时直接撞断言**：
  /// Flutter 的 `Border.paint` 在 `BoxDecoration.borderRadius != null` 时要求
  /// 四条边**颜色与宽度完全一致**（`box_border.dart` 的
  /// "A borderRadius can only be given on borders with uniform colors"），
  /// 因为圆角处无法在两种颜色间过渡。真机上这会让整块面板画不出来。
  ///
  /// 结论（可行性判断）：**Flutter 里"带圆角的分边异色描边"不存在**。
  /// 立体感改由两样已有东西承担：三段白渐变（本身就是上亮下暗）+ 双层柔投影。
  /// 想要顶部那条硬高光，只能在内部叠一条独立的线（`Stack` + `Positioned`），
  /// 那会多一层命中测试与裁剪，本轮不值当 —— 记在这里，将来真要再做。
  static Border rim({Color? edge}) {
    final ln =
        edge ?? (DshColors.isLight ? const Color(0xA6FFFFFF) : const Color(0x29FFFFFF));
    return Border.all(color: ln, width: 1);
  }

  /// 玻璃胶囊（发送键、模型胶囊这类小件）。
  ///
  /// [radius] 走 [DshMetrics.radius]，像素皮肤自动变方角。
  static BoxDecoration capsule({double radius = 22, List<BoxShadow>? shadow}) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: _sheen(),
        stops: const <double>[0.0, 0.55, 1.0],
      ),
      borderRadius: BorderRadius.circular(DshMetrics.radius(radius)),
      border: rim(),
      boxShadow: shadow ?? _softShadow(),
    );
  }

  /// 玻璃面板（消息卡片、次级面板）。
  ///
  /// 比 [capsule] 淡一档：卡片是"面"，按钮是"件"，同一亮度会让页面失去层次。
  static BoxDecoration panel({double radius = 18, List<BoxShadow>? shadow}) {
    final sheen = _sheen()
        .map((c) => c.withValues(alpha: c.a * 0.6))
        .toList(growable: false);
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: sheen,
        stops: const <double>[0.0, 0.55, 1.0],
      ),
      borderRadius: BorderRadius.circular(DshMetrics.radius(radius)),
      border: rim(edge: DshColors.line),
      boxShadow: shadow ?? _softShadow(),
    );
  }

  /// 常规柔投影：大而散的一层 + 贴地的一层（原设计是 `0 26px 44px -22px`
  /// 与 `0 3px 8px -4px` 两道，色随皮肤的强调色走）。
  static List<BoxShadow> _softShadow() {
    final drop = DshColors.isLight
        ? const Color(0x6B4630A0) // rgba(70,48,160,.42)
        : const Color(0xBF000000); // rgba(0,0,0,.75)
    // 玻璃拟态：**悬浮卡片**要"浮"起来 —— 投影更大更远、再补一层近身细影。
    // 三层阴影是材料设计里"高海拔"的标准配方（远柔和 + 近锐利）。
    if (DshMetrics.glassStyle) {
      return <BoxShadow>[
        BoxShadow(
            color: drop, blurRadius: 56, offset: const Offset(0, 30),
            spreadRadius: -20),
        BoxShadow(
            color: drop, blurRadius: 18, offset: const Offset(0, 8),
            spreadRadius: -8),
        BoxShadow(
            color: drop.withValues(alpha: drop.a * 0.6),
            blurRadius: 5, offset: const Offset(0, 2), spreadRadius: -2),
      ];
    }
    return <BoxShadow>[
      BoxShadow(color: drop, blurRadius: 44, offset: const Offset(0, 26), spreadRadius: -22),
      BoxShadow(color: drop, blurRadius: 8, offset: const Offset(0, 3), spreadRadius: -4),
    ];
  }

  /// 按压缩放的包装：按下压下去、松手用 [DshMotion.spring] 弹回。
  ///
  /// 统一等比压到 [DshMotion.pressRound] —— 圆形按钮按非等比会变椭圆，
  /// 而 `AnimatedScale` 本身也只接受等比 double（见 [DshMotion.pressRound]）。
  static Widget pressable({
    required Widget child,
    required bool enabled,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
    Duration? duration,
  }) {
    final d = duration ?? DshMotion.of().fast;
    return PressDetector(
      enabled: enabled,
      onTap: onTap,
      onLongPress: onLongPress,
      builder: (pressed) => AnimatedScale(
        // 按下用 ease（干脆地压下去），松手用 spring（过冲一下再落位）。
        scale: !enabled || !pressed ? 1.0 : DshMotion.pressRound,
        duration: d,
        curve: pressed ? DshMotion.ease : DshMotion.spring,
        child: child,
      ),
    );
  }
}

/// 按下状态的透传包装（给 [DshGlass.pressable] 用，也方便页面自己组合）。
///
/// 为什么不用 Material 自带的 [InkWell]：它给的是水波纹，而这里要的是
/// **整块形变**（按下去缩一下）。两者可以并存，但形变必须由外层持有状态。
class PressDetector extends StatefulWidget {
  const PressDetector({
    super.key,
    required this.builder,
    required this.enabled,
    this.onTap,
    this.onLongPress,
  });

  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget Function(bool pressed) builder;

  @override
  State<PressDetector> createState() => _PressDetectorState();
}

class _PressDetectorState extends State<PressDetector> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.enabled ? (_) => _set(true) : null,
      onTapUp: widget.enabled ? (_) => _set(false) : null,
      onTapCancel: widget.enabled ? () => _set(false) : null,
      onTap: widget.enabled ? widget.onTap : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      child: widget.builder(_pressed),
    );
  }
}

/// 真模糊玻璃壳：`BackdropFilter` + 渐变高光边。
///
/// ## 为什么要单独一个 widget
///
/// `BackdropFilter` 必须被**裁剪**到圆角内，否则模糊会溢出到方角区域；
/// 而"高光边"在 Flutter 里拿不到渐变描边（`BoxDecoration.border` 只吃单色，
/// 且带圆角时四条边必须同色 —— 见 [DshGlass.rim] 的说明）。
///
/// 所以这里是两层：
///   1. 外层 `Container` 画**渐变**（左上亮 → 右下暗），只露出 1.2dp 边；
///   2. 内层 `ClipRRect + BackdropFilter` 做真模糊，并把内容盖在模糊之上。
///
/// 这就是常见"渐变玻璃描边"的做法：**描边不是描边，是底色露出来的一圈**。
class _GlassShell extends StatelessWidget {
  const _GlassShell({
    required this.child,
    required this.radius,
    required this.sigma,
  });

  final Widget child;
  final double radius;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    // ⚠️ **不要**改回「外层渐变铺满 + 内层留 1.2dp」那个做法。
    //
    // 2026-11-16 真机踩到：内层 child 的底是半透明的（glass 分支用 7% 白），
    // 外层那片 54% 白的渐变会**从里面透出来**，在近黑底（泡泡夜）上表现为
    // 整张卡片发灰、文字像隔了一层雾。浅色主题下背景本来就是白纸，
    // 所以测试渲染的截图里完全看不出来 —— 只有真机能暴露。
    //
    // 现在用单色 border：边只占 border 那 1.2dp，不渗进内容层。
    // 代价是没有「左上亮、右下暗」的渐变厚度感，换来的是夜色下的可读性。
    final edge = DshColors.isLight
        ? const Color(0x99FFFFFF)
        : const Color(0x40FFFFFF);

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        // tileMode 必须是 clamp：默认的 decal 在边界会透出透明像素，
        // 圆角处会出现一圈"没模糊到"的亮边（实测可见）。
        filter: ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: edge, width: 1.2),
          ),
          child: child,
        ),
      ),
    );
  }
}
