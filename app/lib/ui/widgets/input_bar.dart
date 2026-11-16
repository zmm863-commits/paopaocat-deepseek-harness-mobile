import 'package:flutter/material.dart';

import '../theme/dsh_motion.dart';
import '../theme/dsh_tokens.dart';

import '../../i18n/dsh_i18n.dart';

/// 底部输入区（设计稿每个对话页底部都是这个形态）。
///
/// **设计稿的纵向次序（这一条是我上一轮做反的，OCR 坐标是硬证据）**：
///
/// | 元素 | 设计稿 y | 屏高比例 |
/// |---|---|---|
/// | 胶囊输入框（`按住说话` / `发消息或按住说话`） | 2301~2354 | 87.2%~89.2% |
/// | 当前模型按钮（如 `Hy4preview`） | 2292~2346 | 86.8%~88.9% |
/// | 底部导航 5 项标签 | 2567~2610 | 97.2%~98.9% |
///
/// 也就是**模型按钮在胶囊下方**（两者几乎同一带，模型按钮是右侧的一个小胶囊），
/// 而输入区整体贴在底部导航之上。上一轮把它放在了输入框上方，属于读图错误。
///
/// [readOnly] = true 时整个胶囊是一个按钮（任务首页用它"点一下进对话页"），
/// false 时是可输入的真实 TextField。
/// [voiceMode] = true 时右侧出现麦克风，**按住说话是真的**（见 [onVoiceState]：
/// 按下启动系统语音识别、松手停止，结果回填输入框）。
///
/// ⚠️ 这条注释原来写的是"占位交互"，而实现早就是真的了（chat_page 的
/// `_onVoiceState` → `_startSpeech`/`_stopSpeech`）—— 属于会误导下一个人的过时注释。
///
/// ## 2026-11-13 换界面：只动质感与动效，不动几何
///
/// 纵向次序、胶囊高度 46dp、按钮直径 46dp 全部保持原样（设计稿坐标是硬证据，
/// 改几何要重新读图）。这一轮加的是三样，参数统一来自 [DshMotion] / [DshGlass]：
///   1. **顶部 1.5px 受光高光**（原设计只有 0.8px 同色描边，形体是平的）；
///   2. **聚焦过渡动画**：边框从细边渐到强调色，走 `DshMotion.base + ease`，
///      不再是瞬间跳变；
///   3. **按压反馈**：按钮与胶囊按下时形变、松手用 spring 弹回。
///
/// 输入框的底**仍然不透明**（`DshColors.fieldFill`，`contrast_test` 钉死了
/// 「文字压在 fieldFill 上要过 AA」）—— 玻璃渐变只给不压正文的部件用。
class InputBar extends StatefulWidget {
  const InputBar({
    super.key,
    this.controller,
    required this.hintText,
    required this.modelName,
    this.readOnly = false,
    this.enabled = true,
    this.onTap,
    this.onTapModel,
    this.onTapAttach,
    this.onSend,
    this.onCancel,
    this.running = false,
    this.voiceMode = false,
    this.canSend = false,
    this.voiceHeld = false,
    this.onVoiceState,
    this.onSendLongPress,
  });

  final TextEditingController? controller;
  final String hintText;
  final String modelName;
  final bool readOnly;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onTapModel;
  final VoidCallback? onTapAttach;
  final VoidCallback? onSend;

  /// 运行中时右下角变成「停止」
  final VoidCallback? onCancel;
  final bool running;

  /// 是否启用"按住说话"（设计稿只有对话页有这个入口）
  final bool voiceMode;

  /// 输入框里有没有内容 —— 有内容时右侧按钮变成「发送」。
  /// 由调用方在 controller 的监听里维护并 setState。
  final bool canSend;

  /// 当前是否处于按住状态（由外层持有，便于同时驱动上方提示条）
  final bool voiceHeld;

  /// 按住状态变化：`held=true` 按下，`false` 松开
  final void Function(bool held)? onVoiceState;

