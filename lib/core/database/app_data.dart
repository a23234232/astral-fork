import 'dart:io';
import 'package:astral/core/models/all_settings.dart';
import 'package:astral/core/models/net_config.dart';
import 'package:astral/core/models/room.dart';
import 'package:astral/core/models/server_mod.dart';
import 'package:astral/core/models/magic_wall_model.dart';
import 'package:astral/core/database/dao/all_settings_dao.dart';
import 'package:astral/core/database/dao/net_config_dao.dart';
import 'package:astral/core/database/dao/room_dao.dart';
import 'package:astral/core/database/dao/server_dao.dart';
import 'package:astral/core/database/dao/magic_wall_dao.dart';
import 'package:isar_community/isar.dart';
import 'package:astral/core/models/theme_settings.dart';
import 'package:astral/core/database/dao/theme_settings_dao.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

class AppDatabase {
  static final AppDatabase _instance = AppDatabase._internal();
  factory AppDatabase() => _instance;
  AppDatabase._internal();

  late Isar isar;
  late ThemeSettingsDao themeSettings;
  late NetConfigDao netConfig;
  late RoomDao rooms;
  late AllSettingsDao allSettings;
  late ServerDao servers;
  late MagicWallDao magicWall;
  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// 初始化数据库
  Future<void> init([String? customDbDir]) async {
    if (_initialized) return;
    late final String dbDir;
    // 以 sudo / pkexec 运行时，若数据库被写到真实用户家目录，需要把属主
    // 归还给该用户（root 创建的文件普通用户默认无写权限，见 #250）。
    String? realUserHomeForChown;

    if (customDbDir != null) {
      // 使用自定义数据库目录
      dbDir = customDbDir;
    } else if (Platform.isAndroid) {
      // Android平台使用应用专属目录
      final appDocDir = await getApplicationDocumentsDirectory();
      dbDir = Directory(path.join(appDocDir.path, 'db')).path;
    } else if (Platform.isLinux) {
      // Linux平台使用用户数据目录。
      // 注意：以 sudo / pkexec 提权运行时 HOME 可能变成 /root，直接用 HOME
      // 会导致普通用户与 root 的数据分叉、后续普通用户读不到（#250）。
      // 因此优先用 SUDO_USER / PKEXEC_UID 对应的真实用户目录；为向后兼容，
      // 若旧路径（当前 HOME 下）已有数据则继续沿用旧路径，避免升级后数据“消失”。
      final envHome = Platform.environment['HOME'] ?? '.';
      final realUserHome = _resolveLinuxRealUserHome();
      final legacyDir =
          Directory(path.join(envHome, '.local', 'share', 'astral', 'db')).path;
      if (realUserHome == null || realUserHome == envHome) {
        dbDir = legacyDir;
      } else {
        final userDir = Directory(
          path.join(realUserHome, '.local', 'share', 'astral', 'db'),
        ).path;
        final useLegacy = Directory(legacyDir).existsSync();
        dbDir = useLegacy ? legacyDir : userDir;
        if (!useLegacy) {
          realUserHomeForChown = realUserHome;
        }
      }
    } else if (Platform.isMacOS) {
      // macOS平台使用应用支持目录
      final appSupportDir = await getApplicationSupportDirectory();
      dbDir = Directory(path.join(appSupportDir.path, 'astral', 'db')).path;
    } else {
      // 其他平台使用可执行文件所在目录
      final executablePath = Platform.resolvedExecutable;
      final executableDir = Directory(executablePath).parent.path;
      dbDir = Directory(path.join(executableDir, 'data', 'db')).path;
    }

    // 确保数据库目录存在
    await Directory(dbDir).create(recursive: true);
    isar = await Isar.open([
      ThemeSettingsSchema,
      NetConfigSchema,
      RoomSchema,
      AllSettingsSchema,
      ServerModSchema,
      MagicWallRuleModelSchema,
      MagicWallGroupModelSchema,
      MagicWallEventLogModelSchema,
    ], directory: dbDir);
    if (realUserHomeForChown != null) {
      _chownLinuxDbDirToRealUser(realUserHomeForChown, dbDir);
    }
    themeSettings = ThemeSettingsDao(isar);
    netConfig = NetConfigDao(isar);
    rooms = RoomDao(isar);
    allSettings = AllSettingsDao(isar);
    servers = ServerDao(isar);
    magicWall = MagicWallDao(isar);

    // 确保初始化完成
    await rooms.init();
    await servers.init();
    _initialized = true;
  }
}

