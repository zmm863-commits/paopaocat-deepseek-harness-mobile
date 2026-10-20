import 'android_toolbox.dart';
import 'dsh_runtime.dart';

/// 会话里的**本地 MCP 服务器** —— 我们自己实现的那个（`toolbox/mcp-office.mjs`）。
///
/// ## 它解决什么
///
/// WorkBuddy 靠本地 183MB 的文档引擎起一个 MCP 服务，把「改文档」变成工具调用
/// （302 个工具）。我们没有那个引擎，但 OOXML 的本质是 ZIP + XML，
/// `toolbox/office-zip.mjs` 已经是现成的 zip 读写库 —— 于是先用三个工具
/// （读单元格 / 写单元格 / 追加段落）把这条路打通。
///
/// ## 挂载方式：stdio（不是 http）
///
/// DSH 运行时的 `dsh-acp` 用 `resolveMcpConfigs()` 解析会话里的 `mcpServers`：
///   * **不带 `type` 字段** → 按 **stdio** 处理，由运行时自己 spawn 这个进程；
///   * `type: 'http'` → streamable-http，要我们自己另外起一个 HTTP 服务。
///
/// 选 stdio 的理由：
///   * 生命周期由运行时管（会话结束就关），我们不用管端口、也不用管僵尸进程；
///   * `command` 用手机里**唯一可执行**的 node（`<nativeLibraryDir>/libnode.so`）——
///     App 数据目录里的文件在 Android 上**不允许被执行**（实测 EACCES），
///     所以 `command` 必须是 nativeLibraryDir 里的那个，脚本本身只是被 node **读**。
///
/// ## ⚠️ 三条不能写错的约束
///
/// 1. `command` 必须是**绝对路径**（`resolveMcpConfigs` 会直接拒掉相对的）。
/// 2. `env` 是**有序的 name/value 条目数组**，不是普通 map（`entriesToRecord()` 会拒重复键）。
/// 3. `failOnStartupError: true` —— **这个服务起不来会连累整个会话**。
///    所以挂之前必须确认：运行时就绪、脚本已落盘、`command` 真的能执行。
///
/// ## 安全边界：只给最小 env，**绝不带 API Key**
///
/// 运行时的 `environment` 里含 `DEEPSEEK_API_KEY` / `COM_API_KEY` / `AGNES_API_KEY` /
/// `ROTATE_API_KEY`（见 `dsh_runtime.dart`）。MCP 服务器是**模型可调用的工具面**，
/// 它的进程环境不该带用户凭据 —— 这与"审计 P0-2：Key 不进模型驱动的 shell"是同一条边界。
/// 所以这里用白名单重建 env，只保留跑 node 与读文件真正需要的那些。
class LocalMcp {
  LocalMcp._();

  /// 服务器名（会变成模型看到的工具命名空间前缀）。
  static const String serverName = 'dsh-office';

  /// 脚本在私有目录里的落盘位置（由 [AndroidToolbox.ensureInstalled] 复制过去）。
  static String scriptPath(String filesDir) => '$filesDir/toolbox/mcp-office.mjs';

  /// 给 ACP `session/new` / `session/resume` 用的 `mcpServers` 条目（stdio）。
  ///
  /// 返回空列表表示**这次不挂**（运行时没就绪 / 脚本没落盘）—— 此时会话照常开，
  /// 只是模型没有这三个工具。**绝不能因为挂不上就让会话开不起来。**
  static List<Map<String, dynamic>> mcpServers({required DshRuntime runtime}) {
    final node = runtime.nodeBinary;
    final script = scriptPath(runtime.filesDir);
    if (node.isEmpty || script.isEmpty) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      {
        'name': serverName,
        // 绝对路径：<nativeLibraryDir>/libnode.so（Android 上唯一能执行的东西）
        'command': node,
        'args': <String>[script],
        // 白名单环境：**不含任何 API Key**（理由见类注释）
        'env': _envEntries(runtime),
      },
    ];
  }

  /// 最小 env（有序条目）。键名沿用 `DshRuntime.environment` 的那一套，
  /// 但**只取与"跑 node + 读写文件"有关的那几项**。
  static List<Map<String, String>> _envEntries(DshRuntime runtime) {
    // ⚠️ 写法注意：列表元素直接用 `{...}` 字面量（靠列表的类型实参推断成 Map）。
    // 写成 `<Map<String,String>>{...}` 会被解析成**集合**字面量，
    // 写成 `Map<String,String>{...}` 又会被报 "A map literal can't be prefixed by 'Map'"。
    final entries = <Map<String, String>>[
      {'name': 'LD_LIBRARY_PATH', 'value': runtime.nativeLibDir},
      {'name': 'HOME', 'value': runtime.filesDir},
      {'name': 'PATH', 'value': '/system/bin:/system/xbin'},
      {'name': 'TMPDIR', 'value': '${runtime.filesDir}/tmp'},
      {'name': 'DSH_HOME', 'value': runtime.nodeHome},
      {'name': 'DSH_ANDROID_NODE_BIN', 'value': runtime.nodeBinary},
      {'name': 'DSH_ANDROID_TOOLBOX', 'value': runtime.toolboxDir},
      {'name': 'DSH_ANDROID_TMPDIR', 'value': '${runtime.filesDir}/tmp'},
    ];
    return entries;
  }
}
