/// 界面语言的回归测试。
///
/// 这里锁住三件容易**悄悄坏掉**的事：
///
///   1. **三张表的条目数必须一致** —— 少一条就是某个界面上那一句话退回中文，
///      而它不会报错、也不会崩，只有切到那个语言才看得见。
///   2. **占位符不能丢** —— `'{0} 个会话'` 的译文如果写成 `'会话'`，
///      数字就凭空消失了（编译通过、运行也不报错）。
///   3. **`const` widget 必须能被刷新** —— 这是整套方案的命门：
///      `const Text(context.tr('设置'))` 这种写法能编译，但如果没有
///      `DshI18n` 的依赖通知，父级重建时它会被原样复用、跳过 rebuild，
///      于是"切了语言界面不变"。下面第 5 组测试就是钉住这个行为。
library;

import 'package:dsh_mobile/i18n/app_language.dart';
import 'package:dsh_mobile/i18n/dsh_i18n.dart';
import 'package:dsh_mobile/i18n/tables/en_table.dart';
import 'package:dsh_mobile/i18n/tables/ja_table.dart';
import 'package:dsh_mobile/i18n/tables/ko_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个**刻意 const** 的探针：内部用 `context.tr` 取文案。
/// 如果 InheritedWidget 那条链路断了，它在语言切换后不会重新 build。
class _ConstProbe extends StatelessWidget {
  const _ConstProbe();

  @override
  Widget build(BuildContext context) => Text(context.tr('设置'));
}

