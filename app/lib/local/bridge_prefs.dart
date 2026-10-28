import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/atomic_file.dart';

/// 「电脑访问」的持久化偏好：**固定端口** + **访问口令**。
///
/// ## 为什么要固定端口
///
/// 以前每次开关都重新挑端口（实测出现过 40731 / 38385 / 42633 / 39885 /
/// 42195……），于是用户每次都得回手机点一次「复制网址」，电脑上收藏的链接
/// 全部失效。挑一次记住，之后优先复用；被占用才顺延。
///
/// ## 为什么要口令
///
/// 设计站那条转发之前**完全没有鉴权**：同一 Wi-Fi 下任何人访问
/// `/agnes-studio/api/models`、`/library/list`、`/library/file` 都是 200，
/// 连用户的 Key（花钱）和资料库文件（155KB 真图实测下载成功）都能拿到。
/// 现在给它一个随机口令，URL 里带 `?token=…`，与 DSH 那条同一个思路。
///
/// ⚠️ 口令存在 App 私有目录，随应用卸载消失；「重置口令」会换一把新的，
/// 旧链接立刻失效（这正是想要的行为）。
class BridgePrefs {
  BridgePrefs._(this._file, this.token, this.dshPort, this.agnesPort);

  final File _file;

  /// 访问口令（32 位十六进制）。空串表示还没生成。
  String token;

  /// 上次用的对外端口（0 = 还没定过）。
  int dshPort;
  int agnesPort;

  static const String _name = 'bridge.json';

  static Future<BridgePrefs> load(String filesDir) async {
    final f = File('$filesDir/$_name');
    var token = '';
    var dsh = 0;
    var agnes = 0;
    try {
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map) {
          token = (raw['token'] as String? ?? '').trim();
          dsh = (raw['dshPort'] as num?)?.toInt() ?? 0;
          agnes = (raw['agnesPort'] as num?)?.toInt() ?? 0;
        }
      }
    } catch (e) {
      debugPrint('[bridge] 读偏好失败（将重新生成）：$e');
    }
    final p = BridgePrefs._(f, token, dsh, agnes);
    if (p.token.isEmpty) {
      p.token = _randomToken();
      await p.save();
    }
    return p;
  }

  Future<void> save() async {
    try {
      writeStringAtomicSync(
        _file,
        '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
              'token': token,
              'dshPort': dshPort,
              'agnesPort': agnesPort,
            })}\n',
      );
    } catch (e) {
      debugPrint('[bridge] 存偏好失败：$e');
    }
  }

  /// 换一把新口令（旧链接立即失效）。
  Future<void> rotateToken() async {
    token = _randomToken();
    await save();
  }

  static String _randomToken() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }
}
