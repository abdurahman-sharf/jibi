import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/backup/encrypted_local_backup_service.dart';
import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';
import 'package:jibi/features/book/book.dart';

import '../../support/memory_keys.dart' show MemoryKeys, NoBiometrics;
import '../../support/test_currencies.dart';
import '../../support/book_wallets.dart';

void main() {
  late Directory sandbox;
  late AppDatabase appDatabase;
  late SqliteBookRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_book_backup_');
    appDatabase = AppDatabase(
      path: '${sandbox.path}${Platform.pathSeparator}database.sqlite',
    );
    repository = SqliteBookRepository(appDatabase);
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

  test(
    'a backup carries the book, its attachment files and restores them',
    () async {
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: NoBiometrics(),
      );
      await security.initialize(pin: '123456');
      final encrypted = Directory(
        '${sandbox.path}${Platform.pathSeparator}encrypted',
      );
      final storage = FileSystemSecureFileStorage(
        encryptedDirectory: encrypted,
        temporaryDirectory: Directory(
          '${sandbox.path}${Platform.pathSeparator}temporary',
        ),
        securityService: security,
      );
      final book = BookServices(
        repository: repository,
        currencies: testCurrencyRegistry(),
        defaultCurrencyCode: () => 'SAR',
        attachments: BookAttachmentsController(
          repository: repository,
          storage: storage,
        ),
      );

      final category = await book.categories.create(
        const BookCategoryDraft(name: 'حسابات اليمن'),
      );
      final account = await book.accounts.create(
        BookAccountDraft.single(
          categoryId: category.id,
          name: 'علي أخي',
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
          date: '2024-12-13',
          details: 'يوم موت أبي علي',
        ),
      );
      final plaintext = Uint8List.fromList(
        List<int>.generate(2048, (index) => index % 251),
      );
      final source = File('${sandbox.path}${Platform.pathSeparator}voucher.jpg');
      await source.writeAsBytes(plaintext);
      final attachment = await book.attachments!.add(
        transactionId: transaction.id,
        request: FileImportRequest(
          sourceFile: source,
          originalExtension: 'jpg',
          mimeType: 'image/jpeg',
        ),
        kind: BookAttachmentKind.voucher,
      );
      final encryptedFile = File(
        '${encrypted.path}${Platform.pathSeparator}${attachment.encryptedFileName}',
      );
      expect(await encryptedFile.exists(), isTrue);

      final service = EncryptedLocalBackupService(
        database: appDatabase,
        securityService: security,
        encryptedFilesDirectory: encrypted,
        rollbackDirectory: Directory(
          '${sandbox.path}${Platform.pathSeparator}rollbacks',
        ),
        clock: () => DateTime.utc(2026, 9, 20),
      );
      final backup = File('${sandbox.path}${Platform.pathSeparator}book.jibi');
      final descriptor = await service.createLocalBackup(
        destination: backup,
        recoveryPassword: '123456',
      );
      // The manifest counts book accounts and every encrypted file.
      expect(descriptor.manifest.numberOfAccounts, 1);
      expect(descriptor.manifest.numberOfAttachments, 1);

      // Lose the attachment (row and encrypted file), then restore.
      await book.attachments!.remove(attachment.id);
      expect(await encryptedFile.exists(), isFalse);
      expect((await book.transactions.find(transaction.id))!.attachments, isEmpty);

      await service.restoreLocalBackup(
        source: backup,
        recoveryPassword: '123456',
      );

      final restored = (await book.transactions.find(transaction.id))!;
      expect(restored.details, 'يوم موت أبي علي');
      expect(restored.balanceAfter, 30000);
      expect(restored.attachments.single.kind, BookAttachmentKind.voucher);
      expect(await encryptedFile.exists(), isTrue);
      final handle = await book.attachments!.open(restored.attachments.single);
      expect(await handle.file.readAsBytes(), plaintext);
      await handle.delete();
      expect(await repository.countBalanceMismatches(account.id), 0);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a missing attachment file is caught when the backup is made', () async {
    final security = AesGcmSecurityService(
      keyStore: MemoryKeys(),
      biometricAuthenticator: NoBiometrics(),
    );
    await security.initialize(pin: '123456');
    final encrypted = Directory(
      '${sandbox.path}${Platform.pathSeparator}encrypted',
    );
    final storage = FileSystemSecureFileStorage(
      encryptedDirectory: encrypted,
      temporaryDirectory: Directory(
        '${sandbox.path}${Platform.pathSeparator}temporary',
      ),
      securityService: security,
    );
    final book = BookServices(
      repository: repository,
      currencies: testCurrencyRegistry(),
      defaultCurrencyCode: () => 'SAR',
      attachments: BookAttachmentsController(
        repository: repository,
        storage: storage,
      ),
    );
    final category = await book.categories.create(
      const BookCategoryDraft(name: 'تصنيف'),
    );
    final account = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'حساب',
        currencyCode: 'YER',
      ),
    );
    final transaction = await book.transactions.create(
      BookTransactionDraft(
        accountId: account.id,
        currencyCode: 'YER',
        walletId: seededMainWalletId,
        type: EntryType.debit,
        amountMinor: 5,
        date: '2025-01-01',
      ),
    );
    final source = File('${sandbox.path}${Platform.pathSeparator}a.pdf');
    await source.writeAsBytes(Uint8List.fromList([1, 2, 3]));
    final attachment = await book.attachments!.add(
      transactionId: transaction.id,
      request: FileImportRequest(
        sourceFile: source,
        originalExtension: 'pdf',
        mimeType: 'application/pdf',
      ),
    );
    await File(
      '${encrypted.path}${Platform.pathSeparator}${attachment.encryptedFileName}',
    ).delete();

    final service = EncryptedLocalBackupService(
      database: appDatabase,
      securityService: security,
      encryptedFilesDirectory: encrypted,
    );
    await expectLater(
      service.createLocalBackup(
        destination: File('${sandbox.path}${Platform.pathSeparator}x.jibi'),
        recoveryPassword: '123456',
      ),
      throwsA(anything),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
