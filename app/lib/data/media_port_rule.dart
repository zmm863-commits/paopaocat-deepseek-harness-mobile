// ignore_for_file: unused_element
//
// ⚠️ 这个文件**故意不 import 任何东西**（叶子文件）—— 别往里加 import。
//
// 为什么必须这样（用户 2026-10-12 排查「还有什么忘了修的」时发现的方向问题）：
// 规则现在要在**数据层**（`configured_models.dart` 读配置时）也生效；
// 而 `agnes_builtin.dart` 因为要用 `ConfiguredModels.envNameFor`
// **反过来 import 了 `configured_models.dart`**。规则要是继续留在
// `agnes_builtin.dart` 里，`configured_models` 一 import 它就成环。
// 所以把"值 + 判定"下沉到这里，`AgnesBuiltin` 改成**引用**这几个常量 ——
// 值仍然只有一份，不会两边漂。

/// 出厂内置的 Agnes 厂家 id。
const String kAgnesProviderId = 'agnes';

/// **已废弃的厂家 id** —— 它们的模型不再登记（读取老配置时会清掉）。
///
/// 为什么需要（2026-10-17）：`opencode`（OpenCode Zen 免费档）的模型普遍回
/// `403 {"type":"RegionError"...}` / 权限不足，用户实测"选取它依然不能使用"。
/// 卡片已按用户要求移除，但**老配置的 `models.json` 里还留着它那几十个模型，
/// 甚至 `selected` 就指向它** —— 那会让 ACP 建会话时内部失败，用户看到的是
/// 「会话没有建立起来」（真机日志：`session/new 失败：Internal error`）。
/// 所以读取时必须一并清掉模型与选中项，否则"删了卡片"根本救不回会话。
const Set<String> kRetiredProviderIds = <String>{'opencode'};

/// Agnes 官方列出的三个"免费"模型（文本 / 图像 / 视频）。
const String kAgnesTextModel = 'agnes-3.0-flash';
const String kAgnesImageModel = 'agnes-image-2.5-flash';
const String kAgnesVideoModel = 'agnes-video-2.5-flash';

/// `providerId` 名下的 `modelId` 是不是**媒体端口**模型。
///
/// Agnes 的图像 / 视频模型是**内置端口**：它们不走 `/chat/completions`，
/// 走的是 `/images/generations` 与 `/videos`。把它们的名字发给
/// `/chat/completions`，上游只会回一个 **400**。
bool isMediaPortModel(String providerId, String modelId) {
  if (providerId.trim().toLowerCase() != kAgnesProviderId) return false;
  final id = modelId.trim().toLowerCase();
  if (id == kAgnesImageModel || id == kAgnesVideoModel) return true;
  // 故意写得宽一点：官方以后换成 `agnes-image-3` 这种新名字也照样挡住，
  // 不会悄悄漏回来。
  return id.contains('image') || id.contains('video');
}

/// 同上，但吃的是 `provider/modelId` 这种 route（用于清掉指向媒体模型的选中项）。
bool isMediaPortRoute(String route) {
  final i = route.indexOf('/');
  if (i <= 0) return false;
  return isMediaPortModel(route.substring(0, i), route.substring(i + 1));
}
