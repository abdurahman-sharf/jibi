import '../../../core/errors/app_exception.dart';
import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../../../shared/formatting/money_format.dart';
import '../domain/book_balance.dart';
import '../domain/book_preferences.dart';
import '../domain/book_labels.dart';
import 'report_models.dart';

/// Arabic month names (Gregorian), January first.
const List<String> arabicMonthNames = <String>[
  'يناير',
  'فبراير',
  'مارس',
  'أبريل',
  'مايو',
  'يونيو',
  'يوليو',
  'أغسطس',
  'سبتمبر',
  'أكتوبر',
  'نوفمبر',
  'ديسمبر',
];

/// Builds the [ReportDocument]s of the accounts book.
///
/// Every number comes from the actual transactions (rule 9), through the same
/// [BookBalanceEngine] the screens use, so a report always agrees with the
/// account or category it describes.
final class BookReportBuilder {
  BookReportBuilder({
    required BookRepository repository,
    required CurrencyRegistry currencies,
    BookPreferences Function()? preferences,
    Future<ReportBranding?> Function()? branding,
    DateTime Function()? clock,
  }) : _repository = repository,
       _currencies = currencies,
       _preferences = preferences ?? (() => BookPreferences.standard),
       _branding = branding,
       _clock = clock ?? DateTime.now;

  final BookRepository _repository;
  final CurrencyRegistry _currencies;

  /// Read at every build, so a report always follows the current settings.
  final BookPreferences Function() _preferences;

  /// Who issues the reports; null when nothing is set up.
  final Future<ReportBranding?> Function()? _branding;
  final DateTime Function() _clock;

  BookLabels get _labels => _preferences().labels;

  String _date(String isoDate) => _preferences().date(isoDate);

  Future<ReportBranding?> _loadBranding() async => _branding?.call();

  // ---- category reports -----------------------------------------------------

  /// "إجمالي المبالغ": debit, credit and net of the category, per currency.
  Future<ReportDocument> categoryTotals(String categoryId) async {
    final category = await _requireCategory(categoryId);
    final summaries = await _repository.accountSummaries(
      categoryId: categoryId,
      includeArchived: false,
    );
    final totals = BookBalanceEngine.currencyTotals(summaries);
    return ReportDocument(
      branding: await _loadBranding(),
      kind: ReportKind.categoryTotals,
      title: 'إجمالي المبالغ',
      info: [
        ReportInfo('التصنيف', category.name),
        ReportInfo('عدد الحسابات', '${summaries.length}'),
      ],
      blocks: [
        for (final total in totals)
          ReportBlock(
            heading: _currencyHeading(total.currencyCode),
            currencyCode: total.currencyCode,
            fractionDigits: _digits(total.currencyCode),
            figures: [
              ReportFigure(
                'عدد الحسابات',
                '${total.accountCount}',
              ),
              ReportFigure(
                'إجمالي ${_labels.debit}',
                _money(total.currencyCode, total.debitMinor),
                side: BalanceSide.debit,
              ),
              ReportFigure(
                'إجمالي ${_labels.credit}',
                _money(total.currencyCode, total.creditMinor),
                side: BalanceSide.credit,
              ),
              ReportFigure(
                'الرصيد الصافي',
                _balanceText(total.currencyCode, total.netMinor),
                side: total.side,
              ),
            ],
          ),
      ],
      notes: [
        'الحسابات المؤرشفة غير مشمولة. كل عملة تُعرض على حدة ولا تُجمع مع غيرها.',
        if (totals.isEmpty) 'لا توجد حسابات في هذا التصنيف.',
      ],
      generatedAt: _clock(),
      fileBaseName: _fileName(['إجمالي المبالغ', category.name]),
    );
  }

