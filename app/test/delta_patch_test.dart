import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_mobile/local/delta_patch.dart';
import 'package:flutter_test/flutter_test.dart';

/// 差分补丁（DSHDELTA1）的编解码回归。
///
/// 为什么这组测试重要：补丁链**一旦算错就是装出坏包**（比"没更新"严重得多）。
/// 所以这里锁住三件事：
///   1. 正常路径：COPY + ADD 拼出来的字节必须**逐字节**等于目标；
///   2. 旧包不对（哈希不符）→ **必须拒绝**，不能硬拼；
///   3. 补丁损坏/截断/头不对 → 必须抛错并**删掉半成品**（调用方据此回退整包）。
void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('deltapatch'));
  tearDown(() async => tmp.delete(recursive: true));

  /// 按 `install/make-delta.mjs` 的格式造一个补丁。
  Uint8List buildPatch({
    required Uint8List oldBytes,
    required Uint8List newBytes,
    required List<Object> ops, // [0, off, len] 或 [1, bytes]
    String? oldSha,
    String? newSha,
    int? newSize,
  }) {
    final opsBuf = BytesBuilder();
    for (final op in ops) {
      if (op is List && op[0] == 0) {
        final b = ByteData(13)
          ..setUint8(0, 0)
          ..setUint64(1, op[1] as int, Endian.little)
          ..setUint32(9, op[2] as int, Endian.little);
        opsBuf.add(b.buffer.asUint8List());
      } else if (op is List && op[0] == 1) {
        final data = op[1] as List<int>;
        final b = ByteData(5)
          ..setUint8(0, 1)
          ..setUint32(1, data.length, Endian.little);
        opsBuf.add(b.buffer.asUint8List());
        opsBuf.add(data);
      }
    }
    final header = jsonEncode(<String, Object>{
      'format': 'DSHDELTA1',
      'oldSha256': oldSha ?? sha256.convert(oldBytes).toString(),
      'newSha256': newSha ?? sha256.convert(newBytes).toString(),
      'oldSize': oldBytes.length,
      'newSize': newSize ?? newBytes.length,
      'ops': ops.length,
    });
    final hj = utf8.encode(header);
    final magic = ascii.encode('DSHDELTA1');
    final len = ByteData(4)..setUint32(0, hj.length, Endian.little);
    return Uint8List.fromList(<int>[
      ...magic,
      ...len.buffer.asUint8List(),
      ...hj,
      ...ZLibEncoder(level: 9).convert(opsBuf.takeBytes()),
    ]);
  }

  test('正常路径：COPY + ADD 拼出来的字节逐字节等于目标', () async {
    final oldBytes = Uint8List.fromList(List<int>.generate(3000, (i) => i % 251));
    const inserted = 'NEW-段-插入';
    final newBytes = Uint8List.fromList(<int>[
      ...oldBytes.sublist(0, 1000),
      ...utf8.encode(inserted),
      ...oldBytes.sublist(1000),
    ]);

    final old = File('${tmp.path}/old.apk')..writeAsBytesSync(oldBytes);
    final patch = File('${tmp.path}/p.patch')
      ..writeAsBytesSync(buildPatch(oldBytes: oldBytes, newBytes: newBytes, ops: <Object>[
        <Object>[0, 0, 1000],
        <Object>[1, utf8.encode(inserted)],
        <Object>[0, 1000, 2000],
      ]));
    final out = File('${tmp.path}/new.apk');

    final head = await DeltaPatch.apply(oldApk: old, patchFile: patch, outApk: out);
    expect(head.newSize, newBytes.length);
    expect(await out.readAsBytes(), equals(newBytes));
    expect(await DeltaPatch.sha256OfFile(out), head.newSha256);
  });

  test('旧包不是补丁认的那一个 → 拒绝（不硬拼）', () async {
    final oldBytes = Uint8List.fromList(List<int>.generate(500, (i) => i));
    final newBytes = Uint8List.fromList(<int>[...oldBytes, 1, 2, 3]);
    final otherOld = File('${tmp.path}/other.apk')
      ..writeAsBytesSync(Uint8List.fromList(List<int>.generate(500, (i) => 200 - i % 7)));

    final patch = File('${tmp.path}/p.patch')
      ..writeAsBytesSync(buildPatch(oldBytes: oldBytes, newBytes: newBytes, ops: <Object>[
        <Object>[0, 0, 500],
        <Object>[1, <int>[1, 2, 3]],
      ]));

    await expectLater(
      DeltaPatch.apply(
          oldApk: otherOld, patchFile: patch, outApk: File('${tmp.path}/x.apk')),
      throwsA(isA<DeltaPatchException>()),
    );
    expect(File('${tmp.path}/x.apk').existsSync(), isFalse,
        reason: '失败不能留下半成品');
  });

  test('补丁被截断 → 抛错并删掉半成品', () async {
    final oldBytes = Uint8List.fromList(List<int>.generate(400, (i) => i % 97));
    final newBytes = Uint8List.fromList(<int>[...oldBytes, 9, 9]);
    final old = File('${tmp.path}/old.apk')..writeAsBytesSync(oldBytes);
    final full = buildPatch(oldBytes: oldBytes, newBytes: newBytes, ops: <Object>[
      <Object>[0, 0, 400],
      <Object>[1, <int>[9, 9]],
    ]);
    // 砍掉尾部（zlib 段不完整）
    final patch = File('${tmp.path}/p.patch')
      ..writeAsBytesSync(Uint8List.sublistView(full, 0, full.length - 8));

    await expectLater(
      DeltaPatch.apply(oldApk: old, patchFile: patch, outApk: File('${tmp.path}/x.apk')),
      throwsA(isA<DeltaPatchException>()),
    );
    expect(File('${tmp.path}/x.apk').existsSync(), isFalse);
  });

  test('拼出来的大小不对 → 抛错（比哈希更早发现）', () async {
    final oldBytes = Uint8List.fromList(List<int>.generate(300, (i) => i % 13));
    final newBytes = Uint8List.fromList(<int>[...oldBytes, 7]);
    final old = File('${tmp.path}/old.apk')..writeAsBytesSync(oldBytes);
    final patch = File('${tmp.path}/p.patch')
      ..writeAsBytesSync(buildPatch(
        oldBytes: oldBytes,
        newBytes: newBytes,
        newSize: newBytes.length + 100, // 故意写错
        ops: <Object>[
          <Object>[0, 0, 300],
          <Object>[1, <int>[7]],
        ],
      ));

    await expectLater(
      DeltaPatch.apply(oldApk: old, patchFile: patch, outApk: File('${tmp.path}/x.apk')),
      throwsA(isA<DeltaPatchException>()),
    );
  });

  test('不是我们的补丁格式 → 明确报错', () async {
    final bad = File('${tmp.path}/bad.patch')..writeAsBytesSync(utf8.encode('PK-not-a-patch'));
    await expectLater(DeltaPatch.readHeader(bad), throwsA(isA<DeltaPatchException>()));
  });
}
