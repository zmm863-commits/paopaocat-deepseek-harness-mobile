---
name: make-slides
description: "做 PPT / 幻灯片 / 演示文稿（原生形状 + 自动排版）"
---

# 做一份幻灯片（生成真正的 .pptx）

本技能负责：把主题或材料变成可交付的 `.pptx`（16:9）。
**产出是原生形状**：色块、圆角卡片、圆点、连线、柱子、文字都是 PowerPoint 自己的对象，
打开后能选中、能改颜色、能改字 —— 不是把网页截成一张图塞进去。

**排版不用你算**：你只写「内容 + 选哪种版式」，坐标、字号、分栏、放不下时怎么缩/怎么分页，
全部由 `pptx-design.mjs` 算。所以**不要**在 JSON 里写坐标、字号、颜色（那些字段不存在）。

什么时候用：用户说「做 PPT / 幻灯片 / 演示文稿 / 把这份材料讲一讲」。
不要用 HTML 幻灯片顶替 PPT，除非用户明确说要 HTML。

## 0. 先问清关键缺口（一次问完）
- 主题是什么？讲给谁听（工作汇报 / 教学 / 路演）？大概几页？
- 有没有现成材料（工作区里的文件名，或直接把正文贴过来）？要不要配图（有本地图片文件吗）？
- 要不要演讲者备注？

主题明确、其余缺口无关紧要时，按合理默认先做，做完明确写出你的假设。

## 1. 收集材料
工作区里的材料用 node 读，不要用 `cat` 猜编码：

```sh
node -e "const t=require('node:fs').readFileSync('材料.md','utf8');console.log('字符数',t.length);console.log(t.slice(0,2000))"
```

材料里有**表格/对比/时间线/数字**时，别拆成一堆要点 —— 用对应的版式（见第 2 步），
那是这份 PPT 好看与否的主要差别。

## 2. 写大纲文件 outline.json
用**写文件工具**直接落盘，**不要用 heredoc / echo**（中文和引号会被 shell 吃掉）。

整份（除 `title` 外都可以省）：

```json
{
  "title": "封面标题",
  "subtitle": "一句话副标题（可选）",
  "author": "作者（可选）",
  "date": "2026-10-16（可选）",
  "theme": "ink",
  "footer": "页脚文字（可选）",
  "transition": "fade",
  "slides": []
}
```

`theme` 六选一：`ink`（墨蓝，默认）· `ocean`（海蓝）· `forest`（苔绿）·
`sunrise`（暖橘）· `berry`（莓紫）· `mono`（灰阶）。
`transition` 可选：`fade` / `push` / `wipe` / `cover` / `zoom`；不写就不加转场（更稳）。

每页写 `layout` 选版式（**不写也行** —— 引擎按内容字段猜，但明确写更准）：

| layout | 什么时候用 | 需要的字段 |
|---|---|---|
| `cover` | 封面（**第一页自动是封面**，不用自己写） | `title` / `subtitle` |
| `section` | 章节分隔（讲到大章节时） | `number`（如 `"01"`）/ `title` / `subtitle` |
| `toc` | 目录 / 议程（4–8 条） | `items` |
| `bullets` | 默认：一个观点的几条支撑 | `bullets` |
| `cards` | 并列的 2–8 件事（每件一句说明） | `items: [{title,text}]` |
| `timeline` | 流程 / 阶段 / 里程碑（≤5 步） | `steps: [{title,text,date}]` |
| `compare` | 两方案对比 / 前后对比 / 利弊 | `left` / `right`，各 `{title,bullets}` |
| `metrics` | 关键数字（2–4 个，如"92% 完成度"） | `metrics: [{value,label,note}]` |
| `chart` | 一组数据（柱状 `bar` / 条形 `hbar` / 堆叠 `stacked`） | `chart: {kind,unit,data:[{label,value}]}` |
| `quote` | 一句引用 / 一条原则 | `text` / `cite` |
| `image` | 配图（图在左、文在右） | `image`（**本地文件的完整路径**）/ `caption` / `bullets` |
| `end` | 结尾 | `title`（如"谢谢"） |

举例：

```json
{
  "title": "手机版 DSH 的一页纸说明",
  "subtitle": "这一批改了什么",
  "theme": "ocean",
  "footer": "内部说明",
  "transition": "fade",
  "slides": [
    { "layout": "toc", "title": "讲三件事",
      "items": ["免 Key 通道", "通道自检", "原生 PPT"] },
    { "layout": "bullets", "title": "做了什么",
      "bullets": ["第一条要点", { "text": "支撑细节", "level": 1 }, "第二条要点"],
      "notes": "讲这页时要说的话（可选）" },
    { "layout": "compare", "title": "两条通道",
      "left": { "title": "A 方案", "bullets": ["优点一", "代价一"] },
      "right": { "title": "B 方案", "bullets": ["优点一", "代价一"] } },
    { "layout": "chart", "title": "包体变化",
      "chart": { "kind": "bar", "unit": " MiB",
                 "data": [{ "label": "上版", "value": 106 }, { "label": "本版", "value": 76 }] } },
    { "layout": "end", "title": "谢谢" }
  ]
}
```

