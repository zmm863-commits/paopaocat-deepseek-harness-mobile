# Bot 团队上手机 —— 测试包说明（0.77 候选）

> 日期：2026-10-17 · 目标：**手机上打开 Bot 页面，看到各个 Bot 在聊天、在解决问题**
>
> ⚠️ **重要变更（构建号 81，同日）**：下文 §3–§5 描述的「**用 WebView 打开 dsh web**」
> 方案**已被用户否决并废弃**。用户原话：「我想要的是**在我 APP 会话界面一样的聊天**，
> 不是要的这种网页内切的方式」。
>
> 现在的做法（`lib/ui/pages/bot_team_page.dart` + `lib/local/bot_team.dart`）：
> **只读 `<DSH_HOME>/bot/state.json` 拿 Bot 名册**（明文 JSON），点任意一条 →
> 用 **App 自己的原生聊天页**打开那个会话（Bot 本来就是普通会话；历史由
> `session_transcript.dart` 读会话文件回放）。
>
> 下文 §3–§5 **保留为踩坑记录** —— 里面那三条硬约束、token 机制、profile 种子、
> `--patch` 位置等**依然有效**（ds-bot 的宿主仍在后台 node 进程里跑，只是对用户不可见）；
> §6 的回滚方式、§8 的排查表也仍然适用。
> 口径（用户定）：**体验和桌面版一样**。所以走的是「把同一套 web 前端搬进手机」，
> 不是用 Flutter 重写界面。

---

## 0. 现在的实现（2026-10-17 最终形态：**网页版**）

> ⚠️ **方向已定（用户 2026-10-17 明确）**：Bot 页面用 **WebView 加载 dsh web**（`bot_page.dart`），
> **不做原生那条线**。原因见下面的「为什么回到网页版」。

```
【用户看到的】
  底部导航「Bot」→ WebView 打开 `http://127.0.0.1:<port>/?token=…`
      └→ 里面就是 **ds-bot 自己的完整网页 UI**（左侧频道/会话列表 + 右侧聊天 + 设置）

【后台】
  BotServer 起一个 `dsh --profile bottest` 的 node 进程
    · bottest = dsh-base + dsh-web-app + **ds-bot**（+ dsh-client-ui-mobile 窄屏增强）
    · **不含** dsh-client-ui-paopaocat（品牌主题）—— 用户 2026-10-17 明确「不需要品牌主题」
    · 种子随 runtime 分发：`<filesDir>/dsh/profiles-seed/bottest`

【会话怎么跑】
  **全在网页内**：会话、群聊、Bot 都由 ds-bot 的网页 UI 驱动，**不走 ACP**。
```

### 为什么回到网页版（2026-10-17 的关键决策）
两条路的差别不在功能，而在**底座**：

| | 网页版 | 原生版（79~100 我做的） |
|---|---|---|
| 会话怎么跑 | 整个 dsh web 在 WebView 里 | App 用 **ACP**（`--profile acp`）建会话再自己渲染 |
| 底座 | `bottest` = `dsh-base + dsh-web-app + ds-bot`，**与桌面版同源** | `acp` = bundles 只有 `dsh-base + dsh-acp-app`，**profile 的 patch 层是空数组** |
| 结果 | 天然齐全，用户实测「可以跑通」 | 每发现一样「桌面版有它没有」就得补一样：TMPDIR、cookie、Key 变量名、协议声明、权限预设、插件包…补了 13 个版本 |

**教训：选方案先看底座。** 极简 profile 不是「轻量」，而是「什么都得自己补齐」。



```
【用户看到的】
  底部导航「Bot」（在首页右边）
    └→ Bot 团队页（原生 Flutter 列表，非网页）
         ├─ 「主 Bot」/「Bot（N）」/「群聊（N）」 三组
         ├─ 点任一条 → **App 现有的聊天页**（ACP resume + 读会话文件回放历史）
         ├─ 右上角「＋」→ 新建 Bot / 新建群聊
         └─ 群条目右侧按钮 → 在「只由主持人点名 ⇄ 全员都会回答」之间切换

【后台（用户看不见）】
  BotServer 起一个 `dsh --profile bottest` 的 node 进程（= ds-bot 宿主）
    ├─ **必须有它**：Bot 会不会回话、会不会互相派活，全靠这个进程
    ├─ 它同时开一个 loopback HTTP 端口，但 App **不**用它显示界面；
    │   App 只用它的 `POST /api/bot` 做「写」操作（新建 Bot/群、切群模式）
    └─ 页面退出**不停**；被系统杀掉后，下次进页自动重启