  /// "تفاصيل جميع المبالغ": one row per account, per currency.
  Future<ReportDocument> categoryDetails(String categoryId) async {
    final category = await _requireCategory(categoryId);
    final summaries = await _repository.accountSummaries(
      categoryId: categoryId,
      includeArchived: false,
    );
    // An account that uses several currencies has one row in each currency's
    // block; two currencies are never added.
    final byCurrency = _groupByCurrency(summaries);
    final blocks = <ReportBlock>[];
    for (final code in byCurrency.keys.toList()..sort()) {
      final accounts = byCurrency[code]!;
      var debit = 0;
      var credit = 0;
      final rows = <List<ReportCell>>[];
      for (final entry in accounts) {
        final totals = entry.line;
        debit += totals.debitMinor;
        credit += totals.creditMinor;
        rows.add([
          ReportCell(entry.summary.account.name),
          _amountCell(code, totals.debitMinor, BalanceSide.debit),
          _amountCell(code, totals.creditMinor, BalanceSide.credit),
          _balanceCell(code, totals.netMinor),
          ReportCell(code),
        ]);
      }
      blocks.add(
        ReportBlock(
          heading: _currencyHeading(code),
          currencyCode: code,
          fractionDigits: _digits(code),
          table: ReportTable(
            columns: [
              const ReportColumn('الحساب', weight: 3),
              ReportColumn(
                _labels.debit,
                kind: ReportColumnKind.amount,
                weight: 2,
              ),
              ReportColumn(
                _labels.credit,
                kind: ReportColumnKind.amount,
                weight: 2,
              ),
              const ReportColumn(
                'الرصيد',
                kind: ReportColumnKind.balance,
                weight: 2.4,
              ),
              const ReportColumn('العملة', weight: 1),
            ],
            rows: rows,
            totals: [
              const ReportCell('الإجمالي', bold: true),
              _amountCell(code, debit, BalanceSide.debit, bold: true),
              _amountCell(code, credit, BalanceSide.credit, bold: true),
              _balanceCell(code, debit - credit, bold: true),
              ReportCell(code, bold: true),
            ],
          ),
        ),
      );
    }
    return ReportDocument(
      branding: await _loadBranding(),
      kind: ReportKind.categoryDetails,
      title: 'تفاصيل جميع المبالغ',
      info: [
        ReportInfo('التصنيف', category.name),
        ReportInfo('عدد الحسابات', '${summaries.length}'),
      ],
      blocks: blocks,
      notes: [
        'الحسابات المؤرشفة غير مشمولة.',
        if (blocks.isEmpty) 'لا توجد حسابات في هذا التصنيف.',
      ],
      generatedAt: _clock(),
      fileBaseName: _fileName(['تفاصيل المبالغ', category.name]),
    );
  }

