/*
 * node_host.cpp —— 在鸿蒙 App 进程内启动 node（通过 dlopen libnode.so）
 *
 * 为什么不是 Process.start 一个 node 可执行文件：
 *   HarmonyOS 的 seccomp 策略不允许应用 fork/exec 任意二进制，
 *   libnode.so 只能是共享库，由宿主进程 dlopen 后在同一进程里跑。
 *
 * 关键约束（全部实测得到，踩错一条就崩）：
 *   1. argc **不能**把 argv 末尾的 nullptr 算进去 —— 多算一个，node 拿到
 *      NULL 参数，5 毫秒内段错误。
 *   2. node::Start 每个进程只能调一次。调第二次直接崩，没有优雅退路。
 *      所以这里用 g_started 闸门，第二次调用明确拒绝而不是让进程崩掉。
 *   3. libnode.so 必须由 RTLD_GLOBAL 打开 —— V8 和 node 内部有跨库符号引用，
 *      RTLD_LOCAL 会让部分符号解析失败。
 *   4. 必须在 thread 里 setenv 完再调 node::Start：node 内部读 getenv，
 *      而且 libuv 在初始化时就会快照部分环境。
 *   5. **92MB 的同步 dlopen 绝不能在 ArkTS 主线程做**（2026-10-28 真机教训）：
 *      主线程加载 92MB .so + 9.3 万符号重定位要几十秒，系统按 ANR 杀进程
 *      → 表现成"点Bot 后 App 闪退重启"。所以 startNode 收到请求后**立即
 *      返回**，加载与启动全部在后台线程完成；结果只写 stderr(hilog) 和
 *      stdout 文件，不发回调用方。
 *   6. stdout 必须重定向到文件（stdoutPath）：进程内 node 的 stdout 无法被
 *      宿主读取，Dart 侧轮询这个文件抓 "dsh web: http://127.0.0.1:<port>"
 *      就绪行。宿主自己的 [node_host] 日志全走 stderr，不受影响。
 *
 * 线程模型：node::Start 会安装信号处理器并接管若干 fd，必须放在独立线程里跑，
 * 不能挡住 ArkTS 的主线程。
 */

#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/mman.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "napi/native_api.h"
#include "hilog/log.h"

namespace {

constexpr const char* kStartSymbol = "_ZN4node5StartEiPPc";
using NodeStartFn = int (*)(int argc, char** argv);

struct StartContext {
  std::string lib_path;
  std::vector<std::string> arg_storage;
  std::vector<char*> argv;
  std::string stdout_path;
  // env pairs 由 worker 线程 setenv（setenv 非线程安全区不高于 start 前）
  std::vector<std::pair<std::string, std::string>> env_pairs;
};

std::mutex g_mutex;
bool g_started = false;
StartContext* g_ctx = nullptr;

// 崩溃也不丢的笔迹：native 各步干完都追加写这个文件，Dart 端轮询读出来。
// 若进程死在某一步，笔迹到哪一行断掉，那就是 kill 的位置。
std::string g_trace_path;
int g_trace_fd = -1;
// 崩溃信号落笔迹：node::Start 一崩，最后一行写的是哪个信号，就是死因。
static void CrashSigHandler(int sig) {
  // 用裸 write 最安全（崩溃态不能再走 C++ 流）
  char buf[64];
  int n = snprintf(buf, sizeof(buf), "CRASH signal=%d (SIGSEGV=11 SIGABRT=6 SIGILL=4 SIGBUS=7)\n", sig);
  if (n > 0 && g_trace_fd >= 0) {
    (void)write(g_trace_fd, buf, (size_t)n);
  }
  // 恢复默认并重发，让系统正常出 tombstone（如果它能出的话）
  signal(sig, SIG_DFL);
  raise(sig);
}

// SIGSYS：鸿蒙 seccomp 拦截了某个 syscall（实测是 libuv 探测的 io_uring_setup(425)）。
// 参考实现实证：必须把 trap 的返回值改成「正好 -1」（不是 -ENOSYS），libuv 的守卫才认；
// 并跳过那条 svc 指令，否则会无限重试同一个调用。
// 不处理的话默认动作是杀进程 —— 表现就是「trace 停在 w7、无 CRASH、无 w8」，极难定位。
static void SigSysHandler(int sig, siginfo_t* si, void* raw_ctx) {
  ucontext_t* uc = reinterpret_cast<ucontext_t*>(raw_ctx);
  long sc = (si != nullptr) ? si->si_syscall : -1;
  unsigned long pc = (uc != nullptr) ? uc->uc_mcontext.pc : 0;
  unsigned int insn = 0;
  if (pc != 0) {
    // 代码段可读，读 PC 处 4 字节判断是不是 svc #0（编码 0xD4000001）
    insn = *reinterpret_cast<unsigned int*>(pc);
  }
  const char* iouring = getenv("UV_USE_IO_URING");
  char buf[256];
  int n = snprintf(buf, sizeof(buf),
                   "SIGSYS sc=%ld pc=0x%lx insn=0x%08x(是svc:%d) UV_USE_IO_URING=%s\n",
                   sc, pc, insn, (insn == 0xD4000001u), iouring ? iouring : "(空)");
  if (n > 0 && g_trace_fd >= 0) (void)write(g_trace_fd, buf, (size_t)n);
#if defined(__aarch64__)
  if (uc != nullptr) {
    // ⚠️ 只改返回值，**不能动 PC**：真机实测 trap 时 PC 已指向 svc 之后
    // （读到的是 B 跳转指令而不是 svc #0），再 +4 会跳过一条有效指令 → SIGSEGV。
    uc->uc_mcontext.regs[0] = static_cast<unsigned long>(-1);  // x0 = -1
  }
#endif
}

void InstallCrashHandlers() {
  signal(SIGSEGV, CrashSigHandler);
  signal(SIGABRT, CrashSigHandler);
  signal(SIGILL,  CrashSigHandler);
  signal(SIGBUS,  CrashSigHandler);

  // SIGSYS 必须用 sigaction 带 SA_SIGINFO（需要 si_syscall 和 ucontext）
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = SigSysHandler;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGSYS, &sa, nullptr);
}

