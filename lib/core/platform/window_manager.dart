import 'package:astral/core/platform/startup_url_scheme.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:astral/core/services/service_manager.dart';

class WindowManagerUtils {
  static Future<void> initializeWindow() async {
    // 检查当前平台是否为 Windows、MacOS 或 Linux
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // 确保窗口管理器已初始化
      await windowManager.ensureInitialized();
      windowManager.setIcon('assets/logo.png');

      // 设置窗口标题为当前应用名称
      windowManager.setTitle(ServiceManager().appSettingsState.appName.value);
      // 定义窗口选项配置
      final windowOptions = WindowOptions(
        size: Size(960, 540),
        // 设置窗口最小大小为 300x300
        minimumSize: Size(200, 300),
        // 设置窗口居中显示
        center: true,
        // 设置窗口标题
        title: ServiceManager().appSettingsState.appName.value,
        // 设置标题栏样式为隐藏
        titleBarStyle: TitleBarStyle.hidden,
        // 设置窗口背景为透明
        backgroundColor: Colors.transparent,
        // 设置是否在任务栏显示
        skipTaskbar: false,
      );

      // 等待窗口准备就绪并显示
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        // 自动启动时始终隐藏窗口（系统启动时无桌面会话）
        if (isAutostart ||
            ServiceManager().startupState.startupMinimize.value) {
          ServiceManager().uiState.setBackground(true);
          await windowManager.hide();
        } else {
          ServiceManager().uiState.setBackground(false);
          await windowManager.show();
          await windowManager.focus();
        }
      });

      await windowManager.setPreventClose(true);

      // 启动路径只做「补齐」，不做迁移/覆盖（对应 issue #259）：
      // - 自启已开启且计划任务不存在 → 创建一次（避免任务被系统清理后永久失效）；
      // - 任务已存在 → 保持原样，不用 /f 重建，尊重用户对触发器/延迟的修改；
      // - 设置关闭 → 什么都不做。同名计划任务可能是用户自己创建的，不能在启动时删。
      // 旧版 HKCU Run / 启动文件夹自启项的清理只在用户主动切换设置时执行
      // （见 app_settings_service.setStartup → handleStartupSetting 默认 migrateLegacy=true）。
      await handleStartupSetting(
        ServiceManager().startupState.startup.value,
        migrateLegacy: false,
      );
    }
  }
}
