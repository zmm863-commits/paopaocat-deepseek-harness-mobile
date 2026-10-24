import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

/// 随包「工具箱」：把 `assets/toolbox/` 下的脚本落到 App 私有目录，供 node 调用。
///
/// 为什么需要它（**这是用户第 3 条反馈的修复的一半**）：
/// 用户要求"生成 PPT"，模型却回「这个沙箱里没有任何可执行环境（无 bash /
/// python / pandoc / node）」，只能给一个 HTML 幻灯片当替代品。
/// Android 上确实没有 python/pandoc；但有随包的 node，而且缺少的是
/// 「让模型能跑命令」和「一个真能写出 .pptx 的脚本」。这两件事分别是：
///   * `assets/toolbox/android-exec-shim.cjs` —— node `--require` 预加载，
///     把 DSH 写死的 `bash -c ...` 重写成 `/system/bin/sh -c ...`，
///     并让 shell 里能直接调 `node`（详见该文件顶部说明）；
///   * `assets/toolbox/make-pptx.mjs` —— 纯 node（只用内置模块）把一份
///     JSON 大纲写成**真的** .pptx。
///
/// ⚠️ 为什么脚本要放在 assets 里、由 Dart 复制到私有目录，而不是直接内嵌成
/// Dart 字符串：这些文件同时要能**在电脑上直接跑**（本地验证过才敢发版），
/// 内嵌进 Dart 就没法独立验证了。落盘位置见 `DshRuntime.execShimPath`
/// 与 `DshRuntime.toolboxDir`。
class AndroidToolbox {
  AndroidToolbox._();

