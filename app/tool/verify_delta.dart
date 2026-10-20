// 开发用：验证「旧包 + 补丁 → 新包」是否逐字节正确。
// 用法：dart run tool/verify_delta.dart <旧.apk> <补丁> <输出.apk>
import 'dart:io';

import 'package:dsh_mobile/local/delta_patch.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('用法：dart run tool/verify_delta.dart <旧.apk> <补丁> <输出.apk>');
    exit(2);
  }
  final oldApk = File(args[0]);
  final patch = File(args[1]);
  final out = File(args[2]);

  final sw = Stopwatch()..start();
  final head = await DeltaPatch.readHeader(patch);
  stdout.writeln('  头：old=${head.oldSha256.substring(0, 16)}… '
      'new=${head.newSha256.substring(0, 16)}… oldSize=${head.oldSize} '
      'newSize=${head.newSize} ops=${head.ops}');

  var lastPct = -1;
  await DeltaPatch.apply(
    oldApk: oldApk,
    patchFile: patch,
    outApk: out,
    onProgress: (f) {
      final pct = (f * 100).floor();
      if (pct != lastPct && pct % 20 == 0) {
        lastPct = pct;
        stdout.writeln('  进度 $pct%');
      }
    },
  );
  final got = await DeltaPatch.sha256OfFile(out);
  stdout.writeln('  拼出来的 sha256=$got');
  stdout.writeln('  期望的   sha256=${head.newSha256}');
  stdout.writeln(got == head.newSha256 ? '✅ 逐字节一致（${sw.elapsedMilliseconds}ms）' : '❌ 不一致');
  exit(got == head.newSha256 ? 0 : 1);
}
