#!/usr/bin/env node
/**
 * 「网页版 Bot 页」产品化裁剪 —— 给第三方 ds-bot 的 client 包打补丁。
 *
 * 为什么要这个脚本（2026-10-28 用户要求）：
 *   用户对网页版 Bot 页提了一条明确的减法要求：
 *     ① 取消「连接插件」那个入口（侧栏底部那颗带 ! 的按钮）；
 *     ② 左下角小金鱼（鲸鱼头像）菜单里，取消「定时任务」和「切换经典 Agent 模式」；
 *     ③ 对话框「+」菜单里，取消「定时任务」；
 *     ④ 设置里把「切换经典 Agent 模式」和「定时任务」也取消。
 *   外加一条文案：断开时说「连不上泡泡猫 DSH，请确认它还在运行。」
 *
 *   ds-bot 是第三方插件（npm ds-bot 0.1.7，Apache-2.0），没有开关能关掉这几项，
 *   只能改它编译好的 client.js —— 所以补丁必须**幂等、可重放、可校验**，
 *   因为① 升级 ds-bot 会覆盖；② 同一个文件同时存在三份（宿主 profile / 运行时种子 / 构建产物）。
 *
 * 幂等做法：文件头写 `/* dshm-web-trim:1,2,…,9 *\/`（已应用的条目 id）。
 *   重跑时只补没应用过的条目 → 加了第 9 条之后，老文件也能增量补齐。
 *
 * 三份副本：
 *   · 本机网页版      /dsh/profiles/web/node_modules/ds-bot/client.js
 *   · 手机运行时种子  dsh-runtime.zip 里 app/profiles-seed/bottest/node_modules/ds-bot/client.js
 *   · 手机已装 profile （由 App 侧 _patchBotWeb 幂等补，见 app/lib/local/bot_server.dart）
 *
 * 用法：
 *   node install/patch-dsbot-web.mjs <ds-bot 目录> [...]      # 打补丁（幂等、可增量）
 *   node install/patch-dsbot-web.mjs --check <dir> [...]      # 只校验
 *
 * 退出码：0 全部命中/已是目标状态；1 有锚点没命中（ds-bot 版本变了）或校验失败。
 */
