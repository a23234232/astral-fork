import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'vpn_service_plugin_method_channel.dart';

abstract class VpnServicePluginPlatform extends PlatformInterface {
  VpnServicePluginPlatform() : super(token: _token);

  static final Object _token = Object();
  static VpnServicePluginPlatform _instance = MethodChannelVpnServicePlugin();

  static VpnServicePluginPlatform get instance => _instance;

  static set instance(VpnServicePluginPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<Map<String, dynamic>> prepareVpn() {
    throw UnimplementedError('prepareVpn() 未实现.');
  }

  Future<Map<String, dynamic>> startVpn({
    String? ipv4Addr,
    List<String>? routes,
    String? dns,
    List<String>? disallowedApplications,
    int? mtu,
    bool notificationsEnabled = true,
  }) {
    throw UnimplementedError('startVpn() 未实现.');
  }

  Future<void> stopVpn() {
    throw UnimplementedError('stopVpn() 未实现.');
  }

  /// 启动连接保活前台服务（连接通知由它持有，进程被杀时通知随服务被系统清理）
  Future<void> startKeepAlive({
    required String status,
    required String ip,
    required String duration,
    bool showContent = true,
  }) {
    throw UnimplementedError('startKeepAlive() 未实现.');
  }

  /// 停止连接保活前台服务（同时移除前台通知）
  Future<void> stopKeepAlive() {
    throw UnimplementedError('stopKeepAlive() 未实现.');
  }

  /// 更新连接通知内容（IP / 时长）
  Future<void> updateNotification({
    required String status,
    required String ip,
    required String duration,
  }) {
    throw UnimplementedError('updateNotification() 未实现.');
  }

  /// 隐藏连接通知内容（前台服务仍必须保留一条最小通知）
  Future<void> hideNotification() {
    throw UnimplementedError('hideNotification() 未实现.');
  }

  /// 重新展示连接通知内容
  Future<void> showNotification({
    required String status,
    required String ip,
    required String duration,
  }) {
    throw UnimplementedError('showNotification() 未实现.');
  }
}
