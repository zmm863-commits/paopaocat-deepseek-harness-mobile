# paopaocat deepseek harness-mobile

> 手机上的 DeepSeek Harness —— 把整套 DSH 运行时装进 Android，完整能力、完整文件系统，全部在你自己的手机里。除了调模型那一步，不依赖任何服务器。

<div align="center">
  <b style="font-size:1.15em;">口袋里的完整 DSH：离线可用，一句话得真实文件</b><br><br>
  <a href="https://github.com/zmm863-commits/paopaocat-deepseek-harness-mobile/releases"><img alt="GitHub Release" src="https://img.shields.io/github/v/release/zmm863-commits/paopaocat-deepseek-harness-mobile?label=Release" /></a>
  <a href="https://github.com/zmm863-commits/paopaocat-deepseek-harness-mobile/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/zmm863-commits/paopaocat-deepseek-harness-mobile" /></a>
  <a href="https://opensource.org/licenses/MIT"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg" /></a><br><br>
  <img alt="screenshots" src="screenshots/shot-01.jpg" width="100%" />
</div>

## 📑 目录
- [✨ 功能一览](#-功能一览)
- [🚀 安装](#-安装)
- [🖼️ 特性巡礼](#-特性巡礼)
- [💬 社区](#-社区)
- [🆕 最近更新](#-最近更新)
- [🛠️ 开发与构建](#-开发与构建)
- [🔐 安全](#-安全) · [⚠️ 已知限制](#-已知限制) · [🖥️ 平台支持](#-平台支持)


## ✨ 功能一览

> 本 App 的功能一览见下方“为什么它是优点”与“12 组内置会话”两节。

## 🚀 安装

DSH 是一套能在本机跑起来的 AI Agent 运行时，能读写文件、执行任务、调用工具、维护多轮上下文。

这个 App 做的是：**把一整套 DSH 运行时原封不动塞进 Android 应用**——内嵌 Node 运行时与全部依赖（`libnode.so` 49MB + `dsh-runtime.zip` 157MB，内核 `@deepseek-ai/dsh 0.1.7-rc.2`），首次启动自动解压到应用私有目录，之后**完全离线运行**（只有与模型对话时才联网）。

它不是网页套壳，也不是远程桌面。关掉网络，它的界面、历史、文件都还在你自己的手机上。

- 包体：`paopaocat-preview-0.14-arm64-v8a.apk` · 188MB · arm64-v8a · minSdk 24
- 内核：Flutter + Node · 321 名专家 / 22 分区 · **12 个技能**（make-image / make-video / make-slides / code-tool / data-analysis / doc-digest / doc-processing / file-organize / sheet-cleanup / study-cards / translate-polish / weekly-report + android-exec-shim + rotate-proxy）
- 外观：深色/浅色双主题一键切换，重启保持；自定义为占位说明，不会切到不存在状态
- 隐私：API Key 只存 Android Keystore，会话与产出在私有目录，执行前需你确认

## 安装

- 真机 arm64，允许安装未知应用
- 安装后首次启动会解压运行时（约 30 秒），之后即可离线使用
- 仅 arm64-v8a 单架构包，x86/armeabi 设备不兼容

```sh
# 校包体
sha256sum paopaocat-preview-0.14-arm64-v8a.apk
# 预期: d5448afcc4d555ad7530e76dba16d78a301b4df89d8b4d4412a940ca77505cad
```

## 快速开始

1. **配模型**：设置 → 选 DeepSeek 官方 / Command / LongCat / MiMo（端点已预填）→ 填 Key → **获取模型**（支持多选）→ 勾选 → **测试并保存**（真打最小对话，通了才显示已就绪）；需要抗限流可建**模型轮换池**（多模型按序尝试，429自动切下一个，详见下文）
2. **开会话**：首页 **开始新会话** → 输入需求 → 看流式回显、工具调用卡片、产物卡片；可 **中断/继续**
3. **用专家与技能**：专家中心开需要的专家（开关真写运行时配置）→ 回会话提需求；也可直接让模型“帮我生成一个技能”
4. **做图/做视频/做 PPT**：跟模型说“生成一张图/做段视频/做个PPT”，它会调 `make-image.mjs`（文生图/图生图/多图合成，1K-4K、8种比例，当前免费）/`make-video.mjs`（文生视频/首尾帧，4-12秒）/`make-pptx.mjs`（真 .pptx，封面+要点+备注）把**真实文件**产到工作区；没配 Key 会报中文错误并给注册地址
5. **收文件**：会话产出自动进 **资料库** → **工作区** 多目录并行；需定时则建任务（每天/工作日/每周/仅一次），到点自跑（依赖常驻通知，受国产 ROM 省电策略影响可能标“已错过”）
6. **附件与12组内置会话**：拍照（系统相机→私有目录）/ 相册选图视频 / 任意文件（给真实路径可被模型读取）/ 语音（调系统识别）；首页 **12 条内置会话每组带一个技能**，一次显示 4 条，点**换一换**可看完全部 3 组

**12 组内置会话 × 12 个技能（首页换一换可看全，每条一点即开会话）**

| # | 会话入口（首页） | 背后技能 | 一句话能做什么 |
|---|---|---|---|
| 1 | 生成一张图片 | `make-image` | 文生图/图生图/多图合成，1K-4K、8种比例，Agnes 免费 |
| 2 | 生成一段视频 | `make-video` | 文生视频/首尾帧，4-12秒，异步轮询 |
| 3 | 做一份 PPT | `make-slides` (`make-pptx.mjs`) | 真 .pptx（16:9，封面+要点+备注） |
| 4 | 写个小工具 | `code-tool` | 单个自包含 .mjs，纯 Node 内置模块，当场跑通 |
| 5 | 分析数据 | `data-analysis` | CSV/JSON 真算一遍，产 Markdown 报告 + 离线 HTML 图表 |
| 6 | 清理表格 | `sheet-cleanup` | 脏 CSV 去重/统格式/补字段/分组汇总，另存 clean-*.csv |
| 7 | 速读长文 | `doc-digest` | 长文压成要点/时间线/关键数字的速读稿 |
| 8 | 处理文档 | `doc-processing` | 摘要/改写/纠错/转 Markdown/HTML，产新文件 |
| 9 | 整理文件 | `file-organize` | 先出方案待确认，再归档/批量重命名，可回退 |
| 10 | 做学习卡片 | `study-cards` | 材料变问答卡片，产 Markdown + 可导入 CSV |
| 11 | 翻译润色 | `translate-polish` | 中英互译/润色，产双语对照 Markdown |
| 12 | 写周报 | `weekly-report` | 扫工作区新增/变更文件，汇总成带路径的周报 |

> 首页一次显示 4 条，点**换一换**换一整组，点 3 次看完全部 12 条；每条都已绑定对应技能，点开即带上下文开会话。

## 0.14 预览版更新（6 个版本 · 36 条）

详见 `docs/emergency-update-0.14.html`（36条逐条列出）与 `docs/preview.md`：

- **生成文件可用 (1-5)**：修会话链路漏带 shell 垫片导致的 `spawn bash ENOENT`、会话内可直接调工具箱脚本、PPT 真出 `.pptx` 而非 HTML 顶替、网页产物直接渲染（可看源码/浏览器打开）、支持系统分享
- **产物只出真文件 (6)**：文件真实存在 + 本次会话写出 双门槛，拦截技能文档示例占位名与旧文件混入
- **模型与 Key (7-19)**：多厂家互不覆盖、获取模型多选、**模型轮换池**（见下文）、内置 Agnes 免费生图/视频、切模型不重建会话、设置页重排为当前模型→我的模型→轮换组→添加模型→Agnes、Key 正确下发、改配置自动重建、仅换模型保留会话、默认模型两端一致、厂家卡片式、拉不到列表时用内置建议模型并说明、模型面板两级厂家→模型且点一次即生效
- **界面 (20-26)**：右上角 ⚙ 改为「工作区」入口、顶栏第二行显示所在工作区、**深色/浅色双主题一键切换且重启保持**、外观文案重写、「自定义」为占位说明、「插件」如实标暂未开放、修 320px 宽屏顶栏溢出
- **会话与日常 (27-34)**：未配模型时明确引导去设置、内置会话 4→12 条且首页 4 条一组「换一换」、边缘侧滑二次确认才退后台、**运行日志一键导出（Key 自动脱敏）+ 开发者邮箱**、设置→关于新增更新说明页、安装包命名统一 `paopaocat-preview-版本-芯片`
- **语音 (35-36，部分未修完)**：补麦克风权限（按需申请）、优先设备端离线识别（Android 12+）再回退系统识别，分情况提示「无离线模型/无识别服务/没听清」

> 语音本地模型未内置原因：DSH 自带语音模型仅提供 macOS/Linux/Windows 原生库，Android bionic 不在支持列表；且 int8 模型 239MB，塞进包不现实。

### 模型轮换池（把多个免费模型绑成一个抗限流模型）

App 内 **设置 → 模型 → 轮换池** 可把多个模型（如各家的免费额度模型）**按顺序绑成一组**，以**组名当模型名**去对话：

- 原理：本地 `rotate-proxy.mjs`（纯 Node 内置模块，无第三方依赖）在 `127.0.0.1:39321` 起一个 OpenAI 兼容代理，按组内顺序逐个尝试；**429 限流 / 500 / 连接失败**时自动换下一个，客户端只看到一次成功响应
- 粘性：记住每组**最近一次成功的成员**（`lastGood`，内存+回写配置），下次从它开始，失败再往下轮
- 暴露：`GET /health`、`GET /v1/models`（每组一个模型）、`POST /v1/chat/completions`（组名或成员真实模型名均可匹配，支持 `rotate/cat` 这类前后缀写法）
- 流式限制（HTTP 协议约束）：只有**还没向客户端吐过字节**时才能换成员；一旦开始管道 SSE，就无法再切（此时中途断开只能结束本次响应并记日志）
- 典型用法：把 DeepSeek 免费、Qwen 免费、MiMo 免费等先后放进同一组，日常对话走组名，额度/限流自动兜底，不用手动切

## 已知限制

- 后台常驻通知依赖系统省电策略，部分国产 ROM 仍会杀进程，错过的任务会如实标“已错过”（非假装跑过）
- 仅 arm64-v8a 单架构，单包 188MB
- 插件安装暂未开放（需先做完安全校验与回滚机制，设置→插件页已如实说明）
- 语音本地模型未内置（见上文原因），识别质量取决于系统离线模型/识别服务

## 为什么它是优点（全量特性，不藏短板）

| 维度 | 优点 |
|---|---|
| **真本地运行时** | 不是网页套壳/远程桌面；`libnode.so` + `dsh-runtime.zip` 完整塞进 APK，首次解压后离线可用，界面/历史/文件都在私有目录 |
| **文件是真的** | 资料库按 mtime/目录双视图，工作区即真实目录，多工作区并行互不干扰，产物双门槛防假文件，生成物直接渲染/分享 |
| **附件走系统原生** | 拍照拉系统相机、相册选图视频、任意文件给真实路径、语音调系统识别；不做“上传成功”假提示，能否看懂取决于模型视觉能力并如实说明 |
| **321专家真生效** | 22分区开关写入 `$DSH_HOME/AGENTS.md`（agent-instructions 通道），模型照人设执行；技能可新建，也可对话生成 |
| **定时是真定时** | 每天/工作日/每周/一次，到点复用对话同一通道执行，记录成功/失败/已错过，不假装跑过（依赖常驻通知） |
| **模型接入最省事** | 4 家端点预填、获取模型多选、测试并保存走真实对话通道、报错中文翻译并给下一步、切模型不丢聊天记录 |
| **轮换池抗限流** | 多个免费模型绑一组，429/500/断连自动换下一个，粘性 lastGood，下次从上次成功的开始；流式仅在未吐字节前可切换（协议约束已如实说明） |
| **做图/做视频/做PPT** | 一句话即得真实文件：生图（文生/图生/多图合成，8比例/1K-4K）、生视频（文生/首尾帧，4-12秒）、真 .pptx；`android-exec-shim` 补齐手机无 bash 的执行链 |
| **隐私与可控** | Key 只存 Android Keystore，不进日志/命令行；执行前弹确认框（工具名+具体内容）；运行日志一键导出且 Key 自动脱敏 |
| **界面可用** | 深浅双主题一键切且重启保持、模型面板两级厂家→模型点一次生效、右上角统一为工作区入口、首页 12 条内置会话分组换一换、320px 宽屏已修、边缘侧滑二次确认才退 |
| **安装与升级** | 覆盖安装签名一致，会话/文件/Key 不丢；包命名统一 `paopaocat-preview-版本-芯片`；187.6MB 单包，minSdk 24 |

## 截图

| | | | |
|---|---|---|---|
| ![](screenshots/shot-01.jpg) | ![](screenshots/shot-02.jpg) | ![](screenshots/shot-03.jpg) | ![](screenshots/shot-04.jpg) |
| ![](screenshots/shot-05.jpg) | ![](screenshots/shot-06.jpg) | ![](screenshots/shot-07.jpg) | ![](screenshots/shot-08.jpg) |

*本文所有截图均来自真机实拍，未做美化（由 `紧急更新.html` 内 10 张 base64 导出，节选 8 张 720 系列作商店主图）。*

## 交流与反馈

- **公众号：泡泡猫（ID: paopaocat888）** — 扫码关注，**直接在公众号里留言讨论**，私信发送 **888** 即可获取安装包链接
  - 二维码：`screenshots/wechat_qr.png` · 也可在 `docs/emergency-update-0.14.html` 末尾扫码关注
  - 适合：使用问题、功能建议、复现反馈（比 GitHub Issue 更轻量，适合手机端随手留言）

- **GitHub Issues**：https://github.com/zmm863-commits/paopaocat-deepseek-harness-mobile/issues — 提 Bug/需求/兼容报告

## 🆕 最近更新

见 [CHANGELOG.md](CHANGELOG.md) 与 [GitHub Releases](https://github.com/zmm863-commits/paopaocat-deepseek-harness-mobile/releases)

## 相关

- 桌面版：`dshpack-017`（Win/macOS）
- 预览图文稿：`docs/preview.md` / `docs/emergency-update-0.14.html`
- 反馈：GitHub Issues + 公众号留言（双通道）

## License

MIT
