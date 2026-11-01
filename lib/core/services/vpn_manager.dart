import 'dart:async';
import 'dart:io';

import 'package:astral/core/services/service_manager.dart';
import 'package:astral/shared/utils/network/ip_utils.dart';
import 'package:vpn_service_plugin/vpn_service_plugin.dart';
import 'package:astral/src/rust/api/simple.dart';

/// VPN 管理器（仅 Android）
class VpnManager {
  static VpnManager? _instance;
  final VpnServicePlugin? _plugin;
  StreamSubscription<dynamic>? _vpnStartedSub;
  bool _androidHooksInitialized = false;

  VpnManager._() : _plugin = Platform.isAndroid ? VpnServicePlugin() : null;

  /// 获取单例实例
  static VpnManager get instance {
    _instance ??= VpnManager._();
    return _instance!;
  }

  /// 获取 VPN 插件实例
  VpnServicePlugin? get plugin => _plugin;

  /// Android 通知 + VPN TUN fd 监听（应用级一次初始化）
  Future<void> initAndroidHooks() async {
    if (!Platform.isAndroid || _androidHooksInitialized) return;
    _androidHooksInitialized = true;

    final services = ServiceManager();
    await services.notifications.initialize();

    await _vpnStartedSub?.cancel();
    _vpnStartedSub = _plugin?.onVpnServiceStarted.listen((data) {
      if (services.networkConfigState.noTun.value) return;
      final fd = data['fd'];
      if (fd is int) {
        configureTunFd(fd);
      }
    });
  }

  /// 准备 VPN 服务（请求权限）
  Future<void> prepare() async {
    final plugin = _plugin;
    if (plugin == null) return;
    await plugin.prepareVpn();
  }

  /// 启动 VPN 服务
  Future<void> start({
    required String ipv4Addr,
    int mtu = 1300,
    List<String> disallowedApplications = const ['com.kevin.astral'],
    List<String> proxyCidrs = const [],
  }) async {
    final plugin = _plugin;
    if (plugin == null) return;
    if (ipv4Addr.isEmpty) return;

    String finalIpv4 = ipv4Addr;
    if (!ipv4Addr.contains('/')) {
      finalIpv4 = '$ipv4Addr/24';
    }

    final customRoutes =
        ServiceManager().vpnState.customVpn.value
            .where((route) => isValidCIDR(route))
            .toList();

    final routes = [
      ...customRoutes,
      ...proxyCidrs.where((route) => isValidCIDR(route)),
    ];

    await plugin.startVpn(
      ipv4Addr: finalIpv4,
      mtu: mtu,
      routes: routes,
      disallowedApplications: disallowedApplications,
      notificationsEnabled: ServiceManager()
          .appSettingsState
          .enableConnectionNotification
          .value,
    );
  }

  /// 停止 VPN 服务
  Future<void> stop() async {
    final plugin = _plugin;
    if (plugin == null) return;
    await plugin.stopVpn();
  }

  /// 启动连接保活前台服务
  ///
  /// 连接通知不再由 Dart 侧 flutter_local_notifications 发出，而是由原生前台服务持有：
  /// 进程被 kill -9 / 系统回收时 Dart 无法执行取消代码，而 Android 只会清理前台服务
  /// 持有的通知，普通 ongoing 通知会永久残留（issue #263）。
  Future<void> startKeepAlive({
    required String status,
    required String ip,
    required String duration,
    bool showContent = true,
  }) async {
    final plugin = _plugin;
    if (plugin == null) return;
    await plugin.startKeepAlive(
      status: status,
      ip: ip,
      duration: duration,
      showContent: showContent,
    );
  }

  /// 停止连接保活前台服务（同时移除系统前台通知）
  Future<void> stopKeepAlive() async {
    final plugin = _plugin;
    if (plugin == null) return;
    await plugin.stopKeepAlive();
  }

  /// 更新连接通知内容（IP / 时长）
  Future<void> updateNotification({
    required String status,
    required String ip,
    required String duration,
  }) async {
    final plugin = _plugin;
    if (plugin == null) return;
    await plugin.updateNotification(
      status: status,
      ip: ip,
      duration: duration,
    );
  }

  /// 隐藏连接通知内容（前台服务仍必须保留一条最小通知）
  Future<void> hideNotification() async {
    final plugin = _plugin;
    if (plugin == null) return;
    await plugin.hideNotification();
  }

  /// 重新展示连接通知内容
  Future<void> showNotification({
    required String status,
    required String ip,
    required String duration,
  }) async {
    final plugin = _plugin;
    if (plugin == null) return;
    await plugin.showNotification(
      status: status,
      ip: ip,
      duration: duration,
    );
  }

  /// 将 TUN fd 传递给 Rust 层
  Future<void> configureTunFd(int fd) async {
    await setTunFd(fd: fd);
  }
}
