import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/models/models.dart';
import '../../../features/book/book.dart';
import '../../../features/book/reports/report_builder.dart' show arabicMonthNames;
import '../../../features/book/reports/report_models.dart' show ReportDocument;
import '../../../shared/widgets/jibi_design.dart';
import '../../../shared/widgets/jibi_feedback.dart';
import '../book_widgets.dart';
import 'book_report_preview_page.dart';

enum _CategoryReport { totals, details, monthly }

enum _AccountReport { statement, monthlyStatement }

class _Choice<T> {
  const _Choice(this.value, this.icon, this.title, this.subtitle);

  final T value;
  final IconData icon;
  final String title;
  final String subtitle;
}

Future<T?> _choose<T>(
  BuildContext context, {
  required String title,
  required String subject,
  required List<_Choice<T>> choices,
}) => showModalBottomSheet<T>(
  context: context,
  showDragHandle: true,
  useRootNavigator: true,
  useSafeArea: true,
  builder: (context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              Text(
                subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.jibiMuted),
              ),
            ],
          ),
        ),
      ),
      for (final choice in choices)
        ListTile(
          key: Key('report-choice-${choice.value.toString().split('.').last}'),
          leading: Icon(choice.icon),
          title: Text(choice.title),
          subtitle: Text(choice.subtitle),
          onTap: () => Navigator.of(context).pop(choice.value),
        ),
      const SizedBox(height: 12),
    ],
  ),
);

Future<void> _pushOptions(BuildContext context, Widget page) =>
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(builder: (_) => page),
    );

/// The reports of a category: totals, the account-by-account details and the
/// month-by-month movement.
Future<void> showCategoryReports(
  BuildContext context,
  BookServices book,
  BookCategory category,
) async {
  final choice = await _choose<_CategoryReport>(
    context,
    title: 'تقارير التصنيف',
    subject: category.name,
    choices: const [
      _Choice(
        _CategoryReport.totals,
        Icons.summarize_outlined,
        'إجمالي المبالغ',
        'المدين والدائن والرصيد الصافي لكل عملة',
      ),
      _Choice(
        _CategoryReport.details,
        Icons.table_rows_outlined,
        'تفاصيل جميع المبالغ',
        'كل حساب بمدينه ودائنه ورصيده',
      ),
      _Choice(
        _CategoryReport.monthly,
        Icons.calendar_month_outlined,
        'إجمالي المبالغ شهرياً',
        'حركة كل شهر برصيد تراكمي، بسنة أو فترة أو حساب محدد',
      ),
    ],
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case _CategoryReport.totals:
      await openReportPreview(
        context,
        book,
        () => book.reports.categoryTotals(category.id),
      );
    case _CategoryReport.details:
      await openReportPreview(
        context,
        book,
        () => book.reports.categoryDetails(category.id),
      );
    case _CategoryReport.monthly:
      await _pushOptions(
        context,
        CategoryMonthlyOptionsPage(book: book, category: category),
      );
  }
}

/// The report of a wallet: its statement between two dates.
Future<void> showWalletReports(
  BuildContext context,
  BookServices book,
  Wallet wallet,
) => _pushOptions(context, WalletStatementOptionsPage(book: book, wallet: wallet));

/// The reports of an account: its statement between two dates, or for one
/// month.
Future<void> showAccountReports(
  BuildContext context,
  BookServices book,
  BookAccount account,
) async {
  final choice = await _choose<_AccountReport>(
    context,
    title: 'تقارير الحساب',
    subject: account.name,
    choices: const [
      _Choice(
        _AccountReport.statement,
        Icons.receipt_long_outlined,
        'كشف الحساب',
        'كل الفترات أو من تاريخ إلى تاريخ',
      ),
      _Choice(
        _AccountReport.monthlyStatement,
        Icons.event_note_outlined,
        'كشف الحساب الشهري',
        'شهر وسنة محددان مع الرصيد في أول الشهر وآخره',
      ),
    ],
  );
  if (choice == null || !context.mounted) return;
  await _pushOptions(
    context,
    switch (choice) {
      _AccountReport.statement => AccountStatementOptionsPage(
        book: book,
        account: account,
      ),
      _AccountReport.monthlyStatement => AccountMonthlyOptionsPage(
        book: book,
        account: account,
      ),
    },
  );
}

// ---- options pages ----------------------------------------------------------

String _two(int value) => value.toString().padLeft(2, '0');

