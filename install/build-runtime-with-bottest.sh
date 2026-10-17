#!/usr/bin/env bash
# 在现有运行时压缩包里加「bottest profile 种子」——手机上 Bot 页面要用。
#
# 为什么需要它：手机 App 现在起的是 `--profile acp`（bundles = dsh-base + dsh-acp-app），
# 那套里**没有** ds-bot（Bot 团队插件）。要让手机上出现 Bot 能力，需要：
#   ① 运行时里有 ds-bot 这个包；
#   ② 有一个 profile（这里叫 bottest）把 dsh-base + dsh-web-app + ds-bot 组合起来；
#   ③ App 启动时把 ① ② 落进 $DSH_HOME/profiles/bottest（名解析锚定 profile 目录，
#      所以 ds-bot 必须在 profile 自己的 node_modules 下）。
#
# 本脚本只做「把种子放进压缩包」这一件事：种子目录原样搬到包里的
# `app/profiles-seed/bottest/`；落盘与建 profile 由 App 侧做。
#
# ⚠️ 必须放在 `app/` 前缀下：手机侧解压器（MainActivity.unpack）只认两个前缀 ——
#   `app/…` → `<filesDir>/dsh/…`、`shims/…` → `<filesDir>/shims/…`，**其余前缀一律丢弃**。
#   所以种子落在 `<filesDir>/dsh/profiles-seed/bottest`，App 从 runtimeRoot 取。
#
# 本机已验证（2026-10-17，DSH_HOME=/tmp/dsh-bottest）：这套最小组合能把 ds-bot
# 激活起来，`POST /api/bot {"endpoint":"state"}` 返回完整团队视图。
#
# 用法：install/build-runtime-with-bottest.sh [输入 zip] [输出 zip] [种子目录]
set -euo pipefail

IN_ZIP="${1:-/root/办公/dsh-runtime-0.57-slim-anysearch.zip}"
OUT_ZIP="${2:-/root/办公/dsh-runtime-bottest.zip}"
SEED="${3:-/tmp/seed-bottest}"

[ -f "$IN_ZIP" ] || { echo "✗ 找不到输入运行时包：$IN_ZIP" >&2; exit 1; }
[ -f "$SEED/package.json" ] || { echo "✗ 种子目录不像 profile：$SEED" >&2; exit 1; }
[ -f "$SEED/node_modules/ds-bot/index.js" ] || { echo "✗ 种子里缺 ds-bot：$SEED/node_modules/ds-bot" >&2; exit 1; }

IN_ZIP="$IN_ZIP" OUT_ZIP="$OUT_ZIP" SEED="$SEED" python3 - <<'PY'
import hashlib, json, os, pathlib, shutil, tempfile, zipfile

src = os.environ['IN_ZIP']
out = os.environ['OUT_ZIP']
seed = pathlib.Path(os.environ['SEED'])
PKG = "app/profiles-seed/bottest"

tmp = tempfile.mkdtemp(prefix='dsh-runtime-bottest-')
try:
    # ① 解出来（条目名里的反斜杠归一成正斜杠；现包是 Windows 的 .NET ZipFile 建的）
    with zipfile.ZipFile(src) as z:
        infos = z.infolist()
        for info in infos:
            name = info.filename.replace('\\', '/')
            if not name or name.endswith('/'):
                continue
            if name.startswith('/') or '..' in name.split('/'):
                raise SystemExit(f'✗ 包里有可疑路径：{info.filename!r}')
            dst = pathlib.Path(tmp, name)
            dst.parent.mkdir(parents=True, exist_ok=True)
            with z.open(info) as f, open(dst, 'wb') as g:
                shutil.copyfileobj(f, g)
    print(f'解出 {len(infos)} 个条目 → {tmp}')

    # ② 放种子（整个目录原样搬）
    dst = pathlib.Path(tmp, PKG)
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(seed, dst)
    files = sum(1 for _ in dst.rglob('*') if _.is_file())
    print(f'写入种子 → {PKG}（{files} 个文件，含 ds-bot）')

    # ③ 重新打包（规范正斜杠；手机侧本来就会归一，两种都认）
    count = 0
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, _dirs, fs in os.walk(tmp):
            for f in fs:
                full = pathlib.Path(root, f)
                z.write(full, full.relative_to(tmp).as_posix())
                count += 1
    size = os.path.getsize(out)
    sha = hashlib.sha256(open(out, 'rb').read()).hexdigest()
    print(f'\n✓ 已生成：{out}')
    print(f'  条目 {count}（原 {len(infos)}，+{count - len(infos)}）')
    print(f'  大小 {size} 字节（原 {os.path.getsize(src)}，+{size - os.path.getsize(src)}）')
    print(f'  sha256 {sha}')

    # ④ 自检：种子在不在、原条目有没有丢、有没有反斜杠残留
    with zipfile.ZipFile(out) as z:
        names = set(z.namelist())
        for need in (f'{PKG}/package.json', f'{PKG}/cordis.patch.yml', f'{PKG}/cordis.yml',
                     f'{PKG}/node_modules/ds-bot/index.js', f'{PKG}/node_modules/ds-bot/client.js',
                     f'{PKG}/node_modules/ds-bot/package.json'):
            assert need in names, f'✗ 新包里缺 {need}'
        assert 'app/lib/bin.js' in names, '✗ 主包入口丢了'
        assert not any('\\' in n for n in names), '✗ 还有反斜杠条目'
    print('  自检：种子齐 ✓ / 主包在 ✓ / 条目全为正斜杠 ✓')
    print(json.dumps({'out': out, 'size': size, 'sha256': sha}, ensure_ascii=False))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY
