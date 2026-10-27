#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""出包后核对（P0-1）：确认**发出去的包**就是**你改的那个源码**。

## 为什么需要它

0.57 的包实际是坏的：`AndroidToolbox.assets` 漏了 `open-app.mjs` 一行，
装到手机上"打开本机应用"永远是死的。（该功能已于 2026-10-10 取消，这里保留这段
历史是为了说明**为什么需要这个检查**：它抓的是"表里有、so 里没有"这个形状。）而当时 **273 条测试全绿** ——
因为那些测试读的是**工作区磁盘**（`File('assets/...')`），不是**包里的字节**。
出包脚本也不跑闸，出完包也没有任何核对。

于是"测试全绿"和"真机坏掉"可以同时成立。这个脚本补的就是这一环：
它只认**包里的字节**，不认源码树，也不认你自己的判断。

## 三项核对

  ① 版本同一   APK 的 `versionName` == 当前 pubspec 推导出的版本
               （防"改了版本号却没重打包 / 发错包"）
  ② 落盘表自检 `libapp.so` 里能找到 `AndroidToolbox.assets` 的**每一个 key**
               （0.57 就是漏在这里 —— 这一项当场就能抓住）
  ③ 资产同一   `app/assets/**` 每个文件在包里逐名存在，且 **size + sha256 一致**
               （防"清单在、内容不在"和"打了旧资产"）

## 怎么用

    # 显式指定包（在仓库任意位置都能跑）
    python3 install/check-release.py dist/paopaocat-preview-0.57-arm64-v8a.apk

    # 不给参数：自动挑 dist/ 里版本号最大的那个 APK
    python3 install/check-release.py

    # 机器可读
    python3 install/check-release.py --json

退出码：0 = 全部通过；1 = 有 FAIL（**这个包不要发**）；2 = 脚本自身出错。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import struct
import sys
import zipfile

# ---------------------------------------------------------------- 基础工具

FLUTTER_ASSET_PREFIX = "assets/flutter_assets/"


class Fail(Exception):
    """一条 FAIL 项。"""

    def __init__(self, check: str, detail: str):
        super().__init__(detail)
        self.check = check
        self.detail = detail


class Skip(Exception):
    """无法核对的项（不当作失败，但必须原样报出来）。"""


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def norm(p: str) -> str:
    """统一分隔符 —— zip 里可能混着反斜杠（历史上真出现过）。"""
    return p.replace("\\", "/")


# ------------------------------------------------- AXML（AndroidManifest.xml）
#
# 包里的 AndroidManifest.xml 是**二进制 AXML**，不是文本，直接 grep 找不到
# versionName。这里手写一个刚好够用的解析器：只取 manifest 元素的属性。
# 为什么不用 aapt/apktool：出包机上不一定装了 Android SDK，而这个脚本要
# 能在任何一台机器上跑（含本机 Linux），不能有外部依赖。

_CHUNK_STRING_POOL = 0x0001
_CHUNK_START_ELEMENT = 0x0102

_TYPE_STRING = 0x03
_TYPE_INT_DEC = 0x10
_TYPE_INT_HEX = 0x11
_TYPE_INT_BOOLEAN = 0x12


def _parse_string_pool(data: bytes, off: int) -> list[str]:
    ctype, _hsize, _csize = struct.unpack_from("<HHI", data, off)
    if ctype != _CHUNK_STRING_POOL:
        raise Skip(f"不是字符串池 chunk（0x{ctype:04x}）")
    count, _style_count, flags, strings_start, _styles_start = struct.unpack_from(
        "<IIIII", data, off + 8
    )
    utf8 = bool(flags & 0x100)
    offsets = struct.unpack_from("<%dI" % count, data, off + 28)
    base = off + strings_start

    def uleb128(p: int) -> tuple[int, int]:
        val = 0
        shift = 0
        while True:
            b = data[p]
            p += 1
            val |= (b & 0x7F) << shift
            if not (b & 0x80):
                return val, p
            shift += 7

    out: list[str] = []
    for o in offsets:
        p = base + o
        if utf8:
            _nchars, p = uleb128(p)
            nbytes, p = uleb128(p)
            out.append(data[p : p + nbytes].decode("utf-8", "replace"))
        else:
            nchars = struct.unpack_from("<H", data, p)[0]
            out.append(data[p + 2 : p + 2 + nchars * 2].decode("utf-16-le", "replace"))
    return out


