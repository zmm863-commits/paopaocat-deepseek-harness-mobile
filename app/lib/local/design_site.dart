import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import '../data/atomic_file.dart';
import 'diagnostics_log.dart';
import 'dsh_runtime.dart';

/// 把随包的「泡泡猫设计站」发布到 DSH 网页服务里，并且只让**网页版**看到入口。
///
/// ## 为什么是"发布进 dist"而不是另起一个端口
///
/// 设计站是 Next.js 静态导出，而且**构建时带了 `basePath="/design"`**
/// —— 它里面的资源引用全是 `/design/_next/static/…` 这样的绝对路径。
/// 所以只要把产物原样放进 DSH 前端的 `dist/design/`，`/design/index.html`
/// 就会被 `dsh-host-frontend-static` 的 fallback 当成普通静态文件返回，
/// 而 `/design/_next/…` 也正好落在同一个前缀下 —— **全部同源、不用改一行
/// 产物、不用开第二个端口、不用额外鉴权配置**。
///
/// 为什么不是塞进运行时压缩包：那会让 `dsh-runtime.zip` 白白 +4.8MB，
/// 而同样的字节 Flutter 那边已经在 `assets/studio/` 里带了一份。这里改成
/// **首次启动时从 Flutter assets 解包过去**，APK 里只存一份。
///
/// ## 「只有网页版才能看到」是怎么做到的
///
/// 注入的那段脚本判断 `location.hostname`：回环（`127.0.0.1` / `localhost` /
/// `::1`）说明是 App 内 WebView 打开的，**不显示**；其它（网卡 IP，也就是
/// 电脑浏览器）才显示。判据与「电脑访问」同源 —— DSH 本体始终绑回环。
class DesignSite {
  DesignSite._();

  /// Flutter assets 里的前缀（`pubspec.yaml` 的 `assets/studio/`）。
  static const String assetPrefix = 'assets/studio/';

  /// 在 DSH 前端 dist 下的挂载目录名 —— **必须与 Next 的 basePath 一致**。
  static const String mountName = 'design';

  /// 注入按钮用的标记（幂等；也用于判断"已经打过了"）。
  static const String scriptMarker = '/* dshm-design-site-button */';

  /// 发布站点 + 注入入口按钮。返回是否成功（失败只记日志，不拦 Bot 服务启动）。
  static Future<bool> publish(DshRuntime runtime) async {
    try {
      final dist = Directory(
          '${runtime.runtimeRoot}/node_modules/@deepseek-ai/dsh-web-frontend/dist');
      if (!dist.existsSync()) {
        DiagnosticsLog.add('design', '前端 dist 不存在，跳过设计站发布：${dist.path}');
        return false;
      }
      final ok = await _unpackTo(Directory('${dist.path}/$mountName'));
      if (!ok) return false;
      await _injectButton(File('${dist.path}/index.html'));
      return true;
    } catch (e) {
      DiagnosticsLog.add('design', '设计站发布失败（不影响网页其它功能）：$e');
      return false;
    }
  }

  /// 把 `assets/studio/**` 解到 [target]，返回是否可用。
  ///
  /// **幂等**：清单指纹（资产名 + 大小合计）没变就直接跳过 —— 这目录里有
  /// 57 个文件 / 4.8MB，每次冷启都重拷会让打开网页明显变慢。
  static Future<bool> _unpackTo(Directory target) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest
        .listAssets()
        .where((p) => p.startsWith(assetPrefix))
        .toList()
      ..sort();
    if (assets.isEmpty) {
      DiagnosticsLog.add('design',
          '安装包里没有 $assetPrefix（构建时没把设计站打进去）—— 请重新构建 App');
      return false;
    }

    // 确定性指纹：不要用 String.hashCode（跨进程不保证一致）。
    var sum = 7;
    var bytes = 0;
    for (final a in assets) {
      for (final c in a.codeUnits) {
        sum = (sum * 31 + c) & 0x7fffffff;
      }
      final data = await rootBundle.load(a);
      bytes += data.lengthInBytes;
    }
    sum = (sum * 31 + bytes) & 0x7fffffff;
    final stamp = File('${target.path}/.published-$sum');

    if (target.existsSync() && stamp.existsSync()) {
      final hasIndex = File('${target.path}/index.html').existsSync();
      if (hasIndex) {
        debugPrint('[design] 已是最新（指纹 $sum），跳过解包');
        return true;
      }
    }

    // 清掉旧版（含上一次的指纹文件），再整份写入。
    if (target.existsSync()) {
      try {
        target.deleteSync(recursive: true);
      } catch (e) {
        DiagnosticsLog.add('design', '清理旧设计站失败：$e');
      }
    }
    target.createSync(recursive: true);

    for (final a in assets) {
      final rel = a.substring(assetPrefix.length);
      if (rel.isEmpty) continue;
      final out = File('${target.path}/$rel');
      out.parent.createSync(recursive: true);
      final data = await rootBundle.load(a);
      out.writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: false,
      );
    }
    writeStringAtomicSync(stamp, '$sum\n');
    DiagnosticsLog.add('design',
        '已发布设计站 → ${target.path}（${assets.length} 个文件 / ${(bytes / 1048576).toStringAsFixed(1)} MB）');
    return true;
  }

  /// 往前端入口页注入一个悬浮入口（幂等，带 [scriptMarker]）。
  ///
  /// 为什么要注入到 `dist/index.html`：DSH 的 SPA 只有这一个入口，
  /// 挂到 body 上的节点不会被 React 卸载；而换成"自己写插件注入 UI slot"
  /// 需要 profile 里多挂一个客户端插件 —— 为一个小入口不值得。
  static Future<void> _injectButton(File indexHtml) async {
    if (!indexHtml.existsSync()) return;
    final src = await indexHtml.readAsString();
    if (src.contains(scriptMarker)) return;

    const script = '''
<script>
$scriptMarker
(function () {
  // 只在"从外部打开"时显示：回环 = App 内 WebView，不给入口。
  var h = location.hostname;
  if (h === '127.0.0.1' || h === 'localhost' || h === '::1' || h === '[::1]') return;
  function mount() {
    if (document.getElementById('dshm-design-entry')) return;
    var a = document.createElement('a');
    a.id = 'dshm-design-entry';
    a.href = '/$mountName/';
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
    final lower = src.toLowerCase();
    final at = lower.lastIndexOf('</body>');
    if (at >= 0) {
      out = '${src.substring(0, at)}$script${src.substring(at)}';
    } else {
      out = '$src$script';
    }
    writeStringAtomicSync(indexHtml, out);
    DiagnosticsLog.add('design', '已给前端入口注入设计站按钮（仅外部访问可见）');
  }
}
