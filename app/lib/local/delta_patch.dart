import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 差分更新补丁（`DSHDELTA1`）的**解码与应用**。
///
/// ## 它解决什么
///
/// 完整包 ~99 MB，而每次更新的真实差异往往只有几 MB（实测 117→122 是 **5.19 MB / 5.3%**）。
/// 有了补丁，用户下载的是「旧包 → 新包」的差异，本地拼出新包再安装。
///
/// ## 为什么是纯 Dart
///
/// 社区主流是 bsdiff/bspatch（C 实现，要 NDK 编 `.so`）。我们两端都自己控，所以用
/// **自定义格式 + Dart 自带的 zlib**：不用引第三方包、不用编原生库、也不用担心 ABI。
/// 格式见 `install/make-delta.mjs` 顶部注释（magic + JSON 头 + zlib 压缩的操作流）。
///
/// ## 三条不能松的校验（补丁链一旦出错就是装坏包）
///
/// 1. **旧包必须是同一个**：头里带 `oldSha256`，拼之前先算一遍已装包的哈希；
/// 2. **拼出来的新包必须逐字节正确**：拼完算 `newSha256`，与头里比；
/// 3. **长度必须对**：`newSize` 不符立刻判失败（比哈希更早发现问题）。
/// 任一条不过 → 删掉半成品、抛 [DeltaPatchException]，由调用方回退到整包下载。
class DeltaPatch {
  DeltaPatch._();

  /// 补丁文件头（从补丁里读出来的元信息）。
  static const String magic = 'DSHDELTA1';

  /// 读补丁头（不应用）。用于展示"这次是增量更新"、以及挑基准。
  static Future<DeltaPatchHeader> readHeader(File patch) async {
    final raf = await patch.open();
    try {
      final head = await raf.read(9 + 4);
      if (head.length < 13) {
        throw const DeltaPatchException('补丁文件太短（连文件头都不全）');
      }
      if (utf8.decode(head.sublist(0, 9), allowMalformed: true) != magic) {
        throw const DeltaPatchException('不是 DSHDELTA1 补丁');
      }
      final len = ByteData.sublistView(head, 9, 13).getUint32(0, Endian.little);
      if (len <= 0 || len > 64 * 1024) {
        throw DeltaPatchException('补丁头长度不合理（$len）');
      }
      final jsonBytes = await raf.read(len);
      final m = jsonDecode(utf8.decode(jsonBytes));
      if (m is! Map) throw const DeltaPatchException('补丁头不是 JSON 对象');
      return DeltaPatchHeader(
        oldSha256: '${m['oldSha256'] ?? ''}'.toLowerCase(),
        newSha256: '${m['newSha256'] ?? ''}'.toLowerCase(),
        oldSize: (m['oldSize'] as num?)?.toInt() ?? -1,
        newSize: (m['newSize'] as num?)?.toInt() ?? -1,
        ops: (m['ops'] as num?)?.toInt() ?? -1,
      );
    } finally {
      await raf.close();
    }
  }

