import 'package:astral/core/services/service_manager.dart';
import 'dart:io';

import 'package:astral/core/services/connection_network_monitor.dart';
import 'package:astral/core/states/connection_state.dart';
import 'package:astral/core/states/player_state.dart';
import 'package:astral/core/states/display_state.dart';
import 'package:astral/core/states/startup_state.dart';
import 'package:astral/core/states/update_state.dart';
import 'package:astral/core/states/window_state.dart';
import 'package:astral/core/states/vpn_state.dart';
import 'package:astral/core/states/app_settings_state.dart';
import 'package:astral/core/repositories/app_settings_repository.dart';
import 'package:astral/core/database/dao/all_settings_dao.dart';
import 'package:astral/core/models/all_settings.dart';
import 'package:astral/shared/utils/github_proxy_selector.dart';
import 'package:astral/core/platform/startup_url_scheme.dart';

/// 应用设置服务：协调 State 与持久化
class AppSettingsService {
  final PlayerState playerState;
  final DisplayState displayState;
  final StartupState startupState;
  final UpdateState updateState;
  final WindowState windowState;
  final VpnState vpnState;
  final AppSettingsState appSettingsState;
  final AppSettingsRepository _repo;

  AppSettingsService({
    required this.playerState,
    required this.displayState,
    required this.startupState,
    required this.updateState,
    required this.windowState,
    required this.vpnState,
    required this.appSettingsState,
    required AppSettingsRepository repository,
  }) : _repo = repository;

  Future<void> init() async {
    final settings = await _repo.get();
    final listenList = await _repo.getListenList();
    final playerName = await _repo.getPlayerName();

    playerState.updatePlayerName(playerName);
    playerState.setListenList(listenList);

    final listStyle = _resolveUserListStyle(settings);
    displayState.setUserListStyle(listStyle);
    if (settings.userListStyle != listStyle.index) {
      await _repo.update((s) {
        s.userListStyle = listStyle.index;
        s.userListSimple = listStyle == UserListStyle.simple;
      });
    }
    displayState.setSortOption(UserSortOption.fromIndex(settings.sortOption));
    displayState.setSortOrder(UserSortOrder.fromIndex(settings.sortOrder));
    displayState.setDisplayMode(UserDisplayMode.fromIndex(settings.displayMode));

    startupState.updateAll(
      startup: settings.startup,
      startupMinimize: settings.startupMinimize,
      startupAutoConnect: settings.startupAutoConnect,
    );

    updateState.setBeta(settings.beta);
    updateState.setAutoCheckUpdate(settings.autoCheckUpdate);

    var downloadAccelerate = settings.downloadAccelerate;
    if (downloadAccelerate == 'https://gh.xmly.dev/') {
      downloadAccelerate = GitHubProxySelector.autoMode;
      await _repo.update((s) => s.downloadAccelerate = downloadAccelerate);
    }
    updateState.setDownloadAccelerate(downloadAccelerate);
    updateState.setLatestVersion(settings.latestVersion);

    appSettingsState.updateEnableConnectionNotification(
      settings.enableConnectionNotification,
    );
    appSettingsState.updateReduceAnimationUpdates(
      settings.reduceAnimationUpdates,
    );
    appSettingsState.updateAutoRetryOnFailure(settings.autoRetryOnFailure);
    appSettingsState.updateMaxRetryCount(settings.maxRetryCount);

    windowState.setCloseMinimize(settings.closeMinimize);
    vpnState.setCustomVpn(List<String>.from(settings.customVpn));
  }

  Future<void> updatePlayerName(String name) async {
    playerState.updatePlayerName(name);
    await _repo.update((s) => s.playerName = name);
  }

  Future<void> setListenList(List<String> list) async {
    playerState.setListenList(list);
    await _repo.update((s) => s.listenList = list);
  }

  Future<void> addListen(String listen) async {
    playerState.addListen(listen);
    await _repo.update((s) => s.listenList = playerState.listenList.value);
  }

  Future<void> deleteListen(int index) async {
    playerState.removeListen(index);
    await _repo.update((s) => s.listenList = playerState.listenList.value);
  }

  Future<void> updateListen(int index, String listen) async {
    await _repo.update((s) {
      s.listenList ??= List<String>.from(AllSettingsDao.defaultListenList);
      s.listenList![index] = listen;
    });
    playerState.setListenList(await _repo.getListenList());
  }

  UserListStyle _resolveUserListStyle(AllSettings settings) {
    if (settings.userListStyle >= 0 &&
        settings.userListStyle < UserListStyle.values.length) {
      return UserListStyle.fromIndex(settings.userListStyle);
    }
    return settings.userListSimple
        ? UserListStyle.simple
        : UserListStyle.detailed;
  }