  /// "إجمالي المبالغ شهرياً": the category's movement month by month.
  ///
  /// The balance column is the balance at the end of that month (opening
  /// balances and everything before the period included). Filter by [year] or
  /// by [fromDate]/[toDate] (which win over [year]), by [currencyCode] and by
  /// [accountId].
  Future<ReportDocument> categoryMonthly(
    String categoryId, {
    int? year,
    String? currencyCode,
    String? accountId,
    String? fromDate,
    String? toDate,
  }) async {
    final category = await _requireCategory(categoryId);
    final range = _range(year: year, fromDate: fromDate, toDate: toDate);
    var summaries = await _repository.accountSummaries(
      categoryId: categoryId,
      includeArchived: false,
    );
    String? accountName;
    if (accountId != null) {
      summaries = [
        for (final summary in summaries)
          if (summary.account.id == accountId) summary,
      ];
      accountName = summaries.isEmpty ? null : summaries.single.account.name;
    }
    final onlyCurrency = currencyCode?.toUpperCase();
    final ids = {for (final summary in summaries) summary.account.id};
    final transactions = summaries.isEmpty
        ? const <BookTransaction>[]
        : [
            for (final row in await _repository.reportTransactions(
              categoryId: categoryId,
              currencyCode: onlyCurrency,
              toDate: range.to,
            ))
              if (ids.contains(row.accountId)) row,
          ];
    // A currency is a block of its own; the accounts that use it contribute
    // their opening balance in THAT currency only.
    final byCurrency = _groupByCurrency(summaries);
    final blocks = <ReportBlock>[];
    for (final code in byCurrency.keys.toList()..sort()) {
      if (onlyCurrency != null && code != onlyCurrency) continue;
      final accounts = byCurrency[code]!;
      var running = accounts.fold<int>(
        0,
        (sum, entry) =>
            sum +
            switch (entry.line.openingType) {
              OpeningType.debit => entry.line.openingMinor,
              OpeningType.credit => -entry.line.openingMinor,
              OpeningType.zero => 0,
            },
      );
      final scoped = [
        for (final row in transactions)
          if (row.currencyCode == code) row,
      ];
      final months = <String, ({int debit, int credit})>{};
      for (final row in scoped) {
        if (range.from != null && row.date.compareTo(range.from!) < 0) {
          running += row.signedMinor;
          continue;
        }
        final key = row.date.substring(0, 7);
        final current = months[key] ?? (debit: 0, credit: 0);
        months[key] = row.type == EntryType.debit
            ? (debit: current.debit + row.amountMinor, credit: current.credit)
            : (debit: current.debit, credit: current.credit + row.amountMinor);
      }
      final rows = <List<ReportCell>>[
        [
          ReportCell(
            range.from == null ? 'الأرصدة الافتتاحية' : 'الرصيد قبل الفترة',
            bold: true,
          ),
          ReportCell.empty,
          ReportCell.empty,
          _balanceCell(code, running, bold: true),
        ],
      ];
      var debitTotal = 0;
      var creditTotal = 0;
      for (final key in months.keys.toList()..sort()) {
        final month = months[key]!;
        debitTotal += month.debit;
        creditTotal += month.credit;
        running += month.debit - month.credit;
        rows.add([
          ReportCell(_monthLabel(key)),
          _amountCell(code, month.debit, BalanceSide.debit),
          _amountCell(code, month.credit, BalanceSide.credit),
          _balanceCell(code, running),
        ]);
      }
      blocks.add(
        ReportBlock(
          heading: _currencyHeading(code),
          currencyCode: code,
          fractionDigits: _digits(code),
          table: ReportTable(
            columns: [
              const ReportColumn('الشهر', weight: 2.4),
              ReportColumn(
                _labels.debit,
                kind: ReportColumnKind.amount,
                weight: 2,
              ),
              ReportColumn(
                _labels.credit,
                kind: ReportColumnKind.amount,
                weight: 2,
              ),
              const ReportColumn(
                'الرصيد',
                kind: ReportColumnKind.balance,
                weight: 2.4,
              ),
            ],
            rows: rows,
            totals: [
              const ReportCell('الإجمالي', bold: true),
              _amountCell(code, debitTotal, BalanceSide.debit, bold: true),
              _amountCell(code, creditTotal, BalanceSide.credit, bold: true),
              _balanceCell(code, running, bold: true),
            ],
            emptyMessage: months.isEmpty
                ? 'لا توجد حركة في هذه الفترة.'
                : null,
          ),
        ),
      );
    }
    return ReportDocument(
      branding: await _loadBranding(),
      kind: ReportKind.categoryMonthly,
      title: 'إجمالي المبالغ شهرياً',
      info: [
        ReportInfo('التصنيف', category.name),
        if (accountName != null) ReportInfo('الحساب', accountName),
        if (currencyCode != null)
          ReportInfo('العملة', currencyCode.toUpperCase()),
        ReportInfo('الفترة', _periodLabel(range.from, range.to, year: year)),
      ],
      blocks: blocks,
      notes: [
        'الرصيد هو رصيد نهاية الشهر شاملاً الأرصدة الافتتاحية وما قبل الفترة. '
            'الحسابات المؤرشفة غير مشمولة.',
        if (blocks.isEmpty) 'لا توجد حسابات مطابقة.',
      ],
      generatedAt: _clock(),
      fileBaseName: _fileName([
        'المبالغ شهرياً',
        category.name,
        ?(year == null ? null : '$year'),
      ]),
    );
  }

  // ---- account reports ------------------------------------------------------

  /// "كشف الحساب": the transactions between [fromDate] and [toDate] (either or
  /// both may be omitted), with the balance carried in from before the period.
  ///
  /// An account can use several currencies, and a running balance across two
  /// of them would be meaningless, so the statement is one block per currency —
  /// each with its own opening balance, running balance and totals.
  /// [currencyCode] narrows it to a single currency.
  Future<ReportDocument> accountStatement(
    String accountId, {
    String? currencyCode,
    String? fromDate,
    String? toDate,
  }) => _statement(
    accountId,
    currencyCode: currencyCode,
    fromDate: fromDate,
    toDate: toDate,
    kind: ReportKind.accountStatement,
    title: 'كشف الحساب',
    period: _periodLabel(fromDate, toDate),
    fileSuffix: null,
  );

