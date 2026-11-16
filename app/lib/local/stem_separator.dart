import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'dsh_runtime.dart';

// ───────────────────────────────────────────────────────────────────────────
// 人声 / 伴奏分离（MDX-Net，本地跑）
//
// 2026-11-14：用户批准「三个梯队都做」的第二梯队，选型标准是**体积可控**
// （原 316MB 的 htdemucs 放弃，用 52.8MB 的 UVR_MDXNET_KARA_2）。
//
// ## 为什么重活在 Rust 里
//
// 分离 = STFT（4096 点 FFT × 数千帧）→ 神经网络 → iSTFT。同样的算法在 Dart
// 里是分钟级，在 Rust 里是秒级。所以 `libmdx.so` 干全部浮点活，这里只做：
// 转码 → 读 PCM → 调库 → 写 WAV → 回收。
//
// ## ONNX Runtime 不额外打包
//
// App 里已经因为离线配音带了 `libonnxruntime.so`（ORT 1.28.2，导出了完整 C API）。
// Rust 侧用 `load-dynamic` 在运行时 dlopen 它 —— 包体不增加，也不会出现两个
// 同名 .so 在 APK 里打架。
// ───────────────────────────────────────────────────────────────────────────

/// 分离结果：两个文件的路径 + 耗时。
class StemResult {
  const StemResult({
    required this.vocalsPath,
    required this.instrumentalPath,
    required this.elapsed,
    required this.durationSeconds,
  });

  /// 人声轨（干净人声）。
  final String vocalsPath;

  /// 伴奏轨（去掉人声后的部分）。
  final String instrumentalPath;

  /// 实际耗时。
  final Duration elapsed;

  /// 音频时长（秒）。
  final double durationSeconds;

  /// 处理速度：音频秒数 / 实际秒数。> 1 表示比实时快。
  double get speedFactor =>
      durationSeconds <= 0 ? 0 : durationSeconds / elapsed.inMilliseconds * 1000;
}

/// 进度回调：0.0 ~ 1.0，外加一句给用户看的话。
typedef StemProgress = void Function(double fraction, String stage);

/// 分离失败时抛这个，带人话原因。
class StemException implements Exception {
  StemException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ── FFI 绑定 ────────────────────────────────────────────────────────────────

typedef _OpenC = Int32 Function(Pointer<Utf8> path, Pointer<Utf8> ortDylib);
typedef _OpenD = int Function(Pointer<Utf8> path, Pointer<Utf8> ortDylib);
typedef _CloseC = Void Function();
typedef _CloseD = void Function();
typedef _SeparateC = Int32 Function(
    Pointer<Float> samples, IntPtr n, Pointer<Float> outVocals, Pointer<Float> outInst);
typedef _SeparateD = int Function(
    Pointer<Float> samples, int n, Pointer<Float> outVocals, Pointer<Float> outInst);

class _MdxLib {
  _MdxLib(this._open, this._separate, this._close);
  final _OpenD _open;
  final _SeparateD _separate;
  final _CloseD _close;

  static _MdxLib? _cached;

  /// 释放 Rust 侧的会话（模型内存）。App 退出或换模型时调用。
  void dispose() {
    _close();
    _cached = null;
  }

  /// 加载 `libmdx.so`。加载不到就抛（调用方如实显示原因，不要静默降级）。
  static _MdxLib load() {
    final hit = _cached;
    if (hit != null) return hit;
    final lib = DynamicLibrary.open('libmdx.so');
    final l = _MdxLib(
      lib.lookupFunction<_OpenC, _OpenD>('mdx_open'),
      lib.lookupFunction<_SeparateC, _SeparateD>('mdx_separate'),
      lib.lookupFunction<_CloseC, _CloseD>('mdx_close'),
    );
    _cached = l;
    return l;
  }
}

// ── 主服务 ──────────────────────────────────────────────────────────────────

class StemSeparator {
  StemSeparator(this.runtime);

  final DshRuntime runtime;

  /// 模型在 assets 里的路径（随包）。
  static const String _assetModel = 'assets/models/uvr-mdxnet-kara2.onnx';

  /// 解包后的模型标记（内容变了要重新解）。
  static const String _modelMarker = '.mdx-model-unpacked';


  String get _workDir => '${runtime.filesDir}/stems';