  /// 把 `旧包 + 补丁` 拼成新包（写到 [outApk]）。
  ///
  /// [verifyOldHash] 默认开：会先把旧包整个哈希一遍（~99 MB，设备上约 1~2 秒）。
  /// 只有确认"旧包就是补丁认的那一个"，COPY 出来的片段才可能是对的。
  static Future<DeltaPatchHeader> apply({
    required File oldApk,
    required File patchFile,
    required File outApk,
    void Function(double fraction)? onProgress,
    bool verifyOldHash = true,
  }) async {
    if (!await oldApk.exists()) {
      throw const DeltaPatchException('找不到已安装的旧包（可能被挪走了）');
    }
    final header = await readHeader(patchFile);
    if (verifyOldHash && header.oldSha256.isNotEmpty) {
      final got = await sha256OfFile(oldApk);
      if (got != header.oldSha256) {
        throw DeltaPatchException(
            '已装包的哈希与补丁不匹配（补丁是给 ${header.oldSha256.substring(0, 12)}… 的）');
      }
    }
    final oldSize = await oldApk.length();
    if (header.oldSize >= 0 && oldSize != header.oldSize) {
      throw DeltaPatchException('旧包大小不符：期望 ${header.oldSize}，实际 $oldSize');
    }

    // 读整个补丁（几 MB）并解出操作流。zlib 解压后的量级 = 新包大小（可能 ~99 MB），
    // 手机内存 15 GB 完全够；换来的是实现简单、没有流式状态机可错。
    final patchBytes = await patchFile.readAsBytes();
    final opsBlob = _inflate(patchBytes);

    final outDir = outApk.parent;
    if (!await outDir.exists()) await outDir.create(recursive: true);
    if (await outApk.exists()) await outApk.delete();

    final src = await oldApk.open();
    final dst = await outApk.open(mode: FileMode.write);
    var written = 0;
    try {
      var p = 0;
      final total = header.newSize > 0 ? header.newSize : opsBlob.length;
      while (p < opsBlob.length) {
        final type = opsBlob[p++];
        if (type == 0) {
          if (p + 12 > opsBlob.length) throw const DeltaPatchException('补丁被截断（COPY 头）');
          final off = _u64(opsBlob, p); p += 8;
          final len = _u32(opsBlob, p); p += 4;
          if (off + len > oldSize) {
            throw const DeltaPatchException('补丁引用了旧包之外的数据');
          }
          await src.setPosition(off);
          var left = len;
          while (left > 0) {
            final n = left > (1 << 20) ? (1 << 20) : left;
            final chunk = await src.read(n);
            if (chunk.isEmpty) throw const DeltaPatchException('读旧包提前结束');
            await dst.writeFrom(chunk);
            written += chunk.length;
            left -= chunk.length;
          }
        } else if (type == 1) {
          if (p + 4 > opsBlob.length) throw const DeltaPatchException('补丁被截断（ADD 头）');
          final len = _u32(opsBlob, p); p += 4;
          if (p + len > opsBlob.length) throw const DeltaPatchException('补丁被截断（ADD 数据）');
          await dst.writeFrom(opsBlob, p, p + len);
          written += len;
          p += len;
        } else {
          throw DeltaPatchException('补丁里有未知操作类型 $type');
        }
        if (onProgress != null && total > 0) {
          onProgress((written / total).clamp(0.0, 1.0));
        }
      }
      await dst.flush();
    } catch (e) {
      await dst.close();
      await src.close();
      // 半成品必须删掉：留着它，后面任何一步都可能误当成品拿去装。
      try {
        if (await outApk.exists()) await outApk.delete();
      } catch (_) {}
      rethrow;
    }
    await dst.close();
    await src.close();

    if (header.newSize >= 0 && written != header.newSize) {
      try {
        await outApk.delete();
      } catch (_) {}
      throw DeltaPatchException('拼出来的大小不符：期望 ${header.newSize}，实际 $written');
    }
    if (header.newSha256.isNotEmpty) {
      final got = await sha256OfFile(outApk);
      if (got != header.newSha256) {
        try {
          await outApk.delete();
        } catch (_) {}
        throw const DeltaPatchException('拼出来的包哈希不符（补丁与旧包可能不是一对）');
      }
    }
    return header;
  }

  /// 文件流式 sha256（99 MB 不整块读进内存）。
  static Future<String> sha256OfFile(File f) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in f.openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.value.toString();
  }

  static Uint8List _inflate(Uint8List patchBytes) {
    final p = _headerEnd(patchBytes);
    final payload = Uint8List.sublistView(patchBytes, p);
    try {
      return Uint8List.fromList(ZLibDecoder().convert(payload));
    } catch (e) {
      throw DeltaPatchException('补丁内容解压失败（文件损坏？）：$e');
    }
  }

  /// 定位到"zlib 段"的起点：magic(9) + u32 头长度 + 头 JSON。
  static int _headerEnd(Uint8List b) {
    if (b.length < 13) throw const DeltaPatchException('补丁文件太短');
    final len = ByteData.sublistView(b, 9, 13).getUint32(0, Endian.little);
    final end = 13 + len;
    if (end > b.length) throw const DeltaPatchException('补丁头长度越界');
    return end;
  }

  static int _u32(Uint8List b, int at) =>
      ByteData.sublistView(b, at, at + 4).getUint32(0, Endian.little);

  static int _u64(Uint8List b, int at) =>
      ByteData.sublistView(b, at, at + 8).getUint64(0, Endian.little);
}

/// 补丁头。
class DeltaPatchHeader {
  const DeltaPatchHeader({
    required this.oldSha256,
    required this.newSha256,
    required this.oldSize,
    required this.newSize,
    required this.ops,
  });

  /// 这个补丁**认**的旧包哈希（必须与已装包一致）。
  final String oldSha256;

  /// 拼出来的新包应该是这个哈希。
  final String newSha256;

  final int oldSize;
  final int newSize;
  final int ops;
}

/// 补丁链上的任何失败都用它 —— 调用方一律**回退整包**，不要试图修补。
class DeltaPatchException implements Exception {
  const DeltaPatchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 把 chunked sha256 的输出收成字符串。
class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
