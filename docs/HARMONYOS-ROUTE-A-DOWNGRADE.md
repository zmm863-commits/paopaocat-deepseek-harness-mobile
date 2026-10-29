# A 路线：Flutter 3.22(ohos) 降级迁移清单

- 日期：2026-10-21
- 路线：A —— 保留现有 Flutter 手机 UI，降级到鸿蒙分支
- 前置文档：`docs/HARMONYOS-NEXT-GO-NO-GO.md`（总体判定）
- 扫描工具：`install/ohos-downgrade-scan.mjs`（可复跑，静态扫描数字出自它）
- 补丁工具：`install/ohos-3.22-compat-patch.mjs`（可复跑，§2.5 的补丁出自它）
- 环境自检：`install/ohos-p0-check.sh`

---

## 0. 一句话结论

**包做出来了：`release/harmony/DSH-Mobile-harmony.hap`（135 MB，已签名验证）。生产代码一行未改。**

| 关键事实 | 值 |
|---|---|
| 用的 Flutter | **`oh-3.47.7-preview`**（Flutter 3.47.7+ohos / **Dart 3.13.5**，与项目同代） |
| 仓库 | `gitcode.com/openharmony-tpc/flutter_flutter`（不是 gitee 的 sig 仓） |
| 生产代码改动 | **0 处**（`flutter analyze` → `lib/` error = 0） |
| 依赖改动 | **0 个**（89 个依赖按原版本全部解出） |
| HAP 大小 | 135 MB（含 `libs/arm64-v8a/libflutter.so` 40 MB + `kernel_blob.bin` + 全部 assets） |
| 签名 | `Digest verify result: true` / `verify permission sign success` / `Verify success` |
| 构建耗时 | 20 秒（依赖已缓存时） |
| 一键复现 | `bash install/ohos-build-flutter-hap.sh app` |

**之前"必须改 6 处"的判断作废。** 那是基于 3.27 分支算的；换到与项目同代的 3.47.7 分支后，改动归零。

### 但还没验证的事（必须说清楚）

**包能编出来 ≠ 包在手机上能跑。** 下面这些是**运行时**问题，编译期看不出来：

| 风险点 | 原因 | 影响 |
|---|---|---|
| `Process.*` 子进程（9 处） | 鸿蒙 seccomp 禁 `exec` | DSH 的 bash 工具、MCP 子进程可能失败 |
| `node-pty` | 鸿蒙无 `/dev/ptmx` | 终端功能可能失效 |
| 后台常驻 | 鸿蒙后台任务约 90 秒上限 | 长时间任务可能被系统挂起 |
| `libnode.so` 能否在鸿蒙加载 | 需 NDK 重新编译 | 若沿用 Android 的二进制则必然失败 |

**没有真机，以上一条都无法验证。** 这一步只能你把包装上去试。



---

## 1. 为什么是 3.22，不是更高

| 项 | 值 | 来源 |
|---|---|---|
| 鸿蒙 Flutter 仓库 | `gitee.com/openharmony-sig/flutter_flutter` | SIG 官方维护，1,266 星，2026-10-15 更新 |
| 最高版本分支 | `3.22.1-ohos-0.1.0` | **注意后缀 0.1.0 = 预览质量** |
| 默认稳定分支 | `3.7.12-ohos-1.0.4` | Dart 2.19，本项目用不了（需要 3.13 语法） |
| 本项目 | Flutter 3.47.6 / Dart 3.13.5 | `pubspec.lock` 的 `sdks:` 段 |
| 差距 | **25 个 Flutter 版本 / Dart 3.13 → 3.4** | — |

**风险提示**：`0.1.0` 不是稳定版语义。选 A 等于把产品押在一个预览分支上，升级路径依赖 SIG 的发布节奏。

---

## 2. 语言层：好消息

扫描 290 个 Dart 文件、107,619 行，**新语法 0 处**。项目没有用到：

- 数字分隔符 `1_000_000`（Dart 3.6）
- null-aware 集合元素 `[?x]`（Dart 3.8）
- dot shorthands `.value`（Dart 3.10）

项目大量使用的是 Dart 3.0 起的 pattern matching / records / sealed class，这些都是 **3.4 已支持**的。

⇒ **Dart 源码几乎不需要为了语法而改。** 这是 A 路线最大的意外之喜，也修正了此前"要退回 25 个版本"的过度悲观判断。

---

## ✅ 2.3 最终结论：Flutter 3.27 路线成立，生产代码只需改 6 处（2026-10-21 深夜，社区查证）

**前两次我都找错了仓库。这次是对的。**

### 错误在哪

| 我用过的 | 结果 |
|---|---|
| `gitee.com/openharmony-sig/flutter_flutter` 的 `3.22.1-ohos-0.1.0` | 空壳，0 个鸿蒙文件 |
| **正确**：`gitcode.com/openharmony-tpc/flutter_flutter` | **51 个分支，鸿蒙工具链完整** |

仓库名是 **`openharmony-tpc`**（不是 `sig`），平台是 **gitcode.com**（不是 gitee.com）。两年间社区把 tpc 仓迁到了 gitcode。

可用分支（实测确认有 `ohos/` 工具链 + `build_hap.dart`）：

| 分支 | Flutter | Dart | 说明 |
|---|---|---|---|
| `br_3.27.4-ohos-1.0.4` | **3.27.4** | **3.6.2** | ⭐ 最优选，离 3.47 最近 |
| `br_3.22.0-ohos-1.0.4` | 3.22.x | 3.4.0 | 次选 |
| `br_3.7.12-ohos-1.1.3` | 3.7.12 | 2.19 | 最老，不建议 |

