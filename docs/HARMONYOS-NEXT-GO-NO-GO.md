# HarmonyOS NEXT 适配可行性 · Go/No-Go 验证结论

- 日期：2026-10-21
- 范围：只做可行性判定，不改动现有 Android 工程
- 结论对象：`dsh-mobile`（Flutter 壳 + 内嵌 Node 运行时）
- 关联架构文档：`docs/ANDROID-LOCAL-PACKAGING.md`

---

## 0. 一句话结论

**Node 在鸿蒙上能跑，但不是在现有 dsh-mobile 工程里、也不是用现有 Android 的 `libnode.so`。**

分层判定：

| 问题 | 结论 | 依据等级 |
|---|---|---|
| 鸿蒙上能否跑通 Node.js | **GO** | 第三方真机实证 + Node 官方构建支持 |
| 现有 dsh-mobile 工程能否直接移植 | **NO-GO** | 本机静态分析 + 平台机制 |
| 重做鸿蒙宿主（ArkTS + 进程内 Node） | **条件性 GO** | 已有开源参考实现，但工具层/UI/分发要重做 |
| 能否上架华为应用市场 | **待定（高风险）** | 第三方结论：ELF 需 AGC 二进制证书，个人开发者难获得 |

一句话：**技术可行性成立，产品可行性取决于你是否接受“重做宿主 + 纯 JS 工具层 + 前台运行 + 可能只能侧载”这四件事。**

---

## 1. 证据分级与边界

本机环境：无鸿蒙设备、无 DevEco Studio、无 OHOS SDK、无 `hdc`。因此**本轮没有做真机复现**，结论由三类证据交叉得出：

| 等级 | 含义 | 本轮使用 |
|---|---|---|
| A | 真机实测（公开、可追溯） | 三个独立项目 + 一篇真机笔记 |
| B | 官方/上游事实 | Node 上游 PR、`configure.py` 支持 |
| C | 本机静态分析 | DSH 运行时依赖、Android `libnode.so` 的 ELF 属性 |
| D | 推断/未取证 | 性能、上架审核、手机端具体机型差异 |

**不要把 A 级第三方结论当成我们自己的实测。** 真机复现需要一台目标设备 + DevEco + 签名，见 §7。

---

## 2. 证据链

### 2.1 A 级：真机跑通记录

1. **`lzzhij/harmonyos-node-notes`（Mate 70 / HarmonyOS 7 / API 26 / arm64）**
   - Node **v24.2.0** 在 App 进程内运行成功，`platform=openharmony`。
   - 端上 HTTP 服务可被 `hdc fport` 访问，ArkWeb 加载 Web UI。
   - 载荷就是 `@deepseek-ai/dsh`（`node_modules/@deepseek-ai/dsh/lib/bin.js`），HAP ≈ 71.8 MB。
   - Agent 完成真实任务（创建文件、写入、读回）。
   - 明确失败结论：`childProcessManager` 返回 **801**；后台常驻 **9800005 / 9900002**；`spawnSync → EACCES`。
   - 来源：<https://github.com/lzzhij/harmonyos-node-notes>

2. **`fellow99/dsh-desktop-ark`（ArkWeb + 进程内 libnode，HarmonyOS 6.1 / API 24 / 2in1）**
   - libnode **v24.2.0** + DSH **0.2.1-rc.2**，HAP ≈ 88 MB，载荷 ≈ 42 MB。
   - 默认 **compat（`--jitless`，零 ACL）**，侧载安装成功，真机 `phase=ready`。
   - 能力矩阵：读/写/编辑、工作区选择、图片、Git（21 工具纯 JS）、子 agent、skills、workflow、`node:sqlite` FTS5 可用；bash/grep/glob/删除/移动/复制/chmod 受限。
   - 来源：<https://github.com/fellow99/dsh-desktop-ark>

3. **`fellow99/dsh-desktop-hos`（Electron 37 / Node 22.17，2in1）**
   - DSH Host + 官方 Web UI 同源跑通；需要 ACL `kernel.ALLOW_WRITABLE_CODE_MEMORY`（JIT），**仅 2in1 / tablet**。
   - 来源：<https://github.com/fellow99/dsh-desktop-hos>

