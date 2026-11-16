import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/state/app_settings.dart';
import 'package:dsh_mobile/ui/theme/dsh_tokens.dart';

/// 主题皮肤（浅色 / 深色）的单测。
///
/// 覆盖三件事：
///   1. 两套皮肤的令牌值（浅色**基本**逐条等于网站 `site.css` 的值，防漂移；
///      **有三个令牌是刻意偏离的** —— 见下面各自的注释，原因是 WCAG 对比度）；
///   2. 换肤通道：`DshColors.applySkin` + 重建后，界面颜色真的跟着变；
///   3. 「自定义」是占位 —— 它不是皮肤、不进 [AppSettings.skinId]、不落盘。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('皮肤令牌', () {
    test('浅色逐条对齐网站 site.css 的浅色令牌', () {
      final p = DshPalettes.light;
      // --bg / --bg-1
      expect(p.bg.toARGB32(), 0xFFEEF3FB);
      expect(p.bgSoft.toARGB32(), 0xFFE5ECF8);
      // --panel rgba(255,255,255,.72) / --panel-strong rgba(255,255,255,.94)
      expect(p.surface.toARGB32(), 0xB8FFFFFF);
      expect(p.surfaceHigh.toARGB32(), 0xF0FFFFFF);
      expect(p.surfaceStrong.toARGB32(), 0xFFFFFFFF);
      // --line rgba(32,74,150,.15) / --line-2 rgba(32,96,190,.32)
      expect(p.line.toARGB32(), 0x26204A96);
      expect(p.line2.toARGB32(), 0x522060BE);
      // --text / --muted / --dim
      expect(p.text.toARGB32(), 0xFF0C1A33);
      expect(p.textDim.toARGB32(), 0xFF566A8D);
      // ⚠️ **有意偏离 site.css 的三个令牌之一**（2026-10-09，审计 P1-7）：
      // site.css 的 --dim = #6E80A3，在浅底上只有 **3.57 / 3.35**（低于 WCAG AA
      // 的 4.5），而它在 lib 下有 215 处引用、大量是 10.5px 小字。
      // 按「同色相最浅的达标值」压到 #5C6B88 → 4.82 / 4.52。
      // **不是漂移，是刻意**：要让两边一致，应该去改网站那份 site.css。
      expect(p.textFaint.toARGB32(), 0xFF5C6B88);
      // --accent / --accent-2 / --accent-3
      // ⚠️ 同样有意偏离：site.css 的 --accent = #0891B2 在浅底上只有 3.30，
      // 而 accent 也用于小字与链接 → 压到 #06748E（4.84 / 4.54）。
      // 按钮填充上的白字对比度反而更好。
      expect(p.accent.toARGB32(), 0xFF06748E);
      expect(p.accent2.toARGB32(), 0xFF7C3AED);
      expect(p.accent3.toARGB32(), 0xFFDB2777);
      // --ok / --warn
      expect(p.ok.toARGB32(), 0xFF0F9D58);
      // ⚠️ 第三个有意偏离：site.css 的 --warn = #A16207 是 4.42（略低于 AA）
      // → #995D07（4.80 / 4.51）。
      expect(p.busy.toARGB32(), 0xFF995D07);
      // --code-bg / --code-text（浅色页里也用深蓝代码块）
      expect(p.codeBg.toARGB32(), 0xFF0F1729);
      expect(p.codeText.toARGB32(), 0xFFE8EEFC);
      // --glow-soft: 0 18px 44px -24px rgba(24,50,100,.30)
      expect(p.panelShadow.first.color.toARGB32(), 0x4D183264);
      expect(p.panelShadow.first.blurRadius, 44);
      expect(p.panelShadow.first.offset, const Offset(0, 18));
      expect(p.panelShadow.first.spreadRadius, -24);
      // --glow-accent: 0 10px 26px -14px rgba(8,145,178,.55)
      expect(p.accentShadow.first.color.toARGB32(), 0x8C0891B2);
      expect(p.accentShadow.first.blurRadius, 26);
    });

    test('深色底按深色指南提亮一档（原 #131719），强调色是同族的深色面', () {
      final p = DshPalettes.dark;
      // 2026-10-05：用户反馈「背景不要太黑」。深色设计指南的共识是
      // **用近黑而非纯黑、层次靠亮度差而非纹理**，故提亮到 #171C20 并新增柔光色。
      expect(p.bg.toARGB32(), 0xFF171C20);
      expect(p.brightness, Brightness.dark);
      // 柔光必须比底色**更亮**，否则背景层那层过渡等于没画
      expect(
        p.bgGlow.computeLuminance(),
        greaterThan(p.bg.computeLuminance()),
        reason: '柔光用来做"上亮下沉"的纵深，必须比底色亮',
      );
      // 青族：#0891b2 → #38e0f5（网站自己的深色代码块 --code-accent）
      expect(p.accent.toARGB32(), 0xFF38E0F5);
      // 紫族 / 粉族：同族提亮
      expect(p.accent2.toARGB32(), 0xFFA78BFA);
      expect(p.accent3.toARGB32(), 0xFFF472B6);
      // 面板是"更亮的半透明层"，不是把浅色的白面板搬过来
      expect(p.surface.a, lessThan(0.2));
      expect(p.isLight, isFalse);
      expect(DshPalettes.light.isLight, isTrue);
    });

    test('byId 认不出来就退回深色（旧的默认值）', () {
      expect(DshPalettes.byId('light').id, 'light');
      expect(DshPalettes.byId('dark').id, 'dark');
      expect(DshPalettes.byId('custom').id, 'dark');
      expect(DshPalettes.byId(null).id, 'dark');
      // 「自定义」不在真实皮肤列表里 —— 它不可能被选中。
      // 2026-10-12：新增第三套「像素」（用户要求）—— 顺序就是设置页里显示的顺序。
      // 2026-11-13：新增「泡泡白 / 泡泡夜」（Lucian 风格色板，只动 DshPalette）。
      expect(DshPalettes.all.map((p) => p.id).toList(),
          <String>['light', 'dark', 'pixel', 'lucian-light', 'lucian-dark']);
      expect(DshPalettes.byId('pixel').id, 'pixel');
      expect(DshPalettes.byId('lucian-light').id, 'lucian-light');
      expect(DshPalettes.byId('lucian-dark').id, 'lucian-dark');
      // 新皮肤各自必须是自己的亮度面（浅色面被判成深色会让整套明暗主题错乱）
      expect(DshPalettes.lucianLight.isLight, isTrue);
      expect(DshPalettes.lucianDark.isLight, isFalse);
    });

    test('玻璃拟态：只有泡泡白/泡泡夜两套打开，且三套形态互斥', () {
      // 用户 2026-11-13 选定「玻璃拟态」（原话只回了一个「3」）。
      // 这三套形态是**互斥的总闸**：像素走 pixelStyle，泡泡走 glassStyle，
      // 另外三套是常规。混着开会让 DshGlass / DshMotion 各自取到互相矛盾的档位。
      expect(DshPalettes.lucianLight.glassStyle, isTrue);
      expect(DshPalettes.lucianDark.glassStyle, isTrue);
      expect(DshPalettes.light.glassStyle, isFalse);
      expect(DshPalettes.dark.glassStyle, isFalse);
      expect(DshPalettes.pixel.glassStyle, isFalse);
      // 玻璃皮肤不能同时是像素皮肤
      for (final p in DshPalettes.all) {
        if (p.glassStyle) {
          expect(p.pixelStyle, isFalse,
              reason: '${p.id}：玻璃拟态和像素风不能同时开');
        }
      }
    });

    test('玻璃拟态的总闸跟着换肤走（页面不自己判皮肤 id）', () {
      DshColors.applySkin(DshPalettes.lucianLight);
      expect(DshMetrics.glassStyle, isTrue);
      DshColors.applySkin(DshPalettes.dark);
      expect(DshMetrics.glassStyle, isFalse);
      // 复原，别影响后面的用例
      DshColors.applySkin(DshPalettes.dark);
    });

    test('像素风：圆角缩放是 0（方角是像素风的一半识别度）', () {
      expect(DshPalettes.pixel.radiusScale, 0,
          reason: '像素风必须把圆角关掉，否则是"暖色深色皮肤"而不是像素风');
      // 浅色/深色不受影响（默认 1.0）
      expect(DshPalettes.light.radiusScale, 1.0);
      expect(DshPalettes.dark.radiusScale, 1.0);
      // 圆角换算要跟着皮肤走
      DshColors.applySkin(DshPalettes.dark);
      expect(DshMetrics.radius(10), 10);
      DshColors.applySkin(DshPalettes.pixel);
      expect(DshMetrics.radius(10), 0);
      expect(DshMetrics.radius(DshMetrics.controlRadius), 0);
      // 复原，别影响后面的用例
      DshColors.applySkin(DshPalettes.dark);
    });

    test('像素风是"换一整套视觉"，不是只换色（用户 2026-10-15 第 6 条）', () {
      // 总闸：只有像素皮肤打开它 —— 所有"要不一样"的地方都读这一个开关
      expect(DshPalettes.pixel.pixelStyle, isTrue);
      expect(DshPalettes.light.pixelStyle, isFalse);
      expect(DshPalettes.dark.pixelStyle, isFalse);

      DshColors.applySkin(DshPalettes.dark);
      expect(DshMetrics.pixelStyle, isFalse);
      expect(DshMetrics.fontFamily, isNull, reason: '普通皮肤用系统默认字体');
      expect(DshMetrics.borderWidth, 1);
      expect(DshMetrics.letterSpacing, 0);

      DshColors.applySkin(DshPalettes.pixel);
      expect(DshMetrics.pixelStyle, isTrue);
      expect(DshMetrics.fontFamily, 'monospace',
          reason: '字体是"大变样子"里最显眼的一条（界面字体风格要完全不同）');
      expect(DshMetrics.borderWidth, 2, reason: '1dp 细边在方角上几乎看不出来');
      expect(DshMetrics.letterSpacing, greaterThan(0));

      // 投影：像素皮肤是**无模糊的硬方块**，普通皮肤是柔和光晕
      for (final sh in DshPalettes.pixel.panelShadow) {
        expect(sh.blurRadius, 0, reason: '像素风不许有模糊光晕');
      }
      expect(DshPalettes.dark.panelShadow.first.blurRadius, greaterThan(0));

      // 主题里的字体族也要跟着走（不然只有"读 DshMetrics 的地方"变了）
      expect(buildDshTheme().textTheme.bodyMedium?.fontFamily, 'monospace');

      DshColors.applySkin(DshPalettes.dark);
      expect(buildDshTheme().textTheme.bodyMedium?.fontFamily, isNot('monospace'));
    });

    test('像素风也过无障碍对比度（contrast_test 会遍历所有皮肤）', () {
      final p = DshPalettes.pixel;
      expect(p.brightness, Brightness.dark);
      expect(p.text, isNot(equals(p.bg)));
      expect(p.accent, isNot(equals(p.bg)));
    });

    test('渐变是青→紫（两端就是 accent / accent-2）', () {
      for (final p in DshPalettes.all) {
        expect(p.grad.colors.first, p.accent);
        expect(p.grad.colors.last, p.accent2);
        expect(p.grad3.colors, <Color>[p.accent, p.accent2, p.accent3]);
      }
    });
  });

  group('换肤通道', () {
    tearDown(() => DshColors.applySkin(DshPalettes.dark));

    test('applySkin 之后所有 getter 都跟着走', () {
      DshColors.applySkin(DshPalettes.dark);
      expect(DshColors.textDim, DshPalettes.dark.textDim);
      expect(DshColors.isLight, isFalse);
      DshColors.applySkin(DshPalettes.light);
      expect(DshColors.textDim, DshPalettes.light.textDim);
      expect(DshColors.bg, DshPalettes.light.bg);
      expect(DshColors.isLight, isTrue);
      // 旧名字 divider 仍然等价于 line
      expect(DshColors.divider, DshPalettes.light.line);
    });

    test('主题跟着当前皮肤走（亮度/底色/圆角）', () {
      DshColors.applySkin(DshPalettes.light);
      var theme = buildDshTheme();
      expect(theme.brightness, Brightness.light);
      // 底色不再由 ThemeData 画：页面/AppBar 都是透明的，真正的底色 + 网格
      // 由最底层的 DshGridBackground 画（见 ui/theme/dsh_grid.dart）。
      expect(theme.scaffoldBackgroundColor, Colors.transparent);
      expect(theme.appBarTheme.backgroundColor, Colors.transparent);
      // 皮肤本身的底色没变，网格层用的是它
      expect(DshColors.bg, DshPalettes.light.bg);
      expect(theme.colorScheme.primary, DshPalettes.light.accent);

      DshColors.applySkin(DshPalettes.dark);
      theme = buildDshTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, Colors.transparent);
      expect(DshColors.bg, DshPalettes.dark.bg);
      expect(theme.colorScheme.primary, DshPalettes.dark.accent);
    });

    testWidgets('重建之后，界面上真的换成了新皮肤的颜色', (tester) async {
      final skin = ValueNotifier<DshPalette>(DshPalettes.dark);
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: skin,
          builder: (context, _) {
            // 与 main.dart 同一条链路：先喂皮肤，再建 MaterialApp
            DshColors.applySkin(skin.value);
            return MaterialApp(
              theme: buildDshTheme(),
              // ⚠️ 这里**不能**写 `const`：const 实例在换肤时会被 Flutter 原样复用
              // （updateChild 直接返回、跳过重建），探测到的颜色就不会变 ——
              // 这正是本次要把十几个 const 构造点去掉的原因。
              // ignore: prefer_const_constructors
              home: Scaffold(body: _Probe()),
            );
          },
        ),
      );
      expect(_probeColor(tester), DshPalettes.dark.textDim);

      skin.value = DshPalettes.light;
      await tester.pump();
      expect(_probeColor(tester), DshPalettes.light.textDim);
      expect(DshColors.textDim, DshPalettes.light.textDim);
    });
  });

  group('AppSettings 的主题选择', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('默认深色；未知 id 被忽略；真实 id 生效并落盘', () async {
      final s = AppSettings();
      await s.load();
      expect(s.skinId, AppSettings.kDefaultSkin);
      expect(s.skin.isLight, isFalse);

      // 「自定义」不是皮肤：切不动，也不写盘
      await s.setSkin('custom');
      expect(s.skinId, AppSettings.kDefaultSkin);
      expect(
          DshPalettes.all.any((p) => p.id == AppSettings.kDefaultSkin), isTrue);

      await s.setSkin('light');
      expect(s.skinId, 'light');
      expect(s.skin.isLight, isTrue);
      expect(s.themeMode, ThemeMode.light);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dsh_theme_skin'), 'light');
    });

    test('重启后保持（第二次 load 读回落盘值）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dsh_theme_skin': 'light',
      });
      final s = AppSettings();
      await s.load();
      expect(s.skinId, 'light');
      expect(s.skin.isLight, isTrue);
    });

    test('磁盘上是坏值就退回默认深色（不把主题留在空状态）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dsh_theme_skin': 'rainbow',
      });
      final s = AppSettings();
      await s.load();
      expect(s.skinId, AppSettings.kDefaultSkin);
    });

    test('「自定义」的说明如实说"还没做"，而不是谎称已支持', () {
      expect(AppSettings.customLabel, '自定义');
      expect(AppSettings.customPendingNote.contains('还没做'), isTrue);
      expect(AppSettings.customPendingNote.contains('不会切主题'), isTrue);
      // 占位说明里不许出现"即将上线"这种画饼
      expect(AppSettings.customPendingNote.contains('即将'), isFalse);
    });
  });

  group('皮肤一致性门禁：不许再写死圆角', () {
    /// 为什么要有这条（**真踩过**）：
    ///
    /// 像素风皮肤的 `radiusScale = 0`（全直角）。做那一版时把界面上写死的
    /// `BorderRadius.circular(N)` 逐处换成了 `DshMetrics.radius(N)`（119 处），
    /// **但漏了一整种写法**：底部弹层里的 `BorderRadius.vertical(top:
    /// Radius.circular(18))` —— 它不是 `BorderRadius.circular`，扫描时看不见。
    /// 后果是：切到像素风之后**主界面全是直角、所有底部弹层仍带 18px 圆角**，
    /// 一个皮肤里两种形态并存（6 处，2026-10-12 查出并已修）。
    ///
    /// 这类漏项不会让任何测试变红、也不会报错，只会"看起来怪"，所以必须由
    /// 一条**源码级门禁**挡住：`lib/` 里除了主题令牌文件，任何地方都不许再出现
    /// `Radius.circular(数字)`。
    ///
    /// ⚠️ 只拦**数字字面量**：`Radius.circular(DshMetrics.radius(8))` 与
    /// 命名常量（`Radius.circular(kX)`）都放行 —— 而且这段判正则不看行，
    /// 所以"换行写在下一行"（`BorderRadius.circular(\n  DshMetrics.radius(...))`）
    /// 不会被误报。
    test('lib/ 里除主题令牌外，不许出现 Radius.circular(数字)', () {
      final offenders = <String>[];
      final tokenFile = File('lib/ui/theme/dsh_tokens.dart');
      expect(tokenFile.existsSync(), isTrue, reason: '测试的工作目录应当是 app/');

      final hardcoded = RegExp(r'Radius\.circular\(\s*\d');
      for (final e in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()) {
        if (!e.path.endsWith('.dart')) continue;
        if (e.path.endsWith('lib/ui/theme/dsh_tokens.dart')) continue;
        final lines = e.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (hardcoded.hasMatch(lines[i])) {
            offenders.add('${e.path}:${i + 1}  ${lines[i].trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '这些地方写死了圆角 —— 像素风（radiusScale=0）下它们不会跟着变直角，'
              '会和其它所有控件不一致。请改成 `DshMetrics.radius(N)`：\n'
              '${offenders.join('\n')}');
    });

    test('三种皮肤下所有底部弹层的顶角都跟着皮肤走（像素风必须是直角）', () {
      // 直接把刚改过的那 6 处点名的形态钉一遍（防有人改回头）。
      final sheets = <String>[
        'lib/ui/widgets/enabled_experts_sheet.dart',
        'lib/ui/pages/expert_page.dart',
        'lib/ui/pages/scheduled_page.dart',
        'lib/ui/pages/model_sheet.dart',
        'lib/ui/pages/chat_page.dart',
      ];
      for (final f in sheets) {
        final src = File(f).readAsStringSync();
        expect(src, contains('Radius.circular(DshMetrics.radius(18))'),
            reason: '$f 的底部弹层顶角又写死回去了 —— 像素风下会是圆的');
      }
      // ⚠️ 这里**刻意不**去文本里找"const 有没有包着它"：那是**编译期**错误
      // （`const` 表达式里不能调用方法），`flutter analyze` 会直接拦下来 ——
      // 我第一版写了条 `contains('const BorderRadius.vertical(...)')` 的断言，
      // 而真实写法是 `shape: const RoundedRectangleBorder(` 把整句包住，
      // 那条断言**永远为真**（假绿）。所以这类"编译器能管的"就不在文本层重复管了。
    });
  });
}

/// 探针：读运行时皮肤的次要文字色（**刻意不用 const 构造** —— const 实例在
/// 换肤时会被 Flutter 原样复用、跳过重建，颜色就不会刷新）。
class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'probe',
        style: TextStyle(color: DshColors.textDim, fontSize: 14),
      ),
    );
  }
}

Color? _probeColor(WidgetTester tester) =>
    tester.widget<Text>(find.text('probe')).style?.color;