  /// "كشف الحساب الشهري": one month of an account, one block per currency.
  Future<ReportDocument> accountMonthlyStatement(
    String accountId, {
    required int year,
    required int month,
    String? currencyCode,
  }) {
    if (month < 1 || month > 12 || year < 1900 || year > 2200) {
      throw const ValidationException(
        code: 'invalid_report_month',
        userMessage: 'اختر شهراً وسنة صحيحين.',
      );
    }
    final first = DateTime(year, month);
    final last = DateTime(year, month + 1, 0);
    return _statement(
      accountId,
      currencyCode: currencyCode,
      fromDate: BookTransaction.formatDate(first),
      toDate: BookTransaction.formatDate(last),
      kind: ReportKind.accountMonthlyStatement,
      title: 'كشف الحساب الشهري',
      period: '${arabicMonthNames[month - 1]} $year',
      fileSuffix: '$year-${month.toString().padLeft(2, '0')}',
      monthly: true,
    );
  }

  Future<ReportDocument> _statement(
    String accountId, {
    required String? currencyCode,
    required String? fromDate,
    required String? toDate,
    required ReportKind kind,
    required String title,
    required String period,
    required String? fileSuffix,
    bool monthly = false,
  }) async {
    final range = _range(fromDate: fromDate, toDate: toDate);
    final account = await _repository.account(accountId);
    if (account == null) {
      throw const NotFoundException(
        code: 'account_not_found',
        userMessage: 'الحساب المطلوب غير موجود.',
      );
    }
    final category = await _repository.category(account.categoryId);
    final onlyCurrency = currencyCode?.toUpperCase();
    final balances = await _repository.accountBalancesOf(accountId);
    final openings = {
      for (final balance in balances) balance.currencyCode: balance,
    };
    // Fetched once, across every currency; each block then takes its own.
    final all = await _repository.reportTransactions(
      accountId: accountId,
      currencyCode: onlyCurrency,
      toDate: range.to,
    );
    // The currencies the account uses: an opening balance or a transaction.
    final codes = <String>{
      for (final balance in balances)
        if (balance.openingMinor > 0 &&
            (onlyCurrency == null || balance.currencyCode == onlyCurrency))
          balance.currencyCode,
      for (final row in all) row.currencyCode,
    }.toList()..sort();
    if (onlyCurrency != null && !codes.contains(onlyCurrency)) {
      throw const NotFoundException(
        code: 'account_currency_not_found',
        userMessage: 'هذا الحساب لا يستخدم هذه العملة.',
      );
    }
    // Built once per document, and only when some row actually carries a
    // wallet (its payment method).
    final paymentLabels = <String, String>{};
    if (all.any((row) => row.walletId != null)) {
      final summaries = await _repository.walletSummaries(
        includeArchived: true,
      );
      for (final summary in summaries) {
        paymentLabels[summary.wallet.id] = summary.wallet.paymentLabel;
      }
    }
    final openingLabel = monthly ? 'الرصيد بداية الشهر' : 'الرصيد الافتتاحي للفترة';
    final finalLabel = monthly ? 'الرصيد نهاية الشهر' : 'الرصيد النهائي';
    final blocks = <ReportBlock>[];
    for (final code in codes) {
      var running = openings[code]?.openingSignedMinor ?? 0;
      final inPeriod = <BookTransaction>[];
      for (final row in all) {
        if (row.currencyCode != code) continue;
        if (range.from != null && row.date.compareTo(range.from!) < 0) {
          running += row.signedMinor;
        } else {
          inPeriod.add(row);
        }
      }
      final openingBalance = running;
      var debit = 0;
      var credit = 0;
      final rows = <List<ReportCell>>[
        [
          ReportCell(range.from == null ? '—' : _date(range.from!)),
          ReportCell(openingLabel, bold: true),
          ReportCell.empty,
          ReportCell.empty,
          ReportCell.empty,
          _balanceCell(code, openingBalance, bold: true),
        ],
      ];
      for (final row in inPeriod) {
        running += row.signedMinor;
        if (row.type == EntryType.debit) {
          debit += row.amountMinor;
        } else {
          credit += row.amountMinor;
        }
        final details = row.details;
        rows.add([
          ReportCell(_date(row.date)),
          ReportCell(
            details == null || details.isEmpty
                ? row.number
                : '${_clip(details)} (${row.number})',
          ),
          ReportCell(_paymentLabel(row, paymentLabels)),
          row.type == EntryType.debit
              ? _amountCell(code, row.amountMinor, BalanceSide.debit)
              : ReportCell.empty,
          row.type == EntryType.credit
              ? _amountCell(code, row.amountMinor, BalanceSide.credit)
              : ReportCell.empty,
          _balanceCell(code, running),
        ]);
      }
      final finalBalance = running;
      blocks.add(
        ReportBlock(
          heading: codes.length > 1 ? _currencyHeading(code) : null,
          currencyCode: code,
          fractionDigits: _digits(code),
          figures: [
            ReportFigure(
              openingLabel,
              _balanceText(code, openingBalance),
              side: balanceSideOf(openingBalance),
            ),
            ReportFigure(
              'إجمالي ${_labels.debit}',
              _money(code, debit),
              side: BalanceSide.debit,
            ),
            ReportFigure(
              'إجمالي ${_labels.credit}',
              _money(code, credit),
              side: BalanceSide.credit,
            ),
            ReportFigure(
              finalLabel,
              _balanceText(code, finalBalance),
              side: balanceSideOf(finalBalance),
            ),
          ],
          table: ReportTable(
            columns: [
              const ReportColumn('التاريخ', weight: 2.2),
              const ReportColumn('التفاصيل', weight: 3.6),
              const ReportColumn('وسيلة الدفع', weight: 1.8),
              ReportColumn(
                _labels.debit,
                kind: ReportColumnKind.amount,
                weight: 2,
              ),
              ReportColumn(
                _labels.credit,
                kind: ReportColumnKind.amount,
                weight: 2,
              ),
              const ReportColumn(
                'الرصيد',
                kind: ReportColumnKind.balance,
                weight: 2.6,
              ),
            ],
            rows: rows,
            totals: [
              ReportCell.empty,
              const ReportCell('الإجمالي', bold: true),
              ReportCell.empty,
              _amountCell(code, debit, BalanceSide.debit, bold: true),
              _amountCell(code, credit, BalanceSide.credit, bold: true),
              _balanceCell(code, finalBalance, bold: true),
            ],
            emptyMessage: inPeriod.isEmpty
                ? 'لا توجد عمليات في هذه الفترة.'
                : null,
          ),
        ),
      );
    }
    return ReportDocument(
      branding: await _loadBranding(),
      kind: kind,
      title: title,
      info: [
        ReportInfo('الحساب', account.name),
        if (category != null) ReportInfo('التصنيف', category.name),
        if (codes.isNotEmpty)
          ReportInfo(
            codes.length > 1 ? 'العملات' : 'العملة',
            codes.map(_currencyHeading).join(' · '),
          ),
        ReportInfo('الفترة', period),
      ],
      blocks: blocks,
      notes: [
        if (codes.length > 1)
          'لكل عملة كشف ورصيد مستقل ولا تُجمع العملات معاً.',
        if (blocks.isEmpty) 'لا توجد أرصدة أو عمليات لهذا الحساب.',
      ],
      generatedAt: _clock(),
      fileBaseName: _fileName([
        monthly ? 'كشف حساب شهري' : 'كشف حساب',
        account.name,
        ?fileSuffix,
        ?onlyCurrency,
      ]),
    );
  }