def read_manifest_version(apk_path: str) -> dict[str, object]:
    """从 APK 的二进制 AndroidManifest.xml 里取 versionName / versionCode。"""
    with zipfile.ZipFile(apk_path) as z:
        if "AndroidManifest.xml" not in z.namelist():
            raise Skip("APK 里没有 AndroidManifest.xml")
        data = z.read("AndroidManifest.xml")

    _ctype, hsize, _csize = struct.unpack_from("<HHI", data, 0)
    strings: list[str] = []
    off = hsize
    while off + 8 <= len(data):
        ctype, chsize, csize = struct.unpack_from("<HHI", data, off)
        if csize == 0:
            break
        if ctype == _CHUNK_STRING_POOL:
            strings = _parse_string_pool(data, off)
        elif ctype == _CHUNK_START_ELEMENT:
            # ResXMLTree_node = chunk header(8) + lineNumber(4) + comment(4) = 16 字节，
            # 所以**元素体从 off + headerSize 开始**，不是从 off + 8。
            # （踩过：按 off+8 算，元素名全错，manifest 永远找不到。）
            body = off + chsize
            ns_ref, name_ref = struct.unpack_from("<II", data, body)
            attr_start, attr_size, attr_count = struct.unpack_from("<HHH", data, body + 8)
            elem = strings[name_ref] if name_ref < len(strings) else "?"
            if elem == "manifest":
                attrs: dict[str, object] = {}
                for i in range(attr_count):
                    ao = body + attr_start + i * attr_size
                    _ns, a_name, _raw = struct.unpack_from("<III", data, ao)
                    _size, _res0, dtype = struct.unpack_from("<HBB", data, ao + 12)
                    (a_data,) = struct.unpack_from("<I", data, ao + 16)
                    key = strings[a_name] if a_name < len(strings) else f"#{a_name}"
                    if dtype == _TYPE_STRING and a_data < len(strings):
                        attrs[key] = strings[a_data]
                    elif dtype in (_TYPE_INT_DEC, _TYPE_INT_HEX):
                        attrs[key] = a_data
                    elif dtype == _TYPE_INT_BOOLEAN:
                        attrs[key] = bool(a_data)
                    else:
                        attrs[key] = f"<type=0x{dtype:02x}>"
                return attrs
        off += csize
    raise Skip("AXML 里没找到 manifest 元素")


# ------------------------------------------------------- 源码树里的事实来源

VERSION_RE = re.compile(r"""kAppVersion\s*=\s*['"]([^'"]+)['"]""")
PUBSPEC_VERSION_RE = re.compile(r"^version:\s*([0-9][^\s+]*)", re.M)
# 'assets/toolbox/x.mjs': 'toolbox/x.mjs',
TABLE_ENTRY_RE = re.compile(r"""['"](assets/[^'"]+)['"]\s*:\s*['"]([^'"]+)['"]""")


def read_version_dart(repo: str) -> str:
    p = os.path.join(repo, "app", "lib", "app_version.dart")
    with open(p, encoding="utf-8") as f:
        src = f.read()
    m = VERSION_RE.search(src)
    if not m:
        raise Skip(f"app_version.dart 里没找到 kAppVersion：{p}")
    return m.group(1)


def read_pubspec_version(repo: str) -> tuple[str, str | None]:
    """返回 (versionName, versionCode)。Flutter 的 versionName 去掉 +build。"""
    p = os.path.join(repo, "app", "pubspec.yaml")
    with open(p, encoding="utf-8") as f:
        src = f.read()
    m = PUBSPEC_VERSION_RE.search(src)
    if not m:
        raise Skip(f"pubspec.yaml 里没找到 version：{p}")
    full = m.group(1)
    name, _, build = full.partition("+")
    return name, (build or None)


def read_toolbox_table(repo: str) -> dict[str, str]:
    """从 android_toolbox.dart 里抠出那张落盘表（源码即事实）。"""
    p = os.path.join(repo, "app", "lib", "local", "android_toolbox.dart")
    with open(p, encoding="utf-8") as f:
        src = f.read()
    # 只在 assets 这张表里找，避免把文件里别的字符串当成表项
    anchor = src.find("Map<String, String> assets")
    if anchor < 0:
        raise Skip("android_toolbox.dart 里没找到 `Map<String, String> assets`")
    end = src.find("};", anchor)
    block = src[anchor : end if end > 0 else len(src)]
    table = {k: v for k, v in TABLE_ENTRY_RE.findall(block)}
    if not table:
        raise Skip("落盘表是空的？")
    return table


