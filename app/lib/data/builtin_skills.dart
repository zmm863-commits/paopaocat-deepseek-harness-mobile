import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// 随包内置的技能（首页 12 条内置会话各绑一个）。
///
/// ## 为什么必须有这个（用户实测反馈的第 8 条）
///
/// 用户：「首页预置的四个内置会话点击以后只是在会话有了几个字，是不是点任意
/// 一个开始会调用相应的技能？」
///
/// 他说得对，而且更根本的问题是：**手机端的 `$DSH_HOME/skills` 是空的**
/// —— 随包运行时里一个技能都没有。DSH 的技能是「会话开始时把技能目录（名字 +
/// 简介）递给模型，模型判断任务匹配才去读技能正文」，所以技能必须**先存在于
/// 设备上**，模型才可能用得上。这里负责把技能安装到
/// `<DSH_HOME>/skills/<name>/…`（DSH 的用户级技能根，见
/// `@deepseek-ai/dsh-skill-filesystem` 的 `roots()`）。
///
/// ## 2026-10-12：从"只装 SKILL.md"改成**整目录安装**
///
/// 原来这里只写一个文件（`<name>/SKILL.md`），因为当时每个技能就是一个文件。
/// 现在要支持两类**多文件技能**：
///   * 别人的技能是「SKILL.md 只留索引 + `references/*.md` 放细节」的**渐进式披露**写法
///     （自家 37 技能创作包里那一套有 254 个参考文件，见 `docs/技能质量对比-0.71.md`）；
///   * `diagram-design` 这类带 assets/scripts 的技能（4.89 MB）。
///
/// 所以改成：**把这个技能在包里出现的所有文件都装过去**（含子目录、含二进制），
/// 文件清单从 `AssetManifest` 现查（`rootBundle` 不能枚举目录，但 asset 清单可以）。
/// 只写 SKILL.md 的话，技能正文里那些 `references/xxx.md` 全是死链 ——
/// 而且**不会报错**，只是模型读不到、质量悄悄掉一档。
///
/// ## 覆盖策略（别改成"每次启动全量覆盖"）
///
/// 用户可以在「技能」页里改这些技能。规则是：
///   * 目标不存在 → 写入（安装）；
///   * 存在、且**每一个我们记过哈希的文件**都与磁盘一致（说明用户没动过）→
///     版本更新时覆盖，并把新增的文件补齐；
///   * 存在、但有任何一个记过哈希的文件被改过/删掉 → **整个技能一律不动**，
///     只记录"用户改过"，绝不把用户的修改悄悄冲掉。
///
/// ⚠️ 判定单位是**技能**而不是文件：用户动过这个技能的一个文件，我们就整体让位 ——
/// 否则"补一半、留一半"会产出用户没写过的混合版本（比不更新更坏）。
///
/// 哈希清单存在 `<DSH_HOME>/dsh-mobile-builtin-skills.json`（**放在技能根
/// 之外**，免得 DSH 的扫描器遇到一个不是技能目录的 JSON）。
class BuiltinSkills {
  BuiltinSkills._();

