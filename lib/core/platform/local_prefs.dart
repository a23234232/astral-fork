import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 轻量本地偏好存储（JSON 文件）。
///
/// 为什么不用 Isar：`*.g.dart` 由 build_runner 生成，当前构建环境不具备生成条件；
/// 这里只需要持久化少量「连接行为」开关，用应用支持目录下的 JSON 文件即可。
///
/// 设计取舍：
/// - 读取失败（文件损坏 / 权限异常 / 平台不支持）一律回退默认值并 debugPrint，
///   不向上抛异常，避免影响主流程；
/// - 写入失败同样只记录日志（内存缓存已更新，本次运行内行为一致）；
/// - 文件读取使用内存缓存，避免每次连接房间都读盘。
class LocalPrefs {
  LocalPrefs._();

  static const String _fileName = 'astral_prefs.json';

  /// #243：连接「自带服务器的房间」时，是否同时叠加用户的全局启用服务器。
  ///
  /// 默认 false：房间自带服务器时只使用房间服务器，避免把用户自己的默认服务器
  /// 混进别人的房间（旧行为是两者无条件合并）。
  static const bool defaultUseGlobalServersWithRoom = false;

  static const String _keyUseGlobalServersWithRoom = 'useGlobalServersWithRoom';

  static File? _cachedFile;
  static Map<String, dynamic>? _cachedData;

  static Future<File> _prefsFile() async {
    final cached = _cachedFile;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$_fileName');
    _cachedFile = file;
    return file;
  }

  static Future<Map<String, dynamic>> _read() async {
    final cached = _cachedData;
    if (cached != null) return cached;

    try {
      final file = await _prefsFile();
      if (!await file.exists()) {
        _cachedData = <String, dynamic>{};
        return _cachedData!;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _cachedData = <String, dynamic>{};
        return _cachedData!;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _cachedData = Map<String, dynamic>.from(decoded);
      } else {
        _cachedData = <String, dynamic>{};
      }
    } catch (e) {
      debugPrint('读取本地偏好失败，使用默认值: $e');
      _cachedData = <String, dynamic>{};
    }
    return _cachedData!;
  }

  static Future<void> _write(Map<String, dynamic> data) async {
    _cachedData = data;
    try {
      final file = await _prefsFile();
      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (e) {
      debugPrint('写入本地偏好失败（仅本次运行生效）: $e');
    }
  }

  /// 房间自带服务器时是否同时连接全局启用服务器（#243）。
  static Future<bool> getUseGlobalServersWithRoom() async {
    final data = await _read();
    final value = data[_keyUseGlobalServersWithRoom];
    return value is bool ? value : defaultUseGlobalServersWithRoom;
  }

  static Future<void> setUseGlobalServersWithRoom(bool value) async {
    final data = Map<String, dynamic>.from(await _read());
    data[_keyUseGlobalServersWithRoom] = value;
    await _write(data);
  }
}