4. **`fellow99/pi-desktop-ark`（手机 JUY-AL80）**
   - compat（`--jitless`）在手机上 **1.6 s 就绪**；同机型 jit 形态即使权限位显示已授予，仍在 `libnode_bridge` 内 SIGTRAP 秒崩。
   - 来源：`dsh-desktop-ark/docs/ACL-无ACL评估.md` §3.1 / §10.6

### 2.2 B 级：Node 官方支持

- Node 上游 PR **#58350 `build: add support for OpenHarmony operating system` 已于 2025-05-21 合并**。
- `configure.py` 的 `valid_os` 已包含 `openharmony`。
- 因此 Node 24+ 可交叉编译到 OHOS；但仍需自行处理 V8 JIT（W^X）与设备权限，**“能编译”不等于“能开 JIT”**。
- 来源：<https://github.com/nodejs/node/pull/58350>

### 2.3 C 级：本机静态分析（dsh-mobile 现状）

从 `dist/paopaocat-preview-0.79-20261021x-full-arm64-v8a.apk` 中提取的运行时：

| 项 | 实测值 | 对鸿蒙的含义 |
|---|---|---|
| `libnode.so` | 48 MB，AArch64，**含 PT_INTERP**（PIE），v26.4.0 | **不能直接复用**：鸿蒙要求真共享库（无 PT_INTERP），否则 `dlopen` 后 V8 TLS 崩溃 |
| `NEEDED` | `libc.so`/`libm.so`/`libdl.so`/`libz1.so`/`libcrypto3.so` 等 | Android bionic/Termux 依赖，OHOS 是 musl，**ABI 不兼容** |
| DSH 运行时 | 0.1.7-rc.2，9,996 文件，132 MB | 需重新打包/裁剪为 HAP 载荷 |
| 原生 `.node` | 仅 `node-pty` 的 darwin/linux prebuild | 鸿蒙无预编译；PTY 也不可用，**终端类能力不可达** |
| WASM | 1 个 `sharp-wasm32` | `--jitless` 下 `WebAssembly === undefined`，图片能力需替代 |
| `flock` | `node-addon-system/flock` 对非 linux/darwin 直接抛 `ERR_FLOCK_UNSUPPORTED_PLATFORM` | 需要 no-op/纯 JS shim（项目已有 Android 版可复用） |
| 原子写 | `dsh-session-persistence-jsonl` 用 `fs.link` | 鸿蒙无硬链接，需要 copy/rename 降级（项目已有 shim） |
| `bash` | `dsh-bash-local` 固定 `spawn('bash', ['-c', ...])` | 鸿蒙手机 seccomp 禁止 exec，**不可用** |
| `grep`/`glob` | `dsh-tool-fs-search` 依赖 `@vscode/ripgrep` 二进制 | 无 arm64-ohos 产物，**需纯 JS 后端** |
| 现有 Android shim | `android-exec-shim.cjs` 依赖 `/system/bin/sh` 可执行 | 鸿蒙手机不可执行，**整套执行 shim 失效** |

---

## 3. Android 与 HarmonyOS NEXT 的关键差异

| 维度 | Android（现状） | HarmonyOS NEXT | 影响 |
|---|---|---|---|
| 启动 Node | `jniLibs/libnode.so` + `Process.start` | **只能进程内 `dlopen` + `node::Start`**；seccomp 禁止 exec | 现有 Dart 侧启动逻辑全部作废 |
| 子进程 | 可用（nativeLibraryDir 例外） | `childProcessManager` 801；`spawnSync` EACCES | 无法用子进程隔离/看门狗/重启 |
| Node 重启 | 可重拉进程 | **同一进程内 `node::Start` 只能一次** | 崩溃 = 重开 App |
| JIT | 可用 | 手机 W^X 拒绝 `PROT_EXEC` → 必须 `--jitless` | 性能 7–10× 慢；WASM 消失 |
| `fetch` | 可用 | `--jitless` 下 undici/llhttp 的 WASM 不可用 | **必须写纯 JS fetch 垫片**，否则模型调用全挂 |
| 文件锁 | bionic 无 flock → no-op shim | 同样无 flock → no-op shim | 可复用现有 shim |
| 硬链接 | SELinux 禁 → copy 降级 | 禁 → `open(wx)`/rename | 可复用现有 shim |
| 后台 | 前台服务可常驻 | 普通应用不能无限常驻（3–4 分钟后被挂起） | DSH 长任务必须前台 |
| UI 框架 | Flutter | **Flutter 官方不支持**；ArkTS/ArkWeb | 4.3 MB Dart UI 不能复用 |
| 分发 | APK 签名 | HAP 签名 + ELF `.codesign`；上架可能需 AGC 二进制证书 | 个人开发者可能只能侧载 |
| 包体 | 227 MB APK | 参考实现 72–88 MB HAP（裁剪后） | 体积反而可控 |

