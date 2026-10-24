import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_jibi_repository.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';

/// A 1x1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  late Directory sandbox;
  late AppDatabase appDatabase;
  late SqliteJibiRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    sandbox = Directory(
      'test${Platform.pathSeparator}_profile_persistence_test',
    );
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
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
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<void> writeRaw(String key, String json) async {
    final database = await appDatabase.database;
    await database.insert('app_settings', <String, Object?>{
      'key': key,
      'value': json,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  group('preferences in the settings row', () {
    test('a row written before this version reads with the defaults', () async {
      await writeRaw(
        'settings_v1',
        jsonEncode(<String, Object>{
          'defaultCurrencyCode': 'SAR',
          'themePreference': 'dark',
        }),
      );

      final settings = await repository.read();

      expect(settings.themePreference, AppThemePreference.dark);
      expect(settings.dateFormat, DateDisplayFormat.yearMonthDay);
      expect(settings.showTransactionTime, isTrue);
      expect(settings.hideBalances, isFalse);
      expect(settings.newestFirst, isTrue);
      expect(settings.confirmBeforeDelete, isTrue);
      expect(settings.defaultEntryType, EntryType.debit);
      expect(settings.debitLabel, isNull);
      expect(settings.creditLabel, isNull);
    });

    test('every preference survives a save and a read', () async {
      await repository.save(
        AppSettings(
          defaultCurrencyCode: 'YER',
          dateFormat: DateDisplayFormat.dayMonthYearSlash,
          showTransactionTime: false,
          hideBalances: true,
          newestFirst: false,
          confirmBeforeDelete: false,
          defaultEntryType: EntryType.credit,
          debitLabel: 'مستحق لي',
          creditLabel: 'مستحق علي',
        ),
      );

      final settings = await repository.read();

      expect(settings.dateFormat, DateDisplayFormat.dayMonthYearSlash);
      expect(settings.showTransactionTime, isFalse);
      expect(settings.hideBalances, isTrue);
      expect(settings.newestFirst, isFalse);
      expect(settings.confirmBeforeDelete, isFalse);
      expect(settings.defaultEntryType, EntryType.credit);
      expect(settings.debitLabel, 'مستحق لي');
      expect(settings.creditLabel, 'مستحق علي');
    });

    test('cleared wording is not stored', () async {
      await repository.save(
        AppSettings(defaultCurrencyCode: 'YER', debitLabel: 'لي'),
      );
      await repository.save(
        (await repository.read()).withSideLabels(),
      );

      final settings = await repository.read();

      expect(settings.debitLabel, isNull);
    });

    test('damaged values fall back to defaults instead of blocking startup',
        () async {
      await writeRaw(
        'settings_v1',
        jsonEncode(<String, Object>{
          'defaultCurrencyCode': 'YER',
          'dateFormat': 'nonsense',
          'defaultEntryType': 7,
          'hideBalances': 'yes',
          'debitLabel': 'سلف',
          'creditLabel': 'سلف', // equal to the other side: not usable
        }),
      );

      final settings = await repository.read();

      expect(settings.dateFormat, DateDisplayFormat.yearMonthDay);
      expect(settings.defaultEntryType, EntryType.debit);
      expect(settings.hideBalances, isFalse);
      expect(settings.debitLabel, isNull);
      expect(settings.creditLabel, isNull);
    });
  });

  group('user profile', () {
    test('is empty before anything is saved', () async {
      final profile = await repository.readUserProfile();

      expect(profile.isBlank, isTrue);
      expect(profile.showLogo, isTrue);
    });

    test('keeps every field and the three pictures', () async {
      await repository.saveUserProfile(
        UserProfile.validated(
          nameAr: 'عبدالرحمن شرف',
          nameEn: 'Abdulrahman Sharaf',
          addressAr: 'صنعاء',
          addressEn: 'Sanaa',
          phone: '+967 777 123 456',
          email: 'a@example.com',
          logo: _png,
          signature: _png,
          stamp: _png,
          showSignature: false,
        ),
      );

      final profile = await repository.readUserProfile();

      expect(profile.nameAr, 'عبدالرحمن شرف');
      expect(profile.nameEn, 'Abdulrahman Sharaf');
      expect(profile.addressAr, 'صنعاء');
      expect(profile.addressEn, 'Sanaa');
      expect(profile.phone, '+967 777 123 456');
      expect(profile.email, 'a@example.com');
      expect(profile.logo, _png);
      expect(profile.signature, _png);
      expect(profile.stamp, _png);
      expect(profile.showLogo, isTrue);
      expect(profile.showSignature, isFalse);
      expect(profile.showStamp, isTrue);
    });

    test('a later save replaces the earlier one, pictures included', () async {
      await repository.saveUserProfile(
        UserProfile.validated(nameAr: 'الأول', logo: _png),
      );
      await repository.saveUserProfile(
        UserProfile.validated(nameAr: 'الثاني'),
      );

      final profile = await repository.readUserProfile();

      expect(profile.nameAr, 'الثاني');
      expect(profile.logo, isNull);
    });

    test('lives beside the settings without touching them', () async {
      await repository.save(AppSettings(defaultCurrencyCode: 'SAR'));
      await repository.saveUserProfile(UserProfile.validated(nameAr: 'أنا'));

      expect((await repository.read()).defaultCurrencyCode, 'SAR');
      expect((await repository.readUserProfile()).nameAr, 'أنا');
    });

    test('a damaged row reads as an empty profile', () async {
      await writeRaw('user_profile_v1', '{not json');
      expect((await repository.readUserProfile()).isBlank, isTrue);

      await writeRaw('user_profile_v1', '[1,2]');
      expect((await repository.readUserProfile()).isBlank, isTrue);

      await writeRaw(
        'user_profile_v1',
        jsonEncode(<String, Object>{
          'nameAr': 'سليم',
          'email': 'not-an-email',
          'logo': '***not base64***',
        }),
      );
      // One bad field must not lose the rest: the whole row is refused and the
      // profile is empty rather than half-valid.
      expect((await repository.readUserProfile()).isBlank, isTrue);
    });
  });

  group('UserProfile.validated', () {
    test('trims and turns blank into null', () {
      final profile = UserProfile.validated(
        nameAr: '  اسم  ',
        nameEn: '   ',
        phone: '',
      );

      expect(profile.nameAr, 'اسم');
      expect(profile.nameEn, isNull);
      expect(profile.phone, isNull);
      expect(profile.displayName, 'اسم');
    });

    test('shows the English name when there is no Arabic one', () {
      expect(UserProfile.validated(nameEn: 'Ali').displayName, 'Ali');
    });

    test('refuses a bad e-mail, a bad phone and too-long text', () {
      void refuses(UserProfile Function() build, String code) => expect(
        build,
        throwsA(
          isA<ValidationException>().having((e) => e.code, 'code', code),
        ),
      );

      refuses(() => UserProfile.validated(email: 'no-at-sign'), 'invalid_email');
      refuses(() => UserProfile.validated(phone: 'call me'), 'invalid_phone');
      refuses(
        () => UserProfile.validated(nameAr: 'أ' * 81),
        'profile_field_too_long',
      );
      refuses(
        () => UserProfile.validated(logo: Uint8List(maxProfileImageBytes + 1)),
        'profile_image_too_large',
      );
    });

    test('accepts Arabic-Indic digits and common phone punctuation', () {
      expect(UserProfile.validated(phone: '(٠٠٩٦٧) 777-123').phone, isNotNull);
    });
  });
}
