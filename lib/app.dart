import 'package:astral/shared/widgets/common/home_widget_refresh_binder.dart';
import 'package:astral/features/home/pages/main_screen.dart';
import 'package:flutter/material.dart';
import 'package:astral/core/services/service_manager.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:signals_flutter/signals_flutter.dart';

class KevinApp extends StatelessWidget {
  const KevinApp({super.key});

  @override
  Widget build(BuildContext context) {
    final services = ServiceManager();

    // 使用 Watch 监听主题变化
    return Watch((context) {
      // 读取当前主题颜色和模式，这样当它们变化时会自动重建
      final themeColor = services.themeState.themeColor.value;
      final themeMode = services.themeState.themeMode.value;

      return MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        // 不再改写 MediaQuery：旧实现强制 devicePixelRatio=1.0 并改
        // textScaler/padding/viewInsets，会破坏小窗口下的缩放与安全区
        // 计算（#246 小窗内容异常）。小窗/紧凑布局改由各布局组件基于
        // 实际约束（LayoutBuilder / MediaQuery.sizeOf）自行处理。
        builder: (BuildContext context, Widget? child) {
          return child ?? const SizedBox.shrink();
        },
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: themeColor, // 使用监听的主题颜色
          brightness: Brightness.light,
        ).copyWith(
          textTheme: Typography.material2021().black.apply(
            fontFamily: 'MiSans',
          ),
          primaryTextTheme: Typography.material2021().black.apply(
            fontFamily: 'MiSans',
          ),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: themeColor, // 使用监听的主题颜色
          brightness: Brightness.dark,
        ).copyWith(
          textTheme: Typography.material2021().white.apply(
            fontFamily: 'MiSans',
          ),
          primaryTextTheme: Typography.material2021().white.apply(
            fontFamily: 'MiSans',
          ),
        ),
        themeMode: themeMode, // 使用监听的主题模式
        home: const HomeWidgetRefreshBinder(child: MainScreen()),
      );
    });
  }
}
