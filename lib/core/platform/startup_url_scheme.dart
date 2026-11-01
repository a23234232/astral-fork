import 'dart:io';
import 'package:astral/core/bootstrap/file_logger.dart';
import 'package:flutter/foundation.dart';

const _taskName = 'Astral';

/// 由 main.dart 在启动时设置，标记当前是否为自动启动
bool isAutostart = false;

/// 删除旧版「启动」文件夹快捷方式。
///
/// 仅在用户主动切换自启设置时调用（见 [handleStartupSetting] 的 migrateLegacy 参数）：
/// 旧版实现每次应用启动都会静默删除这些项目，会误删用户手工创建的自启项（issue #259）。
Future<void> _removeLegacyStartupShortcut() async {
  if (!Platform.isWindows) return;

  try {
    final startupFolder =
        '${Platform.environment['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs\\Startup';
    final shortcutPath = '$startupFolder\\Astral.lnk';
    final shortcut = File(shortcutPath);
    if (await shortcut.exists()) {
      await shortcut.delete();
    }
  } catch (e) {
    await FileLogger().warning('清理旧版启动文件夹快捷方式失败: $e');
    if (kDebugMode) {
      debugPrint('Failed to remove legacy startup shortcut: $e');
    }
  }
}

/// 移除旧的注册表 Run 键（如果存在），迁移到 Task Scheduler 方案。
///
/// 同样只在用户主动切换自启设置时调用，避免每次启动删除用户手工添加的 Run 项。
Future<void> _removeLegacyRegistryRun() async {
  try {
    await Process.run('reg', [
      'delete',
      'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run',
      '/v',
      'Astral',
      '/f',
    ]);
  } catch (_) {
    // 旧键可能不存在，忽略错误（非 0 退出码也不会抛异常）
  }
}

/// 查询计划任务当前是否存在。
///
/// 只按退出码判断：任务不存在时 schtasks 返回非 0。
/// 不能解析输出文本，因为 schtasks 的错误信息会随系统语言本地化。
Future<bool> _startupTaskExists() async {
  try {
    final result = await Process.run('schtasks', [
      '/query',
      '/tn',
      _taskName,
    ]);
    return result.exitCode == 0;
  } catch (e) {
    // 查询本身失败（例如 schtasks 不存在）时按「不存在」处理：
    // 后续创建失败会再记录一次错误，这里不会误删任何东西。
    await FileLogger().error('查询自启动计划任务失败: $e');
    if (kDebugMode) {
      debugPrint('Failed to query startup task: $e');
    }
    return false;
  }
}

/// 判断现有计划任务是不是旧版「系统启动时」(ONSTART) 触发器。
///
/// 旧版本用 `/sc ONSTART` 创建任务，用户升级后如果不重建，任务会一直保留，
/// 表现仍是「开机不自启」——所以需要一次性把它迁移成 ONLOGON（见 #259/#253）。
///
/// 用 `/xml` 判断：导出的 XML 里触发器标签是固定英文
/// （`<BootTrigger>` / `<LogonTrigger>`），不受系统语言影响。
/// 返回：true=旧版启动触发器，false=其它/未知（保持原样，不覆盖用户的修改）。
Future<bool> _startupTaskUsesBootTrigger() async {
  try {
    final result = await Process.run('schtasks', [
      '/query',
      '/tn',
      _taskName,
      '/xml',
    ]);
    if (result.exitCode != 0) return false;
    final xml = result.stdout.toString();
    return xml.contains('<BootTrigger>') && !xml.contains('<LogonTrigger>');
  } catch (e) {
    await FileLogger().warning('读取自启动任务 XML 失败，按已就绪处理: $e');
    return false;
  }
}

/// 记录 schtasks 失败详情（退出码 + stderr）。
///
/// 旧实现只在 kDebugMode 里 debugPrint，Release 用户失败后无任何线索可上报；
/// 这里同时写 FileLogger，方便用户把日志发给开发者定位。
Future<void> _logSchtasksFailure(String action, ProcessResult result) async {
  final message =
      '自启动计划任务$action失败: exitCode=${result.exitCode}, '
      'stderr=${result.stderr}, stdout=${result.stdout}';
  await FileLogger().error(message);
  if (kDebugMode) {
    debugPrint(message);
  }
}

/// 创建计划任务：登录时启动 + 最高权限。
///
/// 触发器用 ONLOGON 而不是 ONSTART：
/// ONSTART 在「系统启动、用户尚未登录」时触发，此时 GUI 托盘程序没有用户会话，
/// 任务实际不会执行（issue #259 / #253 的真实根因）。ONLOGON 在用户登录后触发，
/// 配合 /rl HIGHEST 用最高权限令牌启动，绕过 exe manifest 的 requireAdministrator，
/// 不会弹 UAC，也不需要「登录前运行」这类 Session 0 配置。
///
/// 只在任务不存在时调用本函数；/f 仅用于覆盖「查询瞬间被并发创建」或残留的损坏同名任务。
Future<bool> _createStartupTask() async {
  final executablePath = Platform.resolvedExecutable;
  // /tr 的值必须是 "<exe 完整路径>" --autostart：
  // 安装路径通常含空格（如 C:\Program Files\Astral\astral.exe），
  // 整段引号必须保留，否则 schtasks 会把路径拆成多个参数、任务指向错误的程序。
  final command = '"$executablePath" --autostart';

  try {
    final result = await Process.run('schtasks', [
      '/create',
      '/tn',
      _taskName,
      '/tr',
      command,
      '/sc',
      'ONLOGON',
      '/rl',
      'HIGHEST',
      '/f',
    ]);
    if (result.exitCode != 0) {
      await _logSchtasksFailure('创建', result);
      return false;
    }
    await FileLogger().info(
      '已创建自启动计划任务($_taskName, ONLOGON/HIGHEST): $command',
    );
    return true;
  } catch (e) {
    await FileLogger().error('创建自启动计划任务异常: $e');
    if (kDebugMode) {
      debugPrint('Failed to create startup task: $e');
    }
    return false;
  }
}

