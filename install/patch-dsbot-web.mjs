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
 *   ds-bot 是第三方插件（npm ds-bot 0.1.7，Apache-2.0），没有开关能关掉这几项，
 *   只能改它编译好的 client.js —— 所以补丁必须**幂等、可重放、可校验**，
 *   因为① 升级 ds-bot 会覆盖；② 同一个文件同时存在三份（宿主 profile / 运行时种子 / 构建产物）。
 *
 * 三份副本：
 *   · 本机网页版      /dsh/profiles/web/node_modules/ds-bot/client.js
 *   · 手机运行时种子  dsh-runtime.zip 里 app/profiles-seed/bottest/node_modules/ds-bot/client.js
 *   · 手机已装 profile （由 App 侧 _patchBotWeb 幂等补，见 app/lib/local/bot_server.dart）
 *
 * 用法：
 *   node install/patch-dsbot-web.mjs <ds-bot 目录> [...]      # 打补丁（幂等）
 *   node install/patch-dsbot-web.mjs --check <dir> [...]      # 只校验
 *
 * 退出码：0 全部命中/已是目标状态；1 有锚点没命中（ds-bot 版本变了）或校验失败。
 */
import { readFileSync, writeFileSync, copyFileSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'

const MARK = '/* dshm-web-trim: ds-bot 网页版裁剪（连接插件/定时任务/经典 Agent 模式） */'

/** 每一条都是 [说明, 原文, 替换]；原文必须在文件里出现且只出现一次。 */
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
]

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
  const applied = src.includes(MARK)
  if (checkOnly) {
    const left = EDITS.filter(([, old]) => src.includes(old))
    const ok = applied && left.length === 0
    console.log(`${ok ? '✓' : '✗'} ${file}${ok ? '（已裁剪）' : `（未裁剪：${left.map(([n]) => n).join('、') || '缺标记'}）`}`)
    if (!ok) failed++
    continue
  }
  if (applied) {
    // 已经打过：只验证锚点是否都不在了
    const left = EDITS.filter(([, old]) => src.includes(old))
    if (left.length === 0) {
      console.log(`= ${file} 已裁剪（跳过）`)
      continue
    }
    console.error(`✗ ${file} 有标记但仍有锚点残留：${left.map(([n]) => n).join('、')}`)
    failed++
    continue
  }

  const missing = []
  const dupes = []
  for (const [name, old] of EDITS) {
    const hits = src.split(old).length - 1
    if (hits === 0) missing.push(name)
    else if (hits > 1) dupes.push(`${name}×${hits}`)
  }
  if (missing.length || dupes.length) {
    console.error(`✗ ${file} 锚点不匹配（ds-bot 版本可能变了）：`)
    if (missing.length) console.error(`   未命中：${missing.join('、')}`)
    if (dupes.length) console.error(`   重复命中：${dupes.join('、')}`)
    failed++
    continue
  }

  const backup = `${file}.orig-${Date.now()}`
  copyFileSync(file, backup)
  for (const [, old, next] of EDITS) src = src.replace(old, next)
  src = `${MARK}\n${src}`
  writeFileSync(file, src)
  const size = statSync(file).size
  console.log(`✓ ${file}（备份 ${backup.split('/').pop()}，${size} 字节）`)
}

if (failed) {
  console.error(`\n✗ ${failed} 个目标未完成`)
  process.exit(1)
}
console.log(checkOnly ? '\n✓ 校验通过' : '\n✓ 裁剪完成')
