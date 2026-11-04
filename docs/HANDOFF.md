# DSH 手机版 · 交接清单

> 写给**新会话**：这份文档是当前会话的浓缩交接。读完它 + 仓库里的文档，就能在不重踩坑的前提下继续。
> 生成时间：2026-10-02（界面重做后已更新，见 §5 与 §9）
> 工作区：`D:\新建文件夹\新建文件夹\新建文件夹\新建文件夹`
>
> **0.09 那一版的所有改动、验证证据和踩过的坑，都在 [`docs/RELEASE-0.09.md`](RELEASE-0.09.md)**
> （用户实测反馈 10 条逐条对照 + 设备上跑出来的证据 + 7 个"不修就会发版翻车"的真 bug）。
> **0.13（会话里能不能跑命令 / 切模型要选两次）见 [`docs/RELEASE-0.13.md`](RELEASE-0.13.md)**
> —— 那一版是**模拟器上端到端验证过的**，含"修前症状 → 根因 → 证据原文"。
> **0.14（会话页工作区入口 / 产物只装真文件 / 外观文案）见 [`docs/RELEASE-0.14.md`](RELEASE-0.14.md)**
> —— 含 `analyze` / 82 条单测 / 设备上造"真产出 + 假示例"两条命令的端到端取证。
> 本文件以下内容是 0.08 及更早的交接，仍然有效。

---

## 0. 一句话目标

把 **DSH（DeepSeek Harness）** 做成**能独立跑在 Android 手机上**的 App（除模型 API 外不依赖任何服务器），**界面照同类产品手机版做**。

用户原话（会话开头）：「DSH有没有手机版，我看到同类产品有出的手机版。」→「可是我想开发原生app」→「我要的是独立运行的手机版DSH」。
后来用户发来 11 页设计稿 PDF，说「我要做成的界面是这个样子的」——**那份设计稿就是同类产品手机版的界面截图**。

---

## 1. 当前状态（真实、已验证）

| 项 | 状态 |
|---|---|
| 真机能否使用 | ✅ **用户确认「可以用了」**（界面重做前的版本） |
| **arm64 真机包** | ✅ **第五轮功能全部入包**（2026-10-03 16:33，187.3 MB，sha256 `751C0D65…EBFCE2`）；包内新功能文案 16/16 命中，见 §13.8 |
| **真机包在真机上的验证** | ❌ **未做**——本轮机器上**没有连任何 arm64 设备**（`adb devices` 只有 x86_64 模拟器），见 §11.2 |
| 模型对话 | ✅ 真机 + 模拟器均跑通（真实返回，非 mock） |
| 多轮上下文 | ✅ 实测：见 §11.4 第 3 项（本轮在 release 同源代码上复验） |
| 单 APK 完全本地运行 | ✅ 内嵌 Node 26.4.0 + DSH 全部依赖 |
| **界面** | ✅ **已照设计稿重做 + 按 OCR 坐标逐页对齐**（11 页全部落地，见 §9 / §10） |
| **输入框纵向位置** | ✅ 修好：任务首页胶囊 81.9%~86.9%（§10.2 注 3；本轮复测一致） |
| **任务列表页 page-10** | ✅ 已实现（会话列表 + 新建任务 + 本机账户区；本轮实测有真实数据） |
| **按住说话语音态** | ⚠️ 占位交互（按住有视觉反馈 + 上浮提示条，松手如实提示"暂未接入"） |
| **助手消息展开/收起** | ✅ 已补上（用户消息本来就有，助手消息 >220 字折叠到 8 行） |
| **模型可选列表 + 倍率** | ✅ 已实现，切换会真改 overlay 并重启 ACP 会话（实测见 §9.3 / §11.4） |
| **专家页顶栏 Tab 带** | ✅ 已修（`height: 26` → `30`，对照实验见 §11.5）；第五轮冒烟 `[dsh-flutter-error]` 0 命中 |
| shell 沙箱 | ⚠️ Android 无 landlock，模型会自行降级（见 §6） |
| **资料库** | ✅ **两个 Tab（最近 / 我的资料）+ 真实扫描工作区**；模拟器实测扫到真实文件（见 §13.3 / §13.7） |
| **「项目」Tab** | ✅ 已按用户要求改为 **「设置」**（外观 / 模型 / 插件占位 / 关于，见 §13.4） |
| **模型配置** | ✅ **内置 deepseek / command / longcat / mimo 四家，端点预填**；「获取模型」拉真实列表；错误码译成中文（见 §13.5） |
| **定时任务** | ✅ 可定制时间 + **前台服务保活**；单元测试 12/12；触发实测见 §13.7。⚠️ 后台能力有硬边界（dataSync 每天约 6h 上限、被划掉不触发） |
| **主题** | ⚠️ **只有深色**（浅色需要重构配色，界面里是置灰+说明，不是假开关）；**字号真生效**（4 档） |
| **插件安装** | ⚠️ 占位（按用户要求留占位，不开放） |