/// 解析 Linux 下“实际用户”的家目录（#250）。
///
/// 以 sudo 提权运行时环境变量里有 SUDO_USER；以 pkexec 提权运行时 polkit
/// 会设置 PKEXEC_UID。用它们反查 /etc/passwd 得到真实用户的家目录，
/// 避免把数据库写进 /root。解析失败返回 null，由调用方回退到当前 HOME。
String? _resolveLinuxRealUserHome() {
  final env = Platform.environment;
  final sudoUser = env['SUDO_USER'];
  if (sudoUser != null && sudoUser.isNotEmpty && sudoUser != 'root') {
    final home = _linuxHomeFromPasswd(sudoUser: sudoUser);
    if (home != null) return home;
  }
  final pkexecUid = env['PKEXEC_UID'];
  if (pkexecUid != null && pkexecUid.isNotEmpty) {
    final home = _linuxHomeFromPasswd(uid: pkexecUid);
    if (home != null) return home;
  }
  return null;
}

/// 从 /etc/passwd 中按用户名或 uid 查找家目录；查不到返回 null。
String? _linuxHomeFromPasswd({String? sudoUser, String? uid}) {
  try {
    final passwd = File('/etc/passwd');
    if (!passwd.existsSync()) return null;
    for (final line in passwd.readAsLinesSync()) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final fields = line.split(':');
      if (fields.length < 7) continue;
      final name = fields[0];
      final userId = fields[2];
      final home = fields[5];
      final matched =
          (sudoUser != null && name == sudoUser) ||
          (uid != null && userId == uid);
      if (matched && home.isNotEmpty) return home;
    }
  } catch (_) {
    // 读取失败时交给调用方回退到 HOME
  }
  return null;
}

/// 以 sudo / pkexec 运行时，把 Linux 数据库目录的属主归还给真实用户（#250）。
///
/// root 在用户家目录下创建的文件默认属于 root，后续普通用户（例如用
/// setcap 免 sudo 启动）会因没有写权限而无法打开 Isar 数据库。这里在
/// 初始化完成后执行 `chown -R`，失败只影响后续权限、不影响本次启动，
/// 因此吞掉异常、不中断流程。
void _chownLinuxDbDirToRealUser(String realHome, String dbDir) {
  final env = Platform.environment;
  // sudo 有 SUDO_USER；pkexec 会设置 PKEXEC_UID（数字 uid），chown 都接受
  final owner = env['SUDO_USER'] ?? env['PKEXEC_UID'];
  if (owner == null || owner.isEmpty) return;
  // 只在数据库确实位于真实用户家目录下时才需要 chown
  if (!dbDir.startsWith(realHome)) return;
  // 同时归还上级 astral 目录，避免后续版本在 ~/.local/share/astral 下建文件失败
  final astralDir = Directory(dbDir).parent;
  final target = astralDir.existsSync() ? astralDir.path : dbDir;
  try {
    final result = Process.runSync('chown', ['-R', owner, target]);
    if (result.exitCode != 0) {
      stderr.writeln('chown $owner $target failed: ${result.stderr}');
    }
  } catch (e) {
    // 例如系统没有 chown（极少见）：仅记录，不妨碍启动
    stderr.writeln('chown $owner $target failed: $e');
  }
}