  /// 随包内置技能的名字。**必须与 `assets/skills/<name>/` 一一对应**，
  /// 并且每个都要在 `pubspec.yaml` 里**逐目录**列出来（写父目录不会递归打包）。
  ///
  /// ⚠️ 2026-10-12 更正一处旧说法：这里**不再**要求与 `data/builtin_starters.dart`
  /// 的 skill 字段一一对应。两者是两件事：
  ///   * 这个列表 = **装到设备上**的技能（模型每轮能看到名字 + 简介，任务匹配才去读正文）；
  ///   * starters = **首页的入口卡片**（12 条），只挑了其中一部分做成人人能点的场景。
  /// 所以「首页没入口」的技能照样会被模型用上（用户说"帮我做个网页"就会命中
  /// `frontend-design`），只是首页没有那张卡。加首页卡片是**产品决定**，不是安装的必要条件。
  static const List<String> names = <String>[
    // 手机界面操作（2026-10-23）：让 Agent 能看屏幕、点屏幕、开应用。
    'phone-agent',
    'make-slides',
    'make-image',
    'make-video',
    'data-analysis',
    'doc-processing',
    'doc-digest',
    'sheet-cleanup',
    'code-tool',
    'file-organize',
    'translate-polish',
    'study-cards',
    'weekly-report',
    // 2026-10-12：搬自 Anthropic 官方开源技能库的两个（Apache-2.0，中文改写版）。
    // 它们**没有首页入口**（见上面那段说明）。许可归属写在：
    //   `docs/第三方许可.md` 与设置页「关于 → 第三方组件与许可」（两处必须同步）。
    'frontend-design',
    'discernment-nudge',

    // 2026-10-12（用户「完成清单」）：**文档合写** —— 这一份是**我们自己写的**，
    // 不是搬运：上游那份 `doc-coauthoring` 正文依赖 Claude 产品概念（连接器 / artifacts），
    // 手机上落不了地，而且它的目录里**没有 LICENSE.txt**、许可不明 → 不搬（见台账 #82）。
    // 这一份按手机端真实能力重写：读得到（read-docx）、写得出去（make-docx），
    // 核心是**分步对齐**（先问给谁看 / 再出大纲 / 一次只写一两节 / 边写边确认）。
    // 与 `doc-processing` 的分工：那个是"改一份已有的"，这个是"一起写出新的"。
    // 它**没有首页入口**（和 frontend-design 那类一样，靠任务匹配命中即可）。
    'doc-cowrite',

    // 2026-10-12（用户「也可以」）：**小说改游戏**这条创作线 —— NovelToGame v0.4.0
    // （zenstory.ai，**MIT**，中文简介由本 App 改写、正文与 references/ 一字未改）。
    // 七个阶段是一条流水线，**都很小**（合计约 52 KB）：它们是"设计方法与流程"，
    // 不依赖 python / 桌面工具，所以手机上能直接用。
    // ⚠️ 它们的 `references/` 是**渐进式披露**的参考文件 —— 靠本次刚做的
    //    「整目录安装」才装得过去（只装 SKILL.md 的话正文里全是死链）。
    // 上游的 `examples/`（13MB 示例游戏，含成人向题材）**故意不随包**。
    'novel-to-game',
    'novel-game-analyze',
    'game-concept',
    'game-world-design',
    'game-art-direction',
    'game-build',
    'game-qa',

    // 2026-10-12（用户「a和b」的 B）：**画图表** —— diagram-design v2.6
    // （github.com/cathrynlavery/diagram-design，**MIT**）。44 种图型（架构/流程/时序/
    // ER/时间线/Sankey/甘特…），产物是**自包含 HTML + 内联 SVG** —— 而本 App 的资料库
    // **已经能渲染 HTML**，所以画出来的图能直接打开看。
    // ⚠️ 只搬了必需部分（约 0.9 MB）：SKILL.md + references/ + 五套模板 + icons；
    //    上游 211 个 example-*.html（4.4MB 质量参照）与 5 个 python 脚本**没随包**
    //    （本机没有 python；原因写在 SKILL.md 顶部的署名区块里）。
    'diagram-design',
    // ⚠️ 2026-10-10：`open-phone-app`（打开手机上的应用）已按用户要求**取消**，
    // 连同设备通道（device_bridge）、工具箱脚本（open-app.mjs）与白名单页一起删除。
    // 若以后要恢复，从 git 历史里找 `feat: 打开本机应用` 那一批（含 Kotlin 侧
    // 的 listLaunchableApps / openAppByQuery，以及清单里的 <queries> 声明）。
  ];

  /// 技能的入口文件（诊断与测试用；安装时走 [filesFor] 拿**全部**文件）。
  static String assetPathFor(String name) => 'assets/skills/$name/SKILL.md';

  static String manifestPath(String dshHome) =>
      '$dshHome/dsh-mobile-builtin-skills.json';

