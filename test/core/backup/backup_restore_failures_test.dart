import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/backup/encrypted_local_backup_service.dart';
import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';
import 'package:jibi/features/book/book.dart';

import '../../support/memory_keys.dart' show MemoryKeys, NoBiometrics;
import '../../support/test_currencies.dart';
import '../../support/book_wallets.dart';

/// Every way a restore can be refused must leave the current data alone and
/// say why, so a damaged or wrong file never costs the user their book.
void main() {
  late Directory sandbox;
  late AppDatabase appDatabase;
  late SqliteBookRepository repository;
  late EncryptedLocalBackupService service;
  late BookServices book;
  late File good;
  late String transactionId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  String path(String name) => '${sandbox.path}${Platform.pathSeparator}$name';

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_restore_fail_');
    appDatabase = AppDatabase(path: path('database.sqlite'));
    repository = SqliteBookRepository(appDatabase);
    final security = AesGcmSecurityService(
      keyStore: MemoryKeys(),
      biometricAuthenticator: NoBiometrics(),
    );
    await security.initialize(pin: '123456');
    final encrypted = Directory(path('encrypted'));
    final storage = FileSystemSecureFileStorage(
      encryptedDirectory: encrypted,
      temporaryDirectory: Directory(path('temporary')),
      securityService: security,
    );
    book = BookServices(
      repository: repository,
      currencies: testCurrencyRegistry(),
      defaultCurrencyCode: () => 'SAR',
      attachments: BookAttachmentsController(
        repository: repository,
        storage: storage,
      ),
    );
    final category = await book.categories.create(
      const BookCategoryDraft(name: 'حسابات'),
    );
    final account = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'علي',
        currencyCode: 'YER',
      ),
    );
    final transaction = await book.transactions.create(
      BookTransactionDraft(
        accountId: account.id,
        currencyCode: 'YER',
        walletId: seededMainWalletId,
        type: EntryType.debit,
        amountMinor: 30000,
        date: '2026-09-21',
        details: 'قبل الاستعادة',
      ),
    );
    transactionId = transaction.id;
    service = EncryptedLocalBackupService(
      database: appDatabase,
      securityService: security,
      encryptedFilesDirectory: encrypted,
      rollbackDirectory: Directory(path('rollbacks')),
      clock: () => DateTime.utc(2026, 9, 21),
    );
    good = File(path('good.jibi'));
    await service.createLocalBackup(
      destination: good,
      recoveryPassword: '123456',
    );
  });

  tearDown(() async {
    await repository.dispose();
    await appDatabase.close();
    try {
      await sandbox.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps SQLite handles briefly after close.
    }
  });

  Future<void> expectRefused(
    File source, {
    String password = '123456',
    required String code,
  }) async {
    await expectLater(
      service.restoreLocalBackup(source: source, recoveryPassword: password),
      throwsA(
        isA<AppException>().having((error) => error.code, 'code', code),
      ),
    );
    // Nothing was touched: the book is still there and still readable.
    final still = await book.transactions.find(transactionId);
    expect(still, isNotNull);
    expect(still!.details, 'قبل الاستعادة');
  }

  test('a wrong PIN is refused and the book is untouched', () async {
    await expectRefused(good, password: '654321', code: 'backup_authentication_failed');
  });

  test('a PIN that is not six digits is refused before any work', () async {
    await expectRefused(good, password: '12', code: 'invalid_backup_pin');
  });

  test('a file that is not a backup is refused', () async {
    final garbage = File(path('garbage.jibi'));
    await garbage.writeAsBytes(
      Uint8List.fromList(List<int>.generate(300, (index) => (index * 7) % 256)),
    );
    await expectRefused(garbage, code: 'backup_unreadable');
  });

  test('an empty file is refused', () async {
    final empty = File(path('empty.jibi'));
    await empty.writeAsBytes(Uint8List(0));
    await expectRefused(empty, code: 'backup_unreadable');
  });

  test('a truncated backup (an interrupted download) is refused', () async {
    final bytes = await good.readAsBytes();
    final truncated = File(path('truncated.jibi'));
    await truncated.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));
    await expectRefused(truncated, code: 'backup_authentication_failed');
  });

  test('a backup that is only its header is refused', () async {
    final bytes = await good.readAsBytes();
    // magic + length prefix + header, no ciphertext at all.
    final headerLength = ByteData.sublistView(
      bytes.sublist(15, 19),
    ).getUint32(0, Endian.big);
    final headerOnly = File(path('header_only.jibi'));
    await headerOnly.writeAsBytes(bytes.sublist(0, 19 + headerLength));
    await expectRefused(headerOnly, code: 'backup_unreadable');
  });

  test('a backup written by a newer app version is refused', () async {
    final bytes = await good.readAsBytes();
    const magicLength = 15; // 'JIBI_BACKUP_V1\n'
    final headerLength = ByteData.sublistView(
      bytes.sublist(magicLength, magicLength + 4),
    ).getUint32(0, Endian.big);
    final headerStart = magicLength + 4;
    final header =
        jsonDecode(
              utf8.decode(bytes.sublist(headerStart, headerStart + headerLength)),
            )
            as Map<String, Object?>;
    (header['manifest']! as Map<String, Object?>)['databaseSchemaVersion'] =
        AppDatabase.schemaVersion + 1;
    final newHeader = utf8.encode(jsonEncode(header));
    final prefix = ByteData(4)..setUint32(0, newHeader.length, Endian.big);
    final forged = File(path('from_the_future.jibi'));
    await forged.writeAsBytes(<int>[
      ...bytes.sublist(0, magicLength),
      ...prefix.buffer.asUint8List(),
      ...newHeader,
      ...bytes.sublist(headerStart + headerLength),
    ]);

    await expectRefused(forged, code: 'unsupported_backup_version');
  });

  test('inspecting a backup reports its manifest without a PIN', () async {
    final manifest = await service.inspect(good);
    expect(manifest.databaseSchemaVersion, AppDatabase.schemaVersion);
    expect(manifest.numberOfAccounts, 1);
  });
}