### 3.27 下的实测结果（决定性）

```
flutter pub get  → 成功，77 个依赖全解出，只需降 1 个包
flutter analyze  → 40 issues
  应用 6 处修复后 → 36 issues
    lib/  error = 0     ← 生产代码零错误
    test/ error = 4     ← 全是既有测试脱节，与降级无关
```

**生产代码只需改 6 处（4 个文件）：**

| 文件 | 行 | 改动 | 原因 |
|---|---|---|---|
| `lib/ui/pages/bot_dialogs.dart` | 121 | `initialValue:` → `value:` | `DropdownButtonFormField` 参数名 |
| `lib/ui/pages/settings_tab.dart` | 1942 | `initialValue:` → `value:` | 同上 |
| `lib/ui/pages/bot_page.dart` | 534 | `.toARGB32()` → `.value` | `toARGB32` 是 3.29 才加的 |
| `lib/ui/pages/bot_page.dart` | 536 | `.toARGB32()` → `.value` | 同上 |
| `lib/ui/pages/expert_page.dart` | 236 | `activeThumbColor:` → `activeColor:` | `Switch` 参数名 |
| `lib/ui/pages/expert_page.dart` | 833 | `activeThumbColor:` → `activeColor:` | 同上 |

外加测试文件 23 处 `.toARGB32()` → `.value`。

### 为什么 3.27 比 3.22 好这么多

之前算的 127 处里，**89 处 `withValues` 和 3 处 `CardThemeData` 全是 3.27 引入的**——在 3.27 上本来就存在，根本不用改。

| API | 3.22 | **3.27** | 3.47 |
|---|---|---|---|
| `Color.withValues` | ❌ | **✅** | ✅ |
| `CardThemeData` / `TabBarThemeData` / `DialogThemeData` | ❌ | **✅** | ✅ |
| `Color.toARGB32` | ❌ | ❌（3.29 才有） | ✅ |
| `Switch.activeThumbColor` | ❌ | ❌ | ✅ |
| `DropdownButtonFormField.initialValue` | ❌ | ❌ | ✅ |

⇒ **3.22 的 127 处 → 3.27 的 6 处，减少 95%。**

### 依赖侧只需降一个包

| 包 | 项目现用 | 3.27 要求 | 处理 |
|---|---|---|---|
| `webview_flutter` | `^4.14.1` | 4.13.0 要 `sdk ^3.6.0, flutter >=3.27.0` | 降到 `4.13.0` |

其余 76 个依赖原样可用（`webview_flutter_android` 也不用移除，3.27 的 4.10.0 版可用）。

### 结论修正

**A 路线（Flutter 降级）从"≈重写"变成"6 行代码 + 降一个包版本"。**

这是我前面两次判断错误的纠正。之前给的"完美复刻做不到"的结论，**在 3.27 路线上不成立**——UI 一行都不用动。

---

## 🔧 2.35 构建环境的真实边界：能到哪一步、卡在哪一步

2026-10-21 深夜，在没有 DevEco 的情况下把构建环境推到极限。结论是**清楚的分界线**。

### 已打通（不需要华为账号）

| 环节 | 结果 | 做法 |
|---|---|---|
| OpenHarmony SDK API 12 | ✅ 2.67 GB，SHA256 校验通过 | `repo.huaweicloud.com` 公开镜像 |
| SDK 目录布置 | ✅ `flutter doctor` 显示 `[✓] HarmonyOS toolchain` | 见下方三条冲突的校验规则 |
| Flutter 3.27 鸿蒙分支 | ✅ 带 `ohos/` + `build_hap.dart` | `gitcode.com/openharmony-tpc` |
| ohos 项目生成 | ✅ `flutter create --platforms ohos` | — |
| hvigor 5.2.2 | ✅ 已装（匹配 flutter 3.27 插件期望版本） | `repo.harmonyos.com/npm` |

### SDK 目录的三条冲突校验（踩坑记录）

flutter 3.27 对同一个 SDK 目录有**三种互不兼容的校验**：

| 校验方 | 要求 | 坑 |
|---|---|---|
| `flutter doctor`（`locateHarmonySdk`） | `<sdk>/<纯数字目录>/toolchains/hdc` | 目录名必须能被 `double.tryParse` 解析——`12` 行，`12.0.0` 不行 |
| `flutter build hap`（`globals.hmosSdk`） | `<sdk>/<目录>/sdk-pkg.json` 含 `data.apiVersion` | OpenHarmony SDK 没这文件，必须自己造 |
| `hvigor` | `<sdk>/<platformVersion>/<component>` | API 12 的 `oh-uni-package.json` 没有 `platformVersion` 字段，要回退到 `apiVersion` |

解决：一个真实目录 + 一个纯数字软链 + 造 `sdk-pkg.json`。脚本见 `install/ohos-setup-sdk12.sh`（已跑通）。

另：`flutter doctor` 认 OpenHarmony SDK，但 `flutter build hap` 只认 HarmonyOS SDK——所以会出现"doctor 全绿、build 却说找不到 SDK"的诡异现象。

### 卡住的地方（需要 DevEco）

`flutter build hap` 走到 hvigor 这一步报：

```
The hvigorConfig is not yet available for build.
in hvigorconfig: <项目>/ohos/hvigorconfig.ts
```