【数据流】
  <DSH_HOME>/bot/state.json  ← 名册/群聊（明文 JSON，ds-bot 自己维护）
        │ 只读（App 每 3 秒看一次，文件 mtime 没变就跳过解析）
        ↓
  Bot 团队页的列表

  写操作一律走 `POST /api/bot`（create-bot / create-room / update-room），
  **绝不直接改 state.json** —— 否则两套写入方打架。
```

**关键判断依据**：Bot 就是普通会话（ds-bot 原话 `Every Bot is one root Session`），
所以"看 Bot"这件事根本不需要网页界面，用 App 自己的聊天页打开那个会话即可。

---

## 1. 一句话

手机 App 首页顶栏多了一个 **Bot** 入口；点进去，App 在本机起一个
`dsh --profile bottest` 进程（dsh web + Bot 插件 `ds-bot`），再用 **WebView** 打开它。
界面就是桌面版那一套，**不联网、数据在本机**。

---

## 2. 为什么必须这么做（技术底账）

Bot 的界面不是我们写的，是第三方插件 **`ds-bot`**（[Fei2411/DeepSeek-Bot](https://github.com/Fei2411/DeepSeek-Bot) 0.1.7）自带的浏览器前端：
826 条界面文案 + 群聊 + @选人 + 记忆/密钥/用量/审批卡片 + 实时状态词
（"Running shell commands"、"{name} is typing…"、"paused for your approval"）。
用 Flutter 重写**不可能追平**（也不该追）。

而「Bot」在 DSH 里不是新物种 —— `ds-bot` 自己的注释写着
**"Every Bot is one root Session"**：每个 Bot 就是一个普通会话，
名册/群聊/消息日志都在 `$DSH_HOME/bot/state.json` 里。
所以手机上要的只是「把宿主与那套前端跑起来」。

---

## 3. 关键实现（改代码前先看这三条）

| 事项 | 结论 | 依据 |
|---|---|---|
| profile 名 | **`bottest`**（独立于 `acp`，删目录即回滚） | `BotServer.profileName` |
| 最小组合 | `@deepseek-ai/dsh-base` + `dsh-web-app` + `ds-bot` + `dsh-client-ui-mobile` | 本机实测（下面 §4） |
| 种子位置 | 运行时包内 `app/profiles-seed/bottest/` → 手机解压后 `<filesDir>/dsh/profiles-seed/bottest` | `MainActivity.unpack` **只认 `app/` 和 `shims/` 两个前缀**，其余丢弃 |
| ds-bot 放哪 | **profile 自己的 `node_modules/`** | DSH 插件名解析锚定 profile 目录，放别处解析不到 |
| 启动参数 | `--expose-internals` 必加 | `node-addon-require-builtin` 的 Android shim 要 `require('internal/modules/esm/loader')` |
| **`--patch` 的位置** | **必须排在 `--no-open` 之前** | dsh launcher 一旦遇到它不认识的 token（`--no-open` 就是），**后面全部算 profile 内部 app 的参数** → 写反顺序就 `error: unknown option '--patch'` 退出（0.77 测试包真机报错原文） |
| 端口 | `--port 0` 让系统挑，再解析 stdout | 就绪行格式：`dsh web: http://127.0.0.1:<port>/?token=<43字符>` |
| 认证 | 带 token 打开 → 303 下发 cookie → 之后 /api 可用 | 不带 token 访问是 **401** |

组装运行时包的脚本：`install/build-runtime-with-bottest.sh`
（在现有 runtime 上加种子，输出 `dsh-runtime-bottest.zip`）。

---

## 4. 本机实测（2026-10-17，全部通过）

在 `DSH_HOME=/tmp/...` 的独立环境里跑，**没有碰在用的 `/dsh`**：

- profile 创建：`dsh bottest --from-default-profile web` → 三件套文件
- `--dump-config`：`dsh-client-ui-mobile` / `ds-bot` / `ds-bot/web-search` 都在树里
- 启动：2 秒就绪；`dsh web: http://127.0.0.1:<port>/?token=…`
- 认证：token → `303`；不带 token → `401`
- **Bot API**：`POST /api/bot`（`{"endpoint":"state"}`）
  → `{"ok":true,"value":{revision,bots:[{name:"Chief",…}],rooms,colors,models}}`
- **内存**：最小组合进程 **VmRSS ≈ 200 MB**
  （对照：本机整份 web profile 23 个 bundle 的进程是 **1.46 GB**）
