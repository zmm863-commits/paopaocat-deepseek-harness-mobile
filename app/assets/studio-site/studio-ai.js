/**
 * AI 创作任务层 —— 创作台专用
 * ═══════════════════════════════════════════════════════════════════════
 * 这里定义创作台里能用模型做的 7 类事，以及每类的提示词。
 *
 * 设计取舍（重要）：
 *   Oh Story 的那 38 个技能是写给 DSH agent 的**多轮工作流**（带工具调用、
 *   跨文件约定、断点续跑）。网页版没有 agent 宿主，照搬只会水土不服。
 *   所以这里不复制技能，而是把其中**真正决定输出质量的写作规则**抽出来，
 *   做成「选任务 → 填要求 → 生成 → 写入文件」的单步卡片。
 *
 * 模型调用复用现成通道：app.js 的 callProxy('/v1/chat/completions', …)
 * 密钥始终来自用户浏览器（x-vendor-keys），服务端只做透传。
 *
 * 去 AI 味那套规则（毒句式分级、一级禁用词、标点禁令）提炼自
 * oh-story 的 story-deslop/references/banned-words.md，是纯文本清单，
 * 直接内联在这里，不依赖任何插件。
 * ═══════════════════════════════════════════════════════════════════════
 */
window.StudioAI = (function () {
  'use strict'

  // ── 写作原则（所有创作型任务共享的底子）────────────────────────────
  var CRAFT = [
    '你是一位职业中文网文作者，不是助手。直接产出成稿，不要解释你在做什么。',
    '',
    '写作铁律：',
    '1. 场景化，不概述。每一段都要有具体的时间、地点、动作、对白或物件。',
    '2. 用行为与对白展示情绪，不写"他很愤怒"这类直接命名情绪的句子。',
    '3. 视角要稳。第三人称限知就贴着主角的所见所感，不要跳进别人脑子里。',
    '4. 对白要有潜台词：人物说的话和他的真实目的之间有落差。',
    '5. 段落短。中文网文习惯单段 1–3 句，超过 4 句就拆。',
    '6. 章末留钩子：一个具体的悬念、决定或意外，不用空泛预告。',
    '7. 只推进剧情需要的细节；不写说明书式的设定倾倒。'
  ].join('\n')

  // ── 去 AI 味：精简版（给所有生成正文的任务防 AI 腔）─────────────────
  var SLOP_BRIEF = [
    '严禁以下 AI 腔（出现即算失败）：',
    '- "不是A，而是B"句式（含省略"而"的变体）',
    '- "他/她知道……"这种直述认知的句子',
    '- 万能状语"，带着一丝……"、"，仿佛……一般"',
    '- 眼中闪过 / 嘴角勾起 / 心中一动 / 心头一震 / 深吸一口气 / 不由得',
    '- 章末"他不知道的是……"这类空泛预告',
    '- 破折号 —— 与省略号停顿（中文正文里一律用句号、逗号或短句断句）',
    '- 华丽形容词堆叠（凛冽、深邃、冰冷、狡黠、不容置疑）'
  ].join('\n')

  // ── 去 AI 味：完整规则（给"去 AI 味"任务用）────────────────────────
  var SLOP_FULL = [
    '【一级任务：句式】下列句式出现即修：',
    '1. "不是A，（而）是B" —— 直接写 B，或换成自然表达。',
    '2. 跨段的"不是A。/也不是B。/只是C。" —— 压成 C，除非真的在做排除。',
    '3. "，带着……"万能状语 —— 删状语留主句，或换具体动作。',
    '4. 无情绪声线（"声音不大，却带着……""语气毫无波澜""听不出情绪"）—— 直接写台词内容、声音特征或动作。',
    '5. "他知道/她知道……" —— 用行为展示认知。',
    '6. "仿佛/犹如/宛若……一般" —— 删或白描。',
    '7. "眼中闪过一丝……""嘴角勾起一抹……" —— 删，改写他当场说的话或做的决定。',
    '8. "心中涌起一股……""心头一震" —— 写它改变了什么：选择、台词、物件或后果。',
    '9. 抽象的命运/开端收束（"命运露出獠牙""这一刻终于明白""反击才刚刚开始"）—— 回到角色当下可见的动作、对话或物理后果。',
    '10. 章末预告"他不知道的是……" —— 换成具体的钩子物件或事件。',
    '',
    '【二级任务：标点】',
    '正文（含叙述与对话）禁用：破折号 —— / —、双连字符 --、用省略号做停顿。',
    '一律改用句号、逗号、短句或动作断句。',
    '',
    '【三级任务：禁用词】出现即替换：',
    '情态：仿佛、犹如、宛若、如同、一丝、一抹、些许、几分、隐约、毫无征兆、几不可闻、微不可察',
    '动作：深吸一口气、不禁',
    '表情：眼中闪过、嘴角勾起、眉头微皱、眉眼低垂、瞳孔微缩、瞳孔一缩、指节泛白、眼神锐利、目光锐利',
    '心理：心中一动、心头一震、心下了然、心中暗道、心底泛起、不由得、心中一凛',
    '判断：不容置疑、不容置喙、不易察觉、显而易见、毫无疑问、不可否认、前所未有',
    '形容：坚定、闪烁着光芒、狡黠、深邃、凛冽、冰冷',
    '过渡：不由自主、情不自禁、自然而然、话锋一转',
    '',
    '【四级任务：密度】突然、陡然、骤然、猛然、瞬间、猛地、死死地、好像、似乎',
    '—— 这些不算错，但同一章里反复出现就是偷懒：用同义变体轮换，或改写成具体动作。',
    '',
    '【不能碰的】',
    '- 事实、剧情、人物关系、数字、专有名词一律不许改。',
    '- 不要把"他"改成"她"、不要改人名、地名、招式名。',
    '- 不要为了避开禁用词而删掉整句情节；宁可用白描重写，也不要丢信息。',
    '- 改完总字数应当与原文接近（±15% 以内）。'
  ].join('\n')

  // ── 上下文读取小工具 ───────────────────────────────────────────────
  async function readIfExists(FS, rel) {
    try { return String((await FS.read(rel)).content || '') } catch (e) { return '' }
  }
  function chapterNumber(name) {
    var m = String(name).match(/(\d+)/)
    return m ? parseInt(m[1], 10) : 0
  }
  async function listFiles(FS, rel) {
    try {
      var entries = await FS.list(rel)
      return entries.filter(function (e) { return e.type === 'file' })
    } catch (e) { return [] }
  }
  async function listChapters(FS) {
    var files = await listFiles(FS, '正文')
    var list = files
      .filter(function (e) { return /\.(md|txt)$/i.test(e.name) })
      .map(function (e) { return { rel: e.rel, name: e.name, n: chapterNumber(e.name) } })
    list.sort(function (a, b) { return a.n - b.n || a.name.localeCompare(b.name) })
    return list
  }
  async function readProjectContext(FS) {
    return {
      outline: await readIfExists(FS, '大纲/总纲.md'),
      world: await readIfExists(FS, '设定/世界观.md'),
      setting: await readIfExists(FS, '设定.md'),
      shortOutline: await readIfExists(FS, '小节大纲.md')
    }
  }
  function section(title, body) {
    var text = String(body || '').trim()
    if (!text) return ''
    return '\n\n【' + title + '】\n' + text
  }

  // ── 7 类任务 ───────────────────────────────────────────────────────
  var TASKS = [
    // ────────────────────────────────────────────────────────────────
    {
      key: 'chapter',
      icon: '✍️',
      name: '写正文 / 续写下一章',
      desc: '读已有大纲、设定与上一章，接着往下写',
      fields: [
        { key: 'title', label: '本章标题或章号', type: 'text', placeholder: '第 3 章 雨夜来客', default: '' },
        { key: 'requirement', label: '本章要求（可不填）', type: 'textarea', rows: 3, placeholder: '想写什么、要发生什么、必须有谁出场…' },
        { key: 'words', label: '目标字数', type: 'select', default: '2000', options: ['1200', '2000', '3000', '4000'] },
        { key: 'style', label: '叙述人称', type: 'select', default: '第三人称限知', options: ['第三人称限知', '第三人称全知', '第一人称'] }
      ],
      target: function (v) { return '正文/' + (v.title ? v.title.replace(/[/\\]/g, '_') : '新章') + '.md' },
      build: async function (v, ctx) {
        var chapters = await listChapters(ctx.FS)
        var prev = ''
        var prevName = ''
        if (chapters.length) {
          var last = chapters[chapters.length - 1]
          prev = await readIfExists(ctx.FS, last.rel)
          prevName = last.name
          // 上一章很长时只取后 2000 字（结尾才是接力点）
          if (prev.length > 2000) prev = '……（前略）\n' + prev.slice(-2000)
        }
        var project = await readProjectContext(ctx.FS)
        var user = '请写一章正文。'
        user += section('作品概况', [ctx.bookName ? '书名：' + ctx.bookName : '', ctx.projectKind === 'short' ? '类型：短篇' : '类型：长篇连载'].filter(Boolean).join('\n'))
        user += section('总纲', project.outline)
        user += section('世界观 / 设定', project.world || project.setting || project.shortOutline)
        if (prev) user += section('上一章（' + prevName + '，只看结尾接力）', prev)
        user += section('本章要求', v.requirement)
        user += '\n\n【本次任务】\n'
        user += '章名：' + (v.title || '（沿用大纲顺推）') + '\n'
        user += '人称：' + v.style + '\n'
        user += '目标字数：约 ' + v.words + ' 字\n'
        user += '\n要求：\n'
        user += '1. 承接上一章的处境与情绪，不要重新介绍人物。\n'
        user += '2. 只写这一章，写完即止，不要预告后文。\n'
        user += '3. 直接输出正文，第一行是章名（用 `# 章名` 的 Markdown 标题），不要任何说明或总结。'
        return {
          messages: [
            { role: 'system', content: CRAFT + '\n\n' + SLOP_BRIEF },
            { role: 'user', content: user }
          ],
          temperature: 0.9,
          max_tokens: Math.min(8000, Math.round(Number(v.words || 2000) * 2.2))
        }
      }
    },

    // ────────────────────────────────────────────────────────────────
    {
      key: 'outline',
      icon: '🗂',
      name: '生成大纲',
      desc: '从一句话想法生成总纲 / 分卷 / 章节细纲',
      fields: [
        { key: 'idea', label: '一句话想法 / 核心设定', type: 'textarea', rows: 3, placeholder: '例如：一个被宗门除名的杂役弟子，靠捡别人丢弃的功法碎片重新崛起', required: true },
        { key: 'level', label: '要哪一层', type: 'select', default: '总纲', options: ['总纲', '分卷', '章节细纲'] },
        { key: 'genre', label: '题材', type: 'select', default: '不限', options: ['不限', '玄幻', '仙侠', '都市', '悬疑', '言情', '历史', '科幻', '游戏体育', '年代'] },
        { key: 'length', label: '预计规模', type: 'select', default: '长篇（100 万字以上）', options: ['短篇（1–3 万字）', '中篇（10–30 万字）', '长篇（100 万字以上）'] },
        { key: 'units', label: '卷数 / 章数', type: 'text', placeholder: '例如：4 卷，每卷 40 章', default: '' }
      ],
      target: function (v) { return v.level === '总纲' ? '大纲/总纲.md' : (v.level === '分卷' ? '大纲/分卷.md' : '大纲/细纲.md') },
      build: async function (v, ctx) {
        var project = await readProjectContext(ctx.FS)
        var user = '请写一份' + v.level + '。'
        user += section('核心想法', v.idea)
        user += section('题材', v.genre)
        user += section('规模', v.length + (v.units ? '（' + v.units + '）' : ''))
        user += section('已有大纲（如有请在其基础上续写，保持设定一致）', project.outline)
        user += '\n\n【输出要求】\n'
        if (v.level === '总纲') {
          user += '- 用 `# 书名/项目名 · 总纲` 起头，然后依次给：一句话简介、主角与核心配角、核心冲突、金手指或差异化卖点、爽点节奏与升级线、结局方向。\n'
          user += '- 每部分 3–8 行，要具体到事件和选择，不要写"经历种种磨难"这类空话。'
        } else if (v.level === '分卷') {
          user += '- 按卷拆分，每卷给：卷名、卷内目标、主要冲突、卷末高潮与钩子、字数区间。\n'
          user += '- 卷与卷之间必须递进：对手变强、格局变大、代价变重。'
        } else {
          user += '- 给出连续章节的细纲，每章一行：`第N章 章名 —— 本章事件与钩子`。\n'
          user += '- 每章只写一个核心事件，章末必须有钩子（悬念/决定/意外）。\n'
          user += '- 章节之间要有因果推进，不要每章都是打怪升级的并列结构。'
        }
        user += '\n只输出 Markdown 正文，不要解释。'
        return {
          messages: [
            { role: 'system', content: CRAFT + '\n\n你是结构设计者，擅长冲突升级与钩子节奏。' },
            { role: 'user', content: user }
          ],
          temperature: 0.85,
          max_tokens: 4000
        }
      }
    },

    // ────────────────────────────────────────────────────────────────
    {
      key: 'character',
      icon: '🎭',
      name: '人物与世界观设定',
      desc: '生成人物卡、关系网或世界观条目',
      fields: [
        { key: 'kind', label: '要生成什么', type: 'select', default: '主角人物卡', options: ['主角人物卡', '配角人物卡', '人物关系网', '世界观条目', '势力 / 组织设定'] },
        { key: 'idea', label: '对象与想法', type: 'textarea', rows: 3, placeholder: '例如：女主，表面是人族医修，实为妖族遗孤', required: true },
        { key: 'count', label: '数量', type: 'select', default: '1', options: ['1', '3', '5'] },
        { key: 'tone', label: '基调', type: 'select', default: '不限', options: ['不限', '轻松', '沉重', '爽文', '悬疑'] }
      ],
      target: function (v) { return v.kind === '世界观条目' || v.kind.indexOf('势力') >= 0 ? '设定/世界观.md' : '设定/人物.md' },
      build: async function (v, ctx) {
        var project = await readProjectContext(ctx.FS)
        var existing = await readIfExists(ctx.FS, '设定/人物.md')
        var user = '请设计设定内容。'
        user += section('要生成的内容', v.kind + '，共 ' + v.count + ' 个')
        user += section('想法', v.idea)
        user += section('基调', v.tone)
        user += section('总纲（保持一致）', project.outline)
        user += section('世界观（保持一致）', project.world)
        user += section('已有人物（不要重复、不要冲突）', existing)
        user += '\n\n【设计要求】\n'
        if (v.kind.indexOf('人物卡') >= 0) {
          user += '每个人物必须给全这六项，且写成可执行的具体内容：\n'
          user += '1. 姓名与身份（一句话定位）\n'
          user += '2. 外在欲望：他明面上想要什么\n'
          user += '3. 内在缺陷：什么会毁了他（必须有，不能是完人）\n'
          user += '4. 秘密或把柄：别人不知道的事\n'
          user += '5. 说话方式：给一句他的典型台词\n'
          user += '6. 人物弧光：故事结束时他会变成什么样\n'
        } else if (v.kind === '人物关系网') {
          user += '- 用 Markdown 列表写清每对关系：`A → B：关系（张力所在）`。\n'
          user += '- 每条关系都要有潜在的冲突或代价，不要只有"好友""师徒"这种静态称呼。\n'
        } else {
          user += '- 每个条目给：名称、外观或形态、运行规则、它能带来什么、它的代价或限制、与主线的关系。\n'
          user += '- 规则必须可验证：读者能据此预判什么会发生、什么不会发生。\n'
          user += '- 不要写"强大无比""神秘莫测"这类无法验证的描述。\n'
        }
        user += '\n用 Markdown 输出，可直接存为设定文件。不要解释。'
        return {
          messages: [
            { role: 'system', content: CRAFT + '\n\n你是设定设计师：所有设定都必须能被剧情用到、能被读者验证。' },
            { role: 'user', content: user }
          ],
          temperature: 0.85,
          max_tokens: 3500
        }
      }
    },

    // ────────────────────────────────────────────────────────────────
    {
      key: 'deslop',
      icon: '🧹',
      name: '去 AI 味 / 润色',
      desc: '按禁用词与句式清单重写，不动剧情',
      fields: [
        { key: 'source', label: '要处理哪个文件', type: 'text', default: '正文/第1章.md', placeholder: '相对项目根的文件路径，或点下面的按钮选', required: true },
        { key: 'strength', label: '力度', type: 'select', default: '标准', options: ['轻度（只删禁用词）', '标准（删词+改句式）', '重度（重写句子，保留事实）'] },
        { key: 'extra', label: '额外要求（可不填）', type: 'textarea', rows: 2, placeholder: '例如：对话再口语化一点；战斗场面节奏加快' }
      ],
      target: function (v) { return v.source },
      build: async function (v, ctx) {
        var text = await readIfExists(ctx.FS, v.source)
        if (!text.trim()) throw new Error('读不到内容：' + v.source + '（确认文件路径，或先用「选择本机文件夹」连上项目）')
        // 过长时按段落分次处理（这里先截断保护，避免一次塞爆上下文）
        var LIMIT = 12000
        var truncated = ''
        if (text.length > LIMIT) {
          truncated = text.slice(0, LIMIT)
          text = truncated + '\n\n（……后续内容本次未处理，处理完请再跑一次）'
        }
        var level = v.strength.indexOf('轻度') === 0 ? '只替换禁用词与标点，尽量不改句式结构。'
          : v.strength.indexOf('重度') === 0 ? '可以重写句子、拆句并句，但事实、情节、人物关系一个都不能变。'
            : '删除禁用词，并改写命中清单的句式；句子结构可小幅调整。'
        var user = '下面是一章中文网文正文，请按规则做去 AI 味处理。\n'
        user += '\n【本次力度】' + level + '\n'
        user += section('额外要求', v.extra)
        user += '\n\n【原文开始】\n' + text + '\n【原文结束】\n'
        user += '\n【输出要求】\n'
        user += '1. 只输出处理后的完整正文，前后不要加任何说明、标题或总结。\n'
        user += '2. 保留原文的段落顺序与所有剧情信息。\n'
        user += '3. 保留原有的 Markdown 标题与空行结构。'
        return {
          messages: [
            { role: 'system', content: '你是中文网文的文字编辑，任务是把 AI 腔改成人话。你只改表达，绝不改事实。\n\n' + SLOP_FULL },
            { role: 'user', content: user }
          ],
          temperature: 0.5,
          max_tokens: 8000
        }
      }
    },

    // ────────────────────────────────────────────────────────────────
    {
      key: 'drama',
      icon: '🎬',
      name: '短剧：剧本 / 分镜 / 提示词',
      desc: '一集剧本、镜头分镜表、图片或视频提示词',
      fields: [
        { key: 'kind', label: '要产出什么', type: 'select', default: '一集剧本', options: ['一集剧本', '镜头分镜表', '图片提示词（首帧/关键帧）', '视频提示词（动作与运镜）'] },
        { key: 'idea', label: '这一集要讲什么', type: 'textarea', rows: 3, placeholder: '例如：女主发现丈夫把她的钱转给了前女友，当场翻脸', required: true },
        { key: 'duration', label: '成片时长', type: 'select', default: '90 秒', options: ['60 秒', '90 秒', '120 秒', '180 秒'] },
        { key: 'style', label: '画风 / 影像风格', type: 'select', default: '写实', options: ['写实', '日系动画', '国漫', '3D 渲染', '水墨', '竖屏快节奏'] }
      ],
      target: function (v) {
        if (v.kind === '一集剧本') return '剧集/EP001/剧本.md'
        if (v.kind === '镜头分镜表') return '剧集/EP001/分镜.md'
        if (v.kind.indexOf('图片') === 0) return '剧集/EP001/图片提示词.md'
        return '剧集/EP001/视频提示词.md'
      },
      build: async function (v, ctx) {
        var user = '请产出短剧制作资料。'
        user += section('产出类型', v.kind)
        user += section('本集内容', v.idea)
        user += section('成片时长', v.duration)
        user += section('影像风格', v.style)
        user += '\n\n【输出要求】\n'
        if (v.kind === '一集剧本') {
          user += '- 前 3 秒必须出现钩子（冲突、反问或异常画面），不要铺垫。\n'
          user += '- 全场次格式：`## 场次N · 内/外景 · 地点 · 日/夜`，下面写动作与对白。\n'
          user += '- 对白短，一句一个信息点；每 15 秒左右要有一个情绪或信息的转折。\n'
          user += '- 结尾留反转或强钩子，让人想看下一集。\n'
          user += '- 按 ' + v.duration + ' 成片估算台词量与场次数（约 2.5 字/秒）。'
        } else if (v.kind === '镜头分镜表') {
          user += '- 用 Markdown 表格，列为：镜号 / 景别 / 画面内容 / 角色动作 / 台词或旁白 / 时长(秒) / 运镜。\n'
          user += '- 镜头数按 ' + v.duration + ' 估算（竖屏短剧平均 2–4 秒一个镜头）。\n'
          user += '- 画面内容要写成可直接拍摄或直接画出来的具体描述，不要写"气氛紧张"。'
        } else if (v.kind.indexOf('图片') === 0) {
          user += '- 逐条给关键帧的图片提示词，每条包含：主体与外观、动作与表情、场景与时间、光线、镜头与构图、风格。\n'
          user += '- 用「画面主体 + 场景 + 光线 + 镜头 + 风格」的顺序组织，一条一个画面。\n'
          user += '- 写清人物一致性锚点（发型、服装、标志物），方便跨图保持同一个人。'
        } else {
          user += '- 逐条给视频提示词，每条包含：起始状态、动作过程、结束状态、运镜方式、时长。\n'
          user += '- 明确"人物表演"与"环境运动"分别是什么，避免模型乱动。\n'
          user += '- 一次只描述一个连续镜头，不要写转场或剪辑点。'
        }
        user += '\n只输出 Markdown，不要解释。'
        return {
          messages: [
            { role: 'system', content: CRAFT + '\n\n你是短剧导演兼分镜师，熟悉竖屏短剧的节奏：钩子前置、反转密集、信息不靠台词硬讲。' + '\n\n' + SLOP_BRIEF },
            { role: 'user', content: user }
          ],
          temperature: 0.85,
          max_tokens: 5000
        }
      }
    },

    // ────────────────────────────────────────────────────────────────
    {
      key: 'blurb',
      icon: '🏷',
      name: '书名 · 简介 · 封面提示词',
      desc: '起名、写卖点简介、生成封面视觉提示词',
      fields: [
        { key: 'kind', label: '要产出什么', type: 'select', default: '书名候选', options: ['书名候选', '作品简介', '封面提示词', '章节标题一批'] },
        { key: 'idea', label: '作品内容 / 卖点', type: 'textarea', rows: 4, placeholder: '讲清主角、核心冲突、最大卖点', required: true },
        { key: 'genre', label: '题材', type: 'select', default: '不限', options: ['不限', '玄幻', '仙侠', '都市', '悬疑', '言情', '历史', '科幻', '年代'] },
        { key: 'count', label: '给几个候选', type: 'select', default: '10', options: ['5', '10', '20'] }
      ],
      target: function (v) {
        if (v.kind === '书名候选') return '简介与书名.md'
        if (v.kind === '作品简介') return '简介与书名.md'
        if (v.kind === '封面提示词') return '封面提示词.md'
        return '大纲/章节标题.md'
      },
      build: async function (v, ctx) {
        var project = await readProjectContext(ctx.FS)
        var user = '请产出：' + v.kind + '，共 ' + v.count + ' 个候选。'
        user += section('作品内容与卖点', v.idea)
        user += section('题材', v.genre)
        user += section('总纲（如有）', project.outline)
        user += '\n\n【输出要求】\n'
        if (v.kind === '书名候选') {
          user += '- 每个候选一行：`书名 —— 一句话说明它抓什么点`。\n'
          user += '- 书名控制在 3–8 字，要好记、有画面或有悬念，避免生僻字与纯抽象词。\n'
          user += '- 至少给出三种不同策略：画面型、冲突型、身份反差型。'
        } else if (v.kind === '作品简介') {
          user += '- 写 ' + v.count + ' 个不同切入的简介，每个 80–150 字。\n'
          user += '- 结构：第一句抛处境或反差 → 中间给冲突与代价 → 末句留钩子。\n'
          user += '- 不要写"本书讲述了……"这种说明书开头，也不要剧透结局。'
        } else if (v.kind === '封面提示词') {
          user += '- 给出 ' + v.count + ' 组封面图片提示词，每组含：主体与外观、姿态与情绪、背景场景、光线氛围、构图与留白位置（要留给标题）、画风。\n'
          user += '- 明确说明标题应该压在什么位置、用什么颜色调性。\n'
          user += '- 提示词要可直接复制到生图工具，不要写成策划说明。'
        } else {
          user += '- 给出连续 ' + v.count + ' 章的标题，每行 `第N章 标题`。\n'
          user += '- 标题要能勾起好奇，但不要剧透关键反转。\n'
          user += '- 避免所有标题都用同一个句式。'
        }
        user += '\n只输出 Markdown，不要解释。'
        return {
          messages: [
            { role: 'system', content: '你是中文网文的书名与文案策划，懂平台读者心理：一眼看懂、有反差、有钩子。\n\n不要用"逆袭""传奇""巅峰"这类被写烂的词。' },
            { role: 'user', content: user }
          ],
          temperature: 1.0,
          max_tokens: 3000
        }
      }
    },

    // ────────────────────────────────────────────────────────────────
    {
      key: 'analyze',
      icon: '🔍',
      name: '拆文：导入小说做结构分析',
      desc: '把现成小说拆成章节索引、剧情单元与人物',
      fields: [
        { key: 'source', label: '要拆哪个文件', type: 'text', default: '', placeholder: '项目里的相对路径，例如 原著/全文.md', required: true },
        { key: 'focus', label: '重点看什么', type: 'select', default: '全套', options: ['全套', '结构与节奏', '人物与关系', '爽点与反转', '文风与句式'] },
        { key: 'chunk', label: '本次处理字数', type: 'select', default: '6000', options: ['3000', '6000', '10000'] }
      ],
      target: function (v) { return '拆文库/原著分析.md' },
      build: async function (v, ctx) {
        var text = await readIfExists(ctx.FS, v.source)
        if (!text.trim()) throw new Error('读不到内容：' + v.source)
        var limit = parseInt(v.chunk, 10) || 6000
        var slice = text.slice(0, limit)
        var more = text.length > limit ? '\n\n（原文较长，本次只分析前 ' + limit + ' 字）' : ''
        var user = '请拆解下面这段小说文本。\n'
        user += section('重点', v.focus)
        user += '\n\n【原文开始】\n' + slice + more + '\n【原文结束】\n'
        user += '\n【输出要求】\n'
        user += '- 用 Markdown，按小标题分块。\n'
        if (v.focus === '全套' || v.focus === '结构与节奏') {
          user += '- **章节与场景索引**：列出可识别的章节或场景，各标注功能（铺垫/冲突/反转/收束）。\n'
          user += '- **剧情单元**：按"目标—阻碍—结果"归纳每个单元，标出字数占比。\n'
          user += '- **节奏**：钩子出现在什么位置、多久来一次，指出拖沓或过快的地方。\n'
        }
        if (v.focus === '全套' || v.focus === '人物与关系') {
          user += '- **人物**：出场人物、目标、与主角的关系、在故事中的功能。\n'
          user += '- **关系变化**：这段文本里谁和谁的关系发生了什么位移。\n'
        }
        if (v.focus === '全套' || v.focus === '爽点与反转') {
          user += '- **爽点与反转**：逐个列出，标注它是靠什么建立的（信息差/身份/实力/情绪）。\n'
        }
        if (v.focus === '全套' || v.focus === '文风与句式') {
          user += '- **文风**：叙事人称、句长分布、对白比例、标志性修辞。\n'
          user += '- **可借鉴的写法**：给 3 条能直接用到自己作品里的具体手法。\n'
        }
        user += '- 每条结论后面附一句原文证据（引用原文短句）。\n'
        user += '\n只输出分析结果，不要解释你的流程。'
        return {
          messages: [
            { role: 'system', content: '你是网文拆解编辑，擅长把成稿还原成可复用的结构模型。分析要具体到句子，不要写"结构紧凑"这类空话。' },
            { role: 'user', content: user }
          ],
          temperature: 0.5,
          max_tokens: 6000
        }
      }
    }
  ]

  // ── 对外接口 ───────────────────────────────────────────────────────
  function findTask(key) {
    for (var i = 0; i < TASKS.length; i++) if (TASKS[i].key === key) return TASKS[i]
    return null
  }

  /**
   * 跑一个创作任务。
   * @param key - 任务 key。
   * @param values - 表单值。
   * @param ctx - { FS, projectDir, bookName, projectKind, model, callProxy }
   * @returns {Promise<{text: string, target: string}>}
   */
  async function generate(key, values, ctx) {
    var task = findTask(key)
    if (!task) throw new Error('未知的创作任务：' + key)
    var built = await task.build(values || {}, ctx)
    var model = ctx.model || 'agnes-2.5-flash'
    var call = ctx.callProxy
    if (typeof call !== 'function') throw new Error('模型通道没准备好（callProxy 未注入）')
    var payload = {
      model: model,
      messages: built.messages,
      temperature: built.temperature == null ? 0.85 : built.temperature
    }
    if (built.max_tokens) payload.max_tokens = built.max_tokens
    var data = await call('/v1/chat/completions', payload, 'POST', { model: model })
    var text = ''
    try {
      text = String(data.choices[0].message.content || '')
    } catch (e) { /* 下面统一报错 */ }
    if (!text.trim()) throw new Error('模型没有返回内容（检查 Key、模型名是否正确、额度是否充足）')
    return { text: text.trim(), target: task.target ? task.target(values || {}, ctx) : '' }
  }

  return {
    TASKS: TASKS,
    findTask: findTask,
    generate: generate,
    listChapters: listChapters,
    readIfExists: readIfExists
  }
})()
