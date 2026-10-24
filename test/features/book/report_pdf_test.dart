// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/src/pdf/font/bidi_utils.dart' as pdf_bidi;

import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_builder.dart';
import 'package:jibi/features/book/reports/report_pdf.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/test_currencies.dart';
import '../../support/book_wallets.dart';

ReportFonts _fonts() => ReportFonts(
  regular: File('assets/fonts/Tajawal-Regular.ttf').readAsBytesSync(),
  bold: File('assets/fonts/Tajawal-Bold.ttf').readAsBytesSync(),
);

String _latin1(Uint8List bytes) => latin1.decode(bytes, allowInvalid: true);

/// Number of page objects of a PDF written by the pdf package.
int _pageCount(Uint8List pdf) =>
    RegExp(r'/Type\s*/Page(?![s\w])').allMatches(_latin1(pdf)).length;

void main() {
  late InMemoryBookRepository repository;
  late BookServices book;
  late BookReportBuilder reports;
  late BookCategory category;
  late BookAccount ali;

  setUp(() async {
    repository = InMemoryBookRepository();
    await seedMainWallet(repository);
    final currencies = testCurrencyRegistry();
    book = BookServices(repository: repository, currencies: currencies, defaultCurrencyCode: () => 'SAR');
    reports = BookReportBuilder(
      repository: repository,
      currencies: currencies,
      clock: () => DateTime(2026, 9, 20, 15, 30),
    );
    category = await book.categories.create(
      const BookCategoryDraft(name: 'حسابات اليمن'),
    );
    ali = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'علي أخي',
        currencyCode: 'YER',
      ),
    );
  });

  tearDown(() => repository.dispose());

  group('pdfBidiSafe', () {
    test('keeps a hyphenated date in its written order inside Arabic text', () {
      const text = 'الفترة: 2024-12-01 إلى 2026-09-20';
      // The pdf package's own bidi pipeline reverses the groups of each date
      // when a hyphen sits between digits in right-to-left text.
      final raw = pdf_bidi.logicalToVisual(text);
      expect(raw, contains('01-12-2024'));
      expect(raw, isNot(contains('2024-12-01')));

      final safe = pdf_bidi.logicalToVisual(pdfBidiSafe(text));
      expect(safe, contains('2024/12/01'));
      expect(safe, contains('2026/09/20'));
    });

    test('writes year-month labels and other digit runs safely', () {
      expect(pdfBidiSafe('2025-01 · يناير'), '2025/01 · يناير');
      expect(pdfBidiSafe('اتصل 777-123-456'), 'اتصل 777/123/456');
      final visual = pdf_bidi.logicalToVisual(pdfBidiSafe('اتصل 777-123-456'));
      expect(visual, contains('777/123/456'));
    });

    test('leaves text that needs no help alone', () {
      // No Arabic: already laid out correctly, and the hyphen stays a hyphen.
      expect(pdfBidiSafe('2026-09-20'), '2026-09-20');
      expect(pdfBidiSafe('TX-000001'), 'TX-000001');
      // Arabic, but no hyphen between digits.
      expect(pdfBidiSafe('TX-000001 — يوم موت أبي'), 'TX-000001 — يوم موت أبي');
      expect(pdfBidiSafe('30,000 مدين'), '30,000 مدين');
      expect(pdfBidiSafe('5,250.50 دائن'), '5,250.50 دائن');
      expect(pdfBidiSafe('غير-مرقّم'), 'غير-مرقّم');
      expect(pdfBidiSafe('يوم موت (TX-000001)'), 'يوم موت (TX-000001)');
    });

    test('a lone date is laid out intact by the pipeline', () {
      expect(pdf_bidi.logicalToVisual('2026-09-20'), '2026-09-20');
    });

    test('never introduces characters the font cannot draw', () {
      for (final input in ['الفترة: 2024-12-01', 'x 1-2-3 ي', '٢٠٢٤-١٢']) {
        final safe = pdfBidiSafe(input);
        for (final rune in safe.runes) {
          // No bidi controls (U+202A..U+202E, U+2066..U+2069).
          expect(
            (rune >= 0x202A && rune <= 0x202E) || (rune >= 0x2066 && rune <= 0x2069),
            isFalse,
          );
        }
      }
    });
  });

  group('font coverage', () {
    // The pdf package shapes Arabic into presentation forms and maps the
    // isolated ones back to the base letter's glyph itself. Its table points an
    // isolated yeh at the code point of alef maksura, so the fonts are patched
    // (tool/patch_tajawal_cmap.py); this guards both the patch and any later
    // change of the package.
    test('every letter, in every joining position, has a glyph', () {
      final document = PdfDocument();
      final fonts = {
        'regular': PdfTtfFont(document, ByteData.sublistView(_fonts().regular)),
        'bold': PdfTtfFont(document, ByteData.sublistView(_fonts().bold)),
      };
      final missing = <String>{};
      void check(String text) {
        final visual = pdf_bidi.logicalToVisual(text);
        for (final rune in visual.runes) {
          for (final entry in fonts.entries) {
            if (!entry.value.isRuneSupported(rune)) {
              missing.add(
                '${entry.key}: U+${rune.toRadixString(16).toUpperCase()} in "$text"',
              );
            }
          }
        }
      }

      for (var letter = 0x0621; letter <= 0x064A; letter++) {
        if (letter >= 0x063B && letter <= 0x0640) continue;
        final char = String.fromCharCode(letter);
        // alone, at the end, at the start, in the middle, after a letter that
        // does not join
        for (final word in [char, 'ب$char', '$charب', 'ب$charب', 'ا$char', 'د$char']) {
          check(word);
        }
      }
      for (final word in [
        'سعودي', 'مهدي', 'هادي', 'هدى', 'موسى', 'على', 'الله', 'لا', 'لأن',
        'يمني', 'دولار أمريكي', 'مؤسسة', 'مسؤول', 'شيء', 'رئيس', 'آخر', 'إبراهيم',
        'حوالة ١٢٣٤٥٦٧٨٩٠ ٪ ،؛؟',
      ]) {
        check(word);
      }
      expect(missing, isEmpty, reason: missing.join('\n'));
    });
  });

  group('render', () {
    test('a statement is a valid one-page PDF with the fonts embedded', () async {
      await book.transactions.create(
        BookTransactionDraft(
          accountId: ali.id,
          currencyCode: 'YER',
          walletId: seededMainWalletId,
          type: EntryType.debit,
          amountMinor: 30000,
          date: '2024-12-13',
          details: 'يوم موت أبي علي',
        ),
      );
      final doc = await reports.accountStatement(ali.id);
      final bytes = await ReportPdfRenderer(fonts: _fonts()).render(doc);

      expect(_latin1(bytes.sublist(0, 8)), startsWith('%PDF-'));
      expect(_latin1(bytes.sublist(bytes.length - 12)), contains('%%EOF'));
      expect(_pageCount(bytes), 1);
      final text = _latin1(bytes);
      // The Arabic fonts are embedded as subsets, so the document does not
      // depend on the reader's fonts.
      expect(text, contains('/FontFile2'));
      expect(text, contains('Tajawal'));
      // Metadata carries the title.
      expect(text, contains('/Title'));
    });

    test('no glyph warnings: every drawn character exists in the font', () async {
      // The pdf package prints "Unable to find a font to draw ..." when a
      // character is missing. Capture stdout while rendering.
      final lines = <String>[];
      await runZoned(
        () async {
          await book.transactions.create(
            BookTransactionDraft(
              accountId: ali.id,
              currencyCode: 'YER',
              walletId: seededMainWalletId,
              type: EntryType.credit,
              amountMinor: 525050,
              date: '2025-02-01',
              details: 'حوالة — لا لله (اختبار) 777-123-456',
            ),
          );
          for (final doc in [
            await reports.accountStatement(ali.id),
            await reports.categoryTotals(category.id),
            await reports.categoryDetails(category.id),
            await reports.categoryMonthly(category.id, year: 2025),
            await reports.accountMonthlyStatement(ali.id, year: 2025, month: 2),
          ]) {
            await ReportPdfRenderer(fonts: _fonts()).render(doc);
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => lines.add(line),
        ),
      );
      expect(
        lines.where((line) => line.contains('Unable to find a font')),
        isEmpty,
        reason: lines.join('\n'),
      );
    });

    test('every currency and every report kind renders', () async {
      final sar = await book.accounts.create(
        BookAccountDraft.single(
          categoryId: category.id,
          name: 'حساب سعودي',
          currencyCode: 'SAR',
        ),
      );
      for (final account in [ali, sar]) {
        await book.transactions.create(
          BookTransactionDraft(
            accountId: account.id,
            currencyCode: 'YER',
            walletId: seededMainWalletId,
            type: EntryType.debit,
            amountMinor: 12345,
            date: '2025-02-01',
          ),
        );
      }
      final wallet = await book.wallets.create(
        WalletDraft.single(
          name: 'الصندوق',
          currencyCode: 'YER',
        ),
      );
      await book.walletTransactions.deposit(
        WalletDepositDraft(
          walletId: wallet.id,
          amountMinor: 12345,
          date: '2025-02-01',
        ),
      );
      final renderer = ReportPdfRenderer(fonts: _fonts());
      final docs = [
        await reports.categoryTotals(category.id),
        await reports.categoryDetails(category.id),
        await reports.categoryMonthly(category.id, year: 2025),
        await reports.accountStatement(ali.id),
        await reports.accountMonthlyStatement(sar.id, year: 2025, month: 2),
        await reports.walletStatement(wallet.id),
      ];
      for (final doc in docs) {
        final bytes = await renderer.render(doc);
        expect(bytes.length, greaterThan(2000), reason: doc.title);
        expect(_latin1(bytes.sublist(0, 5)), '%PDF-', reason: doc.title);
      }
    });

    test('an empty report still renders its header and note', () async {
      final empty = await book.categories.create(
        const BookCategoryDraft(name: 'فارغ'),
      );
      final doc = await reports.categoryTotals(empty.id);
      final bytes = await ReportPdfRenderer(fonts: _fonts()).render(doc);
      expect(_pageCount(bytes), 1);
    });

    test('a long statement continues over several pages', () async {
      for (var index = 1; index <= 240; index++) {
        await book.transactions.create(
          BookTransactionDraft(
            accountId: ali.id,
            currencyCode: 'YER',
            walletId: seededMainWalletId,
            type: index.isEven ? EntryType.credit : EntryType.debit,
            amountMinor: index * 10,
            date: '2025-${((index - 1) % 12 + 1).toString().padLeft(2, '0')}-10',
            details: 'عملية رقم $index',
          ),
        );
      }
      final doc = await reports.accountStatement(ali.id);
      final bytes = await ReportPdfRenderer(fonts: _fonts()).render(doc);
      expect(_pageCount(bytes), greaterThan(3));
    });

    test('very long details are clipped instead of breaking the layout', () async {
      await book.transactions.create(
        BookTransactionDraft(
          accountId: ali.id,
          currencyCode: 'YER',
          walletId: seededMainWalletId,
          type: EntryType.debit,
          amountMinor: 1,
          date: '2025-01-01',
          details: 'كلمة ' * 6000,
        ),
      );
      final doc = await reports.accountStatement(ali.id);
      final cell = doc.blocks.single.table!.rows[1][1].text;
      expect(cell.length, lessThan(430));
      expect(cell, contains('…'));
      expect(cell, endsWith('(TX-000001)'));
      final bytes = await ReportPdfRenderer(fonts: _fonts()).render(doc);
      expect(_pageCount(bytes), 1);
    });

    test('thousands of rows render in reasonable time', () async {
      for (var index = 1; index <= 1500; index++) {
        await book.transactions.create(
          BookTransactionDraft(
            accountId: ali.id,
            currencyCode: 'YER',
            walletId: seededMainWalletId,
            type: EntryType.debit,
            amountMinor: index,
            date: '2025-01-${(index % 28 + 1).toString().padLeft(2, '0')}',
            details: 'دفعة $index',
          ),
        );
      }
      final doc = await reports.accountStatement(ali.id);
      final watch = Stopwatch()..start();
      final bytes = await ReportPdfRenderer(fonts: _fonts()).render(doc);
      watch.stop();
      expect(_pageCount(bytes), greaterThan(30));
      // ignore: avoid_print
      print('1500-row statement: ${watch.elapsed.inMilliseconds} ms, ${_pageCount(bytes)} pages, ${bytes.length} bytes');
      expect(watch.elapsed, lessThan(const Duration(seconds: 60)));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
