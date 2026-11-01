import 'dart:io';
import 'package:astral/core/services/service_manager.dart';
import 'package:astral/shared/widgets/common/status_bar_actions.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 状态栏组件
/// 实现了PreferredSizeWidget接口以指定首选高度
class StatusBar extends StatelessWidget implements PreferredSizeWidget {
  const StatusBar({super.key});

  /// 指定状态栏的首选高度为36
  @override
  Size get preferredSize => const Size.fromHeight(36);

  // 检查是否是圣诞期间
  bool get _isChristmasSeason {
    final now = DateTime.now();
    return now.month == 12 && now.day >= 22 && now.day <= 28;
  }

  @override
  Widget build(BuildContext context) {
    // 获取当前主题的配色方案
    final colorScheme = Theme.of(context).colorScheme;

    // 紧凑（小窗/窄屏）布局由 MainScreen 用独立的 36 高标题栏处理，
    // 这里不再依赖窗口宽度猜测分支（#246）；正常宽度沿用完整状态栏。
    return PreferredSize(
      // 设置状态栏高度
      preferredSize: const Size.fromHeight(36),
      child: GestureDetector(
        // 处理拖动事件，仅在桌面平台启用窗口拖动
        onPanStart: (details) {
          if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
            windowManager.startDragging();
          }
        },
        child: AppBar(
          // 显示应用名称
          title: ShaderMask(
            shaderCallback:
                (bounds) => LinearGradient(
                  colors: [
                    Theme.of(context).colorScheme.primary,
                    Theme.of(context).colorScheme.tertiary,
                  ],
                ).createShader(bounds),
            child: Text(
              ServiceManager().appSettingsState.appName.value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: Colors.white, // 必须设置为白色以显示渐变效果
              ),
            ),
          ),
          // 设置AppBar的背景色和前景色
          backgroundColor: colorScheme.primaryContainer,
          foregroundColor: colorScheme.onPrimaryContainer,
          toolbarHeight: 36,
          // 在桌面平台显示窗口控制按钮
          actions: buildDesktopStatusBarActions(
            context,
            isChristmasSeason: _isChristmasSeason,
            colorScheme: colorScheme,
          ),
        ),
      ),
    );
  }
}
