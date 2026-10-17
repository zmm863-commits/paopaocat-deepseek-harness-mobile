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
  const NewBotDialog({super.key});

  /// 返回 `{name, role}`；取消返回 null。
  @override
  State<NewBotDialog> createState() => _NewBotDialogState();
}

class _NewBotDialogState extends State<NewBotDialog> {
  final _name = TextEditingController();
  final _role = TextEditingController();

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
          Text(
            '它会成为一个独立的 Bot：有自己的会话、记忆和工作目录。'
            '模型用当前默认的那一个，建好后可以在它的会话里改。',
            style: TextStyle(color: DshColors.textDim, fontSize: 12, height: 1.5),
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