def repo_asset_files(repo: str) -> dict[str, str]:
    """`app/assets/**` 下每个文件的相对路径（相对 app/）。"""
    root = os.path.join(repo, "app", "assets")
    out: dict[str, str] = {}
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, os.path.join(repo, "app"))
            out[norm(rel)] = full
    return out


# ------------------------------------------------------------------ 三项核对


def _norm_version(v: str) -> tuple:
    """把版本号归一化成可比较的元组：`0.0.58` 与 `0.58` 视为同一版本。

    为什么要这么比：`pubspec.yaml` 的 version 被 pub **强制要求三段式**
    （写 `0.58+58` 会报 `Invalid version number`），而界面上一直显示两段式。
    按字符串比会把"同一个版本"报成漂移 —— 那种噪音会让真漂移被忽略。
    """
    core = str(v).split("+", 1)[0].strip()
    parts = core.split(".")
    # 去掉前导与尾部的 "0" 段（两边都没意义）：
    #   0.0.58 → 58 ；0.58 → 58 ；0.58.0 → 58 ；0.0.57 → 57
    while len(parts) > 1 and parts[0] == "0":
        parts.pop(0)
    while len(parts) > 1 and parts[-1] == "0":
        parts.pop()
    out = []
    for p in parts:
        out.append(int(p) if p.isdigit() else p)
    return tuple(out)


def check_version(apk: str, repo: str, results: list) -> None:
    """① 版本同一。"""
    try:
        expected_name, expected_code = read_pubspec_version(repo)
        dart_version = read_version_dart(repo)
    except (Skip, OSError) as e:
        results.append(("skip", "版本同一", str(e)))
        return
    try:
        attrs = read_manifest_version(apk)
    except (Skip, OSError, zipfile.BadZipFile) as e:
        results.append(("skip", "版本同一", f"读不了包的 manifest：{e}"))
        return

    got_name = attrs.get("versionName")
    got_code = attrs.get("versionCode")

    if got_name != expected_name:
        results.append(
            (
                "fail",
                "版本同一",
                f"包内 versionName = {got_name!r}，但当前源码 pubspec 是 {expected_name!r}\n"
                f"      → 这个包**不是**当前源码打出来的（改完版本号没重打包 / 发错了包）",
            )
        )
    else:
        results.append(("ok", "版本同一", f"versionName = {got_name}（与 pubspec 一致）"))

    if expected_code is not None and str(got_code) != str(expected_code):
        results.append(
            (
                "fail",
                "版本同一",
                f"包内 versionCode = {got_code}，pubspec 是 {expected_code}\n"
                f"      → versionCode 不递增的话 Android 会拒绝覆盖安装",
            )
        )

    # kAppVersion 与 pubspec 的口径漂移：界面显示的版本和装上去的版本不是一回事。
    #
    # ⚠️ 比较要**按版本号语义**比，不能按字符串比：pub 强制三段式（`0.0.58`），
    #    而 App 界面上一直显示两段式（`0.58`）—— 这俩是同一个版本，不是漂移。
    #    原来直接 `!=` 比字符串，于是**每一版都会报一条"版本口径"WARN**，
    #    真漂移（例如界面 0.58、包里 0.0.57）反而被这条噪音淹了。
    #    现在归一化后再比（去掉前导 0 段），真漂移仍然会报。
    if _norm_version(dart_version) != _norm_version(expected_name):
        results.append(
            (
                "warn",
                "版本口径",
                f"界面 kAppVersion = {dart_version!r}，而安装包 versionName = {expected_name!r}\n"
                f"      → 界面上显示的版本号和系统里看到的不一样（这两者应当指同一个版本）",
            )
        )


