# ohos-node —— 让 DSH 在鸿蒙真机上真正跑起来（已成功）

![真机 Bot 界面](screenshot-bot-真机.png)

**2026-10-29 凌晨，HarmonyOS 真机 ADY-AL00（API 26）上完整跑通**：
node v24.2.0 进程内启动 → DSH 起 web 服务 → WebView 渲染出完整 Bot 界面。

## 最终方案（全部真机验证）

| 关卡 | 现象 | 解法 |
|---|---|---|
| W^X 禁可执行内存 | `mmap(PROT_EXEC)` 返回 **EINVAL(22)**（探针实测） | `--jitless` |
| jitless 禁 Wasm | `ReferenceError: WebAssembly is not defined`（undici 的 llhttp） | `jitless-shim.cjs`：拆 node:http 的 WebSocket getter + node-fetch 接管 fetch |
| seccomp trap io_uring | `SIGSYS`（signo=31）秒杀进程，无 CRASH 无 w8 | SIGSYS handler 把返回值设 **-1**（**不能动 PC**！）+ `UV_USE_IO_URING=0` |
| `import.meta.main` 恒 undefined | bin.js 静默退出 rc=0 | `dsh-cli-wrapper.mjs` 显式 `runCli()` |
| WebView 无鸿蒙实现 | `platform_webview_controller` 未实现 | `webview_flutter_ohos: ^3.15.0` |

## 关键排障细节（血泪）

### 1. SIGSYS 的 PC 不能动
真机实测：seccomp trap 时 **PC 已指向 svc 之后**（读到的是 `0x1402f426` = B 跳转指令，
不是 `svc #0` 的 `0xD4000001`）。照抄常见"PC += 4 跳过 svc"的写法会 SIGSEGV：

```
SIGSYS sc=425 pc=0x... insn=0x1402f426(是svc:0) UV_USE_IO_URING=0
CRASH signal=11        ← 因为我多跳了 4 字节
```

正确做法：**只设 `uc_mcontext.regs[0] = -1`，不碰 PC**。

### 2. 覆盖 globalThis.fetch 必须用直接赋值
`Object.defineProperty(globalThis,'fetch',...)` 会触发 realm 的 `syncExports`，
反而把 fetch 的 lazy getter 求值掉 → 加载内置 undici → 崩。
用 `globalThis.fetch = fn` 即可。

### 3. 为什么必须 node 24.2.0 + node-fetch
node 内置 undici 的 llhttp 是 WASM，jitless 下必崩。node-fetch 是纯 JS 走 `node:http`
（原生 llhttp，无需 WASM），且 runtime 里已自带 3.3.2。用 CJS `require(ESM)` 加载它。

## 交付物

- `lib/libnode.so` —— node v24.2.0 OHOS ARM64 共享库（社区验证产物，
  SHA256 `3019bf5f...`，来自 electerm/ohos-node-shared）
- `bridge/cpp/node_host.cpp` —— dlopen + node::Start + SIGSYS/SIGCRASH handler + 崩溃笔迹
- `bridge/ets/*.ets` —— DshNative（dsh/native 通道）/ NodeHost / EntryAbility
- `bridge/mainsrc-0.79/*` —— 0.79 Dart 侧补丁（bot_server 的 argv 与 shim 落盘）
- `screenshot-bot-真机.png` —— 真机 Bot 界面实证

## 真机日志实证

```
w7 node::Start 开跑
SIGSYS sc=425 ... UV_USE_IO_URING=0     ← 被兜住，继续跑
[jitless-shim] node-fetch 已接管 fetch，undici 不会被加载
dsh web: http://127.0.0.1:43157/?token=ZTk1SuAOzBRNkp2947...
```

## 仍待完善（非阻塞）

- WebView 内的「添加文件」选择器：`webview_flutter_ohos` 暂无 `setOnShowFileSelector`，
  代码里 `is AndroidWebViewController` 分支在 ohos 下跳过 —— 页面可浏览/可对话，上传按钮暂无响应。
- jitless 是解释器模式，CPU 占用高（实测 CPU 579%），长对话会慢；后续可评估申请
  `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`（AGC ACL）换回 JIT。
