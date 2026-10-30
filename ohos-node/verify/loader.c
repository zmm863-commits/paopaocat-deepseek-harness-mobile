/* 模拟鸿蒙加载 libnode.so。
 * 补一个 OHOS musl 特有的 fortify 符号：真机上有，模拟环境没有。 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>

typedef int (*node_start_fn)(int argc, char** argv);

/* OHOS libc 的 __fd_chk：fortify 下校验 fd。
 * 用变参实现，兼容不同调用形态；返回 fd 本身。 */
int __fd_chk(int fd, ...) { return fd; }

/* pthread_cond_clockwait 是 musl 1.2.4+ / glibc 2.30+ 的接口。
 * Alpine 3.20 的 musl 1.2.5 里没有它（OHOS 的 musl 有），用 timedwait 降级。 */
#include <pthread.h>
#include <time.h>
int pthread_cond_clockwait(pthread_cond_t* cond, pthread_mutex_t* mutex,
                           clockid_t clockid, const struct timespec* abstime) {
  (void) clockid;
  return pthread_cond_timedwait(cond, mutex, abstime);
}

int main(int argc, char** argv) {
  const char* lib = (argc > 1) ? argv[1] : "/tmp/ohos-node/lib/libnode.so";
  printf("[loader] dlopen(%s)\n", lib);
  void* h = dlopen(lib, RTLD_NOW | RTLD_GLOBAL);
  if (!h) { printf("[loader] ✗ dlopen: %s\n", dlerror()); return 1; }
  printf("[loader] ✓ dlopen 成功\n");

  void* sym = dlsym(h, "_ZN4node5StartEiPPc");
  if (!sym) { printf("[loader] ✗ dlsym: %s\n", dlerror()); return 2; }
  printf("[loader] ✓ node::Start @ %p\n", sym);

  /* 参数：argv[1]=libnode.so，argv[2..]=node 自己的参数 */
  int n = argc - 1;
  if (n < 1) { printf("[loader] 用法: loader <libnode.so> [node 参数...]\n"); return 3; }
  char** nargv = malloc(sizeof(char*) * (n + 1));
  nargv[0] = "node";
  for (int i = 1; i < n; i++) nargv[i] = argv[i + 1];
  printf("[loader] → node::Start(argc=%d)\n", n);
  for (int i = 0; i < n; i++) printf("[loader]    argv[%d]=%s\n", i, nargv[i]);
  fflush(stdout);
  int rc = ((node_start_fn) sym)(n, nargv);
  printf("[loader] node::Start 返回 %d\n", rc);
  return rc;
}
