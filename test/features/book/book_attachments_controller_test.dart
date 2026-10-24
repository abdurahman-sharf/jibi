import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/book_repository.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';
import 'package:jibi/features/book/book.dart';

import '../../support/fake_secure_storage.dart';
import '../../support/test_currencies.dart';
import '../../support/book_wallets.dart';

/// Lets a test make the database write fail after a file was encrypted.
class _FlakyRepository extends InMemoryBookRepository {
  bool failWrites = false;

  @override
  Future<T> write<T>(Future<T> Function(BookWriter writer) action) {
    if (failWrites) {
      return Future<T>.error(StateError('disk full'));
    }
    return super.write(action);
  }
}

void main() {
  late Directory sandbox;
  late _FlakyRepository repository;
  late FakeSecureFileStorage storage;
  late BookServices book;
  late BookTransaction transaction;

  FileImportRequest request(
    List<int> bytes, {
    String extension = 'jpg',
    String mime = 'image/jpeg',
  }) {
    final file = File(
      '${sandbox.path}${Platform.pathSeparator}src-${DateTime.now().microsecondsSinceEpoch}.$extension',
    )..writeAsBytesSync(bytes);
    return FileImportRequest(
      sourceFile: file,
      originalExtension: extension,
      mimeType: mime,
    );
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_attachments_');
    repository = _FlakyRepository();
    await seedMainWallet(repository);
    storage = FakeSecureFileStorage(
      Directory('${sandbox.path}${Platform.pathSeparator}temporary'),
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
      const BookCategoryDraft(name: 'تصنيف'),
    );
    final account = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'حساب',
        currencyCode: 'YER',
      ),
    );
    transaction = await book.transactions.create(
      BookTransactionDraft(
        accountId: account.id,
        currencyCode: 'YER',
        walletId: seededMainWalletId,
        type: EntryType.debit,
        amountMinor: 100,
        date: '2025-01-01',
      ),
    );
  });

  tearDown(() async {
    await repository.dispose();
    await sandbox.delete(recursive: true);
  });

  test('an image is encrypted and attached with its kind and size', () async {
    final added = await book.attachments!.add(
      transactionId: transaction.id,
      request: request([1, 2, 3, 4]),
      kind: BookAttachmentKind.receipt,
    );

    expect(added.kind, BookAttachmentKind.receipt);
    expect(added.mimeType, 'image/jpeg');
    expect(added.encryptedFileName, isNotNull);
    expect(added.checksum, isNotEmpty);
    expect(added.fileName, 'مرفق.jpg');
    expect(storage.stored[added.encryptedFileName], [1, 2, 3, 4]);

    final loaded = (await book.transactions.find(transaction.id))!;
    expect(loaded.attachments.single.id, added.id);
    // Several attachments per transaction are allowed.
    await book.attachments!.add(
      transactionId: transaction.id,
      request: request([9], extension: 'pdf', mime: 'application/pdf'),
    );
    final both = (await book.transactions.find(transaction.id))!.attachments;
    expect(both.map((a) => a.kind), [
      BookAttachmentKind.receipt,
      BookAttachmentKind.pdf,
    ]);
  });

  test('the default kind follows the file type', () {
    expect(BookAttachmentsController.kindFor('image/png'), BookAttachmentKind.image);
    expect(
      BookAttachmentsController.kindFor('application/pdf'),
      BookAttachmentKind.pdf,
    );
    expect(
      BookAttachmentsController.kindFor('application/zip'),
      BookAttachmentKind.document,
    );
  });

  test('an unknown or deleted transaction takes no attachment', () async {
    await expectLater(
      book.attachments!.add(
        transactionId: 'nope',
        request: request([1]),
      ),
      throwsA(isA<NotFoundException>()),
    );
    await book.transactions.delete(transaction.id);
    await expectLater(
      book.attachments!.add(
        transactionId: transaction.id,
        request: request([1]),
      ),
      throwsA(isA<NotFoundException>()),
    );
    expect(storage.stored, isEmpty);
  });

  test('a failed database write leaves no orphan encrypted file', () async {
    repository.failWrites = true;
    await expectLater(
      book.attachments!.add(
        transactionId: transaction.id,
        request: request([1, 2]),
      ),
      throwsA(isA<StateError>()),
    );
    expect(storage.stored, isEmpty);
  });

  test('removing deletes the row and the encrypted file', () async {
    final added = await book.attachments!.add(
      transactionId: transaction.id,
      request: request([5, 6]),
    );
    expect(storage.stored, hasLength(1));

    await book.attachments!.remove(added.id);

    expect(storage.stored, isEmpty);
    expect((await book.transactions.find(transaction.id))!.attachments, isEmpty);
    await expectLater(
      book.attachments!.remove(added.id),
      throwsA(isA<NotFoundException>()),
    );
  });

  test('opening decrypts to a temporary file the caller deletes', () async {
    final added = await book.attachments!.add(
      transactionId: transaction.id,
      request: request([7, 8, 9]),
    );
    final handle = await book.attachments!.open(added);
    expect(handle.file.readAsBytesSync(), Uint8List.fromList([7, 8, 9]));
    await handle.delete();
    expect(handle.file.existsSync(), isFalse);
  });

  test('a migrated attachment references the vault and is never deleted', () async {
    final vaultFile = DocumentFile(
      id: 'vault-file',
      documentId: 'vault-doc',
      encryptedFileName: 'vault.enc',
      originalExtension: 'pdf',
      mimeType: 'application/pdf',
      encryptedSizeBytes: 10,
      checksum: 'abc',
      createdAt: DateTime.utc(2026),
    );
    storage.stored['vault.enc'] = Uint8List.fromList([4, 4]);
    repository.legacyFiles['vault-file'] = vaultFile;
    final reference = BookAttachment(
      id: 'legacy-att',
      transactionId: transaction.id,
      kind: BookAttachmentKind.pdf,
      fileName: 'مرفق.pdf',
      mimeType: 'application/pdf',
      documentFileId: 'vault-file',
      createdAt: DateTime.utc(2026),
    );
    await repository.write((writer) => writer.putAttachment(reference));

    final handle = await book.attachments!.open(reference);
    expect(handle.file.readAsBytesSync(), [4, 4]);
    await handle.delete();

    await book.attachments!.remove(reference.id);
    // Only the reference row goes; the vault keeps its file.
    expect(storage.stored.containsKey('vault.enc'), isTrue);
    expect((await book.transactions.find(transaction.id))!.attachments, isEmpty);
  });

  test('a reference whose vault file is gone reports it', () async {
    final reference = BookAttachment(
      id: 'legacy-att',
      transactionId: transaction.id,
      fileName: 'x.pdf',
      mimeType: 'application/pdf',
      documentFileId: 'missing',
      createdAt: DateTime.utc(2026),
    );
    await expectLater(
      book.attachments!.open(reference),
      throwsA(
        isA<NotFoundException>().having(
          (e) => e.code,
          'code',
          'attachment_file_missing',
        ),
      ),
    );
  });

  test('an owned attachment must carry a checksum', () {
    expect(
      () => BookAttachment(
        id: 'a',
        transactionId: 't',
        fileName: 'f',
        mimeType: 'image/png',
        encryptedFileName: 'x.enc',
        createdAt: DateTime.utc(2026),
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => BookAttachment(
        id: 'a',
        transactionId: 't',
        fileName: 'f',
        mimeType: 'image/png',
        createdAt: DateTime.utc(2026),
      ),
      throwsA(isA<ValidationException>()),
    );
  });
}