  // ---- wallet reports ---------------------------------------------------------

  /// "كشف المحفظة": the movements between [fromDate] and [toDate] (either or
  /// both may be omitted), with the balance carried in from before the
  /// period. One block per currency the wallet holds, each with its own
  /// opening/closing balance; [currencyCode] narrows to a single one.
  Future<ReportDocument> walletStatement(
    String walletId, {
    String? currencyCode,
    String? fromDate,
    String? toDate,
  }) async {
    final range = _range(fromDate: fromDate, toDate: toDate);
    final wallet = await _repository.wallet(walletId);
    if (wallet == null) {
      throw const NotFoundException(
        code: 'wallet_not_found',
        userMessage: 'المحفظة المطلوبة غير موجودة.',
      );
    }
    final balances = await _repository.walletBalancesOf(walletId);
    final targetBalances = currencyCode == null
        ? balances
        : [
            for (final balance in balances)
              if (balance.currencyCode == currencyCode.toUpperCase()) balance,
          ];
    if (targetBalances.isEmpty) {
      throw const NotFoundException(
        code: 'wallet_currency_not_found',
        userMessage: 'هذه المحفظة لا تحمل هذه العملة.',
      );
    }
    // Fetched once, across every currency, so an exchange leg can find its
    // pair even when the report is narrowed to just one of the two.
    final all = await _repository.walletReportTransactions(
      walletId,
      toDate: range.to,
    );
    final legsByGroup = <String, List<WalletTransaction>>{};
    for (final row in all) {
      final group = row.legGroupId;
      if (group != null) (legsByGroup[group] ??= []).add(row);
    }

    final blocks = <ReportBlock>[];
    for (final balance in targetBalances) {
      final code = balance.currencyCode;
      final rowsForCurrency = [
        for (final row in all)
          if (row.currencyCode == code) row,
      ];
      var running = balance.openingMinor;
      final inPeriod = <WalletTransaction>[];
      for (final row in rowsForCurrency) {
        if (range.from != null && row.date.compareTo(range.from!) < 0) {
          running += _signedMinor(row);
        } else {
          inPeriod.add(row);
        }
      }
      final openingBalance = running;
      var incoming = 0;
      var outgoing = 0;
      final rows = <List<ReportCell>>[
        [
          ReportCell(range.from == null ? '—' : _date(range.from!)),
          ReportCell('الرصيد الافتتاحي للفترة', bold: true),
          ReportCell.empty,
          ReportCell.empty,
          _walletBalanceCell(code, openingBalance, bold: true),
        ],
      ];
      for (final row in inPeriod) {
        running += _signedMinor(row);
        if (row.direction == WalletDirection.incoming) {
          incoming += row.amountMinor;
        } else {
          outgoing += row.amountMinor;
        }
        rows.add([
          ReportCell(_date(row.date)),
          ReportCell(_movementDescription(row, legsByGroup)),
          row.direction == WalletDirection.incoming
              ? _amountCell(code, row.amountMinor, BalanceSide.credit)
              : ReportCell.empty,
          row.direction == WalletDirection.outgoing
              ? _amountCell(code, row.amountMinor, BalanceSide.debit)
              : ReportCell.empty,
          _walletBalanceCell(code, running),
        ]);
      }
      final finalBalance = running;
      blocks.add(
        ReportBlock(
          heading: targetBalances.length > 1 ? _currencyHeading(code) : null,
          currencyCode: code,
          fractionDigits: _digits(code),
          figures: [
            ReportFigure(
              'الرصيد الافتتاحي للفترة',
              _walletBalanceText(code, openingBalance),
              side: openingBalance < 0 ? BalanceSide.debit : null,
            ),
            ReportFigure('إجمالي الوارد', _money(code, incoming), side: BalanceSide.credit),
            ReportFigure('إجمالي الصادر', _money(code, outgoing), side: BalanceSide.debit),
            ReportFigure(
              'الرصيد النهائي',
              _walletBalanceText(code, finalBalance),
              side: finalBalance < 0 ? BalanceSide.debit : null,
            ),
          ],
          table: ReportTable(
            columns: [
              const ReportColumn('التاريخ', weight: 2.2),
              const ReportColumn('الوصف', weight: 4.2),
              const ReportColumn('وارد', kind: ReportColumnKind.amount, weight: 2),
              const ReportColumn('صادر', kind: ReportColumnKind.amount, weight: 2),
              const ReportColumn('الرصيد', kind: ReportColumnKind.amount, weight: 2.4),
            ],
            rows: rows,
            totals: [
              ReportCell.empty,
              const ReportCell('الإجمالي', bold: true),
              _amountCell(code, incoming, BalanceSide.credit, bold: true),
              _amountCell(code, outgoing, BalanceSide.debit, bold: true),
              _walletBalanceCell(code, finalBalance, bold: true),
            ],
            emptyMessage: inPeriod.isEmpty
                ? 'لا توجد حركات في هذه الفترة.'
                : null,
          ),
        ),
      );
    }

    return ReportDocument(
      branding: await _loadBranding(),
      kind: ReportKind.walletStatement,
      title: 'كشف المحفظة',
      info: [
        ReportInfo('المحفظة', wallet.name),
        ReportInfo(
          targetBalances.length > 1 ? 'العملات' : 'العملة',
          targetBalances.map((b) => _currencyHeading(b.currencyCode)).join(' · '),
        ),
        ReportInfo('الفترة', _periodLabel(range.from, range.to)),
      ],
      blocks: blocks,
      generatedAt: _clock(),
      fileBaseName: _fileName([
        'كشف محفظة',
        wallet.name,
        if (currencyCode != null) currencyCode.toUpperCase(),
      ]),
    );
  }

