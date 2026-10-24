import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/backup/backup_file_transfer.dart';
import 'package:jibi/core/errors/app_exception.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.jibi.jibi/backup_file_transfer');
  const transfer = AndroidBackupFileTransfer();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('exports only the encrypted file path and suggested name', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });

    final exported = await transfer.export(File('/private/jibi_backup_1.jibi'));

    expect(exported, isTrue);
    expect(received?.method, 'exportBackup');
    expect(received?.arguments, {
      'sourcePath': '/private/jibi_backup_1.jibi',
      'suggestedName': 'jibi_backup_1.jibi',
      'preferGoogleDrive': false,
    });
  });

  test('forwards preferGoogleDrive to the native share sheet', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });

    final exported = await transfer.export(
      File('/private/jibi_backup_1.jibi'),
      suggestedName: 'Jibi_Backup_2026-09-14_1830.zip',
      preferGoogleDrive: true,
    );

    expect(exported, isTrue);
    expect(received?.method, 'exportBackup');
    expect(received?.arguments, {
      'sourcePath': '/private/jibi_backup_1.jibi',
      'suggestedName': 'Jibi_Backup_2026-09-14_1830.zip',
      'preferGoogleDrive': true,
    });
  });

  test('can suggest a SAF zip file name', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });

    final exported = await transfer.export(
      File('/private/jibi_backup_1.jibi'),
      suggestedName: 'Jibi_Backup_2026-09-14_1830.zip',
    );

    expect(exported, isTrue);
    expect(received?.arguments, {
      'sourcePath': '/private/jibi_backup_1.jibi',
      'suggestedName': 'Jibi_Backup_2026-09-14_1830.zip',
      'preferGoogleDrive': false,
    });
  });

  test(
    'returns imported cache file and preserves picker cancellation',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'importBackup' ? '/cache/restore.jibi' : null,
      );
      expect((await transfer.import())?.path, '/cache/restore.jibi');

      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await transfer.import(), isNull);
    },
  );

  test('maps native share failures to specific Arabic messages', () async {
    final expected = <String, String>{
      'no_share_target':
          'لا يوجد تطبيق يستقبل الملف. ثبّت Google Drive أو استخدم «نسخ احتياطي على الجهاز».',
      'backup_share_prepare_failed':
          'تعذر تجهيز ملف النسخة للمشاركة. تحقق من مساحة التخزين.',
      'backup_share_failed': 'تعذر تصدير النسخة الاحتياطية.',
    };
    for (final entry in expected.entries) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => throw PlatformException(code: entry.key),
          );

      await expectLater(
        transfer.export(File('/private/a.jibi'), preferGoogleDrive: true),
        throwsA(
          isA<BackupException>().having(
            (error) => error.userMessage,
            entry.key,
            entry.value,
          ),
        ),
      );
    }
  });
}
