/// 界面截图 —— 给公众号 / README 用的**真实 UI 渲染**，不靠真机。
///
/// 为什么需要它：本机没有 Android 设备，APK 装不上、截不了图。但 Flutter 能在
/// **真实渲染管线**里画出界面并导出 PNG —— 拿到的是 App 代码渲染出来的东西，
/// 不是另画一张示意图。
///
/// 用法：`flutter test test/screenshot_test.dart`
/// 产物：`/tmp/dsh-app/test/shots/*.png`（3 倍分辨率）
///
/// ⚠️ 四个必要条件：
///   1. **加载真实字体** —— 测试环境默认字体是 Ahem，所有字都是方块；
///      中日韩三语要各有着落，所以同时挂 `NotoSansCJK-Regular.ttc`（含 JP/KR
///      face）与 `NotoSansSC-VF.ttf`（简中兜底），同族多字体由引擎按序回退；
///   2. **把字体族塞进 ThemeData** —— App 自己的 TextStyle 大多没写 fontFamily，靠继承；
///   3. **喂一次皮肤** —— 配色是全局静态（`DshColors.applySkin`），main.dart 里会喂，
///      测试里必须自己喂，否则用默认皮肤；
///   4. **喂一次语言** —— `DshStrings.setCurrent` 管 data 层，`DshI18n` 管 UI 层，
///      两个都要给，否则切了语言截图里还是中文。
///
/// 为什么不用 `matchesGoldenFile`：它按**逻辑尺寸**出图（412×915），给公众号偏小。
/// 这里用 `RepaintBoundary.toImage(pixelRatio: 3)` 直接拿物理像素。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_mobile/i18n/app_language.dart';
import 'package:dsh_mobile/i18n/dsh_i18n.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/ui/pages/settings_tab.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 简中（含大部分日文汉字）。系统自带。
const String _fontSc = '/usr/share/fonts/truetype/notosc/NotoSansSC-VF.ttf';

/// CJK 合集（`fonts-noto-cjk` 装的）。日语假名 / 韩语谚文靠它。
/// 缺了就退回只有简中 —— 日韩截图会出现方块，所以下面会检查它存在。
const String _fontCjk =
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';

const String _fontFamily = 'DshCJK';
// 刻意放在 /tmp/dsh-shots（而不是 /tmp/dsh-app 里面）：构建前的 sync 会把
// /tmp/dsh-app 整个清空重建，图放在那儿会被删掉。
const String _outDir = '/tmp/dsh-shots';

/// 截图用的逻辑尺寸（真机常见：412×915 逻辑像素）。
const Size _logical = Size(412, 915);
const double _pixelRatio = 3.0;

/// 要截的那棵子树的 key（`RepaintBoundary` 必须包在它外面）。
const ValueKey<String> _shotKey = ValueKey<String>('shot');

Future<ByteData> _bytesOf(String path) async {
  final bytes = File(path).readAsBytesSync();
  return ByteData.view(bytes.buffer);
}

Future<void> _loadFonts() async {
  final loader = FontLoader(_fontFamily);
  // 顺序即优先级：合集在前（覆盖日韩），简中在后兜底。
  if (File(_fontCjk).existsSync()) {
    loader.addFont(_bytesOf(_fontCjk));
  } else {
    // ignore: avoid_print
    print('[shot] ⚠️ 缺少 $_fontCjk —— 日/韩截图会出现方块。'
        '装法：apt-get install -y fonts-noto-cjk');
  }
  loader.addFont(_bytesOf(_fontSc));
  await loader.load();
}

/// 造一个假的运行时路径表 —— `DshRuntime` 只要这个 Map 就能构造，
/// 所以不用真设备、也不用真目录。
DshRuntime _fakeRuntime() => DshRuntime(<String, dynamic>{
      'nodeBinary': '/data/app/lib/arm64-v8a/libnode.so',
      'nativeLibDir': '/data/app/lib/arm64-v8a',
      'filesDir': '/data/user/0/com.dshmobile.dsh_mobile/files',
      'dshBin': '/data/user/0/com.dshmobile.dsh_mobile/files/dsh/lib/bin.js',
      'nodeHome': '/data/user/0/com.dshmobile.dsh_mobile/files/dshhome',
      'fsShim':
          '/data/user/0/com.dshmobile.dsh_mobile/files/shims/android-fs-shim.cjs',
    });

void _mockNativeChannel() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(DshHost.channel, (MethodCall call) async {
    switch (call.method) {
      case 'permissionStatus':
        return <String, String>{
          'microphone': 'granted',
          'location': 'denied',
          'photos': 'permanently-denied',
          'notifications': 'granted',
        };
      case 'speechSupport':
        return <String, Object>{
          'sdkInt': 34,
          'recognitionAvailable': true,
          'onDeviceAvailable': true,
          'intentHandlers': 3,
          'language': 'zh-CN',
        };
      default:
        return null;
    }
  });
}

