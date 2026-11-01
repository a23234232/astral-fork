import 'dart:async';
import 'dart:io';
import 'package:astral/src/rust/api/utils.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:astral/core/platform/app_info.dart';
import 'package:astral/core/platform/startup_url_scheme.dart';
import 'package:astral/core/bootstrap/log_capture.dart';
import 'package:astral/core/bootstrap/file_logger.dart';
import 'package:astral/core/bootstrap/global_error_handler.dart';
import 'package:astral/core/database/app_data.dart';
import 'package:astral/core/platform/window_manager.dart';
import 'package:astral/core/services/service_manager.dart';
import 'package:astral/core/app_links/app_link_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:path/path.dart' as p;
import 'package:astral/src/rust/frb_generated.dart';
import 'package:astral/app.dart';

void main(List<String> args) async {
  // 检测是否为自动启动
  if (args.contains('--autostart')) {
    isAutostart = true;
  }

  // 初始化文件日志系统（Release 模式下不会创建文件）
  await FileLogger().init();
  GlobalErrorHandler.initialize();

  // 使用错误处理包装主应用
  runZonedGuarded(
    () async {
      await _initializeApp(args);
    },
    (error, stack) {
      GlobalErrorHandler.logError(
        'Uncaught error in main zone',
        error: error,
        stack: stack,
      );
    },
  );
}

/// 初始化 FRB 动态库。
///
/// 生成代码里 `kDefaultExternalLibraryLoaderConfig` 会优先从
/// `rust/target/release/` 加载；若本机曾单独 `cargo build --release`，
/// 会一直误用那份旧 dll（与当前 Dart 绑定 content hash 不一致）。
/// Flutter Windows 会把 cargokit 编好的 `rust_lib_astral.dll` 放在 exe 同目录，
/// 因此桌面端优先从该路径显式加载。
Future<void> _initRustLib() async {
  if (!kIsWeb && Platform.isWindows) {
    final bundledPath = p.join(
      File(Platform.resolvedExecutable).parent.path,
      'rust_lib_astral.dll',
    );
    if (File(bundledPath).existsSync()) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(bundledPath),
      );
      return;
    }
  }
  await RustLib.init();
}

Future<void> _initializeApp(List<String> args) async {
  try {
    await _initRustLib();
    FileLogger().info('RustLib initialized');

    // Linux 下检测是否具备 CAP_NET_ADMIN（创建 TUN / 配置路由所需）。
    // v2.9.60 及以前：非 root 时只 debugPrint + exit(1)，从桌面图标启动时
    // 用户看不到任何提示，表现为「点一下没反应」（#250 / #194）。
    // 现在：缺少能力时给出可操作提示并继续启动（NO-TUN 模式仍可用），
    // 不要再静默退出。
    if (!kIsWeb && Platform.isLinux) {
      await _ensureLinuxNetworkCapability(args);
    }

    WidgetsFlutterBinding.ensureInitialized();

    if (Platform.isMacOS) {
      // 必须 await：此前的 .then 没有等待，父进程会继续初始化并显示窗口，
      // 而提权子进程同时也在运行，形成「双实例 + 一个没有权限」（#189）。
      // 提权成功时 elevated-command 会拉起新进程并等待其退出，这里返回
      // false 表示当前（无权限）进程应当退出，不再初始化第二个实例。
      final elevated = await checkSudo();
      if (!elevated) {
        FileLogger().warning('macOS elevation failed or cancelled, exiting');
        exit(0); // 当前进程退出，交由新进程运行
      }
    }

    await EasyLocalization.ensureInitialized();
    FileLogger().info('EasyLocalization initialized');

    await AppDatabase().init();
    FileLogger().info('Database initialized');

    // 初始化新的服务管理器
    final services = ServiceManager();
    await services.init();
    FileLogger().info('ServiceManager initialized');

    // 初始化贴片服务
    services.widgets.initialize();
    if (Platform.isAndroid) {
      await services.widgets.syncAll();
    }
    FileLogger().info('WidgetService initialized');

    try {
      await AppInfoUtil.init().timeout(const Duration(seconds: 3));
      FileLogger().info('AppInfoUtil initialized');
    } catch (e) {
      FileLogger().warning('AppInfoUtil init timeout/failure, continue: $e');
    }

    await LogCapture().startCapture();
    FileLogger().info('LogCapture started');

    await UrlSchemeRegistrar.registerUrlScheme();
    FileLogger().info('URL scheme registered');

    await _initAppLinks();

    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await WindowManagerUtils.initializeWindow();
      FileLogger().info('Window manager initialized');
    }

    _runApp();
  } catch (e, stack) {
    GlobalErrorHandler.logError(
      'Failed to initialize app',
      error: e,
      stack: stack,
    );
    rethrow;
  }
}