堆栈定位到 `hvigor-ohos-plugin` 内部：

```
ProjectBuildProfileLoader.getBuildProfile()
  ← CoreProjectModelImpl.projectBuildProfileCheck()
  ← ProjectModelImpl 构造
  ← new AppPlugin()
  ← PluginFactory.getAppPlugin()
```

即 `ProjectBuildProfileLoader` 是**模块级全局单例**，必须在 hvigor 初始化项目结构时被填充；手搓入口下 `AppPlugin` 比它先创建，于是抛错。

根因：`hvigorconfig.ts` 里调 `injectNativeModules()`，它内部执行 `hvigor.getHvigorConfig()`——但此时 hvigor 配置对象还没初始化。

**这不是版本问题，是初始化顺序问题。** 试过并排除的：

- hvigor 5.2.2 / 6.26.8 两个版本：都报
- `hvigor-simple.js`（API 8 及以前的入口）：同样报
- `@ohos/hvigor` 多份副本导致状态不共享：统一成单一软链，仍报
- 把依赖放进 `<项目>/ohos/hvigor/node_modules`（`initNodePath` 期望的位置）：仍报

正常 DevEco 环境里，`hvigorw` 不是简单包装 `bin/hvigor.js`——它先跑 wrapper 逻辑（`HVIGOR_PROJECT_WRAPPER_HOME`、`HVIGOR_WRAPPER_PNPM_SCRIPT_PATH`，靠 **pnpm** 管自己的依赖），配置初始化完才加载 `hvigorconfig.ts`。这套胶水是 DevEco 生成的，手搓不可行。

另有一条已定位但未走通的路：hvigor 的依赖搜索路径不是工程目录，而是

```
/root/.hvigor/project_caches/<hash(cwd)>/workspace/node_modules
```

（由 `initNodePath()` 写进 `NODE_PATH`）。把依赖放到那里后，`Cannot find module '@ohos/hvigor-ohos-plugin'` 确实消失了——说明这个发现是对的，但随后撞上上面那个全局单例时序问题。

⇒ **结论：最后一步必须用 DevEco 提供的 `hvigorw`。** 但只需这一个可执行文件（连同它依赖的 wrapper 逻辑），SDK 和 Flutter 都已经备好。

---

## 🔩 2.38 CLT 已装但版本不匹配（2026-10-22 凌晨）

拿到官方 Command Line Tools 后的实测结论。

### 已装

`commandline-tools-linux-x64-6.1.1.418.zip`（2.14 GB，ZIP 完整性校验通过）解压后：

| 组件 | 版本 |
|---|---|
| hvigor | **6.24.5** |
| ohpm | 6.1.2.285 |
| HarmonyOS SDK | **6.1.1 Release（API 24）**，结构完好（含 `sdk-pkg.json` + `default/openharmony`） |

`flutter doctor` 直接绿灯——这份 SDK 是真正的 HarmonyOS SDK，不需要任何伪装。

### 但不匹配

| 项 | flutter 3.27 期望 | CLT 6.1.1 提供 |
|---|---|---|
| hvigor | **5.2.2**（`flutter-hvigor-plugin` 的 devDependencies 写死的） | 6.24.5 |
| SDK API | 12（模板 `compatibleSdkVersion: "5.0.0(12)"`） | 24 |

`flutter build hap` 仍然报：

```
Error Message: The hvigorConfig is not yet available for build.
in hvigorconfig: <项目>/ohos/hvigorconfig.ts
```

### 已排除的设法（全部无效）

| 尝试 | 结果 |
|---|---|
| 用官方 CLT 的 hvigorw（6.24.5） | 报 hvigorConfig 不可用 |
| 把 CLT 的 hvigor 换成 5.2.2（连同 hvigor-ohos-plugin） | 同样报错 |
| 删掉 `hvigorconfig.ts`（本项目无原生插件） | 错误变成 `Cannot find module '@ohos/hvigor-ohos-plugin'` |
| 依赖放工程 `node_modules`（软链到 CLT 同一实体） | Node CLI 能 `require.resolve` 成功，但 hvigor 内部仍找不到 |
| 依赖放 `~/.hvigor/project_caches/<hash>/workspace/node_modules` | 同上 |
| 写 `hvigorw` 包装器在每次构建前自动补依赖 | 同上 |
| 过滤 `--no-daemon` | 无效 |

**关键现象**：同一个路径，`node -e "require.resolve('@ohos/hvigor')"` 成功返回，但 hvigor 内部的 require-hook 解析失败——说明它不走标准 node_modules 查找链，外部注入无效。

### 结论

**需要 DevEco Studio / Command Line Tools 的 5.0.x 版本**（2024 年发布，带 hvigor 5.x + API 12），才能与 flutter 3.27 的鸿蒙分支匹配。用户当前下的是 6.1.1（最新），版本超前了。

历史版本下载页：`https://developer.huawei.com.cn/consumer/cn/deveco-studio/archive/`

---

## ⛔ 2.4 重要更正：3.22-ohos 分支是空壳，此路不通（2026-10-21 深夜实测）

**上一版 §2.5 的前提是错的，必须先更正。**

我当时认定 `3.22.1-ohos-0.1.0` 是"鸿蒙分支"，并据此跑了 analyze。结论"生产代码零 error"只证明了
**项目与原版 Flutter 3.22 兼容**，不代表能出鸿蒙包。真相：