- 打包产物复验：解压新 runtime + 按手机做法覆盖 shims → 同样跑通（手机 runtime 0.1.7-rc.2 版本）

---

## 5. 手机上还没验的（这次要看的）

1. **真机内存与流畅度**：200MB 是 x86_64 上的数，arm64 手机上的真实占用要实测。
2. **WebView 里的观感**：`dsh-client-ui-mobile`（窄屏 CSS + 悬浮导航）在真机上的效果。
3. **后台存活**：Bot 要常驻干活，Android 会杀后台进程 —— 现在**页面退出不停服务**，
   但如果被系统杀掉，下次进页面会自动重启（`BotServer.ensureStarted`）。
4. **首次启动耗时**：冷启要拉插件树，本机 10~25 秒；手机上可能更久（页面里有进度提示）。

---

## 6. 怎么回滚（彻底舍弃）

这个方案**没有动** acp 那条线，也没有改任何既有 profile：

```bash
# 手机侧：删掉 profile 就回到「没有 Bot」的状态（App 里入口还在，但一点会重新建）
adb shell run-as com.dshmobile.dsh_mobile rm -rf files/dshhome/profiles/bottest
```

代码侧全部改动集中在 4 个新/改文件，删掉即可：
`lib/local/bot_server.dart`（新）、`lib/ui/pages/bot_page.dart`（新）、
`lib/ui/app_shell.dart`（入口）、`lib/ui/pages/task_home_view.dart`（顶栏按钮），
外加 `install/build-runtime-with-bottest.sh`（新）与 `MainActivity.RUNTIME_VERSION`。

---

---

## 8. 真机排查对照表（本机已逐项验过的分支）

| 症状 | 本机结论 / 原因 | 怎么办 |
|---|---|---|
| 界面报「Bot 服务没能起来」，日志有 `unknown option '--patch'` | 启动参数顺序（`--patch` 被 web app 当成未知选项）—— **已在构建号 78 修掉** | 装 78 及以上 |
| 界面报「Bot 服务没能起来」，日志是别的错 | 看日志里 `[dsh-bot]` / `[dsh-bot:err]` 开头那几行 | 把日志导出来（设置页） |
| 界面报「运行时里没有 Bot 种子」 | 装的是 **lite 包**，而远端 `runtime.json` 还没更新 → 拉到的旧运行时 | 装 **full 包**；正式发版时要补 runtime.json + 上传 runtime |
| 能进页面，但**左侧边栏没有 Bot 区域** | 大概率 ds-bot 没激活 —— 日志里会有 `did not activate` | 把日志导出来 |
| 页面能开、Bot 也在，但**发消息不回** | Bot 没选模型（`state.json` 里 `waiting:true`），或免费通道被限流 | 在侧边栏给主 Bot 选个模型；换 zen/polli 另一条 |
| 启动时会有一行 `web-search-anysearch: failed to import` | 该插件依赖 `launch-environment`/`schemastery`，bottest 最小组合没加载它们 → **Bot 会话里联网搜索不可用**，**不阻塞**任何主流程 | 可忽略（后续版本再补） |
| App 的「工作区/会话」列表里多出一个很长的路径，底下有 7+ 个会话 | 那是 **bot 自己的工作区**（`<DSH_HOME>/bot/workspace`，编码成 `--…-bot-workspace--`）。Bot 就是普通会话，和 App 共用同一个 `DSH_HOME` | 可忽略（属正常）；后续可考虑在列表里过滤 |

**已在真机真实参数下复验通过的两件（本机）**：
- web（bot）与 acp（会话）两个进程**同时**用同一个 `DSH_HOME`：互不干扰，web 仍正常服务（http=303）。
- 手机上的完整参数组合（`--expose-internals` + 两个 shim + `--patch` + `--no-open --port 0` + `NODE_OPTIONS`）能正常起来。

## 7. 涉及的文件

- `app/lib/local/bot_server.dart` —— 起/停 web 服务、建 profile、解析 token URL
- `app/lib/ui/pages/bot_page.dart` —— WebView 页面（启动进度 / 失败原因 / 返回键先让网页退）
- `app/lib/ui/app_shell.dart`、`app/lib/ui/pages/task_home_view.dart` —— 首页顶栏入口
- `install/build-runtime-with-bottest.sh` —— 往运行时包里塞 profile 种子
- `app/android/.../MainActivity.kt` —— `RUNTIME_VERSION` 2 → 3（运行环境内容变了必须 +1）
