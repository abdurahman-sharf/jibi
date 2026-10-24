import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_jibi_repository.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';

void main() {
  late Directory sandbox;
  late AppDatabase appDatabase;
  late SqliteJibiRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    sandbox = Directory('test${Platform.pathSeparator}_settings_parsing_test');
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
    await sandbox.create(recursive: true);
    appDatabase = AppDatabase(
      path: File(
        '${sandbox.path}${Platform.pathSeparator}database.sqlite',
      ).absolute.path,
    );
    repository = SqliteJibiRepository(appDatabase);
  });

  tearDown(() async {
    await repository.dispose();
    await appDatabase.close();
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  Future<void> writeRaw(String json) async {
    final database = await appDatabase.database;
    await database.insert('app_settings', <String, Object?>{
      'key': 'settings_v1',
      'value': json,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  test('reads a row written by an older build that still has wifi key', () async {
    await writeRaw(
      jsonEncode(<String, Object>{
        'defaultCurrencyCode': 'usd',
        'localeCode': 'ar',
        'themePreference': 'dark',
        'autoLockDuration': 'fiveMinutes',
        'biometricsEnabled': true,
        'screenshotProtectionEnabled': false,
        'clipboardClearAfterMs': 45000,
        'backupSchedule': 'weekly',
        'backupOnWifiOnly': true,
        'backupRetentionCount': 7,
      }),
    );

    final settings = await repository.read();

    expect(settings.defaultCurrencyCode, 'USD');
    expect(settings.themePreference, AppThemePreference.dark);
    expect(settings.autoLockDuration, AutoLockDuration.fiveMinutes);
    expect(settings.biometricsEnabled, isTrue);
    expect(settings.screenshotProtectionEnabled, isFalse);
    expect(settings.clipboardClearAfter, const Duration(seconds: 45));
    expect(settings.backupSchedule, BackupSchedule.weekly);
    expect(settings.backupRetentionCount, 7);
    expect(
      settings.autoBackupOnUnlock,
      isTrue,
      reason: 'rows from older builds get the default of the new setting',
    );
  });

  test('automatic backup on unlock round-trips through save and read', () async {
    await repository.save(
      AppSettings(defaultCurrencyCode: 'SAR', autoBackupOnUnlock: false),
    );

    expect((await repository.read()).autoBackupOnUnlock, isFalse);
  });

  test('missing or malformed keys fall back to defaults', () async {
    await writeRaw(
      jsonEncode(<String, Object>{
        'defaultCurrencyCode': 'SAR',
        'themePreference': 'neon',
        'biometricsEnabled': 'yes',
        'clipboardClearAfterMs': -5,
        'backupRetentionCount': 0,
      }),
    );

    final settings = await repository.read();
    final defaults = AppSettings(defaultCurrencyCode: 'SAR');

    expect(settings.defaultCurrencyCode, 'SAR');
    expect(settings.localeCode, defaults.localeCode);
    expect(settings.themePreference, defaults.themePreference);
    expect(settings.autoLockDuration, defaults.autoLockDuration);
    expect(settings.biometricsEnabled, defaults.biometricsEnabled);
    expect(settings.clipboardClearAfter, defaults.clipboardClearAfter);
    expect(settings.backupSchedule, defaults.backupSchedule);
    expect(settings.backupRetentionCount, defaults.backupRetentionCount);
  });

  test('unreadable JSON still surfaces invalid_settings', () async {
    await writeRaw('not json');

    expect(repository.read(), throwsA(isA<StorageException>()));
  });

  test('save no longer persists the retired wifi-only key', () async {
    await repository.save(AppSettings(defaultCurrencyCode: 'SAR'));

    final database = await appDatabase.database;
    final rows = await database.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['settings_v1'],
    );
    final stored = jsonDecode(rows.single['value']! as String) as Map;
    expect(stored.containsKey('backupOnWifiOnly'), isFalse);
  });
}
