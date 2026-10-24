import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_builder.dart';
import 'package:jibi/features/book/reports/report_text.dart';
import '../../support/test_currencies.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/book_wallets.dart';

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
        openingMinor: 1000,
        openingType: OpeningType.debit,
      ),
    );
  });

  tearDown(() => repository.dispose());

  Future<void> tx(EntryType type, int minor, String date, [String? details]) =>
      book.transactions.create(
        BookTransactionDraft(
          accountId: ali.id,
          currencyCode: 'YER',
          walletId: seededMainWalletId,
          type: type,
          amountMinor: minor,
          date: date,
          details: details,
        ),
      );

  /// The text without the invisible right-to-left marks, line by line.
  List<String> lines(String text) =>
      text.split('\n').map((line) => line.replaceAll('\u200F', '')).toList();

  test('a statement lists its figures, rows and totals', () async {
    await tx(EntryType.debit, 30000, '2024-12-13', 'يوم موت أبي علي');
    await tx(EntryType.credit, 5000, '2025-01-10');
    final text = const ReportTextBuilder().build(
      await reports.accountStatement(ali.id),
    );
    final all = lines(text);

    expect(all.first, '*كشف الحساب*');
    expect(all, contains('الحساب: علي أخي'));
    expect(all, contains('التصنيف: حسابات اليمن'));
    expect(all.any((line) => line.startsWith('الرصيد الافتتاحي')), isTrue);
    expect(
      all,
      contains('• 2024-12-13 | يوم موت أبي علي (TX-000001) | نقدًا | مدين 30,000 | الرصيد 31,000 مدين'),
    );
    // A credit row shows only its own side.
    final credit = all.firstWhere((line) => line.contains('2025-01-10'));
    expect(credit, contains('دائن 5,000'));
    expect(credit, isNot(contains('مدين 5,000')));
    expect(credit, contains('الرصيد 26,000 مدين'));
    // Totals are bold.
    expect(all.any((line) => line.startsWith('*الإجمالي')), isTrue);
    expect(all.last, 'جيبي — 2026-09-20 15:30');
  });

  test('the payment reads نقدًا or the wallet name, never the main wallet name',
      () async {
    final box = await book.wallets.create(
      WalletDraft.single(name: 'حساب الراجحي', currencyCode: 'YER'),
    );
    await tx(EntryType.debit, 100, '2025-01-01', 'دفعة نقدية');
    await book.transactions.create(
      BookTransactionDraft(
        accountId: ali.id,
        currencyCode: 'YER',
        type: EntryType.debit,
        amountMinor: 200,
        date: '2025-01-02',
        details: 'عبر المحفظة',
        walletId: box.id,
      ),
    );
    final text = const ReportTextBuilder().build(
      await reports.accountStatement(ali.id),
    );
    final all = lines(text);

    expect(all.firstWhere((line) => line.contains('دفعة نقدية')), contains('| نقدًا |'));
    expect(
      all.firstWhere((line) => line.contains('عبر المحفظة')),
      contains('| حساب الراجحي |'),
    );
    expect(text, isNot(contains('الصندوق الرئيسي')));
  });

  test('every line starts with a right-to-left mark', () async {
    await tx(EntryType.debit, 100, '2025-01-01', 'Invoice INV-1');
    final text = const ReportTextBuilder().build(
      await reports.accountStatement(ali.id),
    );
    for (final line in text.split('\n').where((line) => line.isNotEmpty)) {
      expect(line.codeUnitAt(0), 0x200F, reason: line);
    }
  });

  test('a long statement keeps the newest rows and points to the PDF', () async {
    for (var index = 1; index <= 40; index++) {
      final month = index <= 28 ? '01' : '02';
      final day = index <= 28 ? index : index - 28;
      await tx(EntryType.debit, index, '2025-$month-${day.toString().padLeft(2, '0')}');
    }
    final text = const ReportTextBuilder(maxRows: 10).build(
      await reports.accountStatement(ali.id),
    );
    final all = lines(text);
    final rows = all.where((line) => line.startsWith('• ')).toList();
    // 40 transactions + the opening row = 41 rows, the last 10 are shown.
    expect(rows, hasLength(10));
    expect(rows.last, contains('TX-000040'));
    expect(rows.first, contains('TX-000031'));
    expect(all.any((line) => line.contains('31 صفاً أقدم')), isTrue);
    expect(all.any((line) => line.contains('ملف PDF')), isTrue);
    // The totals still describe everything.
    expect(all.any((line) => line.startsWith('*الإجمالي')), isTrue);
  });

  test('a short report has no truncation note', () async {
    await tx(EntryType.debit, 100, '2025-01-01');
    final text = const ReportTextBuilder().build(
      await reports.accountStatement(ali.id),
    );
    expect(text, isNot(contains('ملف PDF')));
  });

  test('category details keep the first accounts and each currency apart', () async {
    final sar = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: 'حساب سعودي',
        currencyCode: 'SAR',
      ),
    );
    await tx(EntryType.debit, 30000, '2025-01-01');
    await book.transactions.create(
      BookTransactionDraft(
        accountId: sar.id,
        currencyCode: 'SAR',
        walletId: seededMainWalletId,
        type: EntryType.credit,
        amountMinor: 250050,
        date: '2025-01-02',
      ),
    );
    final text = const ReportTextBuilder().build(
      await reports.categoryDetails(category.id),
    );
    final all = lines(text);
    expect(all.any((line) => line.startsWith('*') && line.contains('SAR')), isTrue);
    expect(all.any((line) => line.startsWith('*') && line.contains('YER')), isTrue);
    // The currency is in the heading, not repeated in every row.
    final aliRow = all.firstWhere((line) => line.contains('علي أخي'));
    expect(aliRow, isNot(contains('YER')));
    // The opening balance (1,000 debit) is part of the debit total.
    expect(aliRow, contains('مدين 31,000'));
    final saudiRow = all.firstWhere((line) => line.contains('حساب سعودي'));
    expect(saudiRow, contains('دائن 2,500.50'));
  });

  test('category totals are figures per currency', () async {
    await tx(EntryType.debit, 30000, '2025-01-01');
    final text = const ReportTextBuilder().build(
      await reports.categoryTotals(category.id),
    );
    final all = lines(text);
    expect(all.first, '*إجمالي المبالغ*');
    expect(all.any((line) => line.startsWith('إجمالي مدين: 31,000')), isTrue);
  });

  test('an empty report says so', () async {
    final empty = await book.categories.create(
      const BookCategoryDraft(name: 'فارغ'),
    );
    final doc = await reports.categoryTotals(empty.id);
    final text = const ReportTextBuilder().build(doc);
    expect(lines(text).first, '*إجمالي المبالغ*');
    for (final note in doc.notes) {
      expect(text, contains(note));
    }
  });
}
