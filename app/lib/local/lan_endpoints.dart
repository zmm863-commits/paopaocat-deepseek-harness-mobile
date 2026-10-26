import 'dart:io';

/// 一个「电脑可能连得过来」的本机地址。
///
/// 为什么需要单独一层（2026-10-26）：手机上有好几张网卡 —— 移动数据（rmnet）、
/// Wi-Fi（wlan）、USB 网络共享（rndis/usb/eth）、热点（ap/swlan）。DSH 的 web
/// 要求 `--host` 必须是**某一个具体网卡的地址**（wildcard 会被明确拒绝，见
/// `dsh --profile web --help`），所以 App 必须自己先把候选地址挑出来，不能让用户
/// 去猜一个 IP 填。
///
/// 移动数据那张虽然也有 IPv4，但外网回不来，必须排除；否则用户会选到一个
/// 「看着有地址、电脑永远连不上」的接口。
class LanEndpoint {
  const LanEndpoint({
    required this.interfaceName,
    required this.address,
    required this.kind,
  });

  /// 网卡名，例如 `rndis0`、`wlan0`。真机排查时要靠它认人。
  final String interfaceName;

  /// 点分 IPv4。
  final String address;

  /// `usb` / `wifi` / `other`。
  final String kind;

  String get label => switch (kind) {
        'usb' => 'USB 共享',
        'wifi' => 'Wi-Fi',
        _ => '其他网络',
      };

  /// 给用户看的完整描述：既说它是什么，也给出网卡名（真机对不上时看这里）。
  String get display => '$label · $address（$interfaceName）';

  @override
  String toString() => display;
}

/// 枚举本机可对外监听的地址。
class LanEndpoints {
  /// 按「电脑最可能连得上」的顺序返回：USB 共享 → Wi-Fi → 其他。
  ///
  /// 为什么 USB 排第一：这个功能的目标场景就是「一根线连到陌生电脑，电脑不装
  /// 任何东西」。Wi-Fi 同名次之（要连同一个网络），移动数据根本进不来。
  static Future<List<LanEndpoint>> list() async {
    final out = <LanEndpoint>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in ifaces) {
        final kind = _kindOf(iface.name);
        if (kind == null) continue; // 移动数据 / 回环 / 虚拟接口
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          if (addr.type != InternetAddressType.IPv4) continue;
          // 链路本地（169.254.x.x）是没拿到 DHCP 时的占位地址，电脑连不上。
          if (addr.address.startsWith('169.254.')) continue;
          out.add(LanEndpoint(
            interfaceName: iface.name,
            address: addr.address,
            kind: kind,
          ));
        }
      }
    } catch (_) {
      // 拿不到网卡列表（权限/平台差异）时返回空 —— 调用方据此显示「没找到地址」，
      // 不要抛异常把整个设置页带崩。
    }
    out.sort((a, b) => _rank(a.kind).compareTo(_rank(b.kind)));
    return out;
  }

  /// 最可能连得上的那个；一个都没有就是 null。
  static Future<LanEndpoint?> preferred() async {
    final all = await list();
    return all.isEmpty ? null : all.first;
  }

  static int _rank(String kind) => switch (kind) {
        'usb' => 0,
        'wifi' => 1,
        _ => 2,
      };

  /// 网卡名 → 类别。返回 null 表示「这张网卡不可能被电脑连到」。
  ///
  /// 分类依据是 Android 的常见命名：
  /// - `rndis0` / `usb0` / `eth0`：USB 网络共享（RNDIS/NCM/ECM），电脑插线后自动出现网卡。
  /// - `wlan0` / `ap0` / `swlan0`：Wi-Fi（station 或热点）。
  /// - `rmnet*` / `ccmni*` / `clat*`：蜂窝数据，外网进不来。
  static String? _kindOf(String name) {
    final n = name.toLowerCase();
    if (n == 'lo') return null;
    if (n.startsWith('rmnet') ||
        n.startsWith('ccmni') ||
        n.startsWith('clat') ||
        n.startsWith('dummy') ||
        n.startsWith('p2p') ||
        n.startsWith('tun') ||
        n.startsWith('tap') ||
        n.startsWith('v4-')) {
      return null;
    }
    if (n.startsWith('rndis') || n.startsWith('usb') || n.startsWith('eth')) {
      return 'usb';
    }
    if (n.startsWith('wlan') || n.startsWith('ap') || n.startsWith('swlan')) {
      return 'wifi';
    }
    return 'other';
  }
}
