# 本地验证 node 能不能在鸿蒙的 musl 上跑（不需要真机）

## 为什么需要这个

鸿蒙上跑 node 的最大未知是「libnode.so 能不能 dlopen、V8 能不能初始化」。
这些不需要真机也能验证——用 qemu 的用户态模拟即可。

## 三条命令

```bash
# 1. 装 qemu（不需要 KVM，用户态模拟）
apt-get install -y qemu-user

# 2. 拿一个 aarch64 的 musl loader（OHOS SDK 的 sysroot 里没有，
#    那是设备上才有的 /system/lib/ld-musl-aarch64.so.1）
curl -sL -o m.apk https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/musl-1.2.5-r4.apk
tar -xzf m.apk lib/ld-musl-aarch64.so.1

# 3. 跑
qemu-aarch64 -L <ohos-sysroot> \
  -E LD_LIBRARY_PATH=<libnode目录>:<ohos-sysroot>/usr/lib/aarch64-linux-ohos \
  lib/ld-musl-aarch64.so.1 ./loader <libnode目录>/libnode.so --version
```

## loader 要补两个 OHOS 特有符号

Alpine 的 musl 没有、但 OHOS 的 musl 有：

```c
int __fd_chk(int fd, ...) { return fd; }                    // fortify fd 检查
int pthread_cond_clockwait(...) { return pthread_cond_timedwait(...); }
```

补这两个之后 libnode.so 就能完整加载。**这两个是真机 libc 自带的，
所以不是产品缺陷，纯粹是模拟环境缺件。**

## 实测结果（2026-10-26）

```
✓ dlopen 成功
✓ node::Start 找到并执行
v22.14.0                       ← V8 初始化成功
JS 跑起来了: v22.14.0 linux arm64
ESM ok function                ← 模块系统正常
import 耗时 718 ms              ← dsh 的 bin.js 能加载
exit=0
```

## 这个方法测不出什么

- 鸿蒙的 seccomp 会不会拦 syscall
- 真机的 SELinux / dlopen 路径策略
- Flutter ↔ ArkTS 的 MethodChannel 通不通

那三项只能真机验。
