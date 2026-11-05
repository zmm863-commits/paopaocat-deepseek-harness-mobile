/// 注入到 Bot 页 WebView 里的那份移动版 CSS 的**回归测试**。
///
/// ## 为什么要有它（2026-11-05 用户真机）
///
/// 用户报：「Bot 页第一次安装让选模型，我看到列出来的模型**无法在页面中选择**。」
///
/// 查下来是 CSS 里一条**通配符太宽**的规则：
///
/// ```css
/// [class*="dock"] button { pointer-events: none !important; }
/// ```
///
/// 它本来只想让输入区下方那几块「轮次 / tokens / 上下文」统计别装成按钮，
/// 但 ds-bot 里带 `dock` 子串的一共有四个类，全都装着实用的按钮：
///
/// * `bt-model-dock`  → `.bt-model-chip`（选模型 / 首次引导的「选择模型」）← 本次事故
/// * `bt-mw-dock`     → `.bt-mw-pill`（Bot 工作状态胶囊，点开看详情）
/// * `bt-secret-dock` → 密钥审批卡片的「批准 / 拒绝」
/// * `bt-q-dock`      → 问答区
///
/// 这一条等于把四处一起废掉 —— 模型点不动只是最显眼的那处，审批按钮点不动更致命。
///
/// 这个文件已经因为 `[class*=...]` 这种写法翻过三次车（`panel` 盖住消息区、
/// `card` 误伤 bcard、`dock` 这次）。所以这里用测试钉死两条：
///
///   1. **注入 CSS 里不许出现针对 `dock` 的 `pointer-events: none`**；
///   2. 凡是「会让元素点不动」的规则，其选择器**不许通配到**那几个交互类。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/ui/pages/bot_mobile_layout.dart';

/// ds-bot 里**必须能点**的类（点不动的后果从"选不了模型"到"审批不了密钥"）。
const List<String> _mustStayClickable = <String>[
  'bt-model-chip', // 选模型 / 首次引导
  'bt-model-chips',
  'bt-mw-pill', // Bot 工作状态胶囊
  'bt-secret-dock', // 密钥审批卡片容器
  'bt-q-dock', // 问答区
];

/// 去掉 `/* ... */` 注释。
///
/// ⚠️ 必须先去掉再解析：这份 CSS 的注释里**大段引用了选择器原文**
/// （比如解释"不要写 `[class*=stat]`"时），不去掉的话注释会被当成选择器的一部分，
/// 于是测试会去检查一段说明文字 —— 我第一次跑就是这么红掉的。
String _stripComments(String css) =>
    css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

/// 把 CSS 拆成「选择器 → 声明块」的粗粒度列表。
List<({String selector, String body})> _rules(String css) {
  final out = <({String selector, String body})>[];
  final re = RegExp(r'([^{}]+)\{([^{}]*)\}', multiLine: true);
  for (final m in re.allMatches(_stripComments(css))) {
    out.add((selector: m.group(1)!.trim(), body: m.group(2)!.trim()));
  }
  return out;
}

/// 这条声明块会不会让元素「点不动」。
bool _disablesPointer(String body) {
  final b = body.replaceAll(' ', '');
  return b.contains('pointer-events:none') || b.contains('display:none');
}

bool _selectorHits(String selector, String cls) {
  // `[class*="xxx"]` 通配
  for (final m in RegExp(r'\[class\*="([^"]+)"\]').allMatches(selector)) {
    if (cls.contains(m.group(1)!)) return true;
  }
  // 直接写类名
  return selector.contains('.$cls');
}

void main() {
  test('★★ 注入 CSS 里不许有针对 dock 的 pointer-events（会废掉选模型和密钥审批）',
      () {
    final rules = _rules(botMobileLayoutCss);
    final bad = <String>[];
    for (final r in rules) {
      if (!_disablesPointer(r.body)) continue;
      if (!r.selector.contains('dock')) continue;
      bad.add('${r.selector} → ${r.body.split('\n').first.trim()}');
    }
    expect(bad, isEmpty,
        reason: '带 dock 的类（bt-model-dock / bt-mw-dock / bt-secret-dock / '
            'bt-q-dock）里全是实用按钮，禁掉就点不动了：\n${bad.join('\n')}');
  });

  test('★★ 任何「点不动」的规则都不许通配到必须能点的类', () {
    final rules = _rules(botMobileLayoutCss);
    final bad = <String>[];
    for (final r in rules) {
      if (!_disablesPointer(r.body)) continue;
      for (final cls in _mustStayClickable) {
        if (_selectorHits(r.selector, cls)) {
          bad.add('${r.selector}  →  命中 $cls');
        }
      }
    }
    expect(bad, isEmpty,
        reason: '这些类点不动会让功能直接失效（模型选不了 / 审批点不了）：\n'
            '${bad.join('\n')}');
  });

  test('统计区仍然用精确类名（不再用 [class*="stat"] 这种通配）', () {
    // bt-member-state / bt-mem-status / bt-connector-status 这些状态位里也有按钮，
    // 通配一次就废一片，所以统计区只能用精确类名。
    expect(botMobileLayoutCss.contains('.bt-us-stat'), isTrue,
        reason: '统计区应该用精确类名 .bt-us-stat / .bt-us-stats 控制');
    final rules = _rules(botMobileLayoutCss);
    final bad = <String>[
      for (final r in rules)
        if (_disablesPointer(r.body) && r.selector.contains('[class*="stat"]'))
          r.selector,
    ];
    expect(bad, isEmpty,
        reason: '不许可用 [class*="stat"] 去关 pointer-events（会误伤状态位按钮）：\n'
            '${bad.join('\n')}');
  });
}
