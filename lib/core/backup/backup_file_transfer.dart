import 'dart:io';

import 'package:flutter/services.dart';

import '../errors/app_exception.dart';

/// Moves already-encrypted backup containers across the Android Storage
/// Access Framework boundary. This adapter never receives a recovery password.
///
/// With `preferGoogleDrive` the platform opens Google Drive's upload screen
/// (or the system share sheet); a `true` result only means that screen opened,
/// because Android does not report whether the upload later completes.
abstract interface class BackupFileTransfer {
  Future<bool> export(
    File source, {
    String? suggestedName,
    bool preferGoogleDrive = false,
  });
  Future<File?> import();
}

final class AndroidBackupFileTransfer implements BackupFileTransfer {
  const AndroidBackupFileTransfer();

  static const _channel = MethodChannel('com.jibi.jibi/backup_file_transfer');

  @override
  Future<bool> export(
    File source, {
    String? suggestedName,
    bool preferGoogleDrive = false,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('exportBackup', {
            'sourcePath': source.path,
            'suggestedName': suggestedName ?? source.uri.pathSegments.last,
            'preferGoogleDrive': preferGoogleDrive,
          }) ??
          false;
    } on MissingPluginException catch (error) {
      throw BackupException(
        code: 'backup_export_unavailable',
        userMessage: 'تصدير النسخة غير متاح على هذا الجهاز.',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw BackupException(
        code: 'backup_export_failed',
        userMessage: switch (error.code) {
          'no_share_target' =>
            'لا يوجد تطبيق يستقبل الملف. ثبّت Google Drive أو استخدم «نسخ احتياطي على الجهاز».',
          'backup_share_prepare_failed' =>
            'تعذر تجهيز ملف النسخة للمشاركة. تحقق من مساحة التخزين.',
          _ => 'تعذر تصدير النسخة الاحتياطية.',
        },
        cause: error,
      );
    }
  }

  @override
  Future<File?> import() async {
    try {
      final path = await _channel.invokeMethod<String>('importBackup');
      return path == null ? null : File(path);
    } on MissingPluginException catch (error) {
      throw BackupException(
        code: 'backup_import_unavailable',
        userMessage: 'استيراد النسخة غير متاح على هذا الجهاز.',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw BackupException(
        code: 'backup_import_failed',
        userMessage: 'تعذر استيراد النسخة الاحتياطية.',
        cause: error,
      );
    }
  }
}