  /// **长按发送键**弹出「发送方式」菜单（排队 / 中断并发送）。
  ///
  /// 为什么是长按：DSH Go 的同款交互 —— 短按的语义必须唯一（发送 / 停止），
  /// 多选一的入口挂在长按上，既不占版面也不用猜。不传则不响应长按。
  final VoidCallback? onSendLongPress;

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  /// 聚焦状态由本层持有：边框过渡动画需要知道"有没有在输入"。
  /// 用内部 FocusNode 而不是让调用方传 —— 调用方（chat_page）已经有一个
  /// controller，再要它管 focus 是把实现细节漏到页面层。
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (!mounted || _focused == _focus.hasFocus) return;
    setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (widget.onTapAttach != null) ...[
              _CircleButton(
                icon: Icons.add,
                onTap: widget.enabled ? widget.onTapAttach : null,
                tooltip: context.tr('添加附件'),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(child: _buildField(context)),
            // 右侧按钮在「麦克风」与「发送」之间切换。
            //
            // 为什么必须切换：设计稿 page-02 的胶囊只有 `按住说话`（当时没有文字），
            // page-11 是 `发消息或按住说话`。如果恒显麦克风，用户打了字就没有发送
            // 入口（实测只能靠软键盘回车）—— 这是上一版引入的真实可用性缺口。
            // 规则：输入框为空 → 麦克风（按住说话）；有文字 → 发送。
            // 运行中 → 停止（与 DSH Go 的「生成中发送键变停止」同语义，已具备）。
            if (widget.voiceMode && !widget.canSend) ...[
              const SizedBox(width: 8),
              _VoiceButton(
                enabled: widget.enabled && !widget.running,
                held: widget.voiceHeld,
                onState: widget.onVoiceState,
              ),
            ] else ...[
              const SizedBox(width: 8),
              _CircleButton(
                icon: widget.running ? Icons.stop : Icons.arrow_upward,
                onTap: widget.running ? widget.onCancel : widget.onSend,
                tooltip:
                    widget.running ? context.tr('停止') : context.tr('发送'),
                primary: true,
                // 长按恒弹菜单：运行中选「怎么发」，空闲时它也会弹（给「立即发送 /
                // 排队」的语义留位置）—— 由调用方决定传不传。
                onLongPress: widget.onSendLongPress,
              ),
            ],
          ],
        ),
        // 模型按钮在输入框**下方**（设计稿 y=2292~2346），右对齐
        if (widget.onTapModel != null)
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 2),
            child: _ModelChip(name: widget.modelName, onTap: widget.onTapModel!),
          ),
      ],
    );
  }

  /// 输入框外壳（两个分支共用）：实底 + 受光高光 + 聚焦过渡。
  ///
  /// 边框由**这里**统一画（`TextField` 自己的 border 全设为 `InputBorder.none`），
  /// 否则外层描边和 `InputDecoration` 的 `focusedBorder` 会叠出两条线。
  Widget _shell({required Widget child, required VoidCallback? onTap}) {
    final m = DshMotion.of();
    return AnimatedContainer(
      duration: m.base,
      curve: DshMotion.ease,
      decoration: BoxDecoration(
        // 输入框的底必须**不透明**：原来用 `DshColors.surface`（深色下 7% 白），
        // 键入的正文会和页面渐变糊在一起 —— 用户 2026-10-15 的原话是
        // 「输入文字的时候和底版混在一起看不清」。见 [DshPalette.fieldFill]。
        color: DshColors.fieldFill,
        borderRadius: BorderRadius.circular(DshMetrics.inputRadius),
        // ⚠️ 必须是**同色同宽**的一圈：Flutter 在有 borderRadius 时禁止分边异色
        //    （`Border.paint` 断言，见 DshGlass.rim 的说明）—— 第一版按"顶部
        //    1.5px 高光"分边写，渲染直接抛异常，clickthrough 测试当场抓到。
        //    聚焦时整圈换强调色；顶部受光感交给上方的柔光（boxShadow）。
        border: Border.all(
          color: _focused ? DshColors.accent : DshColors.line,
          width: 1,
        ),
        boxShadow: _focused
            ? <BoxShadow>[
                BoxShadow(
                  color: DshColors.accent.withValues(alpha: 0.22),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                  spreadRadius: -6,
                ),
              ]
            : null,
      ),
      child: onTap == null ? child : InkWell(onTap: onTap, child: child),
    );
  }

  Widget _buildField(BuildContext context) {
    // 设计稿胶囊高 53 设计像素 ≈ 2.0% 屏高 ≈ 18dp 内文 + 上下 12dp = 42dp。
    // 这里锁成 46dp，和设计稿在屏高上的占比一致。
    const fieldHeight = 46.0;

    final placeholder = Text(
      (widget.controller != null &&
              widget.controller!.text.isNotEmpty &&
              widget.readOnly)
          ? context.tr('发消息…')
          : widget.hintText,
      style: TextStyle(color: DshColors.textFaint, fontSize: 13.5),
    );

    if (widget.readOnly) {
      return Semantics(
        textField: true,
        label: widget.hintText,
        child: _shell(
          onTap: widget.enabled ? widget.onTap : null,
          child: SizedBox(
            height: fieldHeight,
            child: Align(alignment: Alignment.centerLeft, child: placeholder),
          ),
        ),
      );
    }

    return Semantics(
      textField: true,
      label: widget.hintText,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: fieldHeight),
        child: _shell(
          onTap: null,
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            enabled: widget.enabled,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            keyboardType: TextInputType.multiline,
            style: TextStyle(color: DshColors.text, fontSize: 13.5, height: 1.4),
            cursorColor: DshColors.accent,
            decoration: InputDecoration(
              hintText: widget.hintText,
              filled: true,
              // 同上：实色底，保证"正在键入的字"始终压在实底上。
              fillColor: DshColors.fieldFill,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              // 边框交给外层 `_shell` 画（要与聚焦动画同步），这里一律不画。
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// 当前模型按钮（设计稿 `Hy4preview`，输入框右下方的小胶囊）。
class _ModelChip extends StatelessWidget {
  const _ModelChip({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.tr('当前模型 {0}', [name]),
      child: DshGlass.pressable(
        enabled: true,
        onTap: onTap,
                child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          // 玻璃胶囊（不压正文的部件才用渐变；输入框仍走实底，见类注释）。
          // 与输入框同一排控件，所以仍是"浅色偏亮、深色偏淡"的同一族。
          decoration: DshGlass.capsule(radius: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt, size: 12, color: DshColors.accent),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: DshColors.textDim, fontSize: 11),
                ),
              ),
              Icon(Icons.expand_more, size: 14, color: DshColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「按住说话」按钮。
///
/// ⚠️ **这是明确的占位交互，不伪造识别结果**：
/// 本机 App 里没有语音识别链路（`speech_to_text` 之类会显著增加包体积与权限面），
/// 所以按住时只给视觉反馈（放大 + 变青 + 上方提示条），松手时如实告知"暂未接入"。
/// 不做"假装识别出一段文字"的事 —— 那会让用户以为功能坏了。
class _VoiceButton extends StatefulWidget {
  const _VoiceButton({
    required this.enabled,
    required this.held,
    required this.onState,
  });

  final bool enabled;
  final bool held;
  final void Function(bool held)? onState;

  @override
  State<_VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends State<_VoiceButton> {
  @override
  Widget build(BuildContext context) {
    final on = widget.enabled;
    final m = DshMotion.of();
    return Semantics(
      button: true,
      label: context.tr('按住说话'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: on ? (_) => widget.onState?.call(true) : null,
        onLongPressEnd: on ? (_) => widget.onState?.call(false) : null,
        onLongPressCancel: on ? () => widget.onState?.call(false) : null,
        // 松手回弹走 spring（会过冲一下再落位），按下走 ease（干脆）。
        child: AnimatedContainer(
          duration: widget.held ? m.fast : m.state,
          curve: widget.held ? DshMotion.ease : DshMotion.spring,
          width: widget.held ? 54 : 46,
          height: widget.held ? 54 : 46,
          decoration: BoxDecoration(
            color: widget.held
                ? DshColors.accent
                : (on ? DshColors.surface : DshColors.surfaceHigh),
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.held ? DshColors.accent : DshColors.divider,
              width: 0.8,
            ),
            boxShadow: widget.held
                ? [
                    BoxShadow(
                      color: DshColors.accent.withValues(alpha: 0.35),
                      blurRadius: 14,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            Icons.mic_none,
            size: 20,
            color: widget.held
                ? const Color(0xFF06211D)
                : (on ? DshColors.textDim : DshColors.textFaint),
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.primary = false,
    this.onLongPress,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final bool primary;

  /// 长按（只给主按钮用，见 [InputBar.onSendLongPress]）。
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final m = DshMotion.of();

    // 主按钮（发送/停止）走玻璃质感 + 按压形变；
    // 次按钮（加号）保持原来的实底 + 水波纹 —— 一排里两个都发光会没有主次，
    // 而水波纹与形变同时套在同一个手势上会触发两次回调。
    if (!primary) {
      return Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          child: Material(
            color: DshColors.surface,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: 46,
                height: 46,
                child: Icon(
                  icon,
                  size: 19,
                  color: enabled ? DshColors.textDim : DshColors.textFaint,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: DshGlass.pressable(
          enabled: enabled,
          onTap: onTap,
          onLongPress: onLongPress,
          duration: m.fast,
          child: AnimatedContainer(
            duration: m.fast,
            curve: DshMotion.ease,
            width: 46,
            height: 46,
            decoration: enabled
                ? DshGlass.capsule(radius: 23)
                : BoxDecoration(
                    color: DshColors.surfaceHigh,
                    shape: BoxShape.circle,
                    border: Border.all(color: DshColors.line, width: 1),
                  ),
            child: Icon(
              icon,
              size: 19,
              // 底是玻璃渐变（不是强调色实底），所以前景随皮肤正文色走：
              // 浅色皮肤玻璃偏亮 → 深字；深色皮肤玻璃偏暗 → 浅字。
              color: enabled ? DshColors.text : DshColors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}