---

## 4. 关键阻塞点（按严重度排序）

### 4.1 进程模型（硬约束）

- 不能在鸿蒙手机 App 里 `exec` 任何外部程序；`/system/bin/sh` 存在但不可执行。
- 必须：ArkTS 宿主 → NAPI（C++）→ **detached 线程** → `dlopen("libnode.so")` → `dlsym("_ZN4node5StartEiPPc")` → `node::Start(argc, argv)`。
- 硬性配套：
  - `libnode.so` 必须是真共享库（`--shared`，无 `PT_INTERP`）；
  - 一起打包 `libc++_shared.so`；
  - SIGSYS shim 把 `io_uring_setup` 的 seccomp trap 转成 `-1`，并 `UV_USE_IO_URING=0`；
  - `--expose-internals` + 纯 JS `require-builtin` 桩；
  - 启动参数 `--jitless --no-verify-heap`（手机必须）；
  - 单次启动，不设计“进程内重启”。

### 4.2 JIT / WASM / fetch（决定“能不能说话”）

- 手机端 `--jitless` 是硬要求；`WebAssembly` 变为 `undefined`。
- DSH 的模型调用走全局 `fetch`，而 Node 24 的 `fetch` 依赖 undici 的 **WASM llhttp**。
- 因此 compat 形态下**必须安装纯 JS `fetch` 垫片**（原生 `node:http/https` + `ReadableStream`，并封掉 `node:http` 的惰性 getter 阻断 undici 初始化）。
- 参考实现已有 ~960 行成熟实现；这是 POC 的**第一个硬门**：没有它，UI 能开、一发消息就失败。

### 4.3 工具层（决定“agent 能不能干活”）

| 能力 | 鸿蒙手机 | 修复方式 |
|---|---|---|
| `bash` / shell | ❌（无 exec） | 纯 JS 工具层；或仅在 2in1 上走常驻 sh |
| `grep` / `glob` | ❌（无 ripgrep 二进制） | 纯 JS 复刻 rg 的输出契约（NDJSON/路径列表） |
| 删除/移动/复制/chmod | ❌（上游 `ctx.fs` 无原语） | 物化期补丁或自建 seam 工具包 |
| PTY / 终端 | ❌（无 `/dev/ptmx`） | 不支持，UI 隐藏 |
| Git | ✅（`isomorphic-git` 纯 JS，21 工具） | 直接可用 |
| 读写/编辑/图片/工作区 | ✅ | 复用上游 + 宿主桥 |

### 4.4 后台存活

- 普通应用无法无限常驻；`requestSuspendDelay` 只能把切后台时间从 ~90 秒延到 **3–4 分钟**。
- `TASK_KEEPING` 在手机上报 9800005；`DATA_TRANSFER` 进后台后再申请报 9900002。
- 结论：**DSH 必须保持前台**；长任务被切后台会中断。产品上要设计“回到前台续跑”的提示。

### 4.5 UI：两条路，成本差一个量级

