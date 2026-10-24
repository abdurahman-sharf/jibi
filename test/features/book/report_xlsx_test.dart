import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_builder.dart';
import 'package:jibi/features/book/reports/report_models.dart';
import 'package:jibi/features/book/reports/report_xlsx.dart';
import '../../support/test_currencies.dart';
import '../../support/book_wallets.dart';

Map<String, XmlDocument> _open(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return {
    for (final file in archive.files)
      if (file.isFile)
        file.name: XmlDocument.parse(utf8.decode(file.content as List<int>)),
  };
}

extension on XmlDocument {
  List<XmlElement> cells() => findAllElements('c').toList();

  XmlElement cell(String ref) =>
      findAllElements('c').singleWhere((c) => c.getAttribute('r') == ref);

  String cellText(String ref) {
    final c = cell(ref);
    final t = c.findAllElements('t');
    return t.isEmpty ? '' : t.first.innerText;
  }

  String? cellNumber(String ref) {
    final v = cell(ref).findAllElements('v');
    return v.isEmpty ? null : v.first.innerText;
  }
}

void main() {
  late InMemoryBookRepository repository;
  late BookServices book;
  late BookReportBuilder reports;
  late BookCategory category;
  late BookAccount ali;
  late BookAccount saudi;

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
    saudi = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'حساب سعودي',
        currencyCode: 'SAR',
      ),
    );
    Future<void> tx(BookAccount a, EntryType t, int minor, String date, [String? d]) =>
        book.transactions.create(
          BookTransactionDraft(
            accountId: a.id,
            currencyCode: a.id == saudi.id ? 'SAR' : 'YER',
            walletId: seededMainWalletId,
            type: t,
            amountMinor: minor,
            date: date,
            details: d,
          ),
        );
    await tx(ali, EntryType.debit, 30000, '2024-12-13', 'يوم موت أبي');
    await tx(ali, EntryType.credit, 5000, '2025-01-10');
    await tx(saudi, EntryType.debit, 485000, '2025-02-01');
    await tx(saudi, EntryType.credit, 100000, '2025-02-15');
  });

  tearDown(() => repository.dispose());

  test('the package is a well-formed xlsx with the required parts', () async {
    final doc = await reports.accountStatement(ali.id);
    final parts = _open(const ReportXlsxWriter().write(doc));

    expect(parts.keys, containsAll([
      '[Content_Types].xml',
      '_rels/.rels',
      'xl/workbook.xml',
      'xl/_rels/workbook.xml.rels',
      'xl/styles.xml',
      'xl/worksheets/sheet1.xml',
    ]));
    // Every part parsed as XML (well-formedness), and the sheet is RTL.
    final sheet = parts['xl/worksheets/sheet1.xml']!;
    expect(sheet.findAllElements('sheetView').single.getAttribute('rightToLeft'), '1');
    expect(parts['xl/workbook.xml']!.findAllElements('sheet').single.getAttribute('name'), 'كشف الحساب');
    expect(
      parts['[Content_Types].xml']!.findAllElements('Override').map((e) => e.getAttribute('PartName')),
      contains('/xl/worksheets/sheet1.xml'),
    );
  });

  test('a statement sheet has real numbers and the side in its own column', () async {
    final doc = await reports.accountStatement(ali.id);
    final sheet = _open(const ReportXlsxWriter().write(doc))['xl/worksheets/sheet1.xml']!;

    // Header block: title, info, generated stamp, figures, then the table.
    expect(sheet.cellText('A1'), 'كشف الحساب');
    expect(sheet.cellText('A2'), 'الحساب');
    expect(sheet.cellText('B2'), 'علي أخي');
    expect(sheet.cellText('B5'), 'كل الفترات');
    expect(sheet.cellText('B6'), '2026-09-20 15:30');

    // Find the table header row by its first title.
    final header = sheet.cells().firstWhere((c) => c.findAllElements('t').any((t) => t.innerText == 'التاريخ'));
    final headerRow = int.parse(RegExp(r'\d+').firstMatch(header.getAttribute('r')!)!.group(0)!);
    final titles = [
      for (final col in ['A', 'B', 'C', 'D', 'E', 'F', 'G'])
        sheet.cellText('$col$headerRow'),
    ];
    // The balance column is split into amount + side.
    expect(titles, [
      'التاريخ',
      'التفاصيل',
      'وسيلة الدفع',
      'مدين',
      'دائن',
      'الرصيد',
      'الجانب',
    ]);

    final first = headerRow + 2; // after the opening row
    expect(sheet.cellText('A$first'), '2024-12-13');
    expect(sheet.cellText('B$first'), 'يوم موت أبي (TX-000001)');
    expect(sheet.cellNumber('D$first'), '30000');
    expect(sheet.cellNumber('F$first'), '30000');
    expect(sheet.cellText('G$first'), 'مدين');
    final second = first + 1;
    expect(sheet.cellNumber('E$second'), '5000');
    expect(sheet.cellNumber('F$second'), '25000');
    // A blank amount is an empty cell, not a zero or a text.
    expect(sheet.cellNumber('E$first'), isNull);
    // Totals row is the last one.
    final totals = second + 1;
    expect(sheet.cellText('B$totals'), 'الإجمالي');
    expect(sheet.cellNumber('D$totals'), '30000');
    expect(sheet.cellNumber('E$totals'), '5000');
    expect(sheet.cellNumber('F$totals'), '25000');
    // Amount cells use number styles (not the text style 3).
    expect(sheet.cell('D$first').getAttribute('s'), '5');
    expect(sheet.cell('B$first').getAttribute('s'), '3');
  });

  test('decimals are exact and use the currency number format', () async {
    final doc = await reports.accountStatement(saudi.id);
    final sheet = _open(const ReportXlsxWriter().write(doc))['xl/worksheets/sheet1.xml']!;
    final header = sheet.cells().firstWhere((c) => c.findAllElements('t').any((t) => t.innerText == 'التاريخ'));
    final row = int.parse(RegExp(r'\d+').firstMatch(header.getAttribute('r')!)!.group(0)!) + 2;

    expect(sheet.cellNumber('D$row'), '4850.00');
    expect(sheet.cell('D$row').getAttribute('s'), '7'); // #,##0.00
    expect(sheet.cellNumber('E${row + 1}'), '1000.00');
    expect(sheet.cellNumber('F${row + 1}'), '3850.00');
    expect(sheet.cellText('G${row + 1}'), 'مدين');
  });

  test('one sheet per currency, named by its code', () async {
    final doc = await reports.categoryDetails(category.id);
    final parts = _open(const ReportXlsxWriter().write(doc));
    final names = parts['xl/workbook.xml']!
        .findAllElements('sheet')
        .map((e) => e.getAttribute('name'))
        .toList();

    expect(names, ['SAR', 'YER']);
    expect(parts.keys, containsAll(['xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml']));
    final yer = parts['xl/worksheets/sheet2.xml']!;
    expect(yer.cellText('A5'), 'العملة');
    expect(yer.cellText('B5'), 'ريال يمني (YER)');
    // The account rows carry numeric debit/credit and a side.
    final aliCell = yer.cells().firstWhere(
      (c) => c.findAllElements('t').any((t) => t.innerText == 'علي أخي'),
    );
    final row = int.parse(RegExp(r'\d+').firstMatch(aliCell.getAttribute('r')!)!.group(0)!);
    expect(yer.cellNumber('B$row'), '30000');
    expect(yer.cellNumber('C$row'), '5000');
    expect(yer.cellNumber('D$row'), '25000');
    expect(yer.cellText('E$row'), 'مدين');
    expect(yer.cellText('F$row'), 'YER');
  });

  test('monthly report keeps months and balances', () async {
    final doc = await reports.categoryMonthly(category.id, year: 2025, currencyCode: 'SAR');
    final sheet = _open(const ReportXlsxWriter().write(doc))['xl/worksheets/sheet1.xml']!;
    final month = sheet.cells().firstWhere(
      (c) => c.findAllElements('t').any((t) => t.innerText.startsWith('2025-02')),
    );
    final row = int.parse(RegExp(r'\d+').firstMatch(month.getAttribute('r')!)!.group(0)!);
    expect(sheet.cellNumber('B$row'), '4850.00');
    expect(sheet.cellNumber('C$row'), '1000.00');
    expect(sheet.cellNumber('D$row'), '3850.00');
  });

  test('XML special characters and control characters are handled', () async {
    final tricky = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'شركة <أ> & "ب"',
        currencyCode: 'YER',
      ),
    );
    await book.transactions.create(
      BookTransactionDraft(
        accountId: tricky.id,
        currencyCode: 'YER',
        walletId: seededMainWalletId,
        type: EntryType.debit,
        amountMinor: 1,
        date: '2025-01-01',
        details: 'سطر\u0001خفي <&>',
      ),
    );
    final doc = await reports.accountStatement(tricky.id);
    final sheet = _open(const ReportXlsxWriter().write(doc))['xl/worksheets/sheet1.xml']!;

    expect(sheet.cellText('B2'), 'شركة <أ> & "ب"');
    final detail = sheet.cells().firstWhere(
      (c) => c.findAllElements('t').any((t) => t.innerText.contains('سطر')),
    );
    expect(detail.findAllElements('t').first.innerText, 'سطرخفي <&> (TX-000005)');
  });

  test('sheet names are legal and unique', () {
    ReportBlock block(String heading) => ReportBlock(
      heading: heading,
      currencyCode: null,
      table: const ReportTable(
        columns: [ReportColumn('س')],
        rows: [
          [ReportCell('1')],
        ],
      ),
    );
    final doc = ReportDocument(
      kind: ReportKind.categoryDetails,
      title: 'تقرير: خاص/جداً؟',
      info: const [],
      blocks: [block('A[1]:*?'), block('A[1]:*?'), block('x' * 50)],
      generatedAt: DateTime(2026),
      fileBaseName: 'f',
    );
    final names = _open(const ReportXlsxWriter().write(doc))['xl/workbook.xml']!
        .findAllElements('sheet')
        .map((e) => e.getAttribute('name')!)
        .toList();
    expect(names, hasLength(3));
    expect(names.toSet(), hasLength(3));
    for (final name in names) {
      expect(name.length, lessThanOrEqualTo(31));
      expect(name, isNot(matches(RegExp(r'[\[\]:*?/\\]'))));
    }
  });

  test('a report without data still opens and says why', () async {
    final empty = await book.categories.create(const BookCategoryDraft(name: 'فارغ'));
    final doc = await reports.categoryTotals(empty.id);
    final parts = _open(const ReportXlsxWriter().write(doc));
    final sheet = parts['xl/worksheets/sheet1.xml']!;
    expect(sheet.findAllElements('t').any((t) => t.innerText.contains('لا توجد حسابات')), isTrue);
  });

  test('many columns get spreadsheet column letters (AA, AB, ...)', () {
    final columns = [for (var i = 0; i < 30; i++) ReportColumn('c$i')];
    final doc = ReportDocument(
      kind: ReportKind.categoryDetails,
      title: 'عريض',
      info: const [],
      blocks: [
        ReportBlock(
          table: ReportTable(
            columns: columns,
            rows: [
              [for (var i = 0; i < 30; i++) ReportCell('v$i')],
            ],
          ),
        ),
      ],
      generatedAt: DateTime(2026),
      fileBaseName: 'wide',
    );
    final sheet = _open(const ReportXlsxWriter().write(doc))['xl/worksheets/sheet1.xml']!;
    expect(sheet.cellText('Z4'), 'c25');
    expect(sheet.cellText('AA4'), 'c26');
    expect(sheet.cellText('AD4'), 'c29');
    expect(sheet.cellText('AD5'), 'v29');
  });

  test('big amounts stay exact (no floating point)', () {
    final doc = ReportDocument(
      kind: ReportKind.categoryDetails,
      title: 'كبير',
      info: const [],
      blocks: [
        ReportBlock(
          fractionDigits: 3,
          table: const ReportTable(
            columns: [ReportColumn('م', kind: ReportColumnKind.amount)],
            rows: [
              [ReportCell('x', amountMinor: 9007199254740991)],
              [ReportCell('x', amountMinor: 5)],
            ],
          ),
        ),
      ],
      generatedAt: DateTime(2026),
      fileBaseName: 'big',
    );
    final sheet = _open(const ReportXlsxWriter().write(doc))['xl/worksheets/sheet1.xml']!;
    expect(sheet.cellNumber('A5'), '9007199254740.991');
    expect(sheet.cellNumber('A6'), '0.005');
    expect(sheet.cell('A5').getAttribute('s'), '8'); // #,##0.000
  });

  test('custom side labels are used in the side column', () async {
    final doc = await reports.accountStatement(ali.id);
    const writer = ReportXlsxWriter(
      labels: BookLabels(debit: 'مستحق لي', credit: 'مستحق علي'),
    );
    final sheet = _open(writer.write(doc))['xl/worksheets/sheet1.xml']!;
    expect(sheet.findAllElements('t').any((t) => t.innerText == 'مستحق لي'), isTrue);
  });
}
