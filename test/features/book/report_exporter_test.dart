import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_builder.dart';
import 'package:jibi/features/book/reports/report_exporter.dart';
import 'package:jibi/features/book/reports/report_models.dart';
import 'package:jibi/features/book/reports/report_pdf.dart';
import '../../support/test_currencies.dart';
import '../../support/book_wallets.dart';

/// What a fake share sheet saw: the file is deleted after the call, so its
/// contents are read inside it.
class _Shared {
  _Shared({
    required this.path,
    required this.mimeType,
    required this.fileName,
    required this.packages,
    required this.bytes,
  });

  final String path;
  final String mimeType;
  final String? fileName;
  final List<String> packages;
  final Uint8List bytes;
}

void main() {
  late Directory temporary;
  late InMemoryBookRepository repository;
  late BookReportBuilder reports;
  late BookAccount ali;
  late ReportDocument statement;

  final shared = <_Shared>[];
  final texts = <({String text, List<String> packages, String? title})>[];
  final saved = <({String mimeType, String fileName, Uint8List bytes})>[];
  final printed = <({String? jobName, Uint8List bytes})>[];
  var saveResult = true;
  var fontLoads = 0;
  Object? shareFailure;

  SharingReportExporter exporter({ReportTaskRunner? runTask}) =>
      SharingReportExporter(
        temporaryDirectory: temporary,
        loadFonts: () async {
          fontLoads++;
          return ReportFonts(
            regular: File('assets/fonts/Tajawal-Regular.ttf').readAsBytesSync(),
            bold: File('assets/fonts/Tajawal-Bold.ttf').readAsBytesSync(),
          );
        },
        shareFile: (file, mimeType, {fileName, preferredPackages = const []}) async {
          shared.add(
            _Shared(
              path: file.path,
              mimeType: mimeType,
              fileName: fileName,
              packages: preferredPackages,
              bytes: file.readAsBytesSync(),
            ),
          );
          final failure = shareFailure;
          if (failure != null) throw failure;
        },
        shareText: (text, {preferredPackages = const [], chooserTitle}) async {
          texts.add((text: text, packages: preferredPackages, title: chooserTitle));
          final failure = shareFailure;
          if (failure != null) throw failure;
        },
        saveFile: (file, mimeType, {required fileName}) async {
          saved.add((
            mimeType: mimeType,
            fileName: fileName,
            bytes: file.readAsBytesSync(),
          ));
          final failure = shareFailure;
          if (failure != null) throw failure;
          return saveResult;
        },
        printFile: (file, {jobName}) async {
          printed.add((jobName: jobName, bytes: file.readAsBytesSync()));
          final failure = shareFailure;
          if (failure != null) throw failure;
        },
        whatsAppPackages: const ['com.whatsapp', 'com.whatsapp.w4b'],
        runTask: runTask ?? inlineReportTaskRunner,
        nextId: () => 'fixed',
      );

  setUp(() async {
    shared.clear();
    texts.clear();
    saved.clear();
    printed.clear();
    saveResult = true;
    fontLoads = 0;
    shareFailure = null;
    temporary = await Directory.systemTemp.createTemp('jibi_export_test_');
    repository = InMemoryBookRepository();
    await seedMainWallet(repository);
    final currencies = testCurrencyRegistry();
    final book = BookServices(repository: repository, currencies: currencies, defaultCurrencyCode: () => 'SAR');
    reports = BookReportBuilder(
      repository: repository,
      currencies: currencies,
      clock: () => DateTime(2026, 9, 20, 15, 30),
    );
    final category = await book.categories.create(
      const BookCategoryDraft(name: 'حسابات اليمن'),
    );
    ali = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'علي أخي',
        currencyCode: 'YER',
      ),
    );
    await book.transactions.create(
      BookTransactionDraft(
        accountId: ali.id,
        currencyCode: 'YER',
        walletId: seededMainWalletId,
        type: EntryType.debit,
        amountMinor: 30000,
        date: '2025-01-10',
        details: 'يوم موت أبي علي',
      ),
    );
    statement = await reports.accountStatement(ali.id);
  });

  tearDown(() async {
    await repository.dispose();
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  bool empty() => temporary.listSync().isEmpty;

  test('a PDF is written to the temporary folder, shared, then deleted', () async {
    await exporter().shareFile(statement, ReportFormat.pdf);

    expect(shared, hasLength(1));
    final one = shared.single;
    expect(one.mimeType, 'application/pdf');
    expect(latin1.decode(one.bytes.sublist(0, 5)), '%PDF-');
    // Inside the private folder, with the prefix the startup cleanup removes.
    expect(one.path, startsWith(temporary.path));
    expect(one.path.split(Platform.pathSeparator).last, 'jibi-doc-report-fixed.pdf');
    // A readable name for the receiving app: title, subject and the time.
    expect(one.fileName, '${statement.fileBaseName} 20260920-1530');
    expect(one.packages, isEmpty);
    expect(empty(), isTrue);
  });

  test('a spreadsheet is a zip with the spreadsheet type', () async {
    await exporter().shareFile(statement, ReportFormat.xlsx);

    final one = shared.single;
    expect(
      one.mimeType,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    expect(one.bytes.sublist(0, 2), [0x50, 0x4B]);
    expect(one.path, endsWith('.xlsx'));
    expect(empty(), isTrue);
  });

  test('WhatsApp is offered first, then WhatsApp Business', () async {
    await exporter().shareFile(
      statement,
      ReportFormat.pdf,
      target: ReportShareTarget.whatsApp,
    );
    expect(shared.single.packages, ['com.whatsapp', 'com.whatsapp.w4b']);
  });

  test('the file is deleted even when the share fails', () async {
    shareFailure = StateError('no app');
    await expectLater(
      exporter().shareFile(statement, ReportFormat.pdf),
      throwsA(
        isA<StorageException>().having((e) => e.code, 'code', 'report_export_failed'),
      ),
    );
    expect(shared, hasLength(1));
    expect(empty(), isTrue);
  });

  test('a failure that is already an app error is passed on unchanged', () async {
    shareFailure = const StorageException(code: 'custom', userMessage: 'رسالة');
    await expectLater(
      exporter().shareFile(statement, ReportFormat.xlsx),
      throwsA(isA<StorageException>().having((e) => e.code, 'code', 'custom')),
    );
  });

  test('the fonts are loaded once for many PDFs and never for a spreadsheet', () async {
    final service = exporter();
    await service.shareFile(statement, ReportFormat.xlsx);
    expect(fontLoads, 0);
    await service.shareFile(statement, ReportFormat.pdf);
    await service.shareFile(statement, ReportFormat.pdf);
    expect(fontLoads, 1);
  });

  test('the text summary goes to the share sheet with the chosen target', () async {
    await exporter().shareText(statement, target: ReportShareTarget.whatsApp);

    final one = texts.single;
    expect(one.text, contains('كشف الحساب'));
    expect(one.text, contains('علي أخي'));
    expect(one.text, contains('TX-000001'));
    expect(one.packages, ['com.whatsapp', 'com.whatsapp.w4b']);
    expect(one.title, isNotNull);
    expect(empty(), isTrue);
  });

  test('a text share failure becomes an app error', () async {
    shareFailure = StateError('nope');
    await expectLater(
      exporter().shareText(statement),
      throwsA(
        isA<StorageException>().having((e) => e.code, 'code', 'report_share_failed'),
      ),
    );
  });

  group('save to the device', () {
    test('hands the PDF to the save screen with a readable full name', () async {
      final kept = await exporter().saveFile(statement, ReportFormat.pdf);

      expect(kept, isTrue);
      expect(saved, hasLength(1));
      expect(saved.single.mimeType, 'application/pdf');
      expect(saved.single.fileName, 'كشف حساب علي أخي 20260920-1530.pdf');
      expect(latin1.decode(saved.single.bytes.sublist(0, 5)), '%PDF-');
      expect(empty(), isTrue);
    });

    test('saves a spreadsheet with its own extension and type', () async {
      await exporter().saveFile(statement, ReportFormat.xlsx);

      expect(saved.single.fileName, endsWith('.xlsx'));
      expect(saved.single.mimeType, ReportFormat.xlsx.mimeType);
      expect(saved.single.bytes.sublist(0, 2), [0x50, 0x4B]);
    });

    test('a cancelled save says so and leaves nothing behind', () async {
      saveResult = false;

      expect(await exporter().saveFile(statement, ReportFormat.pdf), isFalse);
      expect(empty(), isTrue);
    });

    test('a failure is one readable error and the file is deleted', () async {
      shareFailure = StateError('disk full');

      await expectLater(
        exporter().saveFile(statement, ReportFormat.pdf),
        throwsA(
          isA<StorageException>().having(
            (e) => e.code,
            'code',
            'report_export_failed',
          ),
        ),
      );
      expect(empty(), isTrue);
    });
  });

  group('print', () {
    test('prints the PDF under a readable job name', () async {
      await exporter().printDocument(statement);

      expect(printed, hasLength(1));
      expect(printed.single.jobName, 'كشف حساب علي أخي 20260920-1530');
      expect(latin1.decode(printed.single.bytes.sublist(0, 5)), '%PDF-');
      expect(empty(), isTrue);
    });

    test('a print failure is one readable error and the file is deleted', () async {
      shareFailure = StateError('no printer service');

      await expectLater(
        exporter().printDocument(statement),
        throwsA(isA<StorageException>()),
      );
      expect(empty(), isTrue);
    });
  });

  test('the default runner really works in a background isolate', () async {
    // The closure sent to Isolate.run must hold only plain data; this fails
    // if it ever drags the exporter (files, callbacks) along.
    final background = SharingReportExporter(
      temporaryDirectory: temporary,
      loadFonts: () async => ReportFonts(
        regular: File('assets/fonts/Tajawal-Regular.ttf').readAsBytesSync(),
        bold: File('assets/fonts/Tajawal-Bold.ttf').readAsBytesSync(),
      ),
      shareFile: (file, mimeType, {fileName, preferredPackages = const []}) async {
        shared.add(
          _Shared(
            path: file.path,
            mimeType: mimeType,
            fileName: fileName,
            packages: preferredPackages,
            bytes: file.readAsBytesSync(),
          ),
        );
      },
      shareText: (text, {preferredPackages = const [], chooserTitle}) async {},
      saveFile: (file, mimeType, {required fileName}) async => true,
      printFile: (file, {jobName}) async {},
      whatsAppPackages: const [],
    );
    await background.shareFile(statement, ReportFormat.pdf);
    await background.shareFile(statement, ReportFormat.xlsx);
    expect(shared, hasLength(2));
    expect(latin1.decode(shared[0].bytes.sublist(0, 5)), '%PDF-');
    expect(shared[1].bytes.sublist(0, 2), [0x50, 0x4B]);
    expect(empty(), isTrue);
  });
}