  /// 把模型从 assets 解到私有目录（只做一次）。
  ///
  /// 为什么必须解出来：ONNX Runtime 的 `commit_from_file` 要的是**真实文件路径**，
  /// 而 Flutter 的 assets 在 APK 内部，不是一个可 open 的路径。
  Future<String> ensureModel() async {
    final dir = Directory(_workDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final model = File('${dir.path}/uvr-mdxnet-kara2.onnx');
    final marker = File('${dir.path}/$_modelMarker');
    // 用一个便宜的指纹：模型文件大小 + assets 里那一份的大小。
    final bundleData = await rootBundleLoadSize();
    if (model.existsSync() && marker.existsSync()) {
      try {
        if (model.lengthSync() == bundleData &&
            marker.readAsStringSync().trim() == '$bundleData') {
          return model.path;
        }
      } catch (_) {}
    }
    debugPrint('[stem] 解包模型（约 50MB，只需一次）…');
    final bytes = await rootBundleLoad();
    model.writeAsBytesSync(bytes, flush: true);
    marker.writeAsStringSync('$bundleData');
    debugPrint('[stem] 模型就绪：${model.path}（${bytes.length} 字节）');
    return model.path;
  }

  /// assets 里模型的大小（用来判断要不要重新解）。
  Future<int> rootBundleLoadSize() async {
    final data = await rootBundleLoad();
    return data.length;
  }

  /// assets 里模型的字节。
  Future<Uint8List> rootBundleLoad() async {
    final d = await rootBundle.load(_assetModel);
    return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  }

  // 注：这里原来有一个**同步版** `separate()`。它已经没有任何调用者了
  // （页面走 `stemWorker` + isolate，理由见下面那条注释），而且是唯一一处
  // 会卡住主线程的长调用，2026-11-16 一并删掉。
  //
  // 历史教训留着：**FFI 长调用不能放主 isolate**。它在手机上表现为界面
  // 整段冻结——连转圈都不动，比报错还难受。


}

// ── WAV 读写（16-bit PCM 单声道）─────────────────────────────────────────────

class _WavData {
  _WavData(this.samples, this.sampleRate);
  final Float32List samples;
  final int sampleRate;
}

/// 读 16-bit PCM WAV。只支持单声道（我们转码时就是单声道）。
_WavData _readWav16(String path) {
  final b = File(path).readAsBytesSync();
  if (b.length < 44) throw StemException('WAV 文件不完整');
  // 找 fmt 和 data 块（不要假设固定 44 字节头：ffmpeg 可能带 LIST 块）
  var i = 12;
  int fmtOff = -1, dataOff = -1, dataLen = 0;
  while (i + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(i, i + 4));
    final size = ByteData.sublistView(b, i + 4, i + 8).getUint32(0, Endian.little);
    if (id == 'fmt ') fmtOff = i + 8;
    if (id == 'data') {
      dataOff = i + 8;
      dataLen = size;
      break;
    }
    i += 8 + size + (size.isOdd ? 1 : 0);
  }
  if (fmtOff < 0 || dataOff < 0) throw StemException('不是有效的 WAV');
  final ch = ByteData.sublistView(b, fmtOff + 2, fmtOff + 4).getUint16(0, Endian.little);
  final sr = ByteData.sublistView(b, fmtOff + 4, fmtOff + 8).getUint32(0, Endian.little);
  final bits = ByteData.sublistView(b, fmtOff + 14, fmtOff + 16).getUint16(0, Endian.little);
  if (bits != 16) throw StemException('只支持 16-bit WAV（当前 $bits）');
  final avail = math.min(dataLen, b.length - dataOff);
  final count = avail ~/ 2;
  final out = Float32List(count);
  final bd = ByteData.sublistView(b, dataOff, dataOff + count * 2);
  for (var k = 0; k < count; k++) {
    out[k] = bd.getInt16(k * 2, Endian.little) / 32768.0;
  }
  // 多声道就取第一声道（转码时已经是单声道，这里只是兜底）
  if (ch <= 1) return _WavData(out, sr);
  final mono = Float32List(count ~/ ch);
  for (var k = 0; k < mono.length; k++) {
    mono[k] = out[k * ch];
  }
  return _WavData(mono, sr);
}

/// 写 16-bit PCM WAV（单声道）。
void _writeWav16(String path, Float32List samples, int sampleRate) {
  final n = samples.length;
  final dataLen = n * 2;
  final b = ByteData(44 + dataLen);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataLen, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  b.setUint16(32, 2, Endian.little); // block align
  b.setUint16(34, 16, Endian.little); // bits
  ascii(36, 'data');
  b.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767.0).round();
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  File(path).writeAsBytesSync(b.buffer.asUint8List(), flush: true);
}


// ── isolate 任务（不依赖 DshRuntime，参数全部序列化传入）─────────────────────

/// isolate 的入参。全部是字符串/简单类型 —— isolate 之间不能传对象引用。
class StemTask {
  const StemTask({
    required this.input,
    required this.modelPath,
    required this.ffmpeg,
    required this.workDir,
    required this.ldLibPath,
    required this.ortDylib,
  });

  final String input;
  final String modelPath;
  final String ffmpeg;
  final String workDir;