  int _signedMinor(WalletTransaction row) =>
      row.direction == WalletDirection.incoming ? row.amountMinor : -row.amountMinor;

  /// A wallet balance has no "مدين/دائن" side — it is just a signed amount
  /// (negative shown with a minus sign), unlike a book account's balance.
  String _walletBalanceText(String code, int signedMinor) =>
      signedMinor < 0 ? '-${_money(code, signedMinor)}' : _money(code, signedMinor);

  ReportCell _walletBalanceCell(String code, int signedMinor, {bool bold = false}) =>
      ReportCell(
        _walletBalanceText(code, signedMinor),
        amountMinor: signedMinor,
        side: signedMinor < 0 ? BalanceSide.debit : null,
        bold: bold,
      );

  /// "إيداع (WTX-000001)", "صرف — 500.00 USD ← 1,875.00 SAR (WTX-000002)" for
  /// an exchange leg (both legs are always in the same wallet, so the pair is
  /// available in [legsByGroup] even when the report is narrowed to one
  /// currency), or with a note, "إيداع — بيع بضاعة (WTX-000001)".
  String _movementDescription(
    WalletTransaction row,
    Map<String, List<WalletTransaction>> legsByGroup,
  ) {
    var label = _movementTypeLabel(row.type);
    if (row.type == WalletTransactionType.exchange) {
      final pair = row.legGroupId == null ? null : legsByGroup[row.legGroupId];
      WalletTransaction? counter;
      if (pair != null) {
        for (final leg in pair) {
          if (leg.id != row.id) {
            counter = leg;
            break;
          }
        }
      }
      if (counter != null) {
        final arrow = row.direction == WalletDirection.outgoing ? '←' : '→';
        label =
            '$label — ${_money(row.currencyCode, row.amountMinor)} '
            '${row.currencyCode} $arrow '
            '${_money(counter.currencyCode, counter.amountMinor)} '
            '${counter.currencyCode}';
      }
    }
    final notes = row.notes;
    final withNotes = notes == null || notes.isEmpty ? label : '$label — ${_clip(notes)}';
    return '$withNotes (${row.number})';
  }