| 路线 | 做法 | 成本 | 体验 |
|---|---|---|---|
| A. ArkWeb + 官方 DSH Web UI | ArkTS 壳，进程内 node 起 `dsh web`，ArkWeb 加载 `127.0.0.1` | 低（参考实现已跑通） | 桌面布局，手机上偏挤 |
| B. ArkTS 重写手机 UI | 复用 DSH 本地 HTTP/WS API，ArkUI 重写现有 Flutter 页面 | 高（4.3 MB Dart UI） | 接近现有 dsh-mobile |
| C. Flutter OHOS 社区分支 | 保留 Dart UI，FFI 调 NAPI | 中高 | 依赖非官方分支 + 插件生态（webview/sherpa/file_picker/secure_storage 均无 OHOS 实现） |

**不建议 C**：Flutter 官方不支持 OHOS，现有插件在鸿蒙上大多没有实现，且 `Process.start` 无论如何都要换成 FFI/NAPI，收益不足以抵消风险。

### 4.6 分发与上架（商业可行性）

- 第三方结论：**随包携带 ELF（`libnode.so`）需要 AGC 的二进制证书（`certType: 4`），个人开发者很难获得**。
- 侧载/调试签名可以安装（参考实现已验证）；**公开上架需向华为确认**。
- 这意味着：如果目标是应用市场分发，技术可行不等于商业可行；如果目标是自有设备/企业分发/内部使用，则不阻塞。

### 4.7 版本差

- 参考实现基于 **DSH 0.2.1-rc.2 + Node 24.2.0**。
- 本项目是 **DSH 0.1.7-rc.2 + Node 26.4.0**。
- 需要确认：0.1.7 是否有 node 26 专有依赖；升级到 0.2.x 的成本；OHOS 版 Node 26 是否已有可复现构建（Node 官方支持从 24 起，26 应可构建但需验证）。

---

## 5. 对现有 dsh-mobile 工程的影响

| 现有资产 | 能否复用 | 说明 |
|---|---|---|
| Flutter UI（`app/lib`，4.3 MB） | ❌ | 鸿蒙不支持 Flutter 官方；要么 ArkTS 重写，要么改用 Web UI |
| Android 宿主（`MainActivity` / 解压 / jniLibs） | ❌ | 鸿蒙 HAP 结构、权限、签名、启动方式全不同 |
| `libnode.so`（Termux/Android） | ❌ | bionic + PIE，鸿蒙不可用；必须用 OHOS NDK + Node 24 `--shared` 重建 |
| `android-fs-shim.cjs`（硬链接降级） | ✅ | 纯 JS，鸿蒙同样无硬链接 |
| `android-shim-flock.js`（no-op 锁） | ✅ | 纯 JS，单进程语义一致 |
| `android-shim-require-builtin.js` | ✅ | 纯 JS，配 `--expose-internals` |
| `android-exec-shim.cjs`（bash/node 改写） | ❌ | 依赖 `/system/bin/sh` 可执行；鸿蒙手机禁止 exec |
| 工具箱（`assets/toolbox/*.mjs`，纯 JS） | ✅ | 不依赖子进程的部分可直接复用 |
| 远程模式（连电脑 DSH） | ✅ | 不需要本地 node，风险最低的过渡形态 |
| ACP stdio 协议层 | ⚠️ | 进程内 node 无独立 stdio；需改为本地 socket/HTTP 或直接复用 `dsh web` 的 HTTP/WS |

---

## 6. 建议路线

### 路线 1：先做“技术验证版”（推荐，1–2 周）

目标：用最小宿主证明 `node + dsh + 一次模型对话` 在目标手机上成立。

1. 安装 DevEco Command Line Tools（API 24/26），用 OHOS NDK 构建 Node 24 `--shared`。
2. 校验产物：`llvm-readelf -l libnode.so | grep -c INTERP` 必须为 **0**；`llvm-nm` 能找到 `_ZN4node5StartEiPPc`。
3. ArkTS 壳 + NAPI + detached 线程 + SIGSYS shim + `UV_USE_IO_URING=0` + `--jitless`，跑通 `node -e "console.log(process.platform, process.version)"`。
4. 把 DSH 载荷打成 `tar.gz` 放 `rawfile`，由 **Node 自己解包**（避免鸿蒙解压器写入的文件 Node 读不到）。
5. `require(.../dsh/lib/bin.js)` 跑 `--profile headless --dump-default-config`。
6. 起 `dsh web`，ArkWeb 加载 `127.0.0.1`，发一条模型请求（验证纯 JS fetch 垫片 + SSE）。

