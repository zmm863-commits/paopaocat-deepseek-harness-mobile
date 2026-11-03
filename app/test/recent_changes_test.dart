/// 「最近的改动」扫描器的行为测试。
///
/// 这段逻辑的风险不在"能不能扫到"，而在**别的地方**：
///   * 把 `node_modules` / `.git` 里几万个文件也扫进来 → 打开面板卡三秒；
///   * 把很早的文件也算成"刚刚改的" → 用户看到一堆无关内容，等于没用；
///   * 目录里有坏文件/权限问题 → 整次扫描抛错，页面一片空白。
/// 所以下面逐条钉住。
library;

import 'dart:io';

import 'package:dsh_mobile/data/recent_changes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dsh-recent-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File put(String rel, {required Duration ago, String content = 'x'}) {
    final f = File('${root.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    f.setLastModifiedSync(DateTime.now().subtract(ago));
    return f;
  }

  test('只列时间窗内的文件，并按修改时间倒序', () async {
    put('fresh.txt', ago: const Duration(seconds: 5));
    put('older.txt', ago: const Duration(minutes: 20));
    put('stale.txt', ago: const Duration(hours: 5));

    final got = await RecentChanges.scan(root.path,
        window: const Duration(hours: 1));

    expect(got.map((c) => c.name), <String>['fresh.txt', 'older.txt'],
        reason: '5 小时前那个不该出现；而且新的一定排在前面');
    expect(got.first.modifiedAt.isAfter(got.last.modifiedAt), isTrue);
  });

  test('跳过 node_modules / .git / build 这类目录', () async {
    put('keep.txt', ago: const Duration(minutes: 1));
    put('node_modules/pkg/index.js', ago: const Duration(minutes: 1));
    put('.git/HEAD', ago: const Duration(minutes: 1));
    put('build/out.bin', ago: const Duration(minutes: 1));

    final got = await RecentChanges.scan(root.path,
        window: const Duration(hours: 1));

    expect(got.map((c) => c.name), <String>['keep.txt'],
        reason: '这些目录里的文件改了也不是用户关心的「产出」，扫进来只会拖慢');
  });

  test('跳过隐藏文件与空文件', () async {
    put('visible.txt', ago: const Duration(minutes: 1));
    put('.DS_Store', ago: const Duration(minutes: 1));
    put('empty.txt', ago: const Duration(minutes: 1), content: '');

    final got = await RecentChanges.scan(root.path,
        window: const Duration(hours: 1));

    expect(got.map((c) => c.name), <String>['visible.txt'],
        reason: '隐藏文件是噪音；空文件多半是原子写入的中间态');
  });

  test('相对路径不带前导分隔符，目录与文件名拆开', () async {
    put('sub/dir/report.md', ago: const Duration(minutes: 1), content: 'hello');

    final got = await RecentChanges.scan(root.path,
        window: const Duration(hours: 1));

    expect(got.length, 1);
    final c = got.single;
    expect(c.relativePath, 'sub${Platform.pathSeparator}dir${Platform.pathSeparator}report.md');
    expect(c.name, 'report.md');
    expect(c.directory, 'sub${Platform.pathSeparator}dir');
    expect(c.sizeLabel, '5 B');
  });

  test('根目录不存在 → 返回空列表，不抛错', () async {
    final got = await RecentChanges.scan('${root.path}/does-not-exist');
    expect(got, isEmpty);
  });

  test('相对时间标签是人话', () {
    final c = RecentChange(
      absolutePath: '/x/a.txt',
      relativePath: 'a.txt',
      modifiedAt: DateTime.now().subtract(const Duration(seconds: 12)),
      bytes: 10,
    );
    expect(c.ageLabel, contains('秒前'));
  });
}