  /// 资源路径 → 目标相对路径（相对 `filesDir`）。
  static const Map<String, String> assets = <String, String>{
    'assets/toolbox/android-exec-shim.cjs': 'shims/android-exec-shim.cjs',
    'assets/toolbox/make-pptx.mjs': 'toolbox/make-pptx.mjs',
    // PPT 的**排版引擎**（2026-10-16）：`make-pptx.mjs` 用 `import './pptx-design.mjs'`
    // 引它 —— 所以必须落在**同一个目录**里；少一个文件，会话里跑 make-pptx 会
    // 直接 `Cannot find module`。
    // 分工：这层只管「算」（主题、文本测量、自动缩排/分页、各版式的形状树），
    // 打包成 .pptx（ZIP + OOXML + rels）仍是 make-pptx.mjs 的事 —— 所以它能
    // 在电脑上被单独 import 做纯函数测试（见 install/test-make-pptx.mjs）。
    'assets/toolbox/pptx-design.mjs': 'toolbox/pptx-design.mjs',
    // ── Office 文档（用户 2026-10-12「全做」的 D 项）：
    // 手机上**没有 python / openpyxl / pandas**，但 xlsx/docx 的本质就是
    // **ZIP + XML**，而 node 自带 `node:zlib` —— 所以这条路自己走。
    // `office-zip.mjs` 是**共享库**（造/读都要它，两个脚本用 `./office-zip.mjs` 引它，
    // 与 `agnes-retry.mjs` 同一个先例：落盘必须在同一目录）。
    'assets/toolbox/office-zip.mjs': 'toolbox/office-zip.mjs',
    'assets/toolbox/make-xlsx.mjs': 'toolbox/make-xlsx.mjs',
    'assets/toolbox/read-xlsx.mjs': 'toolbox/read-xlsx.mjs',
    'assets/toolbox/make-docx.mjs': 'toolbox/make-docx.mjs',
    // ── 本地 MCP 服务器（2026-10-20，CHG-2026-10-20-02）──────────────
    // `mcp-office.mjs` 是**我们自己的 MCP 服务**（stdio 传输，零 npm 依赖），
    // 让会话里的模型能直接读写 xlsx / docx —— 对标 WorkBuddy 的本地文档引擎
    // （它 302 个工具，我们先做三个）。
    // ⚠️ 它 `import './office-zip.mjs'` 与 `./read-xlsx.mjs` → **必须同目录**
    //    （和 `agnes-retry.mjs` 同一个先例：落盘必须在同一个目录里）。
    'assets/toolbox/mcp-office.mjs': 'toolbox/mcp-office.mjs',
    // Word 的**读**那一半：.docx → Markdown / 纯文本 / JSON。
    // 与 make-docx 是一对（那边写的能原样读回来，有往返测试钉住）。
    // 图片默认只标注不抽，给 `--extract-images 目录` 才真写出来。
    'assets/toolbox/read-docx.mjs': 'toolbox/read-docx.mjs',
    'assets/toolbox/rotate-proxy.mjs': 'toolbox/rotate-proxy.mjs',
    // ── 手机屏幕助手（2026-10-23）──────────────────────────────────
    // Agent 调「看屏幕 / 点屏幕 / 开应用」的 Node 客户端：读 filesDir/phone-agent.json
    // 拿端口+令牌，再打本机 127.0.0.1 的桥（见 Android 侧 PhoneAgentBridge.kt）。
    'assets/toolbox/phone-agent.mjs': 'toolbox/phone-agent.mjs',
    // 用户第 7 条：内置 Agnes（免费）的生图 / 生视频能力，
    // 用户只要说"生成一张图 / 一段视频"就该直接能跑。
    'assets/toolbox/make-image.mjs': 'toolbox/make-image.mjs',
    'assets/toolbox/make-video.mjs': 'toolbox/make-video.mjs',
    // 「修图」（本机 ffmpeg 滤镜）：一键美化（调色/锐化/磨皮/暗角）+ 去水印（delogo 盖住）。
    // 与 make-image 的分工：**"重画/换风格"用 make-image --ref（图生图，要联网、走 Agnes）；
    // "只动这一小块/调色"用这个（本机、不联网、不花额度）**。详见脚本顶部注释。
    'assets/toolbox/edit-image.mjs': 'toolbox/edit-image.mjs',
    // 口播 / 短剧的合成器（每镜一张带字幕的图 + 一段配音 → 成片）。
    // 「影视」页的口播/短剧就是调它；会话里的模型也可以直接用它（见 AGENTS.md 的说明）。
    // ⚠️ 字幕是 **App 侧用 Flutter 画好**再交给它的 —— 随包 ffmpeg 里没有
    //    subtitles/drawtext/ass 滤镜（NDK 没有 libass/freetype，编不进去）。
    'assets/toolbox/make-narration.mjs': 'toolbox/make-narration.mjs',
    // 「剪辑」：手上**已经有视频之后**的那几刀 —— 剪一段 / 拼接 / 抽音频 / 抽一帧 / 压小。
    // 与 make-narration 的分工：那个是**生成**（图片+配音 → 成片），
    // 这个是**编辑已有素材**。除了 compress 与 --exact，其余都走 `-c copy`
    //（不重编码），所以手机上剪一刀通常几秒就完事、也不掉画质。
    'assets/toolbox/clip-video.mjs': 'toolbox/clip-video.mjs',
    // ⚠️ 这个不是给模型直接调的脚本，而是**生图/生视频共用的库**（429 退避 + 多把 Key）。
    // 两个脚本用 `import './agnes-retry.mjs'` 引它，所以必须落在**同一个目录**里
    //（复制到 filesDir/toolbox/ 下，相对 import 才解析得到）。
    // 它也在表里是必须的：`test/android_toolbox_test.dart` 会检查"目录里每个脚本都在表里"。
    'assets/toolbox/agnes-retry.mjs': 'toolbox/agnes-retry.mjs',
    // 「影视」生图/生视频的**厂家形状表：唯一来源**（用户 2026-10-11 纠正：
    // 影视工具本来就能用多个厂家，不该只认 Agnes 那一套请求形状）。
    // 同样是被 `import './media-vendors.mjs'` 引用的库，必须与两个脚本同目录。
    // 纯计算、不发请求 —— 所以能 `node media-vendors.mjs --selftest` 干跑看形状。
    'assets/toolbox/media-vendors.mjs': 'toolbox/media-vendors.mjs',
    // 「免费模型（无需 Key）」的本地代理：把请求按官方 CLI 的形状转发到
    // OpenCode Zen 的匿名免费额度。**默认关闭**，用户在设置里显式打开才启动。
    // ⚠️ 它绕的是上游"只允许自家 CLI"的限制，所以定位是灰色能力的窄口；
    //    但**不需要任何 Key** —— 上游凭据就是公开的 `public`（脚本里写死）。
    'assets/toolbox/zen-proxy.mjs': 'toolbox/zen-proxy.mjs',
    // 用户意见②：手机上多半没有视觉模型，图片先过一遍「免费视觉链」转成文字，
    // 文本模型才真的看得懂画面（复刻 dsh-vision-router 的思路）。
    'assets/toolbox/vision-proxy.mjs': 'toolbox/vision-proxy.mjs',
    // 本机离线配音（B 方案）：模型是 .tar.bz2，而 Android 没有 tar/bzip2 →
    // 在 node 里解包（bzip2 解码用 vendor 里那份 MIT 的 seek-bzip）。
    // ⚠️ vendor 的内部相对结构必须原样保留：`lib/index.js` 里要求
    //    `require('../package.json')`，摆错一层就起不来。
    'assets/toolbox/untar-bz2.mjs': 'toolbox/untar-bz2.mjs',
    'assets/toolbox/vendor/seek-bzip/LICENSE': 'toolbox/vendor/seek-bzip/LICENSE',
    'assets/toolbox/vendor/seek-bzip/README.md': 'toolbox/vendor/seek-bzip/README.md',
    'assets/toolbox/vendor/seek-bzip/package.json': 'toolbox/vendor/seek-bzip/package.json',
    'assets/toolbox/vendor/seek-bzip/lib/index.js': 'toolbox/vendor/seek-bzip/lib/index.js',
    'assets/toolbox/vendor/seek-bzip/lib/bitreader.js': 'toolbox/vendor/seek-bzip/lib/bitreader.js',
    'assets/toolbox/vendor/seek-bzip/lib/crc32.js': 'toolbox/vendor/seek-bzip/lib/crc32.js',
    'assets/toolbox/vendor/seek-bzip/lib/stream.js': 'toolbox/vendor/seek-bzip/lib/stream.js',
  };

  /// 本次进程内已经装过就不再走一遍（盘上内容仍然逐次比对，见下）。
  static bool _done = false;

  /// 幂等安装：**内容一样就不重写**（否则每次启动都写几个文件，白白抖 IO）。
  ///
  /// 单个文件失败不影响其它文件，也不会抛出去 —— 缺了 shim 只是"模型用不了
  /// bash"，不该让整个 App 起不来；失败会打日志，便于排查。
  static Future<void> ensureInstalled(String filesDir) async {
    if (_done) return;
    if (filesDir.trim().isEmpty) return;

    for (final entry in assets.entries) {
      final dst = File('$filesDir/${entry.value}');
      try {
        final src = await rootBundle.loadString(entry.key);
        if (dst.existsSync() && dst.readAsStringSync() == src) continue;
        final dir = Directory(dst.parent.path);
        if (!dir.existsSync()) dir.createSync(recursive: true);
        await dst.writeAsString(src);
        debugPrint('[dsh-toolbox] 已落盘 ${entry.value}（${src.length} 字符）');
      } catch (e) {
        debugPrint('[dsh-toolbox] 落盘 ${entry.value} 失败：$e');
      }
    }
    _done = true;
  }
}