void _runApp() {
  FileLogger().info('Starting Flutter app');
  runApp(
    EasyLocalization(
      supportedLocales: const [
        Locale('zh'),
        Locale('en'),
      ],
      path: 'assets/translations',
      fallbackLocale: const Locale('zh'),
      child: const KevinApp(),
    ),
  );
}

Future<void> _initAppLinks() async {
  try {
    final registry = AppLinkRegistry();
    await registry.initialize();
    FileLogger().info('App links initialized');
  } catch (e, stack) {
    FileLogger().warning('App links 初始化失败: $e');
    GlobalErrorHandler.logError(
      'Failed to initialize app links',
      error: e,
      stack: stack,
    );
  }
}

/// Linux 下与提权相关的进程能力快照。
///
/// 只依赖 dart:io（在 WidgetsFlutterBinding 初始化之前使用）。
class _LinuxPrivileges {
  const _LinuxPrivileges({
    this.isRoot = false,
    this.hasNetAdmin = false,
    this.hasNetRaw = false,
  });

  /// 是否以 root 身份运行。
  final bool isRoot;

  /// 是否具备 CAP_NET_ADMIN（创建 TUN、配置地址/路由所需）。
  final bool hasNetAdmin;

  /// 是否具备 CAP_NET_RAW（faketcp 的 AF_PACKET/SOCK_RAW 需要）。
  final bool hasNetRaw;

  /// 是否具备 TUN 模式所需的最小能力集。
  bool get canUseTun => isRoot || hasNetAdmin;
}

/// Linux 启动时的能力检查与提权处理（#250 / #194）。
///
/// 旧行为：非 root 且无 SUDO_USER 时只打印一句提示然后 exit(1)，
/// 从桌面图标启动时用户什么都看不到。现在：
///   1. 读取 /proc/self/status 的 CapEff 判断 CAP_NET_ADMIN / CAP_NET_RAW；
///   2. 能力缺失时打印可操作提示（setcap / sudo / NO-TUN）并写入日志；
///   3. 若处于图形会话且存在 pkexec，可尝试提权重启（失败/取消则回退）；
///   4. 无论如何都继续启动应用，绝不因为缺少能力而退出。
Future<void> _ensureLinuxNetworkCapability(List<String> args) async {
  final privileges = _readLinuxPrivileges();
  if (privileges.canUseTun) {
    FileLogger().info(
      'Linux privileges ok: root=${privileges.isRoot}, '
      'cap_net_admin=${privileges.hasNetAdmin}, '
      'cap_net_raw=${privileges.hasNetRaw}',
    );
    return;
  }

  final exe = Platform.resolvedExecutable;
  final hint =
      '当前进程缺少 CAP_NET_ADMIN，TUN 模式（创建虚拟网卡 / 配置路由）不可用。\n'
      '这不会阻止应用启动：可直接使用 NO-TUN 模式'
      '（设置 → 网络 → 关闭 TUN 模式，由 Clash 等工具接管流量）。\n'
      '如需 TUN 模式，任选其一：\n'
      '  1) 以 sudo 运行：sudo "$exe"\n'
      '  2) 授予文件能力（推荐，日常免 sudo）：\n'
      '     sudo setcap \'cap_net_admin,cap_net_raw+ep\' "$exe"\n'
      '     注意：升级 / 重装会覆盖二进制，setcap 随之失效，需要重新执行。\n'
      '     faketcp 依赖 CAP_NET_RAW；magic-dns 还需要 polkit / root 授权，'
      'setcap 模式下可能降级。\n'
      '更多说明见 docs/linux-permissions.md。';
  debugPrint(hint);
  stderr.writeln(hint);
  FileLogger().warning('Linux 缺少 CAP_NET_ADMIN: $hint');

  // 尝试通过 pkexec 提权重启；失败或用户取消时回退为「继续启动」。
  final elevatedSessionFinished = await _tryElevateWithPkexec(args);
  if (elevatedSessionFinished) {
    // 提权实例已经运行结束（用户关闭了应用），不再启动第二个实例。
    exit(0);
  }
}

