/// 对外地址的**唯一出处**。
///
/// ## 为什么单独抽一个函数（2026-10-30 真机踩出来的）
///
/// 面板里有**两个地方**会算出「给用户的地址」：
///   1. `_apply()` —— 用户拨开开关时；
///   2. `_load()` —— 离开页面再进来、或 App 重启后恢复显示时。
///
/// 0.81 只在第 1 处改成了「用 App 的固定口令」，第 2 处仍然用 DSH 自带的
/// launchToken —— 于是用户复制到的是一个**每次重启就失效**的地址，
/// 电脑上打开报 `dsh web authentication required`（用户实测抓到的就是这个）。
///
/// 两处各写一遍必然会再分叉，所以收敛到这里；token 该用哪一把也写死在这里。
library;

/// 拼出给用户/电脑用的 DSH 地址。
///
/// [token] **必须是 App 自己的固定口令**（`BridgePrefs.token`，32 位十六进制），
/// 不能是 DSH 的 launchToken —— 后者由 `processLaunchToken()` 每次进程启动随机
/// 生成、没有注入口子，转发层负责在第一个请求里把它换掉（见 `ForwardRewrite`）。
String publicDshUrl({
  required String host,
  required int port,
  required String token,
}) {
  final t = token.trim();
  // token 一定非空（BridgePrefs 首次加载就会生成）；真为空时也不拼出个半截地址，
  // 让调用方看到明显的异常而不是一个静默 401 的链接。
  if (t.isEmpty) return 'http://$host:$port/';
  return 'http://$host:$port/?token=$t';
}
