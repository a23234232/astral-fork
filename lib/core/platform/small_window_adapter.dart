import 'package:flutter/material.dart';

/// 小窗口（Android 自由窗口 / 分屏 / 平板窄窗）适配工具。
///
/// 只提供「基于实际布局约束」的断点判断，**不再改写 MediaQuery**。
/// 旧实现会强制 `devicePixelRatio = 1.0`、`textScaler = 0.9` 并改写
/// padding/viewInsets，导致整棵 UI 的缩放与安全区计算失真，是小窗
/// 模式下内容区空白/错位（#246）的诱因之一。小窗分支改由各布局组件
/// 通过 `LayoutBuilder` 拿到的真实约束驱动。
class SmallWindowAdapter {
  const SmallWindowAdapter._();

  /// 紧凑宽度断点：低于该逻辑宽度按「小窗口/紧凑」布局处理。
  /// 参考 #246 截图（Redmi K50 Ultra 小窗逻辑宽约 300~310dp，且 5 个
  /// 底部标签仍全部显示，说明旧的 300dp 阈值没有命中）；普通手机竖屏
  /// 宽度通常 ≥360dp，因此取 360 作为紧凑断点，既覆盖真实小窗，
  /// 又能随窗口自由缩放实时生效。
  static const double compactWidthBreakpoint = 360;

  /// 紧凑高度断点：横屏或小窗高度过小时也走紧凑布局，
  /// 避免「顶部栏 + 内容 + 底部导航」在垂直方向挤爆。
  static const double compactHeightBreakpoint = 420;

  /// 基于父级实际约束判断是否使用紧凑布局（推荐：随窗口尺寸实时变化）。
  static bool isCompactConstraints(BoxConstraints constraints) {
    final width =
        constraints.hasBoundedWidth
            ? constraints.maxWidth
            : double.infinity;
    final height =
        constraints.hasBoundedHeight
            ? constraints.maxHeight
            : double.infinity;
    return isCompactSize(Size(width, height));
  }

  /// 基于窗口逻辑尺寸判断（拿不到父级约束时使用，例如 BottomNav）。
  static bool isCompactSize(Size size) {
    return size.width < compactWidthBreakpoint ||
        size.height < compactHeightBreakpoint;
  }
}
