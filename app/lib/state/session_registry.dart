import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/artifacts.dart';
import '../local/acp_client.dart';
import '../ui/widgets/message_stream.dart' show ChatMsg;

/// 一个**正在运行的会话**：进程 + 消息 + 产物 + 状态，全部由壳层持有。
///
/// 用户意见①的"多会话并发 / 切页不打断"就是靠它实现的：
/// 会话页只是"借用"这个对象来渲染；页面被 pop 掉时**只 detach、不杀进程**，
/// 正在生成的回答继续跑，页面回来时再把攒下的通知回放给它。
class LiveSession extends ChangeNotifier {
  LiveSession({
    required this.key,
    required this.acp,
    required this.workspace,
    this.title,
  });

  /// 稳定标识。用「工作区 + 恢复 id」或「工作区 + 新建时刻」拼出来，
  /// 让"同一个会话"在页面来回进出时能命中同一份状态。
  final String key;

  final AcpClient acp;

  /// 这个会话的工作目录。
  final String workspace;

  /// 展示名（可能来自用户改的名字或首条消息）。
  String? title;

  /// ACP 侧的 sessionId（new / resume 之后才知道）。
  String? sessionId;

  /// 是否正在跑一轮回答（首页据此显示"进行中"）。
  ///
  /// ⚠️ 2026-10-20 真机 bug：它原来是**裸字段** —— 谁改它都不会通知任何人。
  /// 于是"离开页面再回来"时，新页面在 `_adoptLive` 里抄一次 `live.running` 就再也不更新；
  /// 而把这一轮跑完的是**旧页面**（它只清了自己的 `_running` + 这里的字段），
  /// 新页面就一直卡在「正在处理…」（用户原话：「文件已经生成了，但依然是正在处理」）。
  /// 现在改成 setter：值真的变了就 notifyListeners → 页面与首页都跟得上。
  bool get running => _running;
  set running(bool v) {
    if (_running == v) return;
    _running = v;
    notifyListeners();
  }

  bool _running = false;

  /// 当前这一轮是**什么时候开始的**（审计 P1-1）。
  ///
  /// 为什么放在句柄上而不是页面里：切页不打断回答（见 [attached]），
  /// 页面重建/切回来时必须能接着显示「已等 M:SS」，归零或消失都会误导用户
  /// —— 那个"我到底等了多久"正是这条要解决的问题。
  DateTime? get turnStartedAt => _turnStartedAt;
  set turnStartedAt(DateTime? v) {
    if (_turnStartedAt == v) return;
    _turnStartedAt = v;
    notifyListeners();
  }

  DateTime? _turnStartedAt;

  /// 页面是否挂在上面。
  bool attached = false;

  /// 创建时刻 / 最后一次有动静的时刻（首页排序与显示用）。
  final DateTime createdAt = DateTime.now();
  DateTime lastActiveAt = DateTime.now();

  /// 消息与产物 —— **放在这里而不是页面里**，这样切页回来不丢。
  final List<ChatMsg> messages = <ChatMsg>[];
  final List<Artifact> artifacts = <Artifact>[];
  final Set<String> artifactKeys = <String>{};

  /// 还没被回答的权限请求（页面不在时也要留着，回来能补答）。
  final List<AcpPermissionRequest> pendingPermissions =
      <AcpPermissionRequest>[];

  /// 页面不在时攒下的通知（有上限，防止长会话把内存吃穿）。
  final List<Map<String, dynamic>> _backlog = <Map<String, dynamic>>[];
  static const int _backlogCap = 4000;

  void Function(Map<String, dynamic> notification)? _onNotification;
  void Function(AcpPermissionRequest request)? _onPermission;
  StreamSubscription<Map<String, dynamic>>? _notificationSub;
  StreamSubscription<AcpPermissionRequest>? _permissionSub;

  /// 进程初始化用的配置指纹（配置变了要重建进程，判断在页面侧）。
  String? spawnConfigKey;

  /// 起这个进程时"**当前选中那条路由自己的管路**"（见 `state/spawn_signature.dart`）。
  ///
  /// 页面重建/切页回来时要读回它：切模型的判据是这份（不是整份配置），
  /// 丢了它就只能退回"整份配置变了就重建"的老口径 —— 用户改别的厂家时
  /// 会把正在聊的会话重启一遍（用户 2026-10-15 第 1 条要修的就是这个）。
  String? spawnRoutePlumbing;

  /// 运行时实际生效的模型 route。
  String? liveRoute;

  /// 页面挂上来：把**它不在期间攒下的**通知先回放，再接实时。
  void attach({
    required void Function(Map<String, dynamic> notification) onNotification,
    required void Function(AcpPermissionRequest request) onPermission,
  }) {
    _onNotification = onNotification;
    _onPermission = onPermission;
    attached = true;
    _ensureListening();

    final replay = List<Map<String, dynamic>>.from(_backlog);
    _backlog.clear();
    for (final n in replay) {
      onNotification(n);
    }
    for (final p in List<AcpPermissionRequest>.from(pendingPermissions)) {
      onPermission(p);
    }
    // 已经交回给页面了 —— 由它负责答复。留在列表里会导致下次回来重复弹。
    pendingPermissions.clear();
    debugPrint('[dsh-live] attach ${_short(key)}（回放 ${replay.length} 条）');
  }

