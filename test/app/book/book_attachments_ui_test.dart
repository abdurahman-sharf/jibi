import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/book/book_account_page.dart';
import 'package:jibi/app/book/book_transaction_form.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';
import 'package:jibi/features/book/book.dart';

import '../../support/book_harness.dart';
import '../../support/fake_secure_storage.dart';

void main() {
  late Directory sandbox;
  late FakeSecureFileStorage storage;
  late FakeDocumentSourcePicker picker;
  late BookFixture fixture;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('jibi_attachments_ui_');
    storage = FakeSecureFileStorage(
      Directory('${sandbox.path}${Platform.pathSeparator}temporary'),
    );
    picker = FakeDocumentSourcePicker();
    fixture = await BookFixture.create(storage: storage);
  });

  tearDown(() async {
    await fixture.dispose();
    sandbox.deleteSync(recursive: true);
  });

  File source(String name, List<int> bytes) =>
      File('${sandbox.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(bytes);

  FileImportRequest request(
    File file, {
    String extension = 'jpg',
    String mime = 'image/jpeg',
  }) => FileImportRequest(
    sourceFile: file,
    originalExtension: extension,
    mimeType: mime,
  );

  Future<void> openForm(
    WidgetTester tester, {
    BookTransaction? transaction,
  }) => pumpBookPage(
    tester,
    BookTransactionFormPage(
      book: fixture.book,
      account: fixture.ali,
      transaction: transaction,
      picker: picker,
    ),
    size: const Size(390, 1600),
  );

  Future<void> chooseFile(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('add-attachment')));
    await tester.tap(find.byKey(const Key('add-attachment')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach-file')));
    await tester.pumpAndSettle();
  }

  testWidgets('a picked file is typed, encrypted on save and its cache removed', (
    tester,
  ) async {
    final file = source('photo.jpg', [1, 2, 3]);
    picker.pickResults.add(request(file));
    await openForm(tester);

    await chooseFile(tester);
    expect(picker.pickCalls, 1);
    expect(find.text('مرفق جديد (jpg)'), findsOneWidget);
    // Nothing is encrypted until the transaction is saved.
    expect(storage.stored, isEmpty);

    // The kind defaults to "صورة"; the user picks "إيصال".
    await tester.tap(find.text('صورة').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('إيصال').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('tx-amount')), '1500');
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    final rows = (await fixture.book.repository.transactionPage(
      fixture.ali.id,
      limit: 10,
    )).items;
    final saved = rows.firstWhere((row) => row.amountMinor == 1500);
    expect(saved.attachments.single.kind, BookAttachmentKind.receipt);
    expect(storage.stored, hasLength(1));
    expect(storage.stored.values.single, [1, 2, 3]);
    // The plaintext cache copy is gone.
    expect(file.existsSync(), isFalse);
  });

  testWidgets('the camera option uses the capture channel', (tester) async {
    final file = source('capture.jpg', [9, 9]);
    picker.captureResults.add(request(file));
    await openForm(tester);

    await tester.ensureVisible(find.byKey(const Key('add-attachment')));
    await tester.tap(find.byKey(const Key('add-attachment')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach-camera')));
    await tester.pumpAndSettle();

    expect(picker.captureCalls, 1);
    expect(picker.pickCalls, 0);
    expect(find.text('مرفق جديد (jpg)'), findsOneWidget);
  });

  testWidgets('cancelling the picker adds nothing', (tester) async {
    await openForm(tester);
    await chooseFile(tester);
    expect(find.textContaining('مرفق جديد'), findsNothing);
  });

  testWidgets('removing a pending file deletes its cache copy right away', (
    tester,
  ) async {
    final file = source('gone.jpg', [1]);
    picker.pickResults.add(request(file));
    await openForm(tester);
    await chooseFile(tester);
    expect(file.existsSync(), isTrue);

    await tester.tap(find.byTooltip('إزالة المرفق'));
    await tester.pumpAndSettle();

    expect(find.textContaining('مرفق جديد'), findsNothing);
    expect(file.existsSync(), isFalse);
  });

  testWidgets('leaving the form unsaved also removes the cache copy', (
    tester,
  ) async {
    final file = source('abandoned.jpg', [1]);
    picker.pickResults.add(request(file));
    await openForm(tester);
    await chooseFile(tester);
    expect(file.existsSync(), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(file.existsSync(), isFalse);
    expect(storage.stored, isEmpty);
  });

  testWidgets('editing shows existing attachments and can remove one', (
    tester,
  ) async {
    final transaction = await fixture.book.transactions.create(
      BookTransactionDraft(
        accountId: fixture.ali.id,
        currencyCode: 'YER',
        walletId: fixture.mainWallet.id,
        type: EntryType.debit,
        amountMinor: 700,
        date: '2025-05-05',
      ),
    );
    final attached = await fixture.book.attachments!.add(
      transactionId: transaction.id,
      request: request(source('old.jpg', [5, 5])),
      kind: BookAttachmentKind.voucher,
    );
    final loaded = (await fixture.book.transactions.find(transaction.id))!;
    await openForm(tester, transaction: loaded);

    expect(find.byKey(Key('existing-${attached.id}')), findsOneWidget);
    expect(find.text('سند'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('إزالة المرفق'));
    await tester.tap(find.byTooltip('إزالة المرفق'));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('existing-${attached.id}')), findsNothing);
    // Still there until saved.
    expect(storage.stored, hasLength(1));

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    expect((await fixture.book.transactions.find(transaction.id))!.attachments, isEmpty);
    expect(storage.stored, isEmpty);
  });

  testWidgets('the statement marks a row with its attachment kind and filters', (
    tester,
  ) async {
    final rows = (await fixture.book.repository.transactionPage(
      fixture.ali.id,
      limit: 10,
    )).items;
    await fixture.book.attachments!.add(
      transactionId: rows.last.id,
      request: request(source('a.jpg', [1])),
      kind: BookAttachmentKind.transferNotice,
    );
    await pumpBookPage(
      tester,
      BookAccountPage(book: fixture.book, accountId: fixture.ali.id),
    );

    // The row's second line reads the payment first, then the attachment kind.
    expect(find.text('نقدًا · إشعار تحويل'), findsOneWidget);
    expect(find.byIcon(Icons.attach_file), findsOneWidget);

    await tester.tap(find.byKey(const Key('statement-filters')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-attachments')));
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();
    expect(find.text('العمليات: 1'), findsOneWidget);
  });

  testWidgets('the details sheet lists attachments; unsupported types say so', (
    tester,
  ) async {
    final rows = (await fixture.book.repository.transactionPage(
      fixture.ali.id,
      limit: 10,
    )).items;
    final target = rows.first;
    final attached = await fixture.book.attachments!.add(
      transactionId: target.id,
      request: request(
        source('data.zip', [1, 2]),
        extension: 'zip',
        mime: 'application/zip',
      ),
    );
    await pumpBookPage(
      tester,
      BookAccountPage(book: fixture.book, accountId: fixture.ali.id),
    );

    await tester.tap(find.byKey(Key('tx-row-${target.id}')));
    await tester.pumpAndSettle();
    expect(find.text('المرفقات (1)'), findsOneWidget);
    expect(find.text('مرفق.zip'), findsOneWidget);
    await tester.tap(find.byKey(Key('attachment-${attached.id}')));
    await tester.pumpAndSettle();
    expect(find.text('لا يمكن معاينة هذا النوع من الملفات.'), findsOneWidget);
    // No decrypted copy was made for a type that cannot be previewed.
    expect(storage.openedHandles, isEmpty);
  });
}