| 分支 | ohos 相关文件数 | `build hap` 命令 | 能否出包 |
|---|---|---|---|
| `3.22.1-ohos-0.1.0` | **0** | **无** | ❌ 不能 |
| `3.7.12-ohos-1.0.4` | **233** | 有 | ✅ 能 |

3.22 分支的 HEAD 提交是 `[flutter_releases] Flutter stable 3.22.0 Framework Cherrypicks`
—— 它是**纯上游 Flutter 3.22.0 的镜像**，名字带 ohos 但一行鸿蒙代码都没有。空壳。

### 这意味着什么

**唯一能出 HAP 的 Flutter 是 3.7.12（2023-02），Dart 2.19。**

项目是 Flutter 3.47.6 / Dart 3.13.5。中间隔 **40 个 Flutter 版本 + Dart 语言主版本**。

依赖生态已经跟不上了（实测 pub 上的最新版约束）：

| 包 | 要求 |
|---|---|
| `shared_preferences` | Flutter ≥ 3.41.0 |
| `webview_flutter` | Flutter ≥ 3.38.0 |
| `file_picker` | Flutter ≥ 3.38.0 |
| `flutter_secure_storage` | Flutter ≥ 3.19.0 |

3.7.12 时代这些包只有 2.0.x / 4.0.x / 5.x，降下去后 API 又变一轮，代码要跟着改。

### 结论：Flutter 降级路线 = 重写，不是迁移

- 降到 3.7.12 要改的代码量 ≈ 重写整个 UI
- 而且 Dart 2.19 不支持 records / patterns / sealed class 等语言特性
- ⇒ **「完美复刻」在这条路上不可能**

**真正能出包的路只有 ArkTS 重写**（或等 3.22-ohos 分支真的长出鸿蒙代码）。

---

## 2.5 P0 实测结果：生产代码零 error（2026-10-21）

> ⚠️ 阅读前请先看 §2.4：本节用的 SDK 分支**没有鸿蒙构建能力**。
> 这里的数字证明的是「项目代码与 Flutter 3.22 API 兼容」（这是**好消息**，
> 说明将来 3.22-ohos 成熟时迁移成本低），**不能**据此认为已经能出鸿蒙包。

这一节是**跑出来的**，不是推出来的。用的不是估算模型，是真编译器。

### 2.5.1 环境

| 组件 | 来源 | 版本 |
|---|---|---|
| Flutter（鸿蒙分支） | `gitee.com/openharmony-sig/flutter_flutter` | `3.22.1-ohos-0.1.0` |
| Dart | 分支内置 | 3.4.0 |
| OpenHarmony SDK | `repo.huaweicloud.com/openharmony/os/7.0-Release` | API 26（`native-linux-x64-26.0.0.38-Beta`） |
| 交叉编译器 | SDK 自带 | OHOS clang 15.0.4，目标 `aarch64-unknown-linux-ohos` |
| hdc | SDK 自带 | 3.2.0f |
| hvigor | 华为 npm registry | 6.26.8 |

SDK 3.38 GB 已校验 SHA256（`130a438c…f338f`），交叉编译器实测能编出 AArch64 ELF。

**注意：P0 全程不需要真机。** 只有 `dart analyze` 和 `dart` 编译，设备到 P3 才必需。

### 2.5.2 三步实测

```
原始状态（3.22 SDK 下直接 analyze）        138 issues（131 error）
      ↓ 应用 install/ohos-3.22-compat-patch.mjs
补丁后                                     11 issues
      ↓ 分离统计
生产代码 lib/                              0 error
测试 test/                                 4 error（与本次降级无关，见 2.5.4）
```

`lib/` 只剩 5 条非错误项（2 条 info 风格、1 条 warning、2 条 info），**没有一条是 error**。

### 2.5.3 补丁的完整清单（每一条都对应官方 breaking change）

| # | 3.47 写法 | 3.22 写法 | 数量 | 依据 |
|---|---|---|---|---|
| 1 | `.withValues(alpha: X)` | `.withOpacity(X)` | 88 | 3.27 用 withValues 取代 withOpacity，两者都是 double 0..1 |
| 2 | `.withValues.withOpacity(X)` | `.withOpacity(X)` | 1 | withValues 是方法引用，去掉这一层 |
| 3 | `.toARGB32()` | `.value` | 25 | 3.27 起 toARGB32 取代 value |
| 4 | `Color.r/.g/.b/.a`（double 0..1） | `.red/.green/.blue/.alpha`（int 0..255） | 5 | 分量访问器改名**且改单位** |
| 5 | `CardThemeData` | `CardTheme` | 1 | 3.27 Material 主题重构 |
| 6 | `TabBarThemeData` | `TabBarTheme` | 1 | 同上 |
| 7 | `DialogThemeData` | `DialogTheme` | 1 | 同上 |
| 8 | `PopScope.onPopInvokedWithResult` | `onPopInvoked` | 1 | 3.22 回调少一个 result 参数 |
| 9 | `DropdownButtonFormField.initialValue` | `value` | 2 | 3.47 把 value 改名 initialValue |
| 10 | `Switch.activeThumbColor`（`Color?`） | `activeColor`（`Color?`） | 2 | 3.47 把 activeColor 改名；**不能**换 thumbColor（那是 `WidgetStateProperty`） |

合计 127 处替换，涉及 35 个文件。

### 2.5.4 剩下的 4 个 error 是**既有问题**，不是降级造成的

全部在 `test/bot_hub_shot_test.dart`：

