# Linux 环境打包记录（0.15 实际流程）

> 背景：原开发机是 Windows（工具链在 `D:\dev\*`），迁移到本机 Linux 后**打包环境是从零搭的**。
> 本文记录**实际跑通的步骤**与**三个中文路径坑**，照着做即可复现。
> 产物：`dist/paopaocat-preview-0.15-arm64-v8a.apk`（187.7 MB）
> 日期：2026-10-05

---

## 0. 一句话结论

```
187.7 MB · arm64-v8a 单架构 · versionCode 15 / versionName 0.0.15
签名 7aaf4448…d3cc17（与 0.14 同一把 debug 证书 → 可直接覆盖安装）
sha256 e0ae462dc1d88f715b4cfedaf6697c173d2b92b578d013876e04bccb97f433eb
```

---

## 1. 工具链（本机装好后与文档记录版本对齐）

| 组件 | 版本 | 位置 | 备注 |
|---|---|---|---|
| Flutter | 3.47.6（Dart 3.13.5） | `/opt/flutter` | 与原 Windows 机一致 |
| JDK | **17.0.20.1** | `/usr/lib/jvm/java-17-openjdk-amd64` | apt 装的 `openjdk-17-jdk`，**版本与原文档记录完全一致** |
| Android SDK | cmdline-tools 19.0 / platforms 36 / build-tools 36.0.0 | `/opt/android-sdk` | 另自动补装了 platforms 34/35、CMake 3.22.1 |
| Gradle | 9.3.1（wrapper 自动下载） | `$GRADLE_USER_HOME/wrapper/dists` | 腾讯镜像，首次约 200 MB |
| 构建依赖 | `dsh-runtime.zip` 151 MB + `jnilibs/arm64-v8a` 11 个 .so | `/tmp/dshbuild/android-node` | **从迁移包 `03-build-deps/` 取** |

> ⚠️ `openjdk-17-jdk-headless` **不够用**：headless 包会让 `sdkmanager` 在
> `LoggerFinderLoader` 初始化处抛 `NoClassDefFoundError`。装完整版 `openjdk-17-jdk`。

---

## 2. 三个中文路径坑（本次全部踩到，根因同一个）

**现象**：任何由 JVM / Dart analyzer 处理"路径"的环节，遇到 `/root/办公`（中文）就失败。
本机 Docker 容器时区是 UTC、locale 是 `en_US`，默认字符集无法映射中文路径。

| # | 在哪踩到 | 报错 | 处置 |
|---|---|---|---|
| ① | `flutter analyze` / `flutter test` | `FormatException: Unexpected end of input`（LSP 分帧字节数错位） | 源码留中文路径，**构建/测试在 ASCII 镜像 `/tmp/dsh-app` 里做** |
| ② | **JVM 启动本身**（`sdkmanager`、`keytool`、`gradle`） | `NoClassDefFoundError: Could not initialize class jdk.internal.logger.LoggerFinderLoader`，根因是 `InvalidPathException: Malformed input ... /root/??????`（`FilePermission.<clinit>`） | **所有命令必须在 ASCII 目录下执行**（`cd /tmp`），依赖也搬去 `/tmp/dshbuild` |
| ③ | `apksigner verify` / `keytool -list` 读中文路径下的文件 | `FileNotFoundException: /root/??????/...` | 先把待处理文件 `cp` 到 `/tmp` 再操作 |

> 判据：同一个 Java 命令，在 `/tmp` 下能跑通、在 `/root/办公` 下报错 —— 那就是坑 ②/③，不是文件损坏。

---

## 3. 关键配置改动

### 3.1 `android/app/build.gradle.kts`：运行时资源路径参数化

原先是写死的 Windows 路径，改成环境变量（默认指向本机 ASCII 目录）：

```kotlin
val dshNodeRoot = System.getenv("DSH_ANDROID_NODE") ?: "/tmp/dshbuild/android-node"
sourceSets {
    getByName("main") {
        assets.srcDirs("src/main/assets", "$dshNodeRoot/app-assets")
        jniLibs.srcDirs("src/main/jniLibs", "$dshNodeRoot/jnilibs")
    }
}
```

Windows 上仍可用：`$env:DSH_ANDROID_NODE = 'D:/dev/android-node'`。

### 3.2 `android/local.properties`（本机文件，已在 .gitignore）

```properties
sdk.dir=/opt/android-sdk
flutter.sdk=/opt/flutter
```

### 3.3 `android/gradle.properties`：写入目标 ABI

```properties
dshAbi=arm64-v8a
```

**为什么不用环境变量**：Gradle daemon 会缓存进程环境，`ORG_GRADLE_PROJECT_dshAbi`
在 daemon 复用时读不到，默认 ABI 会静默生效（原文档 §3.5 记的就是这个坑）。

---

## 4. ⚠️ 最容易漏的一步：签名证书必须沿用原机器的

**本次实际踩到并修好**：

* 首次构建用的是本机 Flutter 自动生成的 `~/.android/debug.keystore`
  → 签名 `2e44eacd…a0b0`
