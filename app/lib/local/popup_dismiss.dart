// 一键关弹窗：扫虚拟屏 OCR，找「跳过 / 关闭 / 以后再说 / 我知道了 / 暂不开启…」
// 这类按钮点掉，连点几轮清掉叠在一起的弹窗。
//
// 文字库提炼自 GKD 公开订阅的全局组（开屏广告 / 更新提示 / 青少年模式）——
// 那些规则全靠无障碍节点 id / text 精确匹配，泡泡猫没有节点树，只走 OCR，
// 所以这里只保留「OCR 认得出、且点了安全」的纯文字按钮。
//
// ⚠️ 危险词黑名单：绝不点「更新 / 升级 / 下载 / 安装 / 确定 / 确认 / 支付 / 删除 /
// 同意 / 授权 / 领取」。开屏广告旁边常常就是「立即更新」，认错一下就会开始下载安装包。

import 'phone_agent_bridge.dart';

/// 纯按钮文案：整行完全相等才认（最安全）。
const List<String> kDismissExact = <String>[
  '跳过', '跳過', '跳 过', 'skip', 'Skip', 'SKIP',
  '关闭', '忽略', '不再提示', '不感兴趣', '残忍拒绝', '放弃',
  '以后再说', '下次再说', '稍后再说', '稍后再看', '下次再约',
  '我知道了', '知道了', '暂不开启', '暂不更新', '暂不', '以后',
];

/// 允许包含匹配（但整行不超过 6 个字，避免点到正文里的字）。
const List<String> kDismissContain = <String>[
  '跳过', '跳過', '关闭', '我知道了', '以后再说', '暂不', '忽略',
];

/// 危险词：含任一个就绝不点。
/// 注意「开启」不能进黑名单，否则会挡掉合法按钮「暂不开启」。
const List<String> kDismissBlock = <String>[
  '更新', '升级', '下载', '安装', '确定', '确认', '支付', '删除', '同意', '授权', '领取',
];

/// 一行 OCR 文字像不像「关弹窗」按钮：0 = 精确命中（优先），1 = 包含命中，-1 = 不能点。
int dismissRank(String text) {
  final String t = text.trim();
  if (t.isEmpty || t.length > 12) return -1;
  // ⚠️ 顺序很重要：精确白名单要先于黑名单。
  // 否则「暂不更新」「暂不开启」这类**安全**按钮会被「更新」黑名单误杀 —— 它们恰恰是最该点的。
  if (kDismissExact.contains(t)) return 0;
  if (kDismissBlock.any(t.contains)) return -1;
  if (t.length <= 6 && kDismissContain.any(t.contains)) return 1;
  return -1;
}

/// 扫屏关弹窗，返回关掉的个数。找不到弹窗就返回 0（不算失败）。
///
/// [rounds] 最多点几轮（默认 3），因为可能叠着开屏广告 + 更新提示 + 通知挽留。
Future<int> dismissPopups(PhoneAgentBridge bridge, {int rounds = 3}) async {
  int closed = 0;
  for (int i = 0; i < rounds; i++) {
    final List<({String text, int cx, int cy})> lines = await bridge.ocr();
    ({String text, int cx, int cy})? hit;
    int best = 9;
    for (final l in lines) {
      final int rank = dismissRank(l.text);
      if (rank >= 0 && rank < best) {
        hit = l;
        best = rank;
      }
      if (rank == 0) break;
    }
    if (hit == null) break;
    await bridge.tap(hit.cx, hit.cy);
    closed++;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }
  return closed;
}