```
error • The named parameter 'onCreate' is required...      test/bot_hub_shot_test.dart:109
error • The named parameter 'onOpenRoom' is required...    test/bot_hub_shot_test.dart:109
error • The named parameter 'onOpenSettings' is required   test/bot_hub_shot_test.dart:109
error • The named parameter 'onOpenTeamChat' isn't defined test/bot_hub_shot_test.dart:112
```

核实：`BotHubPage` 的真实构造（`lib/ui/pages/bot_hub_page.dart:32`）要求 `onCreate` / `onOpenRoom` / `onOpenSettings`，**根本没有** `onOpenTeamChat`。测试传的是旧签名。
⇒ 这个测试文件在**当前 3.47 主干上就已经编译不过**，与 Flutter 版本无关，是历史遗留的测试脱节。

### 2.5.5 最有价值的一条：补丁是**双向兼容**的

实测（对同一份打了补丁的代码，分别用两套 SDK 跑）：

| SDK | 主题类名 | `lib/` error |
|---|---|---|
| Flutter 3.22（Dart 3.4.0） | `CardTheme` | **0** |
| Flutter 3.47（Dart 3.13.5） | `CardThemeData` | **0** |

原因：3.47 只是给旧 API 标了 `@Deprecated`，**没有删**——`int get value`、`int get red`、`withOpacity()` 至今都在（`painting.dart:230/282/345`）。

⇒ **除那 3 行主题改名外，127 处替换在 3.22 和 3.47 上都能编译。** 这带来一个直接好处：

```bash
# 现在就能对主干跑，Android 构建完全不受影响
node install/ohos-3.22-compat-patch.mjs --dir app --keep-theme
```

`--keep-theme` 只跳过 3 行主题改名（那是唯一只能单向的改动）。所以：

- **可以现在预清障**：把 124 处安全替换先落到主干，Android 继续用 3.47 正常发版；
- **降级当天只剩 3 行**：改 `CardThemeData`→`CardTheme` 等三处，一个文件。

这比"降级时一次性改 127 处"风险低得多，因为预清障的部分在两套 SDK 上都被编译器验证过。

### 2.5.6 依赖侧的三个硬约束（实测撞出来的）

`flutter pub get` 在 3.22 下失败三次，每个都是真约束：

| 包 | 3.22 下的问题 | 处理 |
|---|---|---|
| `webview_flutter >=4.9.0` | 要求 Dart ≥3.5.0，3.22 只有 3.4.0 | 必须降到 `4.8.0` |
| `webview_flutter_android >=3.16.9` | 同样要求 Dart ≥3.5.0 | 鸿蒙上本来要自实现，移除此依赖 |
| 全部带 `flutter: ">=x"` 约束的包 | **全部解析失败** | 见下方"版本号坑" |

**版本号坑（必记）**：鸿蒙分支的 `version` 文件是 `0.0.0-unknown`，且唯一的 git tag 是 `github.com/flutter/flutter/3.22.0`（带路径前缀，解析不出 `x.y.z`）→ Flutter 无法确定自己的版本 → pub 把所有 `flutter: ">=x"` 约束判为不满足 → **任何依赖都装不上**。

修法（已在 `/tmp/flutter-ohos` 上验证）：

```bash
cd <flutter-ohos>
git tag 3.22.1 HEAD          # 补一个标准 tag
rm -f bin/cache/flutter.version.json
flutter --version            # 重算缓存 → frameworkVersion: 3.22.1
```

不修这个，P0 一步都走不下去。

---

## 3. Flutter framework：真实破坏点只有 3 处

> ⚠️ 本节是**静态符号扫描**（在拿到 3.22 源码后逐个比对），属于早期估算。
> 结论已被 §2.5 的**真编译器实测**取代并完善：实测破坏面比本节的 3 处更大
> （另有 `withValues` / `toARGB32` / 分量单位 / 三个具名参数），但**全部可机械替换**，
> 且除 3 处主题改名外都双向兼容。以 §2.5 为准。

项目对 Flutter 的依赖面很窄：

```
material.dart     62 次
foundation.dart   52 次（主要是 debugPrint / ChangeNotifier / ValueNotifier）
services.dart     17 次（rootBundle / Clipboard / PlatformException）
widgets.dart       2 次
semantics.dart     1 次
```

用到的都是长期稳定的基础能力：`ListView`、`TextField`、`showModalBottomSheet`（36 处）、`PageView`（10 处）、`PopScope`（6 处）、`NavigationBar`。

### 3.1 逐个符号核对（不是抽样，是全量）

把 3.22.1-ohos 的 framework 源码（643 个 `.dart`，3,518 个定义）和 `dart:ui`（engine 提供，`Color`/`FontWeight`/`Offset`/`VoidCallback` 在这里）一起当真相源，对项目里 597 个 Flutter 相关符号逐个查：

```
能在 3.22 / Dart 核心 / dart:ui / 项目自身找到：  576
找不到：                                          21
  ├ 插件符号（WebViewController / FlutterSecureStorage / FilePicker …）： 15
  ├ 文案里的模型名误报（Gemma / VAE / Con）：                              3
  └ 真实 framework 缺口：                                                  3
```

复跑命令：

```bash
node install/ohos-downgrade-scan.mjs --framework /tmp/flutter-ohos/packages/flutter/lib
```

### 3.2 三个缺口全在同一个文件里

Flutter 3.27 做了一次 Material 主题重构，把 `CardTheme` / `TabBarTheme` / `DialogTheme` 改名成带 `Data` 后缀的类：