  String _movementTypeLabel(WalletTransactionType type) => switch (type) {
    WalletTransactionType.deposit => 'إيداع',
    WalletTransactionType.withdrawal => 'سحب',
    WalletTransactionType.transfer => 'تحويل',
    WalletTransactionType.exchange => 'صرف',
    WalletTransactionType.linked => 'عملية مرتبطة',
  };

  // ---- helpers --------------------------------------------------------------

  Future<BookCategory> _requireCategory(String id) async {
    final category = await _repository.category(id);
    if (category == null) {
      throw const NotFoundException(
        code: 'category_not_found',
        userMessage: 'التصنيف المطلوب غير موجود.',
      );
    }
    return category;
  }

  int _digits(String code) => _currencies.byCode(code).fractionDigits;

  String _money(String code, int minor) =>
      formatMinorGrouped(minor.abs(), _digits(code));

  String _balanceText(String code, int signedMinor) =>
      '${_money(code, signedMinor)} ${_labels.side(balanceSideOf(signedMinor))}';

  ReportCell _amountCell(
    String code,
    int minor,
    BalanceSide side, {
    bool bold = false,
  }) => ReportCell(
    _money(code, minor),
    amountMinor: minor,
    side: side,
    bold: bold,
  );

  ReportCell _balanceCell(String code, int signedMinor, {bool bold = false}) {
    final side = balanceSideOf(signedMinor);
    return ReportCell(
      _balanceText(code, signedMinor),
      amountMinor: signedMinor.abs(),
      side: side,
      bold: bold,
    );
  }

