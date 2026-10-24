import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_builder.dart';
import 'package:jibi/features/book/reports/report_models.dart';
import 'package:jibi/features/book/reports/report_pdf.dart';
import 'package:jibi/features/book/reports/report_text.dart';
import 'package:jibi/features/book/reports/report_xlsx.dart';
import '../../support/test_currencies.dart';
import '../../support/book_wallets.dart';

/// A 1x1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

ReportFonts _fonts() => ReportFonts(
  regular: File('assets/fonts/Tajawal-Regular.ttf').readAsBytesSync(),
  bold: File('assets/fonts/Tajawal-Bold.ttf').readAsBytesSync(),
);

int _images(Uint8List pdf) => RegExp(
  r'/Subtype\s*/Image',
).allMatches(latin1.decode(pdf, allowInvalid: true)).length;

void main() {
  late InMemoryBookRepository repository;
  late BookServices book;
  late BookCategory category;
  late BookAccount ali;
  late CurrencyRegistry currencies;
  var preferences = BookPreferences.standard;
  ReportBranding? branding;

  BookReportBuilder builder() => BookReportBuilder(
    repository: repository,
    currencies: currencies,
    preferences: () => preferences,
    branding: () async => branding,
    clock: () => DateTime(2026, 9, 20, 15, 30),
  );

  setUp(() async {
    preferences = BookPreferences.standard;
    branding = null;
    repository = InMemoryBookRepository();
    await seedMainWallet(repository);
    currencies = testCurrencyRegistry();
    book = BookServices(repository: repository, currencies: currencies, defaultCurrencyCode: () => 'SAR');
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
    await book.transactions.create(
      BookTransactionDraft(
        accountId: ali.id,
        currencyCode: 'YER',
        walletId: seededMainWalletId,
        type: EntryType.credit,
        amountMinor: 5000,
        date: '2025-01-10',
      ),
    );
  });

  tearDown(() => repository.dispose());

  group('ReportBranding.fromProfile', () {
    test('a profile with nothing to print gives no branding', () {
      expect(ReportBranding.fromProfile(UserProfile.empty), isNull);
    });

    test('carries names and contact details', () {
      final value = ReportBranding.fromProfile(
        UserProfile.validated(
          nameAr: 'عبدالرحمن',
          nameEn: 'Abdulrahman',
          addressAr: 'صنعاء',
          phone: '777123456',
          email: 'a@b.com',
        ),
      )!;

      expect(value.displayName, 'عبدالرحمن');
      expect(value.nameEn, 'Abdulrahman');
      expect(value.addressAr, 'صنعاء');
      expect(value.phone, '777123456');
      expect(value.email, 'a@b.com');
      expect(value.hasLetterhead, isTrue);
      expect(value.hasSignatures, isFalse);
    });

    test('leaves out the pictures the user switched off', () {
      final value = ReportBranding.fromProfile(
        UserProfile.validated(
          nameAr: 'أنا',
          logo: _png,
          signature: _png,
          stamp: _png,
          showLogo: false,
          showStamp: false,
        ),
      )!;

      expect(value.logo, isNull);
      expect(value.signature, _png);
      expect(value.stamp, isNull);
      expect(value.hasSignatures, isTrue);
    });

    test('a profile whose only content is switched off is empty', () {
      expect(
        ReportBranding.fromProfile(
          UserProfile.validated(logo: _png, showLogo: false),
        ),
        isNull,
      );
    });
  });

  group('the builder', () {
    test('adds the issuer to every kind of report', () async {
      branding = const ReportBranding(nameAr: 'عبدالرحمن', phone: '777');
      final reports = builder();

      final documents = [
        await reports.categoryTotals(category.id),
        await reports.categoryDetails(category.id),
        await reports.categoryMonthly(category.id),
        await reports.accountStatement(ali.id),
        await reports.accountMonthlyStatement(ali.id, year: 2025, month: 1),
      ];

      for (final document in documents) {
        expect(document.branding?.nameAr, 'عبدالرحمن', reason: '${document.kind}');
      }
    });

    test('adds nothing when no profile is set up', () async {
      expect((await builder().categoryTotals(category.id)).branding, isNull);
    });

    test('follows the side wording and the date format at build time', () async {
      final reports = builder();
      final before = await reports.accountStatement(
        ali.id,
        fromDate: '2024-12-01',
        toDate: '2024-12-31',
      );
      final beforeTable = before.blocks.single.table!;
      expect(beforeTable.columns.map((c) => c.title), contains('مدين'));
      expect(beforeTable.rows[1].first.text, '2024-12-13');
      expect(
        before.info.singleWhere((i) => i.label == 'الفترة').value,
        'من 2024-12-01 إلى 2024-12-31',
      );

      preferences = const BookPreferences(
        labels: BookLabels(
          debit: 'مستحق لي',
          credit: 'مستحق علي',
          debitHint: '',
          creditHint: '',
        ),
        dateFormat: DateDisplayFormat.dayMonthYearSlash,
      );
      final after = await reports.accountStatement(
        ali.id,
        fromDate: '2024-12-01',
        toDate: '2024-12-31',
      );
      final table = after.blocks.single.table!;

      expect(table.columns.map((c) => c.title), contains('مستحق لي'));
      expect(table.columns.map((c) => c.title), isNot(contains('مدين')));
      expect(table.rows[0].first.text, '01/12/2024');
      expect(table.rows[1].first.text, '13/12/2024');
      expect(
        after.info.singleWhere((i) => i.label == 'الفترة').value,
        'من 01/12/2024 إلى 31/12/2024',
      );
      final figures = after.blocks.single.figures.map((f) => f.label);
      expect(figures, contains('إجمالي مستحق لي'));
      expect(figures, contains('إجمالي مستحق علي'));
      // The balance is worded with the custom side too.
      expect(
        after.blocks.single.figures.last.value,
        '30,000 مستحق لي',
      );
      // Only the wording changed: the numbers are the same.
      List<List<int?>> numbers(ReportTable t) => [
        for (final row in t.rows) [for (final c in row) c.amountMinor],
      ];
      expect(numbers(table), numbers(beforeTable));
    });
  });

  group('the exports', () {
    Future<ReportDocument> statement() => builder().accountStatement(ali.id);

    test('the text says who issued the report', () async {
      branding = const ReportBranding(nameAr: 'عبدالرحمن شرف', phone: '777123456');

      final text = const ReportTextBuilder().build(await statement());

      expect(text, contains('الصادر من: عبدالرحمن شرف'));
      expect(text, contains('الهاتف: 777123456'));
    });

    test('the text has no issuer lines without a profile', () async {
      final text = const ReportTextBuilder().build(await statement());

      expect(text, isNot(contains('الصادر من')));
    });

    test('the spreadsheet lists the issuer above the report details', () async {
      branding = const ReportBranding(
        nameAr: 'عبدالرحمن شرف',
        nameEn: 'Abdulrahman',
        addressAr: 'صنعاء',
        phone: '777123456',
        email: 'a@b.com',
        logo: null,
      );

      final bytes = ReportXlsxWriter().write(await statement());
      final archive = ZipDecoder().decodeBytes(bytes);
      final sheet = XmlDocument.parse(
        utf8.decode(
          archive.files
                  .firstWhere((f) => f.name == 'xl/worksheets/sheet1.xml')
                  .content
              as List<int>,
        ),
      );
      final texts = sheet.findAllElements('t').map((e) => e.innerText).toList();

      for (final expected in [
        'الجهة',
        'عبدالرحمن شرف',
        'الاسم الإنجليزي',
        'Abdulrahman',
        'العنوان',
        'صنعاء',
        'الهاتف',
        '777123456',
        'البريد الإلكتروني',
        'a@b.com',
      ]) {
        expect(texts, contains(expected));
      }
    });

    test('the PDF draws the logo, the signature and the stamp', () async {
      branding = ReportBranding(
        nameAr: 'عبدالرحمن شرف',
        nameEn: 'Abdulrahman',
        addressAr: 'صنعاء',
        phone: '777123456',
        logo: _png,
        signature: _png,
        stamp: _png,
      );
      final withBranding = await ReportPdfRenderer(
        fonts: _fonts(),
      ).render(await statement());

      branding = const ReportBranding(nameAr: 'عبدالرحمن شرف');
      final textOnly = await ReportPdfRenderer(
        fonts: _fonts(),
      ).render(await statement());

      branding = null;
      final plain = await ReportPdfRenderer(
        fonts: _fonts(),
      ).render(await statement());

      expect(latin1.decode(withBranding.sublist(0, 5)), '%PDF-');
      expect(_images(plain), 0);
      expect(_images(textOnly), 0);
      expect(_images(withBranding), greaterThanOrEqualTo(3));
      expect(withBranding.length, greaterThan(plain.length));
    });

    test('an unreadable picture is left out instead of failing the report',
        () async {
      branding = ReportBranding(
        nameAr: 'عبدالرحمن',
        logo: Uint8List.fromList([1, 2, 3, 4, 5]),
        signature: Uint8List.fromList([9, 9, 9]),
      );

      final pdf = await ReportPdfRenderer(
        fonts: _fonts(),
      ).render(await statement());

      expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
      expect(_images(pdf), 0);
    });

    test('a report with only a signature has no letterhead but keeps the signature',
        () async {
      branding = ReportBranding(signature: _png);
      final document = await statement();

      expect(document.branding!.hasLetterhead, isFalse);
      expect(document.branding!.hasSignatures, isTrue);
      final pdf = await ReportPdfRenderer(fonts: _fonts()).render(document);
      expect(_images(pdf), greaterThanOrEqualTo(1));
    });
  });
}