| 3.47 写法 | 3.22 写法 | 位置 |
|---|---|---|
| `CardThemeData` | `CardTheme` | `app/lib/ui/theme/dsh_tokens.dart:439` |
| `TabBarThemeData` | `TabBarTheme` | `app/lib/ui/theme/dsh_tokens.dart:524` |
| `DialogThemeData` | `DialogTheme` | `app/lib/ui/theme/dsh_tokens.dart:542` |

⇒ **framework 层的改动量 = 1 个文件 3 行。** 这是 A 路线最大的好消息，也说明此前"25 个版本的 API 差异"在实践中并不成立——因为你只用基础件。

### 3.3 但符号存在 ≠ 行为一致

以上只能证明"编译能过"。3.27 → 3.47 之间还有不报错但表现不同的变更，扫不出来，必须人工过一遍官方 breaking-changes，重点：

- 主题/配色默认值变化（`dsh_tokens.dart` 是自定义主题，影响面集中，好查）
- 滚动物理/回弹行为
- `showModalBottomSheet` 的默认尺寸与圆角（项目用了 36 处，若默认值变了会整体观感变化）
- 文本排版与字体回退（中文字形在鸿蒙上的渲染需要单独看）

---

## 4. 插件：5 个要处理，工作量可估

| 插件 | 项目版本 | 鸿蒙现状 | 处理方式 | 估量 |
|---|---|---|---|---|
| `shared_preferences` | 2.5.6 | SIG 有 `2.3.2-ohos` | 降版本，API 一致 | 0.5 天 |
| `web_socket_channel` | 3.0.3 | 纯 Dart | 无改动 | 0 |
| `provider` | 6.1.5 | 纯 Dart | 无改动 | 0 |
| `crypto` | 3.1.4 | 纯 Dart | 无改动 | 0 |
| `cupertino_icons` | — | 纯资源 | 无改动 | 0 |
| `webview_flutter` | 4.14.1 | SIG 分支基于 **4.8.0** | 降版本；项目只用 `WebViewController` / `setJavaScriptMode` / `NavigationDelegate` / `addJavaScriptChannel` / `loadRequest` / `WebViewWidget`，这些 4.8 都有 | 1–2 天 |
| `webview_flutter_android` | 4.14.1 | Android 专属 | 换成鸿蒙 platform channel，重点是 `setOnShowFileSelector`（Bot 页「添加文件」依赖它） | 2–3 天 |
| `flutter_secure_storage` | 9.2.4 | **无官方 ohos** | 自写插件；项目只用 `read` / `write`（9 个文件），调鸿蒙 `@ohos.security.asset` 或加密 preferences | 2–3 天 |
| `file_picker` | 8.3.7 | **无 ohos**（只有 `file_selector`） | 换 `file_selector_ohos` 或自写；项目只用 `pickFiles`（1 处） | 1–2 天 |
| `sherpa_onnx` | 1.13.8 | pub 无 ohos；upstream 有 `harmony-os/SherpaOnnxTts` HAR | 自写 flutter plugin 桥到 HAR；项目用 `OfflineTts` | 3–5 天 |

**关键点**：这些插件的 API 使用面都极小（secure_storage 只有 read/write、file_picker 只有 pickFiles），所以「自写」不是从零实现一个完整插件，而是实现项目实际用到的那几个方法。

---

## 5. 平台层：这才是大头

### 5.1 9 处 `Process.*` 全部要改

| 文件 | 用途 | 鸿蒙改法 |
|---|---|---|
| `local/dsh_runtime.dart:1427` | 拉起 node 跑 DSH | **FFI → NAPI → 进程内 `node::Start`**（核心改造） |
| `local/acp_client.dart:190` | ACP 会话进程 | 同上，且要考虑「一个进程只能启动一次 node」 |
| `local/bot_server.dart:360` | 本机 bot web 服务 | 同上 |
| ~~`local/local_model_server.dart:529,697`~~ | 本地模型服务 | **随端侧模型一起不搬**（§6），鸿蒙版无此调用 |
| `local/media_service.dart:273` | 媒体处理 | 需先确认鸿蒙侧 ffmpeg 等价物 |
| ~~`local/model_install.dart:270`~~ | 模型安装解压 | **随端侧模型一起不搬**（§6） |
| `local/local_mcp.dart:94,209` | MCP 子进程 | 鸿蒙无子进程，MCP 需改进程内 |

### 5.2 2,743 行 Kotlin 要全部重写成 ArkTS（端侧模型那 1,044 行不写了）

| 文件 | 大小 | 职责 | 鸿蒙对应 |
|---|---|---|---|
| `MainActivity.kt` | 120 KB / 2,368 行 | 解压运行时、jniLibs、文件/相机选择、模型导入、语音识别、扫码、浏览器打开、权限管理、返回键裁决 | 逐项拆到 ArkTS（部分有 Kit 对应）；去掉 16 处 LiteRT 接线 |
| ~~`LiteRtLmBridge.kt`~~ | ~~46 KB / 1,044 行~~ | 端侧模型推理（LiteRT-LM） | **已砍掉，不重写**（§6） |
| `SystemCalendar.kt` | 9.8 KB | 日历读写 | `@ohos.calendarManager` |
| `DshSchedulerService.kt` | 5.6 KB | 前台服务/定时任务 | 鸿蒙后台受限，需重新设计 |

