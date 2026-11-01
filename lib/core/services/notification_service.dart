import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:astral/core/services/service_manager.dart';

/// 连接状态通知服务（仅Android）
///
/// Android 上连接通知由原生保活前台服务（vpn_service_plugin 的
/// AstralKeepAliveService）持有，不再由 flutter_local_notifications 发普通通知：
/// 进程被 kill -9 / 系统回收时 Dart 无法执行任何取消代码，而 Android 只会清理
/// 前台服务持有的通知，普通 ongoing 通知会永久残留（issue #263）。
///
/// TUN 与 NO-TUN 模式都走原生托管——保活服务不依赖 VpnService 的 TUN fd 权限。
/// #264 只在 TUN 模式托管、NO-TUN 仍用普通通知，导致该分支下通知照旧残留，
/// 本实现对此做了补齐。
class NotificationService {
  static NotificationService? _instance;
  final FlutterLocalNotificationsPlugin? _plugin;
  static const int _connectionNotificationId = 1001;

  NotificationService._()
    : _plugin = Platform.isAndroid ? FlutterLocalNotificationsPlugin() : null;

  /// 获取单例实例
  static NotificationService get instance {
    _instance ??= NotificationService._();
    return _instance!;
  }

  /// 连接通知是否由原生保活前台服务托管（Android 且插件可用）
  bool get _nativeManaged =>
      Platform.isAndroid && ServiceManager().vpn.plugin != null;

  /// 初始化通知服务
  Future<void> initialize() async {
    final plugin = _plugin;
    if (plugin == null) return;

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
    );

    await plugin.initialize(settings);
  }

  /// 显示或更新连接状态通知
  ///
  /// [status] 连接状态文本（如"连接中"、"已连接"）
  /// [ip] IP地址
  /// [duration] 连接时长
  Future<void> showConnectionNotification({
    required String status,
    required String ip,
    required String duration,
  }) async {
    if (!Platform.isAndroid) return;

    // 原生托管：通知内容直接写进前台服务通知，进程被杀时随服务一起被系统清理
    if (_nativeManaged) {
      final nativePlugin = ServiceManager().vpn.plugin;
      if (nativePlugin == null) return;

      if (!ServiceManager()
          .appSettingsState
          .enableConnectionNotification
          .value) {
        // 用户关闭了「连接通知」：Android 不允许前台服务没有通知，
        // 因此只能退化成一条最小通知（不展示状态 / IP / 时长）
        await nativePlugin.hideNotification();
        return;
      }

      await nativePlugin.updateNotification(
        status: status,
        ip: ip,
        duration: duration,
      );
      return;
    }

    // 保底：原生插件不可用时仍走旧的 Dart 普通通知逻辑
    await _showFlutterNotification(
      status: status,
      ip: ip,
      duration: duration,
    );
  }

  /// 用 flutter_local_notifications 发普通通知（仅作原生不可用时的保底）
  Future<void> _showFlutterNotification({
    required String status,
    required String ip,
    required String duration,
  }) async {
    final plugin = _plugin;
    if (plugin == null) return;
    if (!ServiceManager().appSettingsState.enableConnectionNotification.value) {
      await cancelConnectionNotification();
      return;
    }

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'astral_connection',
          'Astral 连接状态',
          channelDescription: '显示 Astral 连接状态和信息',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          showWhen: false,
          icon: '@mipmap/ic_launcher',
        );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );

    await plugin.show(
      _connectionNotificationId,
      'Astral - $status',
      'IP: $ip | 连接时间: $duration',
      details,
    );
  }

  /// 取消连接状态通知
  Future<void> cancelConnectionNotification() async {
    if (!Platform.isAndroid) return;

    // 原生托管：前台通知由保活服务持有，停止服务时由系统一并移除。
    // 正常断开时 disconnect() 已显式 stopKeepAlive，这里再停一次作兜底。
    if (_nativeManaged) {
      await ServiceManager().vpn.stopKeepAlive();
      return;
    }

    final plugin = _plugin;
    if (plugin == null) return;
    await plugin.cancel(_connectionNotificationId);
  }

  /// 格式化连接时长
  ///
  /// 将秒数转换为 HH:MM:SS 或 MM:SS 格式
  static String formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
  }
}