  /// 原生库目录（`.../lib/arm64`）。
  ///
  /// ⚠️ 必须传给 ffmpeg：`libffmpeg.so` 自身依赖同目录的 `libavdevice.so` /
  /// `libavformat.so` / `libavcodec.so` 等十几个库，而那些库不在系统的
  /// ld 搜索路径里。不设 `LD_LIBRARY_PATH` 直接 exec，报的错是
  /// `library "libavdevice.so" not found: needed by main executable`
  /// —— 2026-11-16 用户真机撞到的就是这个。
  final String ldLibPath;

  /// 推理引擎的**绝对路径**（`<nativeLibDir>/libonnxruntime.so`）。
  ///
  /// ⚠️ 不能只给库名：Android 从 API 21 起不读 `LD_LIBRARY_PATH` 去 dlopen
  ///    裸库名，只认绝对路径。给 "libonnxruntime.so" 在手机上必然失败。
  final String ortDylib;
}

/// **在独立 isolate 里跑完整分离**（转码 → 读 PCM → FFI → 写 WAV）。
///
/// ## 为什么必须开 isolate
///
/// `mdx_separate` 是一次几十秒到几分钟的**同步 FFI 调用**。放在主 isolate 上，
/// 界面会整段冻结（连转圈都不动）—— 那是最糟的观感。这里把它整体推进后台，
/// 主 isolate 只负责刷新进度。
///
/// [send] 用来回传进度：`[分数, 阶段文字]`；完成回 `['ok', 人声路径, 伴奏路径, 秒数]`；
/// 失败回 `['err', 原因]`。
Future<void> stemWorker(StemTask task, SendPort send) async {
  try {
    send.send(<Object>[0.03, '解码音频']);
    final srcWav = '${task.workDir}/_src.wav';
    final r1 = await Process.run(
      task.ffmpeg,
      <String>[
        '-y', '-i', task.input,
        '-ar', '44100', '-ac', '1', '-c:a', 'pcm_s16le',
        srcWav,
      ],
      // ffmpeg 的所有依赖库都在 nativeLibraryDir 里，必须靠这个变量暴露出来。
      environment: <String, String>{'LD_LIBRARY_PATH': task.ldLibPath},
    );
    if (r1.exitCode != 0 || !File(srcWav).existsSync()) {
      send.send(<Object>['err', '音频解码失败：${_tailOf('${r1.stderr}')}']);
      return;
    }

    send.send(<Object>[0.08, '读取波形']);
    final wav = _readWav16(srcWav);
    final n = wav.samples.length;
    if (n < 44100) {
      send.send(<Object>['err', '音频太短（不到 1 秒）']);
      return;
    }

    send.send(<Object>[0.12, '分离中（本地运算）']);
    final lib = _MdxLib.load();
    final pathPtr = task.modelPath.toNativeUtf8();
    final ortPtr = task.ortDylib.toNativeUtf8();
    final vocals = calloc<Float>(n);
    final inst = calloc<Float>(n);
    final src = calloc<Float>(n);
    try {
      final rcOpen = lib._open(pathPtr, ortPtr);
      if (rcOpen != 0) {
        send.send(<Object>['err', '模型打不开（代码 $rcOpen）']);
        return;
      }
      for (var i = 0; i < n; i++) {
        src[i] = wav.samples[i];
      }
      final rcRun = lib._separate(src, n, vocals, inst);
      if (rcRun != 0) {
        send.send(<Object>['err', '分离失败（代码 $rcRun）']);
        return;
      }
      send.send(<Object>[0.92, '写出结果']);
      final vocalsList = Float32List(n);
      final instList = Float32List(n);
      for (var i = 0; i < n; i++) {
        vocalsList[i] = vocals[i];
        instList[i] = inst[i];
      }
      final base = _baseOf(task.input);
      final vocPath = '${task.workDir}/${base}_vocals.wav';
      final instPath = '${task.workDir}/${base}_instrumental.wav';
      _writeWav16(vocPath, vocalsList, wav.sampleRate);
      _writeWav16(instPath, instList, wav.sampleRate);
      try {
        File(srcWav).deleteSync();
      } catch (_) {}
      send.send(<Object>[
        'ok', vocPath, instPath, n / 44100.0,
      ]);
    } finally {
      calloc.free(pathPtr);
      calloc.free(ortPtr);
      calloc.free(vocals);
      calloc.free(inst);
      calloc.free(src);
      lib._close();
    }
  } catch (e) {
    send.send(<Object>['err', '$e']);
  }
}

String _tailOf(String s) {
  final t = s.trim();
  return t.length <= 160 ? t : t.substring(t.length - 160);
}

String _baseOf(String p) {
  final name = p.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}