  /// The «وسيلة الدفع» column: «نقدًا» for the main wallet, the wallet's own
  /// name for any other, blank for a row from before wallets were linked.
  String _paymentLabel(BookTransaction row, Map<String, String> labels) {
    final walletId = row.walletId;
    return walletId == null ? '' : labels[walletId] ?? '';
  }

  String _currencyHeading(String code) {
    final currency = _currencies.byCode(code);
    return '${currency.name} ($code)';
  }

  /// One entry per (account, currency the account uses), grouped by
  /// currency: an account with three currencies appears once in each of three
  /// groups, and no group ever mixes currencies.
  Map<String, List<({AccountSummary summary, AccountCurrencyTotals line})>>
  _groupByCurrency(Iterable<AccountSummary> summaries) {
    final result =
        <String, List<({AccountSummary summary, AccountCurrencyTotals line})>>{};
    for (final summary in summaries) {
      for (final line in summary.currencies) {
        result
            .putIfAbsent(
              line.currencyCode,
              () => <({AccountSummary summary, AccountCurrencyTotals line})>[],
            )
            .add((summary: summary, line: line));
      }
    }
    return result;
  }

  /// `2026-09` -> `2026-09 · سبتمبر`.
  String _monthLabel(String yearMonth) {
    final month = int.tryParse(yearMonth.substring(5, 7));
    final name = month == null || month < 1 || month > 12
        ? ''
        : ' · ${arabicMonthNames[month - 1]}';
    return '$yearMonth$name';
  }

  ({String? from, String? to}) _range({
    int? year,
    String? fromDate,
    String? toDate,
  }) {
    for (final value in [fromDate, toDate]) {
      if (value != null && !_validIso(value)) {
        throw const ValidationException(
          code: 'invalid_report_date',
          userMessage: 'تاريخ التقرير غير صالح.',
        );
      }
    }
    if (fromDate != null && toDate != null && fromDate.compareTo(toDate) > 0) {
      throw const ValidationException(
        code: 'invalid_report_range',
        userMessage: 'تاريخ البداية يجب أن يسبق تاريخ النهاية.',
      );
    }
    if (fromDate != null || toDate != null) {
      return (from: fromDate, to: toDate);
    }
    if (year != null) {
      if (year < 1900 || year > 2200) {
        throw const ValidationException(
          code: 'invalid_report_year',
          userMessage: 'اختر سنة صحيحة.',
        );
      }
      return (from: '$year-01-01', to: '$year-12-31');
    }
    return (from: null, to: null);
  }

  static bool _validIso(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) return false;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime(year, month, day);
    return parsed.year == year && parsed.month == month && parsed.day == day;
  }

  String _periodLabel(String? from, String? to, {int? year}) {
    if (from == null && to == null) return 'كل الفترات';
    if (year != null && from == '$year-01-01' && to == '$year-12-31') {
      return 'سنة $year';
    }
    if (from != null && to != null) return 'من ${_date(from)} إلى ${_date(to)}';
    if (from != null) return 'من ${_date(from)}';
    return 'حتى ${_date(to!)}';
  }

  /// Long free text is cut so one row can never be taller than a page.
  static String _clip(String value, {int max = 400}) =>
      value.length <= max ? value : '${value.substring(0, max).trimRight()}…';

  /// A file name from [parts]: no separators or characters a file system
  /// rejects, single spaces, bounded length.
  static String _fileName(Iterable<String> parts) {
    final joined = parts
        .join(' ')
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final bounded = joined.length > 80 ? joined.substring(0, 80).trim() : joined;
    return bounded.isEmpty ? 'تقرير' : bounded;
  }
}
