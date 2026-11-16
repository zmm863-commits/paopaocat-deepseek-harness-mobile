# 调研 · 可复用开源项目核实 + phone_agent 改造方案（2026-11-14）

> 本文回答两件事：**A. modlens 能不能装进手机**（可行性判断）；**B. 从 artemis 提炼
> 哪些策略改造 phone_agent**（方案，未动代码）。
> 末尾附「三个梯队」的落地计划（用户已批准都做）。
>
> 按项目规矩：涉及外部方案只写**可行性判断**（能用/不能用/为什么），不写取用关系；
> 许可证对比可写（项目准备开源）。

---

## A. modlens（`@liustack/modlens` 3.27.3）兼容性核实

### A.1 结论

**能装，且是本轮调研里唯一「今天就能上」的插件。** 但要改三处适配（见 A.4），
不是 `dsh plugin add` 一条命令就能用。

### A.2 逐项核实（都是读包/读源码得出的，不是看 README 猜的）

| 检查项 | 结果 | 依据 |
|---|---|---|
| npm 包名 | `@liustack/modlens`（不是 `modlens`） | registry 只有 `@liustack/modlens` |
| 版本 / 时间 | 3.27.3 · 2026-11-07 | registry `dist-tags.latest` |
| `peerDependencies` | **`{}` 完全为空** | 不卡任何 DSH 版本 |
| `engines` | `node >= 22.19` | 手机运行时是 **node 26.4**，满足 |
| 运行时依赖 | 只有 `commander` + `undici` | 都是纯 JS，无 native 模块 |
| 插件入口 import | **只有 `node:fs` / `node:os` / `node:path` / `node:url` + 自己的 `spawnHidden.js`** | `dsh/index.js` 前 17 行，**零 `@deepseek-ai/*` import** |
| 挂载方式 | `cordis.patch.yml` 只有 4 行：`- insert: [{id: modlens, name: '@liustack/modlens'}]` | 不指定宿主 API 版本 |
| 声明需要的能力 | `export const inject = ['tools','agents','attachments','llm']` | `dsh/index.js:169` |
| 对缺失能力的防御 | 多处 `if (typeof ctx.inject === 'function')` / `if (typeof ctx.effect !== 'function') return true` | 说明作者考虑了跨版本宿主 |
| 手机运行时能力面 | **2024 个 `@deepseek-ai/*` 条目**（含 dsh-base / dsh-agent / dsh-tools / dsh-attachment / dsh-session 全套） | 解包 `dsh-runtime.zip` 实测 |

**关键判断**：它不 import 宿主的包，只通过 Cordis 的 `ctx.tools.register()` 这类
**服务接口**工作。所以「版本墙」这个问题对它**不存在** —— 这也解释了为什么它
把 `peerDependencies` 写成空。

### A.3 剩下三个真问题（不是版本，是环境）

1. **配置路径写死 `~/.modlens/config.json`**
   手机上 `$HOME` 是 App 私有目录（`filesDir`），可写，但 App 每次重装/清数据会丢。
   需要改到 `filesDir/dshhome/modlens/` 并跟其他配置一起备份。

2. **视觉模型的 Key 与厂家要在它自己的配置里再填一遍**
   它需要一个**能看图的模型**（Gemini / Claude / GPT-4o / Qwen-VL）干活。App 里用户
   已经配了厂家和 Key，但 modlens 不认 App 的存储（`~/.modlens/config.json`）。
   不改的话用户要在两处各填一次 Key —— 这是**真体验倒退**。

3. **要 spawn 子进程跑 `dist/main.js`（CLI）**
   `spawnHidden.js` 用的是 `node:child_process` 的 `spawn`，`windowsHide: true`
   （对 Android 无影响）。手机上 node 在 `libnode.so`，**不能靠 PATH 找 `node`**
   —— 必须显式传 `libnode.so` 的绝对路径。这条 App 里已有同类适配
   （`DSH_ANDROID_NODE_BIN`），照着传即可。

### A.4 如果要装，改这三处（工作量评估）

| 改动 | 说明 | 估量 |
|---|---|---|
| 配置路径 | 启动前把 `HOME` 指到 App 私有目录，或改包内默认路径 | 小（几行） |
| Key 复用 | 把 App 已配的视觉厂家写进 modlens 的 config.json（或加一层代理读 App 存储） | 中（一个适配层） |
| node 路径 | 子进程 spawn 改用 `libnode.so` 绝对路径 | 小 |

**但先问一个更前置的问题**：用户选的模型如果本来就支持看图（Qwen-VL、GLM-4V 等），
modlens 是**多余**的。它真正的价值场景是「用户用的是纯文本模型，但要发截图」。
所以装之前应该先统计：App 的 45 个模型里，有多少是纯文本？

---

## B. artemis 的策略提炼与 phone_agent 改造方案

### B.1 artemis 是什么档位的参考

google/artemis：17,412★、Apache-2.0、Python 3.12+、**MCP 原生 Server**、
AndroidWorld 基准 **99%+ 任务完成率**、Flash 模式 3–5s/步。