Widget _wrap(Widget child, AppLanguage lang) {
  final base = buildDshTheme();
  return DshI18n(
    language: lang,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _shotTheme(base, _fontFamily),      home: RepaintBoundary(
        key: _shotKey,
        child: Scaffold(
          // App 里底色由最底层 DshGridBackground 铺（见 main.dart），
          // 截图时手动铺一层，免得截成纯黑。
          backgroundColor: DshColors.bg,
          body: child,
        ),
      ),
    ),
  );
}

/// 把 `_shotKey` 那棵子树按 3 倍像素导出成 PNG。
Future<void> _save(WidgetTester tester, String name) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  final image = await boundary.toImage(pixelRatio: _pixelRatio);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory(_outDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File('$_outDir/$name');
  file.writeAsBytesSync(data!.buffer.asUint8List());
  final w = image.width;
  final h = image.height;
  // ⚠️ 必须显式释放这张图。不释放时测试**收尾**会挂住 —— 实测每个 testWidgets
  //    末尾空等 10 分钟才抛 TimeoutException，而 PNG 其实早就写完了
  //    （日志里 `[shot]` 已经打印）。看起来像"出图慢"，其实卡在测试结束。
  image.dispose();
  // ignore: avoid_print
  print('[shot] $name  ${w}x$h  '
      '${(file.lengthSync() / 1024).toStringAsFixed(0)}KB');
}

/// 造一个已切到 [lang] 的外观设置（`setLanguage` 会写盘，所以需要 mock 过的 prefs）。
Future<AppSettings> _settingsFor(AppLanguage lang) async {
  final s = AppSettings();
  await s.setLanguage(lang);
  return s;
}