* 而 0.14 交付记录写的是 `7aaf4448…d3cc17`
* **两者不同 = 装过 0.14 的手机无法覆盖安装**（Android 要求同签名），
  用户只能卸载重装（**会丢数据**）

**解法**：迁移包 `03-build-deps/debug.keystore` 就是原机器那把。装回去即可：

```bash
cp /root/办公/__migr/03-build-deps/debug.keystore ~/.android/debug.keystore
# 验指纹（注意：keytool 读中文路径会失败，先 cp 到 /tmp）
keytool -list -v -keystore ~/.android/debug.keystore -storepass android -alias androiddebugkey
# 期望：SHA256: 7A:AF:44:48:15:AC:78:E3:39:6E:D5:E9:5B:D4:E8:F4:83:74:52:54:55:96:15:D1:BF:D5:F2:01:80:D3:CC:17
```

换掉 keystore 后**必须重新构建**（重签会破坏 zipalign 之外的完整性保证，重构建最干净；
Gradle 有缓存，第二次只要约 18 秒）。

---

## 5. 完整构建命令（实测跑通）

```bash
# ① 依赖搬进 ASCII 路径（只做一次）
mkdir -p /tmp/dshbuild/android-node/app-assets
cp /root/办公/__migr/03-build-deps/android-node/app-assets/dsh-runtime.zip \
   /tmp/dshbuild/android-node/app-assets/
cp -r /root/办公/__migr/03-build-deps/android-node/jnilibs /tmp/dshbuild/android-node/

# ② 同步源码到 ASCII 构建目录
bash /root/办公/sync-dsh-app.sh

# ③ 写目标 ABI + 清旧产物（旧产物会被误当本次结果）
grep -v '^\s*dshAbi\s*=' /tmp/dsh-app/android/gradle.properties > /tmp/gp && \
  mv /tmp/gp /tmp/dsh-app/android/gradle.properties
echo "dshAbi=arm64-v8a" >> /tmp/dsh-app/android/gradle.properties
rm -rf /tmp/dsh-app/build/app/outputs/flutter-apk

# ④ 构建（必须在 ASCII 目录下执行！）
cd /tmp/dsh-app
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOME=/opt/android-sdk  ANDROID_SDK_ROOT=/opt/android-sdk
export DSH_ANDROID_NODE=/tmp/dshbuild/android-node
export GRADLE_USER_HOME=/tmp/gradle-home
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PATH="/opt/flutter/bin:$JAVA_HOME/bin:$PATH"

flutter pub get
flutter build apk --release --target-platform android-arm64
# → build/app/outputs/flutter-apk/app-release.apk（196.8 MB）

# ⑤ 按统一命名落盘（只取本次的 app-release.apk）
cp build/app/outputs/flutter-apk/app-release.apk \
   /root/办公/dsh-mobile/dist/paopaocat-preview-0.15-arm64-v8a.apk
```

首次构建 **958 秒**（要下 Gradle + AGP + Kotlin 依赖、自动补 SDK 组件）；之后 **约 18 秒**。

---

## 5.1 ⚠️ 只出完整包（2026-10-27 用户定死）

**「精简包」已被明令禁止 —— 任何开发周期只能出完整包。** 出包命令必须带
`DSH_ANDROID_INCLUDE_RUNTIME=1`：

```bash
DSH_ANDROID_INCLUDE_RUNTIME=1 flutter build apk --release --target-platform android-arm64
# → 约 113 MB（含 assets/dsh-runtime.zip 32.9 MB）
```

理由：精简包依赖手机上已有运行时，全新安装还要联网下载 `dsh-runtime.zip`，
不符合「拿来就能用」。`install/check-release.py` 已把「缺 dsh-runtime.zip」
从 `warn` 改成 **`fail`**，出精简包过不了闸。

> 历史（存档）：早期区分为「精简包 83MB（给应用内更新）/ 完整包 106MB（给全新安装）」。

0.75 起**每次出包都要出两个**（同 versionCode、同签名，可互相覆盖）：

| | 命令 | 给谁 | 包里带 `assets/dsh-runtime.zip`？ |
|---|---|---|---|
| 精简包 | `flutter build apk --release --target-platform android-arm64` | 应用内更新（手机里已有运行时） | ❌ |
| 完整包 | `DSH_ANDROID_INCLUDE_RUNTIME=1 flutter build apk --release --target-platform android-arm64` | 全新安装 | ✅ |

开关的实现见 `app/android/app/build.gradle.kts` 的 `sourceSets.main.assets.srcDirs`
（`includeRuntime` 决定要不要把 `$DSH_ANDROID_NODE/app-assets` 挂上）。

⚠️ 两个坑（2026-10-16 实测）：
1. **`gradlew` 在 `android/` 下**，同步过来的副本**没有执行位** → 先 `chmod +x android/gradlew`；
2. **`PUB_HOSTED_URL` 是 `https://pub.flutter-io.cn`**（不是 `storage.flutter-io.cn`，
   写错的话 `flutter pub get` 会报 `could not find package flutter_lints`）；
