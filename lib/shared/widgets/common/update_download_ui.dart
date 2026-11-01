import 'dart:io';

import 'package:astral/core/services/update_downloader.dart';
import 'package:astral/core/ui/app_snack_bars.dart';
import 'package:astral/shared/widgets/common/update_dialogs.dart';
import 'package:flutter/material.dart';

/// 更新下载 UI 编排（对话框 / SnackBar）
class UpdateDownloadUi {
  const UpdateDownloadUi._();

  static Future<void> handleDownload(
    BuildContext context,
    Map<String, dynamic> releaseInfo,
    UpdateDownloader downloader,
  ) async {
    if (!context.mounted) return;

    if (Platform.isAndroid) {
      showArchitectureSelectionDialog(
        context: context,
        onSelected: (fileName) {
          startDownload(context, releaseInfo, fileName, downloader);
        },
      );
      return;
    }

    final downloadUrl = downloader.getDownloadUrl(releaseInfo);
    if (downloadUrl == null) {
      AppSnackBars.error(context, '下载失败', '未找到当前平台的安装包');
      return;
    }

    final fileName = downloader.getPlatformFileName();
    if (fileName.isEmpty) {
      AppSnackBars.error(context, '下载失败', '当前平台暂不支持内置下载安装');
      return;
    }

    await _showDownloadDialog(
      context: context,
      downloader: downloader,
      downloadUrl: downloadUrl,
      fileName: fileName,
    );
  }

  static Future<void> startDownload(
    BuildContext context,
    Map<String, dynamic> releaseInfo,
    String fileName,
    UpdateDownloader downloader,
  ) async {
    if (!context.mounted) return;

    final downloadUrl = downloader.getDownloadUrlForFile(releaseInfo, fileName);
    if (downloadUrl == null) {
      AppSnackBars.error(context, '下载失败', '未找到 $fileName 的下载链接');
      return;
    }

    await _showDownloadDialog(
      context: context,
      downloader: downloader,
      downloadUrl: downloadUrl,
      fileName: fileName,
    );
  }

  /// 立刻弹出进度框，测速/选线路也在框内展示，避免「点了没反应」。
  static Future<void> _showDownloadDialog({
    required BuildContext context,
    required UpdateDownloader downloader,
    required String downloadUrl,
    required String fileName,
  }) async {
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => DownloadProgressDialog(
            fileName: fileName,
            onWork: (onStatus, onProgress, isCancelled) async {
              onStatus('正在选择下载线路…');
              onProgress(null);

              final acceleratedUrl = await downloader.resolveAcceleratedUrl(
                downloadUrl,
              );
              // #214：onWork 现在返回 DownloadResult，取消也要给出明确的失败类型，
              // 不能返回 null（否则与 DownloadProgressDialog 的新签名不兼容）。
              if (isCancelled()) {
                return const DownloadResult.failed(
                  DownloadFailure(DownloadFailureKind.cancelled, '下载已取消'),
                );
              }

              onStatus('正在下载更新…');
              onProgress(0);

              return downloader.downloadFile(
                acceleratedUrl,
                fileName,
                (progress) => onProgress(progress),
                isCancelled,
              );
            },
          ),
    );
  }
}