写作要求：
- **一页一个观点**。`bullets` 3–5 条，单条 ≤ 40 字（超了会自动缩字号，再超会自动分页 ——
  那是兜底，不是让你写长）。
- 全文 `**这样**` 可以加粗（会变成真的粗体），别用别的 Markdown 语法。
- 封面由 `title` + `subtitle` 自动生成，**不要**自己再写一页「封面」。
- `notes` 只给需要口述的页写。
- 半角双引号、不要尾随逗号。
- 数据放 `chart`，别写成"第一季度增长 12%"这种要点（那正是 `chart` 存在的理由）。

## 3. 生成 .pptx

```sh
node "$DSH_ANDROID_TOOLBOX/make-pptx.mjs" outline.json "输出.pptx"
```

成功时最后一行形如：
`[make-pptx] ok slides=14 notes=0 media=1 parts=42 bytes=35123 out=/.../输出.pptx`

> **⚠️ 看不到任何输出时怎么办（省 token 的规矩，2026-10-20 真机教训）**
> 先看 `echo "exit=$?"`（0 = 成功；2 = 调用方式不对；1 = 参数/大纲有问题）。
> **绝对不要**去 `grep` / `readFileSync` 这个脚本的源码 —— 它 50 KB、`pptx-design.mjs` 62 KB，
> 读一遍就是几万 token，而且真机上那次为了查"为什么没输出"连续用了 **12 条 bash**、把一整轮
> 的额度都烧在这上面。正确顺序是：
> 1. `node "$DSH_ANDROID_TOOLBOX/make-pptx.mjs" outline.json 输出.pptx; echo "exit=$?"`
> 2. 报错原样贴出来（stderr 会以 `[make-pptx] 错误：` 开头），按提示改大纲；
> 3. 仍然失败就**如实告诉用户**卡在哪一步，不要自己钻源码。

- `slides` 是**真实页数**（含自动拆出来的续页），报页数用它。
- 有警告（图片找不到、字段类型不对）会打在 stderr，以 `[make-pptx] 警告：` 开头 ——
  **要把警告解决掉**，不要无视。
- 想核对实际用了哪些版式：加 `MAKE_PPTX_DEBUG_LAYOUTS=1` 再跑一次。

## 4. 自检（别跳过）

```sh
node -e "const f=require('node:fs');const b=f.readFileSync('输出.pptx');console.log('字节',b.length,'头两字节',b.subarray(0,2).toString())"
```

- 大小应达到几十 KB；头两字节必须是 `PK`（pptx 就是 ZIP 包）。
- 不对就回第 2 步改大纲重跑，**不要**在对话里贴一个没生成的假路径。

## 5. 交付
最终回复里给到：产物**路径原样**、页数、一句话大纲摘要。提示用户可在「资料库」里预览和分享。

## 诚实约束（写进交付说明，别含糊）
- **数据图是用形状画的**（柱子/条形/堆叠条 + 数值标签）：能被任何人一眼看懂、能改颜色尺寸，
  **但不是** PowerPoint 的"图表对象" —— 数据改了要重新生成，不能在 PPT 里改数据源。
- **动画**只做**换页转场**（`transition`）；**没有**逐元素动画、**没有**音频/旁白嵌入。
- 图片只吃**本地文件**（png / jpg / jpeg / gif / bmp，单张 ≤16MB）：**不联网抓图**。
  路径不存在时会画一个占位方块并给警告 —— 那时要么补图，要么删掉这一页的图。
- 本机**没有** python / pandoc / libreoffice，也不能 npm install；不要调 `python-pptx`、不要试 `soffice`。
- 用户要 .docx 时**能做了**（`make-docx.mjs`，见 AGENTS.md 的本机环境说明）；要 .pdf 等本机做不出的格式时
  如实说做不到，替代路径是给 .pptx 或 Markdown。
- 不编造路径，不假装已生成。

## 常见错误
- 在大纲里写坐标/字号/颜色 → 那些字段**不存在**，会被忽略；要改外观请换 `layout` 或 `theme`。
- 大纲里混进中文引号或尾逗号 → 脚本报 `不是合法 JSON`，改回半角并删尾逗号。
- 路径没加引号且含空格/中文 → 用双引号把整个路径包住。
- 一页塞太多要点 → 会自动拆成「（续）」页；更该做的是把它拆成两页不同观点的内容。
- 同一页改两轮仍不满意 → 把大纲贴给用户确认，别自己猜。