import { readFileSync, writeFileSync, copyFileSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'

const MARK_PREFIX = '/* dshm-web-trim:'
/** 第一版（1~8）用的旧标记，遇到就迁移成带 id 的新标记。 */
const LEGACY_MARK = '/* dshm-web-trim: ds-bot 网页版裁剪（连接插件/定时任务/经典 Agent 模式） */'
const LEGACY_IDS = [1, 2, 3, 4, 5, 6, 7, 8]

/** 每一条都是 [说明, 原文, 替换]；原文必须在文件里出现且只出现一次。id = 下标 + 1。 */
const EDITS = [
  [
    '① 侧栏底部「连接插件」入口',
    '    () => shadow("sidebar.footer.action", { id: "bot-connect", order: -100, inject: face }, ConnectPlugins),\n',
    '',
  ],
  [
    '② 小金鱼菜单里的「定时任务」',
    '      [t("Automation tasks"), ClockIcon, () => actions.selectPanel("schedules")],\n',
    '',
  ],
  [
    '③ 小金鱼菜单里的「切换经典 Agent 模式」分组',
    '    ],\n    [\n      [t("Switch to classic Agent mode"), SwitchIcon, () => actions.setSurface("agent")]\n    ]\n  ];',
    '    ]\n  ];',
  ],
  [
    '④ 对话框「+」菜单里的「定时任务」',
    '      (0, import_react11.createElement)("button", { type: "button", role: "menuitem", onClick: schedule }, (0, import_react11.createElement)(ClockIcon), (0, import_react11.createElement)("span", { className: "bt-menu-label" }, t("Scheduled task")))\n',
    '',
  ],
  [
    '⑤ 设置页导航里的「定时任务」一页',
    '["schedules", "Scheduled tasks"], ',
    '',
  ],
  [
    '⑥ 设置→通用里「切换经典 Agent 模式」那一栏',
    `    (0, import_react30.createElement)(
      SetSection,
      { key: "mode", title: t("Mode") },
      (0, import_react30.createElement)(
        SetRow,
        { label: t("Classic Agent mode") },
        (0, import_react30.createElement)("button", { type: "button", className: "bt-soft bt-soft-sm", onClick: () => actions.setSurface("agent") }, t("Switch"))
      )
    )
`,
    '',
  ],
  [
    '⑦ Bot 设置页里的「定时任务」区块',
    '    (0, import_react19.createElement)(BotSchedules, { bot, roster, actions }),\n',
    '',
  ],
  [
    '⑧ Bot 详情抽屉里的「定时任务」摘要',
    '        (0, import_react33.createElement)(ScheduleSummary, { key: "routines", bot, actions })\n',
    '',
  ],
  [
    '⑨ 断开时的文案：加上「泡泡猫」品牌',
    '  "Could not reach DSH. Check that it is still running.": "连不上 DSH，请确认它还在运行。",',
    '  "Could not reach DSH. Check that it is still running.": "连不上泡泡猫 DSH，请确认它还在运行。",',
  ],
]

const ALL_IDS = EDITS.map((_, i) => i + 1)

/** 读文件里已经应用过哪些条目。 */
function readApplied(src) {
  if (src.startsWith(LEGACY_MARK)) return { ids: new Set(LEGACY_IDS), strip: LEGACY_MARK }
  const at = src.indexOf(MARK_PREFIX)
  if (at < 0) return { ids: new Set(), strip: null }
  const end = src.indexOf('*/', at)
  if (end < 0) return { ids: new Set(), strip: null }
  const mark = src.slice(at, end + 2)
  const ids = mark
    .slice(MARK_PREFIX.length, -2)
    .split(',')
    .map((x) => Number(x.trim()))
    .filter((n) => Number.isInteger(n) && n > 0)
  return { ids: new Set(ids), strip: mark }
}

const args = process.argv.slice(2)
const checkOnly = args[0] === '--check'
const dirs = checkOnly ? args.slice(1) : args
if (dirs.length === 0) {
  console.error('用法：node install/patch-dsbot-web.mjs [--check] <ds-bot 目录> [...]')
  process.exit(2)
}

let failed = 0
for (const dir of dirs) {
  const file = join(dir, 'client.js')
  if (!existsSync(file)) {
    console.error(`✗ ${file} 不存在`)
    failed++
    continue
  }
  let src = readFileSync(file, 'utf8')
  const { ids, strip } = readApplied(src)
  const pending = ALL_IDS.filter((id) => !ids.has(id))

  if (checkOnly) {
    const left = pending.filter((id) => src.includes(EDITS[id - 1][1]))
    const ok = left.length === 0
    console.log(`${ok ? '✓' : '✗'} ${file}${ok ? `（已裁剪 ${ALL_IDS.length}/${ALL_IDS.length}）` : `（缺：${left.map((id) => EDITS[id - 1][0]).join('、')}）`}`)
    if (!ok) failed++
    continue
  }

  if (pending.length === 0) {
    console.log(`= ${file} 已是最新（${ALL_IDS.length} 条全在）`)
    continue
  }

  const missing = []
  for (const id of pending) {
    const old = EDITS[id - 1][1]
    const hits = src.split(old).length - 1
    if (hits === 0) missing.push(EDITS[id - 1][0])
    else if (hits > 1) missing.push(`${EDITS[id - 1][0]}（重复命中 ${hits} 次）`)
  }
  if (missing.length) {
    console.error(`✗ ${file} 锚点不匹配（ds-bot 版本可能变了），本次一条都不改：`)
    console.error(`   ${missing.join('、')}`)
    failed++
    continue
  }

  const backup = `${file}.orig-${Date.now()}`
  copyFileSync(file, backup)
  // 去掉旧标记行，避免叠加
  if (strip) src = src.slice(strip.length).replace(/^\r?\n/, '')
  for (const id of pending) {
    const old = EDITS[id - 1][1]
    const next = EDITS[id - 1][2]
    src = src.replace(old, next)
  }
  const nowIds = [...new Set([...ids, ...pending])].sort((a, b) => a - b)
  const mark = `${MARK_PREFIX}${nowIds.join(',')} */`
  writeFileSync(file, `${mark}\n${src}`)
  const size = statSync(file).size
  console.log(`✓ ${file}（补了 ${pending.length} 条：${pending.join(',')}，标记 ${nowIds.join(',')}，${size} 字节）`)
}

if (failed) {
  console.error(`\n✗ ${failed} 个目标未完成`)
  process.exit(1)
}
console.log(checkOnly ? '\n✓ 校验通过' : '\n✓ 裁剪完成')
