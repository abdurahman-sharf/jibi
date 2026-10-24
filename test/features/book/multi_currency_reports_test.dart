import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/book_repository.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_builder.dart';
import 'package:jibi/features/book/reports/report_models.dart';
import 'package:jibi/features/book/reports/report_pdf.dart';
import 'package:jibi/features/book/reports/report_text.dart';
import 'package:jibi/features/book/reports/report_xlsx.dart';
import '../../support/book_wallets.dart';
import '../../support/test_currencies.dart';

/// Reports of an account that uses several currencies: one section per
/// currency, each with its own opening, running balance and totals — and never
/// a balance or a total that adds two currencies. Built on both repositories.
///
/// «محمد خالد» (one account):
///
/// | currency | opening        | transactions                              | now         |
/// |----------|----------------|-------------------------------------------|-------------|
/// | YER      | 5,000 debit    | +1,000 debit (Jan 1), 200 credit (Feb 10) | 5,800 debit |
/// | SAR      | 300.00 credit  | +100.00 debit (Jan 15), +50.00 (Feb 15)   | 150.00 credit |
/// | USD      | none           | +20.00 debit (Feb 20)                     | 20.00 debit |
final class _Harness {
  _Harness(this.repository, this.dispose);

  final BookRepository repository;
  final Future<void> Function() dispose;
}

Future<_Harness> _openMemory() async {
  final repository = InMemoryBookRepository();
  return _Harness(repository, repository.dispose);
}

Future<_Harness> _openSqlite() async {
  final database = AppDatabase(path: inMemoryDatabasePath);
  final repository = SqliteBookRepository(database);
  return _Harness(repository, () async {
    await repository.dispose();
    await database.close();
  });
}

Map<String, XmlDocument> _open(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return {
    for (final file in archive.files)
      if (file.isFile)
        file.name: XmlDocument.parse(utf8.decode(file.content as List<int>)),
  };
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  _suite('in-memory repository', _openMemory);
  _suite('sqlite repository', _openSqlite);
}

