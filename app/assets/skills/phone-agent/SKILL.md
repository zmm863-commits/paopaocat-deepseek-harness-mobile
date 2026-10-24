---
name: phone-agent
description: 操作手机界面（看屏幕/点按/输入/开应用）。用户说「帮我打开XX」「帮我点一下XX」「屏幕上有什么」时使用。
---

# 手机屏幕助手

你现在**能操作这台手机**：看屏幕、读控件、点、滑、开应用。用户说「帮我看头条热点」「帮我打开剪映剪一下」这类话时，用本技能。

## 先决条件（跑之前先确认）

```bash
node toolbox/phone-agent.mjs status
```

- `connected: true` → 可以用。
- 报「总开关是关的」→ 告诉用户：**设置 → 应用 → 屏幕助手 → 打开总开关**。
- 报「无障碍服务没连上」→ 告诉用户：**系统设置 → 无障碍 → DSH 屏幕助手 → 开启**。
- 报「找不到 phone-agent.json」→ 桥没起来，让用户重启一次 App。

**这三条都不要自己去改系统设置**，只能引导用户点。

## 命令

> 路径都是相对 App 私有目录的（`filesDir`），`toolbox/phone-agent.mjs` 已随包落盘。

| 命令 | 作用 |
|---|---|
| `node toolbox/phone-agent.mjs status` | 桥/无障碍状态、当前前台包名 |
| `node toolbox/phone-agent.mjs shot [out.png]` | **截当前屏幕**存成 PNG，打印路径（默认 `/tmp/pa-shot.png`） |
| `node toolbox/phone-agent.mjs nodes` | 控件树 JSON（每项带 `text`/`desc`/`cls`/`clickable`/`bounds`） |
| `node toolbox/phone-agent.mjs find <文字>` | 在控件树里找含该文字的控件，**打印中心坐标** |
| `node toolbox/phone-agent.mjs tap <x> <y>` | 点（坐标是屏幕像素，与 `bounds` 同一坐标系） |
| `node toolbox/phone-agent.mjs swipe <x1> <y1> <x2> <y2> [ms]` | 滑 |
| `node toolbox/phone-agent.mjs apps [关键词]` | 列手机里的应用（`标签<TAB>包名`，系统应用带 `[系统]`） |
| `node toolbox/phone-agent.mjs launch <包名或应用名>` | 打开应用（**可以只给名字**，如 `launch 头条`） |

## 两条路线：先用节点树，没有再用截图

### 路线 A（首选）：读控件 → 点坐标

```bash
node toolbox/phone-agent.mjs find 设置        # → 打印 center: [1122, 2821]
node toolbox/phone-agent.mjs tap 1122 2821    # 点它
```

优点：**准**（坐标来自真实控件，不会点偏）。
适合：绝大多数原生 App、Flutter App（DSH 自己就是）、微信/头条/浏览器这类。

### 路线 B（兜底）：截图 → 自己看图决定点哪

```bash
node toolbox/phone-agent.mjs shot /tmp/s.png
```

然后**读这张图**（你有视觉能力时），判断按钮在哪，再 `tap`。

**什么时候必须走 B**：
- `find` 返回「界面上没找到」→ 说明界面是**自绘**的（游戏、剪映、视频播放器控件）；
- 这类界面**没有控件树**，只能靠看图。

⚠️ 走 B 时坐标是**目测**的，容易偏。做法：点完**再截一张图确认点中了没有**，没中就调坐标重试（最多 3 次，别死循环）。

## 走错路怎么办：`key`

```bash
node toolbox/phone-agent.mjs key back      # 返回上一页
node toolbox/phone-agent.mjs key home       # 回桌面
```

**任何一步点偏了、进了弹窗、页面不对 —— 先 `key back`，别硬点。**
连按 3 次 back 还回不去，就 `key home` 重来。

## 输入文字：`input`

```bash
node toolbox/phone-agent.mjs tap <搜索框坐标>   # 先点中输入框（聚焦）
node toolbox/phone-agent.mjs input 电影票        # 再写字
```

⚠️ 两个已知限制：
- **自绘界面的输入框**（游戏/部分 App 自绘搜索栏）认不出来，会报「没能写入」→ 那时**如实让用户自己打字**；
- 有些框会**清空原内容再写**（不是追加）。要追加就先读出来拼好。

## 等页面：`waittext` 比 sleep 可靠

```bash
node toolbox/phone-agent.mjs waittext 电影票 8000   # 最多等 8 秒
```

退出码 0 = 出现了；1 = 没等到。**没等到不是失败，可能只是字在图片里** —— 那就 `shot` 看图。

---

## 用户的两个典型场景

### 「帮我看今日头条的热点新闻」

```bash
node toolbox/phone-agent.mjs launch 头条      # 打开它
sleep 3
node toolbox/phone-agent.mjs shot /tmp/t.png  # 看首页
# 读图 → 找到"热点"入口 → find 热点 或 目测坐标 tap
# 再 shot 一次，把看到的内容用中文总结给用户
```

**关键**：最后要**把看到的内容讲出来**（用户要的是新闻，不是"我点了两下"）。