/// 删除计划任务。
///
/// 只在用户主动关闭自启开关时调用；应用启动路径绝不删除，
/// 因为同名任务/自启项可能是用户自己手工创建的（issue #259）。
Future<void> _deleteStartupTask() async {
  try {
    final result = await Process.run('schtasks', [
      '/delete',
      '/tn',
      _taskName,
      '/f',
    ]);
    if (result.exitCode != 0) {
      await _logSchtasksFailure('删除', result);
      return;
    }
    await FileLogger().info('已删除自启动计划任务($_taskName)');
  } catch (e) {
    await FileLogger().error('删除自启动计划任务异常: $e');
    if (kDebugMode) {
      debugPrint('Failed to delete startup task: $e');
    }
  }
}

/// 处理 Windows 开机自启设置（幂等）。
///
/// 两种调用方，语义不同：
/// - 用户主动切换设置（`app_settings_service.setStartup`，不传 migrateLegacy 即默认 true）：
///   清理旧版自启项；开启时任务不存在才创建、已存在则保留；关闭时任务存在才删除。
/// - 应用启动路径（`window_manager.dart` 传 migrateLegacy: false）：
///   只做「补齐」——设置开启且任务不存在才创建一次；
///   任务已存在就保持原样，设置关闭也**绝不**在这里删除任务。
///   这修掉了「每次启动都用 /f 强制重建任务、并删掉用户手工添加项」的 #259 根因。
///
/// [migrateLegacy] 同时代表「是否由用户主动操作触发」：只有 true 时才允许
/// 执行旧版自启项清理与关闭时的删除这种破坏性动作。
Future<void> handleStartupSetting(
  bool enable, {
  bool migrateLegacy = true,
}) async {
  if (!Platform.isWindows) return;

  // 1) 用户主动切换设置时，先做旧机制迁移：清掉旧版 HKCU Run 键与启动文件夹快捷方式。
  //    这是 #253 中「旧机制与 UAC 冲突」的迁移动作，只应在用户明确操作时做一次；
  //    应用启动路径（migrateLegacy=false）绝不能删，否则正是 #259 抱怨的
  //    「每次运行 Astral 后用户自建的自启项被删掉」。
  if (migrateLegacy) {
    await _removeLegacyStartupShortcut();
    await _removeLegacyRegistryRun();
  }

  if (!enable) {
    // 关闭：只有用户主动关闭时才删除任务。
    // 应用启动路径（migrateLegacy=false）直接返回，避免删掉用户自建的同名任务。
    if (!migrateLegacy) return;
    if (await _startupTaskExists()) {
      await _deleteStartupTask();
    }
    return;
  }

  // 2) 开启（或启动时补齐）：幂等——已存在就什么都不做，
  //    尊重用户对任务的修改（触发器/延迟/权限等）；不存在才创建一次。
  //    绝不再无条件 /f 重建。
  if (await _startupTaskExists()) {
    // 例外：老版本用 /sc ONSTART 创建的任务在「系统启动、用户尚未登录」时触发，
    // GUI 程序拿不到用户会话，实际不会启动（#259/#253）。升级后如果不迁移，
    // 老用户会一直保留这个失效任务，所以这里做一次性迁移：
    // 只有确认它是 BootTrigger 时才重建为 ONLOGON；用户手工改过的
    // LogonTrigger 任务一律保持原样，不覆盖。
    if (await _startupTaskUsesBootTrigger()) {
      await FileLogger().info('检测到旧版 ONSTART 自启任务，迁移为 ONLOGON');
      await _createStartupTask();
      return;
    }
    if (kDebugMode) {
      debugPrint('Startup task already exists, keep it untouched: $_taskName');
    }
    return;
  }

  await _createStartupTask();
}

class UrlSchemeRegistrar {
  /// 注册 URL scheme 到 Windows 注册表
  static Future<bool> registerUrlScheme() async {
    if (!Platform.isWindows) return true;

    try {
      final executablePath = Platform.resolvedExecutable;

      final commands = [
        [
          'add',
          'HKEY_CURRENT_USER\\Software\\Classes\\astral',
          '/ve',
          '/d',
          'URL:Astral Protocol',
          '/f',
        ],
        [
          'add',
          'HKEY_CURRENT_USER\\Software\\Classes\\astral',
          '/v',
          'URL Protocol',
          '/d',
          '',
          '/f',
        ],
        [
          'add',
          'HKEY_CURRENT_USER\\Software\\Classes\\astral\\DefaultIcon',
          '/ve',
          '/d',
          '"$executablePath",1',
          '/f',
        ],
        [
          'add',
          'HKEY_CURRENT_USER\\Software\\Classes\\astral\\shell\\open\\command',
          '/ve',
          '/d',
          '"$executablePath" "%1"',
          '/f',
        ],
      ];

      for (final command in commands) {
        final result = await Process.run('reg', command);
        if (result.exitCode != 0) {
          if (kDebugMode) {
            debugPrint('Failed to execute reg command: ${command.join(' ')}');
            debugPrint('Error: ${result.stderr}');
          }
          return false;
        }
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error registering URL scheme: $e');
      }
      return false;
    }
  }
}