**产物**：`dsh-mobile\dist\`
| 文件 | 大小 | 生成时间 | 用途 |
|---|---|---|---|
| `dsh-local-arm64-v8a-app-release.apk` | **187.3 MB** | **2026-10-03 16:33** | **真机包（第五轮功能全部入包）** |
| `dsh-local-x86_64-app-debug.apk` | 249.5 MB | 2026-10-03 16:27 | 模拟器（同源代码，本轮冒烟用；**不交付**） |

> ✅ arm64 release 已重建，时间戳（09:33）**晚于**最后一次源码改动（`model_sheet.dart` 20:29），
> 且 `lib/arm64-v8a/libapp.so` 内已确认含第二轮新界面字符串（22/22，见 §11.3）。
> ⚠️ 但它**没在任何 arm64 设备上跑过** —— 交付时请明确这一点。


---

## 2. 项目结构与关键路径

```
dsh-mobile\
├── app\                          Flutter 工程（界面 + 本地运行时封装）
│   ├── lib\main.dart             入口：未解压→SetupPage，已就绪→AppShell；注册 FlutterError 日志
│   ├── lib\local\dsh_runtime.dart 运行时封装（spawn / overlay 生成 / 凭据注入）
│   ├── lib\local\acp_client.dart  ★ ACP stdio 客户端（多轮的关键，界面重做**未改动**）
│   ├── lib\data\
│   │   ├── model_catalog.dart    ★ 可选模型清单（三档 + 6 个模型 + 倍率）
│   │   └── artifacts.dart        产物卡片模型 + 从工具调用里提取文件名的解析
│   ├── lib\state\
│   │   ├── model_store.dart      ★ 当前模型/档位的持久化与广播
│   │   └── bridge_state.dart     早期远程方案遗留（不用）
│   ├── lib\ui\
│   │   ├── app_shell.dart        ★ 底部 5 项导航 + 各页装配 + overlay 写入
│   │   ├── chat_page.dart        转发文件（旧路径 → pages/chat_page.dart）
│   │   ├── theme\dsh_tokens.dart ★ 设计 token（配色/间距/字号，含设计稿坐标系）
│   ├── pages\
│   │   │   ├── task_home_view.dart  设计稿 page-08 任务首页（输入区贴底 87%）
│   │   │   ├── chat_page.dart       设计稿 page-01~04/11 对话页
│   │   │   ├── model_sheet.dart     设计稿 page-01 下半 模型选择弹层
│   │   │   ├── expert_page.dart     设计稿 page-09 专家中心
│   │   │   ├── task_list_view.dart  设计稿 page-10 任务列表（第二轮新增）
│   │   │   ├── library_page.dart    设计稿 page-05 资料库
│   │   │   ├── scheduled_page.dart  设计稿 page-06 定时任务
│   │   │   └── project_page.dart    设计稿 page-07 项目空间
│   │   ├── widgets\
│   │   │   ├── bottom_nav.dart      5 项底部导航
│   │   │   ├── input_bar.dart       胶囊输入框 + 模型按钮 + 附件/发送
│   │   │   ├── message_stream.dart  消息流 / 产物卡片 / 工具卡片 / 附件菜单
│   │   │   └── common.dart          空态、页面标题、胶囊、文件类型角标
│   │   ├── setup_page.dart      首次引导（解压运行时，未改动）
│   │   └── settings_page.dart   模型设置（加了 extraModelIds 注册）
│   └── android\app\src\main\kotlin\...\MainActivity.kt  ← 解压 assets 的宿主（未改动）
├── install\                      ★ 全部构建/打包脚本（动手前先读这里）
│   ├── fetch-termux-deps.mjs     抓 Termux node + 依赖库
│   ├── assemble-android-runtime.ps1
│   ├── normalize-runtime-libs.mjs 补齐库的 SONAME 别名
│   ├── patch-node-shell.mjs      修补 node 里硬编码的 Termux shell 路径
│   ├── prepare-jnilibs.mjs       ★ 依赖闭包 + 库改名 + DT_NEEDED 改写
│   ├── build-app-assets.ps1      把 DSH 树打成 assets zip（含 3 个 shim）
│   ├── build-local-apk.ps1       ★ 构建 APK（-Abi / -Mode）
│   ├── android-shim-require-builtin.js  ┐
│   ├── android-shim-flock.js            ├ 三个必需的 Android shim
│   ├── android-fs-shim.cjs              ┘
│   └── android-acp-smoke.mjs     ★ 设备上直接验证 ACP 多轮的脚本
│   ├── uitap.ps1                 ★ 语义树 dump + 按 label 点击/长按（第二轮新增）
│   └── shot.ps1                  ★ 截屏落到本地（绕开中文路径，第二轮新增）
├── docs\
│   ├── ANDROID-LOCAL-VERIFICATION.md   可行性验证报告（4 个平台障碍）
│   ├── ANDROID-LOCAL-PACKAGING.md      打包实现与 8 个踩坑记录
│   ├── check_encoding.py               ★ 扫 dart 源码乱码标记（第二轮新增）
│   ├── screenshots\                    ★ 新界面在模拟器上的实拍（13 张）
│   └── HANDOFF.md                      ← 本文件
└── bridge\  probes\  fixtures\    早期远程方案遗留（当前不用，可忽略）
```

**工作区里的相关目录**：

| 路径 | 内容 |
|---|---|
| `D:\dev\android-node\runtime\{aarch64,x86_64}\` | 解包后的 Termux node + 依赖库 |
| `D:\dev\android-node\jnilibs\{arm64-v8a,x86_64}\` | ★ 可直接进 APK 的 libnode.so + 库 |
| `D:\dev\android-node\app-assets\dsh-runtime.zip` | ★ DSH 依赖树 + shim（150.6 MB） |
| `D:\dev\build\app-local\` | ASCII 构建副本（**必须**，见 §3.8） |
| `pdf-images\` | 设计稿 11 张图 + **`ocr-all.txt`（设计稿可读文本）** |

**构建环境**：Flutter `D:\dev\flutter` ｜ JDK17 `D:\dev\jdk\jdk-17.0.20.1+1` ｜ SDK `D:\dev\android-sdk` ｜ Gradle home `D:\dev\gradle-home`

---

## 3. 关键技术结论（重踩会浪费大量时间）

### 3.1 Node 运行时只能选 Termux 的 node
`nodejs-mobile` 停在 **Node 18**，而 DSH 用了 `node:sqlite`（22.5+ 才有）。所以用 **Termux 的 node 26.4.0**。
node 二进制里**硬编码**了 `/data/data/com.termux/files/usr/bin/sh`，必须用 `patch-node-shell.mjs` 做**同长度**替换为 `/system/bin/sh`（否则所有子进程调用 `ENOENT`）。

### 3.2 三个 Android 专用 shim（缺一个都起不来）
| shim | 解决什么 |
|---|---|
| `android-shim-require-builtin.js` | `node-addon-require-builtin` 无 android 构建（boot 阶段 fatal）。用标准 `require` 实现，配合 `--expose-internals` |
| `android-shim-flock.js` | `node-addon-system` 的 flock 显式拒绝非 linux/darwin；bionic 也无 `flock()`。单进程场景退化为 no-op |
| `android-fs-shim.cjs` | **SELinux 禁止硬链接**，而 DSH 会话持久化用 `link()` 做原子写。降级为 `copyFile(COPYFILE_EXCL)`（语义等价：不覆盖已存在文件） |

**启动 node 必须同时带**：`--expose-internals` **和** `--require <fs-shim>`。
（我写测试脚本时两次漏掉，症状分别是 `Cannot find module 'internal/modules/esm/loader'` 和 `EACCES: link ... session.v4.jsonl.zstd`。）

### 3.3 node 必须以 `libnode.so` 进 jniLibs
Android 只允许从 `nativeLibraryDir` 执行原生程序。而 Termux 的库名（`libcrypto.so.3`、`libicui18n.so.78`、`libz.so.1`）**不以 `.so` 结尾**，不能作为 jniLibs 打包 → 必须**改名 + 改写所有 ELF 的 DT_NEEDED**。
`prepare-jnilibs.mjs` 会解析 ELF 依赖闭包，只输出真正需要的库（arm64 共 11 个）。

> ⚠️ 该脚本的正则曾写成 `lib[...]{2,40}`，导致 **`libz` 只有 1 个字符**被漏掉，arm64 缺 `libz1.so`。
> x86_64 因为早期手工复制过而侥幸通过。**已修为 `{1,40}`**。

### 3.4 `useLegacyPackaging` 而不是 manifest 的 `extractNativeLibs`
Android 默认不从 APK 解压 `.so`，`nativeLibraryDir` 是空的 → `libnode.so` 无法执行。
AGP 拒绝 manifest 里写 `extractNativeLibs="true"`，要求用 `packaging.jniLibs.useLegacyPackaging = true`。
**顺带效果：APK 从 420 MB 降到 227 MB。**

### 3.5 ABI 要写进 `gradle.properties`
`flutter build apk -PdshAbi=...` **不会转发** `-P` 给 Gradle；环境变量 `ORG_GRADLE_PROJECT_*` 又会被 **Gradle daemon 缓存**。
唯一可靠做法：构建脚本改写 `android/gradle.properties` 里的 `dshAbi=` 并 `gradlew --stop`。
另外 `abiFilters` 会被 Flutter 插件覆盖，需再用 `packaging.jniLibs.excludes` 显式排除非目标 ABI。

### 3.6 assets 里的 zip 有两个隐式陷阱
- **`ZipInputStream` 会提前结束**：26495 个条目只解出 3 个 → 改用 `ZipFile`（读 central directory）。
- **.NET 在 Windows 上写 zip 用反斜杠**（`app\xxx` 而非 `app/xxx`）→ Kotlin 侧必须 `name.replace('\\','/')` 再判断前缀。

### 3.7 Kotlin 注释里别写路径通配
Kotlin 支持**嵌套块注释**，注释里写 `app/**` 会开启第二层注释，报 `Unclosed comment` + `Missing '}'`。

### 3.8 非 ASCII 路径 + PowerShell 5.1 都是雷
- 项目路径含中文会让 **AGP 报错**、`flutter analyze` 抛 `FormatException` → 必须 robocopy 到 ASCII 副本（`D:\dev\build\app-local`）再构建。
- 本机 PowerShell 是 **5.1**，按 ANSI 读无 BOM 的 UTF-8 脚本 → **`.ps1` 必须纯 ASCII**。
  （曾出现「变量插值静默变成空串」，查了很久才发现是中文注释乱码产生了引号。）
- **同一个中文路径还会让 `adb pull` 报 `cannot create file/directory`**（本次实测）。
  截屏/取文件一律用 `adb exec-out screencap -p > 本地文件`，不要用 `adb pull` 到中文路径下。
- **`adb pull` 的目标文件名里带 `-` 也会失败**（被当成参数）。用下划线命名。

### 3.9 界面层的三个坑（本次新踩，都很难从现象反推原因）

**a) `Spacer` / `Expanded` 绝不能放进 `SingleChildScrollView`。**
`Spacer` 是 `Expanded` 的糖，而滚动容器给子节点的 `maxHeight` 是无限的 →
直接抛 `RenderFlex children have non-zero flex but incoming height constraints are unbounded`。
真机表现是**整页空白**（只剩底色），因为 Flutter 的 build 异常默认不打进 logcat（见 c）。
纵向留白必须按屏高比例显式算（`LayoutBuilder` + `SizedBox(height: h * 0.07)`）。

**b) 相对 import 写错层数时，报错信息会误导人。**
把 `lib/ui/pages/xxx.dart` 里的 `../theme/a.dart` 写成少一层，Dart 只报
`Target of URI doesn't exist`。如果**同一批**新文件层数都写错，你会看到几十上百条
"文件不存在"，很容易误判成"分析器坏了 / 缓存脏了"（本次就这样浪费了很多时间）。
对策：下面这段脚本能在 3 秒内确认所有相对 import 是否真的落到了文件上，改完就跑。

```powershell
# 用法：$lib 指向 app\lib，逐条解析相对 import 并检查目标文件是否存在
$lib = 'D:\...\dsh-mobile\app\lib'
Get-ChildItem -Recurse -File -Filter *.dart $lib | ForEach-Object {
  $rel = $_.FullName.Substring($lib.Length+1) -replace '\\','/'
  $parts = $rel -split '/'
  $dir = if ($parts.Length -gt 1) { $parts[0..($parts.Length-2)] } else { @() }
  [regex]::Matches([System.IO.File]::ReadAllText($_.FullName), "(?m)^\s*(?:import|export)\s+'([^']+)'") | ForEach-Object {
    $uri = $_.Groups[1].Value
    if ($uri -like 'dart:*' -or $uri -like 'package:*') { return }
    $segs = New-Object System.Collections.ArrayList; $dir | ForEach-Object { [void]$segs.Add($_) }
    $uri -split '/' | ForEach-Object {
      if ($_ -eq '.' -or $_ -eq '') { } elseif ($_ -eq '..') { $segs.RemoveAt($segs.Count-1) } else { [void]$segs.Add($_) }
    }
    if (-not (Test-Path (Join-Path $lib ($segs -join '\')))) { Write-Host "BROKEN $rel -> $uri" }
  }
}
```

**c) Flutter 的 build/布局异常默认**不**进 `adb logcat -s flutter`。**
界面出问题是"整页空白"时，日志一片干净，只能靠截图猜。
`main.dart` 里已经接管了 `FlutterError.onError` 并把异常 + 前 12 行堆栈打到
`[dsh-flutter-error]` 前缀下 —— 以后界面不对，先 grep 这个前缀。

### 3.10 怎么在没有视觉工具的情况下验证界面
本次视觉模型限流、本机也没装 tesseract，靠下面两条路把界面验到了"内容级"：
- **语义树**：`main.dart` 里的 `ensureSemantics()` 一直在，用
  `adb shell uiautomator dump /sdcard/u.xml` + `cat` 能读到**所有**按钮/文字/坐标
  （Flutter 会把它合成 `content-desc`，形如 `任务&#10;任务`）。
  这是判断"页面上到底有什么"最可靠的手段，比截图快。
- **交互日志**：底部导航点击、打开对话页都打了 `[dsh-nav]` 前缀；
  ACP 生命周期打 `[chat][acp]`。点击有没有生效看日志，不要靠像素猜。
- 截图只用来确认"有没有大面积空白"，用色带统计即可（见 `docs\screenshots\`）。

### 3.11 凭据怎么进 App
- API Key 存 `flutter_secure_storage`，**以环境变量注入 node 进程**（overlay 用 `apiKeyEnv` 引用同名变量），**不进命令行**。
- overlay 必须**同时覆盖 `agent-default-model` 和 profile 自己的行**（`headless` / `acp` 各自的 config 会盖掉前者）。
- 开发/自动化可从 `files\dev-api-key.txt` 读（便于 `adb shell run-as ... 'cat > ...'` 用 stdin 注入，避免 Key 出现在命令行）。
- ⚠️ 曾出现两处 Key **长度都是 93 但内容不同**导致认证失败——注入前先确认来源。

---

## 4. 设计稿要点（★ 这是界面工作的依据）

原 PDF：`C:\Users\25894\AppData\Roaming\PaopaocatDSH\attachments\v1\files\70\70bfdcc1...\生成PDF.pdf`（11 页，图片型，夸克导出）
已提取图片 + OCR：**`pdf-images\ocr-all.txt`**（368 行，含每行文字的 y/x 坐标）
配色：全 11 页深色，平均色在 `#1c`–`#2c`；设计稿主色偏青（`#182828` 占比 10%）。

### 4.1 底部导航（每页都有，5 项）
`任务` ｜ `专家` ｜ `资料库` ｜ `定时任务` ｜ `项目`
（坐标 y≈2567-2610，x 依次约 85 / 327 / 556 / 783 / 1058）

### 4.2 各页内容（来自 OCR）

**page-08 = 任务首页（品牌页）**
- 顶部标题 `同类产品` + `云端 >`
- 中部品牌区：logo + `你的AI好Buddy` + `在读大学生专属福利，认证即领积分`
- 功能提示轮播：`进行数据分析及可视化` / `进行文档处理` / `做一份幻灯片` / `品制作工作台` + `换一换`
- 底部输入框：`发消息或按住说话`

**page-01 / 02 / 03 / 04 / 11 = 对话页 + 弹层**
- 顶部：对话标题（如 `最近爆火的一套抽·`）+ `○云端`；正文上方有 `内容由AI生成`
- 消息流：用户长消息 → `展开√` → `已完成` → 助手回复（含 `《XX家族_AI漫剧通用剧本模板.md》` 等产物名）
- 输入区：`按住说话`，右侧当前模型按钮（如 `Hy4preview`）
- **模型选择弹层**（page-01 下半）：标题 `选择模型`；三档 `快速 0.21x` / `均衡 0.65x` / `极致 1.20x`；模型列表带倍率：
  `Hy4 preview 0.29x (夜间免费)`、`Hy3 0.00x (限时免费)`、`Hy3 0.05x`、`Deepseek-V4.1-Flash 0.11x`、`GLM-5.3 0.79x`、`GLM-5.3-Flash 0.06x`
- **附件菜单**（page-03）：`拍照` ｜ `照片／视频` ｜ `添加文件`；下方 `专家中心` / `使用技能` / `连接器` / `定时任务`
- **产物列表**（page-04）：`产物` 标题 + 文件卡片（`XX家族_填空速成表 MD 文件·4.6KB`、`XX家族_AI漫剧通用剧本 MD 文件·16.3KB`）+ `批量操作`

**page-05 = 资料库**：标题 `资料库`；搜索框 `搜索资料库`；Tab `最近` / `我的资料` / `团队空间`；文件列表（pdf/docx/html/pptx）

**page-06 = 定时任务**：标题 `定时任务`；空态 `暂无定时任务`

**page-07 = 项目空间**：标题 `项目空间`；副标题 `多人协同，打造超级团队`；`我的项目`；卡片如 `陵川那些事（最近更新于9小时前）`、`项目新手指引（最近更新于 2026-07-11）`

**page-09 = 专家中心**：Tab `专家` / `技能` / `连接器`；分类 `全部` / `专家团` / `腾讯专家` / `高校新生攻略` / `产品设计`；专家卡带名称+描述（如 `深度调研`、`LLM知识库`、`爽文创作`、`策略回测`、`嵌入式固件`、`AI图像提示词工程师`、`知识管理专家`、`世界观架构师`）

**page-10 = 任务列表**：顶栏 `云端`；`新建任务`；`任务` 分组；任务卡；底部账户区 `阿白` / `体验版` / `1651.01`

### 4.3 坐标怎么换算成布局比例（界面重做的关键）

设计稿按竖屏导出，机身 **1215 x 2640** 设计像素。`dsh_tokens.dart` 里就是这么定的：

```
dx(x) = x / 1215      // x → 屏宽比例
dy(y) = y / 2640      // y → 屏高比例
```

用 OCR 行坐标直接换算，几个关键位置：

| 设计稿元素 | y 坐标 | 屏高比例 |
|---|---|---|
| 顶栏标题 | 162-214 | 7% |
| `内容由AI生成` | 371 | 14% |
| 消息正文 | 547 | 21% |
| 输入框 | 2138-2200 | 82-85% |
| 底部导航 | 2567-2610 | 97% |

> ⚠️ 早先一版把基准写成了 3840，导致所有纵向位置被压缩 31%，输入框和导航的间距
> 明显比设计稿紧。**改布局比例前先确认基准是 2640。**

### 4.4 实测配色（从设计稿采样 + 实现里在用）

| 用途 | 值 |
|---|---|
| 页面底色 | `#131719` |
| 卡片 / 区块底色（设计稿主色） | `#1C2828` |
| 顶栏 / 底部导航 | `#161C1D` |
| 主色（青） | `#3FE0C8` |
| 正文 / 次要 / 弱化文字 | `#E8EFEC` / `#94A8A4` / `#6B7C79` |
| 用户气泡 / 助手气泡 | `#25383A` / `#1B2426` |

---

## 5. 下一步（建议优先级）

1. **真机复测 arm64 包（最高优先）**：arm64 release 已重建（§11.3），但本轮机器上**没有 arm64 设备**，
   所以「装真机 → 引导解压 → 5 页导航 → 配模型 → 发消息 → 多轮」这条链路**一次都没在 arm64 上跑过**。
   接上真机后直接按 §7 与 §11.4 的命令重跑一遍即可；解压只要做过一次就不用重来。
2. **修专家页 2px overflow**：`expert_page.dart` 顶栏 Tab 带 `height: 26` → `30`（一行，根因与验证见 §11.5）。
   修完顺手把 arm64 + x86_64 两个包一起重建一次，别只重建一个（否则两个包又不同源）。
3. **把模型清单的 `routeId` 换成真实 id**：见 §9.3。现在设计稿那 6 个模型名是**显示名**，
   `model_catalog.dart` 里的 routeId 是占位值；不换成端点真实存在的 id，实际只会跑
   「设置」里填的那个模型（界面能切、选择能存盘，但后端路由不变）。
   > 🔶 **用户本次未对此表态，继续沿用安全兜底策略**（见 §9.3 的 `resolveActiveRoute`）。
   > 这是一个**待用户决策项**：要么给真实 routeId，要么保留"切名不变后端"。
4. **权限确认弹层缺工具信息**：本轮实测模型弹「Agent 请求执行操作」时，弹层只显示
   「这是一次需要你确认的操作：」+ `拒绝` / `允许一次`，**没有说明要执行什么**。
   根因待查（`session/request_permission` 的 `toolCall` 字段可能没被渲染）。见 §11.6。
5. **Android 上 `bash` / `glob` 不可用**：本轮实测模型报
   `spawn bash EACCES`、`glob could not start its search command (ripgrep launch failed)`，
   只有 `read` 能用。模型会自行降级，但可用工具面比桌面窄很多。见 §11.6。
6. **资料库 / 专家 / 项目接真实数据**：现在这三页只有布局 + 空态/样例（见 §9.4、§10.5）。
   资料库可以先把 DSH 产物目录索引起来（`files/workspace` 下的文件）。
7. **产物卡片改成结构化**：目前是从工具调用的文本里正则捞文件名（`artifacts.dart`），
   因为 ACP 协议没有 artifact 通知。要更准就得在工具层约定输出格式。
8. **任务列表接 DSH 会话文件**：`page-10` 已做，但数据源只是"本次运行期间发过消息的
   会话"（内存态，重启即空）。DSH 自己的 `session.v4.jsonl.zstd` 就在磁盘上，
   做一层索引就能显示历史任务（见 §10.5）。**注意**：本轮已把该文件的读取方法搞清楚了
   （多帧 zstd 的解法见 §11.4），复制文件到本地时要避开 PowerShell 的二进制重定向坑。
9. **语音输入真接入**：现在的"按住说话"是**明确标注的占位交互**（见 §10.4）。
   要真做需要引 `speech_to_text` 之类的插件，会同时增加包体积与权限面。
10. 收尾项：`node-pty` / `sharp` 在 Android 上的降级行为未验证（它们都是懒加载，不用到就不触发）。

---

## 6. 已知限制（不要当成 bug 去修）

- **shell 沙箱不可用**：模型报 `Shell sandbox isn't available on this host`（DSH 在 Linux 用 landlock，Android 内核没启用）。实测模型会自行降级（改用文件工具完成任务），不阻塞。
- **首启解压约 75 秒**（26495 个文件）。真机上还要担心存储空间（APK 186 MB + 解压约 480 MB）与长时间前台等待被系统打断。
- **APK 是 debug 签名**：正式分发需换 keystore。
- **`dsh-local-x86_64-app-debug.apk` 只用于模拟器**；真机装 arm64 release。
- **设计稿里"云端"的东西本地没有**：账户积分、团队空间、连接器、云端任务列表、
  多会话切换都是同类产品云端能力，本地 DSH 不提供。这几处刻意做成空态而不是假数据。
- **聊天记录不持久化到界面**：重启 App 后对话页是空的（DSH 自己的会话文件还在，
  但界面没有历史列表 —— 这也是 `page-10` 任务列表页没做的原因）。

---

## 7. 常用命令与验证流程

### 构建 APK（在项目根）
```powershell
# 真机包（arm64）
install\build-local-apk.ps1 -Abi arm64-v8a -Mode release
# 模拟器包（x86_64，调试用）
install\build-local-apk.ps1 -Abi x86_64 -Mode debug
# 前置：若运行时/资源缺失
node install\prepare-jnilibs.mjs arm64-v8a
install\build-app-assets.ps1
```
产物落在 `dsh-mobile\dist\`。

### 运行时资源怎么来（首次或需要重建时）
```powershell
node install\fetch-termux-deps.mjs
install\assemble-android-runtime.ps1 -Arch aarch64
node install\normalize-runtime-libs.mjs aarch64
node install\patch-node-shell.mjs aarch64
node install\prepare-jnilibs.mjs aarch64
```

### 模拟器验证 App 全流程
```powershell
$adb = "D:\dev\android-sdk\platform-tools\adb.exe"
& $adb install -r "dsh-mobile\dist\dsh-local-x86_64-app-debug.apk"
& $adb shell pm clear com.dshmobile.dsh_mobile      # 需要重走解压时
& $adb shell am start -n com.dshmobile.dsh_mobile/.MainActivity
# 关键日志（App 内所有关键状态都打在这里）
& $adb logcat -s flutter      # 看 [dsh-*] 前缀
& $adb logcat -s DshLocal     # 看解压进度
```

**⚠️ UI 自动化的两个坑**（我踩过）：
1. Flutter 是自绘引擎，默认 `uiautomator` 读不到文本 —— 已在 `main.dart` 里 `ensureSemantics()` 修好（通过语义树可读）。
2. 点输入框后**软键盘弹出会让布局上移约 850px**，发送按钮坐标随之改变 → 每次点击前重新 `uiautomator dump`。
   定位技巧：输入框是 `class="android.widget.EditText"`；发送按钮是 `content-desc=""` 且位于下半屏的 `Button`。
   （注意 `SelectableText` 会让消息气泡也变成 clickable，别用"最后一个 clickable"来猜。）

### 设备上直接验证 ACP 多轮（不依赖 UI）
```powershell
# 需要设备上有 DSH 树 + 运行时 + .env（含 COM_API_KEY）
& $adb push install\android-acp-smoke.mjs /data/local/tmp/dshhome/
# 运行见 install\android-acp-smoke.mjs 顶部注释；成功标志：
#   [smoke] 多轮上下文: ✓ 成立（答对了口令）
```
> 该脚本的子进程**也必须**带 `--expose-internals` 和 `--require <fs-shim>`。

### 读设计稿（视觉工具限流时的替代方案）
```powershell
# 11 页已 OCR 完毕，直接读结果：
#   pdf-images\ocr-all.txt
# 需要重新 OCR：
& C:\Python314\python.exe pdf-images\ocr.py <输出文件> <图片...>
# 布局分析（逐行色差切分）：
& node pdf-images\analyze-layout.mjs <图片>
```
RapidOCR 装法：`C:\Python314\python.exe -m pip install --user rapidocr-onnxruntime`
（控制台直接 print 中文会因 cp936 乱码，**必须写 UTF-8 文件再读**。）

---

## 8. 会话记录位置（如需回溯原始对话）

```
C:\Users\25894\AppData\Roaming\PaopaocatDSH\sessions\
  --D-~65B0~5EFA~6587~4EF6~5939-...--\        ← cwd 的路径编码（= 本工作区）
    session-9bbb3827-a77a-4919-8d88-7be2b6a82ba3\session.v4.jsonl.zstd   3.66 MB
```
会话文件是 **zstd 压缩的 JSONL**（Node 22.15+ 可用 `zlib.zstdDecompressSync` 解）。
但本清单已经把该会话的关键结论全部提炼，通常不需要回溯原始记录。

---

## 9. 界面重做记录（照设计稿对齐，本次完成）

### 9.1 改了哪些文件

**新增（16 个）**

| 文件 | 做什么 |
|---|---|
| `lib\ui\theme\dsh_tokens.dart` | 设计 token：配色 / 间距 / 圆角 / 字号 + 设计稿坐标系换算 |
| `lib\ui\app_shell.dart` | 底部 5 项导航 + 各页装配 + overlay 写入/自愈逻辑 |
| `lib\ui\pages\task_home_view.dart` | page-08 任务首页（自绘 logo + 轮播 + 输入框） |
| `lib\ui\pages\chat_page.dart` | page-01~04/11 对话页（ACP 会话 + 消息流 + 产物） |
| `lib\ui\pages\model_sheet.dart` | page-01 下半 模型选择弹层（三档 + 带倍率列表） |
| `lib\ui\pages\expert_page.dart` | page-09 专家中心（3 Tab + 5 分类 + 专家卡网格） |
| `lib\ui\pages\library_page.dart` | page-05 资料库（标题 + 搜索 + 3 Tab + 空态） |
| `lib\ui\pages\scheduled_page.dart` | page-06 定时任务（空态 + 新建按钮） |
| `lib\ui\pages\project_page.dart` | page-07 项目空间（副标题 + 我的项目 + 卡片） |
| `lib\ui\widgets\bottom_nav.dart` | 5 项底部导航（等分，对齐设计稿 x 坐标） |
| `lib\ui\widgets\input_bar.dart` | 胶囊输入框 + 模型按钮 + 附件/发送/停止 |
| `lib\ui\widgets\message_stream.dart` | 消息流 / 产物卡片 / 工具调用卡片 / 附件菜单 / 展开收起 |
| `lib\ui\widgets\common.dart` | 空态、页面标题、筛选胶囊、文件类型角标、区块标题 |
| `lib\data\model_catalog.dart` | 可选模型清单（三档 + 6 模型 + 倍率 + 档位推导） |
| `lib\data\artifacts.dart` | 产物模型 + 从工具内容里提取文件名/体积 + 产物列表页 |
| `lib\state\model_store.dart` | 当前模型/档位持久化 + 变更广播 |

**修改（4 个）**

| 文件 | 改了什么 |
|---|---|
| `lib\main.dart` | 挂新主题；`LocalShell` 改用 `AppShell`；载入模型清单；生成/升级 overlay；接管 `FlutterError.onError` |
| `lib\local\dsh_runtime.dart` | `writeModelConfig` 新增 `extraModelIds`（注册整份清单）；新增 `readConfiguredRoute` / `countRegisteredModels`。**spawn / 凭据注入 / 环境变量一个字节没动** |
| `lib\ui\settings_page.dart` | 保存时把清单其余 routeId 一并注册 |
| `lib\ui\chat_page.dart` | 改成转发文件（旧路径 → `pages/chat_page.dart`），避免改了路径就编译不过 |

**刻意没动**：`acp_client.dart`、三个 Android shim、`MainActivity.kt`、`build-local-apk.ps1`、
`prepare-jnilibs.mjs` 等构建链脚本。"引导→解压→配模型→发消息→多轮"这条链路保持原样。

### 9.2 验证结果（都是实测，非推断）

| 项 | 结果 |
|---|---|
| `flutter analyze` | ✅ **No issues found!**（0 error / 0 warning / 0 info） |
| x86_64 debug 构建 | ✅ 成功，`dsh-mobile\dist\dsh-local-x86_64-app-debug.apk`（249.2 MB） |
| 安装 + 启动 | ✅ 模拟器 `sdk_gphone64_x86_64`（API 36）装机启动正常，无 Flutter 异常 |
| 5 项底部导航 | ✅ 依次点击，日志 `[dsh-nav] tab -> 专家(1) / 资料库(2) / 定时任务(3) / 项目(4) / 任务(0)` 全部命中 |
| 各页内容 | ✅ 语义树 dump 出设计稿文案：`同类产品`/`你的AI好Buddy`/`在读大学生专属福利，认证即领积分`/`发消息或按住说话`/`换一换`；`专家`+5 分类+8 张专家卡；`资料库`+3 Tab；`暂无定时任务`；`项目空间`+`多人协同，打造超级团队` |
| 模型弹层 | ✅ 点开 dump 到：`选择模型` / `快速 0.21x` / `均衡 0.65x` / `极致 1.20x` / `Hy4 preview 0.29x 夜间免费` / `Hy3 0.00x 限时免费` / `Hy3 0.05x` / `Deepseek-V4.1-Flash 0.11x` / `GLM-5.3 0.79x` — 与设计稿一致 |
| 换模型真的生效 | ✅ 选 `Deepseek-V4.1-Flash` 后日志：`[dsh-model] overlay 已重写：默认=deepseek/deepseek-v4.1-flash，注册 7 条`；设备上 `model.overlay.yml` 确有 7 条 models；按钮文字同步变为 `Deepseek-V4.1-Flash` |
| 对话页 + ACP | ✅ `[chat][acp] initialize ok` → `session created: 2ae5bc91-…` → `ACP session ready … model=Deepseek-V4.1-Flash` |
| **端到端发消息** | ✅ 在新界面的输入框打字 + 点发送 → `[chat] prompt: …` → `[chat] message: PONG` → `stopReason=end_turn`，消息渲染到页面上 |
| 附件菜单（page-03） | ✅ dump 到 `拍照` / `照片／视频` / `添加文件` / `专家中心` / `使用技能` / `连接器` / `定时任务` / `收起` |
| 参考截图 | ✅ `docs\screenshots\` 下 7 张（page01/03/05/06/07/08/09） |

### 9.3 模型切换是怎么落地的（以及它的诚实边界）

**机制**：`model_sheet` 点选 → `ModelStore` 存盘 + 广播 → `app_shell` 重写
`model.overlay.yml`（把整份清单注册进 `providers.<id>.models`，`agent-default-model`
与 `acp` 两处指向选中项）→ `ChatPage` 监听 store，**关掉旧 ACP 子进程、重建会话**。
之所以必须重启进程：overlay 是 `--patch` 在**进程启动时**读入的。

**边界（重要）**：设计稿那 6 个模型名（`Hy4 preview` / `GLM-5.3` …）是同类产品云端的**显示名**，第三方端点不存在这些 id。所以：
- 没在「设置」填过 model id → 用 `model_catalog.dart` 里的 routeId（想真区分就改这里）
- 填过 → 只有显式选中「自定义模型」才用你的；其余条目**回落到你的 model id 保证能跑**
  （宁可"切了名但后端不变"，也不要"切了就报未知模型、对话直接不可用"）

这段取舍实现在 `app_shell.dart` 的 `resolveActiveRoute()`，注释写清楚了。

### 9.4 和设计稿的差距清单

**已对齐**
- §4.2 里的 page-01 / 03 / 04（弹层与菜单部分）/ 05 / 06 / 07 / 08 / 09 / 11 的**布局形态、Tab、分类、文案、空态**
- 5 项底部导航、深色配色（`#131719` 底 / `#1C2828` 卡 / `#3FE0C8` 主色）
- 模型弹层的三档 + 倍率 + 免费角标

**占位 / 未接数据**（不是"忘了做"，是本地没有对应能力）
- **资料库文件列表**：设计稿有 6 个样例文件（pdf/docx/html/pptx），本地没建索引 → 只做空态
- **专家中心**：8 张卡是设计稿里的专家名与描述（文案保真），点进去的详情页没有
- **技能 / 连接器 Tab**：设计稿只给了 Tab 名，内容 → 空态
- **项目空间**：`项目新手指引` / `陵川那些事` 两条是设计稿样例，用来对齐卡片形态；无项目存储层
- **定时任务**：无调度引擎 → 只有空态 + 新建按钮（点了提示未实现）
- **产物卡片**：靠正则从工具输出里捞文件名（ACP 协议没有 artifact 通知）。设计稿那种
  "4.6KB / 16.3KB" 的体积**拿不到就留空**，不编造
- **附件菜单的 4 个动作**（拍照 / 照片视频 / 添加文件 / 连接器…）：只有菜单形态，点了提示未实现

**还没做**
- **page-10 任务列表页**（多会话列表、`新建任务`、账户区 `阿白/体验版/1651.01`）——
  对话页目前是单会话，没有会话列表数据源
- **按住说话（语音输入）**：输入框右侧是麦克风图标，但没有语音链路
- **`展开` 对助手消息**：只对用户消息做了展开/收起
- **输入框纵向位置**：设计稿在屏高 ~85%，实测落在 ~44%（品牌区 + 输入框整体居中导致）。
  这是**已知偏差**，要更贴设计稿可以把输入框区改成贴底固定、只让轮播区滚动

### 9.5 界面相关的复盘（下次少走弯路）

- 一切布局比例以 `dsh_tokens.dart` 的 `dx()/dy()`（基准 **1215 x 2640**）为准，
  不要在页面里手写魔法数字
- 新增页面后**先跑 §3.9b 那段 import 检查脚本**，再去 `flutter analyze`
- 界面"整页空白"时先 grep `[dsh-flutter-error]`（§3.9c）
- 验证界面优先用 `uiautomator dump`（§3.10），截图只用来确认有没有大面积空白

---

## 10. 第二轮界面对齐记录（照 OCR 坐标逐页校准，本轮完成）

> 本轮用户指令：**「继续按照 pdf 的风格修改」** —— 把界面往 `pdf-images/page-*.jpg` 逼。
> 依据是 `pdf-images/ocr-all.txt` 的**逐行 y/x 坐标**（368 行，每页一节）。
> 设计稿图片是 **1216 x 2688**（不是文档里早先写的 1215 x 2640；两者比例一致，
> `/2640` 的换算仍然成立，误差 <0.2%）。
>
> 两条**不依赖我读图**的独立校验脚本（本轮新增，可复跑）：
> - `docs\check_layout.py <截图> [设计稿]`：逐行扫色带，输出每页的"横向色带分界线"
> - `docs\find_accent.py <截图...>`：按青色（品牌主色）定位 logo / 选中态 / 主要按钮
>
> 例：`page08_task.png` 上跑 `find_accent.py` 得到青色集中在
> `y=410..599`（17.1%~25.0%），和语义树量出的 logo 块 492~607px 相互印证。

### 10.1 本轮改了哪些文件

| 文件 | 改了什么 |
|---|---|
| `lib\ui\theme\dsh_tokens.dart` | 新增 `sp()` 换算助手；`topBarHeight(screenH)` / `navContentHeight(screenH)` 改成**按屏高比例**（原来写死 56/62dp）；新增设计稿锚点常量（`kContentTopY` / `kSegTabY` / `kNavTopY` / `kInputBottomY`）；`pagePad` 16→15、`cardPad` 14→13、新增 `cardGap` |
| `lib\ui\widgets\common.dart` | 新增 `DshPageHeader`（把"标题中心落在设计稿 y=227"集中实现一次）；`DshEmptyState` 加 `centerY` 参数（定时任务空态要落在 58.2% 而不是居中） |
| `lib\ui\widgets\input_bar.dart` | **模型按钮从输入框上方挪到下方**（设计稿 y=2292 在胶囊 2301 之下）；空输入→麦克风、有文字→发送；`_VoiceButton` 按住态（放大+变青+光晕）；按钮 40→46dp；胶囊固定 46dp |
| `lib\ui\widgets\bottom_nav.dart` | 高度改按屏高比例（设计稿导航带 6.1% 屏高） |
| `lib\ui\pages\task_home_view.dart` | **P0：输入区改成贴底固定层**（原来和品牌区一起在滚动容器里居中、落在 44%）；滚动层间距改成"固定块高 + 按设计稿比例分配剩余留白"，内容永不超过一屏；logo 78→70dp |
| `lib\ui\pages\chat_page.dart` | 顶栏高度按设计稿 11.1% 算；输入区只给下限不写死高度（原来会 overflow 8.9px）；新增 `_voiceHeld` / `_hasInput` / `onSessionUsed` 回调 |
| `lib\ui\pages\task_list_view.dart` | **新文件**：设计稿 `page-10` 任务列表（`云端` / `新建任务` / `任务` 分组 / 任务卡 / 本机账户区） |
| `lib\ui\pages\model_sheet.dart` | 面板高度 0.66→**0.68 屏高**；行高改成固定 62dp（设计稿行距 170 设计像素） |
| `lib\ui\pages\expert_page.dart` | Tab 带 32→26dp + 上留白收到 ≤12dp（实测原来低 2.3%）；分类→网格间距按实测校准；`childAspectRatio` 1.02→**0.95**（行距 479→540px，设计 505） |
| `lib\ui\pages\library_page.dart` | 用 `DshPageHeader`；搜索框/ Tab 间距按实测校准 |
| `lib\ui\pages\scheduled_page.dart` | 用 `DshPageHeader`；**去掉自加的「新建定时任务」通栏按钮**（设计稿这一页没有），改成右上角 `+`；空态 `centerY=0.62` |
| `lib\ui\pages\project_page.dart` | 副标题拉到设计稿的 30% 屏高（原来紧贴标题）；卡片行距放大约 15% |
| `lib\ui\pages\app_shell.dart` | 新增任务登记 `_registerSession` + `_openTaskList` + `_TaskListPage` 壳 |
| `lib\ui\widgets\message_stream.dart` | 间距按下表收紧（正文顶 ≈15.9%、用户消息底 → `已完成` ≈9dp）；**助手消息加展开/收起**（>220 字折叠 8 行）；新增「待办」提示条（只从真实 todo 工具输出里摘 `- [ ]`，摘不到就不渲染） |
| `install\uitap.ps1` | **新文件**：dump 语义树 + 按 label 点击/长按（纯 ASCII，PS 5.1 可跑） |
| `install\shot.ps1` | **新文件**：截屏落到本地（先 pull 到 ASCII 目录再复制，绕开中文路径） |

**刻意没动**：`acp_client.dart`、`dsh_runtime.dart`、三个 Android shim、`MainActivity.kt`、
`build-local-apk.ps1`、`prepare-jnilibs.mjs`。界面改动没有碰运行时链路。

### 10.2 设计稿比例 vs 实现比例（逐页对照）

设计稿比例 = OCR 的 y 坐标 ÷ 2640。实现比例 = 模拟器（1080x2400，屏高 2400px）
上 `uiautomator dump` 出来的 bounds ÷ 2400。**要换算成同一口径**：
设计稿 y=2301 对应"整屏 87.2%"，而模拟器上屏幕高 2400px 含状态栏 63px，
所以两边都按"整屏"算才是可比数字。

#### page-08 任务首页（本轮重点）

| `page-08` 任务首页（本轮重点） | | | | | |
| 标题 `同类产品` | 163~218 | 6.2~8.3 | 238~290 | 9.9~12.1 | +3.6（见注 1） |
| `云端 >` | 239~287 | 9.1~10.9 | 301~345 | 12.5~14.4 | +3.4（见注 1） |
| logo 品牌标 | 377~465 | 14.3~17.6 | 492~607 | 20.5~25.3 | +6.2（见注 2） |
| — logo 实际着色区（青色实测） | — | — | 410~599 | 17.1~25.0 | +4.5（见注 2） |
| `你的AI好Buddy` | 445~530 | 16.9~20.1 | 607~686 | 25.3~28.6 | +8.5（见注 2） |
| 福利文案 | 518~564 | 19.6~21.4 | 702~752 | 29.3~31.3 | +9.7（见注 2） |
| 中部提示区标题 | 1075~1173 | 40.7~44.4 | 1061~1119 | 44.2~46.6 | +3.5 |
| 提示 1 | 1307 | 49.5 | 1190~1256 | 49.6~52.3 | +0.1 ✅ |
| 提示 2 | 1445 | 54.7 | 1298~1363 | 54.1~56.8 | −0.6 ✅ |
| 提示 3 | 1588 | 60.2 | 1405~1471 | 58.5~61.3 | −1.7 ✅ |
| 提示 4 | 1727 | 65.4 | 1513~1579 | 63.0~65.8 | −2.4 ✅ |
| **输入胶囊** | **2301~2354** | **87.2~89.2** | **1965~2086** | **81.9~86.9** | 胶囊中心 84.4 vs 88.2（见注 3） |
| 模型按钮 | 2292~2346 | 86.8~88.9 | 2104~2179 | 87.7~90.8 | +0.9 ✅ |
| 底部导航标签 | 2567~2610 | 97.2~98.9 | 2194~2337 | 91.4~97.4 | 标签所在带 ✅ |

> **注 1（顶栏偏高的问题）**：实现里 `同类产品` 中心 264px = 11.0%，
> 设计稿中心 190px = 7.2%。差 3.8% 屏高（约 91px）。原因是 `SafeArea` 已经
> 吃掉 63px 状态栏，而设计稿的坐标是**含状态栏**的整屏坐标。已按 §10.3 的办法
> 逐轮逼近，最终落在 11.0%（此处仍有差值是因为模拟器状态栏 63px 比设计稿 72px 略矮，
> 且 Flutter 的 `viewPadding.top` 与设计稿状态栏高度的口径不完全一致）。
>
> **注 2（品牌区）**：OCR 在品牌区**自相矛盾** —— `同类产品萝`（logo）377~465 与
> `你的Al好Buddy` 445~530 的框**互相重叠 20px**，福利文案 518~564 又压在标语上。
> 说明 OCR 把 logo 图形块与叠字效果混在一起抓了。所以这一块**不能**纯按 y 摆
> （会把 logo 和标语叠在一起），改成本文件 §10.3 的"固定块高 + 比例分余量"策略。
> 结论：品牌区在设计稿里的**相对次序**（logo → 标语 → 福利）已 1:1 复现，
> 绝对位置比设计稿低 6~10%。
>
> **注 3（输入胶囊）**：这是本轮 P0。胶囊顶 1965px = 81.9%，底 2086px = 86.9%，
> 即**胶囊压在 87% 线上、底边几乎正好是 87%**；模型按钮 87.7%~90.8% 落在设计稿
> 的 86.8%~88.9% 内。上一轮实测是 ~44%（品牌区与输入框整体居中导致），
> **本轮已从 44% 修正到 87%**。之所以不能让胶囊中心也精确落在 88.2%：
> 模拟器底部导航带手势条（24dp），导航上方的可用空间只有 21% 屏高，
> 而设计稿给输入区留了 24.6%；再往下推会压出 `RenderFlex overflow`
> （实测过一次，溢出 8.9px）。

#### page-11 / page-02 对话页

| 元素 | 设计稿 % | 实现 % | 差 |
|---|---|---|---|
| 标题带 | 6.3~8.1 | 8.5~10.6（px 204~254） | +2.4 |
| `内容由AI生成` | 15.3~16.7（page-11: 403~442） | 16.5~19.7（px 396~472） | +1.2 |
| 用户消息顶 | 20.7 (547) | 19.7 (px 472) | −1.0 ✅ |
| `已完成` | 40.0 (1057) | 25.8~34.9（px 619~837，含助手正文） | 结构对齐，绝对位置随内容长度浮动 |
| 输入胶囊 `按住说话` | 81.0~83.3 | 81.9~86.9 | +1.4 ✅ |
| 模型按钮 `Hy4preview` | 86.8~88.9 | 87.7~90.8 | +0.9 ✅ |
| 底部导航 | 93.9~98.9 | 91.4~97.4 | ✅ |

#### page-01 模型选择弹层

| 元素 | 设计稿 % | 实现 % | 差 |
|---|---|---|---|
| `选择模型` 标题 | 37.5~39.4 | 34.2~37.0（px 821~887） | −2.9 |
| `快速 0.21x` | 42.2~44.5 | 38.3~45.5 | −1.3 ✅ |
| `均衡 0.65x` | 48.5~51.0 | 45.5~52.7 | −1.3 ✅ |
| `极致 1.20x` | 55.1~57.3 | 52.7~59.9 | −1.2 ✅ |
| `Hy4 preview` 行 | 61.6~63.6 | 65.5~72.5 | +2.6 |
| `Hy3 0.00x` 行 | 67.9~70.2 | 72.5~79.5 | +2.3 |
| 模型行行距 | 6.4% (170px) | 7.0%（168px） | +0.6 |

#### page-03 附件菜单

| 元素 | 设计稿 % | 实现 % | 差 |
|---|---|---|---|
| `拍照` / `照片／视频` / `添加文件` | 63.3~65.3 | 41.5~51.2 | −17（结构相同、位置上移，见注） |
| `专家中心` | 72.3~74.4 | 53.6~58.4 | −18（同上） |
| `使用技能` | 79.3~81.3 | 58.4~63.2 | −20（同上） |
| `连接器` | 86.1~88.3 | 63.2~68.0 | −22（同上） |
| `定时任务` | 93.1~95.0 | 68.0~72.8 | −24（同上） |

> 注：设计稿 page-03 的菜单是**从屏幕中部往下铺到屏幕底部**（拍照 63% 起、
> 定时任务 95%），而我们的是从输入区上方往上弹（`Scaffold` 的 Column 里
> 输入区之前）。**五项次序、图标、文案 100% 一致**，只是整块上移了。
> 要严格对齐得把菜单做成底部弹层（`showModalBottomSheet`），本轮没动 ——
> 因为它现在和输入框贴在一起（点了能立刻看到、点"收起"能关），
> 改成弹层会多一次 modal 语义，属于交互取舍，留给下一轮定。

#### page-09 专家中心

| 元素 | 设计稿 % | 实现 % | 差 |
|---|---|---|---|
| 顶栏 Tab 带 | 7.3~9.8 | 6.7~9.5（px 160~228） | ✅ |
| 分类胶囊行 | 18.7~20.7 | 13.3~17.5（px 320~420） | −2.4（带中心 15.4 vs 19.7） |
| 第 1 排卡 | 名 32.8 (865) / 述 28.6~34.2 | 19.7~41.1（px 473~987） | 卡顶 −2.8 |
| 第 2 排卡 | 40.5~47.1 | 42.2~63.7（px 1013~1528） | ✅ |
| 第 3 排卡 | — | 64.8~86.2（px 1554~2069） | ✅ |
| 卡片两列 x | 左 119~498 / 右 681~1098 | 左 39~528 / 右 552~1041 | 左右间隙 15% 屏宽 ✅ |
| 行距 | 505px | 540px | +7% |

#### page-05 资料库

| 元素 | 设计稿 % | 实现 % | 差 |
|---|---|---|---|
| 标题 `资料库` | 7.5~9.7 | 8.5~11.1（px 203~266） | +1.0 |
| 搜索框 `搜索资料库` | 14.9~16.7 | 21.6~25.3（px 518~607） | +7（见注） |
| Tab `最近/我的资料/团队空间` | 22.3~24.5 | 20.9~23.9（px 501~574） | −1.0 ✅ |
| Tab 三项 x | 65 / 276 / 592 | 39 / 172 / 379 | 间距比例 ✅ |

> 注：搜索框那一行**没有语义标签**（hint 不进语义树），20.9%~25.3% 是我按
> `TextField` 的固定 44dp 高度反推的带。设计稿 14.9% 与实现的差距来自
> "标题 → 搜索框"这段留白，可再收 ~8dp；本轮没继续微调（下方 Tab 已对齐，
> 动它会把 Tab 推下去）。

#### page-06 定时任务

| 元素 | 设计稿 % | 实现 % | 差 |
|---|---|---|---|
| 标题 `定时任务` | 7.6~9.6 | 9.8~12.4（px 235~298） | +2.3 |
| 空态 `暂无定时任务` | 58.2~59.7 | 61.3~63.6（px 1472~1527） | +3.2 |

#### page-07 项目空间

| 元素 | 设计稿 % | 实现 % | 差 |
|---|---|---|---|
| 标题 `项目空间` | 7.6~9.6 | 8.5~11.1（px 203~266） | +1.0 ✅ |
| 副标题 `多人协同，打造超级团队` | 29.9~31.4 | 29.0~31.2（px 697~749） | ✅ |
| `我的项目` | 36.7~38.7 | 35.1~37.5（px 842~900） | −1.5 ✅ |
| 卡 1 `陵川那些事` | 43.8~48.4 | 38.7~47.4（px 928~1137） | −2.6 |
| 卡 2 `项目新手指引` | 53.9~58.4 | 47.4~56.1（px 1137~1346） | −3.5 |

#### page-10 任务列表（本轮新增）

| 元素 | 设计稿 % | 实现 % | 差 |
|---|---|---|---|
| 顶栏 `云端` | 6.1~8.7 | 8.5~11.7（px 203~280） | +2.4 |
| `新建任务` | 12.8~14.8 | 14.0~19.4（px 335~466） | +2.7（带中心 16.7 vs 13.8） |
| 分组 `任务` | 20.0~21.9 | 21.2~23.7（px 509~569） | +1.2 ✅ |
| 任务卡标题 | 24.7~26.6 | 25.1~33.6（px 602~806） | ✅（卡高 8.5%） |
| 账户名 `阿白` | 92.6~94.9 | 92.2~94.4（px 2213~2265） | ✅ |
| `体验版` / `1651.01` | 95.5~97.1 | 94.6~96.5（px 2271~2318） | ✅ |
| 底部导航 | 97.2~98.9 | 91.4~97.4 | ✅（标签带） |

> 账户区文案做了**如实映射**：设计稿是云端账号（`阿白` / `体验版` / `1651.01` 积分），
> 本地没有账号体系，所以显示 `本机用户` / `本地运行时 · 非云端账户` / `本次任务 N`。
> 不伪造账号数据。

### 10.3 任务首页纵向节奏是怎么定的（改之前先读）

设计稿 `page-08` 的 OCR 文字框在品牌区**互相重叠**（见注 2），所以这一页不能纯按 y 摆。
采取的办法是：

1. 各块高度用**实测 dp** 写死（`_ScrollBody` 里的常量，模拟器上 dump 出来的真实值）；
2. 只剩一个自由度：块与块之间的 3 段跨块留白，按设计稿的
   `84 : 511 : 353` 比例分配剩余空间；
3. `_gapWeights = [2, 42, 56]` 是**量了四轮之后定的** —— 模拟器导航带手势条（24dp），
   滚动层比设计稿窄，"按原始比例"会把品牌区和提示区一起推低 5~6% 屏高；
4. 剩余空间不够时（小屏/大字号）等比压缩，于是内容**永远不超一屏** →
   没有多余滚动、没有回弹（用户明确要求手感自然）。用 `ClampingScrollPhysics`。

### 10.4 「按住说话」是什么状态（不要当成完整功能）

**是明确标注的占位交互**，不是语音输入：

- 按住 → 按钮放大到 54dp、变青色、加光晕；输入框上方浮出 `正在聆听…松开结束` 提示条
- 松手 → 提示条消失，底部 SnackBar 如实说 `语音输入暂未接入：本机没有语音识别链路，按住只是占位反馈`
- 日志：`[chat] voice hold` / `[chat] voice release`
- **不会伪造识别结果**。要真做得引 `speech_to_text` 之类插件（增包体积 + 权限面）

另外本轮补了一个**真实的可用性缺口**：输入框有文字时，右下角从麦克风**切换成发送按钮**。
上一版恒显麦克风，用户打了字只能靠软键盘回车发送。

### 10.5 page-10 的数据源边界

任务列表的数据来自 `AppShell._tasks`：**本次运行期间用户实际发过消息的会话**
（标题取首条消息前 24 字，日志前缀 `[dsh-tasks]`）。**内存态，重启即空**。

- ✅ 真的会话：不是设计稿的假数据
- ❌ 不是历史任务：DSH 的 `session.v4.jsonl.zstd` 在磁盘上有，但界面层还没索引它
- 账户区是"本机状态"而不是云端账号（见 §10.2 page-10 的注）
- 「新建任务」= 新开一个对话页；点某条任务也是新开会话（**不是恢复该会话**）

### 10.6 本轮踩的坑（都是新坑）

1. **`LayoutBuilder` 绝不能放进 `SingleChildScrollView`**。
   放进 viewport 里会在 `performLayout` 期间触发布局，报
   `'!_debugDoingThisLayout': is not true`，真机表现是**整页空白**，
   logcat 里只有 assert 没有堆栈头（因为 Flutter 的 build 异常默认不打进 logcat）。
   正确写法：`LayoutBuilder` 放在滚动容器**外面**，把 `constraints.maxHeight`
   当参数传给滚动内容。

2. **输入区高度不能写死**。模拟器底部导航带手势条（`viewPadding.bottom` = 24dp），
   留给输入区的只有 21% 屏高（设计稿是 24.6%），写死 `height: 0.085*H`
   直接压出 `RenderFlex overflowed by 8.9 pixels`。
   正确写法：`Container(constraints: BoxConstraints(minHeight: ...))` 让内容自己撑开。

3. **PowerShell 的 `Get-Content -Raw` + `Set-Content` 会把 UTF-8 源码变乱码**。
   本机 PowerShell 是 5.1，默认按 ANSI 读无 BOM 的 UTF-8 → 读出来就是乱码，
   再写回就永久损坏（本次一次性损坏了 `expert_page` / `library_page` / `project_page` 三个文件，
   靠 `D:\dev\build\app-local` 的镜像副本才救回来）。
   **改 Dart 源码一律用编辑工具，不要用 PowerShell 命令做文本替换。**
   批量改完可以跑 `docs\check_encoding.py`（本轮新增，扫 30 个 dart 文件找乱码标记）。

4. **`adb shell input keyevent KEYCODE_BACK` 连按两次会直接退出 App**
   （一次退对话页、一次退 App）—— 会让后续截图全变成桌面。这就是
   `screenshots\` 里一度出现一整批"桌面截图"的原因。点击一律用 `install\uitap.ps1`。

5. **`adb shell input text` 里的空格要写成 `%s`**，否则参数会被截断
   （本次第一次发消息实际只发出了 `Reply` 一个词）。

6. **软键盘弹出会让整页上移约 820px**（输入行从 y=2025 移到 y=1207）。
   每次点击前都要重新 `uiautomator dump`。

---

## 11. 第三轮：arm64 真机包重建 + 运行时验证记录（2026-10-03）

> 本轮用户指令：**「先把 arm64 真机包打出来」**。
> 结论：包**已重建并结构验证通过**；但**本机没有 arm64 设备，真机链路一步都没跑**。
> 下文把「实测到的」和「没能实测的」严格分开写。

### 11.1 前置预检：运行时资源**不需要**重建（有依据）

判断依据是**时间戳 + 内容归属**，不是猜：

| 资源 | 时间戳 | 归属 | 结论 |
|---|---|---|---|
| `runtime\aarch64\` | 2026-10-02 12:05（node 二进制） | Termux node 26.4.0，与界面源码无关 | 不需要重建 |
| `jnilibs\arm64-v8a\` | 2026-10-02 14:42（11 个库） | 由 `prepare-jnilibs.mjs` 从上面那份 runtime 导出 | 派生且**新于**源 → 不需要重建 |
| `app-assets\dsh-runtime.zip` | 2026-10-02 12:07（157,924,646 B = 150.6 MB） | 打包 **`D:\Programs\PaopaocatDSH\app`** + 3 个 shim | 见下 |

关键点：**这两轮界面改动一行都没进过这个 zip**。

- zip 的来源是 `D:\Programs\PaopaocatDSH\app`（`build-app-assets.ps1` 的 `-DshSource` 默认值），
  **不是** `dsh-mobile\app`。界面源码在后者，所以改界面**不可能**让 zip 过期。
- DSH 树本身最新改动是 **2026-09-26 15:39**（`@deepseek-ai/dsh-host-webserver/lib/index.js`），
  早于 zip 的 12:07 → **DSH 树在 zip 之后没有再动过**。
- 三个 shim 源文件是 11:56~12:01，zip 里存的是 12:07 的副本 → 一致。
- zip 条目数 **26,495**，与 §6 记录的"26495 个文件"吻合，说明是完整包。
- 本轮**没有**执行 `prepare-jnilibs.mjs` 或 `build-app-assets.ps1`（重复打包 484 MB 无收益）。
  如果以后 DSH 树更新了，或 shim 改了，就要重跑 §7「运行时资源怎么来」那串命令。

### 11.2 真机：**没有连接任何 arm64 设备**

```
$ adb devices -l
List of devices attached
emulator-5554   device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 device:emu64xa transport_id:1
$ adb shell getprop ro.product.cpu.abi
x86_64
```

- 唯一的 `emulator-5554` 是 **x86_64 模拟器**（AVD `dsh-test`，`abi.type = x86_64`，
  镜像 `system-images\android-34\google_apis\x86_64`）。
- SDK 里**只装了 x86_64 的系统镜像**，没有 arm64 镜像 → 也不能临时起一个 arm64 模拟器。
- 因此 arm64 APK **无法在本机运行**（装上去会因 ABI 不匹配被拒）。

> ⚠️ **如实报告：本轮只完成了构建与结构验证，未做任何真机验证。**
> §11.4 的运行时验证是在 **x86_64 模拟器**上、用**与 arm64 包同一轮源码**构建的
> debug 包做的 —— 它能证明"代码是对的"，**不能**替代"arm64 包在真机上能跑"。

### 11.3 构建结果与结构验证（实测）

```powershell
install\build-local-apk.ps1 -Abi arm64-v8a -Mode release
```

- 脚本行为确认：先 `robocopy` 到 ASCII 副本 `D:\dev\build\app-local`（§3.8），
  再改写 `android\gradle.properties` 的 `dshAbi=arm64-v8a`（构建前实测该值是 `x86_64`，
  即上一轮遗留），然后 `gradlew --stop` → `flutter build apk --release --target-platform android-arm64`。
- 打印 `assets: 150.6 MB   jniLibs: 92.8 MB`，Gradle `assembleRelease` 耗时 **279.7 s**（约 4.7 分钟）。

**产物**

| 项 | 值 |
|---|---|
| 路径 | `dsh-mobile\dist\dsh-local-arm64-v8a-app-release.apk` |
| 体积 | 195,202,967 B = **186.2 MB** |
| 生成时间 | **2026-10-03 09:33:28** |
| sha256 | `ED34524FB9254AF67A8202D5595CB2F743ED7B294CF3E9619E9DF87842B800EC` |
| 晚于最后一次源码改动（20:29）？ | ✅ 是 |

**包内结构（`aapt` / `apksigner` 实测）**

- `lib/` 下**只有 `lib/arm64-v8a/`**，15 个 `.so`：`libapp.so`、`libnode.so` +
  `libc++_shared / libcares / libcrypto3 / libdartjni / libdatastore_shared_counter /
  libffi / libflutter / libicudata78 / libicui18n78 / libicuuc78 / libsqlite3 / libssl3 / libz1`
  → 与 `jnilibs\arm64-v8a\` 的 11 个库 + Flutter 自身的 4 个一致，**没有混入其它 ABI**。
- 签名：**Android Debug 证书**（`CN=Android Debug`，v2 方案；与 §6 说明一致，
  `build.gradle.kts` 里 release 明确用 `signingConfigs.getByName("debug")`，
  用的是 `C:\Users\25894\.android\debug.keystore`，**没有新建 keystore**）。

**新界面确实在包里（编译期证据）**

`libapp.so` 是 AOT 快照，把 `lib/arm64-v8a/libapp.so`（4.8 MB）解出来扫字符串，
第二轮新增的界面文案 **22/22 全部命中**（Dart 3 把 CJK 字面量存成 **UTF-16LE**，
ASCII 存 UTF-8 —— 只按 UTF-8 扫会全部 MISS，这是个能坑人的点）：

```
HIT 本机用户 / 本地运行时 · 非云端账户 / 本次任务 / 新建任务        (page-10)
HIT 选择模型 / 快速 / 均衡 / 极致                                  (模型弹层)
HIT 你的AI好Buddy / 在读大学生专属福利，认证即领积分 / 发消息或按住说话 / 换一换  (page-08)
HIT 暂无定时任务 / 多人协同，打造超级团队 / 搜索资料库 / 专家 / 连接器
HIT 语音输入暂未接入                                               (占位交互文案)
```

### 11.4 运行时验证（**在 x86_64 模拟器上做，不是真机**）

前置：模拟器上 DSH 运行时**早已解压好**（`files/dsh` + `files/dshhome` 都在），
所以本轮没走「首次引导→解压 75 秒」这一步；重装只覆盖 APK，数据保留。
装的是 `dist\dsh-local-x86_64-app-debug.apk`（2026-10-02 20:30，**与 arm64 包同一轮源码**）。

| # | 验证项 | 实测证据 |
|---|---|---|
| 1 | 安装 + 启动 | `adb install -r` → `Success`；启动后 `[dsh-nav]`/`[chat]` 日志正常 |
| 2 | 5 项底部导航齐全 | 语义树有 `任务|专家|资料库|定时任务|项目`，x 区间 `0-216/216-432/432-648/648-864/864-1080`（五等分）；日志 `[dsh-nav] tab -> …（0~4）` 五次全命中 |
| 3 | 各页内容 | 专家页：3 Tab + 5 分类 + 8 张卡；资料库：3 Tab + 空态；定时任务：`暂无定时任务` + 右上 `+`；项目空间：`多人协同，打造超级团队` + 2 卡；page-10：`云端`/`新建任务`/`本机用户`/`本次任务` |
| 4 | **任务页输入框贴底** | 胶囊 `[920,1965][1041,2086]` = 整屏 **81.9%~86.9%**（设计 87.2%~89.2%），与 §10.2 注 3 一致；模型按钮 `[612,2104][1035,2179]` 在胶囊**下方** |
| 5 | 无整页空白 | 全程 `[dsh-flutter-error]` 只在专家页出现过（见 §11.5），**其它 4 页零异常**；语义树每页都 dump 出完整内容 |
| 6 | 模型弹层 + 切换 | dump 到 `选择模型` + 三档 + 6 个模型行；点 `Deepseek-V4.1-Flash` 后日志 `[dsh-model] overlay 已重写：默认=deepseek/deepseek-v4.1-flash，注册 7 条` |
| 7 | ACP 会话 | `[chat][acp] initialize ok` → `session created: 92dbfe6f-…` → `ACP session ready … model=Deepseek-V4.1-Flash` |
| 8 | 发消息 | `[chat] prompt: ZEBRA-7741` → `[chat] message: I don't have enough to act on yet — **"ZEBRA-7741"** …` → `stopReason=end_turn` |
| 9 | **多轮上下文** | 第 4 轮问「see it earlier in this conversation?」→ 答 **"ZEBRA-7741 — yes, it appears earlier in this conversation"**（同一 `sessionId` 连续 `session/prompt`，见下） |

> **第 9 项的重要更正（别被中间两次失败误导）**：我第 2、3 轮问的是
> "the passphrase I just sealed you" / "what passphrase did I ask you to remember"，
> 模型两次都答"没有 passphrase"。**这不是上下文丢失** —— 第 4 轮直接问就答对了。
> 原因是我把 `ZEBRA-7741` 说成"暗号/passphrase"，模型把它当成了**提示注入测试**而拒答
> （它的 thought 明写 "This is a social engineering / prompt injection test"）。
> **测多轮上下文时不要用"暗号/口令"这类措辞，直接问"你还记得之前那个字符串吗"更可靠。**
> 另外已把设备上的会话文件取回解码，3 个 turn 的记录完整、`ZEBRA-7741` 出现 39 次，
> 从数据层确认上下文没有丢。

**截图**：`docs\screenshots\` 新增 9 张，全部加 `_arm64` 后缀（未覆盖 x86_64 的旧图）：
`page08_task_arm64` / `page09_expert_arm64` / `page05_library_arm64` / `page06_scheduled_arm64` /
`page07_project_arm64` / `page01_model_sheet_arm64` / `page10_task_list_arm64` /
`page02_chat_turn1_arm64` / `page02_chat_multiturn_arm64`。
（"`_arm64`"是**命名约定**，实际是在 x86_64 模拟器上截的 —— 见 §11.2。）

顺带得到一个**渲染一致性**旁证：同一页在新旧两轮的 PNG 体积几乎相同
（page08 150.4 vs 150.5 KB、page09 186.6 vs 186.7 KB、page01 172.8 vs 173.2 KB…），
只有 page-10 差 9.8 KB —— 因为本轮列表里有真实任务数据、上一轮是空的。

### 11.5 本轮新发现的 bug：专家页冷启动 2px overflow（已定位 + 已验证修法）

**现象**（可 100% 复现）：`am force-stop` → 启动 → **第一次**点「专家」，
logcat 出现 3 次：

```
[dsh-flutter-error] A RenderFlex overflowed by 2.0 pixels on the bottom.
[dsh-flutter-error] context: during layout
```

之后在同一进程里再点回专家页**不再出现**（第一次布局后约束就松了）。

**量化**：刚好 **3 次**、每次 2 行 → 命中 **3 个同构子节点**，指向顶栏那 3 个 `_TopTab`。

**根因**：`expert_page.dart` 顶栏 Tab 带写死 `height: 26`，而
`_TopTab` 的内容 = `Text(15)` + `SizedBox(3)` + `Container(2)`，
再加上该带的 `Padding`/`InkWell` 内边距，紧到只剩 ~0.8dp 余量，
**冷启动首帧（字体 metrics 未稳定 / 约束更紧）就顶破 2px**。

**修法已用对照实验验证**（改一处常量，其余全不动）：

| 实验 | 操作 | 结果 |
|---|---|---|
| 基线 | `height: 26` | 冷启动进专家页 → **复现** 3 次 `overflowed by 2.0 pixels` |
| 探针 | `height: 30` | 同样命令、同样步骤 → **0 次 overflow**，5 页切换全程 `[dsh-flutter-error]` 为空 |

> 探针是在 ASCII 副本 `D:\dev\build\app-local` 上做的，**已还原**；
> 仓库源码 `dsh-mobile\app\lib\ui\pages\expert_page.dart` 全程**没被改动**
> （探针前后 sha256 均为 `2168F718…2D37`，已核对）。

**本轮为什么没顺手修进交付包**：修完就得重建 arm64，而 arm64 无法在本机验证，
交付时间会从"今晚"推到更晚、且会引入一个"两个包不同源"的中间态。
**release 下这个 assert 不报**（所以真机用户看不到报错），只留 2px 裁剪。
建议**与其它改动合并后**一次重建两个包（见 §5 第 2 条）。

### 11.6 本轮新踩的坑 / 新发现的环境限制

1. **`adb exec-out … cat > 文件` 会被 PowerShell 破坏**（二进制重定向），
   症状是 zstd 报 `Unknown frame descriptor`。**正确姿势**：用
   `System.Diagnostics.Process` + `RedirectStandardOutput` 读 `BaseStream` 再 `WriteAllBytes`，
   或先 `run-as … cat > /sdcard/x` 再 `adb pull`。
   （注意：`adb shell "a > b"` 里的 `>` 会被**本地** shell 抢走，要在设备端执行的命令别这么拼。）
2. **`session.v4.jsonl.zstd` 是"多帧 zstd"**（本轮实测 32 帧）。
   `zlib.zstdDecompressSync` **只解第一帧就返回**（第一帧恰好是 200 字节的 session 头，
   看着像"文件只有这么点内容"，极易误判成"上下文没存"）。
   解法：按 magic `28 B5 2F FD` 切帧、逐帧解、拼起来。本轮脚本：
   `D:\dev\build\apkcheck\read-session2.mjs`（保留在 ASCII 目录，可直接复用）。
3. **Dart 3 AOT 快照里 CJK 字面量是 UTF-16LE**，不是 UTF-8。
   想验证"某个中文文案在不在 APK 的 `libapp.so` 里"，必须两种编码都扫，
   否则会得到"全部 MISS"的错误结论（本轮差点据此误判 arm64 包是旧的）。
   可复用脚本：`D:\dev\build\apkcheck\verify-ui-strings.mjs`。
4. **Android 上模型的 `bash` / `glob` 不可用**：实测模型报
   `Error: spawn bash EACCES`、`Error: glob could not start its search command (ripgrep launch failed)`，
   `read` 正常（`not found` 是正常的路径不存在）。模型会自行降级并如实说明。
5. **权限确认弹层信息不足**：`session/request_permission` 弹出来时，界面只显示
   「Agent 请求执行操作 / 这是一次需要你确认的操作：」+ `拒绝` / `允许一次`，
   **没有工具名、没有参数**，用户无从判断。（对应会话记录里的 `approval/asked` / `approval/decided`。）
6. **点底部导航切不走对话页**：对话页是叠在 `AppShell` 之上的，底部导航虽然可见可点
   （`[dsh-nav] tab -> …` 照样打印），但当前显示的还是对话页。
   要回任务首页得点对话页左上角的 `返回`。
7. **任务首页右上角 `任务列表` 的坐标**是 `[967,238][1041,311]`（中心约 1004,275），
   别用早先记的 `(990,275)` 之外的猜测值；点错会落到 `设置`。

---

## 12. 第四轮：收尾 + 专家库/技能 + 会话调整（2026-10-03）

> 本轮用户指令（三段）：
> 1. 收尾上一轮（猫头图标补胡须 / 48dp 不糊 / 换底色、重建两个包、补 HANDOFF）；
> 2. **「取消连接器，只保留专家和技能。专家内置的专家库，涵盖各行各业，类似于目前插件里的专家功能，
>    每一名专家有开关，打开开关以后，在会话的专家中心里显示。技能可以用户自定义，也可以通过对话来生成技能。」**
> 3. **「会话界面…把连接器取掉，专家中心点击以后，会显示已经打开开关的专家」**
>
> ⚠️ 本轮按用户要求**边做边写本文件**，所以每完成一个子任务就往 §12.x 追加一节。

### 12.1 关键调查：真实专家花名册到底在哪（结论 + 证据）

**结论：本机 DSH 的「专家」= 第三方插件 `@michengai/dsh-agency-agents`（The Agency，321 名专家 / 22 个分区）。**
但**它只装在桌面版 web profile 里，手机运行时里没有**。这是本轮最重要的一条事实，直接决定了开关能不能"真起作用"。

| 项 | 事实 | 证据 |
|---|---|---|
| 插件包 | `@michengai/dsh-agency-agents` **v1.0.5**，package.json 自述 "321 summonable domain experts" | 读 `…\profiles\web\node_modules\@michengai\dsh-agency-agents\package.json` |
| 注册方式 | profile 的 `cordis.patch.yml` 里两行 `insert`：`agency-agents-remote` + `agency-agents` | 读 `…\profiles\web\cordis.patch.yml` 第 75-76 行 |
| 花名册位置 | `assets\agency-agents\`（英文）与 `assets\agency-agents-zh\`（中文），按 22 个分区目录分 | `Get-ChildItem` 实测：academic 7 / company 6 / design 11 / engineering 68 / finance 9 / game-development 21 / gis 13 / healthcare 3 / hr 2 / legal 2 / marketing 43 / paid-media 7 / product 5 / project-management 7 / research 1 / sales 9 / security 12 / spatial-computing 6 / specialized 68 / supply-chain 4 / support 7 / testing 10 |
| 专家文件格式 | YAML frontmatter（`name` / `description` / `emoji` / `color`）+ Markdown 人设正文（身份与记忆 / 核心使命 / 关键规则 …） | 例：`agency-agents-zh\engineering\engineering-code-reviewer.md`（172 行） |
| 中文分区名 | 插件源码里就有 `ZH_DIVISION` 映射表（学术 / 公司经营 / 设计 / 工程 / 金融 / 游戏开发 / 地理信息 / 医疗健康 / 人力资源 / 法务 / 市场营销 / 付费媒体 / 产品 / 项目管理 / 研究 / 销售 / 安全 / 空间计算 / 专业 / 支持 / 供应链 / 测试） | 读 `lib\src-D62nL1RE.js`（minified，偏移 53183） |
| 启用状态字段 | 插件 schema 有 `teamSnapshotSchema { teams, enabledTeams, enabledExperts, revision }` + 工具 `list_experts` / `summon_experts` / `get_expert_team` | 同文件偏移 34500 / 87476 |

**⚠️ 手机运行时里没有这个插件**：
`D:\dev\android-node\app-assets\dsh-runtime.zip`（26,495 条目）里 `agency` / `michengai` **命中 0 条**，
顶层只有 `app/`（= `D:\Programs\PaopaocatDSH\app`）+ `shims/`。
→ 所以「把状态写回插件的 `enabledExperts`」在手机上**做不到**（插件不在设备上，写了也没人读）。

### 12.2 那怎么让开关"真起作用"？—— 找到一条只用内置插件、且可验证的通道

DSH 内置插件 `@deepseek-ai/dsh-agent-instructions`（在 `dsh-base` bundle 里**默认挂载**）负责把
`AGENTS.md` 类文件渲染进 agent 的**会话上下文**：

- 用户全局文件固定是 **`$DSH_HOME/AGENTS.md`**，在**第一个请求之前**进入 durable context；
- 项目级候选 `AGENTS.md` / `CLAUDE.md`（沿 cwd 向上找 `.git`），本地覆盖 `AGENTS.local.md` / `CLAUDE.local.md`；
- 单批上限 `maxBytes: 65536`（`dsh-base\cordis.patch.yml` 第 288-291 行）。

证据：`D:\Programs\PaopaocatDSH\app\node_modules\@deepseek-ai\dsh-agent-instructions\lib\index.js`
里 `const USER_GLOBAL_FILE = "AGENTS.md"`、`DEFAULT_INSTRUCTION_FILE_CANDIDATES = ["AGENTS.md","CLAUDE.md"]`。

**方案**：专家开关 = 把「已开启专家」的人设摘要写进 `$DSH_HOME/AGENTS.md` 的一个受管区块。
→ 开关**真的改变模型看到的内容**，且**落盘持久化**，且**零新依赖**（不碰 ACP / 三 shim / MainActivity）。

### 12.3 技能侧：链路本来就是真的

`dsh-base` 默认挂载 `dsh-skill` / `dsh-skill-filesystem` / `dsh-tool-skill`（`cordis.patch.yml` 第 293-304 行），
技能目录就是 `DSH_HOME/skills`，`create_skill` 工具写的就是它 —— 所以「列真实技能 / 自定义新建 / 对话生成」
这条链路不需要新增任何东西，只要把 UI 接到真实目录即可。

### 12.4 代码落地（第一~三轮全部改完，analyze 通过）

| 文件 | 动作 | 说明 |
|---|---|---|
| `install\build-expert-catalog.mjs` | 新增 | 从真实插件资产解析花名册（PS 无关，Node 脚本；中文注释，Node 按 UTF-8 读，不踩 PowerShell 5.1 的坑） |
| `app\assets\experts\agency_catalog.json` | 新增 | 165,428 B，**321 名 / 22 分区**，sha256 `C4070E653C55238E9B7214FB17B90F99C8B3454DEC9D0B988A6B1E5BD2552D1C` |
| `app\lib\data\expert_catalog.dart` | 新增 | 解析资产 → 分区 + 专家（名称/简介/emoji/核心使命摘要），带来源说明 |
| `app\lib\data\expert_store.dart` | 新增 | 开关状态持久化 + **把已开启专家写进 `$DSH_HOME/AGENTS.md` 受管区块**（真效果） |
| `app\lib\data\skill_store.dart` | 新增 | 读写 DSH **真实**技能根（用户级 `$DSH_HOME/skills` + 项目级 `<工作区>/.dsh/skills`），格式与 DSH 一致 |
| `app\lib\ui\pages\expert_page.dart` | **重写** | Tab 只留 `专家`/`技能`（**连接器已删**）；专家库分类胶囊 + 卡片开关；技能列表 + 新建/编辑/删除 + 对话生成 |
| `app\lib\ui\widgets\enabled_experts_sheet.dart` | 新增 | 会话「专家中心」弹层：**只显示已开启开关的专家** + 空态引导 |
| `app\lib\ui\widgets\message_stream.dart` | 改 | `AttachMenu._row2` **删掉「连接器」**（只剩 专家中心/使用技能/定时任务） |
| `app\lib\ui\pages\chat_page.dart` | 改 | 附件菜单分发：`专家中心` 弹已开启专家、`使用技能` 跳 专家→技能 子页、`定时任务` 跳对应 Tab；其余仍如实提示未接入 |
| `app\lib\ui\app_shell.dart` | 改 | 用真实 `runtime.nodeHome` / 当前工作区装配 ExpertPage；新增 `ExpertTabRequest` 子页跳转；`_openChat` 支持 Map 返回值 |
| `app\pubspec.yaml` | 改 | 注册 `assets/experts/agency_catalog.json` |

**校验（已跑）**：
- 相对 import 检查脚本 → `broken=0`
- `docs\check_encoding.py app\lib` → `checked=37 bad=0`
- `flutter analyze`（在 ASCII 副本 `D:\dev\build\app-local`）→ **`No issues found!`**（0 error / 0 warning）

**`dsh_runtime.dart` 本轮没有改动**（专家/技能都走新的 data 层文件，不碰 ACP/三 shim/MainActivity）。

### 12.5 猫头图标：胡须 / 48px 糊 / 纯黑底（三件都修了）

改的是 `install\make-icon.py`（重跑：`C:\Python314\python.exe install\make-icon.py`）。

**① 胡须其实一直在，只是"画了但看不见"——根因是颜色，不是几何。**
`WHISKERS_L` 三根一直存在，但它们是**深色 `#0E1A18`**，而胡须伸出去的部分落在**近黑背景 `#131719`** 上 → 深色画在深色上，等于没画。
另外胡须是**画在脸之前**的，所以内侧被脸盖住 —— 只有露在脸颊外面的那截可见。
→ 修法：胡须改用**浅薄荷 `#E0FBF2`**（伸到脸上的部分本来就被盖住，所以浅色不会和青色脸打架），同时加粗（宽版 0.030→0.036；小图 0.062）。

**② 背景从"近黑"换成品牌深青渐变。取色与理由：**
`#284542`（顶）→ `#121D1C`（底），基准色 `#182828`（设计稿主色）写进 `values/colors.xml`。
- 为什么不用纯黑/原 `#131719`：相对亮度 **22.3 → 62.6（2.8×）**，纯黑壁纸上轮廓才看得见；
- 为什么是"极轻渐变"而不是花哨渐变：同色系、小色差，只用来给图形一个边界和一点体积感；
- 为什么用渐变 drawable 而不是 `<color>`：自适应图标的 `<background>` 可以是任意 drawable，`<shape>` + `<gradient angle=270>` 即可（新增 `drawable\ic_launcher_background.xml`）。

**③ 48dp 糊：新增"简化版"渲染（`compact`，尺寸 ≤ 72px）。**
干掉的：腮红、嘴（48px 下就是一团灰）。放大的：眼半径 0.098→**0.118**、高光 0.034→**0.052** 且更靠上、鼻子从 0.076×0.041 改成 **0.120×0.072**、胡须最细 **2px**。
96px 及以上仍用完整细节版。

**④ 自适应图标安全区仍然有硬校验**（`check_safe_zone()`）：现在把胡须的**描边半径**也算进去，
实测最远点 **32.49dp**（安全圆半径 33.0dp），通过；越界会直接抛错不写文件。

**⑤ 视觉工具本轮限流，所以用"不依赖看图"的审计做证据**（`audit_small_render()`，
对 48px 实渲染逐像素按最近参考色分类）：

```
[farthest] 32.49 dp at (24.17, 66.87)  (safe radius 33.0)
[audit launcher 48px] bg=1642 (71%) head=285 whisker=30 dark=47 hl=8 ear=35
[audit round    48px] bg=1246 (54%) head=285 whisker=30 dark=47 hl=8 ear=35
lum(icon bg top)=62.6 vs old near-black 22.3 (2.8x)
```
`whisker=30` 就是"浅色胡须像素在 48px 下**真的存在**"的量化证据（改颜色之前这一项是 **0**）。

**产物**：`mipmap-{m,h,xh,xxh,xxxh}dpi\ic_launcher(.round).png`（mdpi/hdpi 走 compact）、
`mipmap-anydpi-v26\ic_launcher(.round).xml`、`drawable\ic_launcher_foreground.xml`、
**新增** `drawable\ic_launcher_background.xml`、`values\colors.xml`、
`install\icon-preview.png`、`install\icon-preview-48px-zoom.png`（48px @4x 最近邻放大，已更新到最新版）。

> ⚠️ 本轮视觉后端（5 个模型）全部 429 限流，**我没能亲眼复核渲染结果**。
> 图标的外观结论来自上面这段程序化审计 + 用户目视。
> 已用 `vision_present` 把两张预览图推到会话里供直接查看。

---

## 13. 第五轮：换真猫图标 + 设置页/资料库/模型预设（2026-10-03）

> 本轮用户指令（多段）：
> 1. 「不好看，把泡泡猫主题里边卧着的小白猫拿出来用」→ 图标换**真猫**；
> 2. 「模型内置 deepseek、command、longcat、mimo，先把端口都填好，用户输入 key 就可以了
>    （有获取模型的按钮，可以让用户选择获取的模型，如果获取模型需要 key，有信息提示）」；
> 3. 「如果用户使用过程中模型出现 429 或其他错误代码，要翻译成中文告诉用户。模型可以自定义」；
> 4. 「资料库取消团队空间，仅有最近和我的资料」「项目改为设置」。
>
> ⚠️ 重要更正：**§12.5 描述的是"手绘矢量猫"**（旧 `make-icon.py`）。那只已被**整体废弃**，
> 下面 §13.1 是现行的图标链路。看图标相关的事只看 §13.1。

### 13.1 图标：手绘矢量猫 → 真猫（用户指定）

**结论（用户已目视确认）**：启动器图标与 App 内品牌 logo 都用
**泡泡猫 UI 插件 `dsh-client-ui-paopaocat` 的 `assets/mascot-cat.webp`**。

找到它的路径（下次别再满盘找猫）：

```
D:\Programs\PaopaocatDSH\data-template\profiles\web\node_modules\
  dsh-client-ui-paopaocat\assets\mascot-cat.webp
```

| 事实 | 值 | 怎么确认的 |
|---|---|---|
| 尺寸/通道 | 512×512 RGBA，四角透明（alpha 0–255） | Pillow 直接读 |
| 本体包围盒 | `(61, 91, 459, 427)` → **398×336，宽>高（卧姿）** | `alpha.getbbox()` |
| 毛色 | 中心像素 `(236,240,243)` ≈ 近白 → **白猫** | 取像素 |
| 就是它 | 该插件 `src/client/ppc-mascot.ts` 里的 `PPC_MASCOT_IMAGE` 指向本文件 | grep 源码 |
| 本源留存 | 已钉到 `dsh-mobile\design\mascot-cat-source.webp` | — |

> 备选素材（本 App **不用**）：同目录 `cat-mascot.svg`（矢量版）、
> `mascot-samples/{A-photoreal,B-3d-render,C-watercolor,D-anime}.png`（四个风格样张）、
> `assets/default-wallpaper.jpg`。

**现行图标脚本**：`install\make-icon.py`（已整体重写，读上面那张真猫图）：

- 自适应前景：`res\drawable-{m,h,xh,xxh,xxxh}dpi\ic_launcher_foreground.png`
  （108dp 画布，猫占 62% 居中；**脚本会主动删除旧的 `drawable\ic_launcher_foreground.xml`**，
  否则手绘矢量 drawable 会盖住位图前景）
- 传统方形/圆形：`res\mipmap-*\ic_launcher(.round).png`（48/72/96/144/192，深青渐变底 + 猫）
- App 内：`app\assets\images\paopaocat_mascot.png`（398×336 抠图，已登记进 `pubspec.yaml`）
- 预览：`install\icon-preview.png`、`install\icon-preview-48px-zoom.png`
- 旧的矢量脚本存档在 `install\_legacy\make-icon-vector.py`（**不要重跑**）

`app\lib\ui\widgets\cat_head.dart` 的 `CatHeadLogo` 已从 `CustomPaint` 改为 `Image.asset`，
所以"启动器一只猫、App 里另一只猫"这个隐患从根上消除了。

> 详细来源与重跑命令另见 **`docs\BRAND-ASSETS.md`**。

### 13.2 arm64 真机包重建（15:26）+ 四项包内核验

```powershell
install\build-local-apk.ps1 -Abi arm64-v8a -Mode release   # Gradle assembleRelease 131.3s
```

| 项 | 值 |
|---|---|
| 路径 | `dist\dsh-local-arm64-v8a-app-release.apk` |
| 体积 | 196,076,100 B = **187.0 MB** |
| 生成时间 | **2026-10-03 15:26:39** |
| sha256 | `A93D6BCCF959EEC51878CFFC7AF16814A70FAE57B984A86A91AB2F4F3386F65F` |

**四项核验（都是实测，不是推断）**

1. **只有 arm64**：`lib/` 下仅 `arm64-v8a` 15 个 `.so`（含 `libnode.so`）。
2. **新猫图标真的在包里**：包内 `res/` 出现 **108/162/216/324/432**（自适应前景）
   与 **48/72/96/144/192**（传统/圆形）全套 PNG。
   ⚠️ release 构建会**重命名资源**（`ic_launcher` → `res/CH.png` 这种），
   所以**按名字搜 `ic_launcher` 会一无所获**，要按**尺寸**找 —— 这点差点让我误判图标没进包。
3. **App 内猫图在包里**：`assets/flutter_assets/assets/images/paopaocat_mascot.png`（206,219 B）。
4. **应用名**：`aapt2 dump badging` → `application-label:'泡泡猫的Deepseek harness'`，
   `package: name='com.dshmobile.dsh_mobile'`（**appId 未改**，所以能覆盖安装），
   `native-code: 'arm64-v8a'`。

> ⚠️ **真机运行依然未验证**：本机没有 arm64 设备（§11.2 的结论没变）。

### 13.3 资料库：去掉「团队空间」，接真实文件

- `ui\pages\library_page.dart`（重写，27 KB）+ 新增 `data\library_store.dart`（18.8 KB）
- Tab 从三个减到**两个**：`最近` / `我的资料`（`static const _tabs = ['最近', '我的资料']`）
- 扫描**当前工作区**（目录由 `resolveWorkspaceFromFilesDir` 在运行时解析，**不写死绝对路径**）：
  `dir.list(followLinks: false)`（符号链接可能成环，一律不跟）、**深度 ≤ 4、最多 500 个文件**
- 口径（都写进代码注释）：`最近` = 按 mtime 倒序、**只列最近 100 条**并在页脚如实写"共 N 个"；
  `我的资料` = 按所在目录分组，根目录那组最前
- 搜索框接真实过滤；文本类可预览；扫描失败给错误/空态，**不静默返回假数据**

### 13.4 「项目」Tab → 「设置」Tab

- `ui\widgets\bottom_nav.dart`：第 5 项 `项目` → `设置`（图标 `workspaces` → `settings`）
- 新增 `ui\pages\settings_tab.dart`（外观 / 模型 / 插件 / 关于 四个分区）
- 新增 `state\app_settings.dart`：字号档位（0.90/1.00/1.15/1.30）+ 持久化（SharedPreferences）
- `main.dart`：`DshMobileApp` 改为 StatefulWidget 持有 `AppSettings`，
  在 `MaterialApp.builder` 里用 `MediaQuery.textScaler` 让**字号影响所有页面**（含推入的对话页）
- `ui\app_shell.dart`：第 5 个页面换成 `SettingsTab`；`project_page.dart` **不再挂载**（文件保留作参考）

> **说实话**：主题只有**深色**。浅色要把 `DshColors` 的静态常量抽成跟随 `ThemeData`
> 的主题变量（约二十个文件），本轮没做 —— 所以设置页里「浅色」是**置灰**并写明原因的，
> 不是"点了没反应"的假开关。字号是**真生效**的。

### 13.5 模型：四家内置 + 预填端口 + 获取模型 + 中文报错

**新增三个数据层文件（全部实测驱动）**

| 文件 | 作用 |
|---|---|
| `data\model_providers.dart` | 四家预设（端点已预填）+ Key 申请入口 + 每家的坑 |
| `data\api_error_text.dart` | **错误翻译层**：429/401/403/404/413/5xx/超时/DNS/TLS → 中文，带 `retryable` 与原始技术细节 |
| `data\model_fetcher.dart` | `GET {base}/models`（`dart:io HttpClient`，**不引第三方包**），容忍多种返回结构，失败走上面的翻译层 |

**四个端点全部实测过**（2026-10-03，直接请求 `/models`）：

| 服务商 | Base URL | 实测结果 |
|---|---|---|
| Command（聚合，推荐） | `https://api.commandcode.ai/provider/v1` | **200** + 完整模型清单 |
| LongCat（美团） | `https://api.longcat.chat/openai/v1` | **401** `invalid_api_key`（**主机与路径真实存在**） |
| MiMo（小米） | `https://api.xiaomimimo.com/v1` | **401** `invalid_key`（同上） |
| DeepSeek 官方 | `https://api.deepseek.com` | 本机 `dsh-deepseek-account-platform` 的 `inferenceOrigin` 默认值 |

> 技巧（可复用）：**401 ≠ 端点错**。能返回结构化 JSON 就证明主机名、路径、协议都对；
> 只有 `getaddrinfo ENOTFOUND` 才是域名不存在。查未知端点时别急着判死。
> 四家 `/models` **都要求鉴权**（无 Key 一律 401），所以 Key 为空时 fetcher **不发请求**，
> 直接返回中文提示。

**顺带解决了 §5.2 的悬案**：设计稿那 6 个模型名在 Command 端点上**真的有对应 id** ——
`tencent/hy4-preview`、`zai-org/GLM-5.3`、`deepseek/deepseek-v4.1-flash`、
`xiaomi/mimo-v2.6-pro`、`meituan/LongCat-2.0`。用户选 Command 时不必再"切了名字但后端没变"。

**设置页行为**：服务商胶囊（选中自动填 Base URL / provider id）→ 填 Key →
「获取模型」（带 Key 请求，摊出列表让用户点选，非 OpenAI 兼容的模型会标注"仅支持 /messages"）→
「保存并应用」（写 secure storage + 重写 overlay + 重建 runtime）。
任何错误都以**中文**呈现，原始信息折在「技术细节」里。
`provider id` 沿用 `com`（Command 的历史短名）**刻意不改**，否则老用户的 overlay 会失效。

### 13.6 定时任务（本轮进行中）

已知事实（决定了实现路线）：
1. `dsh_runtime.dart` 已有 **`headless(prompt)`** 一次性执行通道 → 复用它，不另造执行路径；
2. 随包运行时 26,495 个条目里 **`automation` 命中 0** → DSH 自带调度在手机上不存在，
   **调度必须 App 自己实现**；
3. Android 上「后台运行」必须有**前台服务**（常驻通知），否则进程会被回收。

> 实现细节与验证结论见下面 §13.7。

### 13.7 定时任务：实现 + 验证（本轮完成）

**用户原话**：「定时任务主要就是用户定制各种任务的执行时间，后台运行。」

#### 落地文件

| 文件 | 作用 |
|---|---|
| `app\lib\data\schedule_store.dart` | 新增。任务模型 + 运行历史（上限 50 条）+ JSON 落盘 `<filesDir>/schedules.json`；**纯函数 `computeNextRun()`** 集中所有日期边界；`humanize()` 出人话；`markMissedIfStale()` 如实记「已错过」 |
| `app\lib\local\schedule_runner.dart` | 新增。`Timer.periodic(20s)` 检查到期 → 调 **`DshRuntime.headless(prompt)`**。同一时刻只跑一个；`runningTask` / `lastOutcome` 两个 ValueNotifier 供 UI |
| `app\lib\ui\pages\scheduled_page.dart` | 重写（原 54 行空态）。列表 / 新建编辑弹层（名称、任务说明、一次·每天·工作日·每周、时间选择、weekly 多选星期）/ 启用开关 / 立即运行一次 / 删除二次确认 / 可展开运行历史 / 如实的能力边界提示 |
| `app\android\...\DshSchedulerService.kt` | 新增。前台服务 + 常驻通知（`dataSync` 类型）。只负责把进程留住，调度仍在 Dart 侧 |
| `MainActivity.kt` | 通道新增 `startSchedulerService` / `stopSchedulerService` / `notificationStatus` |
| `AndroidManifest.xml` | 新增 `FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`POST_NOTIFICATIONS`、`WAKE_LOCK`；注册 service（`foregroundServiceType="dataSync"`、`stopWithTask="false"`） |
| `app\lib\local\dsh_runtime.dart` | **只增不改**：`DshHost` 加三个静态方法（启停服务、查通知权限）。原有 ACP / shim / 解压逻辑一行未动 |
| `app\lib\ui\app_shell.dart` | 建 `ScheduleStore` + `ScheduleRunner`；按「是否有已启用任务」启停前台服务；壳销毁时停服务 |
| `app\test\schedule_next_run_test.dart` | 新增。**12 个用例**覆盖 daily / weekdays / weekly / once / 跨月跨年 / humanize / ruleLabel |

#### 复用了什么、没造什么

执行走的是**已经跑通**的 `headless()` 通道（内部 `dsh --profile headless --patch <overlay> <任务>`）——
定时任务和用户手打消息用的是同一个模型、同一份 overlay，没有第二条执行路径。

#### 验证证据（都是实测）

**① 单元测试：12/12 通过**（在 ASCII 副本跑 `flutter test`）

```
00:00 +12: All tests passed!
[weekdays] 周五=2026-01-02 09:00 → next=2026-01-05 08:00 (weekday=1)
[weekly 三/五] from=2026-01-07 09:00 → next=2026-01-09 08:00 (weekday=5)
[humanize] 明天8点 = 明天 08:00
```

> ⚠️ **第一版测试我自己写错了三处**：用 `difference().inDays` 断言天数，
> 但时间差会被时间点截断（周五 09:00 → 周一 08:00 是 2 天 23 小时，`inDays`=2 而非 3）。
> 现在一律用**精确到分钟的 `DateTime` 全等**断言，不掺算术近似。
> 另有 1 处是**实现**该改：`humanize` 原本对明天的任务返回「23 小时后」，
> 已改成优先按日历日表述（「明天 08:00」）—— 用户关心的是哪天几点。

**② `flutter analyze`：`No issues found!`（0 error / 0 warning / 0 info）**

**③ 模拟器冒烟（x86_64，与真机包同源代码）——这一步抓到了一个真崩溃**

```
[dsh-flutter-error] type 'Padding' is not a subtype of type 'LibraryEntry' in type cast
  at _LibraryPageState._buildBody (library_page.dart:293)
```

资料库**一渲染列表就抛异常、整页空白**。根因：`_buildRows` 往同一个 `List<Object>` 里
塞了三种东西（直插的组件页脚、分组头、文件条目），而 `itemBuilder` 假设
"不是分组头就一定是 `LibraryEntry`" 并**显式强转**。
`Object` 上的强转是**运行期**失败，所以 `flutter analyze` 全绿也照样崩——
这就是「静态检查通过 ≠ 能跑」的活标本。已改成按类型分流（`is _GroupHeader` / `is LibraryEntry` / `is Widget`），
修后冒烟 `[dsh-flutter-error]` **0 命中**。

**④ 四个 Tab 的语义树证据**（Flutter 自绘，语义树是唯一可靠的"界面上有什么"）

> ⚠️ 两个踩坑：`adb pull` 的**目标路径含中文会失败**（`cannot create file/directory`），
> 必须先 pull 到纯 ASCII 目录再复制；另外 **Flutter 把可见文本放在 `content-desc`**，
> 可编辑输入框的值才放 `text` —— 只抽 `text=` 会得到"0 条文本"的错误结论。

| Tab | dump 到的原文（节选） |
|---|---|
| 首页 | `泡泡猫的DSH` ｜ `本机 · moni-ws` ｜ `欢迎来到泡泡猫的DSH` ｜ `请帮忙推广一下我的公众号，粉丝太少没有更新动力了` ｜ `我帮你用泡泡猫的DSH，把想法做成成品` ｜ 导航 `首页/专家/资料库/定时任务/设置` |
| 资料库 | `重新扫描工作区` ｜ **只有 `最近` / `我的资料` 两个 Tab（团队空间已消失）** ｜ `工作区 1 个文件` ｜ 真实文件 `WORKSPACE-INFO.txt 92 B 5 小时前` |
| 定时任务 | `新建定时任务` ｜ `暂无定时任务` ｜ 引导文案 |
| 设置 | `外观`（字号 小/标准/大/特大；深色选中；浅色置灰+说明）｜ `模型已配置` ｜ 四家服务商胶囊 ｜ Key 申请入口 ｜ `获取模型` ｜ `保存并应用` |

**⑤ 调度器真的起来了**（logcat）

```
[dsh-schedule] 调度器已启动，tick=20s
[dsh-nav] 保活服务已停止（没有已启用任务）     ← 无启用任务时按设计不挂通知
[dsh-nav] tab -> 资料库 (2) / 定时任务 (3) / 设置 (4)
```

#### 后台运行到底做到哪一步（**如实**）

| 情形 | 会不会触发 |
|---|---|
| App 在前台 | ✅ |
| App 切到后台（进程还活着，常驻通知在） | ✅ 设计目标 |
| 用户从"最近任务"划掉 / 被 ROM 省电策略杀掉 | ❌ 不触发；恢复后**记为「已错过」**，不假装跑过 |
| Android 14+ 连续运行 | ⚠️ `dataSync` 类型有**每天约 6 小时**累计上限，超时系统会停掉服务。要突破需改用 `specialUse` + `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`（本 App 未做） |
| Android 13+ 未授予通知权限 | ⚠️ 服务仍运行，但**常驻通知不可见**（界面已写明） |

> **真机依然未验证**（本机无 arm64 设备）。上面 ③④⑤ 都是 x86_64 模拟器上的实测。

### 13.8 最终 arm64 真机包 + 端到端触发验证

```powershell
install\build-local-apk.ps1 -Abi arm64-v8a -Mode release   # Gradle assembleRelease 174.7s
```

| 项 | 值 |
|---|---|
| 路径 | `dist\dsh-local-arm64-v8a-app-release.apk` |
| 体积 | 196,412,880 B = **187.3 MB** |
| 生成时间 | **2026-10-03 16:33:20** |
| sha256 | `751C0D65305D7459EF09873F9961DBBE007B6358437E4548D6E5629897EBFCE2` |

**包内四项核验（实测）**

1. **只有 arm64**：`lib/` 下仅 `arm64-v8a` 15 个 `.so`（含 `libnode.so`）。
2. **新猫图标在包里**：按**尺寸**核对到 108/162/216/324/432（自适应前景）与 48/72/96/144/192。
   （release 会重命名资源，按名字搜 `ic_launcher` 一定搜不到 —— 见 §13.2。）
3. **App 内猫图在包里**：`assets/flutter_assets/assets/images/paopaocat_mascot.png`（206,219 B）。
4. **本轮新功能文案 16/16 全部命中** `lib/arm64-v8a/libapp.so`：
   `泡泡猫的DSH` / `请帮忙推广一下我的公众号` / `我帮你用泡泡猫的DSH` / `我的资料` / `暂无文件` /
   `暂无定时任务` / `点右上角 + 新建` / `外观` / `获取模型` / `保存并应用` /
   `请求太频繁`（429 中文）/ `API Key 无效或没填`（401 中文）/ `MiMo（小米）` / `LongCat（美团）` /
   `后台运行依赖一个常驻通知`。
   ⚠️ Dart 3 AOT 里 **CJK 是 UTF-16LE**，只按 UTF-8 扫会全 MISS（两种编码都扫才对）。

**端到端触发验证：定时任务真的到点跑了（这是本轮最有价值的一条证据）**

做法：不驱动界面的时间选择器（盲点太脆），而是往设备里**种一条 2 分钟后到期的任务**，
重启 App 后盯 logcat：

```
08:42:19  [dsh-schedule] 调度器已启动，tick=20s
08:44:19  [dsh-schedule] 执行任务「SMOKE-TASK」rule=仅一次 · 08:44     ← 到点触发（due 08:44:06，晚 13s = 一个 tick）
08:45:02  [dsh-schedule] 完成「SMOKE-TASK」exit=0                    ← 真实模型调用，模型回了 SCHED-OK
```

设备上落盘的结果（`run-as ... cat files/schedules.json`）也印证了整条链路：

```json
{"schedules":[{"id":"sch-smoke","name":"SMOKE-TASK","enabled":false,
  "lastRunAt":"2026-10-03T08:45:02.136060","lastOk":true,
  "nextRunAt":null,"lastSummary":"SCHED-OK"}],
 "runs":[{"at":"...","ok":true,"summary":"SCHED-OK","missed":false,"taskName":"SMOKE-TASK"}]}
```

即：**读盘 → 算下次时间 → 到点执行 → 复用 headless() 真实调用模型 → 结果落历史 → 「仅一次」自动停用**，
每一步都有证据。

> ⚠️ 两个只有真机/自动化才会暴露的坑：
> 1. **`run-as pkg sh -c "cat > files/x"` 里的双引号会被 `adb shell` 自己吃掉**，
>    于是 `>` 由**外层 shell（shell 用户）**执行，文件根本没进 App 私有目录
>    （表现是读回时 `No such file or directory`）。要**内层用单引号**。
> 2. **模拟器时钟是 UTC**（logcat 08:42 而本地 16:42），Dart 的 `DateTime.now()` 取设备时钟，
>    所以种任务时 `nextRunAt` 必须按 **UTC** 写，否则会落在 8 小时之后、永远不触发。

**本轮仍然未验证的（如实列出）**

| 项 | 为什么 |
|---|---|
| **arm64 包在真机上运行** | 本机没有 arm64 设备（§11.2）；上面全部是 x86_64 模拟器实测 |
| 前台服务在**后台**真的把进程留住 | 触发验证时 App 一直在前台。后台存活受 ROM 省电策略影响，只能真机长期观察 |
| `dataSync` 在 Android 14+ 的 6 小时上限行为 | 需要长时间真机运行才能观察到 |
| 通知权限拒绝时的表现 | 模拟器默认给了通知权限，未构造拒绝场景 |
| 「获取模型」按钮打到真实服务商 | 需要用户自己的 Key；本轮只验证了端点可达（401/200）与解析逻辑 |

---

## 14. 第六轮：用户真机实测反馈修复（2026-10-03）

> 用户在手机上装了 **16:33 那个 arm64 包** 之后，一次性反馈了 5 条问题 + 1 条新要求。
> 这一轮全部围绕"实测反馈"展开 —— 前面几轮的验证都止于模拟器，这轮才是真机使用暴露的问题。

### 14.1 用户原话（逐条，不要转述走味）

1. 「首页底部导航的上边，有个发信息或按住说话的按钮和一个向上箭头（无法使用）以及一个模型选择按钮。取掉这三个按钮，改为开始新会话。」
2. 「在会话界面模型选择读取的不是设置里已经有的模型，而是我截图上的模型。而且发现个问题，我选择任何模型都可以会话，明明没有配置。」
3. 「拍照、照片/视频、添加文件、语音均无法使用。」
4. 「设置页面我没有填写 apikey 我看到的是已经填写，把保存并应用改为测试并保存，用户填写完后点击会测试模型是否连通，连通会收缩填写页面，显示该模型已就绪。」
5. 「会话我看见有已经生成会话历史，这是什么时候的事，而且恢复一个会话，历时性息不在界面上回放，这样是不是不方便回忆是怎么回事。」
6. （新要求）「各个工作区会话会收缩，只有点击才可以展示有多少会话。」

### 14.2 问题 2 的根因（**这一轮最实质的发现**）

| 旧实现 | 造成的真实后果 |
|---|---|
| `data/model_catalog.dart` 里**写死**一份设计稿模型清单：`Hy4 preview` / `Hy3` / `GLM-5.3` / `GLM-5.3-Flash` … 还带 `0.29x`、`0.11x` 这类倍率 | 对话页模型面板显示的是**云端服务的显示名与计价**，用户端点上根本不存在 →「读取的不是设置里的模型，而是我截图上的模型」 |
| `app_shell.dart` 的 `resolveActiveRoute()` 有一层"未知 routeId 就回落到用户在设置里配的 model id"的兜底 | **不管点哪个模型都能跑**（其实全跑同一个后端）→「我选择任何模型都可以会话，明明没有配置」 |

**修法（彻底换掉来源，而不是打补丁）**：
新增 `data/configured_models.dart` —— 清单的**唯一来源**变成用户在设置页真实配置的
`<filesDir>/models.json`。设置页「测试并保存」通过 / 「获取模型」之后写入它，
`state/model_store.dart` 只读它。**没配置过就是空清单**，模型面板如实显示
「还没有可用的模型」并指向设置页。`resolveActiveRoute()` 随之砍掉整层映射
（现在每条的 `routeId` 就是真实 model id，不需要映射，也就没有假象）。

> `data/model_catalog.dart` 里那份设计稿清单与三档 `kModelTiers` **已删除**，
> 文件顶部留了一大段"不要再加回来"的说明。

### 14.3 修复清单（文件级）

| # | 问题 | 改了什么 |
|---|---|---|
| 1 | 首页三个控件 | `ui/pages/task_home_view.dart`：去掉 `InputBar`（输入胶囊 + 向上箭头 + 模型按钮），换成一个「开始新会话」按钮；连带清掉 `modelName` / `onOpenModelSheet` 死参数与 `app_shell` 里的 `_openModelSheetFromHome` |
| 2 | 模型清单来源 | 新增 `data/configured_models.dart`；重写 `state/model_store.dart`（从 models.json 载入）、`ui/pages/model_sheet.dart`（真实清单 + 空态，不再显示编不出来的倍率）；`data/model_catalog.dart` 删掉硬编码清单与档位；`app_shell.dart` 简化 `resolveActiveRoute`/`applyModelSelection`/`ensureModelConfig`；`main.dart` 改 `load(filesDir:)` 并在模型变更后重载 |
| 4 | 测试并保存 | `data/model_fetcher.dart` 新增 `testModelConnection()`（**POST `/chat/completions`**，与对话同一条 OpenAI 兼容通道，`max_tokens:16`）；`ui/pages/settings_tab.dart`：「保存并应用」→「测试并保存」，通过则 `_collapsed=true` 收起表单显示「该模型已就绪」（含耗时），不通过则摊出中文原因；新增 `_readyCard()` 与 `_testOnly()`；并**显示 API Key 的来源** |
| 6 | 工作区默认收缩 | `ui/pages/workspace_page.dart`：`_expanded` 初始为空（删掉 `initState` 里自动展开当前工作区那行）；**收起时不显示会话数**，只显示「点击展开会话」，点开才显示「N 个会话 · 含本次运行」 |

### 14.4 必须先跟用户讲清的事实：他的"没配置"其实是历史遗留

用户第 4 条说「我没填过 API Key，却看到已经填写了」——**这不是 App 乱填**。
APK 覆盖安装**不会清 App 私有目录**，而 Key 存在：
1. `flutter_secure_storage`（Android Keystore）里的 `dsh_model_api_key`，或
2. 设备上的开发注入文件 `files/dev-api-key.txt`（前几轮用 adb 注入过）。

同理第 5 条看到的历史会话，也是**这台手机更早几轮测试**写进 DSH 会话目录的记录。
所以这轮在设置页**把 Key 的来源直接显示出来**（`_keySource`），
并在载入时若已有完整配置就收起表单 —— 用户不会再对着一张"自己没填过却填满"的表单发懵。

> ⚠️ 注意：**我读不到用户手机上的数据**，所以"具体是哪一天产生的"目前只能靠
> 会话文件的时间戳在界面上显示出来（见 §14.5 待办）。

### 14.5 本轮待办 / 交给他人的部分

| 项 | 状态 |
|---|---|
| 问题 3：拍照 / 照片视频 / 添加文件 / 语音 做成真能用 | 交子代理（原生 MethodChannel，**不引入第三方包**） |
| 问题 5b：恢复会话时回放历史消息 | 交子代理（会话是**多帧 zstd**，参考 `D:\dev\build\apkcheck\read-session2.mjs`） |
| 问题 5a：会话时间戳 | 已要求子代理在解码时一并取出并暴露在 `session_index.dart` 的返回结构里；由主会话在 `workspace_page.dart` 消费（子代理不得改该文件，避免冲突） |
| 重新构建 + 模拟器冒烟 + arm64 包 | 待上面落地后统一做 |

### 14.6 落地结果（含两项关键调查）

#### ① 问题 3：四个入口改成**真能用**（原生 system Intent，零第三方包）

`MainActivity.kt` 的 `dsh/native` 通道新增四个方法（都走 `startActivityForResult` + `pendingResult`）：

| 方法 | 实现 | 返回 |
|---|---|---|
| `pickFile` | `ACTION_GET_CONTENT`（`*/*`）→ 复制到 `files/attachments/`（重名加 `-1` 后缀） | 真实绝对路径 |
| `pickMedia` | 同上，`EXTRA_MIME_TYPES = image/*,video/*` | 同上 |
| `takePhoto` | `ACTION_IMAGE_CAPTURE` + **FileProvider**（`${applicationId}.fileprovider`，路径见 `res/xml/file_paths.xml`） | 照片路径（全分辨率） |
| `recognizeSpeech` | `ACTION_RECOGNIZE_SPEECH`（zh-CN） | 识别文本 |

- **不用 `resolveActivity` 做前置判断**：Android 11+ 的包可见性会让它在没声明 `<queries>` 时**错误返回 null**（明明有相机也说没有）。改成直接启动 + 捕获异常，并在 Manifest 补 `<queries>`（IMAGE_CAPTURE / RECOGNIZE_SPEECH）。
- Dart 侧（`chat_page.dart`）：拿到路径后**插进输入框**，由用户确认再发送；图片/视频的文本里**如实注明**"二进制文件、能否理解取决于模型视觉能力"。语音识别结果同样先填进输入框。
- **不做"上传"假象**：DSH 在 Android 上只有 `read` 工具可用（文本文件模型能真读到）。

#### ② 问题 5：两个决定性调查（省掉了一整块工作 + 让回放成为可能）

**调查 A：`session/list` 本来就返回 `createdAt`。**
`@deepseek-ai/dsh-acp/lib/index.js` 的 `listSessions` 逐条给 `createdAt` 并**按它倒序**排（第 1270-1274 行）。是我们的 `acp_client.dart` 解析时把它**丢掉了**。
→ 修：`listSessions` 返回 `createdAt`（容忍秒/毫秒两档）→ `session_index.dart` 透传 → `DshSession.createdAt` → 会话行显示「刚刚 / 12 分钟前 / 2026-09-28 14:02」。

**调查 B：`session/resume` 不返回任何历史消息。**
同文件第 1208-1251 行：只返回 `{ configOptions }`。所以"恢复时回放历史"**协议层给不了**，必须自己读会话文件。
→ 新增 `local/session_transcript.dart`：把一段 node 脚本**内嵌成 Dart 字符串**（每次调用重写，避免设备上留旧脚本），写到 `<filesDir>/tools/read-transcript.mjs`，再用 `DshRuntime.runOnce` 跑它。

**会话记录的真实结构（实测，不要凭猜改）**：多帧 zstd，逐行 JSON，每行 `{"type":...}`：
`session`(含 `createdAt` 毫秒) / **`session/title`(DSH 生成的真实标题)** / `user/message`(`data.content[]`) /
`assistant/message`(`data.message.content[]`，其中 `reasoning` 是思维链**不回放**) / `tool/call` / `turn/start|end` …

**实证**：把内嵌脚本**原样抽出**，拿本机真实会话（2.1MB / 820 帧 / 1511 条记录）跑 →
`title=@手机 App 开发专家 这是一份交`、`createdAt=2026-10-02 18:24:07`、`total=192`，回放内容正确。
→ `chat_page.dart` 恢复会话时渲染一个**只读、可展开、限高 45% 屏高**的历史块（不塞进实时消息流，避免和本次对话混淆）。

#### ③ 老配置用户自愈（冒烟时发现的真问题）

冒烟报告里会话页显示 `当前模型 未配置模型` —— 因为新的 `models.json` 在**本版本之前配过模型的用户**（例如用户的手机）上不存在，他们升级后会"明明配置还在却选不到模型"。
→ `main.dart` 启动时自愈：若清单为空且安全存储里有 `dsh_model_id`，用那条配置补一个只有 1 个模型的 `models.json`，用户点「获取模型」后自然换成真实列表。

#### ④ 冒烟验证（x86_64 模拟器，脚本 `install/verify_round6.py`）

> 这个脚本用 **Python** 而不是 PowerShell：它要按中文 `content-desc` 找控件，而 PS 5.1 读无 BOM 的 UTF-8 会乱码（本轮踩了两次）。

| # | 验证项 | 结果 |
|---|---|---|
| 1 | 首页 | ✅ 出现 `开始新会话`；旧 `发消息或按住说话` **已消失** |
| 2 | 设置页 | ✅ 处于**收起状态**（显示 `重新测试` / `修改配置`），外观四档字号 + 深色 + 「浅色（未适配）」置灰与说明都在 |
| 3 | 资料库 | ✅ 有 `最近` / `我的资料`，**没有 `团队空间`** |
| 4 | 定时任务 | ✅ 显示上一轮种的 `SMOKE-TASK`（已停用 / 成功 / 运行历史 1 条） |
| 5 | 会话页附件菜单 | ✅ 三项 `拍照` `照片／视频` `添加文件` + `专家中心` `使用技能` `定时任务` 全部渲染 |
| 6 | **点「添加文件」** | ✅ **真的拉起了系统文件选择器**（截图 `round6_picker.png`） |
| 7 | logcat | ✅ flutter 异常 / FATAL / `ActivityNotFoundException` / `FileProvider` 报错 **0 命中** |

#### ⑤ 本轮仍未验证的（如实）

| 项 | 为什么 |
|---|---|
| arm64 包在真机上跑 | 本机没有 arm64 设备（§11.2 的结论没变）；模拟器是 x86_64 |
| 真机上拍照/相册/语音的实际体验 | 需要真机的相机应用与语音服务；模拟器只验证到"能拉起系统组件且不崩" |
| 图片能否被模型"看懂" | 取决于模型视觉能力与协议支持；本 App 只做"把真实路径给模型"这一层 |
| 历史回放的真实渲染 | 解码器已在真实数据上验证，但界面渲染只在模拟器上间接确认（未构造"恢复一条有历史的会话"的点击） |