/// 尝试用 pkexec 提权重启当前应用（仅 Linux）。
///
/// 返回 true 表示提权实例已正常结束，调用方应退出当前进程；
/// 返回 false 表示未尝试或提权失败，调用方继续以无特权模式启动。
Future<bool> _tryElevateWithPkexec(List<String> args) async {
  final env = Platform.environment;
  // 登录自启动时不弹密码框，避免开机即打扰用户
  if (isAutostart) return false;
  // 已经是 root / 通过 sudo 启动时无需再提权
  if (env['SUDO_USER'] != null) return false;
  // 便于用户/发行版关闭自动提权（例如统一下发 setcap 的场景）
  if (env['ASTRAL_NO_PKEXEC'] == '1') return false;
  // 只在图形会话下尝试：无显示环境时没有 polkit agent，必然失败
  final hasDisplay =
      (env['DISPLAY']?.isNotEmpty ?? false) ||
      (env['WAYLAND_DISPLAY']?.isNotEmpty ?? false);
  if (!hasDisplay) return false;
  final pkexec = File('/usr/bin/pkexec');
  if (!pkexec.existsSync()) return false;

  final exe = Platform.resolvedExecutable;
  // 透传启动参数（URL scheme 等）；--autostart 已在上面被排除
  final appArgs = args.where((arg) => arg != '--autostart').toList();
  // pkexec 会把环境重置为最小集，直接跑 GUI 程序常报「cannot open display」，
  // 因此用 `pkexec env DISPLAY=... XAUTHORITY=...` 的方式把会话变量带过去。
  final sessionEnv = <String>[];
  for (final key in const [
    'DISPLAY',
    'WAYLAND_DISPLAY',
    'XAUTHORITY',
    'XDG_RUNTIME_DIR',
    'XDG_SESSION_TYPE',
    'DBUS_SESSION_BUS_ADDRESS',
  ]) {
    final value = env[key];
    if (value != null && value.isNotEmpty) {
      sessionEnv.add('$key=$value');
    }
  }
  final pkexecArgs = <String>[
    if (sessionEnv.isNotEmpty) ...['env', ...sessionEnv],
    exe,
    ...appArgs,
  ];
  try {
    FileLogger().info('Linux 缺少 CAP_NET_ADMIN，尝试 pkexec 提权重启: $exe');
    stderr.writeln(
      '正在尝试通过 pkexec 提权重启 Astral；'
      '若取消授权，将继续以 NO-TUN 模式启动。',
    );
    final result = await Process.run('pkexec', pkexecArgs);
    if (result.exitCode == 0) {
      FileLogger().info('pkexec 提权实例已结束，父进程退出');
      return true;
    }
    FileLogger().warning(
      'pkexec 提权失败（exitCode=${result.exitCode}），继续以无特权模式启动',
    );
    stderr.writeln(
      'pkexec 提权失败（exitCode=${result.exitCode}），继续以无特权模式启动。',
    );
    return false;
  } catch (e) {
    FileLogger().warning('pkexec 提权异常，继续以无特权模式启动: $e');
    stderr.writeln('pkexec 提权异常，继续以无特权模式启动: $e');
    return false;
  }
}

/// 读取当前 Linux 进程的能力快照（#250 / #194）。
///
/// 通过 /proc/self/status 的 CapEff 判断 CAP_NET_ADMIN（bit 12）与
/// CAP_NET_RAW（bit 13），不引入任何第三方依赖；读取失败时退回 `id -u`
/// 判断是否 root（root 视为具备全部能力）。
_LinuxPrivileges _readLinuxPrivileges() {
  var isRoot = false;
  try {
    final status = File('/proc/self/status').readAsStringSync();
    final uidMatch = RegExp(
      r'^Uid:\s+(\d+)',
      multiLine: true,
    ).firstMatch(status);
    if (uidMatch != null) {
      isRoot = uidMatch.group(1) == '0';
    }
    final capMatch = RegExp(
      r'^CapEff:\s*([0-9a-fA-F]+)',
      multiLine: true,
    ).firstMatch(status);
    if (capMatch != null) {
      final caps = BigInt.parse(capMatch.group(1)!, radix: 16);
      // CAP_NET_ADMIN = 12，CAP_NET_RAW = 13
      final hasNetAdmin = ((caps >> 12) & BigInt.one) == BigInt.one;
      final hasNetRaw = ((caps >> 13) & BigInt.one) == BigInt.one;
      return _LinuxPrivileges(
        isRoot: isRoot,
        hasNetAdmin: isRoot || hasNetAdmin,
        hasNetRaw: isRoot || hasNetRaw,
      );
    }
  } catch (e) {
    FileLogger().warning('/proc/self/status 读取失败，改用 uid 判断: $e');
  }

  if (!isRoot) {
    try {
      final result = Process.runSync('id', ['-u']);
      if (result.exitCode == 0) {
        isRoot = result.stdout.toString().trim() == '0';
      }
    } catch (_) {
      // 忽略：按无特权处理，继续启动（NO-TUN 模式可用）
    }
  }
  return _LinuxPrivileges(
    isRoot: isRoot,
    hasNetAdmin: isRoot,
    hasNetRaw: isRoot,
  );
}