  /// 页面走了：**只解除绑定**，进程继续跑（这正是"切页不打断"的关键）。
  void detach() {
    if (!attached) return;
    _onNotification = null;
    _onPermission = null;
    attached = false;
    debugPrint('[dsh-live] detach ${_short(key)}（进程保留，回答继续）');
    notifyListeners();
  }

  void _ensureListening() {
    if (_notificationSub != null) return;
    _notificationSub = acp.notifications.listen((n) {
      lastActiveAt = DateTime.now();
      final cb = _onNotification;
      if (cb != null) {
        cb(n);
      } else {
        _backlog.add(n);
        if (_backlog.length > _backlogCap) _backlog.removeAt(0);
      }
      notifyListeners();
    });
    _permissionSub = acp.permissionRequests.listen((p) {
      lastActiveAt = DateTime.now();
      final cb = _onPermission;
      if (cb != null) {
        cb(p); // 页面在，直接交给它弹审批框
      } else {
        // 人不在：先留存，回来 attach 时补弹。
        // （不存的话这个请求会一直挂着 —— DSH 侧等不到决定不会继续，
        //   默认 120s 超时就自动拒绝了。）
        pendingPermissions.add(p);
        debugPrint(
            '[dsh-live] 页面不在，暂存一个权限请求（现有 ${pendingPermissions.length} 个）');
      }
      notifyListeners();
    });
  }

  /// 这个权限请求被答复了（从待答列表里摘掉）。
  void resolvePermission(AcpPermissionRequest p) {
    pendingPermissions.removeWhere((x) => identical(x, p) || x.id == p.id);
  }

  /// 用户显式关闭这个会话 —— **只有这里**才会真的杀进程。
  Future<void> close() async {
    _onNotification = null;
    _onPermission = null;
    attached = false;
    await _notificationSub?.cancel();
    await _permissionSub?.cancel();
    _notificationSub = null;
    _permissionSub = null;
    try {
      await acp.close();
    } catch (e) {
      debugPrint('[dsh-live] 关闭进程失败：$e');
    }
    dispose();
  }

  static String _short(String s) => s.length <= 12 ? s : s.substring(0, 12);
}

/// 会话注册表：**壳层持有**，负责所有会话进程的生老病死。
///
/// 为什么必须有它：`AcpClient` 原先由 `ChatPage` 的 State 持有、在 `dispose()`
/// 里 `close()`；而会话页是 `Navigator.push` 出来的全屏路由，用户点底部别的
/// Tab 就会 pop → dispose → 进程在 300ms 后被杀，**正在生成的回答被当场打断**。
/// 把所有权上移到壳层之后，会话页的生死与进程的生死就解耦了。
class SessionRegistry extends ChangeNotifier {
  final Map<String, LiveSession> _sessions = <String, LiveSession>{};

  /// 全部活着的会话（新→旧）。
  List<LiveSession> get all {
    final list = _sessions.values.toList();
    list.sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
    return list;
  }

  /// 正在跑回答的那些（首页用）。
  List<LiveSession> get runningOnes => all.where((s) => s.running).toList();

  LiveSession? byKey(String key) => _sessions[key];

  /// 找一个**已经在跑**的会话：同一个工作区，且恢复 id 对得上。
  ///
  /// 命中就复用（页面重进时不再起新进程，也不会打断正在跑的回答）。
  LiveSession? findReusable({required String workspace, String? resumeId}) {
    for (final s in _sessions.values) {
      if (s.workspace != workspace) continue;
      if (resumeId != null && resumeId.isNotEmpty) {
        if (s.sessionId == resumeId) return s;
      } else if (s.sessionId == null) {
        // 还没拿到 sessionId 的"刚起步"会话，也算可复用
        return s;
      }
    }
    return null;
  }

  void register(LiveSession s) {
    _sessions[s.key] = s;
    // 把句柄自身的状态变化（例如"这轮跑完了"）转发出去 ——
    // 首页那条「正在回答」提示要跟着动。
    s.addListener(notifyListeners);
    debugPrint('[dsh-live] 注册会话 ${s.key}（现存 ${_sessions.length} 个）');
    notifyListeners();
  }

  /// 用户显式关闭某个会话。
  Future<void> close(String key) async {
    final s = _sessions.remove(key);
    if (s == null) return;
    s.removeListener(notifyListeners);
    await s.close();
    debugPrint('[dsh-live] 已关闭 ${s.key}（剩 ${_sessions.length} 个）');
    notifyListeners();
  }

  /// 关掉一个 LiveSession 对象（按对象找 key）。
  Future<void> closeSession(LiveSession s) => close(s.key);

  /// App 退出/重启运行时：全部收尸。
  Future<void> closeAll() async {
    final list = _sessions.values.toList();
    _sessions.clear();
    for (final s in list) {
      s.removeListener(notifyListeners);
      await s.close();
    }
    notifyListeners();
  }
}