/// `2026-09-20`, the form the reports take dates in.
String isoDay(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${_two(value.month)}-${_two(value.day)}';

class _OptionsScaffold extends StatelessWidget {
  const _OptionsScaffold({
    required this.title,
    required this.subject,
    required this.actionLabel,
    required this.onSubmit,
    required this.children,
  });

  final String title;
  final String subject;
  final String actionLabel;
  final VoidCallback? onSubmit;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: ListView(
      padding: bookPagePadding,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            subject,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ),
        ...children,
      ],
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          key: const Key('report-options-submit'),
          onPressed: onSubmit,
          icon: const Icon(Icons.visibility_outlined),
          label: Text(actionLabel),
        ),
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: context.jibiMuted,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}

class _ChoiceChips<T> extends StatelessWidget {
  const _ChoiceChips({
    required this.values,
    required this.labelOf,
    required this.selected,
    required this.onSelected,
    required this.keyPrefix,
  });

  final List<T> values;
  final String Function(T value) labelOf;
  final T selected;
  final ValueChanged<T> onSelected;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final value in values)
        ChoiceChip(
          key: Key('$keyPrefix-${labelOf(value)}'),
          label: Text(labelOf(value)),
          selected: value == selected,
          onSelected: (_) => onSelected(value),
        ),
    ],
  );
}

/// "من تاريخ" / "إلى تاريخ": two optional dates.
class _DateRangeFields extends StatelessWidget {
  const _DateRangeFields({
    required this.from,
    required this.to,
    required this.onFrom,
    required this.onTo,
  });

  final String? from;
  final String? to;
  final ValueChanged<String?> onFrom;
  final ValueChanged<String?> onTo;

  Future<void> _pick(
    BuildContext context,
    String? current,
    ValueChanged<String?> onChanged,
  ) async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(current ?? '') ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (picked != null) onChanged(isoDay(picked));
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _DateButton(
          buttonKey: const Key('report-from'),
          label: 'من تاريخ',
          value: from,
          onPressed: () => _pick(context, from, onFrom),
          onClear: from == null ? null : () => onFrom(null),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: _DateButton(
          buttonKey: const Key('report-to'),
          label: 'إلى تاريخ',
          value: to,
          onPressed: () => _pick(context, to, onTo),
          onClear: to == null ? null : () => onTo(null),
        ),
      ),
    ],
  );
}

class _DateButton extends StatelessWidget {
  const _DateButton({
    required this.buttonKey,
    required this.label,
    required this.value,
    required this.onPressed,
    required this.onClear,
  });

  final Key buttonKey;
  final String label;
  final String? value;
  final VoidCallback onPressed;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    key: buttonKey,
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(56),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 11, color: context.jibiMuted),
              ),
              Text(
                value ?? 'غير محدد',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
              ),
            ],
          ),
        ),
        if (onClear != null)
          InkResponse(
            key: Key('${(buttonKey as ValueKey<String>).value}-clear'),
            onTap: onClear,
            child: const Icon(Icons.close, size: 18),
          ),
      ],
    ),
  );
}

List<int> _years() {
  final now = DateTime.now().year;
  return [for (var year = now + 1; year >= now - 9; year--) year];
}

class _MonthYearFields extends StatelessWidget {
  const _MonthYearFields({
    required this.month,
    required this.year,
    required this.onMonth,
    required this.onYear,
  });

  final int? month;
  final int year;
  final ValueChanged<int>? onMonth;
  final ValueChanged<int> onYear;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (month != null && onMonth != null) ...[
        Expanded(
          child: DropdownButtonFormField<int>(
            key: const Key('report-month'),
            initialValue: month,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'الشهر'),
            items: [
              for (var index = 1; index <= 12; index++)
                DropdownMenuItem(
                  value: index,
                  child: Text('$index · ${arabicMonthNames[index - 1]}'),
                ),
            ],
            onChanged: (value) {
              if (value != null) onMonth!(value);
            },
          ),
        ),
        const SizedBox(width: 12),
      ],
      Expanded(
        child: DropdownButtonFormField<int>(
          key: const Key('report-year'),
          initialValue: year,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'السنة'),
          items: [
            for (final value in _years())
              DropdownMenuItem(value: value, child: Text('$value')),
          ],
          onChanged: (value) {
            if (value != null) onYear(value);
          },
        ),
      ),
    ],
  );
}

void _show(
  BuildContext context,
  BookServices book,
  Future<ReportDocument> Function() build,
) {
  unawaited(openReportPreview(context, book, build));
}

// ---- account statement --------------------------------------------------------

enum _StatementPeriod { all, thisMonth, thisYear, custom }

const Map<_StatementPeriod, String> _statementPeriodLabels = {
  _StatementPeriod.all: 'كل الفترات',
  _StatementPeriod.thisMonth: 'هذا الشهر',
  _StatementPeriod.thisYear: 'هذه السنة',
  _StatementPeriod.custom: 'فترة محددة',
};