**验收线**：`node --version`、`dsh --version`、`--dump-default-config`、Web UI 首屏、一条流式模型回复。五条全过才叫“跑通 node + DSH”。

### 路线 2：产品级手机版（2–4 人月）

在路线 1 之上：

- 扩 `deviceTypes` 到 phone，处理手机权限/窗口/返回键/文件选择器。
- 补纯 JS 工具层：grep/glob、删除/移动/复制/chmod、bash 替代或明确禁用。
- 补纯 JS fetch 垫片 + SSE。
- 决定 UI：ArkWeb 版（快）或 ArkTS 重写（体验好）。
- 前台保活、切后台恢复、崩溃重开提示。
- 签名/分发方案（侧载 vs 企业 vs 上架）。
- DSH 0.1.7 → 0.2.x 升级评估（或反向把参考实现的 shim 移植到 0.1.7）。

### 路线 3：过渡产品（低风险）

只做 ArkTS 远程客户端，连电脑上的 DSH（现有 `bridge` 已具备 WebSocket/ACP 能力）。
优点：1–2 周可交付，不碰 node/签名/上架；缺点：不是“端侧离线”。

---

## 7. 未验证项 / 需要确认

| # | 项 | 说明 |
|---|---|---|
| 1 | 目标设备形态 | 手机 / 平板 / 2in1 的限制差异很大（2in1 有 sh、JIT 权限；手机没有） |
| 2 | HarmonyOS 版本 | 参考实现覆盖 API 24（2in1）与 API 26（Mate 70）；目标机型需实测 |
| 3 | 是否需要上架 | 决定 ELF 二进制证书是否是硬阻塞 |
| 4 | 真机复现 | 本机无设备/SDK，§6 路线的第 1–6 步均需在设备上跑 |
| 5 | 性能 | `--jitless` 下 DSH 冷启动参考 1.6 s，但长回合/工具链耗时需实测 |
| 6 | DSH 0.1.7 兼容性 | 参考实现是 0.2.1-rc.2；0.1.7 的 profile/插件差异需评估 |

---

## 8. 参考

- 鸿蒙内嵌 Node 真机笔记：<https://github.com/lzzhij/harmonyos-node-notes>
- ArkWeb + 进程内 Node 的 DSH 实现：<https://github.com/fellow99/dsh-desktop-ark>
- Electron on HarmonyOS 的 DSH 实现：<https://github.com/fellow99/dsh-desktop-hos>
- Node 上游 OpenHarmony 支持 PR：<https://github.com/nodejs/node/pull/58350>
- 华为 Native Child Process 文档：<https://developer.huawei.com/consumer/cn/doc/harmonyOS-guides/capi-nativechildprocess-development-guideline>
- 本项目 Android 架构：`docs/ANDROID-LOCAL-PACKAGING.md`

---

## 附：本机已执行的验证命令（可复跑）

```bash
# 1) 现有 Android libnode.so 的平台属性
unzip -o dist/paopaocat-preview-0.79-20261021x-full-arm64-v8a.apk 'lib/arm64-v8a/libnode.so' -d /tmp/elf
readelf -h /tmp/elf/lib/arm64-v8a/libnode.so | grep -E 'Class|Machine|Type'
readelf -l /tmp/elf/lib/arm64-v8a/libnode.so | grep -c INTERP   # → 1（PIE，不可 dlopen）
readelf -d /tmp/elf/lib/arm64-v8a/libnode.so | grep NEEDED      # → bionic/Termux 库

# 2) DSH 运行时依赖面
unzip -q assets/dsh-runtime.zip -d /tmp/dshrt/tree
find /tmp/dshrt/tree -name '*.node' -o -name '*.wasm'
grep -rn "spawn('bash'" /tmp/dshrt/tree/app/node_modules/@deepseek-ai/dsh-bash-local/lib
grep -rn "ripgrep" /tmp/dshrt/tree/app/node_modules/@deepseek-ai/dsh-tool-fs-search/lib
```
