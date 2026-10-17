# Bot 团队上手机 —— 测试包说明（0.77 候选）

> 日期：2026-10-17 · 目标：**手机上打开 Bot 页面，看到各个 Bot 在聊天、在解决问题**
> 口径（用户定）：**体验和桌面版一样**。所以走的是「把同一套 web 前端搬进手机」，
> 不是用 Flutter 重写界面。

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

## 7. 涉及的文件

- `app/lib/local/bot_server.dart` —— 起/停 web 服务、建 profile、解析 token URL
- `app/lib/ui/pages/bot_page.dart` —— WebView 页面（启动进度 / 失败原因 / 返回键先让网页退）
- `app/lib/ui/app_shell.dart`、`app/lib/ui/pages/task_home_view.dart` —— 首页顶栏入口
- `install/build-runtime-with-bottest.sh` —— 往运行时包里塞 profile 种子
- `app/android/.../MainActivity.kt` —— `RUNTIME_VERSION` 2 → 3（运行环境内容变了必须 +1）