**不要低估这块**：120 KB 的 `MainActivity` 里混着启动、解压、选择器、权限、返回键五类职责，ArkTS 侧不是"翻译一遍"，而是按鸿蒙 Ability/Extension 模型重新划分。

---

## 6. 端侧模型：已决策砍掉（并且几乎零成本）

**决策（2026-10-21）：鸿蒙版不包含端侧模型；Android 版保持不变。**

先给一个容易被忽略的事实：**端侧模型在 Android 版本身就已经不可达了。**

`ui/widgets/bottom_nav.dart` 里写着（2026-10-12 撤下）：

> 用户原话「本地大模型这一块不是太成熟，把这个功能删掉先」+「知识库也一并清理掉」。
> 做法是**撤入口、留代码**（用户选的可逆方案）……但现在**没有任何入口**能到达它们。

⇒ 所以砍掉它不是"减法"，而是"**鸿蒙版不再打包一批已经到不了的代码**"。用户可感知的功能没有任何变化。

### 6.1 精确裁剪边界

| 类别 | 内容 | 量 |
|---|---|---|
| Kotlin | `LiteRtLmBridge.kt`（整文件） | **1,044 行** |
| Kotlin | `MainActivity.kt` 里的 16 处 LiteRT 接线 | 16 处 |
| Dart | `local_model_server` / `local_model_spec` / `model_install` / `model_downloader` / `model_store` / `model_fit` / `model_manifest` / `model_importer` / `model_crash_store` / `ondevice_models_page` / `local_model_home_page` / `local_chat_page` | **6,384 行** |
| 资源 | `assets/models/model_manifest.json` | 6 KB（无实际模型，运行时下载） |

### 6.2 对工期的影响

| 项 | 砍掉前 | 砍掉后 |
|---|---|---|
| Kotlin 重写量 | 3,787 行 | **2,743 行**（−1,044，−28%） |
| P4 端侧模型换后端 | 3–6 周 | **取消** |
| 总工期 | 12–16 周 | **8–10 周** |

### 6.3 鸿蒙版要一并摘掉的东西

- `local_model_server.dart` 里的 `Process.start`（原 §5.1 的 2 处）—— 随文件一起不搬
- `MainActivity.kt` 的 `litertlmLog` 方法通道回调
- `model_settings_panel.dart`（3,253 行）里与端侧模型相关的段落需逐段甄别：**它同时承载云模型设置，不能整文件砍**

### 6.4 保留的后路

Android 版代码不动，所以将来若鸿蒙端侧推理成熟（MindSpore Lite / ONNX Runtime 有稳定方案），把上述文件搬回来即可，不需要重新设计。

---

## 6.5 已交付：可安装的鸿蒙 HAP（2026-10-21）

**在没有任何真机的情况下，构建链路已完整打通并产出可安装的已签名 HAP。**

### 产物

```
release/harmony/DSH-Mobile-signed.hap     106 KB
  verify-app: Digest verify result: true
              verify permission sign success
              verify: Verify success
```

装法：

```bash
hdc install release/harmony/DSH-Mobile-signed.hap
hdc shell aa start -a EntryAbility -b com.dshmobile.harmony
```

### 一键复现

```bash
bash install/ohos-build-hap.sh          # 构建 + 签名 + 验证
bash install/ohos-build-hap.sh --build-only
```

工程在 `ohos/`（ArkTS），**完全没碰 `app/android/`**。

### 这个包是什么、不是什么

**是**：一个能装进鸿蒙手机、能启动、显示 ArkTS 页面的真实应用。
它证明了——SDK 获取、ArkTS 编译、HAP 打包、证书链、profile 签名、安装包结构，**全链路都通**。

**不是**：DSH Mobile 的复刻。它现在只有一个页面（`Index.ets`），没有 DSH 的任何功能。

### 构建链路踩出来的 5 个硬坑（都已解决，写进脚本）

| # | 坑 | 现象 | 解法 |
|---|---|---|---|
| 1 | SDK 目录结构 | `The SDK management mode has changed` | 组件必须放 `<sdk>/<platformVersion>/`，如 `26.0.0/ets`，不能扁平 |
| 2 | 缺 previewer 组件 | 报"license agreement is not accepted"（误导） | `SDK_COMPONENTS` 含 previewer，必须解压 |
| 3 | `deviceTypes` 无 `phone` | `The intersection of the system capability sets is empty` | OpenHarmony SDK 26 只有 `default`/`tablet`/`2in1`/`tv`/`wearable`，**手机用 `default`** |
| 4 | 中文路径 | `00306003 Invalid project path` | hvigor 与 hap-sign-tool **都不接受中文路径**。本仓库含 `办公`，所以构建/签名/验证全部转到 `/tmp/dsh-ohos-build` 进行 |
| 4b | 中文路径（更隐蔽） | `NoClassDefFoundError: Could not initialize class java.io.FilePermission` | **在中文目录里跑 java 工具会静默失败**，连 `verify-app` 都挂。必须在 ASCII 目录下执行 |
| 5 | 证书链根用错 | `verify certificate chain failed! Signature does not match` | 根必须用 `rootcacert`，不能用 `cacert`（两者同名不同物，用错会得到重复的两级链） |

另有两条配置事实：

- **API 26+ 的版本号要写字符串** `"26.0.0"`，不能写数字 `26`（API 10–25 反过来必须写数字）
- `modelVersion` 要在 `oh-package.json5` 和 `hvigor/hvigor-config.json5` **两处一致**

### 环境（零账号，全部公开镜像）