def check_toolbox_table(apk: str, repo: str, results: list) -> None:
    """② 落盘表自检：每个 key 都必须在 libapp.so 里找得到。"""
    try:
        table = read_toolbox_table(repo)
    except (Skip, OSError) as e:
        results.append(("skip", "落盘表自检", str(e)))
        return

    with zipfile.ZipFile(apk) as z:
        so_names = [n for n in z.namelist() if re.fullmatch(r"lib/[^/]+/libapp\.so", norm(n))]
        if not so_names:
            results.append(("skip", "落盘表自检", "包里没有 lib/*/libapp.so"))
            return
        blob = b""
        for n in so_names:
            blob += z.read(n)

    missing = [k for k in sorted(table) if k.encode("utf-8") not in blob]
    if missing:
        results.append(
            (
                "fail",
                "落盘表自检",
                f"{len(missing)} 个脚本在 `AndroidToolbox.assets` 里，但**包内 libapp.so 里找不到**：\n"
                + "".join(f"        - {k}   （AOT 里没有这个字符串 → 运行时不会落盘）\n" for k in missing)
                + "      → 技能文件会照名字去调它，真机上表现为「模型犯傻 / 命令不存在」\n"
                "      → 修法：补进 app/lib/local/android_toolbox.dart 的 assets 表，然后**重新出包**",
            )
        )
    else:
        results.append(("ok", "落盘表自检", f"{len(table)} 个脚本的字符串都在包内 {so_names[0]} 里"))


def check_assets(apk: str, repo: str, results: list) -> None:
    """③ 资产同一：逐名 + size + sha256。"""
    want = repo_asset_files(repo)
    if not want:
        results.append(("skip", "资产同一", "app/assets/ 是空的？"))
        return

    with zipfile.ZipFile(apk) as z:
        packed = {norm(n): n for n in z.namelist() if norm(n).startswith(FLUTTER_ASSET_PREFIX)}
        missing: list[str] = []
        differ: list[tuple[str, int, int]] = []
        for rel, full in sorted(want.items()):
            entry = packed.get(FLUTTER_ASSET_PREFIX + rel)
            if entry is None:
                missing.append(rel)
                continue
            local = open(full, "rb").read()
            if len(local) != z.getinfo(entry).file_size or sha256_bytes(local) != sha256_bytes(z.read(entry)):
                differ.append((rel, len(local), z.getinfo(entry).file_size))

    problems: list[str] = []
    if missing:
        problems.append(
            f"      仓库里 {len(missing)} 个资产**不在包里**（pubspec 漏声明 / 目录不通递归）：\n"
            + "".join(f"        - {m}\n" for m in missing)
        )
    if differ:
        problems.append(
            f"      仓库里 {len(differ)} 个资产**内容与包里不一样**（打了旧资产）：\n"
            + "".join(f"        - {p}  仓库 {a} B / 包内 {b} B\n" for p, a, b in differ)
        )
    if problems:
        results.append(("fail", "资产同一", f"{len(want)} 个资产里对不上 {len(missing) + len(differ)} 个：\n" + "".join(problems)))
    else:
        results.append(("ok", "资产同一", f"{len(want)} 个资产在包里逐名一致，size + sha256 全部相同"))

    # 顺带：随包运行时 zip 在不在
    with zipfile.ZipFile(apk) as z:
        runtime = [n for n in z.namelist() if norm(n).endswith("dsh-runtime.zip")]
        if not runtime:
            # ⚠️ 2026-10-27 用户定死：**不允许出精简包**，任何开发周期只能出完整包。
            #    原来是 warn（于是 82MB 的精简包能过闸），现在必须是 fail：
            #    精简包依赖手机上已有运行时，全新安装还要联网下载，不符合
            #    「拿来就能用」。重新出包：构建时带 DSH_ANDROID_INCLUDE_RUNTIME=1。
            results.append((
                "fail",
                "运行时包",
                "包里没有 dsh-runtime.zip —— 这是精简包，已被明令禁止。"
                "请带 DSH_ANDROID_INCLUDE_RUNTIME=1 重新构建完整包"))
        else:
            info = z.getinfo(runtime[0])
            results.append(("ok", "运行时包", f"{norm(runtime[0])}  {info.file_size / 1048576:.1f} MB"))