3. 切换 flavor 之前清一下 `build/app/intermediates/{assets,merged_native_libs,stripped_native_libs}`，
   免得 Gradle 的增量判断把上一次的原生库留在包里。

## 5.2 ⚠️ `$DSH_ANDROID_NODE/jnilibs` 里有两个来源，重建时**别把它们弄丢**

`jniLibs.srcDirs` 收两个目录的内容：

* **Termux 的 node 与依赖库**（libnode / libicu* / libcrypto3…）—— 由
  `install/fetch-termux-deps.mjs` + `install/normalize-runtime-libs.mjs` 重新生成；
* **ffmpeg 那一套 10 个 `.so`**（libffmpeg / libffprobe / libav* / libsw* / libpostproc）
  —— 由 `install/build-ffmpeg-android.sh` 编出来**手工放进去的**，**上面那两个脚本不会生成它们**。

2026-10-16 就踩了这个坑：重建 `android-node` 之后 ffmpeg 那 10 个文件没了，
于是 0.75 的 `20261015a`~`h` 全部**没有 ffmpeg**（口播 / 短剧 / 剪辑 / 配音在真机上 ENOENT），
而 `libapp.so` 里的字符串、单测、`flutter analyze` **全部照过** —— 只有
`python3 install/check-release.py`（只认包里的字节）能拦下来。

所以：**重建构建目录后，务必跑一次 `check-release.py`**；持久副本放在
`/root/办公/__migr/03-build-deps/android-node/jnilibs/`（与 node 依赖同处），
丢了就从最近的 `dist/*.apk` 里取回（`unzip -j <apk> 'lib/arm64-v8a/libav*.so' …`）。

## 5.3 ⚠️ 想核对"包里的文案"时：Dart AOT 把中文存成 **UTF-16LE**

出 0.76 时差点因此误判成"更新说明没进包"：拿 `unzip -p … libapp.so | strings | grep '检查更新'`
**一个都找不到**（连 0.75 包里早就有的文案也找不到）。真因是 **Dart AOT 的字符串常量**：
纯 ASCII 的存成一字节（Latin-1，能被 `grep`/`strings` 直接看到），
**含中文的存成两字节 UTF-16LE** —— 所以按 UTF-8 找永远是 0。

正确的核对姿势（Python）：

```python
import zipfile
blob = zipfile.ZipFile('dist/xxx.apk').read('lib/arm64-v8a/libapp.so')
print(blob.count('修好 20 个问题'.encode('utf-16-le')))   # 1 表示在包里
```

`install/check-release.py` 之所以没踩这个坑，是因为它只核对**纯 ASCII** 的东西
（脚本路径、`AndroidToolbox.assets` 的 key）。

## 6. 交付前静态自检（本次全部通过）

```bash
cd /tmp
export PATH="$JAVA_HOME/bin:/opt/android-sdk/build-tools/36.0.0:$PATH"
cp /root/办公/dsh-mobile/dist/paopaocat-preview-0.15-arm64-v8a.apk /tmp/verify.apk
```

| # | 检查项 | 本次结果 |
|---|---|---|
| ① | 包名 / 版本 | `com.dshmobile.dsh_mobile` · versionCode **15** · versionName **0.0.15** |
| ② | ABI | **仅 `arm64-v8a`**（`native-code: 'arm64-v8a'`） |
| ③ | native 库数量 | **15 个**（11 个 DSH 运行时库 + libapp/libflutter/libdartjni/libdatastore） |
| ④ | `libnode.so` | ELF 64-bit **ARM aarch64**，interpreter `/system/bin/linker64`，48 MB |
| ⑤ | shell 路径补丁 | `/data/data/com.termux/files/usr/bin/sh` 残留 **0**、`/system/bin/sh` 已应用 |
| ⑥ | `assets/dsh-runtime.zip` | **26495** 条目，151 MB |
| ⑦ | 签名 | `7aaf4448…d3cc17`（**与 0.14 一致 → 可覆盖安装**） |
| ⑧ | 依赖闭包 | 全部 `DT_NEEDED` 能在 jniLibs 内解析，**0 缺失**（含 `libz1.so`） |
| ⑨ | 权限 | 12 条（含本次新增的 LOCATION / READ_MEDIA_*） |
| ⑩ | 体积 | 187.7 MB（0.14 是 187.6 MB） |

---

## 7. 复现注意事项（给下一次）

1. **一切都在 ASCII 路径下做** —— 源码可以留中文路径，但 analyzer / JVM / Java 工具必须在 ASCII 目录执行。
2. **签名证书是交付的一部分** —— 换机器打包时，务必沿用原机器的 `debug.keystore`，否则老用户无法覆盖安装。
   本次已把它装到 `~/.android/debug.keystore`（备份了本机自动生成的到 `/tmp/debug.keystore.bak-2e44eacd`）。
3. **只取 `app-<mode>.apk`** —— 构建前清空 `flutter-apk` 目录；文档 §5 记过一次"名字写 arm64、内容其实是 x86_64"的事故。
4. `dshAbi` 写 `gradle.properties` 而不是环境变量（daemon 缓存）。
5. 别用 headless JDK。
