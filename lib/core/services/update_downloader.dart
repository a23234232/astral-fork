import 'dart:async';
import 'dart:io';

import 'package:astral/core/services/service_manager.dart';
import 'package:astral/shared/utils/github_proxy_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 下载失败原因分类（#214：不再把所有失败都吞成 null，让 UI 能显示真实原因）。
enum DownloadFailureKind {
  /// 网络层错误（域名解析、连接被拒绝、网络中断等）
  network,

  /// 请求/读取超时
  timeout,

  /// 服务器返回非 200 状态码
  http,

  /// 写本地文件失败（磁盘空间、权限等）
  write,

  /// 用户取消
  cancelled,

  /// 其它未分类错误
  unknown,
}

/// 单个下载失败的描述（面向用户的文案 + 排查提示）。
class DownloadFailure {
  final DownloadFailureKind kind;
  final String message;
  final String? detail;
  final int? statusCode;

  const DownloadFailure(
    this.kind,
    this.message, {
    this.detail,
    this.statusCode,
  });

  bool get isCancelled => kind == DownloadFailureKind.cancelled;

  /// 展示给用户的多行文案：真实原因 + 可执行的排查提示。
  String get displayMessage {
    final buffer = StringBuffer(message);
    final extra = detail?.trim();
    if (extra != null && extra.isNotEmpty) {
      buffer.write('\n$extra');
    }
    switch (kind) {
      case DownloadFailureKind.network:
      case DownloadFailureKind.timeout:
      case DownloadFailureKind.http:
        buffer.write('\n提示：请到「设置 > 更新设置」检查网络加速/代理配置后重试。');
        break;
      case DownloadFailureKind.write:
        buffer.write('\n提示：请检查磁盘剩余空间或应用写权限后重试。');
        break;
      case DownloadFailureKind.cancelled:
      case DownloadFailureKind.unknown:
        break;
    }
    return buffer.toString();
  }
}

/// 下载结果：成功携带文件路径，失败携带 [DownloadFailure]。
class DownloadResult {
  final String? filePath;
  final DownloadFailure? failure;

  const DownloadResult.success(this.filePath) : failure = null;

  const DownloadResult.failed(this.failure) : filePath = null;

  bool get isSuccess => filePath != null;
}

/// 更新包下载与 URL 解析（纯 IO，不含 UI）
class UpdateDownloader {
  static const requestTimeout = Duration(seconds: 15);

  Future<String> resolveAcceleratedUrl(String rawUrl) async {
    final setting = ServiceManager().updateState.downloadAccelerate.value;
    if (!GitHubProxySelector.isAccelerationEnabled(setting)) {
      return rawUrl;
    }

    final prefix = await GitHubProxySelector.resolvePrefix(setting);
    if (prefix == null || prefix.isEmpty) {
      return rawUrl;
    }

    if (GitHubProxySelector.isAutoMode(setting)) {
      ServiceManager().updateState.setResolvedDownloadAccelerate(prefix);
    }

    return GitHubProxySelector.buildProxiedUrl(prefix, rawUrl);
  }

  String getPlatformFileName() {
    if (Platform.isAndroid) {
      return 'astral-arm64-v8a.apk';
    } else if (Platform.isWindows) {
      return 'astral-windows-x64-setup.exe';
    } else {
      return '';
    }
  }

  String? getDownloadUrl(Map<String, dynamic> releaseInfo) {
    final fileName = getPlatformFileName();
    if (fileName.isEmpty) return null;
    return getDownloadUrlForFile(releaseInfo, fileName);
  }

  String? getDownloadUrlForFile(
    Map<String, dynamic> releaseInfo,
    String fileName,
  ) {
    final assets = releaseInfo['assets'] as List<dynamic>?;
    if (assets == null) return null;

    for (final asset in assets) {
      if (asset['name'] == fileName) {
        return asset['browser_download_url'] as String?;
      }
    }
    return null;
  }

  /// 下载更新包。
  ///
  /// 返回 [DownloadResult] 而不是 `String?`（#214）：旧实现把所有异常都吞掉并返回
  /// null，UI 只能显示「下载失败：无法保存文件」，无法区分超时/网络/HTTP 状态码/
  /// 写盘失败。现在按阶段捕获并分类，失败路径会清理半成品文件。
  Future<DownloadResult> downloadFile(
    String url,
    String fileName,
    void Function(double) onProgress,
    bool Function() isCancelled,
  ) async {
    File? file;
    IOSink? sink;
    var success = false;

    try {
      // 1) 建立连接 + 等待响应头
      http.StreamedResponse response;
      try {
        final request = http.Request('GET', Uri.parse(url));
        response = await request.send().timeout(requestTimeout);
      } on TimeoutException catch (e) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.timeout,
            '下载请求超时（${requestTimeout.inSeconds} 秒内无响应）',
            detail: e.toString(),
          ),
        );
      } on SocketException catch (e) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.network,
            '网络连接失败（无法连接到下载服务器）',
            detail: e.message,
          ),
        );
      } on HandshakeException catch (e) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.network,
            'HTTPS 握手失败（可能是代理或证书问题）',
            detail: e.message,
          ),
        );
      } on http.ClientException catch (e) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.network,
            '网络请求失败',
            detail: e.message,
          ),
        );
      }

      // 2) HTTP 状态码
      if (response.statusCode != 200) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.http,
            '下载服务器返回 HTTP ${response.statusCode}',
            detail: '${response.reasonPhrase ?? ''}：$url',
            statusCode: response.statusCode,
          ),
        );
      }

      // 3) 准备本地文件
      final File targetFile;
      try {
        final dir = await getTemporaryDirectory();
        targetFile = File('${dir.path}/$fileName');
        file = targetFile;
        if (await targetFile.exists()) {
          await targetFile.delete();
        }
      } on FileSystemException catch (e) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.write,
            '无法创建下载文件',
            detail: e.message,
          ),
        );
      }

      // 4) 流式下载 + 写盘
      final IOSink writer;
      try {
        writer = targetFile.openWrite();
        sink = writer;
      } on FileSystemException catch (e) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.write,
            '无法写入下载文件',
            detail: e.message,
          ),
        );
      }

      final contentLength = response.contentLength;
      var downloadedBytes = 0;

      try {
        await for (final chunk in response.stream) {
          if (isCancelled()) {
            return DownloadResult.failed(
              const DownloadFailure(DownloadFailureKind.cancelled, '下载已取消'),
            );
          }

          writer.add(chunk);
          downloadedBytes += chunk.length;

          if (contentLength != null && contentLength > 0) {
            onProgress(downloadedBytes / contentLength);
          }
        }

        await writer.flush();
        await writer.close();
        sink = null;
      } on FileSystemException catch (e) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.write,
            '写入下载文件失败（可能是磁盘空间不足或权限问题）',
            detail: e.message,
          ),
        );
      } on TimeoutException catch (e) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.timeout,
            '下载数据读取超时',
            detail: e.toString(),
          ),
        );
      } on http.ClientException catch (e) {
        return DownloadResult.failed(
          DownloadFailure(
            DownloadFailureKind.network,
            '下载过程中网络中断',
            detail: e.message,
          ),
        );
      }

      success = true;
      onProgress(1.0);
      return DownloadResult.success(targetFile.path);
    } catch (e) {
      debugPrint('下载失败: $e');
      return DownloadResult.failed(
        DownloadFailure(DownloadFailureKind.unknown, '下载失败：$e'),
      );
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }

      // 失败时清理半成品文件，避免下次安装到损坏的包
      if (!success && file != null) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }
    }
  }
}
