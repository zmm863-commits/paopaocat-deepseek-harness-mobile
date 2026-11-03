import 'dart:io';

import 'package:flutter/material.dart';

import '../../i18n/dsh_i18n.dart';
import '../../local/backup_service.dart';
import '../../local/dsh_runtime.dart';
import '../theme/dsh_tokens.dart';

/// 「备份与恢复」—— 把数据打成一个加密文件，新手机上再还原。
///
/// 用户 2026-10-31 定名「备份与恢复」（原「备份与换手机」）：恢复也是高频动作，
/// 名字里只提换手机会让人以为平时用不上。
///
/// ## 这个页面只解决一件事
///
/// 用户换手机。**不是**网盘浏览、不是自动同步 —— 就是「导出 → 自己传过去 → 导入」。
///
/// ## 为什么不接网盘
///
/// 用户手上已经有微信、QQ、网盘 App。App 只需要把数据变成一个文件，
/// 传那一步交给他们已经在用的工具。这样零服务器、零授权、不会因为
/// 某个第三方接口改了就挂掉。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.runtime});

  final DshRuntime runtime;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final TextEditingController _pw = TextEditingController();
  bool _busy = false;
  String? _note;
  String? _error;

  /// 最近一次备份成功的文件路径（2026-11-01）。
  ///
  /// 用户反馈「点开始备份，能看到备份，怎么分享出去、备份文件在哪不知道」——
  /// 以前备份完只自动弹一次分享面板，一关就再也找不着文件了。所以这里记住路径：
  /// ① 界面上把路径显示出来；② 常驻一个「分享」按钮随时重发分享面板。
  String? _lastOut;

  @override
  void initState() {
    super.initState();
    _restoreLastOut();
  }

  /// 上次备份的文件路径（落盘）。
  ///
  /// ⚠️ 为什么必须落盘（2026-11-03 用户第二次反馈「不知道备份文件在什么地方，
  /// 也没有分享按钮」）：`_lastOut` 原来只是内存字段，**App 一重启就没了** ——
  /// 用户备份完关掉 App 再进来，路径和分享按钮双双消失，看起来就像"从来没做过备份"。
  String get _lastOutFile => '${widget.runtime.filesDir}/last_backup.txt';

  Future<void> _restoreLastOut() async {
    try {
      final f = File(_lastOutFile);
      if (!f.existsSync()) return;
      final path = f.readAsStringSync().trim();
      if (path.isEmpty || !File(path).existsSync()) return;
      if (!mounted) return;
      setState(() => _lastOut = path);
    } catch (_) {
      // 读不到就当没有，不打扰用户
    }
  }

  Future<void> _rememberLastOut(String path) async {
    try {
      File(_lastOutFile).writeAsStringSync(path);
    } catch (_) {
      // 写失败不影响备份本身
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  // ── 备份 ─────────────────────────────────────────────────────────

  Future<void> _pack() async {
    final pw = _pw.text;
    if (pw.trim().length < 8) {
      setState(() => _error = context.tr('密码至少 8 位 —— 它要挡住的是「拿到文件的人」。'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _note = context.tr('正在打包…');
    });
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll(':', '')
        .replaceAll('-', '')
        .replaceAll('T', '-');
    // ⚠️ 备份包必须落在**有 FileProvider 白名单**的子目录里（2026-11-03 真机踩到）：
    // 原来直接写在 `files/` 根下，分享时抛
    //   `NOT_SHAREABLE: 这个文件所在的位置不允许对外分享`
    // （白名单是按用途逐条开的，根目录故意没开 —— 那里有运行时 zip、标记文件）。
    //
    // 所以改写到 `files/backups/`，并在 `res/xml/file_paths.xml` 给它开一条。
    // 不图省事写 `path="."`：那会把整个私有目录都开出去。
    final backupDir = Directory('${widget.runtime.filesDir}/backups');
    if (!backupDir.existsSync()) backupDir.createSync(recursive: true);
    final out = '${backupDir.path}/泡泡猫备份-$stamp.pcbak';
    final r = await BackupService.pack(
      runtime: widget.runtime,
      password: pw,
      outPath: out,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) {
        _lastOut = r.out;
        if (r.out != null) _rememberLastOut(r.out!);
        _note = context.tr('备份好了：{0} 个文件。想传走就点下面的「分享」。',
            <Object?>['${r.files}']);
      } else {
        _error = r.error;
        _note = null;
      }
    });
    if (r.ok && r.out != null) {
      // 顺手把系统分享面板拉起来（多数用户的下一步就是"传走"）。
      // 但**不能只靠这一次**：面板一关用户就找不着文件了 —— 所以上面记了路径、
      // 下面也留了常驻的「分享」按钮，随时能再发一次。
      final res = await DshHost.shareFile(r.out!, subject: '泡泡猫备份');
      if (!mounted) return;
      if (res == 'no_app') {
        setState(() => _note = context.tr('这台设备没有能分享的应用。'
            '备份文件在：{0}', <Object?>[r.out!]));
      }
    }
  }

  /// 把最近一次备份再分享一次（面板关了也能重发）。
  Future<void> _shareAgain() async {
    final path = _lastOut;
    if (path == null || path.trim().isEmpty) return;
    try {
      final res = await DshHost.shareFile(path, subject: '泡泡猫备份');
      if (!mounted) return;
      if (res == 'no_app') {
        setState(() => _error = context.tr('这台设备没有能分享的应用。'
            '文件在：{0}', <Object?>[path]));
      }
    } catch (e) {
      // ⚠️ 老位置的备份包分享不了（2026-11-03）：白名单只开了 backups/ 等几个
      // 子目录，而**这一版之前的备份包都写在 files/ 根下**。用户升级后点分享
      // 会抛 NOT_SHAREABLE。
      //
      // 不假装成功，也不只说"失败" —— 告诉他换哪个按钮：
      // 「保存到手机」走系统 SAF（直接读文件，不经过 FileProvider），旧包也能存出去。
      if (!mounted) return;
      final msg = '$e';
      setState(() => _error = msg.contains('NOT_SHAREABLE')
          ? context.tr('这个备份包在旧位置，系统不允许分享。'
              '换用「保存到手机」把它存到下载目录，或者重新做一次备份。')
          : msg);
    }
  }

  /// 把最近一次备份**另存到用户自己选的位置**（通常是「下载」目录）。
  ///
  /// 为什么要有它（2026-11-03 用户：「不知道备份的文件在什么地方」）——
  /// 备份文件本来打在 App 私有目录（`/data/data/.../files/`），
  /// **文件管理器根本看不到**。所以光告诉他路径没用，得给他一个
  /// "存到我能找到的地方"的动作。
  ///
  /// 走系统 SAF（`ACTION_CREATE_DOCUMENT`）：不需要任何存储权限，
  /// 位置由用户自己选 —— 这是 Android 10+ 分区存储下的正路。
  Future<void> _saveToPhone() async {
    final path = _lastOut;
    if (path == null || path.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final name = path.split('/').last;
      final r = await DshHost.exportTextFile(
        fileName: name,
        sourcePath: path,
        // 备份包是二进制，给一个通用类型（避免被当成文本打开而损坏）
        mime: 'application/octet-stream',
      );
      if (!mounted) return;
      setState(() {
        if (r == 'cancel') {
          // 用户自己取消，不是错误 —— 什么都不说
        } else if (r.startsWith('ok:')) {
          _note = context.tr('已保存到你选的位置。以后从「文件管理 → 下载」就能找到它。');
        } else {
          _error = context.tr('没能保存（{0}）', <Object?>[r]);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 恢复 ─────────────────────────────────────────────────────────

  Future<void> _pickAndRestore() async {
    final path = await DshHost.pickAttachment('file');
    if (path == null || path.trim().isEmpty || !mounted) return;
    final pw = _pw.text;
    if (pw.trim().isEmpty) {
      setState(() => _error = context.tr('先在上面填当时的备份密码，再选文件。'));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _note = context.tr('正在读取备份包…');
    });
    final info = await BackupService.inspect(
      runtime: widget.runtime,
      inPath: path,
      password: pw,
    );
    if (!mounted) return;
    if (!info.ok) {
      setState(() {
        _busy = false;
        _note = null;
        _error = info.error;
      });
      return;
    }
    setState(() {
      _busy = false;
      _note = null;
    });

    // 先让用户看清"这个包里是什么"，再动手 —— 导入是破坏性的。
    final when = info.createdAt?.toString().substring(0, 16) ?? '?';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('确认恢复？')),
        content: Text(
          context.tr('这个包里是：{0} 个文件，打包于 {1}。\n\n'
              '恢复会覆盖当前手机上的数据。不过放心 —— 覆盖之前会自动'
              '先给现在的数据打一份备份，出错了能倒回去。\n\n'
              '模型 API Key 不会迁移（存在系统加密区，导不出来），'
              '恢复后需要重新填。',
              <Object?>['${info.files}', when]),
          style: const TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('确认恢复'),
                style: TextStyle(color: DshColors.err)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busy = true;
      _note = context.tr('正在恢复…（先给当前数据留一份备份，再覆盖）');
    });
    final r = await BackupService.restoreWithSafety(
      runtime: widget.runtime,
      inPath: path,
      password: pw,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) {
        _error = null;
        _note = context.tr('恢复完成：{0} 个文件。导入前的备份在「{1}」。',
            <Object?>['${r.files}', r.safetyPath ?? '']);
      } else {
        _note = null;
        _error = r.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              DshMetrics.pagePad, DshMetrics.pagePad, DshMetrics.pagePad, 32),
          children: [
            Row(
              children: [
                Semantics(
                  button: true,
                  label: context.tr('返回'),
                  child: InkWell(
                    onTap: () => Navigator.of(context).maybePop(),
                    borderRadius: BorderRadius.circular(DshMetrics.radius(9)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(2, 6, 8, 6),
                      child: Icon(Icons.arrow_back_ios_new,
                          size: 16, color: DshColors.text),
                    ),
                  ),
                ),
                Text(
                  context.tr('备份与恢复'),
                  style: TextStyle(
                    color: DshColors.text,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              context.tr('把会话、记忆、模型配置、工作区文件打成一个**加密文件**。'
                  '换新手机时，把它带过去再恢复就行。'),
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 14),

            // 密码（备份与恢复共用同一个输入框：用户想的就是"我那次的密码"）
            Text(context.tr('备份密码'),
                style: TextStyle(
                    color: DshColors.text, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: _pw,
              obscureText: true,
              enabled: !_busy,
              decoration: InputDecoration(
                hintText: context.tr('至少 8 位'),
                helperText: context.tr(
                    '忘了这个密码，备份文件就永远打不开了 —— 没有找回途径。'),
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 14),

            _actionCard(
              title: context.tr('备份到文件'),
              desc: context.tr('打包当前手机上的数据，然后用系统分享发到任何地方'
                  '（微信、网盘、数据线都可以）。'),
              button: context.tr('开始备份'),
              onTap: _busy ? null : _pack,
            ),
            const SizedBox(height: 10),
            _actionCard(
              title: context.tr('从文件恢复'),
              desc: context.tr('选一个 .pcbak 文件，输入当时的密码。'
                  '恢复前会自动给当前数据留一份备份。'),
              button: context.tr('选择备份文件'),
              onTap: _busy ? null : _pickAndRestore,
            ),

            if (_note != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: DshColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                ),
                child: Text(_note!,
                    style: TextStyle(
                        color: DshColors.text, fontSize: 12, height: 1.6)),
              ),
            ],
            // 最近一次备份：把**文件在哪**写出来 + 一个随时能再发的「分享」按钮。
            // （用户 2026-11-01：以前只自动弹一次分享面板，一关就找不着文件了。）
            if (_lastOut != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: DshColors.surface,
                  borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                  border: Border.all(color: DshColors.line, width: 0.8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.tr('最近一次备份'),
                        style: TextStyle(
                            color: DshColors.textDim,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    // 路径用等宽字体、允许换行 —— 太长也要能看全
                    Text(_lastOut!,
                        style: DshFonts.code(
                            color: DshColors.textFaint, fontSize: 10),
                        softWrap: true),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        // 「保存到手机」是**真正解决"文件在哪"**的那个按钮：
                        // 备份包原本在 App 私有目录，文件管理器看不到。
                        FilledButton.tonalIcon(
                          onPressed: _busy ? null : _saveToPhone,
                          icon: const Icon(Icons.download, size: 15),
                          label: Text(context.tr('保存到手机'),
                              style: const TextStyle(fontSize: 12)),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _shareAgain,
                          icon: const Icon(Icons.share, size: 15),
                          label: Text(context.tr('分享'),
                              style: const TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.tr('「保存到手机」存到你自己选的位置（一般是「下载」），'
                          '之后文件管理器里就能看到；「分享」直接发到微信/网盘。'),
                      style: TextStyle(
                          color: DshColors.textFaint,
                          fontSize: 10,
                          height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: DshColors.err.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(DshMetrics.radius(8)),
                ),
                child: Text(_error!,
                    style: TextStyle(
                        color: DshColors.err, fontSize: 12, height: 1.6)),
              ),
            ],

            const SizedBox(height: 20),
            Text(
              context.tr('不会迁移的东西：模型 API Key（存在系统加密区，任何 App 都导不出来）、'
                  '运行时文件（新手机装完 App 会自己解包）。\n\n'
                  '恢复后要做的第一件事：到「模型」里把缺的 Key 补上。'),
              style: TextStyle(
                  color: DshColors.textFaint, fontSize: 11, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionCard({
    required String title,
    required String desc,
    required String button,
    required VoidCallback? onTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: DshColors.panel(
        radius: 11,
        color: DshColors.surfaceHigh,
        borderColor: DshColors.line,
        glow: false,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: DshColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(desc,
              style: TextStyle(
                  color: DshColors.textDim, fontSize: 11, height: 1.6)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: const TextStyle(fontSize: 12.5),
              ),
              child: Text(button),
            ),
          ),
        ],
      ),
    );
  }
}
