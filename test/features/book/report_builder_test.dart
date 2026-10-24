import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_builder.dart';
import 'package:jibi/features/book/reports/report_models.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/book_wallets.dart';
import '../../support/test_currencies.dart';

void main() {
  late InMemoryBookRepository repository;
  late BookServices book;
  late BookReportBuilder reports;
  late BookCategory category;
  late BookAccount ali;
  late BookAccount incoming;
  late BookAccount saudi;
  late BookAccount old;

  /// The currency each account was opened with (an account has none of its
  /// own any more: a transaction names its currency, which these tests keep
  /// equal to the account's so the old single-currency expectations still read).
  final accountCurrency = <String, String>{};

  Future<BookAccount> account(
    String name,
    String currency, {
    int opening = 0,
    OpeningType type = OpeningType.zero,
  }) async {
    final created = await book.accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: name,
        currencyCode: currency,
        openingMinor: opening,
        openingType: type,
      ),
    );
    accountCurrency[created.id] = currency;
    return created;
  }

  Future<BookTransaction> tx(
    BookAccount a,
    EntryType type,
    int amount,
    String date, {
    String? details,
    String walletId = seededMainWalletId,
  }) => book.transactions.create(
    BookTransactionDraft(
      accountId: a.id,
      currencyCode: accountCurrency[a.id] ?? 'YER',
      type: type,
      amountMinor: amount,
      date: date,
      details: details,
      walletId: walletId,
    ),
  );

  Future<Wallet> wallet(
    String name,
    String currency, {
    int opening = 0,
  }) => book.wallets.create(
    WalletDraft.single(
      name: name,
      currencyCode: currency,
      openingMinor: opening,
    ),
  );

  Future<WalletTransaction> deposit(Wallet w, int amount, String date) =>
      book.walletTransactions.deposit(
        WalletDepositDraft(walletId: w.id, amountMinor: amount, date: date),
      );

  Future<WalletTransaction> withdraw(Wallet w, int amount, String date) =>
      book.walletTransactions.withdraw(
        WalletWithdrawalDraft(walletId: w.id, amountMinor: amount, date: date),
      );

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
    ali = await account('علي أخي', 'YER', opening: 1000, type: OpeningType.debit);
    incoming = await account('التحويلات الواردة', 'YER');
    await account('أسامة أخي', 'YER');
    saudi = await account('حساب سعودي', 'SAR');
    old = await account('قديم', 'YER');
    await tx(ali, EntryType.debit, 30000, '2024-12-13', details: 'يوم موت أبي علي');
    await tx(ali, EntryType.credit, 5000, '2025-01-10', details: 'سداد');
    await tx(ali, EntryType.debit, 100, '2026-09-20');
    await tx(incoming, EntryType.credit, 302500, '2025-01-05', details: 'حوالة');
    await tx(saudi, EntryType.debit, 485000, '2025-02-01');
    await tx(saudi, EntryType.credit, 100000, '2025-02-15');
    await tx(old, EntryType.debit, 999900, '2025-03-01');
    await book.accounts.setStatus(old.id, BookAccountStatus.archived);
    // A deleted transaction never appears anywhere.
    final gone = await tx(ali, EntryType.debit, 777, '2025-06-06');
    await book.transactions.delete(gone.id);
  });

  tearDown(() => repository.dispose());

  ReportBlock block(ReportDocument doc, String code) =>
      doc.blocks.singleWhere((b) => b.currencyCode == code);

  group('category totals', () {
    test('per currency, archived accounts left out', () async {
      final doc = await reports.categoryTotals(category.id);

      expect(doc.title, 'إجمالي المبالغ');
      expect(doc.blocks.map((b) => b.currencyCode), ['SAR', 'YER']);
      final yer = block(doc, 'YER').figures;
      // Debit: 1,000 opening + 30,000 + 100. Credit: 5,000 + 302,500.
      expect(yer.map((f) => f.label), [
        'عدد الحسابات',
        'إجمالي مدين',
        'إجمالي دائن',
        'الرصيد الصافي',
      ]);
      expect(yer[1].value, '31,100');
      expect(yer[2].value, '307,500');
      expect(yer[3].value, '276,400 دائن');
      expect(yer[3].side, BalanceSide.credit);
      final sar = block(doc, 'SAR').figures;
      expect(sar[1].value, '4,850.00');
      expect(sar[2].value, '1,000.00');
      expect(sar[3].value, '3,850.00 مدين');
    });

    test('agrees with the engine the screens use', () async {
      final doc = await reports.categoryTotals(category.id);
      final summaries = await repository.accountSummaries(
        categoryId: category.id,
        includeArchived: false,
      );
      for (final total in BookBalanceEngine.currencyTotals(summaries)) {
        final figures = block(doc, total.currencyCode).figures;
        expect(figures[1].value.replaceAll(',', ''), contains(
          (total.debitMinor ~/ (total.currencyCode == 'SAR' ? 100 : 1)).toString(),
        ));
      }
    });

    test('an empty category says so', () async {
      final empty = await book.categories.create(
        const BookCategoryDraft(name: 'فارغ'),
      );
      final doc = await reports.categoryTotals(empty.id);
      expect(doc.blocks, isEmpty);
      expect(doc.notes.any((n) => n.contains('لا توجد حسابات')), isTrue);
    });

    test('an unknown category is refused', () async {
      await expectLater(
        reports.categoryTotals('nope'),
        throwsA(isA<NotFoundException>()),
      );
    });
  });

  group('category details', () {
    test('one row per account with debit, credit, balance and currency', () async {
      final doc = await reports.categoryDetails(category.id);
      final yer = block(doc, 'YER').table!;

      expect(yer.columns.map((c) => c.title), [
        'الحساب',
        'مدين',
        'دائن',
        'الرصيد',
        'العملة',
      ]);
      // Sorted by name; the archived account is absent, and so is an account
      // that uses no currency yet (no opening balance, no transaction): it has
      // nothing to show in any currency's table.
      expect(yer.rows.map((r) => r.first.text), [
        'التحويلات الواردة',
        'علي أخي',
      ]);
      final aliRow = yer.rows.last;
      expect(aliRow[1].text, '31,100');
      expect(aliRow[2].text, '5,000');
      expect(aliRow[3].text, '26,100 مدين');
      expect(aliRow[3].amountMinor, 26100);
      expect(aliRow[3].side, BalanceSide.debit);
      expect(aliRow[4].text, 'YER');
      final incomingRow = yer.rows.first;
      expect(incomingRow[2].text, '302,500');
      expect(incomingRow[3].text, '302,500 دائن');
      // Totals row.
      expect(yer.totals![1].text, '31,100');
      expect(yer.totals![2].text, '307,500');
      expect(yer.totals![3].text, '276,400 دائن');
    });

    test('currencies never share a table', () async {
      final doc = await reports.categoryDetails(category.id);
      final sar = block(doc, 'SAR').table!;
      expect(sar.rows, hasLength(1));
      expect(sar.rows.single[3].text, '3,850.00 مدين');
    });
  });

  group('account statement', () {
    test('carries the opening balance and a running balance', () async {
      final doc = await reports.accountStatement(ali.id);
      final table = doc.blocks.single.table!;

      expect(doc.title, 'كشف الحساب');
      expect(doc.info.map((i) => '${i.label}: ${i.value}'), [
        'الحساب: علي أخي',
        'التصنيف: حسابات اليمن',
        'العملة: ريال يمني (YER)',
        'الفترة: كل الفترات',
      ]);
      expect(table.columns.map((c) => c.title), [
        'التاريخ',
        'التفاصيل',
        'وسيلة الدفع',
        'مدين',
        'دائن',
        'الرصيد',
      ]);
      // Opening row + three live transactions (the deleted one is absent).
      expect(table.rows, hasLength(4));
      expect(table.rows.first[1].text, 'الرصيد الافتتاحي للفترة');
      expect(table.rows.first[5].text, '1,000 مدين');
      expect(table.rows[1][0].text, '2024-12-13');
      expect(table.rows[1][1].text, 'يوم موت أبي علي (TX-000001)');
      expect(table.rows[1][2].text, 'نقدًا'); // paid through the main wallet
      expect(table.rows[1][3].text, '30,000');
      expect(table.rows[1][4].text, '');
      expect(table.rows[1][5].text, '31,000 مدين');
      expect(table.rows[2][4].text, '5,000');
      expect(table.rows[2][5].text, '26,000 مدين');
      expect(table.rows[3][5].text, '26,100 مدين');
      expect(table.totals![3].text, '30,100');
      expect(table.totals![4].text, '5,000');
      expect(table.totals![5].text, '26,100 مدين');
    });

    test('shows نقدًا for the main wallet and never its own name', () async {
      final doc = await reports.accountStatement(ali.id);
      final table = doc.blocks.single.table!;
      final paid = [
        for (final r in table.rows.skip(1)) r[2].text,
      ];
      expect(paid, everyElement('نقدًا'));
      expect(paid, isNotEmpty);
      expect(
        [for (final r in table.rows) r[2].text],
        isNot(contains('الصندوق الرئيسي')),
      );
    });

    test('shows the wallet name when the transaction is paid through one', () async {
      final box = await wallet('حساب الراجحي', 'YER');
      final withWallet = await tx(
        ali,
        EntryType.debit,
        400,
        '2026-01-02',
        walletId: box.id,
      );
      final doc = await reports.accountStatement(ali.id);
      final table = doc.blocks.single.table!;
      final row = table.rows.singleWhere(
        (r) => r[1].text.contains(withWallet.number),
      );
      expect(row[2].text, 'حساب الراجحي');
    });

    test('a transaction from before wallets were linked shows no payment', () async {
      final now = DateTime.utc(2020);
      await repository.write(
        (writer) => writer.putTransaction(
          BookTransaction(
            id: 'legacy-1',
            number: 'TX-900001',
            accountId: ali.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 1,
            date: '2026-01-03',
            createdAt: now,
            updatedAt: now,
          ),
        ),
      );
      final doc = await reports.accountStatement(ali.id);
      final table = doc.blocks.single.table!;
      final row = table.rows.singleWhere(
        (r) => r[1].text.contains('TX-900001'),
      );
      expect(row[2].text, '');
    });

    test('report figures agree with the stored balances and totals', () async {
      final doc = await reports.accountStatement(ali.id);
      final summary = (await repository.accountSummary(ali.id))!;
      final table = doc.blocks.single.table!;
      final stored = (await repository.transactionPage(
        ali.id,
        newestFirst: false,
        limit: 50,
      )).items;
      for (var index = 0; index < stored.length; index++) {
        // Row 0 is the opening row.
        final cell = table.rows[index + 1][5];
        expect(cell.amountMinor, stored[index].balanceAfter.abs());
      }
      final figures = doc.blocks.single.figures;
      expect(figures.last.value, '26,100 مدين');
      expect(summary.totalsOf('YER')!.netMinor, 26100);
    });

    test('a period carries in the balance from before it', () async {
      final doc = await reports.accountStatement(
        ali.id,
        fromDate: '2025-01-01',
        toDate: '2025-12-31',
      );
      final table = doc.blocks.single.table!;

      expect(doc.info.last.value, 'من 2025-01-01 إلى 2025-12-31');
      // 1,000 opening + 30,000 (2024) carried in.
      expect(table.rows.first[5].text, '31,000 مدين');
      expect(table.rows, hasLength(2));
      expect(table.rows[1][4].text, '5,000');
      expect(table.rows[1][5].text, '26,000 مدين');
      final figures = doc.blocks.single.figures;
      expect(figures[0].value, '31,000 مدين');
      expect(figures[1].value, '0');
      expect(figures[2].value, '5,000');
      expect(figures[3].value, '26,000 مدين');
      // The 2026 transaction is after the period.
      expect(table.rows.any((r) => r[0].text == '2026-09-20'), isFalse);
    });

    test('a period without transactions keeps the balance and says so', () async {
      final doc = await reports.accountStatement(
        ali.id,
        fromDate: '2025-07-01',
        toDate: '2025-07-31',
      );
      final table = doc.blocks.single.table!;
      expect(table.emptyMessage, 'لا توجد عمليات في هذه الفترة.');
      expect(table.rows, hasLength(1));
      expect(table.totals![5].text, '26,000 مدين');
    });

    test('an account in credit is worded as credit', () async {
      final doc = await reports.accountStatement(incoming.id);
      final table = doc.blocks.single.table!;
      expect(table.rows.first[5].text, '0 متعادل');
      expect(table.rows[1][4].text, '302,500');
      expect(table.rows[1][5].text, '302,500 دائن');
      expect(table.rows[1][5].side, BalanceSide.credit);
    });

    test('decimals follow the currency', () async {
      final doc = await reports.accountStatement(saudi.id);
      final table = doc.blocks.single.table!;
      expect(doc.blocks.single.fractionDigits, 2);
      expect(table.rows[1][3].text, '4,850.00');
      expect(table.rows[2][4].text, '1,000.00');
      expect(table.rows[2][5].text, '3,850.00 مدين');
    });

    test('bad dates and ranges are refused', () async {
      await expectLater(
        reports.accountStatement(ali.id, fromDate: '2025-02-30'),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        reports.accountStatement(
          ali.id,
          fromDate: '2026-01-01',
          toDate: '2025-01-01',
        ),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        reports.accountStatement('nope'),
        throwsA(isA<NotFoundException>()),
      );
    });
  });

  group('monthly account statement', () {
    test('covers one month with its opening and closing balance', () async {
      final doc = await reports.accountMonthlyStatement(
        ali.id,
        year: 2025,
        month: 1,
      );
      final table = doc.blocks.single.table!;

      expect(doc.title, 'كشف الحساب الشهري');
      expect(doc.info.last.value, 'يناير 2025');
      expect(table.rows.first[1].text, 'الرصيد بداية الشهر');
      expect(table.rows.first[5].text, '31,000 مدين');
      expect(table.rows[1][0].text, '2025-01-10');
      expect(doc.blocks.single.figures.first.label, 'الرصيد بداية الشهر');
      expect(doc.blocks.single.figures.last.label, 'الرصيد نهاية الشهر');
      expect(doc.blocks.single.figures.last.value, '26,000 مدين');
    });

    test('February has the right last day (leap year)', () async {
      await tx(ali, EntryType.debit, 1, '2024-02-29');
      final doc = await reports.accountMonthlyStatement(
        ali.id,
        year: 2024,
        month: 2,
      );
      expect(doc.blocks.single.table!.rows.any((r) => r[0].text == '2024-02-29'), isTrue);
    });

    test('rejects an impossible month', () async {
      expect(
        () => reports.accountMonthlyStatement(ali.id, year: 2025, month: 13),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('wallet statement', () {
    test('carries the opening balance and a running balance', () async {
      final cash = await wallet('الصندوق', 'YER', opening: 1000);
      await deposit(cash, 500, '2025-01-10');
      await withdraw(cash, 200, '2025-01-11');
      final doc = await reports.walletStatement(cash.id);
      final table = doc.blocks.single.table!;

      expect(doc.title, 'كشف المحفظة');
      expect(doc.info.map((i) => '${i.label}: ${i.value}'), [
        'المحفظة: الصندوق',
        'العملة: ريال يمني (YER)',
        'الفترة: كل الفترات',
      ]);
      expect(table.columns.map((c) => c.title), [
        'التاريخ',
        'الوصف',
        'وارد',
        'صادر',
        'الرصيد',
      ]);
      // No "مدين/دائن" wording — a wallet balance is a plain signed amount.
      expect(table.rows, hasLength(3));
      expect(table.rows.first[1].text, 'الرصيد الافتتاحي للفترة');
      expect(table.rows.first[4].text, '1,000');
      expect(table.rows[1][0].text, '2025-01-10');
      expect(table.rows[1][1].text, contains('إيداع'));
      expect(table.rows[1][2].text, '500');
      expect(table.rows[1][3].text, '');
      expect(table.rows[1][4].text, '1,500');
      expect(table.rows[2][1].text, contains('سحب'));
      expect(table.rows[2][3].text, '200');
      expect(table.rows[2][4].text, '1,300');
      expect(table.totals![2].text, '500');
      expect(table.totals![3].text, '200');
      expect(table.totals![4].text, '1,300');
      final figures = doc.blocks.single.figures;
      expect(figures.map((f) => f.label), [
        'الرصيد الافتتاحي للفترة',
        'إجمالي الوارد',
        'إجمالي الصادر',
        'الرصيد النهائي',
      ]);
      expect(figures.last.value, '1,300');
    });

    test('a negative balance is shown with a minus sign, not "دائن"', () async {
      final cash = await wallet('الصندوق', 'YER');
      await withdraw(cash, 500, '2025-01-10');
      final doc = await reports.walletStatement(cash.id);
      final table = doc.blocks.single.table!;
      expect(table.rows.last[4].text, '-500');
      expect(doc.blocks.single.figures.last.value, '-500');
    });

    test('a movement note is appended to the description', () async {
      final cash = await wallet('الصندوق', 'YER');
      await book.walletTransactions.deposit(
        WalletDepositDraft(
          walletId: cash.id,
          amountMinor: 100,
          date: '2025-01-01',
          notes: 'بيع بضاعة',
        ),
      );
      final doc = await reports.walletStatement(cash.id);
      final table = doc.blocks.single.table!;
      expect(table.rows.last[1].text, contains('بيع بضاعة'));
    });

    test('a period carries in the balance from before it', () async {
      final cash = await wallet('الصندوق', 'YER', opening: 1000);
      await deposit(cash, 500, '2025-01-10');
      await deposit(cash, 700, '2025-06-01');
      final doc = await reports.walletStatement(
        cash.id,
        fromDate: '2025-02-01',
        toDate: '2025-12-31',
      );
      final table = doc.blocks.single.table!;
      expect(doc.info.last.value, 'من 2025-02-01 إلى 2025-12-31');
      // 1,000 opening + 500 (January) carried in.
      expect(table.rows.first[4].text, '1,500');
      expect(table.rows, hasLength(2));
      expect(table.rows[1][2].text, '700');
      expect(table.rows[1][4].text, '2,200');
    });

    test('a period without movements keeps the balance and says so', () async {
      final cash = await wallet('الصندوق', 'YER', opening: 1000);
      final doc = await reports.walletStatement(
        cash.id,
        fromDate: '2025-07-01',
        toDate: '2025-07-31',
      );
      final table = doc.blocks.single.table!;
      expect(table.emptyMessage, 'لا توجد حركات في هذه الفترة.');
      expect(table.rows, hasLength(1));
      expect(table.totals![4].text, '1,000');
    });

    test('decimals follow the currency', () async {
      final sarWallet = await wallet('محفظة سعودية', 'SAR');
      await deposit(sarWallet, 123456, '2025-01-01');
      final doc = await reports.walletStatement(sarWallet.id);
      final table = doc.blocks.single.table!;
      expect(doc.blocks.single.fractionDigits, 2);
      expect(table.rows[1][2].text, '1,234.56');
      expect(table.rows[1][4].text, '1,234.56');
    });

    test('bad dates and an unknown wallet are refused', () async {
      final cash = await wallet('الصندوق', 'YER');
      await expectLater(
        reports.walletStatement(cash.id, fromDate: '2025-02-30'),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        reports.walletStatement('nope'),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('a multi-currency wallet produces one block per currency, each '
        'with its own opening and closing balance', () async {
      final w = await book.wallets.create(
        const WalletDraft(
          name: 'محفظة متعددة',
          openings: [
            WalletOpeningDraft(currencyCode: 'SAR', openingMinor: 1000),
            WalletOpeningDraft(currencyCode: 'USD', openingMinor: 200),
          ],
        ),
      );
      await book.walletTransactions.deposit(
        WalletDepositDraft(
          walletId: w.id,
          currencyCode: 'SAR',
          amountMinor: 500,
          date: '2025-01-10',
        ),
      );
      await book.walletTransactions.deposit(
        WalletDepositDraft(
          walletId: w.id,
          currencyCode: 'USD',
          amountMinor: 50,
          date: '2025-01-10',
        ),
      );

      final all = await reports.walletStatement(w.id);
      expect(all.blocks, hasLength(2));
      final sarBlock = all.blocks.singleWhere((b) => b.currencyCode == 'SAR');
      final usdBlock = all.blocks.singleWhere((b) => b.currencyCode == 'USD');
      // Opening 1000/200 minor + a 500/50 minor deposit, both 2-decimal
      // currencies: 10.00 -> 15.00 and 2.00 -> 2.50.
      expect(sarBlock.figures.first.value, '10.00'); // opening
      expect(sarBlock.figures.last.value, '15.00'); // closing
      expect(usdBlock.figures.first.value, '2.00');
      expect(usdBlock.figures.last.value, '2.50');

      final narrowed = await reports.walletStatement(w.id, currencyCode: 'USD');
      expect(narrowed.blocks, hasLength(1));
      expect(narrowed.blocks.single.currencyCode, 'USD');
    });

    test('the file name mentions the wallet', () async {
      final cash = await wallet('صندوقي', 'YER');
      final doc = await reports.walletStatement(cash.id);
      expect(doc.fileBaseName, 'كشف محفظة صندوقي');
    });
  });

  group('category monthly', () {
    test('month by month with cumulative balances, per currency', () async {
      final doc = await reports.categoryMonthly(category.id, year: 2025);
      final yer = block(doc, 'YER').table!;

      expect(doc.title, 'إجمالي المبالغ شهرياً');
      expect(doc.info.last.value, 'سنة 2025');
      expect(yer.columns.map((c) => c.title), [
        'الشهر',
        'مدين',
        'دائن',
        'الرصيد',
      ]);
      // Before 2025: 1,000 opening + 30,000 = 31,000 debit.
      expect(yer.rows.first[0].text, 'الرصيد قبل الفترة');
      expect(yer.rows.first[3].text, '31,000 مدين');
      // January 2025: credits 5,000 and 302,500.
      expect(yer.rows[1][0].text, '2025-01 · يناير');
      expect(yer.rows[1][2].text, '307,500');
      expect(yer.rows[1][3].text, '276,500 دائن');
      expect(yer.rows, hasLength(2));
      expect(yer.totals![1].text, '0');
      expect(yer.totals![2].text, '307,500');
      expect(yer.totals![3].text, '276,500 دائن');

      final sar = block(doc, 'SAR').table!;
      expect(sar.rows[1][0].text, '2025-02 · فبراير');
      expect(sar.rows[1][1].text, '4,850.00');
      expect(sar.rows[1][2].text, '1,000.00');
      expect(sar.rows[1][3].text, '3,850.00 مدين');
    });

    test('all time starts from the opening balances', () async {
      final doc = await reports.categoryMonthly(category.id);
      final yer = block(doc, 'YER').table!;
      expect(doc.info.last.value, 'كل الفترات');
      expect(yer.rows.first[0].text, 'الأرصدة الافتتاحية');
      expect(yer.rows.first[3].text, '1,000 مدين');
      // 2024-12, 2025-01, 2026-09.
      expect(yer.rows.skip(1).map((r) => r[0].text), [
        '2024-12 · ديسمبر',
        '2025-01 · يناير',
        '2026-09 · سبتمبر',
      ]);
      expect(yer.totals![3].text, '276,400 دائن');
    });

    test('can be narrowed to one currency and one account', () async {
      final sarOnly = await reports.categoryMonthly(
        category.id,
        year: 2025,
        currencyCode: 'sar',
      );
      expect(sarOnly.blocks.map((b) => b.currencyCode), ['SAR']);
      expect(sarOnly.info.map((i) => i.label), contains('العملة'));

      final aliOnly = await reports.categoryMonthly(
        category.id,
        year: 2025,
        accountId: ali.id,
      );
      expect(aliOnly.blocks.map((b) => b.currencyCode), ['YER']);
      final rows = aliOnly.blocks.single.table!.rows;
      expect(rows[1][2].text, '5,000');
      expect(aliOnly.info.map((i) => i.value), contains('علي أخي'));
    });

    test('a custom range wins over the year', () async {
      final doc = await reports.categoryMonthly(
        category.id,
        year: 2024,
        fromDate: '2026-01-01',
        toDate: '2026-12-31',
      );
      final yer = block(doc, 'YER').table!;
      expect(yer.rows.skip(1).map((r) => r[0].text), ['2026-09 · سبتمبر']);
      expect(doc.info.last.value, 'من 2026-01-01 إلى 2026-12-31');
    });

    test('a period without movement says so and keeps the balance', () async {
      final doc = await reports.categoryMonthly(category.id, year: 2030);
      final yer = block(doc, 'YER').table!;
      expect(yer.emptyMessage, 'لا توجد حركة في هذه الفترة.');
      expect(yer.totals![3].text, '276,400 دائن');
    });

    test('no matching account gives no block', () async {
      final doc = await reports.categoryMonthly(
        category.id,
        accountId: 'nope',
      );
      expect(doc.blocks, isEmpty);
    });
  });

  group('file names and metadata', () {
    test('file names have no forbidden characters and mention the account', () async {
      final tricky = await account('أ/ب:ج*د؟', 'YER');
      final doc = await reports.accountStatement(tricky.id);
      expect(doc.fileBaseName, isNot(matches(RegExp(r'[\\/:*?"<>|]'))));
      expect(doc.fileBaseName, startsWith('كشف حساب'));
      expect(doc.generatedAt, DateTime(2026, 9, 20, 15, 30));
    });

    test('the monthly statement file name carries the month', () async {
      final doc = await reports.accountMonthlyStatement(
        ali.id,
        year: 2025,
        month: 1,
      );
      expect(doc.fileBaseName, 'كشف حساب شهري علي أخي 2025-01');
    });

    test('rowCount counts table rows of every currency', () async {
      final doc = await reports.categoryDetails(category.id);
      expect(doc.rowCount, 3);
    });
  });
}