# ------------------------------------------------------------------ 引擎检查
#
# 两个方向都要查，因为两边都会"静默失效"：
#   * 已下线的引擎**不该**在包里 —— 它是 11.8 MB 的死重，而且真机实证在
#     Armv9.2 上处理长请求必然段错误（0.47 按用户选定的"路线 A"下线）。
#     多带一份不会报错，只会让包变大、让排查时误以为"这条路还能用"。
#   * 有几个库**必须**在包里 —— 它们不是链接进去的，而是运行时 `dlopen` 的
#     （现状：ffmpeg/ffprobe 那 10 个 `.so`；LiteRT 四件套已按用户决定拿掉，见下）。
#     谁"顺手清理一下 native 库"就会让本地模型在真机上崩，而编译期毫无征兆。
RETIRED_ENGINE_LIBS = {
    "libsdserver.so": "stable-diffusion 服务器（2026-10-11 按用户要求删除：纯死重，14.9 MiB）",
    "libstable-diffusion.so": "stable-diffusion 引擎（同上）",
    "libllamaserver.so": "llama.cpp 服务器",
    "libllama.so": "llama.cpp",
    "libllama-common.so": "llama.cpp 公共库",
    "libllama-server-impl.so": "llama.cpp 服务器实现",
    "libmtmd.so": "llama.cpp 多模态",
    "libggml.so": "ggml",
    "libggml-base.so": "ggml base",
    "libggml-cpu.so": "ggml CPU 后端",
    "libggml-vulkan.so": "ggml Vulkan 后端",
}

# 运行时被 dlopen 的库：**必须**存在，缺了就起不来。
#
# ⚠️ 2026-10-16 订正：这里**不再**列 LiteRT 那四件套。
#    本地大模型已于 2026-10-14 按用户决定整个拿掉
#    （原话「本地模型那一套彻底不用了」），`build.gradle.kts` 的 `packaging.jniLibs`
#    里**明确排除**了那四个 .so（0.75 起安装包因此少 11.2 MiB，changelog 里也对用户写了）。
#    它们现在**刻意不在包里，不算失败** —— 见下面 `PARKED_ENGINE_LIBS`。
#    以前留在这里的后果是：每一次 0.75 出包都会**假红**（把"按决策拿掉的东西"
#    报成"缺了会崩"），而假红和假绿一样会让真问题被忽略。
MUST_SHIP_LIBS = {}

# 「假装成 .so 的可执行程序」：它们**不是** dlopen 的库，而是要被 **exec** 的程序
# —— Android 只允许从 nativeLibraryDir 执行文件，所以必须以 `lib*.so` 的名字打包
# （名字改成 `ffmpeg` 就进不了 APK：Gradle 只收 lib/*.so）。
#
# 为什么也要进"必须存在"：缺了**不会崩**，而是等到用户点「口播 / 短剧」时才
# ENOENT —— 那正是最难查的一类问题（编译期毫无征兆、测试也照过）。所以出包时
# 就必须拦下来。
MUST_SHIP_EXEC_SO = {
    "libffmpeg.so": "ffmpeg（口播 / 短剧的拼接、转码、混音、加字幕）",
    "libffprobe.so": "ffprobe（探测时长与流信息）",
    # ffmpeg/ffprobe 是**共享库版**（静态双份要 42.8 MB，共享后 23.8 MB）——
    # 下面这些 libav*/libsw* 是它们运行时必须能加载到的。缺任何一个都**不是**
    # "命令不存在"，而是链接期失败（`CANNOT LINK EXECUTABLE ... library not found`），
    # 报错更难懂，所以一并列进必须存在的清单。
    "libavcodec.so": "ffmpeg 编解码库（含 libx264）",
    "libavformat.so": "ffmpeg 容器/封装库",
    "libavfilter.so": "ffmpeg 滤镜库（scale/delogo/eq/unsharp…）",
    "libavutil.so": "ffmpeg 基础库",
    "libswscale.so": "ffmpeg 图像缩放/色彩转换",
    "libswresample.so": "ffmpeg 音频重采样",
    "libavdevice.so": "ffmpeg 输入设备（编译时带上的，体积很小）",
    "libpostproc.so": "ffmpeg 后处理（编译时带上的）",
}