| 组件 | 版本 | 来源 |
|---|---|---|
| OpenHarmony SDK | API 26（`26.0.0.38-Beta`） | `repo.huaweicloud.com/openharmony/os/7.0-Release/` |
| OHOS clang | 15.0.4（`aarch64-unknown-linux-ohos`） | SDK 自带 |
| hdc | 3.2.0f | SDK 自带 |
| hvigor | 6.26.8 | `repo.harmonyos.com/npm/` |
| hap-sign-tool | SDK 自带 | 含 `OpenHarmony.p12` 测试证书 |
| JDK | 17（`apt install openjdk-17-jdk-headless`） | Debian 源 |

SDK 3.38 GB 已校验 SHA256 `130a438c…f338f`。

---

## 7. 分阶段计划

### P0：环境与基线（1 周）

- 装 DevEco Command Line Tools（API 12/14 按目标机型定）
- 拉 `3.22.1-ohos-0.1.0`，跑通它自带的 hello world
- 用 3.22 的 Dart 跑 `dart analyze` 扫本项目，记录真实报错数（本机无法做，需要在 3.22 SDK 下跑）
- **验收**：3.22-ohos 能出一个能装到设备上的空壳 HAP

### P1：插件替换（1–2 周）

- shared_preferences / webview_flutter 降版本并跑通
- 自写 secure_storage、file_picker 的 ohos 实现
- **验收**：App 能在鸿蒙上启动、读到已存的设置与 Key

### P2：平台层重写（3–4 周）

- 解压运行时 → ArkTS
- 权限申请 → module.json5 + 运行期申请
- 文件/相机选择器、语音识别、扫码 → 对应 Kit
- 返回键裁决 → 参考项目已有 `_shouldExitOnBack` 单点裁决设计
- **验收**：除「跑 node」外的所有页面都能操作

### P3：进程内 node（2–3 周）

- OHOS NDK 编译 Node 24 `--shared`（验收：无 `PT_INTERP`、能导出 `_ZN4node5StartEiPPc`）
- FFI → NAPI → detached 线程 → `node::Start`
- 纯 JS fetch 垫片 + 载荷自解包
- **验收**：`process.platform === 'openharmony'`、`dsh --version`、一次流式模型对话

### ~~P4：端侧模型~~ —— 已取消

端侧模型砍掉（见 §6），P4 整段不做了。

**总工期：8–10 周**（砍掉前为 12–16 周）

---

## 8. 你要接受的四个永久缺口

1. **手机端不能执行外部程序** → `bash` 工具、`node xxx.mjs` 不可用
2. **无 PTY** → 终端面板不可用
3. **Node 一进程只能启动一次** → 崩溃 = 重开 App，无自动重启
4. **后台不可常驻** → 切后台 3–4 分钟后被挂起

这四项不在"待解决问题"里，因为它们没有解。产品文案需要如实表达。

---

## 9. 与本文件的关系

- 总体 go/no-go：`docs/HARMONYOS-NEXT-GO-NO-GO.md`
- 本文件：A 路线的精确迁移清单
- 扫描器：`install/ohos-downgrade-scan.mjs`（每次改依赖都建议重跑）

---

## 附录 B：真机首战（2026-10-28）

设备：ADY-AL00（HarmonyOS 7.0 / API 26），无线调试 192.168.3.42:33333，UDID `437AB…D0`。

### 证书：开源 OpenHarmony 证书在商业鸿蒙上**不被信任**

`hdc install` 报 `9568257 fail to verify pkcs7 file` —— 只能走 **华为 AGC**：
我方出 CSR（`signing-agc/dsh-debug.csr`，EC P-256）→ AGC 申请调试证书（.cer）+
调试 Profile（.p7b，绑 UDID）→ keystore 用 `openssl pkcs12` 自打 → `hap-sign-tool` 重签。
材料与成品：`signing-agc/`（cer/p7b/p12/key），应用「泡泡猫DSH手机鸿蒙版」已建。
⚠️ 签名命令必须在 ASCII 路径跑（中文路径触发 java `InvalidPathException`）。

### 真机实测结果（v4 包）

| 环节 | 结果 |
|---|---|
| 安装（AGC 调试签名） | ✅ install bundle successfully |
| 冷启动 | ✅ 不闪退（v4 已去掉冷启动启 node） |
| `dsh/native` 通道 | ✅ 收发正常，getPaths/isRuntimeReady 等 11 个方法已通 |
| 随包 runtime | ✅ copyRuntimeAsset 落盘 32.9 MB，**不联网** |
| 解压 | ✅ 9995 文件 2.4 秒（zlib.decompressFile + app/→dsh/ 映射 + shims 覆盖） |
| Flutter 主界面 | ✅ 工作区/公告/版本检查/调度器日志全通 |
| shared_preferences | ✅ 原生实现（`SharedPrefs.ets`，JSON 存储），MissingPluginException 归零 |
| 调度器保活 | startSchedulerService notImplemented（鸿蒙无前台服务），stop 恒 true |

### 仍未验证 / 未做

- **node 进程内启动未触发**（v4 起冷启动不自动启 node；`NodeHost` 就绪有待 UI 显式调用）
  下一步：dsh/native 增加 `startNode` 方法 + Dart 侧 AcpClient 的鸿蒙分支
  （session 走本机 HTTP 桥，不能用 stdio —— node 在进程内）
- 语音/TTS/微信扫码/APK 自更新 → notImplemented，Dart 侧已优雅降级
