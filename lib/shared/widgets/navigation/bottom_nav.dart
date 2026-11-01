import 'dart:math' as math;

import 'package:astral/core/platform/small_window_adapter.dart';
import 'package:astral/core/services/service_manager.dart';
import 'package:astral/core/ui/navigation.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class BottomNav extends StatelessWidget {
  final List<NavigationItem> navigationItems;
  final ColorScheme colorScheme;

  const BottomNav({
    super.key,
    required this.navigationItems,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final selectedIndex = ServiceManager().uiState.selectedIndex.value;

      return LayoutBuilder(
        builder: (context, constraints) {
          final windowSize = MediaQuery.sizeOf(context);
          final availableWidth =
              constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : windowSize.width;

          // 小窗/窄屏：使用可横向滚动的紧凑导航；正常宽度沿用
          // BottomNavigationBar，保持原有视觉与交互（#246）。
          if (SmallWindowAdapter.isCompactSize(windowSize) ||
              availableWidth < SmallWindowAdapter.compactWidthBreakpoint) {
            return _buildCompactNav(
              context,
              selectedIndex,
              availableWidth,
            );
          }

          return BottomNavigationBar(
            backgroundColor: colorScheme.surfaceContainerLow,
            type: BottomNavigationBarType.fixed,
            selectedItemColor: colorScheme.primary,
            unselectedItemColor: colorScheme.onSurfaceVariant,
            showUnselectedLabels: true,
            selectedFontSize: 12,
            unselectedFontSize: 10,
            items:
                navigationItems
                    .map(
                      (item) => BottomNavigationBarItem(
                        icon: Icon(item.icon, size: 24),
                        activeIcon: Icon(item.activeIcon, size: 24),
                        label: item.label,
                      ),
                    )
                    .toList(),
            currentIndex: selectedIndex
                .clamp(0, math.max(0, navigationItems.length - 1))
                .toInt(),
            onTap: (index) {
              ServiceManager().uiState.selectedIndex.value = index;
            },
          );
        },
      );
    });
  }

  /// 紧凑底部导航：固定高度 + 横向滚动，保证窄窗口下所有入口都可达，
  /// 不会因 5 个 item 挤压而溢出（#246）。
  Widget _buildCompactNav(
    BuildContext context,
    int selectedIndex,
    double availableWidth,
  ) {
    final safeIndex = selectedIndex
        .clamp(0, math.max(0, navigationItems.length - 1))
        .toInt();
    final itemCount = math.max(1, navigationItems.length);
    final itemWidth = math.max(64.0, availableWidth / itemCount);

    return Material(
      color: colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 54,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < navigationItems.length; i++)
                  SizedBox(
                    width: itemWidth,
                    height: 54,
                    child: InkWell(
                      onTap: () {
                        ServiceManager().uiState.selectedIndex.value = i;
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            i == safeIndex
                                ? navigationItems[i].activeIcon
                                : navigationItems[i].icon,
                            size: 20,
                            color:
                                i == safeIndex
                                    ? colorScheme.primary
                                    : colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            navigationItems[i].label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              color:
                                  i == safeIndex
                                      ? colorScheme.primary
                                      : colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