void _suite(String name, Future<_Harness> Function() open) {
  group(name, () {
    late _Harness harness;
    late BookServices book;
    late BookReportBuilder reports;
    late BookCategory category;
    late BookAccount mohammed;

    setUp(() async {
      harness = await open();
      await seedMainWallet(harness.repository);
      final currencies = testCurrencyRegistry();
      book = BookServices(
        repository: harness.repository,
        currencies: currencies,
        defaultCurrencyCode: () => 'YER',
      );
      reports = BookReportBuilder(
        repository: harness.repository,
        currencies: currencies,
        clock: () => DateTime(2026, 9, 20, 15, 30),
      );
      category = await book.categories.create(
        const BookCategoryDraft(name: 'حسابات اليمن'),
      );
      mohammed = await book.accounts.create(
        BookAccountDraft(
          categoryId: category.id,
          name: 'محمد خالد',
          openings: const [
            BookAccountOpeningDraft(
              currencyCode: 'YER',
              openingMinor: 5000,
              openingType: OpeningType.debit,
            ),
            BookAccountOpeningDraft(
              currencyCode: 'SAR',
              openingMinor: 30000,
              openingType: OpeningType.credit,
            ),
          ],
        ),
      );
      Future<void> tx(String code, EntryType type, int minor, String date) =>
          book.transactions.create(
            BookTransactionDraft(
              accountId: mohammed.id,
              currencyCode: code,
              type: type,
              amountMinor: minor,
              date: date,
              details: 'حركة $code',
              walletId: seededMainWalletId,
            ),
          );
      await tx('YER', EntryType.debit, 1000, '2025-01-01');
      await tx('SAR', EntryType.debit, 10000, '2025-01-15');
      await tx('YER', EntryType.credit, 200, '2025-02-10');
      await tx('SAR', EntryType.debit, 5000, '2025-02-15');
      await tx('USD', EntryType.debit, 2000, '2025-02-20');
    });

    tearDown(() => harness.dispose());

    ReportBlock block(ReportDocument doc, String code) =>
        doc.blocks.singleWhere((b) => b.currencyCode == code);

    String figure(ReportBlock b, String label) =>
        b.figures.singleWhere((f) => f.label == label).value;

    group('the account statement', () {
      test('is one section per currency, in currency order', () async {
        final doc = await reports.accountStatement(mohammed.id);
        expect(doc.blocks.map((b) => b.currencyCode), ['SAR', 'USD', 'YER']);
        for (final b in doc.blocks) {
          expect(b.heading, contains(b.currencyCode!),
              reason: 'each section says which currency it is');
        }
        expect(doc.info.map((i) => i.label), contains('العملات'));
        expect(doc.notes.join(' '), contains('لا تُجمع العملات'));
      });

      test('every currency has its own opening, running balance and totals',
          () async {
        final doc = await reports.accountStatement(mohammed.id);

        final yer = block(doc, 'YER');
        expect(figure(yer, 'الرصيد الافتتاحي للفترة'), '5,000 مدين');
        expect(figure(yer, 'إجمالي مدين'), '1,000');
        expect(figure(yer, 'إجمالي دائن'), '200');
        expect(figure(yer, 'الرصيد النهائي'), '5,800 مدين');
        // Opening row, then the two YER rows with THEIR running balance.
        final yerRows = yer.table!.rows;
        expect(yerRows, hasLength(3));
        expect(yerRows[0][5].text, '5,000 مدين');
        expect(yerRows[1][5].text, '6,000 مدين');
        expect(yerRows[2][5].text, '5,800 مدين');

        final sar = block(doc, 'SAR');
        expect(figure(sar, 'الرصيد الافتتاحي للفترة'), '300.00 دائن');
        expect(figure(sar, 'إجمالي مدين'), '150.00');
        expect(figure(sar, 'الرصيد النهائي'), '150.00 دائن');
        final sarRows = sar.table!.rows;
        expect(sarRows, hasLength(3));
        expect(sarRows[1][5].text, '200.00 دائن');
        expect(sarRows[2][5].text, '150.00 دائن');

        final usd = block(doc, 'USD');
        expect(figure(usd, 'الرصيد الافتتاحي للفترة'), '0.00 متعادل');
        expect(figure(usd, 'الرصيد النهائي'), '20.00 مدين');
        expect(usd.table!.rows, hasLength(2));
      });

      test('no cell, figure or total adds two currencies', () async {
        final doc = await reports.accountStatement(mohammed.id);
        // What a mixed total would have been in minor units or text.
        const forbidden = ['5,800.00', '6,800', '5,970', '5,820', '5,780'];
        for (final b in doc.blocks) {
          for (final f in b.figures) {
            for (final bad in forbidden) {
              expect(f.value, isNot(contains(bad)), reason: '${b.currencyCode}');
            }
          }
          // Every row of a section belongs to that section's currency only:
          // the details cell carries the transaction's own currency tag.
          for (final row in b.table!.rows.skip(1)) {
            expect(row[1].text, contains('حركة ${b.currencyCode}'));
          }
        }
      });

      test('can be narrowed to one currency, case-insensitively', () async {
        final doc = await reports.accountStatement(
          mohammed.id,
          currencyCode: 'sar',
        );
        expect(doc.blocks, hasLength(1));
        expect(doc.blocks.single.currencyCode, 'SAR');
        expect(doc.blocks.single.heading, isNull,
            reason: 'one section needs no heading');
        expect(doc.info.map((i) => i.label), contains('العملة'));
        expect(doc.fileBaseName, contains('SAR'));
      });

      test('refuses a currency the account never used', () async {
        await expectLater(
          reports.accountStatement(mohammed.id, currencyCode: 'EUR'),
          throwsA(
            isA<NotFoundException>().having(
              (e) => e.code,
              'code',
              'account_currency_not_found',
            ),
          ),
        );
      });

      test('a period carries the balance in per currency', () async {
        final doc = await reports.accountStatement(
          mohammed.id,
          fromDate: '2025-02-01',
          toDate: '2025-02-28',
        );
        // January's movement moved into each currency's opening.
        expect(
          figure(block(doc, 'YER'), 'الرصيد الافتتاحي للفترة'),
          '6,000 مدين',
        );
        expect(
          figure(block(doc, 'SAR'), 'الرصيد الافتتاحي للفترة'),
          '200.00 دائن',
        );
        expect(
          figure(block(doc, 'USD'), 'الرصيد الافتتاحي للفترة'),
          '0.00 متعادل',
        );
        expect(figure(block(doc, 'YER'), 'الرصيد النهائي'), '5,800 مدين');
        expect(figure(block(doc, 'SAR'), 'الرصيد النهائي'), '150.00 دائن');
        expect(block(doc, 'YER').table!.rows, hasLength(2));
      });

      test('the monthly statement keeps each currency apart too', () async {
        final doc = await reports.accountMonthlyStatement(
          mohammed.id,
          year: 2025,
          month: 2,
        );
        expect(doc.blocks.map((b) => b.currencyCode), ['SAR', 'USD', 'YER']);
        expect(
          figure(block(doc, 'YER'), 'الرصيد بداية الشهر'),
          '6,000 مدين',
        );
        expect(figure(block(doc, 'YER'), 'الرصيد نهاية الشهر'), '5,800 مدين');
        expect(figure(block(doc, 'SAR'), 'الرصيد نهاية الشهر'), '150.00 دائن');

        final onlyUsd = await reports.accountMonthlyStatement(
          mohammed.id,
          year: 2025,
          month: 2,
          currencyCode: 'USD',
        );
        expect(onlyUsd.blocks.single.currencyCode, 'USD');
        expect(figure(onlyUsd.blocks.single, 'الرصيد نهاية الشهر'), '20.00 مدين');
      });

      test('an account with one currency reads as it always did', () async {
        final other = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'علي أخي'),
        );
        await book.transactions.create(
          BookTransactionDraft(
            accountId: other.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 700,
            date: '2025-03-01',
            walletId: seededMainWalletId,
          ),
        );
        final doc = await reports.accountStatement(other.id);
        expect(doc.blocks, hasLength(1));
        expect(doc.blocks.single.heading, isNull);
        expect(doc.info.map((i) => i.label), contains('العملة'));
        expect(doc.notes, isEmpty);
      });

      test('an account that uses no currency yet says so', () async {
        final empty = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'فارغ'),
        );
        final doc = await reports.accountStatement(empty.id);
        expect(doc.blocks, isEmpty);
        expect(doc.notes.join(' '), contains('لا توجد أرصدة أو عمليات'));
      });
    });

    group('the category reports', () {
      Future<BookAccount> otherAccount() async {
        final other = await book.accounts.create(
          BookAccountDraft(categoryId: category.id, name: 'علي أخي'),
        );
        await book.transactions.create(
          BookTransactionDraft(
            accountId: other.id,
            currencyCode: 'YER',
            type: EntryType.credit,
            amountMinor: 300,
            date: '2025-02-01',
            walletId: seededMainWalletId,
          ),
        );
        await book.transactions.create(
          BookTransactionDraft(
            accountId: other.id,
            currencyCode: 'USD',
            type: EntryType.debit,
            amountMinor: 1000,
            date: '2025-02-02',
            walletId: seededMainWalletId,
          ),
        );
        return other;
      }

      test('totals are one block per currency, summing only that currency',
          () async {
        await otherAccount();
        final doc = await reports.categoryTotals(category.id);
        expect(doc.blocks.map((b) => b.currencyCode), ['SAR', 'USD', 'YER']);

        final yer = block(doc, 'YER');
        expect(figure(yer, 'عدد الحسابات'), '2', reason: 'both use YER');
        expect(figure(yer, 'إجمالي مدين'), '6,000');
        expect(figure(yer, 'إجمالي دائن'), '500');
        expect(figure(yer, 'الرصيد الصافي'), '5,500 مدين');

        final sar = block(doc, 'SAR');
        expect(figure(sar, 'عدد الحسابات'), '1');
        expect(figure(sar, 'إجمالي دائن'), '300.00');
        expect(figure(sar, 'إجمالي مدين'), '150.00');
        expect(figure(sar, 'الرصيد الصافي'), '150.00 دائن');

        final usd = block(doc, 'USD');
        expect(figure(usd, 'عدد الحسابات'), '2');
        expect(figure(usd, 'إجمالي مدين'), '30.00');
      });

      test('details list an account in every currency it uses', () async {
        await otherAccount();
        final doc = await reports.categoryDetails(category.id);
        List<String> names(String code) => [
          for (final row in block(doc, code).table!.rows) row.first.text,
        ];
        // Sorted by name within each currency.
        expect(names('YER'), ['علي أخي', 'محمد خالد']);
        expect(names('SAR'), ['محمد خالد']);
        expect(names('USD'), ['علي أخي', 'محمد خالد']);
        final totals = block(doc, 'YER').table!.totals!;
        expect(totals[1].text, '6,000');
        expect(totals[2].text, '500');
        expect(totals[3].text, '5,500 مدين');
        // Each row's own currency is spelled out in its last cell.
        for (final code in ['YER', 'SAR', 'USD']) {
          for (final row in block(doc, code).table!.rows) {
            expect(row.last.text, code);
          }
        }
      });

      test('monthly starts each currency from its own openings and can be '
          'narrowed to one', () async {
        final all = await reports.categoryMonthly(category.id, year: 2025);
        expect(all.blocks.map((b) => b.currencyCode), ['SAR', 'USD', 'YER']);
        // The opening row of each block is that currency's opening alone.
        expect(block(all, 'YER').table!.rows.first[3].text, '5,000 مدين');
        expect(block(all, 'SAR').table!.rows.first[3].text, '300.00 دائن');

        // Starting in February, January's movement joins each opening — still
        // per currency.
        final february = await reports.categoryMonthly(
          category.id,
          fromDate: '2025-02-01',
          toDate: '2025-02-28',
        );
        expect(block(february, 'YER').table!.rows.first[3].text, '6,000 مدين',
            reason: 'opening 5,000 + January debit 1,000');
        expect(block(february, 'SAR').table!.rows.first[3].text, '200.00 دائن',
            reason: 'opening 300.00 credit + January debit 100.00');

        final onlySar = await reports.categoryMonthly(
          category.id,
          year: 2025,
          currencyCode: 'SAR',
        );
        expect(onlySar.blocks.map((b) => b.currencyCode), ['SAR']);
        expect(onlySar.blocks.single.table!.totals![3].text, '150.00 دائن');
      });
    });

    group('every export shows the right currency', () {
      test('the WhatsApp text has a section per currency', () async {
        final doc = await reports.accountStatement(mohammed.id);
        final text = const ReportTextBuilder().build(doc);
        for (final code in ['SAR', 'USD', 'YER']) {
          expect(text, contains(code));
        }
        expect(text, contains('5,800 مدين'));
        expect(text, contains('150.00 دائن'));
        expect(text, contains('20.00 مدين'));
      });

      test('the spreadsheet has one sheet per currency with its own numbers',
          () async {
        final doc = await reports.accountStatement(mohammed.id);
        final parts = _open(const ReportXlsxWriter().write(doc));
        final names = parts['xl/workbook.xml']!
            .findAllElements('sheet')
            .map((e) => e.getAttribute('name'))
            .toList();
        expect(names, ['SAR', 'USD', 'YER']);
        String sheetText(int index) => parts['xl/worksheets/sheet$index.xml']!
            .findAllElements('t')
            .map((t) => t.innerText)
            .join(' | ');
        expect(sheetText(1), contains('150.00'));
        expect(sheetText(3), contains('5,800'));
      });

      test('the PDF renders every currency section', () async {
        final doc = await reports.accountStatement(mohammed.id);
        final bytes = await ReportPdfRenderer(
          fonts: ReportFonts(
            regular: File('assets/fonts/Tajawal-Regular.ttf').readAsBytesSync(),
            bold: File('assets/fonts/Tajawal-Bold.ttf').readAsBytesSync(),
          ),
        ).render(doc);
        expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
        expect(bytes.length, greaterThan(2000));
      });
    });
  });
}
