// 关弹窗判定逻辑的单元测试。
//
// 这套逻辑是"能不能安全自动点"的唯一闸门：点错了点的是「立即更新」（开始下载安装包）
// 或者「同意并继续」（授权），所以每一条都要钉死。

import 'package:dsh_mobile/local/popup_dismiss.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('关弹窗：能安全点的', () {
    test('精确按钮文案 → 0（优先点）', () {
      for (final String t in <String>[
        '跳过',
        '关闭',
        '以后再说',
        '下次再说',
        '稍后再说',
        '我知道了',
        '知道了',
        '暂不开启',
        '暂不更新',
        '不感兴趣',
        '残忍拒绝',
        '放弃',
        '不再提示',
        '忽略',
      ]) {
        expect(dismissRank(t), 0, reason: '「$t」应该被精确命中');
      }
    });

    test('带前后空格的按钮也认', () {
      expect(dismissRank('  跳过  '), 0);
      expect(dismissRank('\n关闭\t'), 0);
    });

    test('短文案里含跳过 → 1（包含命中，第二优先）', () {
      expect(dismissRank('跳过广告'), 1);
      expect(dismissRank('跳过 3s'), 1);
    });
  });

  group('关弹窗：绝不能点的', () {
    test('更新 / 升级 / 下载 / 安装 一律拒绝', () {
      for (final String t in <String>[
        '立即更新',
        '立即升级',
        '马上升级',
        '下载安装包',
        '安装',
        '更新',
        '去看看新版本',
      ]) {
        expect(dismissRank(t), -1, reason: '「$t」是危险按钮，绝不能点');
      }
    });

    test('确定 / 确认 / 支付 / 删除 / 同意 / 授权 / 领取 一律拒绝', () {
      for (final String t in <String>[
        '确定',
        '确认',
        '确认支付',
        '删除',
        '同意并继续',
        '同意',
        '授权',
        '立即领取',
        '领取',
        '开启',
      ]) {
        expect(dismissRank(t), -1, reason: '「$t」点了会出事或会误操作');
      }
    });

    test('正文里的字不能被当成按钮（太长就拒绝）', () {
      expect(dismissRank('点击跳过广告即可继续观看完整视频内容'), -1);
      expect(dismissRank('关闭后你将无法收到新消息通知'), -1);
    });

    test('普通内容文本不误判', () {
      for (final String t in <String>[
        'Xiaomi',
        '5',
        '价格',
        '淘宝',
        '搜索',
        '广告',
      ]) {
        expect(dismissRank(t), -1, reason: '「$t」不是弹窗按钮');
      }
    });

    test('空行不算', () {
      expect(dismissRank(''), -1);
      expect(dismissRank('   '), -1);
    });
  });

  group('关弹窗：优先级', () {
    test('精确命中优先于包含命中（避免点到「跳过广告」这种长文案）', () {
      expect(dismissRank('关闭'), 0);
      expect(dismissRank('关闭广告'), 1);
    });
  });
}