void TW(const std::string& step) {
  if (g_trace_path.empty()) {
    return;
  }
  if (g_trace_fd < 0) {
    g_trace_fd = open(g_trace_path.c_str(), O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (g_trace_fd < 0) {
      return;
    }
  }
  dprintf(g_trace_fd, "%s\n", step.c_str());
}

// 日志：⚠️ 应用进程的 stderr **不进 hilog**（2026-10-28 真机黑屏教训），
// 必须走 OH_LOG_Print 才能真正出现在 hilog 里。stderr 保留一份给命令行测试。
// stdout 已被 node 占用，这里绝不能写 stdout。
#define LOGI(...)                                            \
  do {                                                       \
    TW("[oh] " __VA_ARGS__);                                 \
  } while (0)

/*
 * worker 线程：dlopen → dlsym → setenv → freopen(stdout) → node::Start。
 * 每一步都写stderr —— 失败时这是唯一可查的现场（hilog | grep node_host）。
 */
void* NodeMain(void* raw) {
  auto* ctx = static_cast<StartContext*>(raw);
  TW("w0 线程启动");
  InstallCrashHandlers();

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_started) {
      TW("[oh] 另一线程已启动 node 拒绝");
      return nullptr;
    }
  }

  TW("w1 dlopen 前");
  void* handle = dlopen(ctx->lib_path.c_str(), RTLD_NOW | RTLD_GLOBAL);
  if (handle == nullptr) {
    TW("w1x dlopen 失败");
    TW(std::string("w1x dlopen err: ") + (dlerror() ? dlerror() : "unknown"));
    return nullptr;
  }
  TW("w2 dlopen 后");

  void* sym = dlsym(handle, kStartSymbol);
  if (sym == nullptr) {
    TW("w2x dlsym 失败");
    TW(std::string("w2x dlsym err: ") + (dlerror() ? dlerror() : "unknown"));
    return nullptr;
  }
  TW("w3 dlsym 后");

  for (const auto& kv : ctx->env_pairs) {
    setenv(kv.first.c_str(), kv.second.c_str(), 1);
  }
  // 鸿蒙 seccomp 会 trap io_uring_setup(425)，而 libuv 初始化时**无条件**探测它。
  // 关掉探测（必须在 node::Start / libuv 初始化之前）—— 这是根治，SIGSYS handler 只是兜底。
  setenv("UV_USE_IO_URING", "0", 1);
  TW(std::string("w4 env 写入 ") + std::to_string(ctx->env_pairs.size()) + " 项");
  TW("w4 env 已写入");

  if (!ctx->stdout_path.empty()) {
    // ⚠️ 用 dup2 而不是 freopen：node 的 console.log 走 libuv → 直接写 fd 1。
    // 关键：**stderr 也必须 dup2 到同一个文件**——node 的致命错误走 stderr，
    // 而 App 进程的 stderr 在鸿蒙上进不了 hilog，不重定向就永远看不到死因。
    int outfd = open(ctx->stdout_path.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (outfd < 0) {
      TW(std::string("w-f stdout 打开失败: ") + ctx->stdout_path);
    } else {
      if (dup2(outfd, STDOUT_FILENO) < 0) {
        TW(std::string("w-f dup2 stdout 失败: ") + ctx->stdout_path);
      }
      if (dup2(outfd, STDERR_FILENO) < 0) {
        TW(std::string("w-f dup2 stderr 失败: ") + ctx->stdout_path);
      }
      if (outfd != STDOUT_FILENO && outfd != STDERR_FILENO) close(outfd);
      TW(std::string("w-f stdout+stderr 已 dup2 到 ") + ctx->stdout_path);
    }
  }
  TW("w5 stdout 已定向");

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_started = true;
  }
  TW("w6 闸门已置，准备 start");

  int argc = static_cast<int>(ctx->argv.size());
  TW(std::string("w7 node::Start 启动 argc=") + std::to_string(argc));
  for (int i = 0; i < argc; i++) {
    TW(std::string("argv[") + std::to_string(i) + "]= " + (ctx->argv[i] ? ctx->argv[i] : "(null)"));
  }
  TW("w7 node::Start 开跑");
  int rc = reinterpret_cast<NodeStartFn>(sym)(argc, ctx->argv.data());
  TW(std::string("w8 node::Start 已退出 rc=") + std::to_string(rc).c_str());
  return nullptr;
}

