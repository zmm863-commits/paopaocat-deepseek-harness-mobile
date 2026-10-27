/**
 * 本机目录文件层 —— 创作台专用
 * ═══════════════════════════════════════════════════════════════════════
 * 让创作台直接读写**用户自己电脑**上的目录，服务器完全不参与。
 * 服务端已无任何文件接口，本模块是创作台唯一的文件来源。
 *
 * 两档能力（浏览器差异，无解）：
 *   · rw —— File System Access API（Chrome 86+ / Edge）：就地读写
 *   · ro —— webkitdirectory 降级（Firefox / Safari）：能选目录、能看内容，
 *           但不能保存。这两家对 File System Access 的官方立场是反对，
 *           不会支持，所以降级是终态而非过渡。
 *
 * 安全上下文是硬门槛：非 https/localhost 下 showDirectoryPicker 是 undefined，
 * 所以 rw 能力检测里同时校验 window.isSecureContext。
 *
 * 目录句柄存 IndexedDB（句柄可结构化克隆），下次打开可一键重连，
 * 但浏览器要求用户手势，因此仍需点一次按钮。
 * ═══════════════════════════════════════════════════════════════════════
 */
window.LocalFS = (function () {
  'use strict'

  /** 可编辑的文本扩展名（与原服务端口径一致）。 */
  var TEXT_EXT = new Set(['.md', '.txt', '.json', '.yaml', '.yml', '.toml'])
  /** 列目录时跳过的目录名。 */
  var SKIP_DIRS = new Set(['node_modules', '.git', '.next', 'dist', 'lib'])
  /** 单文件上限（2MB，与原服务端口径一致）。 */
  var MAX_BYTES = 2 * 1024 * 1024
  var DB_NAME = 'psw-studio'
  var DB_STORE = 'handles'
  var DB_KEY = 'workspace'

  /** 'rw' | 'ro' | 'none' */
  var mode = 'none'
  /** rw 模式下选中的根目录句柄。 */
  var dirHandle = null
  /** 当前根目录名（浏览器不给绝对路径，只能显示名字）。 */
  var rootName = ''
  /** ro 模式：rel → File。 */
  var roFiles = new Map()
  /** ro 模式：全部目录 rel（含空串代表根）。 */
  var roDirs = new Set()

  // ── 小工具 ─────────────────────────────────────────────────────────
  function extOf(name) {
    var i = name.lastIndexOf('.')
    return i < 0 ? '' : name.slice(i).toLowerCase()
  }
  function isText(name) {
    return TEXT_EXT.has(extOf(name))
  }
  function normRel(rel) {
    return String(rel || '')
      .split('/')
      .filter(function (s) { return s && s !== '.' })
      .join('/')
  }
  function sortEntries(list) {
    return list.sort(function (a, b) {
      if (a.type !== b.type) return a.type === 'dir' ? -1 : 1
      return a.name.localeCompare(b.name)
    })
  }
  var encoder = typeof TextEncoder !== 'undefined' ? new TextEncoder() : null
  function byteLength(text) {
    return encoder ? encoder.encode(text).length : String(text).length
  }

  // ── IndexedDB：记住目录句柄 ────────────────────────────────────────
  function openDB() {
    return new Promise(function (resolve, reject) {
      var req = indexedDB.open(DB_NAME, 1)
      req.onupgradeneeded = function () {
        if (!req.result.objectStoreNames.contains(DB_STORE)) req.result.createObjectStore(DB_STORE)
      }
      req.onsuccess = function () { resolve(req.result) }
      req.onerror = function () { reject(req.error || new Error('IndexedDB 打开失败')) }
    })
  }
  async function idbPut(value) {
    var db = await openDB()
    await new Promise(function (resolve, reject) {
      var tx = db.transaction(DB_STORE, 'readwrite')
      tx.objectStore(DB_STORE).put(value, DB_KEY)
      tx.oncomplete = function () { resolve() }
      tx.onerror = function () { reject(tx.error) }
    })
    db.close()
  }
  async function idbGet() {
    var db = await openDB()
    var value = await new Promise(function (resolve, reject) {
      var tx = db.transaction(DB_STORE, 'readonly')
      var r = tx.objectStore(DB_STORE).get(DB_KEY)
      r.onsuccess = function () { resolve(r.result) }
      r.onerror = function () { reject(r.error) }
    })
    db.close()
    return value || null
  }
  async function idbDel() {
    var db = await openDB()
    await new Promise(function (resolve, reject) {
      var tx = db.transaction(DB_STORE, 'readwrite')
      tx.objectStore(DB_STORE).delete(DB_KEY)
      tx.oncomplete = function () { resolve() }
      tx.onerror = function () { reject(tx.error) }
    })
    db.close()
  }

  // ── 能力检测 ───────────────────────────────────────────────────────
  function supportsReadWrite() {
    return typeof window.showDirectoryPicker === 'function' && window.isSecureContext === true
  }
  function supportsReadOnly() {
    try {
      return 'webkitdirectory' in document.createElement('input')
    } catch (e) {
      return false
    }
  }
  function capability() {
    if (supportsReadWrite()) return 'rw'
    if (supportsReadOnly()) return 'ro'
    return 'none'
  }
  /** 拿不到 rw 时，用可读的原因解释给用户。 */
  function whyNoReadWrite() {
    if (typeof window.showDirectoryPicker === 'function' && window.isSecureContext !== true) {
      return '当前地址不是安全上下文（需要 https 或 localhost），浏览器不暴露本机目录 API'
    }
    var ua = navigator.userAgent
    if (/firefox/i.test(ua)) return 'Firefox 不支持本机目录读写（Mozilla 官方立场为反对）'
    if (/safari/i.test(ua) && !/chrome/i.test(ua)) return 'Safari 不支持本机目录读写（WebKit 官方立场为反对）'
    return '当前浏览器不支持本机目录读写（请用 Chrome 或 Edge）'
  }

  // ── rw：选目录 / 记忆 ──────────────────────────────────────────────
  /**
   * 选择器互斥锁。
   *
   * Chrome 在同一个文档里只允许有一个文件选择器处于激活状态，第二个请求会抛
   * `Failed to execute 'showDirectoryPicker': File picker already active.`
   * ——对话框还开着时再点一次按钮就会撞上（双击同理）。
   * 这里做两件事：① 挡住并发调用；② 把浏览器的英文错误翻成人话。
   */
  var picking = false

  function friendlyPickerError(error) {
    var name = error && error.name ? error.name : ''
    var msg = error instanceof Error ? error.message : String(error)
    if (name === 'AbortError' || /abort/i.test(msg)) return '已取消选择'
    if (/already active/i.test(msg)) {
      return '系统里已经有一个文件夹选择窗口开着（多半是之前遗留的、被别的窗口挡住看不见）：先把它找出来关掉；实在找不到就完全退出浏览器再重新打开——刷新页面没用。'
    }
    if (/must be handling a user gesture|user gesture/i.test(msg)) {
      return '浏览器要求这次选择必须由你的点击直接触发，请重新点一下按钮'
    }
    return msg
  }

  async function pick() {
    if (picking) throw new Error('正在等上一个文件夹选择窗口，先把它处理掉再点')
    if (!supportsReadWrite()) throw new Error(whyNoReadWrite())
    picking = true
    try {
      var h = await window.showDirectoryPicker({ mode: 'readwrite', id: 'studio-workspace' })
      dirHandle = h
      rootName = h.name || 'ROOT'
      mode = 'rw'
      try { await idbPut(h) } catch (e) { /* 隐私模式可能不可写，忽略 */ }
      return rootName
    } catch (error) {
      throw new Error(friendlyPickerError(error))
    } finally {
      picking = false
    }
  }

  /** 尝试恢复上次的目录；不弹窗，只查询权限。 */
  async function restore() {
    if (!supportsReadWrite()) return { status: 'unsupported' }
    var h = null
    try { h = await idbGet() } catch (e) { return { status: 'none' } }
    if (!h || typeof h.queryPermission !== 'function') return { status: 'none' }
    dirHandle = h
    rootName = h.name || 'ROOT'
    try {
      var perm = await h.queryPermission({ mode: 'readwrite' })
      if (perm === 'granted') {
        mode = 'rw'
        return { status: 'ok', name: rootName }
      }
    } catch (e) { /* 查询失败就当需要重新授权 */ }
    return { status: 'need-permission', name: rootName }
  }

  /** 用户手势里请求权限（恢复上次目录时用）。 */
  async function grant() {
    if (!dirHandle) throw new Error('没有可恢复的目录')
    var perm = await dirHandle.requestPermission({ mode: 'readwrite' })
    if (perm !== 'granted') throw new Error('授权被拒绝')
    mode = 'rw'
    return rootName
  }

  /** 忘记记住的目录。 */
  async function forget() {
    try { await idbDel() } catch (e) { /* ignore */ }
    reset()
  }

  function reset() {
    dirHandle = null
    mode = 'none'
    rootName = ''
    roFiles = new Map()
    roDirs = new Set()
  }

  // ── rw：目录与文件操作 ─────────────────────────────────────────────
  async function resolveDir(rel) {
    var h = dirHandle
    var parts = normRel(rel).split('/').filter(Boolean)
    for (var i = 0; i < parts.length; i++) h = await h.getDirectoryHandle(parts[i])
    return h
  }

  async function rwList(rel) {
    var dir = await resolveDir(rel)
    var base = normRel(rel)
    var out = []
    for await (var entry of dir.entries()) {
      var name = entry[0], h = entry[1]
      if (name.startsWith('.')) continue
      var childRel = base ? base + '/' + name : name
      if (h.kind === 'directory') {
        if (SKIP_DIRS.has(name)) continue
        out.push({ name: name, rel: childRel, type: 'dir' })
      } else {
        var size
        try { size = (await h.getFile()).size } catch (e) { /* ignore */ }
        out.push({ name: name, rel: childRel, type: 'file', size: size, editable: isText(name) })
      }
    }
    return sortEntries(out)
  }

  async function rwRead(rel) {
    var rel2 = normRel(rel)
    var parts = rel2.split('/')
    var fileName = parts.pop()
    if (!isText(fileName)) throw new Error('该文件类型不支持打开（只支持 md / txt / json / yaml / yml / toml）')
    var dir = await resolveDir(parts.join('/'))
    var fh = await dir.getFileHandle(fileName)
    var file = await fh.getFile()
    if (file.size > MAX_BYTES) throw new Error('文件超过 2MB 上限')
    return { content: await file.text(), mtimeMs: file.lastModified, size: file.size }
  }

  async function rwWrite(rel, content) {
    var rel2 = normRel(rel)
    var parts = rel2.split('/')
    var fileName = parts.pop()
    if (!fileName) throw new Error('文件名无效')
    if (!isText(fileName)) throw new Error('该文件类型不支持保存（只支持 md / txt / json / yaml / yml / toml）')
    var text = String(content == null ? '' : content)
    var bytes = byteLength(text)
    if (bytes > MAX_BYTES) throw new Error('内容超过 2MB 上限')
    var dir = dirHandle
    for (var i = 0; i < parts.length; i++) dir = await dir.getDirectoryHandle(parts[i], { create: true })
    var fh = await dir.getFileHandle(fileName, { create: true })
    var w = await fh.createWritable()
    await w.write(text)
    await w.close()
    return bytes
  }

  async function rwDetectProjects() {
    var out = []
    var tops = []
    for await (var entry of dirHandle.entries()) {
      var name = entry[0], h = entry[1]
      if (h.kind !== 'directory') continue
      if (name.startsWith('.') || SKIP_DIRS.has(name)) continue
      tops.push(name)
    }
    for (var i = 0; i < tops.length; i++) {
      var t = tops[i]
      var sub = [], files = []
      var dh = await dirHandle.getDirectoryHandle(t)
      for await (var child of dh.entries()) {
        if (child[1].kind === 'directory') sub.push(child[0])
        else files.push(child[0])
      }
      var isLong = ['正文', '大纲', '设定', '追踪'].some(function (d) { return sub.indexOf(d) >= 0 })
      var isShort = files.indexOf('正文.md') >= 0 && (files.indexOf('小节大纲.md') >= 0 || files.indexOf('设定.md') >= 0)
      if (isLong) out.push({ dir: t, kind: 'long', name: t })
      else if (isShort) out.push({ dir: t, kind: 'short', name: t })
    }
    for (var j = 0; j < tops.length; j++) {
      var n = tops[j]
      if (n === '拆文库') {
        try {
          var bh = await dirHandle.getDirectoryHandle(n)
          for await (var book of bh.entries()) {
            if (book[1].kind === 'directory') out.push({ dir: n + '/' + book[0], kind: 'analysis', name: book[0] })
          }
        } catch (e) { /* ignore */ }
      } else if (n.indexOf('拆文库-') === 0) {
        out.push({ dir: n, kind: 'analysis', name: n.slice(4) })
      }
    }
    return out
  }

  async function createProject(kind, name) {
    if (mode !== 'rw') throw new Error('只读模式无法新建项目（请用 Chrome 或 Edge 打开）')
    var safeName = String(name || '').trim().replace(/[/\\]/g, '_')
    if (!safeName) throw new Error('项目名不能为空')
    var exists = true
    try { await dirHandle.getDirectoryHandle(safeName) } catch (e) { exists = false }
    if (exists) throw new Error('「' + safeName + '」已存在')

    var dir = await dirHandle.getDirectoryHandle(safeName, { create: true })
    async function put(rel, text) {
      var parts = rel.split('/')
      var file = parts.pop()
      var d = dir
      for (var i = 0; i < parts.length; i++) d = await d.getDirectoryHandle(parts[i], { create: true })
      var fh = await d.getFileHandle(file, { create: true })
      var w = await fh.createWritable()
      await w.write(text)
      await w.close()
    }
    if (kind === 'long') {
      var subs = ['正文', '大纲', '设定', '追踪']
      for (var k = 0; k < subs.length; k++) await dir.getDirectoryHandle(subs[k], { create: true })
      await put('大纲/总纲.md', '# ' + safeName + ' · 总纲\n\n## 一句话简介\n\n\n## 主角\n\n\n## 核心冲突\n\n\n## 分卷\n\n')
      await put('设定/世界观.md', '# ' + safeName + ' · 世界观\n\n')
      await put('追踪/_tracking-state.json', JSON.stringify({ project: safeName, chapters: [], updatedAt: Date.now() }, null, 2))
    } else {
      await put('正文.md', '# ' + safeName + '\n\n')
      await put('小节大纲.md', '# ' + safeName + ' · 小节大纲\n\n')
      await put('设定.md', '# ' + safeName + ' · 设定\n\n')
    }
    return safeName
  }

  // ── ro：降级只读 ───────────────────────────────────────────────────
  function indexReadOnly(files) {
    roFiles = new Map()
    roDirs = new Set([''])
    rootName = ''
    for (var i = 0; i < files.length; i++) {
      var f = files[i]
      var p = String(f.webkitRelativePath || f.name).split('/').filter(Boolean)
      if (!rootName) rootName = p[0] || 'ROOT'
      var parts = p.slice(1)
      if (!parts.length) continue
      var rel = parts.join('/')
      roFiles.set(rel, f)
      for (var k = 1; k < parts.length; k++) roDirs.add(parts.slice(0, k).join('/'))
    }
  }

  function pickReadOnly() {
    return new Promise(function (resolve, reject) {
      if (!supportsReadOnly()) {
        reject(new Error('当前浏览器连只读目录选择都不支持，请改用 Chrome 或 Edge'))
        return
      }
      if (picking) {
        reject(new Error('正在等上一个文件夹选择窗口，先把它处理掉再点'))
        return
      }
      picking = true
      var release = function () { picking = false }
      var input = document.createElement('input')
      input.type = 'file'
      input.webkitdirectory = true
      input.multiple = true
      input.style.position = 'fixed'
      input.style.left = '-9999px'
      var done = false
      input.addEventListener('change', function () {
        if (done) return
        done = true
        var files = Array.prototype.slice.call(input.files || [])
        input.remove()
        release()
        if (!files.length) { reject(new Error('没有选择任何文件')); return }
        indexReadOnly(files)
        mode = 'ro'
        resolve(rootName)
      })
      input.addEventListener('cancel', function () {
        if (done) return
        done = true
        input.remove()
        release()
        reject(new Error('已取消选择'))
      })
      document.body.appendChild(input)
      input.click()
    })
  }

  function roChildren(rel) {
    var base = normRel(rel)
    var prefix = base ? base + '/' : ''
    var out = []
    var seen = new Set()
    roDirs.forEach(function (d) {
      if (d === base || d.indexOf(prefix) !== 0) return
      var rest = d.slice(prefix.length)
      if (!rest || rest.indexOf('/') >= 0) return
      if (seen.has(rest) || rest.startsWith('.') || SKIP_DIRS.has(rest)) return
      seen.add(rest)
      out.push({ name: rest, rel: prefix + rest, type: 'dir' })
    })
    roFiles.forEach(function (f, r) {
      if (r.indexOf(prefix) !== 0) return
      var rest = r.slice(prefix.length)
      if (!rest || rest.indexOf('/') >= 0 || rest.startsWith('.')) return
      out.push({ name: rest, rel: r, type: 'file', size: f.size, editable: isText(rest) })
    })
    return sortEntries(out)
  }

  async function roRead(rel) {
    var r = normRel(rel)
    var f = roFiles.get(r)
    if (!f) throw new Error('文件不在本次选择的目录里：' + r)
    if (!isText(r)) throw new Error('该文件类型不支持打开')
    if (f.size > MAX_BYTES) throw new Error('文件超过 2MB 上限')
    return { content: await f.text(), mtimeMs: f.lastModified, size: f.size }
  }

  function roDetectProjects() {
    var out = []
    var tops = []
    roDirs.forEach(function (d) { if (d && d.indexOf('/') < 0) tops.push(d) })
    tops.forEach(function (t) {
      if (t.startsWith('.') || SKIP_DIRS.has(t)) return
      var sub = [], files = []
      roDirs.forEach(function (d) {
        if (d.indexOf(t + '/') === 0 && d.slice(t.length + 1).indexOf('/') < 0) sub.push(d.slice(t.length + 1))
      })
      roFiles.forEach(function (f, r) {
        if (r.indexOf(t + '/') === 0 && r.slice(t.length + 1).indexOf('/') < 0) files.push(r.slice(t.length + 1))
      })
      var isLong = ['正文', '大纲', '设定', '追踪'].some(function (d) { return sub.indexOf(d) >= 0 })
      var isShort = files.indexOf('正文.md') >= 0 && (files.indexOf('小节大纲.md') >= 0 || files.indexOf('设定.md') >= 0)
      if (isLong) out.push({ dir: t, kind: 'long', name: t })
      else if (isShort) out.push({ dir: t, kind: 'short', name: t })
    })
    tops.forEach(function (t) {
      if (t === '拆文库') {
        roDirs.forEach(function (d) {
          if (d.indexOf('拆文库/') === 0 && d.slice(4).indexOf('/') < 0) out.push({ dir: d, kind: 'analysis', name: d.slice(4) })
        })
      } else if (t.indexOf('拆文库-') === 0) {
        out.push({ dir: t, kind: 'analysis', name: t.slice(4) })
      }
    })
    return out
  }

  // ── 对外统一接口（按 mode 分派）─────────────────────────────────────
  async function list(rel) {
    if (mode === 'rw') return rwList(rel)
    if (mode === 'ro') return roChildren(rel)
    throw new Error('还没有选择目录')
  }
  async function read(rel) {
    if (mode === 'rw') return rwRead(rel)
    if (mode === 'ro') return roRead(rel)
    throw new Error('还没有选择目录')
  }
  async function write(rel, content) {
    if (mode === 'ro') throw new Error('只读模式：Firefox / Safari 不支持写回本机文件，请用 Chrome 或 Edge 打开')
    if (mode !== 'rw') throw new Error('还没有选择目录')
    return rwWrite(rel, content)
  }
  async function detectProjects() {
    if (mode === 'rw') return rwDetectProjects()
    if (mode === 'ro') return roDetectProjects()
    throw new Error('还没有选择目录')
  }

  return {
    capability: capability,
    supportsReadWrite: supportsReadWrite,
    supportsReadOnly: supportsReadOnly,
    whyNoReadWrite: whyNoReadWrite,
    pick: pick,
    pickReadOnly: pickReadOnly,
    restore: restore,
    grant: grant,
    forget: forget,
    reset: reset,
    list: list,
    read: read,
    write: write,
    detectProjects: detectProjects,
    createProject: createProject,
    get mode() { return mode },
    get rootName() { return rootName }
  }
})()