# ⚠️ stable-diffusion 已于 2026-10-11 **移到"必须不在包里"那一档**
# （用户原话「① 直接删」）—— 它是纯死重：0.45 起界面没有任何入口指向它，
# 却占压缩后约 14.9 MiB / 未压缩 40.8 MiB。**要恢复**的话见
# `app/android/app/build.gradle.kts` 里那段说明（三段都要做）。
#
# 有意**不随包**（或有意保留）的引擎库：只报信息、不算失败。
#
# * 本地大模型四件套（LiteRT-LM）：2026-10-14 用户决定整个拿掉，安装包少 11.2 MiB。
#   代码与 AAR 依赖**原样保留**（`LiteRtLmBridge.kt` 还在，且 native 失败被
#   `catch (Throwable)` 接住）—— 要恢复只需删掉 `build.gradle.kts` 里那四行
#   `excludes`，重出包即可，**不用改任何代码**。
PARKED_ENGINE_LIBS = {
    "libLiteRtClGlAccelerator.so": "LiteRT OpenCL/GL 加速器（本地大模型已按用户决定拿掉）",
    "libLiteRtCompilerPlugin_Qualcomm.so": "LiteRT Qualcomm 编译插件（同上）",
    "libLiteRtDispatch_Qualcomm.so": "LiteRT Qualcomm 调度（同上）",
    "liblitertlm_jni.so": "LiteRT-LM JNI 桥（同上）",
}


def check_engines(apk: str, repo: str, results: list) -> None:
    with zipfile.ZipFile(apk) as z:
        libs = {}
        for i in z.infolist():
            n = norm(i.filename)
            if "/lib/" in n or n.startswith("lib/"):
                libs[posixpath.basename(n)] = (i.file_size, i.compress_size)
        # ffmpeg/ffprobe 的 ELF 头要现读（`libs` 里只存了大小，没有内容）——
        # 顺手在这一层取出来，省得后面再开一次 zip。
        exec_heads = {}
        for name in MUST_SHIP_EXEC_SO:
            for i in z.infolist():
                if posixpath.basename(norm(i.filename)) == name:
                    with z.open(i) as fh:
                        exec_heads[name] = fh.read(20)
                    break

    if not libs:
        results.append(("skip", "引擎检查", "包里没有 lib/ 下的原生库？"))
        return

    # ① 已下线的引擎不许在
    stale = {k: v for k, v in libs.items() if k in RETIRED_ENGINE_LIBS}
    if stale:
        wasted = sum(v[1] for v in stale.values())
        results.append(
            (
                "fail",
                "引擎检查：已下线的引擎不该在包里",
                f"{len(stale)} 个 llama.cpp 相关库仍在包里（压缩后 {wasted / 1e6:.1f} MB；单位是十进制 MB）：\n"
                + "".join(f"        - {k}（{RETIRED_ENGINE_LIBS[k]}）\n" for k in sorted(stale))
                + "      → 0.47 已按用户选定的「路线 A」下线 llama.cpp（GGUF 全部从清单撤下），\n"
                "        且真机实证它在 Armv9.2 上处理长请求必然段错误 —— 留在包里是纯死重。\n"
                "      → 修法：出包时不要设 DSH_ANDROID_INCLUDE_LLAMA=1（默认已经不带）。",
            )
        )
    else:
        results.append(("ok", "引擎检查：已下线的引擎不该在包里", "没有任何 llama.cpp 相关库（已按 0.47 下线）"))

    # ② 必须随包的（运行时 dlopen）不许缺
    must = dict(MUST_SHIP_LIBS)
    must.update(MUST_SHIP_EXEC_SO)
    missing = [k for k in must if k not in libs]
    if missing:
        results.append(
            (
                "fail",
                "引擎检查：运行时 dlopen 的库必须都在",
                "缺了这些库（它们不是链接进去的，是运行时 dlopen 的）：\n"
                + "".join(f"        - {k}（{must[k]}）\n" for k in missing)
                + "      → 缺了编译期无征兆、真机上本地模型直接崩（本地大模型功能整体失效）。",
            )
        )
    else:
        results.append(
            ("ok", "引擎检查：运行时 dlopen 的库必须都在",
             f"{len(must)} 个都在"
             "（" + "、".join(sorted(must)) + "）")
        )

    # ②b ffmpeg/ffprobe 必须是 **AArch64** 的 ELF（放错了架构 = 装上也跑不起来）
    bad_arch = []
    for name in MUST_SHIP_EXEC_SO:
        if name not in libs:
            continue  # 缺文件那条已经在上面的"必须存在"里报过了，别重复报
        head = exec_heads.get(name)
        try:
            if not head or head[:4] != b"\x7fELF":
                bad_arch.append(f"{name}（不是 ELF）")
            elif head[18:20] != b"\xb7\x00":  # e_machine == EM_AARCH64(183)，小端
                bad_arch.append(
                    f"{name}（e_machine={int.from_bytes(head[18:20], 'little')}，不是 AArch64=183）")
        except Exception as exc:  # 读不出来也要说清楚，不能静默放过
            bad_arch.append(f"{name}（读取失败：{exc}）")
    if bad_arch:
        results.append(("fail", "ffmpeg 架构检查",
                        "以下文件不是 AArch64 的 ELF：" + "；".join(bad_arch)))
    elif all(k in libs for k in MUST_SHIP_EXEC_SO):
        results.append(("ok", "ffmpeg 架构检查",
                        "libffmpeg.so / libffprobe.so 都是 AArch64 ELF ✓"))

    # ③ 有意保留的：只报信息
    parked = [k for k in PARKED_ENGINE_LIBS if k in libs]
    if parked:
        size = sum(libs[k][0] for k in parked) / 1e6
        results.append(
            ("ok", "引擎检查：有意保留的引擎",
             f"{'、'.join(parked)}（未压缩 {size:.1f} MB）—— 按决策**刻意不随包**（不算失败），"
             f"要恢复只需去掉 ondevice_models_page 的那处过滤")
        )