### 真实跑通过的完整流程（2026-10-23 实测，可直接照抄）

**任务**：在淘宝搜「电影票」。**实际遇到的障碍：两个弹窗。**

```bash
launch 淘宝
sleep 7
# 障碍一：双11 消费券弹窗 → 先在 nodes 里找"关闭按钮"
#   → 找到 bounds=[553,2133,671,2251] → 中心 (612,2192)
tap 612 2192            # 关掉它
tap 532 318             # 点搜索框
input 电影票             # 写进去（中文 OK）
tap 1073 318            # 点「搜索」按钮
# 障碍二：系统定位权限弹窗 → 点"不允许"（不要给购物 App 定位）
# → 然后才看到搜索结果
```

**这个例子要记住的**：
1. 开 App 后**必先 `nodes` 看一眼有没有弹窗**，别直接点目标；
2. 弹窗的关闭按钮通常在 `nodes` 里叫「关闭按钮」「关闭」「×」，`clickable=true`；
3. 每一步之间 `sleep 2~3`，别急；
4. **遇到系统权限弹窗（定位/通知/相机）选「不允许」**，除非用户明确要；选了要告诉用户。

### 「帮我剪辑这段影片」（剪映）

```bash
node toolbox/phone-agent.mjs launch 剪映
sleep 4
node toolbox/phone-agent.mjs shot /tmp/j.png
```

剪映是**自绘界面**（`find` 找不到东西），必须一路 `shot → 看图 → tap → 再 shot 确认`。

⚠️ **这类流程很慢、容易失败**。诚实做法：
1. 先试 2~3 步，能走通就继续；
2. 走不通就**如实告诉用户"卡在哪一步、看到什么"**，别假装成功；
3. 也可以建议用户自己点开头几步，你接手后面的。

## 两种点击：手势 vs 节点（实测结论：本机都要求前台）

| 方式 | 命令 | 原理 | 前台要求 |
|---|---|---|---|
| 手势点击 | `tap x y` | 把触摸注入系统输入流 | **必须前台**（触摸只送前台窗口） |
| 节点点击 | `clicknode --pkg <包名> --text <文字>` | 直接调控件的 `ACTION_CLICK` 回调 | **理论上可不前台，但本机实测拿不到后台窗口** |

**2026-10-23 实测（moto XT2551-3 / Android 16）**：
`/windows` 只返回 `com.android.systemui` + 当前前台 App 两个窗口，
**切到后台的淘宝根本不在列表里** → 对后台 App 做 `clicknode` 报「没找到/没暴露」。

所以本机的现实是：**只能操作前台那个 App**。
（别的软件号称"后台点击"，多半是 root/Shizuku 注入了 `INJECT_EVENTS`，
或厂商特权，或者它的"后台"其实是"用户不看着 DSH、但目标 App 仍在前台"。）

**什么时候用 `clicknode`**：目标在前台、且你**不想依赖坐标**时 ——
它比 `tap x y` 稳（界面滚动/分辨率变了也不会点偏），因为它走的是控件本身。

```bash
node toolbox/phone-agent.mjs clicknode --pkg com.taobao.taobao --text 搜索
```

---

## ⚠️ 手势点击必须带 `--expect` 防误点

触摸只送到**当前前台窗口**。如果中途来了通知、用户按了 Home、或别的 App 抢了前台，
你这一下就会点到**别的 App 上**（往聊天框里发乱码、改掉设置、甚至点掉东西）。

所以：**每次 `tap` / `swipe` 都带 `--expect <包名>`**。

```bash
node toolbox/phone-agent.mjs tap 612 2192 --expect com.taobao.taobao
```

前台不是这个包 → 服务端**拒绝这次点击**（409）并告诉你实际前台是谁。
收到这个错误就：`status` 看现在在哪 → `key back` 或重新 `launch` 目标 App → 再来。

**包名从哪来**：`launch 淘宝` 的返回里带包名；或 `apps 淘宝` 查。

---

## 硬规矩（违反会出事）

0. **点之前带 `--expect`**（见上一节）—— 不带就等于允许点歪到别的 App。
1. **不要盲点**。每次 `tap` 前要么有 `find` 给的坐标，要么刚看过截图。**绝不猜坐标**。
2. **点完要确认**。重要操作后 `shot` 一次，看是否真的生效。
3. **不碰钱、不碰密码、不点"确认支付/删除/卸载"**。这类动作要先问用户，得到明确答复再动。
4. **不要连续快速点**。每步之间留 1~2 秒（界面动画没走完时点击会落在旧位置）。
5. **FLAG_SECURE 页面截不到图**（银行、支付密码页）→ `shot` 会黑屏或报失败。如实说，别硬来。
6. **总开关关掉就停**。用户关了开关，你就不要再尝试任何操作。

## 参数

- 坐标：**屏幕物理像素**，与 `nodes` 输出的 `bounds: [left, top, right, bottom]` 同一坐标系。
  中心点 = `[(left+right)/2, (top+bottom)/2]`。
- 截图分辨率：这台机通常是 `1224 × 2992`（`/status` 不报尺寸，`shot` 出来的 PNG 就是真实像素）。
