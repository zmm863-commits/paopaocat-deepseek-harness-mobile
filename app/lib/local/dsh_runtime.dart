import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../data/session_capabilities.dart';
import '../data/agnes_builtin.dart';
import '../data/configured_models.dart';
import 'android_toolbox.dart';
import 'diagnostics_log.dart';
import 'local_model_spec.dart';
import '../data/atomic_file.dart';

/// 与 Android 宿主的通道：运行时路径、解压、进度。
///
/// 宿主侧（MainActivity.kt）负责把随包的 DSH 运行时解开到 App 私有目录；
/// 这里只拿路径、触发解压，然后由 Dart 自己拉起 node 进程。
class DshHost {
  static const MethodChannel channel = MethodChannel('dsh/native');

  static void Function(int done, String current)? onUnpackProgress;

  /// 宿主（原生）收到**返回键 / 边缘侧滑返回手势**时问一句："这次要不要真的退？"
  ///
  /// 返回 true = 退到后台；false = 什么都不做。**没有设置处理器时按"允许退"处理**，
  /// 不能因为没人接管就把用户卡在界面里。
  ///
  /// 为什么要在原生侧问（用户第 10 条反馈）：Android 14+ 在 targetSdk ≥ 35 时返回手势
  /// 由系统直接处理，实测 Flutter 框架那条路收不到事件（在首页边缘侧滑一下，App 直接
  /// 退到后台，Dart 一行业务日志都没有）。所以 MainActivity 自己注册
  /// `OnBackInvokedCallback`，把决定权交回 Dart。
  static Future<bool> Function()? onSystemBack;