/// 给截图用的主题**盖上字体族**（本机测试环境的默认字体是 Ahem —— 一个字一个方块）。
///
/// ## 为什么光改 textTheme 不够（2026-10-13 体检踩到，实测截图里标题/芯片是 `口口口`）
///
/// `ThemeData` 构建时，**各组件主题会从 textTheme 派生出自己的样式**（chip 的 labelStyle、
/// button 的 textStyle、appBar 的 titleTextStyle…）。之后再 `copyWith(textTheme: …)`
/// **追不回那些已经派生好的引用** —— 它们仍然指着"没有 fontFamily"的那份，
/// 于是用它们渲染的文字（AppBar 标题、ChoiceChip 标签、按钮文字…）回退到 Ahem。
/// 所以这里逐个盖一遍。**设备上没这个问题**（回退到系统字体），
/// 所以这纯粹是**截图底座**的活，不是 App 的问题。
ThemeData _shotTheme(ThemeData base, String family) {
  TextStyle? f(TextStyle? s) => s?.copyWith(fontFamily: family);
  return base.copyWith(
    // ⚠️ **还得盖 typography**（2026-10-13 诊断出来的最后一层）：
    //    App 的 textTheme **没有定义 labelLarge / labelMedium 这些**，
    //    运行时它们来自 `Typography`（字体族 null）—— 而 `TextTheme.apply`
    //    **盖不到 null 字段**（实测 `labelLarge.family` 一直是 null）。
    //    芯片标签、输入框提示走的正是这些 label* 样式，所以它们一直是方块。
    typography: Typography(
      englishLike: base.typography.englishLike.apply(fontFamily: family),
      dense: base.typography.dense.apply(fontFamily: family),
      tall: base.typography.tall.apply(fontFamily: family),
    ),
    textTheme: base.textTheme.apply(fontFamily: family),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: family),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: f(base.appBarTheme.titleTextStyle),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: f(base.chipTheme.labelStyle),
      secondaryLabelStyle: f(base.chipTheme.secondaryLabelStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          f(base.filledButtonTheme.style?.textStyle?.resolve(<WidgetState>{})),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          f(base.textButtonTheme.style?.textStyle?.resolve(<WidgetState>{})),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          f(base.outlinedButtonTheme.style?.textStyle?.resolve(<WidgetState>{})),
        ),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      hintStyle: f(base.inputDecorationTheme.hintStyle),
      labelStyle: f(base.inputDecorationTheme.labelStyle),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelStyle: f(base.tabBarTheme.labelStyle),
      unselectedLabelStyle: f(base.tabBarTheme.unselectedLabelStyle),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      contentTextStyle: f(base.snackBarTheme.contentTextStyle),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: f(base.dialogTheme.titleTextStyle),
      contentTextStyle: f(base.dialogTheme.contentTextStyle),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: f(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: f(base.listTileTheme.subtitleTextStyle),
    ),
  );
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    _mockNativeChannel();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DshColors.applySkin(DshPalettes.dark);
  });

  // ── 四语言的「设置 → 外观」：这一组图就是本次语言功能的自证 ──────────────
  //
  // ⚠️ 必须**每个语言一个 testWidgets**，不要合成一个再循环 pumpWidget。
  //    实测：同一个 testWidgets 里第二次 pumpWidget 换掉整棵 MaterialApp 会卡住
  //    （第二张图再也出不来，一路等到超时）；拆开写则 4 张都能正常出。
  for (final lang in AppLanguage.values) {
    testWidgets('shot-${lang.id} 设置页 · ${lang.nativeName}', (tester) async {
      tester.view.physicalSize = _logical * _pixelRatio;
      tester.view.devicePixelRatio = _pixelRatio;
      addTearDown(tester.view.reset);

      DshStrings.setCurrent(lang);
      final settings = await _settingsFor(lang);
      await tester.pumpWidget(_wrap(
        SettingsTab(
          runtime: _fakeRuntime(),
          appSettings: settings,
          onModelChanged: () async {},
        ),
        lang,
      ));
      // ⚠️ 刻意不用 `pumpAndSettle`：它要等"所有动画都结束"，而这棵树里有循环
      //    动画 / 未完成的 future，实测会一路等到 10 分钟超时抛 TimeoutException。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _save(tester, 'settings-${lang.id}.png');
      // 主动卸树，让各 State 的 dispose 跑完（否则收尾也会拖）。
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  // ── 原有三张（中文，公众号 / README 用）──────────────────────────────
  testWidgets('设置页 · 深色 · 六个下拉板块 + 关于', (tester) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);

    DshStrings.setCurrent(AppLanguage.zh);
    await tester.pumpWidget(_wrap(
      SettingsTab(
        runtime: _fakeRuntime(),
        appSettings: AppSettings(),
        onModelChanged: () async {},
      ),
      AppLanguage.zh,
    ));
    // ⚠️ 刻意不用 `pumpAndSettle`：它要等"所有动画都结束"，而这棵树里有循环动画 /
    //    未完成的 future，实测会一路等到 10 分钟超时才抛 TimeoutException ——
    //    表现就是"图不出、卡住"。固定推两帧就够，图里也不会有中间态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _save(tester, 'settings-dark.png');
  });

  testWidgets('设置页 · 展开「模型轮换池」', (tester) async {
    // 用**加长画布**把展开后的轮换池内容也带进同一张图。
    // 不用滚动：`dragUntilVisible` 在测试里既慢又容易卡住（实测卡死过一次）。
    tester.view.physicalSize =
        const Size(412 * _pixelRatio, 1400 * _pixelRatio);
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);

    DshStrings.setCurrent(AppLanguage.zh);
    await tester.pumpWidget(_wrap(
      SettingsTab(
        runtime: _fakeRuntime(),
        appSettings: AppSettings(),
        onModelChanged: () async {},
      ),
      AppLanguage.zh,
    ));
    // ⚠️ 刻意不用 `pumpAndSettle`：它要等"所有动画都结束"，而这棵树里有循环动画 /
    //    未完成的 future，实测会一路等到 10 分钟超时才抛 TimeoutException ——
    //    表现就是"图不出、卡住"。固定推两帧就够，图里也不会有中间态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('模型轮换池'));
    // ⚠️ 刻意不用 `pumpAndSettle`：它要等"所有动画都结束"，而这棵树里有循环动画 /
    //    未完成的 future，实测会一路等到 10 分钟超时才抛 TimeoutException ——
    //    表现就是"图不出、卡住"。固定推两帧就够，图里也不会有中间态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _save(tester, 'settings-pool-open.png');
  });

  testWidgets('设置页 · 浅色皮肤', (tester) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);

    DshColors.applySkin(DshPalettes.light);
    DshStrings.setCurrent(AppLanguage.zh);
    await tester.pumpWidget(_wrap(
      SettingsTab(
        runtime: _fakeRuntime(),
        appSettings: AppSettings(),
        onModelChanged: () async {},
      ),
      AppLanguage.zh,
    ));
    // ⚠️ 刻意不用 `pumpAndSettle`：它要等"所有动画都结束"，而这棵树里有循环动画 /
    //    未完成的 future，实测会一路等到 10 分钟超时才抛 TimeoutException ——
    //    表现就是"图不出、卡住"。固定推两帧就够，图里也不会有中间态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _save(tester, 'settings-light.png');
  });

  // ── 2026-11-13 换界面周期：两套新皮肤必须有自己的实物图 ──────────────
  //
  // 发布铁律要求"新版本要更新截图" —— 皮肤是本周期唯一的视觉交付物，
  // 只有 light/dark 两张旧图等于没交付。结构照抄上面的浅色用例（同一段
  // pump 节奏：固定两帧，**不能 pumpAndSettle**，理由见上面的注释）。
  testWidgets('设置页 · 泡泡白（新皮肤）', (tester) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);

    DshColors.applySkin(DshPalettes.lucianLight);
    DshStrings.setCurrent(AppLanguage.zh);
    await tester.pumpWidget(_wrap(
      SettingsTab(
        runtime: _fakeRuntime(),
        appSettings: AppSettings(),
        onModelChanged: () async {},
      ),
      AppLanguage.zh,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _save(tester, 'settings-lucian-light.png');
  });

  testWidgets('设置页 · 泡泡夜（新皮肤）', (tester) async {
    tester.view.physicalSize = _logical * _pixelRatio;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);

    DshColors.applySkin(DshPalettes.lucianDark);
    DshStrings.setCurrent(AppLanguage.zh);
    await tester.pumpWidget(_wrap(
      SettingsTab(
        runtime: _fakeRuntime(),
        appSettings: AppSettings(),
        onModelChanged: () async {},
      ),
      AppLanguage.zh,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _save(tester, 'settings-lucian-dark.png');
  });
}