**但它不能直接跑在手机上**：它是 Python 进程 + 要通过 adb/设备桥连真机。
手机端没有 Python，也没有第二台设备可连。所以**只借策略，不借实现**。

### B.2 四条值得移植的策略（按价值排序）

#### ① 坐标归一化到 0–1000 网格（最有价值，也最便宜）

artemis 的 OCR 工具里写得很直白：

```python
# ocr.py:119-124
center_x = (min_x + max_x) / 2
center_y = (min_y + max_y) / 2
norm_x = int(max(0, min(1000, center_x * 1000 / width)))
norm_y = int(max(0, min(1000, center_y * 1000 / height)))
normalized_results.append({"text": text, "coordinates": [norm_x, norm_y]})
```

**为什么重要**：
- 模型输出与设备分辨率**解耦** —— 1080p / 1440p / 折叠屏同一套提示词与历史都成立；
- LLM 对 **≤1000 的整数**坐标判断明显比 1200×2640 这种四位数准；
- 换机时历史轨迹仍然可用。

**移植到 phone_agent**：点击/长按/滑动工具的参数改成 `x, y ∈ [0,1000]`，
内部按 `w* x/1000`、`h* y/1000` 换算成像素再调 `input tap`。
保留原像素入口作为**高级用法**（模型明确说"用像素"时），但默认走归一化。

#### ② 持久化 UI Automator 客户端（性能关键）

`read_hierarchy.py` 的 docstring 原话：

> Use this instead of running `uiautomator dump` command via adb shell,
> as it is much faster and more stable.

`uiautomator dump` 每次都要起进程、写 XML 到 `/sdcard`、再读回来 —— 单次
**几百毫秒到 2 秒**，而且频繁调用会互相抢文件导致偶发空文件。

**移植到 phone_agent**：起一个常驻的层级读取通道（无障碍服务/AccessibilityNodeInfo），
一次握手、多次读取；拿不到时再退回 `dump`。

#### ③ 三级定位兜底 + 记账

artemis 的顺序是：**元素索引 → 坐标 → 视觉**。
- 优先用无障碍树里的**节点索引**（界面重排也能命中）；
- 退化到**文本/描述匹配**；
- 最后才是**坐标**（OCR 或视觉定位，自绘界面靠这层）。

**移植关键点不是顺序，是"记账"**：每次点击要记「用了哪一级、命中什么」。
现在 phone_agent 点空了只知道"没反应"，看不到"为什么没反应"。

#### ④ 动作前验证 + 阻塞交回（Pro 模式）

artemis 的 Pro 模式会在**每个动作前校验目标是否还在**，被阻塞的动作
**交回 Operator 恢复**，而不是硬重试。

**移植到 phone_agent**：点击前重新读一次目标节点的存在性（成本低：一次层级查询）；
不存在就返回"界面已变，需要重新观察"，让模型重新决策 —— 而不是盲点 + 重试 3 次。

### B.3 不建议移植的

- **它整个 Python 运行时**：手机没有 Python，装一套解释器只为跑它不值得。
- **langchain / pydantic 那套依赖**：与手机端 node 技术栈无关。
- **云驱动（cloud_driver）**：需要云端设备池，个人场景用不上。

### B.4 改造清单（未执行，等批准）

| 改动 | 文件 | 说明 |
|---|---|---|
| 点击/滑动工具支持 0–1000 归一坐标 | `phone_agent` 工具定义 + 执行层 | 默认归一化，像素为高级入口 |
| 层级读取常驻化 | 原生侧（无障碍服务） | 失败退回 `uiautomator dump` |
| 三级定位 + 记账 | 工具层 | 每次动作记录命中级与目标 |
| 动作前存在性校验 | 工具层 | 失败返回"界面已变"而非硬重试 |

---

## C. 三个梯队的落地计划（用户已批准都做）

| 梯队 | 项目 | 落地形态 | 主要风险 |
|---|---|---|---|
| 一 | **Drawnix**（15,056★ MIT） | 白板塞进 WebView，导出 PNG/JSON；替换现在「只能生成静态图」的 diagram 技能 | WebView 性能、与 Flutter 手势冲突 |
| 二 | **人声分离**（htdemucs ONNX 316MB） | 短剧/口播：拆人声+伴奏，换配音、去原声 | 体量：必须找 2-stem 轻量变体并量化 |
| 三 | **LiteParse**（13,043★ Apache-2.0 Rust） | 资料库 PDF → 带坐标的结构化文本，供模型引用 | Rust 交叉编译 aarch64 |

**建议顺序**：一（零 native、最快见效）→ 三（中等）→ 二（最重，且要先解决体量）。

---

## D. 本轮没做的事

- 没动任何 App 源码（本文只有调研与方案）。
- modlens **没装**（要先回答 A.4 的前置问题：多少模型是纯文本）。
- artemis 方案**没实施**（等批准）。
- 三个梯队**没开始**。