  /// 安装宿主回调（原生 → Dart 的方法通道）。
  ///
  /// 只装一次；重复调用是安全的（后一次覆盖同名前一次）。
  static void _installHandler() {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'unpackProgress':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          onUnpackProgress?.call(
              args['done'] as int? ?? 0, args['current'] as String? ?? '');
          return null;
        case 'modelImportProgress':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          onImportProgress?.call(
            args['done'] as int? ?? 0,
            args['total'] as int? ?? 0,
            args['current'] as String? ?? '',
          );
          return null;
        case 'shouldExitOnBack':
          final handler = onSystemBack;
          if (handler == null) return true;
          try {
            return await handler();
          } catch (e) {
            debugPrint('[dsh-host] onSystemBack 抛错（按允许退处理）：$e');
            return true;
          }
        // LiteRT-LM 是**进程内**的（没有子进程 stdout），它自己的日志走这条通道进来。
        // 上线理由：出问题时用户能在「运行日志」里看到，而不是只能靠我猜。
        case 'litertlmLog':
          final msg = call.arguments as String? ?? '';
          if (msg.isNotEmpty) {
            DiagnosticsLog.add('[dsh-litertlm]', msg);
            debugPrint('[dsh-litertlm] $msg');
          }
          return null;
        default:
          return null;
      }
    });
  }

  /// 注册解压进度回调（宿主 → Dart）。
  static void bindProgress(void Function(int done, String current) callback) {
    onUnpackProgress = callback;
    _installHandler();
  }

  /// 只注册"返回手势"这条通道（App 启动早期调用；与解压进度互不干扰）。
  static void bindBackHandler() => _installHandler();

  /// 「导入端侧模型」的进度（宿主 → Dart）：第 done 个 / 共 total 个 / 当前文件名。
  ///
  /// 为什么必须有：批量导入动辄几个 GB，用户得看到"正在拷第几个"，
  /// 否则就是在盯着一个转圈的界面猜它到底活着没有。
  static void Function(int done, int total, String current)? onImportProgress;

  static void bindImportProgress(
      void Function(int done, int total, String current) callback) {
    onImportProgress = callback;
    _installHandler();
  }

  static Future<Map<String, dynamic>> getPaths() async {
    final raw = await channel.invokeMethod<Map>('getPaths');
    return Map<String, dynamic>.from(raw ?? const {});
  }

  static Future<bool> isRuntimeReady() async =>
      await channel.invokeMethod<bool>('isRuntimeReady') ?? false;

  /// 解压随包运行时（幂等：已解压会立即返回）。
  static Future<bool> unpackRuntime() async =>
      await channel.invokeMethod<bool>('unpackRuntime') ?? false;

  /// **完整包**里有没有随包的运行环境（精简包返回 false —— 这不是错误）。
  static Future<bool> hasRuntimeAsset() async =>
      await channel.invokeMethod<bool>('hasRuntimeAsset') ?? false;

  /// 把随包的运行环境取出来落到 `files/runtime.zip`，返回字节数（没有 asset 时 0）。
  ///
  /// 走原生是为了**流式拷贝**：33 MB 的 asset 用 `rootBundle.load()` 会整个进内存。
  static Future<int> copyRuntimeAsset() async =>
      await channel.invokeMethod<int>('copyRuntimeAsset') ?? 0;

  // ------------------------------------------------------- 定时任务保活（前台服务）

  /// 启动/更新保活前台服务（常驻通知，见 `DshSchedulerService.kt`）。
  ///
  /// 刻意不抛异常：后台启动前台服务在部分 ROM 上会被系统直接拒绝
  /// （`IllegalStateException`），那是环境限制而不是 App 的 bug，
  /// 不该让界面崩掉。失败只记日志。
  static Future<void> startSchedulerService(int enabledCount) async {
    try {
      await channel.invokeMethod<bool>(
        'startSchedulerService',
        <String, dynamic>{'count': enabledCount},
      );
    } catch (e) {
      debugPrint('[dsh-host] startSchedulerService 失败: $e');
    }
  }

  static Future<void> stopSchedulerService() async {
    try {
      await channel.invokeMethod<bool>('stopSchedulerService');
    } catch (e) {
      debugPrint('[dsh-host] stopSchedulerService 失败: $e');
    }
  }

  /// 系统是否允许发通知。Android 13+ 没授权时**常驻通知不可见**（服务仍在跑），
  /// 界面需要如实告诉用户这一点。取不到返回 null（未知），别据此下结论。
  static Future<bool?> notificationsAllowed() async {
    try {
      return await channel.invokeMethod<bool>('notificationStatus');
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------- 附件与语音（系统 Intent）

  /// 选附件。`kind` 取：
  ///   * `file`  → 任意文件（ACTION_GET_CONTENT）
  ///   * `media` → 照片或视频
  ///   * `photo` → 直接拍照（ACTION_IMAGE_CAPTURE + FileProvider）
  ///
  /// 返回 App 私有目录 `files/attachments/` 下的**真实绝对路径**；
  /// **用户取消返回 null**（调用方要如实提示，不能假装选到了东西）。
  /// 失败抛 [PlatformException]，其 `message` 已是中文（原生侧给的）。
  static Future<String?> pickAttachment(String kind) async {
    final method = switch (kind) {
      'photo' => 'takePhoto',
      'media' => 'pickMedia',
      _ => 'pickFile',
    };
    return channel.invokeMethod<String>(method);
  }

  /// 拉起系统语音识别，返回识别文本；取消或没有可用识别服务时返回 null。
  static Future<String?> recognizeSpeech() async =>
      channel.invokeMethod<String>('recognizeSpeech');

  /// **语音能力自检**：这台设备到底有没有可用的语音识别服务？
  ///
  /// 返回：
  ///   * `sdkInt`              —— Android 版本；
  ///   * `recognitionAvailable` —— 系统「有识别服务」的官方判定；
  ///   * `onDeviceAvailable`   —— Android 12+ 的**设备端离线识别**是否可用；
  ///   * `intentHandlers`      —— 能处理 `RECOGNIZE_SPEECH` 的应用数量
  ///     （0 = 这台机器上没有装任何语音识别服务）；
  ///   * `language`            —— 实际使用的识别语言标签。
  ///
  /// 为什么要有它：用户反馈「语音还是不能用」时，光看现象分不清是
  /// **设备没有识别服务**（那谁都救不了，只能用文字输入或接云端）还是
  /// **有服务但识别失败**（那要查权限/语言包/时序）。有了这一项就能一次分清。
  static Future<Map<String, Object?>> speechSupport() async {
    final r =
        await channel.invokeMethod<Map<Object?, Object?>>('speechSupport');
    if (r == null) return <String, Object?>{};
    return r.map((k, v) => MapEntry('$k', v));
  }

  /// 松手即停：让正在进行的识别立刻结束（设备端路径），触发结果回调。
  ///
  /// 返回：
  ///   * `'ok'`     —— 已发出停止指令；
  ///   * `'noop'`   —— 当前没有在识别（例如走的是系统 Intent 路径，由系统自己录音）；
  ///   * `'failed'` —— 底层停止失败。
  ///
  /// **一律不抛错**：停止失败不该打断"取识别结果"这条主链路。
  static Future<String> stopSpeech() async =>
      (await channel.invokeMethod<String>('stopSpeech')) ?? 'noop';

  // ---------------------------------------------------- 手机系统权限（意见⑦）

  /// 读取一组系统权限的当前状态。
  ///
  /// 返回键 → 状态，状态取值：
  ///   * `granted`            —— 已授权；
  ///   * `denied`             —— 未授权，**还能再弹**系统授权框；
  ///   * `permanently-denied` —— 用户勾了"不再询问"，只能去系统设置里开；
  ///   * `not-declared`       —— 这个 Android 版本不需要它（例如 13 以下的通知）。
  ///
  /// 键：`microphone` / `location` / `photos` / `notifications`。
  static Future<Map<String, String>> permissionStatus() async {
    final r =
        await channel.invokeMethod<Map<Object?, Object?>>('permissionStatus');
    return _stringMap(r);
  }

  /// 申请一组权限（可能触发多次系统弹窗，由系统合并）。返回**申请后**的状态。
  static Future<Map<String, String>> requestPermissions(
      List<String> keys) async {
    final r = await channel.invokeMethod<Map<Object?, Object?>>(
      'requestPermissions',
      <String, dynamic>{'keys': keys},
    );
    return _stringMap(r);
  }

  /// 跳到本应用的系统设置详情页（权限被永久拒绝后唯一的出路）。返回是否成功拉起。
  static Future<bool> openAppSettings() async =>
      (await channel.invokeMethod<bool>('openAppSettings')) ?? false;

  /// 打开一个「特殊权限」的系统页面。
  ///
  /// [which] 取：`all-files`（全部文件访问）/ `overlay`（悬浮窗）/
  /// `write-settings`（修改系统设置）/ `usage-access`（使用情况访问）/
  /// `install-packages`（安装未知应用）。
  ///
  /// 返回 `opened` / `unsupported`（该版本没有这个页面）/ `failed`。
  /// **这些权限应用无法自行授予**，必须用户在系统页面里手动打开。
  static Future<String> openSpecialSettings(String which) async =>
      (await channel.invokeMethod<String>(
        'openSpecialSettings',
        <String, dynamic>{'which': which},
      )) ??
      'unsupported';

  static Map<String, String> _stringMap(Map<Object?, Object?>? raw) {
    if (raw == null) return <String, String>{};
    return raw.map((k, v) => MapEntry('$k', '$v'));
  }

  /// 用系统的"打开方式"打开一个文件（传**绝对路径**，必须在 App 私有目录内）。
  ///
  /// 返回：
  ///   * `'ok'`     —— 已经拉起某个应用；
  ///   * `'no_app'` —— 系统里没有能打开这种类型的应用
  ///     （**这是环境事实、不是失败**，调用方要如实告诉用户，别假装打开了）。
  ///
  /// 参数错误 / 文件不存在会抛 [PlatformException]（`message` 已是中文）。
  static Future<String> openFile(String path) async {
    final r = await channel.invokeMethod<String>(
      'openFile',
      <String, dynamic>{'path': path},
    );
    return r ?? 'ok';
  }

  // ------------------------------------------------------------- 应用内更新

  /// 问清"这台设备上的安装环境"：能不能装、已装应用是哪个签名。
  ///
  /// 为什么签名也一起问：覆盖安装要求**新旧包同一签名**，而 Dart 侧拿不到
  /// "已装应用的签名"（那是 `PackageManager` 的东西），只能由原生给。
  ///
  /// 返回原生给的原始 Map（键：`canInstall` / `installedSignature` / `versionCode` /
  /// `versionName` / `sdkInt` / `packageName`），由 `local/apk_installer.dart`
  /// 翻成强类型 —— 这里**不解释**，免得两处各解释一遍。
  static Future<Map<String, Object?>?> updateInfo() async {
    final r = await channel.invokeMethod<Map<Object?, Object?>>('updateInfo');
    if (r == null) return null;
    return r.map((k, v) => MapEntry('$k', v));
  }

  /// 校验一个 APK：是不是合法包、以及它的签名是否与**当前这个 App** 同一家。
  ///
  /// 返回键：`matched` / `apkSignature` / `installedSignature` / `reason` / `detail`。
  /// `reason` 是机器可读的原因（`not_an_apk` / `apk_unsigned` / `installed_unknown` /
  /// `signature_mismatch` / `read_failed`），**`matched` 为 false 时一定有值**。
  ///
  /// ⚠️ 这是"更新包没被换成别人的"的**唯一防线**：读不出签名一律算不通过，
  /// 不要在这里做任何"拿不到就当它过"的兜底。
  static Future<Map<String, Object?>?> verifyApk(String path) async {
    final r = await channel.invokeMethod<Map<Object?, Object?>>(
      'verifyApk',
      <String, dynamic>{'path': path},
    );
    if (r == null) return null;
    return r.map((k, v) => MapEntry('$k', v));
  }

  /// 把下载好的 APK 交给系统安装器（FileProvider + `package-archive`）。
  ///
  /// 返回：
  ///   * `'ok'`              —— 安装界面已拉起（**装没装成拿不到**，界面不能假装知道）；
  ///   * `'need_permission'` —— 还没允许"安装未知应用"，要先引导去系统设置；
  ///   * `'no_app'`          —— 系统里没有能处理安装 Intent 的应用（定制 ROM 上才有）；
  ///   * `'bad_path'`        —— 路径不在 FileProvider 白名单里（配置问题，要报出来）。
  static Future<String> installApk(String path) async {
    final r = await channel.invokeMethod<String>(
      'installApk',
      <String, dynamic>{'path': path},
    );
    return r ?? 'ok';
  }

  /// 用系统浏览器打开一个**网址**（内置厂家的「去注册 / 申请 Key」按钮）。
  ///
  /// 返回：
  ///   * `'ok'`     —— 已经拉起浏览器；
  ///   * `'no_app'` —— 设备上没有能打开网页的应用（环境事实，要如实告诉用户）。
  ///
  /// 只允许 http/https（原生侧也会再拦一次）；空串/非法 scheme 抛 [PlatformException]。
  /// 唤起**微信扫一扫**（用户 2026-10-15 第 8 条：「关于」里的公众号二维码长按
  /// 要能弹出扫描、进公众号）。
  ///
  /// ⚠️ **`ok` 只表示"把微信拉起来了"，不表示扫一扫真的开了。**
  ///
  /// `weixin://dl/scan` 是微信的**内部** scheme，微信现在**拒绝外部调用**：
  /// 本机实测长按后弹出来的是微信自己的错误页「对不起，当前页面无法访问」
  /// （社区实证一致："以前可以，现在不行了"）。所以界面**不许**再承诺
  /// "已打开微信扫一扫" —— 只能说"已经把微信叫起来了"。
  ///
  /// 返回（机器可读，界面翻成人话）：
  ///   * `ok`        —— 微信**接住了**这个 Intent（原生侧先 resolveActivity 确认
  ///     接住的是 `com.tencent.mm` 本尊，不是浏览器之类抢注的应用）。它之后画
  ///     扫一扫还是画错误页，由微信决定；
  ///   * `no_wechat` —— 没装微信，或 `weixin://` 被别的应用接住，或解析不到；
  ///   * `failed:…`  —— 其它异常（部分 ROM 会拦截非 http 的跳转）。
  ///
  /// 为什么不是"App 自己扫码"：那要加相机权限 + CameraX + 识别库，
  /// 而微信本来就有扫一扫 —— App 的职责只是**把它叫起来**。
  static Future<String> openWechatScan() async {
    try {
      final r = await channel.invokeMethod<String>('openWechatScan');
      return r ?? 'failed:empty';
    } catch (e) {
      return 'failed:$e';
    }
  }

  static Future<String> openUrl(String url) async {
    final r = await channel.invokeMethod<String>(
      'openUrl',
      <String, dynamic>{'url': url.trim()},
    );
    return r ?? 'ok';
  }

  /// 用**系统自带的 TTS** 把文本合成成 WAV 文件（口播/短剧的配音）。
  ///
  /// 为什么是系统 TTS：这是给**网友**用的 App —— 不能假设他们注册过某家云 TTS。
  /// 系统 TTS 人人都有、零配置、免费、可离线。想要更自然的音色可以在界面上改用 MiMo。
  ///
  /// 返回（**机器可读**，`data/tts.dart` 负责翻成人话）：
  ///   * `'ok'`        —— 合成好了、文件非空；
  ///   * `'no_engine'` —— 设备没有 TTS 引擎；
  ///   * `'no_lang'`   —— 有引擎但**没装中文语音数据**（要引导用户去系统设置装，或改用 MiMo）；
  ///   * `'no_text'` / `'bad_path'` —— 参数问题；
  ///   * `'error:…'`   —— 其它失败（含 `error:timeout`）。
  ///
  /// ⚠️ 合成是**异步**的：原生侧要等引擎回调 `onDone` 才返回，所以这个 Future
  /// 可能等几秒（长文本更久）。界面必须显示进度、可取消。
  static Future<String> ttsToFile({
    required String text,
    required String path,
    double? rate,
    double? pitch,
  }) async {
    final r = await channel.invokeMethod<String>('ttsToFile', <String, dynamic>{
      'text': text,
      'path': path,
      if (rate != null) 'rate': rate,
      if (pitch != null) 'pitch': pitch,
    });
    return r ?? 'ok';
  }

  /// 用系统的「分享」面板把一个文件发给其它应用（ACTION_SEND + FileProvider）。
  ///
  /// 返回：
  ///   * `'ok'`     —— 已经拉起分享面板（用户选了哪个应用不归我们管）；
  ///   * `'no_app'` —— 系统里没有任何能接收分享的应用
  ///     （环境事实、不是失败，调用方要如实说明）。
  ///
  /// 参数错误 / 文件不存在会抛 [PlatformException]（`message` 已是中文）。
  static Future<String> shareFile(String path, {String? subject}) async {
    final r = await channel.invokeMethod<String>(
      'shareFile',
      <String, dynamic>{
        'path': path,
        if (subject != null && subject.trim().isNotEmpty)
          'subject': subject.trim(),
      },
    );
    return r ?? 'ok';
  }

  /// 把一张**本地图片文件**存进**系统相册**（微信「扫一扫 → 相册」要用）。
  ///
  /// ## 为什么需要它
  ///
  /// 微信已经把 `weixin://dl/scan` 这条外部唤起路堵了（见 [openWechatScan]），
  /// 所以「关于」页那张公众号二维码得给一条**用户自己走得通**的路：
  /// **微信 → 扫一扫 → 右上角相册 → 选这张图**。二维码打包在 assets 里，
  /// 用户截屏也可以，但直接帮他存进相册更省事。
  ///
  /// ## 返回（机器可读，界面翻成人话）
  ///
  ///   * `'ok'`        —— 已经存进相册；
  ///   * `'bad_path'`  —— 源文件不存在 / 不是文件（环境事实，不是崩溃）；
  ///   * `'failed:…'`  —— 写入失败，或系统版本低于 Android 10
  ///     （那条路要存储权限，**原生侧刻意不申请**，返回一句中文说明）；
  ///     空路径也一样走这里（原生抛的 `BAD_ARGS` 被下面兜成 `failed:…`）。
  ///
  /// ⚠️ 调用方**必须**按这三个返回码如实提示：存没存进去是用户看得见的事实，
  /// 不许统一说"好了"。
  /// 让手机振一下（首页那只猫：点一下短振、连点到第 7 下长振）。
  ///
  /// 返回（机器可读，界面**不弹提示**、只在日志里留痕）：
  ///   * `'ok'`          —— 已经振了；
  ///   * `'off'`         —— **系统把振动关了**（设置 → 声音与振动）。这时不振动才是对的：
  ///                        界面照常弹泡泡即可，**不要试图绕过用户自己的开关**；
  ///   * `'no_vibrator'` —— 这台设备没有振动器（模拟器 / 部分平板）；
  ///   * `'failed:…'`    —— 其它异常（如实返回，不假装振过）。
  ///
  /// ⚠️ `VIBRATE` 是**普通权限**（安装即授予、不弹窗），所以它**不在**设置页
  /// 「手机权限」那一栏里 —— 那一页列的是要用户手动点的权限。
  static Future<String> vibrate(int ms) async {
    try {
      final r = await channel
          .invokeMethod<String>('vibrate', <String, dynamic>{'ms': ms});
      return r ?? 'ok';
    } catch (e) {
      // 测试环境没有原生实现时会走到这里（MissingPluginException 等）：
      // 振动失败**不该**影响交互，所以照实返回、由调用方忽略。
      return 'failed:$e';
    }
  }

  static Future<String> saveImageToGallery(String path) async {
    try {
      final r = await channel.invokeMethod<String>(
        'saveImageToGallery',
        <String, dynamic>{'path': path.trim()},
      );
      return r ?? 'failed:empty';
    } catch (e) {
      return 'failed:$e';
    }
  }

  /// 设备与安装信息（运行日志的头部要用，界面不展示）。
  ///
  /// 走原生而不是 `dart:io` 的 `Platform.*`：Android 上 Dart 只能给到
  /// `android` / `Linux` 这一层，拿不到 manufacturer / SDK / versionCode /
  /// ABI / 屏幕尺寸 —— 而那些恰恰是"分析崩溃"时第一眼要看的东西。
  /// 取不到时返回空 map（调用方降级成 Dart 侧能拿到的信息，不要假装成功）。
  static Future<Map<String, dynamic>> deviceInfo() async {
    try {
      final raw = await channel.invokeMethod<Map>('deviceInfo');
      return Map<String, dynamic>.from(raw ?? const <String, dynamic>{});
    } catch (e) {
      debugPrint('[dsh-host] 读设备信息失败：$e');
      return <String, dynamic>{};
    }
  }

  /// 用系统「保存文件」选择器（SAF，ACTION_CREATE_DOCUMENT）把 App 私有目录里的
  /// 一个文本文件导出到用户选的位置（通常是"下载"）。
  ///
  /// 为什么走它而不是自己写 `/sdcard/Download`：Android 10+ 的分区存储让
  /// "直接往公共目录写"既需要权限又容易被厂商 ROM 拦；SAF 是系统给的正路，
  /// 不需要任何权限，用户自己决定存哪儿。
  ///
  /// [fileName] 是**选择器里预填的文件名**（可以带中文）；
  /// [sourcePath] 必须是 App 私有目录里的真实文件；
  /// [mime] 默认 `text/plain`。
  ///
  /// 返回约定（调用方据此给用户**准确**的反馈）：
  ///   * `'ok:<content-uri>'` —— 已写入用户选的位置（uri 可直接显示给用户）；
  ///   * `'cancel'`           —— 用户自己取消了（**不是错误**）；
  ///   * `'no_app'`           —— 系统里没有"保存文件"界面（极罕见，环境事实）。
  ///
  /// 参数错误 / 源文件不存在 / 写失败会抛 [PlatformException]（`message` 已是中文）。
  static Future<String> exportTextFile({
    required String fileName,
    required String sourcePath,
    String mime = 'text/plain',
  }) async {
    final r = await channel.invokeMethod<String>(
      'exportTextFile',
      <String, dynamic>{
        'fileName': fileName,
        'sourcePath': sourcePath,
        'mime': mime,
      },
    );
    return r ?? 'cancel';
  }

  /// 从手机本地**批量**导入端侧模型。
  ///
  /// 真实实现全在原生侧（SAF 多选 → 分块流式拷贝 → sha256/字节数校验 → 原子改名），
  /// 原因见 MainActivity.kt 的 `launchModelImport`：`content://` 只有原生能读流，
  /// 而且 1–3 GB 的文件必须分块处理，不能过 Dart 的内存。
  ///
  /// 返回每个文件的结果（**成功失败都在里面，一个失败不影响其余**）；
  /// 用户在系统选择器里取消时返回 `null` —— 调用方要能把"取消"和"失败"分开说。
  static Future<List<Map<String, dynamic>>?> importModelFiles({
    required String targetDir,
    required List<Map<String, dynamic>> expected,
  }) async {
    final r = await channel.invokeMethod<List<Object?>>(
      'importModelFiles',
      <String, dynamic>{
        'targetDir': targetDir,
        'expected': expected,
      },
    );
    if (r == null) return null;
    return r
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
  }
}

/// 一次 node 执行的结果。
class DshRunResult {
  const DshRunResult(
      {required this.exitCode,
      required this.stdout,
      required this.stderr,
      this.cancelled = false});

  final int exitCode;
  final String stdout;
  final String stderr;

  /// 这次运行是不是**被调用方主动取消**的（见 [DshRuntime.runOnce] 的 `cancel`）。
  ///
  /// 单列一个字段而不是让调用方去猜 `exitCode == -9`：被 kill 的信号号在不同
  /// 平台上不一样，"取消"和"崩了"对用户是两句完全不同的话。
  final bool cancelled;

  bool get ok => exitCode == 0;

  @override
  String toString() =>
      'exit=$exitCode${cancelled ? '（已取消）' : ''}\n'
      '--- stdout ---\n$stdout\n--- stderr ---\n$stderr';
}

/// DSH 的本地运行时封装。
///
/// 关键约束（都是实测结论）：
///  - node 二进制必须以 `libnode.so` 的形式位于 nativeLibraryDir 才能执行；
///  - 依赖库同在该目录，通过 `LD_LIBRARY_PATH` 暴露；
///  - 必须以 `--expose-internals` 启动（替代缺失的原生 addon）；
///  - 必须 `--require` 文件系统 shim（Android SELinux 禁止硬链接，
///    而 DSH 的会话持久化用 link() 做原子写）；
///  - 必须 `--require` 执行环境 shim（Android 上没有 bash，而 DSH 的 bash 工具
///    写死了 spawn `"bash"` —— 见 `assets/toolbox/android-exec-shim.cjs`）。
class DshRuntime {
  DshRuntime(
    this.paths, {
    this.apiKey,
    this.apiKeys = const <String, String>{},
  });

  final Map<String, dynamic> paths;

  /// 模型 API Key（v1 单厂家形态，保留给老调用点）。
  final String? apiKey;

  /// 环境变量名 → Key（v2：每个厂家一把，见 `state/provider_keys.dart`）。
  final Map<String, String> apiKeys;

  String get nodeBinary => paths['nodeBinary'] as String? ?? '';

  /// 随包的 **ffmpeg**（口播 / 短剧的合成与拼接要用）。
  ///
  /// ⚠️ 与 node 完全同一个道理（这段注释别删，它解释了为什么不是 assets）：
  ///   * Android **不允许从 App 数据目录执行文件**（实测 EACCES，见
  ///     `assets/toolbox/android-exec-shim.cjs` 顶部注释）；
  ///   * 只有 `<nativeLibraryDir>/lib*.so` 能被 Gradle 打进包、解压出来、并且可执行；
  ///   * 所以 ffmpeg 是以 `libffmpeg.so` 的形式**假装成一个原生库**打包的。
  ///
  /// 名字必须是 `lib*.so`，**不能**改成 `ffmpeg` —— 改了就进不了 APK。
  /// 调用方式有两条路（都通）：
  ///   * 环境变量 `DSH_ANDROID_FFMPEG` / `AGNES_FFMPEG`（认变量的代码用这个）；
  ///   * 技能脚本里直接写 `ffmpeg ...`（shim 的 prelude 定义了同名 shell 函数）。
  String get ffmpegBinary => nativeLibDir.isEmpty ? '' : '$nativeLibDir/libffmpeg.so';
  String get ffprobeBinary => nativeLibDir.isEmpty ? '' : '$nativeLibDir/libffprobe.so';
  String get nativeLibDir => paths['nativeLibDir'] as String? ?? '';
  String get filesDir => paths['filesDir'] as String? ?? '';
  String get dshBin => paths['dshBin'] as String? ?? '';
  String get nodeHome => paths['nodeHome'] as String? ?? '';

  /// 出厂运行时**解包后**的根目录（`MainActivity.unpack()` 把压缩包里的 `app/`
  /// 解到 `<filesDir>/dsh`）。判断"运行时里有没有某个插件"就看这里。
  String get runtimeRoot => '$filesDir/dsh';

  /// 运行时里有没有 AnySearch 的搜索后端插件（决定 overlay 会不会写那两行）。
  bool get runtimeHasAnysearchPlugin =>
      SessionCapabilities.runtimeHasAnysearchPlugin(runtimeRoot);
  String get fsShim => paths['fsShim'] as String? ?? '';

  /// 模型 overlay 的落盘位置（首次运行前由 [writeModelConfig] 生成）。
  String get overlayPath => '$nodeHome/model.overlay.yml';

  /// 执行环境 shim 的落盘位置（由 `AndroidToolbox.install` 从随包资源复制）。
  String get execShimPath => '$filesDir/shims/android-exec-shim.cjs';

  /// 随包工具箱目录（pptx 生成脚本、轮换代理脚本）。
  String get toolboxDir => '$filesDir/toolbox';
  String get pptxScriptPath => '$toolboxDir/make-pptx.mjs';
  String get rotateProxyScriptPath => '$toolboxDir/rotate-proxy.mjs';

  /// 看图代理（用户意见②）：把图片转成文字描述，好喂给只认文字的模型。
  String get visionProxyScriptPath => '$toolboxDir/vision-proxy.mjs';

  /// 轮换代理的**兜底**起始端口。
  ///
  /// ⚠️ 正常路径已经不用它了（审计 P0-3）：代理现在用 `--port 0` 让系统挑一个
  /// **空闲**端口，真实端口由代理在就绪行里报出来、`RotationProxy` 再回填给 overlay。
  /// 固定端口（39321~39330）的问题是：同机任何应用扫这 10 个端口就能找到它，
  /// 然后用用户的 Key 花钱。这里只留给"代理没起来"时 overlay 的占位值。
  static const int rotateBasePort = 39321;

  /// 轮换代理的**客户端令牌**（审计 P0-3）。
  ///
  /// 为什么必须惰性生成 + 只在这里存一份：Dart 侧有两处要读它 ——
  /// ① 拉起代理时随 stdin 配置下发；② 写进 DSH 进程环境（overlay 用
  /// `apiKeyEnv: ROTATE_API_KEY` 引用，DSH 拿它当 provider 的 Key 发出来）。
  /// 两侧必须**同一个值**，而生成时机不能依赖启动顺序（代理可能在 DSH 进程
  /// 之前或之后才起）。惰性 getter + 静态缓存正好满足：谁先读都一样。
  static String? _rotateToken;
  static String get rotateToken => _rotateToken ??= _newToken();

  /// 32 位十六进制随机串（128 bit）。用 `Random.secure()`：这是安全令牌，
  /// 不能用可预测的伪随机。
  static String _newToken() {
    final r = Random.secure();
    final b = StringBuffer();
    for (var i = 0; i < 32; i++) {
      b.write(r.nextInt(16).toRadixString(16));
    }
    return b.toString();
  }

  /// 这个 App 起**任何** node 进程时都要带的那份环境。
  ///
  /// ⚠️ **公开是有原因的，别改回私有**：会话进程（`AcpClient.start`）之前自己拼了
  /// 一份精简 env（只有 LD_LIBRARY_PATH / DSH_HOME / PATH / TMPDIR + Key），于是
  /// `DSH_ANDROID_NODE_BIN` / `DSH_ANDROID_FS_SHIM` / `DSH_ANDROID_EXEC_SHIM` /
  /// `DSH_ANDROID_TMPDIR` / `DSH_ANDROID_TOOLBOX` / `AGNES_*` **一个都没有** →
  /// 执行环境 shim 认为自己"缺配置"从而完全不改写 → 模型一调 bash 就是
  /// `spawn bash ENOENT`（用户真机截图原文），`node "$DSH_ANDROID_TOOLBOX/make-image.mjs"`
  /// 也必然发不出去。**会话是唯一一条必须带全的路径**（定时任务/轮换代理早就带了）。
  Map<String, String> get environment => <String, String>{
        'LD_LIBRARY_PATH': nativeLibDir,
        'DSH_HOME': nodeHome,
        'HOME': filesDir,
        'PATH': '/system/bin:/system/xbin',
        'TMPDIR': '$filesDir/tmp',
        // 执行环境 shim 的配置（assets/toolbox/android-exec-shim.cjs 读它们）。
        // Android 上没有 bash / python / pandoc，只有 /system/bin/sh。
        'DSH_ANDROID_NODE_BIN': nodeBinary,
        'DSH_ANDROID_FS_SHIM': fsShim,
        'DSH_ANDROID_EXEC_SHIM': execShimPath,
        'DSH_ANDROID_TOOLBOX': toolboxDir,
        // 随包的 ffmpeg / ffprobe（口播 / 短剧用）。三个变量都给：
        //   · DSH_ANDROID_* 是本 App 的约定（shim 的 prelude 也读它定义 shell 函数）；
        //   · AGNES_FFMPEG 是桌面端影视工具插件认的名字（它 locate ffmpeg 时**优先**
        //     看这个变量）—— 用同一个名字，两边行为一致，技能脚本不用分平台改。
        if (ffmpegBinary.isNotEmpty) 'DSH_ANDROID_FFMPEG': ffmpegBinary,
        if (ffprobeBinary.isNotEmpty) 'DSH_ANDROID_FFPROBE': ffprobeBinary,
        if (ffmpegBinary.isNotEmpty) 'AGNES_FFMPEG': ffmpegBinary,
        // shim 用它做"可写临时目录"（Android 上没有 /tmp）。
        'DSH_ANDROID_TMPDIR': '$filesDir/tmp',
        // ── 内置的 Agnes（免费生图 / 生视频）────────────────────────────
        // 用户第 7 条要求：内置免费生图/生视频端点，用户提出要生成图片或视频时
        // 自动调用。脚本 `toolbox/make-image.mjs` / `make-video.mjs` 读这几个
        // 变量；`AGNES_API_KEY` 由 ProviderKeys 注入（用户没配就没有，脚本会
        // 如实让他去注册，不会假装生成成功）。
        'AGNES_BASE_URL': AgnesBuiltin.baseUrl,
        'AGNES_REGISTER_URL': AgnesBuiltin.registerUrl,
        'AGNES_DOCS_URL': AgnesBuiltin.docsUrl,
        'AGNES_IMAGE_MODEL': AgnesBuiltin.imageModel,
        'AGNES_VIDEO_MODEL': AgnesBuiltin.videoModel,
        // 每个厂家各自的凭据（overlay 用 apiKeyEnv 引用这些变量名）。
        //
        // ⚠️ 安全边界（2026-10-09 审计 P0-2）：这些 Key **不再**能被"模型驱动的
        // shell"读到。收紧的地方在 `assets/toolbox/android-exec-shim.cjs` 的
        // `parentEnvBase()` —— 它给子进程的 env 基底是**白名单**
        // （`DSH_ANDROID_` / `DSH_DEVICE_` / `AGNES_` / `LOCAL_`），
        // 而不是过去的"全量继承 process.env"。
        //
        // 为什么**不**在这里再设一份 `DSH_ANDROID_ENV_PASSTHROUGH`：那样白名单就
        // 存在于两个地方，改一处忘一处 → 要么漏凭据、要么把「打开本机应用 /
        // 免费生图」这类随包功能改坏。**清单只有一份，在 shim 里。**
        // 需要新的环境变量进 shell 时，去 shim 改那张表并补测试
        // （install/test-toolbox-node.mjs 盯着它）。
        ...apiKeys,
        // 轮换代理的客户端令牌（审计 P0-3）。overlay 里 `rotate` 厂家的
        // `apiKeyEnv: ROTATE_API_KEY` 引用它 → DSH 会把它当 Key 发成
        // `Authorization: Bearer <token>`，代理校验后才转发。
        //
        // ⚠️ 这个变量**必须留在 shell 白名单之外**（见 shim 的
        // `DEFAULT_ENV_PASSTHROUGH`，里面没有 `ROTATE_`）—— 否则模型驱动的
        // shell 能读到它，就能直接拿用户的 Key 去打代理。
        'ROTATE_API_KEY': rotateToken,
        // 凭据走环境变量：overlay 用 apiKeyEnv 引用同名变量，
        // 避免把 Key 拼进命令行（进程列表里可见）。
        if (apiKey != null && apiKey!.isNotEmpty) ...{
          'COM_API_KEY': apiKey!,
          'DEEPSEEK_API_KEY': apiKey!,
          'OPENAI_API_KEY': apiKey!,
        },
      };

  // ------------------------------------------------------------------ overlay

  /// 用一份**完整配置**重写 overlay（v2 主入口）。
  ///
  /// 之所以要 overlay：`acp` / `headless` 这类 profile 默认把路由写死为官方
  /// DeepSeek + DEEPSEEK_API_KEY，换成自建/第三方端点必须覆写这两行
  /// （agent-default-model 与 profile 自己的行）。
  ///
  /// **[config] 里所有厂家都会被写进去** —— 用户实测反馈「设置完一个模型就
  /// 无法再选其他厂家」，根因正是旧实现整份 overlay 只声明一个 provider，
  /// 一旦 DSH 路由里没声明过某个 model，切过去就报未知模型。
  ///
  /// [activeRoute] 是选中项的全限定 route（`deepseek/xxx` 或 `rotate/cat`）。
  /// [rotatePort] 是本地轮换代理的端口；配置里有组时才会写 `rotate` 这个厂家。
  ///
  /// [localModel] 是本机跑着的端侧模型（见 `local_model_server.dart`）。
  /// **它必须是"正在运行"的规格**：传 null 就不写 `local` 厂家 ——
  /// 这条很关键，否则 App 重启后 overlay 还指着一个已经死掉的本地端口，
  /// 用户看到的是"选了 local 模型，一发消息就报错"。
  Future<void> writeOverlayFromConfig({
    required ConfiguredConfig config,
    required String activeRoute,
    int? rotatePort,
    LocalModelSpec? localModel,
    /// 会话里的联网搜索：运行时里有 AnySearch 后端插件、且用户开着 → 写激活片段。
    ///
    /// 见 `data/session_capabilities.dart`（⚠️ 老运行包没有这个插件，硬写会让会话起不来，
    /// 所以调用方必须先确认 [runtimeHasAnysearchPlugin]）。
    bool nativeWebSearch = false,
    /// 子智能体是否提供（出厂是提供的）。关掉 → 写 disabled 片段。
    bool subagentEnabled = true,
    /// 指定子会话用哪家/哪个模型（都为空 = 跟随父会话，不写片段）。
    String? subagentProvider,
    String? subagentModel,
  }) async {
    final home = Directory(nodeHome);
    if (!home.existsSync()) home.createSync(recursive: true);

    final providers = <ProviderSpec>[...config.providers];
    final groups = <RotationGroupSpec>[...config.groups];

    // 只写"真的有模型"的厂家。
    //
    // ⚠️ 这个过滤是必须的：用户在设置里加了一个厂家但还没拉到模型时，
    // `providers` 里会有一个空 models 的条目；YAML 里 `models:` 后面没有任何列表项
    // 就是 **null**，DSH 的配置校验会因此让**整份 overlay** 失败 ——
    // 表现是"对话突然完全不能用"。宁可少写一个空厂家，也不能写坏整份配置。
    final emittable = <ProviderSpec>[
      for (final p in providers)
        if (config.models.any((m) => m.provider == p.id)) p,
    ];
    if (emittable.isEmpty && groups.isEmpty && localModel == null) {
      debugPrint(
          '[dsh-runtime] 没有任何「带模型的厂家」/轮换组/本地模型，拒绝写空 providers（会写坏 overlay）');
      return;
    }

    // 路由解析：形如 `provider/model`；厂家已消失时回落到第一个**可写**的厂家
    // （注意不是 `providers` 的第一个 —— 那可能是个空厂家）。
    var activeProvider = '';
    var activeModel = '';
    final slash = activeRoute.indexOf('/');
    if (slash > 0) {
      activeProvider = activeRoute.substring(0, slash);
      activeModel = activeRoute.substring(slash + 1);
    }
    final isRotate = activeProvider == ConfiguredModels.rotateProviderId;
    final isLocal = activeProvider == LocalModelSpec.providerId;

    if (!isRotate &&
        !isLocal &&
        !emittable.any((p) => p.id == activeProvider)) {
      if (emittable.isNotEmpty) {
        activeProvider = emittable.first.id;
        final mine =
            config.models.where((m) => m.provider == activeProvider).toList();
        activeModel = mine.isNotEmpty ? mine.first.id : config.models.first.id;
      } else if (groups.isNotEmpty) {
        // 一个模型都没配、但有轮换组：直接把默认指向第一个组。
        activeProvider = ConfiguredModels.rotateProviderId;
        activeModel = groups.first.name;
      } else {
        // 只有本地模型：默认就指向它（用户点了"启动本地服务"就该能直接用）。
        activeProvider = LocalModelSpec.providerId;
        activeModel = localModel!.modelId;
      }
    }
    if (isLocal) {
      // 本地服务没在跑（或模型换了）时，不要把默认指向它。
      if (localModel == null || localModel.modelId != activeModel.trim()) {
        debugPrint('[dsh-runtime] 选中的本地模型 "$activeModel" 不在运行，回落到第一个厂家');
        if (emittable.isNotEmpty) {
          activeProvider = emittable.first.id;
          final mine =
              config.models.where((m) => m.provider == activeProvider).toList();
          activeModel =
              mine.isNotEmpty ? mine.first.id : config.models.first.id;
        } else if (groups.isNotEmpty) {
          activeProvider = ConfiguredModels.rotateProviderId;
          activeModel = groups.first.name;
        } else {
          activeProvider = LocalModelSpec.providerId;
          activeModel = localModel!.modelId;
        }
      } else {
        activeModel = localModel.modelId;
      }
    }
    if (activeProvider == ConfiguredModels.rotateProviderId) {
      activeModel = activeModel.trim();
      if (activeModel.isEmpty && groups.isNotEmpty) {
        activeModel = groups.first.name;
      }
      if (groups.every((g) => g.name != activeModel)) {
        // 组被删掉了：回落到第一个可写厂家，不要写一个不存在的 provider/model。
        debugPrint('[dsh-runtime] 选中的轮换组 "$activeModel" 不存在，回落到第一个厂家');
        if (emittable.isNotEmpty) {
          activeProvider = emittable.first.id;
          final mine =
              config.models.where((m) => m.provider == activeProvider).toList();
          activeModel =
              mine.isNotEmpty ? mine.first.id : config.models.first.id;
        } else {
          activeModel = groups.first.name;
        }
      }
    }

    final buf = StringBuffer();
    // ⚠️ 这一段里**所有字符串值都必须过 `_yamlStr`（加双引号）**，一个都不能少。
    //
    // 为什么（2026-10-10 真机事故，用户报"轮换池叫 001 就所有模型都不能用"）：
    // YAML 会把**裸写的纯数字**解析成整数 —— `- id: 001` 变成数字 1，
    // 而 dsh-llm-pi-ai 校验 `id` 必须是字符串，于是报
    //   `$.providers.rotate.models[0].id expected string but got 1`
    // → `dsh: warning: 2 entries did not activate`（整张 providers 表没适配器）
    // → ACP `session/new 失败：Internal error`，**会话和定时任务全挂，换任何模型都不行**
    //   （因为坏的是 provider 注册表，不是某一个模型）。
    //
    // 加引号后 `- id: "001"` 就是字符串，纯数字池名照样能用。
    // 回读侧（readConfiguredRoute / countRegisteredModels）本来就会剥掉引号，
    // 所以这一改不会影响 App 自己读回配置。
    // ⚠️ 别把引号当作"多余"删掉 —— 这不是风格问题，是"数字名会不会炸掉全部模型"的问题。
    //
    // 规则（简单到不会漏）：**厂家名、模型 id、轮换组名、provider/model 路由值，
    // 一律过 `_yamlStr` 加引号**。常量（如 `rotate` / `local`）也照加 —— 统一规则才好检查，
    // 否则就要每处判断"这个值会不会是纯数字"，而漏一次就是全部模型都不能用。
    // 兜底断言见 `test/local_model_overlay_test.dart` 的"数字名"那组。
    buf.writeln('# 由 App 生成：把 DSH 的模型路由指向用户配置的端点。');
    buf.writeln('# 覆盖两处是必须的 —— profile 自己的 config 会盖掉 agent-default-model。');
    buf.writeln('# 这里会把**所有**厂家一起写进来，切厂家不会丢配置。');
    buf.writeln('- id: llm-pi-ai');
    buf.writeln('  name: "@deepseek-ai/dsh-llm-pi-ai"');
    buf.writeln('  config:');
    buf.writeln('    providers:');

    for (final p in providers) {
      buf.writeln('      ${_yamlStr(p.id)}:');
      buf.writeln('        apiKeyEnv: ${p.apiKeyEnv}');
      // ⚠️⚠️ 2026-10-17 订正：**不能再走"内置 provider"那条路**。
      //
      // 我原以为：只要不写 api/baseURL，DSH 就会用它**内置**的 `opencode-go` provider
      // （那样能自动带上 `x-opencode-session` 头）。真机打脸的原文（用户 97 版日志）：
      //   llm-pi-ai: provider "opencode-go" model "deepseek-v4.1-flash" needs an api;
      //   the installed catalog does not describe it,
      //   so set the route's api to the wire protocol its endpoint speaks
      // 也就是说 **DSH 的 catalog 里根本没有这个 provider**（pi-ai 的
      // `providers/opencode-go.js` 并不等于 DSH 的 installed catalog）。
      // 结果：会话建不起来，用户看到「会话没有建立起来」。
      //
      // 正确做法：**照自定义通道写全**（api + baseURL），**并用 `headers` 把那个头补上**
      // —— `profile` 的 schema 里 `headers: z.dict(z.string())` 是支持的，
      // 而实测 `x-opencode-session` 用**固定值**就能过校验（curl 验证：
      // 带 `x-opencode-session: dsh-probe-1` 会走到 401「Go requires a credential」，
      // 说明头本身已被接受；不带则是 400 MissingSessionID）。
      final needsOpenCodeHeader = p.id == 'opencode-go' || p.id == 'opencode';
      buf.writeln('        api: ${p.api}');
      buf.writeln('        baseURL: ${_yamlStr(p.baseUrl)}');
      if (needsOpenCodeHeader) {
        buf.writeln('        headers:');
        buf.writeln('          x-opencode-session: dsh-mobile');
      }
      buf.writeln('        models:');
      final mine = config.models.where((m) => m.provider == p.id).toList();
      for (final m in mine) {
        buf.writeln('          - id: ${_yamlStr(m.id)}');
        buf.writeln('            name: ${_yamlStr(m.displayName)}');
        buf.writeln('            contextWindow: ${m.context ?? 1000000}');
      }
    }

    // 轮换组：注册成 `rotate` 这个厂家下的"模型"（每个组一个），
    // 真正干活的是本地代理（见 local/rotation_proxy.dart）。
    if (groups.isNotEmpty) {
      final port = rotatePort ?? rotateBasePort;
      buf.writeln('      ${_yamlStr(ConfiguredModels.rotateProviderId)}:');
      buf.writeln('        apiKeyEnv: ROTATE_API_KEY');
      buf.writeln('        api: openai-completions');
      buf.writeln('        baseURL: "http://127.0.0.1:$port/v1"');
      buf.writeln('        models:');
      for (final g in groups) {
        buf.writeln('          - id: ${_yamlStr(g.name)}');
        buf.writeln('            name: ${_yamlStr('${g.name}（轮换组）')}');
        buf.writeln('            contextWindow: 1000000');
      }
    }

    // 端侧模型：注册成 `local` 这个厂家下的模型，真正干活的是 App 内起的
    // llama.cpp（见 local/local_model_server.dart）。它自带 OpenAI 兼容路由，
    // 所以这里只是"指过去"，没有任何转发逻辑。
    if (localModel != null) {
      buf.writeln('      ${_yamlStr(LocalModelSpec.providerId)}:');
      buf.writeln('        apiKeyEnv: ${LocalModelSpec.apiKeyEnvName}');
      buf.writeln('        api: openai-completions');
      buf.writeln('        baseURL: "http://127.0.0.1:${localModel.port}/v1"');
      buf.writeln('        models:');
      buf.writeln('          - id: ${_yamlStr(localModel.modelId)}');
      buf.writeln(
          '            name: ${_yamlStr('${localModel.displayName}（本机运行）')}');
      // ⚠️ 必须跟引擎的 -c 一致：DSH 拿它去 clamp maxTokens
      // （maxTokens = contextWindow - 已用 - 4096），写小了 → maxTokens=1 →
      // 空回复（真机踩坑见 local_model_spec.dart 的 contextSize 注释）。
      buf.writeln('            contextWindow: ${localModel.contextSize}');
    }

    buf.writeln();
    buf.writeln('- id: agent-default-model');
    buf.writeln('  name: "@deepseek-ai/dsh-agent-default-model"');
    buf.writeln('  config:');
    buf.writeln('    provider: ${_yamlStr(activeProvider)}');
    buf.writeln('    model: ${_yamlStr(activeModel)}');
    buf.writeln();
    buf.writeln('# ACP 服务器用自己的 config 决定每个新会话的路由，会盖掉 agent-default-model，');
    buf.writeln('# 所以要单独覆盖这一行 —— 漏掉它的话，对话会退回官方端点并因凭据无效而失败。');
    buf.writeln('- id: acp');
    buf.writeln('  name: "@deepseek-ai/dsh-acp"');
    buf.writeln('  config:');
    buf.writeln('    provider: ${_yamlStr(activeProvider)}');
    buf.writeln('    model: ${_yamlStr(activeModel)}');
    buf.writeln();
    buf.writeln('# ── Android 沙箱与执行环境（关键，别删）────────────────────────');
    buf.writeln('# 1) 沙箱后端是 Linux-only（landlock / namespace），Android 上不可用：');
    buf.writeln('#    read-only / workspace-write 下写文件、glob、bash 都会报');
    buf.writeln('#    "no backend usable"，模型根本写不出文件。');
    buf.writeln('# 2) 所以移动端默认 danger-full-access = 不套沙箱、直接执行。');
    buf.writeln('#    安全边界仍在：进程被 Android 应用沙箱（独立 UID）圈住，');
    buf.writeln('#    模型碰不到其它应用的数据，也出不了 App 私有目录之外。');
    buf.writeln('- id: sandbox-policy');
    buf.writeln('  name: "@deepseek-ai/dsh-sandbox-policy"');
    buf.writeln('  config:');
    buf.writeln('    mode: danger-full-access');
    buf.writeln();
    // ⚠️ **必须显式指定权限预设**（真机日志 2026-10-09 复现）：
    //    acp profile 声明的预设是 read-only / workspace-write / danger-full-access，
    //    而上面把 sandbox 默认值改成了 danger-full-access；**组合出来的
    //    “沙箱 + 审批”默认值就匹配不上任何一个预设** → 插件直接不激活，启动时报
    //      `permission (@deepseek-ai/dsh-permission-presets): Error: composed sandbox
    //       and approval defaults match no preset; configure defaultPreset explicitly`
    //      `dsh: warning: 1 entry did not activate`
    //    后果是会话里的命令审批与预设行为都不是我们以为的那套。
    //    修法就是这里显式点名 —— 本机拿同样的 patch 复现过：加这一行，两行报错都消失。
    buf.writeln('- id: permission');
    buf.writeln('  name: "@deepseek-ai/dsh-permission-presets"');
    buf.writeln('  config:');
    buf.writeln('    defaultPreset: danger-full-access');

    // ⚠️ **让 ds-bot 与 App 共用同一个工作区**（2026-10-19 用户报「生成的资料无法到资料库」）。
    // ds-bot 的团队工作区默认是 `<DSH_HOME>/bot/workspace`（它自己建的，见 roster.js:
    // `config.workspace ?? join(home, 'workspace')`），而 App 的「资料库」读的是
    // `<filesDir>/workspace` —— **两边不是同一个目录**，所以 Bot 产出的文件资料库看不到。
    // ds-bot 认 `config.workspace`，这里显式指过去（overlay 在 profile 之后应用，
    // 按 id 覆盖种子 insert 进来的那条 `bot`）。
    buf.writeln('- id: bot');
    buf.writeln('  config:');
    buf.writeln("    workspace: ${_yamlStr('$filesDir/workspace')}");


    // ── 会话里的两种能力（2026-10-15）：联网搜索的后端、以及子智能体开关 ──
    //
    // 为什么写在这里：overlay 是 App 唯一掌控的 patch 层，而出厂那层把
    // `web.searchProvider` 钉死在 deepseek-official（要 Key）、子智能体则是默认开。
    // 这两件事都是"按用户选择改钉"，片段由 data/session_capabilities.dart 生成（可单测）。
    if (nativeWebSearch) {
      buf.write(SessionCapabilities.nativeWebSearchPatch());
    }
    final subagent = SessionCapabilities.subagentPatch(
      enabled: subagentEnabled,
      provider: subagentProvider,
      model: subagentModel,
    );
    if (subagent.isNotEmpty) buf.write(subagent);

    writeStringAtomicSync(File(overlayPath), buf.toString());
    debugPrint(
      '[dsh-runtime] overlay 已重写：${providers.length} 个厂家 / '
      '${config.models.length} 个模型 / ${groups.length} 个轮换组，'
      '默认=$activeProvider/$activeModel',
    );
  }

  /// 写入模型配置（**v1 兼容入口**，老调用点还在用）。
  ///
  /// 语义：读现有 `models.json`（拿到别的厂家），把 (providerId, baseUrl)
  /// 这个厂家 upsert 进去、把 [modelId] / [fallbackModelId] / [extraModelIds]
  /// 注册到它名下，默认路由指向 `providerId/modelId`。
  Future<void> writeModelConfig({
    required String baseUrl,
    required String providerId,
    required String modelId,
    String? fallbackModelId,
    String? apiKeyEnvName,
    List<String> extraModelIds = const <String>[],
  }) async {
    final old = ConfiguredModels.readConfig(filesDir);
    final pid = ConfiguredModels.sanitizeProviderId(providerId);

    final spec = ConfiguredModels.provider(
      id: pid,
      label: old.providerOf(pid)?.label ?? providerId,
      baseUrl: baseUrl,
      apiKeyEnv: apiKeyEnvName,
    );

    final ids = <String>{modelId.trim()};
    if (fallbackModelId != null && fallbackModelId.trim().isNotEmpty) {
      ids.add(fallbackModelId.trim());
    }
    for (final e in extraModelIds) {
      if (e.trim().isNotEmpty) ids.add(e.trim());
    }

    final models = <ModelSpec>[
      for (final m in old.models)
        if (m.provider != pid) m,
      for (final id in ids)
        ModelSpec(
          provider: pid,
          id: id,
          name: old.modelOfRoute('$pid/$id')?.name,
          context: old.modelOfRoute('$pid/$id')?.context,
        ),
    ];

    await writeOverlayFromConfig(
      config: ConfiguredConfig(
        version: ConfiguredModels.currentVersion,
        providers: <ProviderSpec>[
          for (final p in old.providers)
            if (p.id != pid) p,
          spec,
        ],
        models: models,
        groups: old.groups,
        selected: '$pid/${modelId.trim()}',
      ),
      activeRoute: '$pid/${modelId.trim()}',
    );
  }

  /// 把运行时里的 anysearch 插件补进某个 profile 的 `node_modules`。
  ///
  /// 为什么要补（2026-10-17 对照真机日志发现的一个**判断错位**）：
  ///   * [runtimeHasAnysearchPlugin] 检查的是**运行时解包根**
  ///     （`<filesDir>/dsh/node_modules/@deepseek-ai/dsh-web-search-anysearch`）；
  ///   * 而真正 `import` 它的是 **profile 自己的 `node_modules`**。
  /// 两者不是一回事 → App 以为"有"、照常在补丁里写 `- insert: web-search-anysearch`，
  /// 而 `acp` profile 是 **DSH 首次使用时从它自带模板建的**，里面没有这个包 →
  /// 每次启动都刷 `web-search-anysearch (@deepseek-ai/dsh-web-search-anysearch): failed to import`。
  /// （对照：bottest 的**种子**里我们早就放了它，所以 bot 那边没这条。）
  ///
  /// 只在 profile 目录**已存在**时补 —— 不存在时交给 DSH 自己初始化，
  /// 下次启动前我们会再补一次。
  Future<void> ensureProfileHasAnysearch(String profileName) async {
    final src = Directory('$runtimeRoot/node_modules/@deepseek-ai/dsh-web-search-anysearch');
    if (!src.existsSync()) return;
    final profDir = Directory('$nodeHome/profiles/$profileName');
    if (!profDir.existsSync()) {
      debugPrint('[dsh-runtime] profile $profileName 还不存在，跳过补 anysearch（DSH 会自己初始化）');
      return;
    }
    final dst = Directory('${profDir.path}/node_modules/@deepseek-ai');
    final target = Directory('${dst.path}/dsh-web-search-anysearch');
    if (target.existsSync()) return;
    try {
      dst.createSync(recursive: true);
      // 用系统 cp 不可靠（Android 上路径与权限都别扭），交给 Dart 递归复制。
      _copyDirSync(src, target);
      debugPrint('[dsh-runtime] 已把 anysearch 插件补进 profile $profileName');
    } catch (e) {
      debugPrint('[dsh-runtime] 补 anysearch 到 profile $profileName 失败（会有 failed to import 警告）：$e');
    }
  }

  static void _copyDirSync(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final e in from.listSync(recursive: true, followLinks: false)) {
      final rel = e.path.substring(from.path.length + 1);
      final target = '${to.path}/$rel';
      if (e is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (e is File) {
        File(target).writeAsBytesSync(e.readAsBytesSync());
      }
    }
  }

  /// 写一份**最小 overlay**：只放"与模型无关、但会直接影响会话行为"的几段。
  ///
  /// 为什么需要单独一个方法（2026-10-17 真机铁证）：
  /// `writeOverlayFromConfig` 在"没有任何带模型的厂家"时会**主动拒绝**
  /// （`没有任何「带模型的厂家」/轮换组/本地模型，拒绝写空 providers（会写坏 overlay）`）
  /// —— 它这个自我保护是对的，但后果是：**还没配模型的用户根本没有 overlay 文件**，
  /// 于是 `BotServer` / `ACPServer` 那句 `if (runtime.hasModelConfig) [... '--patch', overlayPath]`
  /// 不成立，**连带权限预设一起没传** → 会话退回默认的 `workspace-write` + `approval: ask`；
  /// 而 Android 上**没有 DSH 需要的沙箱后端**，于是每个工具调用都要用户点一次批准。
  /// 用户的原话是「一直出现 agent 请求执行操作」，会话产物里的证据是
  /// `"sandboxMode": { "val": "workspace-write" }`。
  ///
  /// 这里**故意不写 providers**（避免"写坏 overlay"那个风险），只写权限段。
  Future<void> writeMinimalOverlay() async {
    final buf = StringBuffer();
    buf.writeln('# 由 App 生成：最小 overlay（用户还没配模型时也要有的那几段）。');
    buf.writeln('# 关键作用是权限预设 —— 缺了它，Android 上每个工具调用都要用户批准。');
    buf.writeln('- id: permission');
    buf.writeln('  name: "@deepseek-ai/dsh-permission-presets"');
    buf.writeln('  config:');
    buf.writeln('    defaultPreset: danger-full-access');

    // ⚠️ **让 ds-bot 与 App 共用同一个工作区**（2026-10-19 用户报「生成的资料无法到资料库」）。
    // ds-bot 的团队工作区默认是 `<DSH_HOME>/bot/workspace`（它自己建的，见 roster.js:
    // `config.workspace ?? join(home, 'workspace')`），而 App 的「资料库」读的是
    // `<filesDir>/workspace` —— **两边不是同一个目录**，所以 Bot 产出的文件资料库看不到。
    // ds-bot 认 `config.workspace`，这里显式指过去（overlay 在 profile 之后应用，
    // 按 id 覆盖种子 insert 进来的那条 `bot`）。
    buf.writeln('- id: bot');
    buf.writeln('  config:');
    buf.writeln("    workspace: ${_yamlStr('$filesDir/workspace')}");

    writeStringAtomicSync(File(overlayPath), buf.toString());
    debugPrint('[dsh-runtime] 已写最小 overlay（权限预设 danger-full-access）');
  }

  bool get hasModelConfig => File(overlayPath).existsSync();

  /// overlay 里有没有「Android 沙箱修复」**且**「权限预设显式指定」（升级迁移用）。
  ///
  /// ⚠️ 后半句是 2026-10-09 加的：老 overlay 里只有 sandbox-policy，没有
  ///    `defaultPreset` —— 那会让 `dsh-permission-presets` 不激活（启动时报
  ///    "composed sandbox and approval defaults match no preset"）。
  ///    所以判据必须**同时**看两段：只看 sandbox-policy 的话，老用户装上新版
  ///    也不会重写 overlay，那条错误会一直挂着。
  bool get overlayHasSandboxFix {
    final f = File(overlayPath);
    if (!f.existsSync()) return false;
    final txt = f.readAsStringSync();
    final hasSandbox =
        txt.contains('sandbox-policy') || txt.contains('danger-full-access');
    return hasSandbox && txt.contains('defaultPreset');
  }

  /// 匹配"厂家段落头"那一行：`      local:` 或 `      "local":`。
  ///
  /// 为什么**两种都必须认**：0.58 及更早写的是裸值；0.59 起为了"纯数字名不会被
  /// YAML 解析成整数"（否则 `- id: 001` → 整数 1 → 整张 providers 表不激活 →
  /// 所有模型都不能用，见 writeOverlayFromConfig 的注释）改成带引号。
  /// 用户升级时磁盘上留的是**旧写法**的 overlay —— 只认新写法会把"有 local 厂家"
  /// 判成没有，于是启动时误判"端口是残留的"而多写一次、或漏掉该做的清理。
  ///
  /// ⚠️ 正则用 StringBuffer 拼，不能写成 `r'...${...}...'`：Dart 的 raw string
  /// **不做插值**，那样会去找字面的 `${...}`，永远匹配不上（本文件历史上踩过两次）。
  /// ⚠️ 结尾那截必须用 **raw 串**（`r'\s*$'`）：写在普通字符串里 `\s` 不是合法转义，
  /// Dart 会把它当成字面 `s` —— 正则悄悄变成 `s*`（几乎匹配一切），
  /// 那种错误不会报错、只会让"认错厂家段落"。前半段要插值所以用普通串，两截拼起来。
  static RegExp _providerHeadRe(String id) =>
      RegExp('^ {6}"?${RegExp.escape(id)}"?:' r'\s*$');

  /// `text` 里有没有 `id:` 这个厂家段落（新旧两种写法都认，理由见 [_providerHeadRe]）。
  static bool _hasProviderSection(String text, String id) =>
      text.contains('$id:') || text.contains('"$id":');

  /// overlay 里有没有写「轮换组」那个本地代理厂家（升级迁移用：
  /// 老用户的 overlay 里没有它，而用户已经建了组，不重写就切不过去）。
  bool get overlayHasRotateProvider {
    final f = File(overlayPath);
    if (!f.existsSync()) return false;
    return _hasProviderSection(
        f.readAsStringSync(), ConfiguredModels.rotateProviderId);
  }

  /// overlay 里有没有写「端侧模型」这个本地厂家。
  bool get overlayHasLocalProvider {
    final f = File(overlayPath);
    if (!f.existsSync()) return false;
    return _hasProviderSection(
        f.readAsStringSync(), LocalModelSpec.providerId);
  }

  /// 读出 overlay 里记的**端侧模型服务端口**（没有则 null）。
  ///
  /// 为什么需要它：本地推理进程随 App 一起死，overlay 文件却留着。App 重开时
  /// overlay 可能还指着昨天那个端口 —— 那时 DSH 一发消息就是"连接被拒"。
  /// 启动时用它判定"是不是留了个坏端口"，然后重写 overlay 把它摘掉。
  ///
  /// 与 `readRotatePort` 同样的坑：**只能从 `local:` 段落里读**，
  /// 全文抓第一个 `127.0.0.1` 会抓到用户自己配的本地端点。
  int? readLocalModelPort() {
    try {
      final f = File(overlayPath);
      if (!f.existsSync()) return null;
      var inLocal = false;
      for (final line in f.readAsLinesSync()) {
        // ⚠️ 这里**必须**用字符串拼接而不是 r'...${...}...'：
        // Dart 的 raw string **不做插值**，写成 r'^ {6}$id:\s*$' 的话
        // 正则会去找字面的 `${...}`，永远匹配不上、函数永远返回 null。
        // （原来读轮换代理端口的那个函数就踩了这个坑，见下面 readRotatePort。）
        // ⚠️ 用 StringBuffer 拼，而不是 `r'...${...}...'` 或 `'a' + id + 'b'`：
        //   · raw string **不做插值** → 正则去找字面的 `${...}`，永远匹配不上
        //     （本函数的原始版本就是这么静默失效的，永远返回 null）；
        //   · 插值/拼接写正则 → 得在正则里写 `\$`（结尾锚）与 `\s` 双重转义。
        // StringBuffer 两头都躲开了，正则本身保持 `:\s*$` 的可读原样。
        if (_providerHeadRe(LocalModelSpec.providerId).hasMatch(line)) {
          inLocal = true;
          continue;
        }
        if (inLocal && RegExp(r'^ {6}\S').hasMatch(line)) break;
        if (!inLocal) continue;
        final m = RegExp(r'http://127\.0\.0\.1:(\d+)/v1').firstMatch(line);
        if (m != null) return int.tryParse(m.group(1)!);
      }
      return null;
    } catch (e) {
      debugPrint('[dsh-runtime] readLocalModelPort failed: $e');
      return null;
    }
  }

  /// 读出 overlay 里记的**轮换代理端口**（没有则 null）。
  ///
  /// 为什么要读它：代理是**本地进程**，App 一重启就没了，但 overlay 文件还在。
  /// 如果只在"需要重写 overlay"时才去起代理，就会出现「昨天能用、今天打开就报
  /// 连不上」——重启后代理没起，overlay 却还指着那个端口。
  ///
  /// ⚠️ 必须从 `rotate:` 这个厂家段落里读，**不能全文抓第一个 `127.0.0.1`**：
  /// 用户可能真的配了一个本地端点（我的联调配置里就有一个指向 `127.0.0.1:9` 的
  /// 坏端点），全文正则会把它的端口当成代理端口，于是每次都判定"端口不一致"白重写。
  int? readRotatePort() {
    try {
      final f = File(overlayPath);
      if (!f.existsSync()) return null;
      final lines = f.readAsLinesSync();
      var inRotate = false;
      for (final line in lines) {
        // ⚠️ 以前这里是 `RegExp(r'^ {6}${ConfiguredModels.rotateProviderId}:\s*$')`
        // —— Dart 的 raw string **不做插值**，于是这个正则去找字面的 `${...}`，
        // 永远匹配不上，`readRotatePort()` 一直返回 null：**"overlay 里记的端口
        // 与这次起的不一致就重写"这条逻辑从来没生效过**（端口被占用时会留下
        // 一个指向旧端口的 overlay）。由 local_model_overlay_test 顺带抓出来，一并修。
        // 同 readLocalModelPort：StringBuffer 拼正则，避开 raw-string 不插值
        // 与 `\$`/`\s` 双重转义两个坑。
        if (_providerHeadRe(ConfiguredModels.rotateProviderId).hasMatch(line)) {
          inRotate = true;
          continue;
        }
        if (inRotate && RegExp(r'^ {6}\S').hasMatch(line)) break; // 进入下一个厂家
        if (!inRotate) continue;
        final m = RegExp(r'http://127\.0\.0\.1:(\d+)/v1').firstMatch(line);
        if (m != null) return int.tryParse(m.group(1)!);
      }
      return null;
    } catch (e) {
      debugPrint('[dsh-runtime] readRotatePort failed: $e');
      return null;
    }
  }

  /// overlay 里 `providers.<id>.models` 下注册了几个 model。
  ///
  /// 解析失败（文件不存在/格式意外）返回 -1，调用方应视为"需要重写"。
  int countRegisteredModels() {
    try {
      final f = File(overlayPath);
      if (!f.existsSync()) return -1;
      var count = 0;
      for (final line in f.readAsLinesSync()) {
        // 只有 models 列表里的 `- id:` 才算（启动项自己的 `- id: llm-pi-ai` 缩进不同）
        if (RegExp(r'^ {10}- id:\s*\S+').hasMatch(line)) count++;
      }
      return count;
    } catch (e) {
      debugPrint('[dsh-runtime] countRegisteredModels failed: $e');
      return -1;
    }
  }

  /// 从已生成的 overlay 里读出**默认路由**（`agent-default-model` 那一段）。
  ///
  /// 只做很浅的解析：overlay 是本类自己写的，格式可控，不需要引 YAML 库。
  ({String? providerId, String? modelId}) readConfiguredRoute() {
    try {
      final f = File(overlayPath);
      if (!f.existsSync()) return (providerId: null, modelId: null);
      final lines = f.readAsLinesSync();
      String? provider;
      String? model;
      var inDefault = false;
      for (final line in lines) {
        if (RegExp(r'^- id:\s*agent-default-model\s*$').hasMatch(line)) {
          inDefault = true;
          continue;
        }
        if (inDefault && line.startsWith('- id:')) break; // 进入下一段
        if (!inDefault) continue;
        final mp = RegExp(r'^\s+provider:\s*(\S+)\s*$').firstMatch(line);
        if (mp != null) provider = mp.group(1)!.replaceAll('"', '');
        final mm = RegExp(r'^\s+model:\s*(\S+)\s*$').firstMatch(line);
        if (mm != null) model = mm.group(1)!.replaceAll('"', '');
      }
      return (providerId: provider, modelId: model);
    } catch (e) {
      debugPrint('[dsh-runtime] readConfiguredRoute failed: $e');
      return (providerId: null, modelId: null);
    }
  }

  // --------------------------------------------------------------- 进程与执行

  /// 运行时是否已解压就绪（fs shim 与 DSH 入口都已落盘）。
  bool get isUnpacked => File(fsShim).existsSync() && File(dshBin).existsSync();

  /// 启动一个 node 进程（调用方负责读写 stdio）。
  ///
  /// [withShims] = false 时不挂 `--require` 那两个 shim。留给"常驻小服务"这类
  /// 不需要改 child_process / 文件系统语义的脚本（见 `rotation_proxy.dart`：
  /// 实测在设备上挂 shim 起代理会失败，不挂就正常 —— 多一条退路比硬扛好）。
  Future<Process> spawn(
    List<String> args, {
    Map<String, String>? extraEnv,
    bool withShims = true,
  }) async {
    // 必须先检查：未解压时 node 只会报
    //   "Cannot find module '.../shims/android-fs-shim.cjs' (internal/preload)"
    // 用户根本看不出真正原因是"还没点准备运行时"。
    if (!isUnpacked) {
      throw StateError('运行时尚未就绪：请先点「准备运行时」完成解压（约需 75 秒），再执行。');
    }

    // 执行环境 shim / 工具箱是随包资源，第一次 spawn 前落到私有目录。
    await AndroidToolbox.ensureInstalled(filesDir);

    final tmp = Directory('$filesDir/tmp');
    if (!tmp.existsSync()) tmp.createSync(recursive: true);

    return Process.start(
      nodeBinary,
      <String>[
        '--expose-internals',
        if (withShims) ...['--require', fsShim, '--require', execShimPath],
        ...args,
      ],
      environment: <String, String>{...environment, ...?extraEnv},
      includeParentEnvironment: true,
      workingDirectory: filesDir,
    );
  }

  /// 跑一次性命令并收集输出（用于验证与 headless 任务）。
  ///
  /// ⚠️ **必须等管道排空**。第一版是 `await exitCode` 之后直接 `cancel()` 订阅 ——
  /// 对于"立刻退出"的命令（例如 `node --version`），退出事件往往比 stdout 的
  /// 数据事件先到，于是 cancel 把还没读到的输出**丢掉**，表现为
  /// `exit=0 stdout="" stderr=""`（真机上实测：App 里跑 `node --version` 读回空，
  /// 而从 shell 跑同一个命令有输出）。这里用 `asFuture()` 等两个流自然结束。
  ///
  /// [cancel]（可选）：那个 future 一旦完成，**立刻 kill 掉这次进程**，
  /// 返回的结果里 [DshRunResult.cancelled] 为 true。
  /// 谁需要它：模型提炼这类"用户会想中途放弃"的一次性任务（见
  /// `data/memory_extract.dart`）。**只 kill 自己这个进程** —— 不去碰会话
  /// （ACP）进程，那一条长连接是用户正在用的东西。
  /// 传 null 时这条路径**与以前一模一样**（没有任何额外分支）。
  Future<DshRunResult> runOnce(
    List<String> args, {
    Duration timeout = const Duration(minutes: 10),
    Map<String, String>? extraEnv,
    Future<void>? cancel,
  }) async {
    final process = await spawn(args, extraEnv: extraEnv);
    final stdout = StringBuffer();
    final stderr = StringBuffer();

    // ⚠️ 子进程输出**同时**喂给诊断日志（tee）。
    // 为什么不能另开一个 listen：Process 的 stdout 是单订阅流，第二个订阅会抛
    // "Stream has already been listened to"，而且那会改变原有的解析行为。
    // 所以就在同一个回调里顺手 tee 一份 —— 每行都过 DiagnosticsLog 的脱敏。
    final outTee = DiagnosticsLineTee('dsh-proc:out');
    final errTee = DiagnosticsLineTee('dsh-proc:err');
    DiagnosticsLog.add(
      'dsh-proc',
      '启动：${args.take(3).join(' ')}${args.length > 3 ? ' …（共 ${args.length} 个参数）' : ''}',
    );

    // 必须按 UTF-8 解码：直接 write(List<int>) 会把字节数组的 toString 写进去。
    final outDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
      stdout.write(chunk);
      outTee.feed(chunk);
    }).asFuture<void>();
    final errDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
      stderr.write(chunk);
      errTee.feed(chunk);
    }).asFuture<void>();

    // 取消：**不跟 exitCode 抢**（抢了就要自己处理两条流），只负责"到点就杀" ——
    // 杀完 exitCode 这个 future 自然完成，下面的等待逻辑一行都不用改。
    var cancelled = false;
    if (cancel != null) {
      unawaited(cancel.then((_) {
        cancelled = true;
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (e) {
          // 进程已经自己退出了 —— 这就是"取消晚了一步"，不算错误。
          debugPrint('[dsh-runtime] 取消时进程已结束：$e');
        }
        stderr.write('\n[已取消，进程已终止]');
        DiagnosticsLog.add('dsh-proc', '已取消，进程已终止（kill -9）');
      }));
    }

    int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      code = -1;
      stderr.write('\n[超时 ${timeout.inSeconds}s，已终止]');
      DiagnosticsLog.add('dsh-proc', '超时 ${timeout.inSeconds}s，已终止（kill -9）');
    }
    // 给管道 3 秒把尾巴排干净（正常几毫秒就 done；超时也不卡住调用方）。
    try {
      await Future.wait<void>(<Future<void>>[outDone, errDone])
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // 排空失败不影响返回值：已经读到的内容照样返回。
    }
    outTee.finish();
    errTee.finish();
    DiagnosticsLog.add(
      'dsh-proc',
      '结束：exit=$code，stdout=${stdout.length} 字符，stderr=${stderr.length} 字符',
    );

    return DshRunResult(
      exitCode: code,
      stdout: stdout.toString(),
      stderr: stderr.toString(),
      cancelled: cancelled,
    );
  }

  // -------------------------------------------------------------- 便捷入口

  /// `node --version`：最轻的自检（不需要模型凭据）。
  Future<DshRunResult> nodeVersion() => runOnce(['--version']);

  /// `dsh --version`：验证 CLI 能加载。
  Future<DshRunResult> version() => runOnce([dshBin, '--version']);

  /// 组合配置树：验证插件系统能加载（不调用模型、不需要凭据）。
  Future<DshRunResult> dumpDefaultConfig({String profile = 'headless'}) =>
      runOnce([dshBin, '--profile', profile, '--dump-default-config']);

  /// 跑一个 headless 任务（会真实调用模型，需要 [hasModelConfig] 与有效凭据）。
  ///
  /// [timeout] / [cancel] 直接透传给 [runOnce]（"从会话里提炼记忆"要用它们：
  /// 一次提炼等 150 秒就该停，用户点取消也该真的把进程杀掉）。
  /// 两个参数都可选，老的调用点（定时任务）行为**一字不变**。
  Future<DshRunResult> headless(
    String task, {
    Map<String, String>? extraEnv,
    Duration timeout = const Duration(minutes: 10),
    Future<void>? cancel,
  }) =>
      runOnce([
        dshBin,
        '--profile',
        'headless',
        if (hasModelConfig) ...['--patch', overlayPath],
        task,
      ], extraEnv: extraEnv, timeout: timeout, cancel: cancel);
}

/// 把 YAML 标量安全地写出来（名字里可能有中文、冒号、井号……）。
String _yamlStr(String raw) {
  final s = raw.replaceAll('\\', r'\\').replaceAll('"', r'\"');
  return '"$s"';
}