  Future<void> setUserListStyle(UserListStyle style) async {
    displayState.setUserListStyle(style);
    await _repo.update((s) {
      s.userListStyle = style.index;
      s.userListSimple = style == UserListStyle.simple;
    });
  }

  Future<void> setUserListSimple(bool value) async {
    await setUserListStyle(
      value ? UserListStyle.simple : UserListStyle.detailed,
    );
  }

  Future<void> setSortOption(UserSortOption option) async {
    displayState.setSortOption(option);
    await _repo.update((s) => s.sortOption = option.index);
  }

  Future<void> setSortOrder(UserSortOrder order) async {
    displayState.setSortOrder(order);
    await _repo.update((s) => s.sortOrder = order.index);
  }

  Future<void> setDisplayMode(UserDisplayMode mode) async {
    displayState.setDisplayMode(mode);
    await _repo.update((s) => s.displayMode = mode.index);
  }

  Future<void> setStartup(bool value) async {
    startupState.setStartup(value);
    await _repo.update((s) => s.startup = value);
    await handleStartupSetting(value);
  }

  Future<void> setStartupMinimize(bool value) async {
    startupState.setStartupMinimize(value);
    await _repo.update((s) => s.startupMinimize = value);
  }

  Future<void> setStartupAutoConnect(bool value) async {
    startupState.setStartupAutoConnect(value);
    await _repo.update((s) => s.startupAutoConnect = value);
  }

  Future<void> setBeta(bool value) async {
    updateState.setBeta(value);
    await _repo.update((s) => s.beta = value);
  }

  Future<void> setAutoCheckUpdate(bool value) async {
    updateState.setAutoCheckUpdate(value);
    await _repo.update((s) => s.autoCheckUpdate = value);
  }

  Future<void> setDownloadAccelerate(String value) async {
    updateState.setDownloadAccelerate(value);
    await _repo.update((s) => s.downloadAccelerate = value);
  }

  Future<void> updateLatestVersion(String version) async {
    updateState.setLatestVersion(version);
    await _repo.update((s) => s.latestVersion = version);
  }

  Future<void> updateEnableConnectionNotification(bool enable) async {
    appSettingsState.updateEnableConnectionNotification(enable);
    await _repo.update((s) => s.enableConnectionNotification = enable);

    if (!Platform.isAndroid) return;

    // Android：连接通知由原生保活前台服务持有（TUN / NO-TUN 一致），
    // 开关切换直接改原生通知内容，不再走普通通知，避免进程被杀后残留（issue #263）。
    if (!enable) {
      // 关闭连接通知：Android 不允许前台服务没有通知，因此仍会保留一条
      // 不含状态 / IP / 时长的最小通知；该通知会随服务在进程结束时被系统清理。
      await ServiceManager().vpn.hideNotification();
      return;
    }

    // 重新打开：连接中/已连接时立即恢复完整内容；
    // 未连接时保活服务未运行，调用安全地无操作，下次连接会带内容启动。
    // 时长在下一次网络监控轮询（约 1 秒）时刷新。
    final state = ServiceManager().connectionState.connectionState.value;
    if (state == CoState.connecting) {
      await ServiceManager().vpn.showNotification(
        status: '连接中',
        ip: '正在获取...',
        duration: '00:00',
      );
    } else if (state == CoState.connected) {
      await ServiceManager().vpn.showNotification(
        status: '已连接',
        ip: ConnectionNetworkMonitor.notificationDisplayIp(),
        duration: '00:00',
      );
    }
  }

  Future<void> updateReduceAnimationUpdates(bool enable) async {
    appSettingsState.updateReduceAnimationUpdates(enable);
    await _repo.update((s) => s.reduceAnimationUpdates = enable);
  }

  Future<void> updateAutoRetryOnFailure(bool enable) async {
    appSettingsState.updateAutoRetryOnFailure(enable);
    await _repo.update((s) => s.autoRetryOnFailure = enable);
  }

  Future<void> updateMaxRetryCount(int count) async {
    appSettingsState.updateMaxRetryCount(count);
    await _repo.update((s) => s.maxRetryCount = count);
  }

  Future<void> updateCloseMinimize(bool value) async {
    windowState.setCloseMinimize(value);
    await _repo.update((s) => s.closeMinimize = value);
  }

  Future<void> addCustomVpn(String value) async {
    vpnState.addCustomVpn(value);
    await _repo.update((s) => s.customVpn = vpnState.customVpn.value);
  }

  Future<void> deleteCustomVpn(int index) async {
    vpnState.removeCustomVpn(index);
    await _repo.update((s) => s.customVpn = vpnState.customVpn.value);
  }

  Future<void> updateCustomVpn(int index, String value) async {
    await _repo.update((s) => s.customVpn[index] = value);
    vpnState.setCustomVpn(List<String>.from((await _repo.get()).customVpn));
  }
}