/// Options of "كشف الحساب": all periods, this month, this year or two dates.
class AccountStatementOptionsPage extends StatefulWidget {
  const AccountStatementOptionsPage({
    required this.book,
    required this.account,
    super.key,
    this.today,
  });

  final BookServices book;
  final BookAccount account;

  /// For tests.
  final DateTime? today;

  @override
  State<AccountStatementOptionsPage> createState() =>
      _AccountStatementOptionsPageState();
}

class _AccountStatementOptionsPageState
    extends State<AccountStatementOptionsPage> {
  _StatementPeriod _period = _StatementPeriod.all;
  String? _from;
  String? _to;
  String? _currency;

  void _submit() {
    final now = widget.today ?? DateTime.now();
    String? from;
    String? to;
    switch (_period) {
      case _StatementPeriod.all:
        break;
      case _StatementPeriod.thisMonth:
        from = isoDay(DateTime(now.year, now.month));
        to = isoDay(DateTime(now.year, now.month + 1, 0));
      case _StatementPeriod.thisYear:
        from = '${now.year}-01-01';
        to = '${now.year}-12-31';
      case _StatementPeriod.custom:
        from = _from;
        to = _to;
        if (from == null && to == null) {
          showJibiMessage(context, 'اختر تاريخ البداية أو النهاية على الأقل.');
          return;
        }
        if (from != null && to != null && from.compareTo(to) > 0) {
          showJibiMessage(context, 'تاريخ البداية يجب أن يسبق تاريخ النهاية.');
          return;
        }
    }
    _show(
      context,
      widget.book,
      () => widget.book.reports.accountStatement(
        widget.account.id,
        currencyCode: _currency,
        fromDate: from,
        toDate: to,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _OptionsScaffold(
    title: 'كشف الحساب',
    subject: widget.account.name,
    actionLabel: 'عرض الكشف',
    onSubmit: _submit,
    children: [
      _AccountCurrencySection(
        book: widget.book,
        accountId: widget.account.id,
        selected: _currency,
        onSelected: (value) => setState(() => _currency = value),
      ),
      _Section(
        label: 'الفترة',
        child: _ChoiceChips<_StatementPeriod>(
          keyPrefix: 'period',
          values: _StatementPeriod.values,
          labelOf: (value) => _statementPeriodLabels[value]!,
          selected: _period,
          onSelected: (value) => setState(() => _period = value),
        ),
      ),
      if (_period == _StatementPeriod.custom)
        _Section(
          label: 'من — إلى',
          child: _DateRangeFields(
            from: _from,
            to: _to,
            onFrom: (value) => setState(() => _from = value),
            onTo: (value) => setState(() => _to = value),
          ),
        ),
    ],
  );
}

// ---- account monthly statement ------------------------------------------------

/// Options of "كشف الحساب الشهري": one month of one year.
class AccountMonthlyOptionsPage extends StatefulWidget {
  const AccountMonthlyOptionsPage({
    required this.book,
    required this.account,
    super.key,
    this.today,
  });

  final BookServices book;
  final BookAccount account;

  /// For tests.
  final DateTime? today;

  @override
  State<AccountMonthlyOptionsPage> createState() =>
      _AccountMonthlyOptionsPageState();
}

class _AccountMonthlyOptionsPageState extends State<AccountMonthlyOptionsPage> {
  late int _month = (widget.today ?? DateTime.now()).month;
  late int _year = (widget.today ?? DateTime.now()).year;
  String? _currency;

  @override
  Widget build(BuildContext context) => _OptionsScaffold(
    title: 'كشف الحساب الشهري',
    subject: widget.account.name,
    actionLabel: 'عرض الكشف',
    onSubmit: () => _show(
      context,
      widget.book,
      () => widget.book.reports.accountMonthlyStatement(
        widget.account.id,
        year: _year,
        month: _month,
        currencyCode: _currency,
      ),
    ),
    children: [
      _AccountCurrencySection(
        book: widget.book,
        accountId: widget.account.id,
        selected: _currency,
        onSelected: (value) => setState(() => _currency = value),
      ),
      _Section(
        label: 'الشهر والسنة',
        child: _MonthYearFields(
          month: _month,
          year: _year,
          onMonth: (value) => setState(() => _month = value),
          onYear: (value) => setState(() => _year = value),
        ),
      ),
    ],
  );
}

/// "العملة": lets an account statement be narrowed to one of the currencies the
/// account uses. An account with a single currency (or none) shows nothing —
/// there is nothing to choose; with several, the statement has one block per
/// currency by default ("كل العملات"), and never a balance across them.
class _AccountCurrencySection extends StatefulWidget {
  const _AccountCurrencySection({
    required this.book,
    required this.accountId,
    required this.selected,
    required this.onSelected,
  });

  final BookServices book;
  final String accountId;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  State<_AccountCurrencySection> createState() =>
      _AccountCurrencySectionState();
}

class _AccountCurrencySectionState extends State<_AccountCurrencySection> {
  List<String> _currencies = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final summary = await widget.book.accounts.summary(widget.accountId);
    if (!mounted || summary == null) return;
    setState(() => _currencies = summary.currencyCodes);
  }

  @override
  Widget build(BuildContext context) {
    if (_currencies.length < 2) return const SizedBox.shrink();
    return _Section(
      label: 'العملة',
      child: _ChoiceChips<String?>(
        keyPrefix: 'account-report-currency',
        values: [null, ..._currencies],
        labelOf: (value) => value ?? 'كل العملات',
        selected: widget.selected,
        onSelected: widget.onSelected,
      ),
    );
  }
}

// ---- wallet statement --------------------------------------------------------

/// Options of "كشف المحفظة": all periods, this month, this year or two dates.
class WalletStatementOptionsPage extends StatefulWidget {
  const WalletStatementOptionsPage({
    required this.book,
    required this.wallet,
    super.key,
    this.today,
  });

  final BookServices book;
  final Wallet wallet;

  /// For tests.
  final DateTime? today;

  @override
  State<WalletStatementOptionsPage> createState() =>
      _WalletStatementOptionsPageState();
}

class _WalletStatementOptionsPageState
    extends State<WalletStatementOptionsPage> {
  _StatementPeriod _period = _StatementPeriod.all;
  String? _from;
  String? _to;
  String? _currency;
  List<String> _currencies = const [];

  @override
  void initState() {
    super.initState();
    _loadCurrencies();
  }

  Future<void> _loadCurrencies() async {
    final summary = await widget.book.wallets.summary(widget.wallet.id);
    if (!mounted || summary == null) return;
    setState(() => _currencies = summary.currencies);
  }

  void _submit() {
    final now = widget.today ?? DateTime.now();
    String? from;
    String? to;
    switch (_period) {
      case _StatementPeriod.all:
        break;
      case _StatementPeriod.thisMonth:
        from = isoDay(DateTime(now.year, now.month));
        to = isoDay(DateTime(now.year, now.month + 1, 0));
      case _StatementPeriod.thisYear:
        from = '${now.year}-01-01';
        to = '${now.year}-12-31';
      case _StatementPeriod.custom:
        from = _from;
        to = _to;
        if (from == null && to == null) {
          showJibiMessage(context, 'اختر تاريخ البداية أو النهاية على الأقل.');
          return;
        }
        if (from != null && to != null && from.compareTo(to) > 0) {
          showJibiMessage(context, 'تاريخ البداية يجب أن يسبق تاريخ النهاية.');
          return;
        }
    }
    _show(
      context,
      widget.book,
      () => widget.book.reports.walletStatement(
        widget.wallet.id,
        currencyCode: _currency,
        fromDate: from,
        toDate: to,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _OptionsScaffold(
    title: 'كشف المحفظة',
    subject: widget.wallet.name,
    actionLabel: 'عرض الكشف',
    onSubmit: _submit,
    children: [
      if (_currencies.length > 1)
        _Section(
          label: 'العملة',
          child: _ChoiceChips<String?>(
            keyPrefix: 'wallet-report-currency',
            values: [null, ..._currencies],
            labelOf: (value) => value ?? 'كل العملات',
            selected: _currency,
            onSelected: (value) => setState(() => _currency = value),
          ),
        ),
      _Section(
        label: 'الفترة',
        child: _ChoiceChips<_StatementPeriod>(
          keyPrefix: 'period',
          values: _StatementPeriod.values,
          labelOf: (value) => _statementPeriodLabels[value]!,
          selected: _period,
          onSelected: (value) => setState(() => _period = value),
        ),
      ),
      if (_period == _StatementPeriod.custom)
        _Section(
          label: 'من — إلى',
          child: _DateRangeFields(
            from: _from,
            to: _to,
            onFrom: (value) => setState(() => _from = value),
            onTo: (value) => setState(() => _to = value),
          ),
        ),
    ],
  );
}

// ---- category monthly ----------------------------------------------------------

enum _MonthlyPeriod { all, year, custom }

const Map<_MonthlyPeriod, String> _monthlyPeriodLabels = {
  _MonthlyPeriod.all: 'كل الفترات',
  _MonthlyPeriod.year: 'سنة',
  _MonthlyPeriod.custom: 'فترة محددة',
};

/// Options of "إجمالي المبالغ شهرياً": year or dates, one currency, one
/// account.
class CategoryMonthlyOptionsPage extends StatefulWidget {
  const CategoryMonthlyOptionsPage({
    required this.book,
    required this.category,
    super.key,
    this.today,
  });

  final BookServices book;
  final BookCategory category;

  /// For tests.
  final DateTime? today;

  @override
  State<CategoryMonthlyOptionsPage> createState() =>
      _CategoryMonthlyOptionsPageState();
}

class _CategoryMonthlyOptionsPageState
    extends State<CategoryMonthlyOptionsPage> {
  _MonthlyPeriod _period = _MonthlyPeriod.year;
  late int _year = (widget.today ?? DateTime.now()).year;
  String? _from;
  String? _to;
  String? _currency;
  String? _accountId;
  List<AccountSummary> _summaries = const [];

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    try {
      final summaries = await widget.book.accounts.summaries(
        categoryId: widget.category.id,
        includeArchived: false,
      );
      if (!mounted) return;
      setState(() => _summaries = summaries);
    } on Object {
      // The filters just stay empty; the report itself still works.
    }
  }

  /// Every currency any account of the category uses.
  List<String> get _currencies => ({
    for (final summary in _summaries) ...summary.currencyCodes,
  }.toList()..sort());

  /// The accounts that use the chosen currency (all when none is chosen).
  List<BookAccount> get _visibleAccounts => [
    for (final summary in _summaries)
      if (_currency == null || summary.totalsOf(_currency!) != null)
        summary.account,
  ];

  void _submit() {
    int? year;
    String? from;
    String? to;
    switch (_period) {
      case _MonthlyPeriod.all:
        break;
      case _MonthlyPeriod.year:
        year = _year;
      case _MonthlyPeriod.custom:
        from = _from;
        to = _to;
        if (from == null && to == null) {
          showJibiMessage(context, 'اختر تاريخ البداية أو النهاية على الأقل.');
          return;
        }
        if (from != null && to != null && from.compareTo(to) > 0) {
          showJibiMessage(context, 'تاريخ البداية يجب أن يسبق تاريخ النهاية.');
          return;
        }
    }
    _show(
      context,
      widget.book,
      () => widget.book.reports.categoryMonthly(
        widget.category.id,
        year: year,
        fromDate: from,
        toDate: to,
        currencyCode: _currency,
        accountId: _accountId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currencies = _currencies;
    final accounts = _visibleAccounts;
    return _OptionsScaffold(
      title: 'إجمالي المبالغ شهرياً',
      subject: widget.category.name,
      actionLabel: 'عرض التقرير',
      onSubmit: _submit,
      children: [
        _Section(
          label: 'الفترة',
          child: _ChoiceChips<_MonthlyPeriod>(
            keyPrefix: 'period',
            values: _MonthlyPeriod.values,
            labelOf: (value) => _monthlyPeriodLabels[value]!,
            selected: _period,
            onSelected: (value) => setState(() => _period = value),
          ),
        ),
        if (_period == _MonthlyPeriod.year)
          _Section(
            label: 'السنة',
            child: _MonthYearFields(
              month: null,
              year: _year,
              onMonth: null,
              onYear: (value) => setState(() => _year = value),
            ),
          ),
        if (_period == _MonthlyPeriod.custom)
          _Section(
            label: 'من — إلى',
            child: _DateRangeFields(
              from: _from,
              to: _to,
              onFrom: (value) => setState(() => _from = value),
              onTo: (value) => setState(() => _to = value),
            ),
          ),
        if (currencies.length > 1)
          _Section(
            label: 'العملة',
            child: _ChoiceChips<String?>(
              keyPrefix: 'currency',
              values: [null, ...currencies],
              labelOf: (value) => value ?? 'كل العملات',
              selected: _currency,
              onSelected: (value) => setState(() {
                _currency = value;
                _accountId = null;
              }),
            ),
          ),
        if (accounts.length > 1)
          _Section(
            label: 'الحساب',
            child: DropdownButtonFormField<String?>(
              key: ValueKey('account-${_currency ?? 'all'}'),
              initialValue: _accountId,
              isExpanded: true,
              decoration: const InputDecoration(),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('كل الحسابات'),
                ),
                for (final account in accounts)
                  DropdownMenuItem<String?>(
                    value: account.id,
                    child: Text(
                      account.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _accountId = value),
            ),
          ),
      ],
    );
  }
}
