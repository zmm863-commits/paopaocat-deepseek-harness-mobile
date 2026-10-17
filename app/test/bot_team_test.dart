import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/local/bot_team.dart';

/// Bot 名册解析的单测（纯逻辑，不碰文件系统与网络）。
///
/// 为什么值得钉住：这份解析决定了 Bot 页**看到什么**。
///   * `bots` / `rooms` 的 key 是 session id（ds-bot 的原话：Every Bot is one root Session）；
///   * 主 Bot 必须排最前（它是要紧的那个）；
///   * `onlyAdminAnswers` 直接决定「群里为什么没人理」——2026-10-17 的对照实验证明：
///     `mode=admin` **且确有 admin** 时只有主持人能开口；没有 admin 时全员都会答。
/// 这些判断一旦被改错，表现就是"界面少了人"或者"群又不说话了"，很难靠肉眼发现。
void main() {
  Map<String, dynamic> sample() => <String, dynamic>{
        'version': 1,
        'mainBotIds': <String>['s-chief'],
        'workspaceId': 'ws-1',
        'bots': <String, dynamic>{
          // 故意让非主 Bot 排在前面，验证"主 Bot 排最前"的排序
          's-writer': <String, dynamic>{
            'id': 's-writer',
            'name': '乙写作',
            'role': '写作',
            'model': 'polli/openai-fast',
            'color': 'blue',
          },
          's-chief': <String, dynamic>{
            'id': 's-chief',
            'name': 'Chief',
            'role': 'Chief of Staff',
            'appliedModel': 'deepseek/deepseek-flash',
            'color': 'deepseek',
          },
        },
        'rooms': <String, dynamic>{
          's-room1': <String, dynamic>{
            'id': 's-room1',
            'name': '有主持人的群',
            'members': <String>['s-chief', 's-writer'],
            'admin': 's-chief',
            'mode': 'admin',
          },
          's-room2': <String, dynamic>{
            'id': 's-room2',
            'name': '没主持人的群',
            'members': <String>['s-chief', 's-writer'],
            'mode': 'admin',
          },
          's-room3': <String, dynamic>{
            'id': 's-room3',
            'name': '全员群',
            'members': <String>['s-chief', 's-writer'],
            'admin': 's-chief',
            'mode': 'everyone',
          },
        },
      };

  test('解析：bot / room 的 id 就是 session id，成员数对得上', () {
    final t = BotTeam.fromJson(sample());
    expect(t.bots.length, 2);
    expect(t.bots.map((b) => b.id), containsAll(<String>['s-chief', 's-writer']));
    expect(t.rooms.length, 3);
    final r = t.rooms.firstWhere((r) => r.id == 's-room1');
    expect(r.memberCount, 2);
    expect(r.adminId, 's-chief');
  });

  test('主 Bot 排最前（即使 json 里它写在后面）', () {
    final t = BotTeam.fromJson(sample());
    expect(t.bots.first.id, 's-chief');
    expect(t.bots.first.isMain, isTrue);
    expect(t.bots.last.isMain, isFalse);
  });

  test('模型的取值优先 appliedModel（模型已生效），并给出短名', () {
    final t = BotTeam.fromJson(sample());
    final chief = t.bots.firstWhere((b) => b.id == 's-chief');
    // json 里只有 appliedModel，没有 model
    expect(chief.model, 'deepseek/deepseek-flash');
    expect(chief.modelShort, 'deepseek-flash');
  });

  test('★ onlyAdminAnswers：有主持人 + admin 模式 → 只有主持人开口', () {
    final t = BotTeam.fromJson(sample());
    final r = t.rooms.firstWhere((r) => r.id == 's-room1');
    expect(r.onlyAdminAnswers, isTrue);
    expect(r.whoAnswersLabel, contains('主持人'));
  });

  test('★ onlyAdminAnswers：没有主持人 → 全员都会答（实测行为）', () {
    final t = BotTeam.fromJson(sample());
    final r = t.rooms.firstWhere((r) => r.id == 's-room2');
    expect(r.adminId, isNull);
    expect(r.onlyAdminAnswers, isFalse);
    expect(r.whoAnswersLabel, contains('全员'));
  });

  test('★ onlyAdminAnswers：mode=everyone 时即使有主持人也全员都答', () {
    final t = BotTeam.fromJson(sample());
    final r = t.rooms.firstWhere((r) => r.id == 's-room3');
    expect(r.adminId, 's-chief');
    expect(r.onlyAdminAnswers, isFalse);
  });

  test('空 / 缺字段 / 类型不对的数据不会炸（按空处理）', () {
    expect(BotTeam.fromJson(<String, dynamic>{}).isEmpty, isTrue);
    expect(
        BotTeam.fromJson(<String, dynamic>{
          'bots': <String>['不是 map'],
          'rooms': '也不是 map',
        }).isEmpty,
        isTrue);
  });

  test('JSON 往返：真实 state.json 的形状能解析（含中文名）', () {
    const raw = '''
{"mainBotIds":["s-1"],"workspaceId":"w","bots":{"s-1":{"id":"s-1","name":"发布官","role":"发版","color":"orange"}},"rooms":{}}''';
    final t = BotTeam.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    expect(t.bots.single.name, '发布官');
    expect(t.bots.single.role, '发版');
    expect(t.bots.single.isMain, isTrue);
  });
}
