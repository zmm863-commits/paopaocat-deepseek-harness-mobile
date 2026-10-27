import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/atomic_file.dart';
import 'diagnostics_log.dart';
import 'dsh_runtime.dart';

/// 给 DSH 的网页入口注入「泡泡猫设计站」按钮，**只在外部访问时显示**。
///
/// ## 演变（2026-10-27）
///
/// 第一版把设计站的静态产物解包进 DSH 前端 dist 的 `/design/`，确实能打开页面，
/// 但**一用就 404** —— 因为设计站是「前端 + Node 后端」架构，所有能力都打
/// `/agnes-studio/api/*`，光有静态文件等于空壳。
///
/// 现在静态与 API 都由手机里的那个后端（`AgnesWeb`，独立端口）提供，所以这里
/// 只负责一件事：往 DSH 的前端入口页塞一个跳转按钮。
///
/// ## 「只有网页版才能看到」
///
/// 注入的脚本判断 `location.hostname`：回环（`127.0.0.1` / `localhost` / `::1`）
/// 说明是 App 内 WebView，**不显示**；网卡 IP（电脑浏览器）才显示。
class DesignSite {
  DesignSite._();

  /// 注入按钮用的标记（幂等；也用于判断"已经打过了"）。
  static const String scriptMarker = '/* dshm-design-site-button */';

  /// 给入口页注入（或更新）按钮。[url] 是设计站的完整地址（外部可访问）。
  static Future<bool> injectEntry(DshRuntime runtime, String url) async {
    try {
      final f = File(
          '${runtime.runtimeRoot}/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html');
      if (!f.existsSync()) {
        DiagnosticsLog.add('design', '前端入口不存在，跳过注入：${f.path}');
        return false;
      }
      final src = f.readAsStringSync();
      // 已经注入过同一地址 → 不用再写。
      if (src.contains(scriptMarker) && src.contains(url)) return true;

      // 先摘掉旧的那一段（地址变了要能更新），再插新的。
      var base = src;
      final startAt = base.indexOf(scriptMarker);
      if (startAt >= 0) {
        final open = base.lastIndexOf('<script>', startAt);
        final close = base.indexOf('</script>', startAt);
        if (open >= 0 && close > open) {
          base = base.substring(0, open) + base.substring(close + '</script>'.length);
        }
      }

      final script = '''
<script>
$scriptMarker
(function () {
  var h = location.hostname;
  if (h === '127.0.0.1' || h === 'localhost' || h === '::1' || h === '[::1]') return;
  var TARGET = '$url';
  function mount() {
    if (document.getElementById('dshm-design-entry')) return;
    var a = document.createElement('a');
    a.id = 'dshm-design-entry';
    a.href = TARGET;
    a.target = '_blank';
    a.rel = 'noopener';
    a.title = '泡泡猫设计站';
    a.textContent = '🎨 设计站';
    a.style.cssText = [
      'position:fixed', 'top:10px', 'right:12px', 'z-index:2147483000',
      'padding:6px 12px', 'border-radius:999px',
      'background:rgba(24,28,36,.86)', 'color:#e8f0ff',
      'font:500 12px/1.6 system-ui,-apple-system,"PingFang SC",sans-serif',
      'text-decoration:none', 'border:1px solid rgba(120,170,255,.45)',
      'box-shadow:0 2px 10px rgba(0,0,0,.28)', 'backdrop-filter:blur(6px)',
      'cursor:pointer', 'user-select:none'
    ].join(';');
    a.onmouseenter = function () { a.style.background = 'rgba(40,70,120,.95)'; };
    a.onmouseleave = function () { a.style.background = 'rgba(24,28,36,.86)'; };
    document.body.appendChild(a);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mount);
  } else {
    mount();
  }
})();
</script>
''';

      String out;
      final lower = base.toLowerCase();
      final at = lower.lastIndexOf('</body>');
      out = at >= 0 ? '${base.substring(0, at)}$script${base.substring(at)}' : '$base$script';
      writeStringAtomicSync(f, out);
      DiagnosticsLog.add('design', '已注入设计站入口：$url（仅外部访问可见）');
      return true;
    } catch (e) {
      DiagnosticsLog.add('design', '注入设计站入口失败（不影响其它功能）：$e');
      return false;
    }
  }

  /// 撤掉入口按钮（关闭「电脑访问」时调用）。
  static Future<void> removeEntry(DshRuntime runtime) async {
    try {
      final f = File(
          '${runtime.runtimeRoot}/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html');
      if (!f.existsSync()) return;
      final src = f.readAsStringSync();
      final at = src.indexOf(scriptMarker);
      if (at < 0) return;
      final open = src.lastIndexOf('<script>', at);
      final close = src.indexOf('</script>', at);
      if (open < 0 || close < 0) return;
      final out = src.substring(0, open) + src.substring(close + '</script>'.length);
      writeStringAtomicSync(f, out);
      debugPrint('[design] 已移除设计站入口');
    } catch (e) {
      debugPrint('[design] 移除入口失败：$e');
    }
  }
}
