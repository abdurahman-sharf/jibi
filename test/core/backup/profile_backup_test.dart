import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/backup/encrypted_local_backup_service.dart';
import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_jibi_repository.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/security/security.dart';

import '../../support/memory_keys.dart' show MemoryKeys, NoBiometrics;

/// A 1x1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// المتطلبات 60: the backup carries the user data and the settings.
void main() {
  late Directory sandbox;
  late AppDatabase appDatabase;
  late SqliteJibiRepository repository;
  late AesGcmSecurityService security;
  late EncryptedLocalBackupService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_profile_backup_');
    appDatabase = AppDatabase(
      path: '${sandbox.path}${Platform.pathSeparator}database.sqlite',
    );
    repository = SqliteJibiRepository(appDatabase);
    security = AesGcmSecurityService(
      keyStore: MemoryKeys(),
      biometricAuthenticator: NoBiometrics(),
    );
    await security.initialize(pin: '123456');
    service = EncryptedLocalBackupService(
      database: appDatabase,
      securityService: security,
      encryptedFilesDirectory: Directory(
        '${sandbox.path}${Platform.pathSeparator}encrypted',
      ),
      rollbackDirectory: Directory(
        '${sandbox.path}${Platform.pathSeparator}rollbacks',
      ),
      clock: () => DateTime.utc(2026, 9, 20),
    );
  });

  tearDown(() async {
    await repository.dispose();
    await appDatabase.close();
    try {
      await sandbox.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps SQLite handles briefly after close; data already checked.
    }
  });

  test('the profile and the display preferences come back after a restore',
      () async {
    await repository.save(
      AppSettings(
        defaultCurrencyCode: 'YER',
        dateFormat: DateDisplayFormat.dayMonthYearDash,
        hideBalances: true,
        showTransactionTime: false,
        newestFirst: false,
        confirmBeforeDelete: false,
        defaultEntryType: EntryType.credit,
        debitLabel: 'مستحق لي',
        creditLabel: 'مستحق علي',
      ),
    );
    await repository.saveUserProfile(
      UserProfile.validated(
        nameAr: 'عبدالرحمن شرف',
        nameEn: 'Abdulrahman Sharaf',
        addressAr: 'صنعاء',
        phone: '777123456',
        email: 'a@example.com',
        logo: _png,
        signature: _png,
        stamp: _png,
        showStamp: false,
      ),
    );
    final backup = File('${sandbox.path}${Platform.pathSeparator}profile.jibi');
    await service.createLocalBackup(
      destination: backup,
      recoveryPassword: '123456',
    );

    // Everything is lost or changed afterwards.
    await repository.save(AppSettings(defaultCurrencyCode: 'SAR'));
    await repository.saveUserProfile(UserProfile.empty);
    expect((await repository.readUserProfile()).isBlank, isTrue);

    await service.restoreLocalBackup(
      source: backup,
      recoveryPassword: '123456',
    );

    final profile = await repository.readUserProfile();
    expect(profile.nameAr, 'عبدالرحمن شرف');
    expect(profile.nameEn, 'Abdulrahman Sharaf');
    expect(profile.addressAr, 'صنعاء');
    expect(profile.phone, '777123456');
    expect(profile.email, 'a@example.com');
    expect(profile.logo, _png);
    expect(profile.signature, _png);
    expect(profile.stamp, _png);
    expect(profile.showStamp, isFalse);

    final settings = await repository.read();
    expect(settings.defaultCurrencyCode, 'YER');
    expect(settings.dateFormat, DateDisplayFormat.dayMonthYearDash);
    expect(settings.hideBalances, isTrue);
    expect(settings.showTransactionTime, isFalse);
    expect(settings.newestFirst, isFalse);
    expect(settings.confirmBeforeDelete, isFalse);
    expect(settings.defaultEntryType, EntryType.credit);
    expect(settings.debitLabel, 'مستحق لي');
    expect(settings.creditLabel, 'مستحق علي');
  });

  test('the backup file does not show the profile in plain text', () async {
    await repository.saveUserProfile(
      UserProfile.validated(
        nameAr: 'اسم-سري-للاختبار',
        phone: '777987654',
        email: 'secret-mail@example.com',
        signature: _png,
      ),
    );
    final backup = File('${sandbox.path}${Platform.pathSeparator}secret.jibi');

    await service.createLocalBackup(
      destination: backup,
      recoveryPassword: '123456',
    );

    final raw = latin1.decode(await backup.readAsBytes(), allowInvalid: true);
    expect(raw, isNot(contains('secret-mail@example.com')));
    expect(raw, isNot(contains('777987654')));
    expect(raw, isNot(contains(base64Encode(_png))));
  });

  test('a backup made before the profile existed restores with no profile',
      () async {
    await repository.save(AppSettings(defaultCurrencyCode: 'YER'));
    final backup = File('${sandbox.path}${Platform.pathSeparator}old.jibi');
    await service.createLocalBackup(
      destination: backup,
      recoveryPassword: '123456',
    );
    await repository.saveUserProfile(UserProfile.validated(nameAr: 'لاحقاً'));

    await service.restoreLocalBackup(
      source: backup,
      recoveryPassword: '123456',
    );

    expect((await repository.readUserProfile()).isBlank, isTrue);
    expect((await repository.read()).defaultCurrencyCode, 'YER');
  });
}