  /// 这个技能在包里**所有**文件的 asset key（按路径排序，稳定可测）。
  ///
  /// 为什么靠 `AssetManifest` 而不是自己列一张表：那样每加一个文件都要改两处，
  /// 迟早对不上；而 asset 清单是**打包时生成的事实**。
  static Future<List<String>> filesFor(String name) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final prefix = 'assets/skills/$name/';
    final out = <String>[
      for (final key in manifest.listAssets())
        if (key.startsWith(prefix) && key.length > prefix.length) key,
    ];
    out.sort();
    return out;
  }

  /// 安装 / 更新内置技能。返回给日志与界面用的统计。
  static Future<BuiltinSkillReport> install(String dshHome) async {
    var installed = 0;
    var updated = 0;
    var keptUser = 0;
    final errors = <String>[];

    if (dshHome.trim().isEmpty) {
      return (
        installed: 0,
        updated: 0,
        keptUser: 0,
        errors: <String>['DSH_HOME 为空']
      );
    }

    final manifest = await _readManifest(dshHome);
    final owned = <String, Map<String, String>>{
      for (final e in manifest.entries) e.key: <String, String>{...e.value},
    };

    for (final name in names) {
      final dirPath = '$dshHome/skills/$name';
      try {
        final keys = await filesFor(name);
        if (keys.isEmpty) {
          errors.add('$name: 包里没有这个技能的任何文件（pubspec 是不是漏了这一行？）');
          continue;
        }

        // 读进内存并算哈希。技能都是小文件（最大的也就几 MB），不必流式。
        final assetBytes = <String, Uint8List>{};
        final assetHashes = <String, String>{};
        const prefix = 'assets/skills/';
        for (final key in keys) {
          final rel = key.substring(prefix.length + name.length + 1);
          final data = await rootBundle.load(key);
          final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
          assetBytes[rel] = bytes;
          assetHashes[rel] = _sha256Bytes(bytes);
        }

        final tracked = owned[name];
        final dirExists = Directory(dirPath).existsSync();

        // ① 用户改过吗？（判定单位 = 整个技能）
        if (tracked != null) {
          final touched = await _userTouched(dirPath, tracked);
          if (touched) {
            keptUser++;
            owned.remove(name);
            debugPrint('[dsh-skills] $name 已被用户修改，保留用户的版本（含新增文件也不覆盖）');
            continue;
          }
        }

        // ② 需要写吗？（已经是最新的就跳过 —— 不产生无谓 IO 与文件时间戳变化）
        if (tracked != null && dirExists && _sameHashes(tracked, assetHashes)) {
          owned[name] = assetHashes;
          continue;
        }

        for (final e in assetBytes.entries) {
          final f = File('$dirPath/${e.key}');
          await f.parent.create(recursive: true);
          await f.writeAsBytes(e.value, flush: true);
        }
        owned[name] = assetHashes;
        if (dirExists) {
          updated++;
        } else {
          installed++;
        }
      } catch (e) {
        errors.add('$name: $e');
        debugPrint('[dsh-skills] 安装技能 $name 失败：$e');
      }
    }

    await _writeManifest(dshHome, owned);
    final report = (
      installed: installed,
      updated: updated,
      keptUser: keptUser,
      errors: errors,
    );
    debugPrint(
      '[dsh-skills] 内置技能：新增 $installed / 更新 $updated / '
      '保留用户改动 $keptUser / 失败 ${errors.length}（根目录 $dshHome/skills）',
    );
    return report;
  }

  /// 我们记过哈希的文件里，有任何一个与磁盘不一致（改了或删了）→ true。
  ///
  /// 只检查**我们记过的**那些：用户自己新加的文件不算"改动"（那是加法，不冲突）。
  static Future<bool> _userTouched(
      String dirPath, Map<String, String> tracked) async {
    for (final e in tracked.entries) {
      final f = File('$dirPath/${e.key}');
      if (!f.existsSync()) return true;
      if (_sha256Bytes(await f.readAsBytes()) != e.value) return true;
    }
    return false;
  }

  static bool _sameHashes(
      Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  /// 读哈希清单。格式 v2 = `{name: {相对路径: sha256}}`。
  ///
  /// **兼容 v1**（`{name: sha256}`，只记 SKILL.md）：老版本装上的技能在第一次
  /// 升级时要能被正确识别为"是我们的"，否则会被当成"用户改过"而永远不再更新。
  static Future<Map<String, Map<String, String>>> _readManifest(
      String dshHome) async {
    try {
      final f = File(manifestPath(dshHome));
      if (!f.existsSync()) return <String, Map<String, String>>{};
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return <String, Map<String, String>>{};

      // ⚠️ **必须读 `owned` 这一层**（历史上这里读错过）。
      //
      // 2026-10-12 修：原来的写法是「遍历**顶层**、留下值是字符串的键」，
      // 而文件长这样：`{version:1, updatedAt:"2026-…", owned:{技能名:哈希}}` ——
      // 顶层里唯一是字符串的是 `updatedAt`，于是读回来的是
      // `{'updatedAt': '2026-…'}`：`owned['make-image']` **恒为 null**。
      // 后果很严重而且完全静默：`lastWritten == null` 让"用户改过就让位"这条
      // **从来没生效过** —— 每次启动都会把所有内置技能**覆盖回原版**，
      // 用户的手改白改。
      final ownedRaw = decoded['owned'];
      if (ownedRaw is! Map) return <String, Map<String, String>>{};

      final out = <String, Map<String, String>>{};
      for (final e in ownedRaw.entries) {
        final v = e.value;
        if (v is String) {
          // v1：那条哈希指的是 SKILL.md（v1 每个技能只记一个文件）
          out['${e.key}'] = <String, String>{'SKILL.md': v};
        } else if (v is Map) {
          out['${e.key}'] = <String, String>{
            for (final f2 in v.entries)
              if (f2.value is String) '${f2.key}': f2.value as String,
          };
        }
      }
      return out;
    } catch (e) {
      debugPrint('[dsh-skills] 读内置技能清单失败（按空处理）：$e');
      return <String, Map<String, String>>{};
    }
  }

  static Future<void> _writeManifest(
      String dshHome, Map<String, Map<String, String>> owned) async {
    try {
      final dir = Directory(dshHome);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await File(manifestPath(dshHome)).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
              'version': 2,
              'updatedAt': DateTime.now().toIso8601String(),
              'owned': owned,
            })}\n',
        flush: true,
      );
    } catch (e) {
      debugPrint('[dsh-skills] 写内置技能清单失败：$e');
    }
  }

  /// 按**字节**算哈希（不是按文本）—— 技能里可能有图片/字体这类二进制文件，
  /// 用 `utf8.encode` 会直接抛在二进制上。
  static String _sha256Bytes(List<int> bytes) =>
      sha256.convert(bytes).toString();
}

typedef BuiltinSkillReport = ({
  int installed,
  int updated,
  int keptUser,
  List<String> errors,
});
