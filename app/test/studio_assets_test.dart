/// 「设计画布」产物**必须完整随包**的守护测试。
///
/// ## 为什么必须自动化守
///
/// Flutter 的 `assets:` 声明**不递归**：写 `- assets/studio/` 只会带**该目录下的
/// 文件**，`_next/static/chunks/…` 这些子目录里的东西**一个都不会进包**。
///
/// 而"漏了"的表现是**手机上白屏**（HTML 在、JS 404），**本机测试却全绿**（测试读的
/// 是磁盘，文件当然都在）—— 项目里为 `assets/toolbox/vendor/seek-bzip` 记过一模一样
/// 的坑（见 pubspec 里那条注释）。所以这里把"磁盘上有的目录，pubspec 里必须有"
/// 变成一条会红的测试。
///
/// ⚠️ 这条测试**依赖真实产物**（`assets/studio/` 必须是 `next build` 的 out/）。
/// 它不联网、不构建，只做两边的集合比对。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const studioRoot = 'assets/studio-site';

  test('产物在（跑了 next build 并拷进来）', () {
    final dir = Directory(studioRoot);
    expect(dir.existsSync(), isTrue,
        reason: '没有 $studioRoot —— 先 `npx next build` 再把 out/ 拷进来');
    final index = File('$studioRoot/index.html');
    expect(index.existsSync(), isTrue, reason: '产物里没有 index.html');
    expect(index.lengthSync(), greaterThan(500),
        reason: 'index.html 太小，像是空文件或没构建成功');
    // 至少有打包后的 JS 资源，否则就是"只有一个空壳 HTML"。
    final hasChunk = dir
        .listSync(recursive: true)
        .whereType<File>()
        .any((f) => f.path.endsWith('.js'));
    expect(hasChunk, isTrue, reason: '产物里一个 .js 都没有 —— 页面打不开');
  });

  test('磁盘上每个含文件的目录，pubspec.yaml 里都必须声明（否则手机上白屏）', () {
    final root = Directory(studioRoot);
    if (!root.existsSync()) {
      markTestSkipped('产物不在，跳过（由上面那条测试报缺）');
      return;
    }

    // 磁盘侧：所有"直接含文件"的目录
    final onDisk = <String>{};
    for (final e in root.listSync(recursive: true)) {
      if (e is File) {
        onDisk.add(e.parent.path.replaceAll('\\', '/'));
      }
    }

    // pubspec 侧：声明里的 assets/studio* 目录
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(r'^\s+-\s+(assets/studio[^\s]*)/\s*$', multiLine: true)
        .allMatches(pubspec)
        .map((m) => m.group(1)!)
        .toSet();

    final missing = onDisk.difference(declared).toList()..sort();
    expect(missing, isEmpty,
        reason: '这些目录没在 pubspec.yaml 里声明，手机上会缺文件（白屏）：\n'
            '  ${missing.join('\n  ')}\n'
            '修法：find assets/studio -type f -printf "%h\\n" | sort -u ，'
            '把结果逐行写成 assets: 下的条目');

    final stale = declared.difference(onDisk).toList()..sort();
    expect(stale, isEmpty,
        reason: 'pubspec 里声明了磁盘上不存在的目录（产物重建后残留）：\n'
            '  ${stale.join('\n  ')}');
  });
}
