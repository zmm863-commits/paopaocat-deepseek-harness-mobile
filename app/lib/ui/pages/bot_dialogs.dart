// ⚠️ **当前未引用**（2026-10-17 用户决定改用网页版后保留）：
// Bot 页现在用的是 `bot_page.dart`（WebView 加载 dsh web），见 app_shell.dart。
// 这一份是「原生方案」的实现（Flutter 列表 + 走 ACP 的会话），保留是为了：
//   ① 以后若要把 Bot 页做回原生，改 app_shell 的 import 与那一行即可；
//   ② 里面的「谁回答」切换、主 Bot 提示等交互逻辑有参考价值。
// 但**它的会话路径（ACP）有已知的底座短板**（acp profile 是最小组合），
// 详见 docs/BOT-TEST.md 里 2026-10-17 那段「为什么回到网页版」。
import 'package:flutter/material.dart';

import '../../local/bot_team.dart';
import '../theme/dsh_tokens.dart';

/// 「新建 Bot」与「新建群聊」的输入弹窗 —— Bot 页自己用的原生对话框。
///
/// 为什么必须有：`85` 那版把网页界面删掉之后，App 里**没有任何地方能新建 Bot 或群**了
/// （原来那些是在网页界面里建的）。名册页只能"看"，不能"加"，团队就长不大。
///
/// 两者都走 ds-bot 自己的 API（`create-bot` / `create-room`），原因同 [BotServer.callApi]：
/// 不直接改 `state.json`，避免两套写入方打架。
class NewBotDialog extends StatefulWidget {
  const NewBotDialog({
    super.key,
    required this.willBeMain,
    this.models = const <String>[],
  });

  /// 这次新建的 Bot 会不会成为**主 Bot**。
  ///
  /// 事实（2026-10-17 核对 ds-bot 源码）：主 Bot 是它首次启动时**自动建**的
  /// （`bootstrap()` → `createBot({..., main: true})`），而 `create-bot` 接口
  /// **不带 main 参数** —— 所以用户手动建的永远是普通 Bot。
  /// 一旦主 Bot 被删，团队就"群龙无首"而界面看不出来。
  /// 因此：团队里没有主 Bot 时，本次新建会被事后 `set-main`，并在弹窗里提前讲明。
  final bool willBeMain;

  /// 可选模型（route 字符串，如 `deepseek/deepseek-flash`）；空则不显示下拉。
  final List<String> models;

  /// 返回 `{name, role, model}`；model 为空串表示"用团队默认"。取消返回 null。
  @override
  State<NewBotDialog> createState() => _NewBotDialogState();
}

class _NewBotDialogState extends State<NewBotDialog> {
  final _name = TextEditingController();
  final _role = TextEditingController();

  /// 选中的模型 route；null = 用团队默认（建好后也能在它的会话里改）。
  String? _model;

  @override
  void dispose() {
    _name.dispose();
    _role.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DshColors.surfaceStrong,
      title: Text('新建 Bot', style: TextStyle(color: DshColors.text, fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 👑 主 Bot 的事必须提前讲明：用户建的时候得知道"我建的是团队负责人"
          if (widget.willBeMain)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: DshColors.accentDim,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '👑 这将成为「主 Bot」——团队负责人：它能创建和修改其他 Bot，'
                '并管理所有群聊（群里说话会先交给它，由它 @ 别人分派）。',
                style: TextStyle(
                    color: DshColors.accent, fontSize: 12, height: 1.45),
              ),
            )
          else
            Text(
              '这会是一个普通 Bot：有自己的会话、记忆和工作目录。'
              '团队里已有主 Bot，它不会取代它。',
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 12, height: 1.5),
            ),
          const SizedBox(height: 14),
          TextField(
            controller: _name,
            autofocus: true,
            style: TextStyle(color: DshColors.text, fontSize: 15),
            decoration: InputDecoration(
              labelText: '名字（必填）',
              hintText: '比如：设计、查资料',
              labelStyle: TextStyle(color: DshColors.textDim),
              hintStyle: TextStyle(color: DshColors.textFaint),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _role,
            style: TextStyle(color: DshColors.text, fontSize: 15),
            decoration: InputDecoration(
              labelText: '它负责什么（可选）',
              hintText: '比如：负责视觉与排版',
              labelStyle: TextStyle(color: DshColors.textDim),
              hintStyle: TextStyle(color: DshColors.textFaint),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.models.isNotEmpty) ...[
            const SizedBox(height: 12),
            // 拉不到模型列表时不显示这个下拉（不能给一个空的选择器）。
            DropdownButtonFormField<String?>(
              initialValue: _model,
              isExpanded: true,
              dropdownColor: DshColors.surfaceStrong,
              style: TextStyle(color: DshColors.text, fontSize: 14),
              decoration: InputDecoration(
                labelText: '用哪个模型',
                labelStyle: TextStyle(color: DshColors.textDim),
              ),
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                    value: null, child: Text('跟团队默认走')),
                for (final m in widget.models)
                  DropdownMenuItem<String?>(value: m, child: Text(m)),
              ],
              onChanged: (v) => setState(() => _model = v),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: DshColors.textDim)),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('创建'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(<String, String>{
      'name': name,
      'role': _role.text.trim(),
      'model': _model ?? '',
    });
  }
}

/// 新建群聊：群名（可留空，ds-bot 会按成员自动命名）+ 勾选成员。
class NewRoomDialog extends StatefulWidget {
  const NewRoomDialog({super.key, required this.candidates});

  final List<BotTeamBot> candidates;

  /// 返回 `{name, members(List<String>)}`；取消返回 null。
  @override
  State<NewRoomDialog> createState() => _NewRoomDialogState();
}

class _NewRoomDialogState extends State<NewRoomDialog> {
  final _name = TextEditingController();
  final _picked = <String>{};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = _picked.length >= 2;
    return AlertDialog(
      backgroundColor: DshColors.surfaceStrong,
      title: Text('新建群聊', style: TextStyle(color: DshColors.text, fontSize: 16)),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '至少选两个 Bot 才能建群（它们会在同一个会话里一起干活）。',
              style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              style: TextStyle(color: DshColors.text, fontSize: 15),
              decoration: InputDecoration(
                labelText: '群名（可留空）',
                hintText: '留空就按成员名字自动起',
                labelStyle: TextStyle(color: DshColors.textDim),
                hintStyle: TextStyle(color: DshColors.textFaint),
              ),
            ),
            const SizedBox(height: 6),
            // 成员多选：给个上限高度，成员多了自己滚。
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final b in widget.candidates)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _picked.contains(b.id),
                        activeColor: DshColors.accent,
                        checkColor: DshColors.onAccent,
                        title: Text(
                          b.name.isEmpty ? b.id : b.name,
                          style: TextStyle(color: DshColors.text, fontSize: 14),
                        ),
                        subtitle: b.role.isEmpty
                            ? null
                            : Text(b.role,
                                style: TextStyle(
                                    color: DshColors.textDim, fontSize: 11.5)),
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _picked.add(b.id);
                            } else {
                              _picked.remove(b.id);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: DshColors.textDim)),
        ),
        FilledButton(
          onPressed: canCreate
              ? () => Navigator.of(context).pop(<String, Object>{
                    'name': _name.text.trim(),
                    'members': _picked.toList(),
                  })
              : null,
          child: Text(canCreate ? '创建' : '至少选 2 个'),
        ),
      ],
    );
  }
}