// 从 napi object 里读一个 string 字段；缺省返回 def。
std::string GetStringProp(napi_env env, napi_value obj, const char* key,
                          const std::string& def = "") {
  napi_value v = nullptr;
  if (napi_get_named_property(env, obj, key, &v) != napi_ok) return def;
  napi_valuetype t;
  if (napi_typeof(env, v, &t) != napi_ok || t != napi_string) return def;
  size_t len = 0;
  if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return def;
  std::string out(len, '\0');
  size_t copied = 0;
  napi_get_value_string_utf8(env, v, out.data(), len + 1, &copied);
  out.resize(copied);
  return out;
}

// 从 napi object 里读全部 string 值（env 对象 → 键值列表）
std::vector<std::pair<std::string, std::string>> GetEnvPairs(napi_env env,
                                                             napi_value obj) {
  std::vector<std::pair<std::string, std::string>> out;
  napi_value keys = nullptr;
  if (napi_get_property_names(env, obj, &keys) != napi_ok) return out;
  uint32_t n = 0;
  if (napi_get_array_length(env, keys, &n) != napi_ok) return out;
  for (uint32_t i = 0; i < n; i++) {
    napi_value k = nullptr, v = nullptr;
    if (napi_get_element(env, keys, i, &k) != napi_ok) continue;
    if (napi_get_property(env, obj, k, &v) != napi_ok) continue;
    size_t klen = 0, vlen = 0;
    napi_get_value_string_utf8(env, k, nullptr, 0, &klen);
    napi_get_value_string_utf8(env, v, nullptr, 0, &vlen);
    std::string ks(klen, '\0'), vs(vlen, '\0');
    size_t c1 = 0, c2 = 0;
    napi_get_value_string_utf8(env, k, ks.data(), klen + 1, &c1);
    napi_get_value_string_utf8(env, v, vs.data(), vlen + 1, &c2);
    ks.resize(c1);
    vs.resize(c2);
    if (!ks.empty()) out.emplace_back(std::move(ks), std::move(vs));
  }
  return out;
}

napi_value MakeBool(napi_env env, bool b) {
  napi_value v = nullptr;
  napi_get_boolean(env, b, &v);
  return v;
}

napi_value MakeString(napi_env env, const std::string& s) {
  napi_value v = nullptr;
  napi_create_string_utf8(env, s.c_str(), s.size(), &v);
  return v;
}