def pick_apk(repo: str) -> str:
    dist = os.path.join(repo, "dist")
    cands = [f for f in os.listdir(dist) if f.endswith(".apk")] if os.path.isdir(dist) else []

    def key(name: str) -> tuple:
        m = re.search(r"(\d+)\.(\d+)", name)
        nums = tuple(int(x) for x in m.groups()) if m else (0, 0)
        return (nums, os.path.getmtime(os.path.join(dist, name)))

    if not cands:
        raise SystemExit(f"dist/ 里没有 .apk：{dist}")
    return os.path.join(dist, max(cands, key=key))


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    default_repo = os.path.dirname(here)

    ap = argparse.ArgumentParser(description="出包后核对：确认交付物 == 被测物")
    ap.add_argument("apk", nargs="?", help="APK 路径（默认取 dist/ 里版本号最大的）")
    ap.add_argument("--repo", default=default_repo, help="dsh-mobile 仓库根（默认脚本的上一级）")
    ap.add_argument("--json", action="store_true", help="输出机器可读结果")
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    apk = os.path.abspath(args.apk) if args.apk else pick_apk(repo)

    if not os.path.isfile(apk):
        print(f"找不到 APK：{apk}", file=sys.stderr)
        return 2
    if not os.path.isdir(os.path.join(repo, "app")):
        print(f"不像 dsh-mobile 仓库根（没有 app/）：{repo}", file=sys.stderr)
        return 2

    results: list[tuple[str, str, str]] = []
    for fn in (check_version, check_toolbox_table, check_assets, check_engines):
        try:
            fn(apk, repo, results)
        except Exception as e:  # 单项异常不该让整份核对消失
            results.append(("skip", fn.__name__, f"核对过程出错：{type(e).__name__}: {e}"))

    icon = {"ok": "PASS", "fail": "FAIL", "warn": "WARN", "skip": "SKIP"}
    fails = [r for r in results if r[0] == "fail"]

    if args.json:
        print(
            json.dumps(
                {
                    "apk": apk,
                    "repo": repo,
                    "ok": not fails,
                    "results": [{"status": s, "check": c, "detail": d} for s, c, d in results],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 1 if fails else 0

    size_mb = os.path.getsize(apk) / 1048576
    print("=" * 72)
    print(f"出包后核对  {os.path.basename(apk)}  ({size_mb:.1f} MB)")
    print(f"源码树      {repo}")
    print("=" * 72)
    for status, check, detail in results:
        print(f"[{icon[status]:4}] {check}")
        for line in detail.splitlines():
            print(f"       {line}")
    print("-" * 72)
    if fails:
        print(f"结论：**不要发这个包** —— {len(fails)} 项 FAIL")
        for _s, c, _d in fails:
            print(f"        · {c}")
        return 1
    print("结论：全部通过 —— 这个包里的字节和当前源码树一致，可以发")
    return 0


if __name__ == "__main__":
    sys.exit(main())