void main() {
  group('三张表', () {
    test('条目数一致，且规模对得上（2051 条界面文案）', () {
      // 994 这个数不是随手写的：2026-10-09 按审计 P0-11/P1-5 清过一轮漂移
      // （补 48 条漏翻 / 删 77 条陈旧 / 修 17 条换行错，三张表各自）。
      // 清理的依据是 `install/i18n/check-tables.mjs` —— 那个脚本以前**不存在**，
      // 只在表头注释里被引用（这就是漂移能攒到 48/77 的原因）。
      // 以后改文案：先跑 check-tables，它会让你顺手把这里和表一起更新。
      // ⚠️ 2026-10-11 1143 → 1144：新增「无需 Key」（免费模型那一组的状态徽标）。
      // ⚠️ 2026-10-11 1144 → 1180：新增「修图」整页（36 条：档位/位置/强度/去水印说明…）。
      // ⚠️ 2026-10-11 1180 → 1212：新增「图像 / 视频模型」设置（32 条：模型行/添加表单/边界说明…）。
      // ⚠️ 2026-10-11 1212 → 1225：设置页「特殊权限」从"一排只有名字的按钮"改成
      //    列表（每项：用途 + 手动路径 + 去设置）；同时删掉两条被替换的旧失败文案。
      //    ⚠️ 这个数字是**读当前表实际长度**得出的。
      // ⚠️ 2026-10-11 1225 → 1227：补上 media_page「擦除」改名后的 3 条新文案 +
      //    ondevice_models_page 的「本地服务没起来：{0}」，同时删掉 2 条陈旧条目
      //    （用 install/i18n/rewrite-tables.mjs 写盘，check-tables 已复核 0 漂移）。
      // ⚠️ 2026-10-11 1227 → 1231：新增「图像 / 视频模型 → 添加模型」里的
      //    **内置外部厂商**预设（6 家一行 chip）+ 两条边界说明 + 一条 Key 提示。
      // ⚠️ 2026-10-11 1231 → 1251：**影视工具支持多个厂家**（用户纠正）——
      //    新增厂家参数矩阵的 12 条说明（`MediaVendors` 的 note）+「尺寸 / 分辨率」
      //    两个标签 +「已按这家支持的档位改成 {0}」+ 不支持时的两句如实说明 +
      //    settings_tab 里改成事实的 3 条（视频内置厂商 / 图像边界 / 边界总结）；
      //    同时删掉 4 条**已经不对**的旧话术（"图像请求按 Agnes 形状发"
      //    "视频暂时没有内置外部厂商"等）。净 +23 是本次的改动。
      //    另外 +1 是同事同时在改的 ondevice_models_page（llama.cpp 引擎那句）。
      //    两次都用 install/i18n/rewrite-tables.mjs 写盘，check-tables 复核 0 漂移。
      // ⚠️ 2026-10-11 1251 → 1258：补上**两条"永远翻不了"的路**（不是新增文案，
      //    是这些文案以前根本没进过表）：
      //    ① settings 里 6 家**图像预设的 note** 是数据表字面量、界面用
      //       `Text(presetNote)` 原文显示 → 切英/日/韩露中文。改成
      //       `context.tr(presetNote)` 并在 media_models.dart 加扫描器锚点（+6 条，
      //       其中万相/MiniMax 两条是新改的端点说明）；
      //    ② local_chat_page 里那句带参数的提示原来走 `_toast('中文', args)`，
      //       字面量不在 `tr(...)` 里 → 扫描器看不见 → 表里没有 → 静默不翻。
      //       改成 `_toastMsg(context.tr('…', args))`（+1 条）。
      //    这次的 7 条**不是新功能文案**，是"本来就该翻、但机制上永远翻不了"的补齐。
      // ⚠️ 2026-10-12 1258 → 1268：用户报的 4 条里两条带新文案 ——
      //    ① 图像/视频模型那一页**新增 Key 输入**（原来只有一句"去云端大模型那边配"，
      //       用户找不到地方填）：+8 条（标题、说明、按钮、两种状态、两个 toast、对话框）；
      //    ② 擦除改成**图上自由框选**：+3 条（直接选的说明、快捷起点、宽/高微调两根滑杆）；
      //    ③ 本地模型上下文那句重写（"已按它启动" → "上下文已收敛到 N 格"）：1 条换 1 条，
      //       净 0；④ 面板不透明化不涉及文案。
      //    另外 rewrite-tables 顺带删了 18 条陈旧键（其中含被上面 ③ 取代的那条）。
      //    老规矩：`rewrite-tables.mjs` 写盘 → `check-tables.mjs` 复核 0 漂移。
      // ⚠️ 2026-10-12 1268 → 1271：知识库切片修复带出 3 条 ——
      //    知识库页要如实标出"这个索引是旧切法建的"（+2：状态行 + 说明）
      //    与「重建（推荐）」按钮（+1）。
      // ⚠️ 2026-10-12 1271 → 1283 → 1325（同一轮里的两次 +）：
      //    · 1283：影视页「配音」改造 —— 加 MiniMax 这一家、音色下拉、
      //      语速档位/滑杆、拉取音色，以及全部失败文案（+12）；
      //    · 1325：搬入两个 Anthropic 开源技能时改写了
      //      「第三方组件与许可」那一整段（-1 旧 key / +1 新 key，同时补上
      //      前面配音那一批的 44 条译文）。老规矩：rewrite-tables 写盘 →
      //      check-tables 复核 0 漂移（三张表条数必须一致）。
      // ⚠️ 2026-10-12 1353 → 1367：工作台新增「创作 · 小说改游戏」入口（+14；许可段那次是"删旧加新"净 0）
      //    与它的说明页（这是什么 / 七个阶段 / 怎么开始 / 边界），共 +14 条。
      // ⚠️ 2026-10-12 1325 → 1334：设置 → 外观新增「思考过程」三档
      //    （折叠 / 展开 / 不显示）+ 该分区的说明与「已落盘」提示（+9）。
      // ⚠️ 2026-10-12 1387 → 1413：工作台新增「AI 角色（实验）」一格（+26）——
      //    标题、入口说明、三张开局牌的每一段（名字/情境/角色/场景/目标）、
      //    共用规则、开始按钮，以及四条"边界（如实说）"（+25）；
      //    首句骨架 `promptTemplate` 单独算一条（+1，带 {0}..{4} 五个占位符，
      //    让"【你演】/【场景】/【目标与结束条件】"这些小标题也跟语言走）。
      //    注意这些中文都写在 `const` 数据表里，扫描器看不见 —— 靠
      //    `ai_role_page.dart` 底部 `aiRoleI18nAnchors()` 里的字面量才被收进来
      //    （同理见 `media_models.dart` 的 `_presetNoteAnchors`）。
      // ⚠️ 2026-10-12 1413 → 1460：工作台新增「剪辑」一格（+47）——
      //    五个操作（剪一段/拼接/抽音频/抽一帧/压小）的名字与说明、参数区的每一句、
      //    资料库选片弹层、结果卡与四条"边界（如实说）"。
      //    同样：五个操作写在 `ClipPage.ops` 这个 `const` 表里，靠
      //    `clip_page.dart` 底部 `clipI18nAnchors()` 才收得到。
      // ⚠️ 2026-10-12 1460 → 1499：首页那 13 条内置起始语（+39 = 13 × 标题/副标题/首句）。
      //    这一批**不是靠锚点**收进来的，而是**修了扫描器本身**：
      //    `builtin_starters.dart` 原来在 `scan.mjs` 的 SKIP_FILES 里（旧理由
      //    "内置会话模板，点一下会发给电脑端"）——那条排除太宽：它连首页卡片的
      //    **标题/副标题**（纯手机端 UI 文字）一起跳过了，于是切英/日/韩时
      //    首页 13 张卡全是中文，而 check-tables 照样报 0 漂移。
      //    现在把它移出 SKIP_FILES，那 39 条中文自己就是 key（不再需要锚点函数）。
      // ⚠️ 2026-10-13 1559 → 1598：设置页新增「检查更新」整块（L1）——
      //    29 条界面文案（标题/说明/按钮/状态/更新源/开关/下载卡/失败细节）
      //    + 10 条来自 `local/update_checker.dart` 的解析与网络错误（这些直接写在
      //    `tr('…')` 里，所以**不需要锚点函数**就进了表）。
      //    老规矩：`rewrite-tables.mjs` 写盘 → `check-tables.mjs` 复核 0 漂移。
      // ⚠️ 2026-10-13 1598 → 1634：同一版接着做 L2（应用内下载 + 双校验 + 交给系统安装）——
      //    +39 条（下载进度/取消/重新下载、哈希与签名的每一条失败说明、安装权限引导、
      //    "最后那一下必须你亲手点"），同时**删掉 3 条陈旧**（L1 里那几句
      //    "去浏览器下载"，L2 已改成「下载到本机」，旧的没人用了）。
      //    其中 10 条来自 `local/apk_downloader.dart` 与 `local/apk_installer.dart`，
      //    都直接写在 `tr('…')` 里，所以不需要锚点函数。
      // ⚠️ 2026-10-13 1634 → 1636：下载器补了两道安全闸（文件名洗净 + 体积上限 2 GB），
      //    它们各自带一句会显示给用户的话（"大得不像话，停下了"），所以 +2。
      // ⚠️ 2026-10-14 1636 → 1646：L3 包瘦身（运行时不再随包，改为首次启动下载）——
      //    「准备运行环境」那一页多了一个下载阶段（+12），并删掉 2 条旧说明
      //    （原文写着"随包的运行环境"，已经不成立了）。
      // ⚠️ 2026-10-14 1646 → 1650：修掉"全新安装 + 无网就打不开"那个硬伤后，
      //    更新卡片要**提前说清这次下的是哪个包**（精简 / 完整），+4。
      // ⚠️ 2026-10-15 1654 → 1670：用户一次提了 8 条，其中 7 条落地（音乐播放器
      //    那条我判断不做，理由见 docs/CHANGES-2026-10-15.md §5）。新增文案 16 条：
      //    首页滚动公告栏（4：公告 / 公告：{0} / 上次同步 / 缓存说明 + 查看详情）、
      //    猫咪说话（7：语义标签 + 6 句）、二维码长按（4）、切模型提示（1）。
      //    另有 7 条 key 因「工作台 → 创作台」改名（数量不变）。
      // ⚠️ 2026-10-15 1670 → 1671：免费通道被上游第三次闸住，403 要**专翻一条**
      //    （原来会落到通用 403 文案"套餐不含 / Key 权限受限"，把用户导向错误的排查）。
      // ⚠️ 2026-10-15 1684 → 1705：新增「会话联网搜索」（AnySearch，用户选定 B 方案）
      //    的设置页板块与状态文案，+21 条。
      // ⚠️ 2026-10-15 1705 → 1713：新增「子智能体」板块（开关 + 子会话用哪个模型 + 两条
      //    如实说明），+8 条。
      // ⚠️ 2026-10-15 1713 → 1715：准备运行环境那一页改成分「随包自带 / 不随包」两套文案
      //    （用户真机反馈：完整包也被要求下 32 MB），+3 新 −1 旧 = +2。
      // ⚠️ 2026-10-15 1671 → 1684：兑现「不用填 Key」的承诺 —— 新增 Pollinations
      //    免 Key 通道（`data/polli_channel.dart`）的设置页板块与状态文案，+13 条；
      //    同时把 Zen 那一节改名为「免费模型 · OpenCode Zen（第三方通道）」并加交叉指引。
      // ⚠️ 2026-10-15 1650 → 1654：会话丢失修复单（A/B/C）——
      //    「还没开始对话，正在按新模型准备会话…」（切模型时还没有会话可切）、
      //    「这条没能发出去：会话没能建起来，可以再试一次。」（A 的兜底文案）、
      //    「没有回答」（回放里那条失败提示的标签）、
      //    「磁盘历史会话 {0} 条（其中 {1} 条是空会话，没列出来）」（A 的第二半），+4。
      // ⚠️ 2026-10-15 1715 → 1822（0.75 的六项修复一起加进来的 119 条 + 删掉 12 条陈旧）：
      //    · 设置页归纳成 4 组（模型 / AI 能力 / 外观与语言 / 应用）+ 检查更新并入「关于」
      //    · 记忆做成完整功能（分类 / 重要度 / 作用范围 / 导入导出 / **从会话自动提炼**）
      //    · 外观新增「壁纸」（选图 / 变暗 / 模糊）
      //    · 二维码长按改成三条真走得通的路（复制公众号 ID / 存相册 / 仍然试一次）
      //    · 会话历史并进消息流（不再只是只读回放框）
      // 口径：`install/i18n/{check,rewrite}-tables.mjs` 复核 **0 漂移**，
      //      译文写在 `install/i18n/translations-drift.json` 后由 rewrite 写盘。
      // ⚠️ 2026-10-16 1822 → 1821：去掉了「测试并保存」那条"只登记前 N 个"的说明
      //    （用户要求所有模型全部获取，截断逻辑与那句文案一起删了）。
      // ⚠️ 2026-10-16 1821 → 1827：「设计画布」（创作台入口）新增 6 条文案。
      // ⚠️ 2026-10-16 1827 → 1830：创作台入口屏分类，新增 3 条分组标题
      //    （生成图像与视频 / 口播与短剧 / 创作；「工具」原来就有）。
      // ⚠️ 2026-10-16 1830 → 1833：长会话助手的主动提示新增 3 条。
      // ⚠️ 2026-10-16 1833 → 1883：**「通道自检」整块原来一条都没进表**（它用裸中文字面量，
      //    不是 tr('...')）→ 外语界面下这一页全是中文。本轮把它的标题/结论/下一步
      //    全部改成 tr('...') 并翻译；同批还有 zen 免 Key 通道的新文案与地区封锁那条。
      //    另删 1 条陈旧（自检弹层的说明改写了："只做读探测"不再成立 —— 免 Key 那条
      //    要真发一句对话，否则只看清单会把"用不了"报成"好的"）。
      // ⚠️ 2026-10-19 1893 → 1896：OpenCode Go 卡片那三句（Key 提示 / 套餐说明 /
      //    端点与 *-free 的说明）在 2026-10-17 加进 model_providers.dart 时**只写了中文**，
      //    check-tables 一直在报「漏翻 3 条」。本轮补上 en/ja/ko。
      // ⚠️ 2026-10-17 1892 → 1893：新增「这个模型在你所在地区不可用」——
      //    实测 OpenCode 的 beam-free 会回 403 RegionError（not available in your country），
      //    原来被笼统翻成"没有访问该模型的权限"，把人往 Key/套餐方向带。
      // ⚠️ 2026-10-16 1883 → 1892：创作台补了「做 PPT / 幻灯片」入口（用户问
      //    「ppt 这个功能放哪了」）—— 入口标题/说明 + 弹层说明 + 4 个可点的例子。
      // ⚠️ 2026-10-19 1896 → 1900：准备页区分「首次使用」与「正在更新运行环境」
      //    （用户报「更新安装后变成重新安装了」—— 运行环境版本跨了，老用户也会走到那一页，
      //    原来标题写死「首次使用」，看着像被重装）。新增 4 条：标题 / 两句解释 / 按钮。
      // ⚠️ 2026-10-19 1900 → 1903：启动画面里「正在更新运行环境」三句（一次性升级用），
      //    因为改成"进门只看能不能用、换新在启动画面里静默做"。
      // ⚠️ 2026-10-20 1903 → 1908：0.78 首装引导（标题 + 三条要点 + 按钮）。
      // ⚠️ 2026-10-20 1911 → 1913：思考块结束后的**单行摘要**（CHG-03）——
      //    「思考了 {0} 秒」/「思考了 {0} 分 {1} 秒」两条。
      //    老规矩：rewrite-tables.mjs 写盘 → check-tables.mjs 复核 0 漂移。
      // ⚠️ 2026-10-20 1913 → 1914：审批弹层那句「没能取到这一步的详情…」
      //    —— 它**此前根本不在表里**（三张表都查不到），所以切英/日/韩时
      //    那一段警示一直是中文；CHG-04 重构时被扫描器认出，本轮补上译文。
      // ⚠️ 2026-10-20 1914 → 1922：系统日历同步（CHG-05）的 8 条 ——
      //    「日历」「同步到系统日历」「申请日历权限」+ 4 条状态说明 + 1 条带占位符的。
      // ⚠️ 2026-10-21 1922 → 1923：差分更新两处文案（「增量 {0}」「正在把补丁拼成…」）。
      // ⚠️ 2026-10-24 1923 → 1933：屏幕助手（phone-agent）设置页 10 条文案。
      // ⚠️ 2026-10-24 1933 → 1967：「后台操作台」页（虚拟屏 + 实时画面 + 应用列表）34 条。
      // ⚠️ 2026-10-24 1967 → 1973：「免装 Shizuku（无线调试配对）」7 条，删 1 条陈旧。
      expect(kEnTable.length, 2051);
      expect(kJaTable.length, kEnTable.length);
      expect(kKoTable.length, kEnTable.length);
    });

    test('没有任何译文是空的（空串会让界面上出现一片空白）', () {
      final bad = <String>[];
      for (final table in <Map<String, String>>[kEnTable, kJaTable, kKoTable]) {
        table.forEach((k, v) {
          if (v.trim().isEmpty) bad.add(k);
        });
      }
      expect(bad, isEmpty, reason: '这些 key 的译文是空的：$bad');
    });

    test('中文即原文：中文语言下任何 key 都原样返回', () {
      for (final k in kEnTable.keys) {
        expect(DshStrings.translate(AppLanguage.zh, k), k);
      }
    });

    test('占位符不丢：key 里出现的 {n} 必须在译文里也出现', () {
      final problems = <String>[];
      final re = RegExp(r'\{\d+\}');
      for (final entry in <String, Map<String, String>>{
        'en': kEnTable,
        'ja': kJaTable,
        'ko': kKoTable,
      }.entries) {
        entry.value.forEach((k, v) {
          for (final m in re.allMatches(k)) {
            final p = m.group(0)!;
            if (!v.contains(p)) {
              problems.add('[${entry.key}] 「$k」→「$v」丢了 $p');
            }
          }
        });
      }
      expect(problems, isEmpty, reason: problems.take(10).join('\n'));
    });

    test('抽样：常用界面词确实翻成了目标语言', () {
      expect(kEnTable['设置'], 'Settings');
      expect(kJaTable['设置'], '設定');
      expect(kKoTable['설정'] ?? kKoTable['设置'], isNotNull);
      for (final t in <String>[
        kEnTable['外观']!,
        kJaTable['外观']!,
        kKoTable['外观']!
      ]) {
        expect(t, isNotEmpty);
      }
    });
  });

  group('语言解析', () {
    test('落盘值不认识时兜底到中文（绝不留在空状态）', () {
      expect(AppLanguage.byId(null), AppLanguage.zh);
      expect(AppLanguage.byId('nope'), AppLanguage.zh);
      expect(AppLanguage.byId('ja'), AppLanguage.ja);
      expect(AppLanguage.byId('ko'), AppLanguage.ko);
    });

    test('四种语言的 id 唯一且不可为空', () {
      final ids = AppLanguage.values.map((l) => l.id).toSet();
      expect(ids.length, AppLanguage.values.length);
      expect(ids.every((i) => i.isNotEmpty), isTrue);
    });
  });

  group('切语言能刷新界面（核心机制）', () {
    testWidgets('const 子树在 DshI18n 换语言时也会重建', (tester) async {
      // 中文
      await tester.pumpWidget(
        const DshI18n(
          language: AppLanguage.zh,
          child: MaterialApp(home: _ConstProbe()),
        ),
      );
      expect(find.text('设置'), findsOneWidget);

      // 同一个 const 实例，只换语言 —— 必须变成英文
      await tester.pumpWidget(
        const DshI18n(
          language: AppLanguage.en,
          child: MaterialApp(home: _ConstProbe()),
        ),
      );
      await tester.pump();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('设置'), findsNothing);
    });

    testWidgets('中文界面里查表不会把中文换成别的', (tester) async {
      await tester.pumpWidget(
        const DshI18n(
          language: AppLanguage.zh,
          child: MaterialApp(home: _ConstProbe()),
        ),
      );
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });
  });
}