void FinishResult(napi_env env, napi_value result, bool ok,
                  const std::string& error = "", int32_t argc = -1) {
  napi_set_named_property(env, result, "ok", MakeBool(env, ok));
  napi_set_named_property(env, result, "error", MakeString(env, error));
  if (argc >= 0) {
    napi_value a = nullptr;
    napi_create_int32(env, argc, &a);
    napi_set_named_property(env, result, "argc", a);
  }
}

/*
 * startNode({
 *   libPath: string,        // libnode.so 绝对路径
 *   args:    string[],      // node argv（完整，无哨兵）
 *   env:     object,        // 环境变量
 *   stdoutPath: string,     // node stdout 落盘文件（供 Dart 轮询）
 * }) -> { ok, argc, error }
 *
 * ⚠️ 本函数**不做** dlopen：解析 opts + 建后台线程 + 立即返回。
 */
napi_value StartNode(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  napi_value result = nullptr;
  napi_create_object(env, &result);

  if (argc < 1) {
    FinishResult(env, result, false, "startNode 需要一个 options 对象");
    return result;
  }

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_started) {
      FinishResult(env, result, false,
                   "node 已经启动过。node::Start 每个进程只能调一次，"
                   "第二次会直接崩进程，所以这里拒绝执行。");
      return result;
    }
    if (g_ctx != nullptr) {
      FinishResult(env, result, false, "已有启动请求在处理中");
      return result;
    }
  }

  TW("[sn] S0 进入 StartNode（主线程）");
  std::string lib_path = GetStringProp(env, argv[0], "libPath");
  if (lib_path.empty()) {
    FinishResult(env, result, false, "缺少 libPath");
    return result;
  }
  TW(std::string("[sn] S1 libPath=") + lib_path);

  auto* ctx = new StartContext();
  ctx->lib_path = lib_path;
  TW("[sn] S2 ctx 已分配");

  napi_value env_obj = nullptr;
  if (napi_get_named_property(env, argv[0], "env", &env_obj) == napi_ok) {
    napi_valuetype t;
    if (napi_typeof(env, env_obj, &t) == napi_ok && t == napi_object) {
      ctx->env_pairs = GetEnvPairs(env, env_obj);
    }
  }
  TW(std::string("[sn] S3 env 解析 ") + std::to_string(ctx->env_pairs.size()) + " 项");

  ctx->arg_storage.emplace_back("node");
  napi_value args_arr = nullptr;
  if (napi_get_named_property(env, argv[0], "args", &args_arr) == napi_ok) {
    napi_valuetype t;
    if (napi_typeof(env, args_arr, &t) == napi_ok && t == napi_object) {
      uint32_t n = 0;
      napi_get_array_length(env, args_arr, &n);
      for (uint32_t i = 0; i < n; i++) {
        napi_value e = nullptr;
        napi_get_element(env, args_arr, i, &e);
        size_t elen = 0;
        napi_get_value_string_utf8(env, e, nullptr, 0, &elen);
        std::string es(elen, '\0');
        size_t c = 0;
        napi_get_value_string_utf8(env, e, es.data(), elen + 1, &c);
        es.resize(c);
        ctx->arg_storage.push_back(std::move(es));
      }
    }
  }
  // ⚠️ 绝不补 nullptr 哨兵；argc == argv.size()
  ctx->argv.reserve(ctx->arg_storage.size());
  for (auto& s : ctx->arg_storage) {
    ctx->argv.push_back(const_cast<char*>(s.c_str()));
  }

  ctx->stdout_path = GetStringProp(env, argv[0], "stdoutPath");

  // ⚠️ 关键：必须把 tracePath 赋给全局 g_trace_path，否则 TW() 看到空串直接 return，
  // 所有笔迹一行都不落盘（2026-10-28 追了两小时才发现丢的是这一行）。
  g_trace_path = GetStringProp(env, argv[0], "tracePath");
  TW(std::string("[sn] S4 tracePath=") + g_trace_path);

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_ctx = ctx;
  }

  pthread_t tid;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);
  int rc = pthread_create(&tid, &attr, NodeMain, ctx);
  pthread_attr_destroy(&attr);
  TW(std::string("[sn] S5 pthread_create rc=") + std::to_string(rc));
  if (rc != 0) {
    FinishResult(env, result, false,
                 "pthread_create 失败: " + std::to_string(rc));
    return result;
  }

  // 立即返回：加载与启动在后台线程，结果走 hilog/stdout 文件
  FinishResult(env, result, true, "", static_cast<int32_t>(ctx->argv.size()));
  return result;
}

// 自检（**仅命令行/测试场景**）：同步 dlopen —— 绝不能在 ArkTS 主线程调。
napi_value Probe(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  napi_value result = nullptr;
  napi_create_object(env, &result);

  if (argc < 1) {
    FinishResult(env, result, false, "probe 需要一个 libPath 字符串");
    return result;
  }

  size_t len = 0;
  napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
  std::string path(len, '\0');
  size_t copied = 0;
  napi_get_value_string_utf8(env, argv[0], path.data(), len + 1, &copied);
  path.resize(copied);

  napi_set_named_property(env, result, "path", MakeString(env, path));
  napi_set_named_property(env, result, "exists",
                          MakeBool(env, access(path.c_str(), R_OK) == 0));

  void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
  if (handle == nullptr) {
    FinishResult(env, result, false, dlerror() ? dlerror() : "未知");
    return result;
  }
  void* sym = dlsym(handle, kStartSymbol);
  FinishResult(env, result, sym != nullptr,
               sym != nullptr ? "" : (dlerror() ? dlerror() : "符号未导出"));
  napi_set_named_property(env, result, "hasStart", MakeBool(env, sym != nullptr));
  return result;
}

// 真机内存能力探针：回答「鸿蒙 seccomp 到底禁了什么」。
// 返回 JSON 字符串，逐项 mmap/mprotect 试，记录 errno。
napi_value ProbeMemory(napi_env env, napi_callback_info info) {
  std::string report;
  auto line = [&report](const char* name, bool ok, int err) {
    char buf[128];
    snprintf(buf, sizeof(buf), "%s=%s(errno=%d)\n", name, ok ? "OK" : "FAIL", err);
    report += buf;
  };

  // 1) mmap 可写可执行 (RWX)
  void* p1 = mmap(nullptr, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                  MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  line("mmap_RWX", p1 != MAP_FAILED, errno);
  if (p1 != MAP_FAILED) munmap(p1, 4096);

  // 2) mmap 只读可执行 (RX)
  void* p2 = mmap(nullptr, 4096, PROT_READ | PROT_EXEC,
                  MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  line("mmap_RX", p2 != MAP_FAILED, errno);
  if (p2 != MAP_FAILED) munmap(p2, 4096);

  // 3) mmap 读写 (RW) 再 mprotect 加 EXEC
  void* p3 = mmap(nullptr, 4096, PROT_READ | PROT_WRITE,
                  MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  if (p3 != MAP_FAILED) {
    int rc = mprotect(p3, 4096, PROT_READ | PROT_EXEC);
    line("mprotect_RW_to_RX", rc == 0, errno);
    munmap(p3, 4096);
  } else {
    line("mmap_RW", false, errno);
  }

  // 4) V8 崩溃点：mmap(PROT_NONE, MAP_FIXED) 重映射已分配的页
  void* p4 = mmap(nullptr, 4096, PROT_READ | PROT_WRITE,
                  MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  if (p4 != MAP_FAILED) {
    void* r4 = mmap(p4, 4096, PROT_NONE, MAP_FIXED | MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    line("mmap_PROT_NONE_FIXED", r4 != MAP_FAILED, errno);
    munmap(p4, 4096);
  } else {
    line("mmap_RW2", false, errno);
  }

  // 5) madvise DONTNEED（V8 decommit 的另一种路径）
  void* p5 = mmap(nullptr, 8192, PROT_READ | PROT_WRITE,
                  MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  if (p5 != MAP_FAILED) {
    int rc = madvise(p5, 8192, MADV_DONTNEED);
    line("madvise_DONTNEED", rc == 0, errno);
    munmap(p5, 8192);
  }

  napi_value result = nullptr;
  napi_create_string_utf8(env, report.c_str(), report.size(), &result);
  return result;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"startNode", nullptr, StartNode, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"probeMemory", nullptr, ProbeMemory, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "nodehost",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterNodeHost() {
  napi_module_register(&g_module);
  // constructor 里路径未知 —— TW 靠 startNode 传进来的 tracePath 生效
}
