import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../core/platform/external_link_launcher.dart';
import '../../features/book/book.dart';
import '../../shared/formatting/money_format.dart';
import '../../shared/widgets/coach_marks.dart';
import '../../shared/widgets/external_activity_scope.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../../shared/widgets/whatsapp_glyph.dart';
import '../coach_tours.dart';
import '../jibi_app_shell.dart';
import 'book_audit_page.dart';
import 'book_forms.dart';
import 'book_transaction_details.dart';
import 'book_transaction_form.dart';
import 'book_widgets.dart';
import 'reports/book_report_launcher.dart';

enum _Period { all, thisMonth, thisYear }

/// One account's statement: info card, a pinned-header transactions table,
/// lazy loading, search and filters, and a pinned totals bar.
class BookAccountPage extends StatefulWidget {
  const BookAccountPage({
    required this.book,
    required this.accountId,
    this.launcher = const AndroidExternalLinkLauncher(),
    super.key,
  });

  final BookServices book;
  final String accountId;

  /// Opens the phone's dialer/WhatsApp for the account's phone number.
  /// Overridden in tests to avoid touching real platform channels.
  final ExternalLinkLauncher launcher;

  @override
  State<BookAccountPage> createState() => _BookAccountPageState();
}

class _BookAccountPageState extends State<BookAccountPage> {
  late final Stream<AccountSummary?> _summary = widget.book.accounts
      .watchSummary(widget.accountId);
  late final TransactionListController _list;
  bool _listReady = false;

  // Targets of the hint tour.
  final _tipReports = GlobalKey(debugLabel: 'tip-statement-reports');
  final _tipSearch = GlobalKey(debugLabel: 'tip-statement-search');
  final _tipSort = GlobalKey(debugLabel: 'tip-statement-sort');
  final _tipFilters = GlobalKey(debugLabel: 'tip-statement-filters');
  final _tipFirstRow = GlobalKey(debugLabel: 'tip-statement-row');
  final _tipAdd = GlobalKey(debugLabel: 'tip-statement-add');

  List<CoachStep> _tourSteps() => [
    CoachStep(
      target: _tipReports,
      title: 'تقارير الحساب',
      message:
          'كشف الحساب وكشفه الشهري، وتصديرهما PDF أو Excel أو واتساب أو طباعة.',
    ),
    CoachStep(
      target: _tipSearch,
      title: 'بحث',
      message: 'ابحث بالتفاصيل أو المبلغ أو التاريخ أو رقم العملية.',
    ),
    CoachStep(
      target: _tipFilters,
      title: 'تصفية',
      message: 'حسب النوع والتاريخ والمبلغ والعمليات ذات المرفقات.',
    ),
    CoachStep(
      target: _tipSort,
      title: 'الترتيب',
      message: 'بدّل بين الأحدث أولاً والأقدم أولاً.',
    ),
    CoachStep(
      target: _tipFirstRow,
      title: 'العملية',
      message: 'اضغط عليها لترى تفاصيلها وتعدّلها أو تشاركها أو تحذفها.',
    ),
    CoachStep(
      target: _tipAdd,
      title: 'إضافة جديد',
      message: 'سجّل عملية مدين أو دائن؛ الرصيد يُحسب تلقائياً.',
    ),
  ];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  bool _searching = false;
  _Period _period = _Period.all;
  BookTransactionFilter _sheetFilter = BookTransactionFilter.none;
  BookCategory? _category;
  String? _categoryLoadedFor;

  /// The currencies the account uses, kept up to date from its summary (for the
  /// currency filter and for reading a typed amount in each of them).
  List<String> _currencyCodes = const [];

  /// wallet id -> what the payment method reads as in the rows: «نقدًا» for
  /// the main wallet, the wallet's own name otherwise. Kept live, so renaming
  /// a wallet (or changing which one is main) updates the rows at once.
  Map<String, String> _paymentLabels = const {};
  StreamSubscription<List<WalletSummary>>? _walletsSub;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _walletsSub = widget.book.wallets.watchSummaries().listen((summaries) {
      if (!mounted) return;
      setState(
        () => _paymentLabels = {
          for (final summary in summaries)
            summary.wallet.id: summary.wallet.paymentLabel,
        },
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.startTourOnce(CoachTourIds.account, _tourSteps);
    if (!_listReady) {
      // The order the user chose in the settings is only the starting point;
      // the sort button still flips it for this visit.
      _list = TransactionListController(
        transactions: widget.book.transactions,
        accountId: widget.accountId,
        newestFirst: context.bookPrefs.newestFirst,
      );
      _listReady = true;
    }
  }

  @override
  void dispose() {
    unawaited(_walletsSub?.cancel());
    _debounce?.cancel();
    _scroll.dispose();
    _query.dispose();
    _list.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 400) {
      unawaited(_list.loadMore());
    }
  }

  Future<void> _loadCategory(BookAccount account) async {
    if (_categoryLoadedFor == account.categoryId) return;
    _categoryLoadedFor = account.categoryId;
    final category = await widget.book.categories.find(account.categoryId);
    if (mounted) setState(() => _category = category);
  }

  ({String? from, String? to}) _periodRange() {
    final now = DateTime.now();
    switch (_period) {
      case _Period.all:
        return (from: null, to: null);
      case _Period.thisMonth:
        return (
          from: BookTransaction.formatDate(DateTime(now.year, now.month)),
          to: BookTransaction.formatDate(DateTime(now.year, now.month + 1, 0)),
        );
      case _Period.thisYear:
        return (
          from: BookTransaction.formatDate(DateTime(now.year)),
          to: BookTransaction.formatDate(DateTime(now.year, 12, 31)),
        );
    }
  }

  /// The effective filter: the sheet's choices, the period chips (unless the
  /// sheet set explicit dates) and the search text.
  BookTransactionFilter _effectiveFilter() {
    final range = _periodRange();
    final typed = _query.text.trim();
    // A date typed the way it is shown is looked up by its stored form.
    final text =
        BookPreferencesScope.of(context).isoFromDisplay(typed) ?? typed;
    // The same digits are a different number of minor units in currencies
    // with different decimals, so a typed amount is read in each currency the
    // account uses (or only the one being filtered to).
    Map<String, int>? amounts;
    final numeric = canonicalAmountInput(text);
    if (RegExp(r'^\d+(\.\d+)?$').hasMatch(numeric)) {
      final codes = _sheetFilter.currencyCode == null
          ? _currencyCodes
          : [_sheetFilter.currencyCode!];
      for (final code in codes) {
        try {
          (amounts ??= {})[code.toUpperCase()] = widget.book.currencies
              .parseAmount(input: numeric, currencyCode: code)
              .amountMinor;
        } on Object {
          // Not a valid amount in this currency (too many decimals).
        }
      }
    }
    return _sheetFilter.copyWith(
      fromDate: () => _sheetFilter.fromDate ?? range.from,
      toDate: () => _sheetFilter.toDate ?? range.to,
      text: () => text.isEmpty ? null : text,
      textAmountsMinor: () => amounts,
    );
  }

  void _applyFilter() => unawaited(_list.setFilter(_effectiveFilter()));

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _applyFilter);
  }

  /// Narrows the list, the count and the totals bar to one currency (null =
  /// every currency). An amount range is only meaningful within one currency,
  /// so a change of currency clears it.
  void _setCurrency(String? code) {
    setState(
      () => _sheetFilter = _sheetFilter.copyWith(
        currencyCode: () => code,
        minAmountMinor: () => null,
        maxAmountMinor: () => null,
      ),
    );
    _applyFilter();
  }

  Future<void> _openFilters(BookAccount account) async {
    final result = await showModalBottomSheet<BookTransactionFilter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (_) => _FilterSheet(
        book: widget.book,
        account: account,
        initial: _sheetFilter,
        // An amount range needs one currency: the chosen one, or the only one
        // the account uses.
        amountCurrency:
            _sheetFilter.currencyCode ??
            (_currencyCodes.length == 1 ? _currencyCodes.single : null),
      ),
    );
    if (result != null && mounted) {
      setState(() => _sheetFilter = result);
      _applyFilter();
    }
  }

  Future<void> _addTransaction(BookAccount account) => openTransactionForm(
    context,
    widget.book,
    account: account,
    initialCurrencyCode: _sheetFilter.currencyCode,
  );

  Future<void> _setStatus(BookAccount account, BookAccountStatus status) async {
    try {
      await widget.book.accounts.setStatus(account.id, status);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    }
  }

  Future<void> _delete(BookAccount account, AccountSummary summary) async {
    final transactionCount = summary.transactionCount;
    final confirmed = await JibiConfirmationDialog.show(
      context,
      title: 'حذف الحساب',
      message: transactionCount > 0
          ? 'سيُحذف الحساب «${account.name}» وعملياته الـ$transactionCount '
                'نهائياً. هل تريد المتابعة؟'
          : 'سيُحذف الحساب «${account.name}» نهائياً. هل تريد المتابعة؟',
      confirmLabel: 'حذف',
      isDestructive: true,
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.book.accounts.delete(account.id);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<AccountSummary?>(
    stream: _summary,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting &&
          !snapshot.hasData) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      final summary = snapshot.data;
      if (summary == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('الحساب غير موجود.')),
        );
      }
      unawaited(_loadCategory(summary.account));
      _currencyCodes = summary.currencyCodes;
      // A currency the list was filtered to can stop being one of the account's
      // (its last transaction moved to another currency or was deleted): drop
      // the filter instead of leaving an empty list behind a chip that is gone.
      final filtered = _sheetFilter.currencyCode;
      if (filtered != null && !_currencyCodes.contains(filtered)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _sheetFilter.currencyCode == filtered) {
            _setCurrency(null);
          }
        });
      }
      return _scaffold(context, summary);
    },
  );

  Widget _scaffold(BuildContext context, AccountSummary summary) {
    final account = summary.account;
    return Scaffold(
      appBar: AppBar(
        title: Text(account.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          KeyedSubtree(
            key: _tipReports,
            child: IconButton(
              key: const Key('statement-reports'),
              tooltip: 'تقارير وتصدير',
              icon: const Icon(Icons.assessment_outlined),
              onPressed: () =>
                  showAccountReports(context, widget.book, account),
            ),
          ),
          KeyedSubtree(
            key: _tipSearch,
            child: IconButton(
              key: const Key('statement-search'),
              tooltip: 'بحث',
              icon: Icon(_searching ? Icons.search_off : Icons.search),
              onPressed: () {
                setState(() {
                  _searching = !_searching;
                  if (!_searching && _query.text.isNotEmpty) {
                    _query.clear();
                    _applyFilter();
                  }
                });
              },
            ),
          ),
          PopupMenuButton<String>(
            key: const Key('statement-menu'),
            tooltip: 'المزيد',
            onSelected: (value) async {
              switch (value) {
                case 'edit':
                  await openAccountForm(context, widget.book, account: account);
                case 'suspend':
                  await _setStatus(account, BookAccountStatus.suspended);
                case 'activate':
                  await _setStatus(account, BookAccountStatus.active);
                case 'audit':
                  await pushFormPage<void>(
                    context,
                    BookAuditLogPage(book: widget.book, accountId: account.id),
                  );
                case 'archive':
                  await _setStatus(account, BookAccountStatus.archived);
                case 'delete':
                  await _delete(account, summary);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('تعديل الحساب')),
              const PopupMenuItem(value: 'audit', child: Text('سجل الحساب')),
              if (account.status == BookAccountStatus.active)
                const PopupMenuItem(
                  value: 'suspend',
                  child: Text('إيقاف الحساب'),
                )
              else
                const PopupMenuItem(
                  value: 'activate',
                  child: Text('تفعيل الحساب'),
                ),
              if (account.status != BookAccountStatus.archived)
                const PopupMenuItem(value: 'archive', child: Text('أرشفة')),
              const PopupMenuItem(value: 'delete', child: Text('حذف الحساب')),
            ],
          ),
        ],
      ),
      body: ValueListenableBuilder<TransactionListState>(
        valueListenable: _list,
        builder: (context, state, _) => _body(context, summary, state),
      ),
      bottomNavigationBar: _TotalsBar(
        addKey: _tipAdd,
        book: widget.book,
        summary: summary,
        currencyCode: _sheetFilter.currencyCode,
        onAdd: account.acceptsTransactions
            ? () => _addTransaction(account)
            : null,
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AccountSummary summary,
    TransactionListState state,
  ) {
    final account = summary.account;
    final filterActive = !state.filter.isEmpty;
    final hasAny = summary.transactionCount > 0;
    return CustomScrollView(
      key: const Key('statement-scroll'),
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              children: [
                if (_searching) ...[
                  TextField(
                    key: const Key('statement-query'),
                    controller: _query,
                    autofocus: true,
                    onChanged: (_) => _onQueryChanged(),
                    decoration: const InputDecoration(
                      hintText:
                          'ابحث بالتفاصيل أو المبلغ أو التاريخ أو رقم العملية',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _InfoCard(
                  book: widget.book,
                  summary: summary,
                  categoryName: _category?.name,
                  launcher: widget.launcher,
                ),
                const SizedBox(height: 12),
                _PeriodBar(
                  sortKey: _tipSort,
                  filterKey: _tipFilters,
                  period: _period,
                  count: state.matchCount,
                  newestFirst: state.newestFirst,
                  filterActive: !_sheetFilter.isEmpty,
                  currencies: _currencyCodes,
                  currency: _sheetFilter.currencyCode,
                  onCurrency: _setCurrency,
                  onPeriod: (value) {
                    setState(() => _period = value);
                    _applyFilter();
                  },
                  onToggleSort: () =>
                      unawaited(_list.setNewestFirst(!state.newestFirst)),
                  onFilters: () => _openFilters(account),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        if (state.loading && state.items.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (state.items.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: !hasAny
                ? JibiEmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'لا توجد عمليات لهذا الحساب',
                    message: account.acceptsTransactions
                        ? 'سجّل أول عملية لتظهر هنا.'
                        : 'الحساب لا يقبل عمليات جديدة.',
                    actionLabel: account.acceptsTransactions
                        ? 'إضافة أول عملية'
                        : null,
                    onAction: account.acceptsTransactions
                        ? () => _addTransaction(account)
                        : null,
                  )
                : Center(
                    child: Text(
                      filterActive
                          ? 'لا توجد عمليات مطابقة.'
                          : 'لا توجد عمليات.',
                      style: TextStyle(color: context.jibiMuted),
                    ),
                  ),
          )
        else ...[
          SliverPersistentHeader(
            pinned: true,
            delegate: _TableHeaderDelegate(),
          ),
          SliverList.builder(
            itemCount: state.items.length,
            itemBuilder: (context, index) => KeyedSubtree(
              key: index == 0 ? _tipFirstRow : null,
              child: _TransactionRow(
                key: Key('tx-row-${state.items[index].id}'),
                book: widget.book,
                account: account,
                transaction: state.items[index],
                paymentLabel: _paymentLabels[state.items[index].walletId],
                onTap: () => showBookTransactionDetails(
                  context,
                  book: widget.book,
                  account: account,
                  transactionId: state.items[index].id,
                ),
              ),
            ),
          ),
          if (state.loadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.book,
    required this.summary,
    required this.categoryName,
    required this.launcher,
  });

  final BookServices book;
  final ExternalLinkLauncher launcher;
  final AccountSummary summary;
  final String? categoryName;

  @override
  Widget build(BuildContext context) {
    final account = summary.account;
    final several = summary.currencies.length > 1;
    return BookCard(
      key: const Key('statement-info'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Spacer(),
              if (categoryName != null)
                JibiBadge(
                  categoryName!,
                  icon: Icons.folder_open_outlined,
                  background: Theme.of(context).colorScheme.primary
                      .withValues(alpha: 0.10),
                  foreground: Theme.of(context).colorScheme.primary,
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            several ? 'الأرصدة القائمة (لكل عملة على حدة)' : 'الرصيد القائم',
            style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          // One row per currency the account uses; never a single total.
          KeyedSubtree(
            key: const Key('statement-balance'),
            child: AccountBalanceLines(
              currencies: book.currencies,
              summary: summary,
              size: several ? 22 : 32,
            ),
          ),
          if (account.phone != null && account.phone!.isNotEmpty) ...[
            const SizedBox(height: 12),
            _PhoneRow(phone: account.phone!, launcher: launcher),
          ],
          if (account.status != BookAccountStatus.active) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: context.jibiMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    account.status == BookAccountStatus.suspended
                        ? 'الحساب متوقف: يمكنك عرضه والبحث فيه، ولا يقبل عمليات جديدة.'
                        : 'الحساب مؤرشف.',
                    style: TextStyle(color: context.jibiMuted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The account's phone number with quick call/WhatsApp buttons, mirroring
/// the support screen's launch pattern (external activity scope, silent
/// failure surfaced as a toast).
class _PhoneRow extends StatelessWidget {
  const _PhoneRow({required this.phone, required this.launcher});

  final String phone;
  final ExternalLinkLauncher launcher;

  static String _digitsOnly(String value) => value
      .replaceAllMapped(
        RegExp('[٠-٩]'),
        (m) => '٠١٢٣٤٥٦٧٨٩'.indexOf(m[0]!).toString(),
      )
      .replaceAll(RegExp(r'[^0-9]'), '');

  Future<void> _launch(
    BuildContext context,
    Future<bool> Function() open, {
    required String unavailable,
  }) async {
    final run = ExternalActivityScope.of(context);
    final release = ExternalActivityScope.releaseOf(context);
    var opened = false;
    try {
      opened = await run(open, holdUntilResumed: true);
    } on Object {
      opened = false;
    }
    if (opened) return;
    release();
    if (context.mounted) showJibiMessage(context, unavailable);
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(Icons.phone_outlined, size: 16, color: context.jibiMuted),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          phone,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.start,
          style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
        ),
      ),
      IconButton(
        key: const Key('account-phone-call'),
        tooltip: 'اتصال',
        icon: const Icon(Icons.call_outlined),
        onPressed: () => _launch(
          context,
          () => launcher.dial(phone),
          unavailable: 'لا يوجد تطبيق اتصال على هذا الجهاز.',
        ),
      ),
      IconButton(
        key: const Key('account-phone-whatsapp'),
        tooltip: 'واتساب',
        icon: const WhatsAppGlyph(size: 20, color: Color(0xFF25D366)),
        onPressed: () => _launch(
          context,
          () => launcher.openWhatsApp(
            phone: _digitsOnly(phone),
            message: '',
          ),
          unavailable: 'تعذر فتح واتساب على هذا الجهاز.',
        ),
      ),
    ],
  );
}

class _PeriodBar extends StatelessWidget {
  const _PeriodBar({
    required this.sortKey,
    required this.filterKey,
    required this.period,
    required this.count,
    required this.newestFirst,
    required this.filterActive,
    required this.currencies,
    required this.currency,
    required this.onCurrency,
    required this.onPeriod,
    required this.onToggleSort,
    required this.onFilters,
  });

  final GlobalKey sortKey;
  final GlobalKey filterKey;
  final _Period period;
  final int count;
  final bool newestFirst;
  final bool filterActive;

  /// The currencies the account uses; the chips appear when there are several.
  final List<String> currencies;
  final String? currency;
  final ValueChanged<String?> onCurrency;
  final ValueChanged<_Period> onPeriod;
  final VoidCallback onToggleSort;
  final VoidCallback onFilters;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final entry in const {
              _Period.all: 'الكل',
              _Period.thisMonth: 'هذا الشهر',
              _Period.thisYear: 'هذه السنة',
            }.entries) ...[
              ChoiceChip(
                key: Key('period-${entry.key.name}'),
                label: Text(entry.value),
                selected: period == entry.key,
                onSelected: (_) => onPeriod(entry.key),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
      if (currencies.length > 1) ...[
        const SizedBox(height: 4),
        SingleChildScrollView(
          key: const Key('currency-filter'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ChoiceChip(
                key: const Key('currency-filter-all'),
                label: const Text('كل العملات'),
                selected: currency == null,
                onSelected: (_) => onCurrency(null),
              ),
              for (final code in currencies) ...[
                const SizedBox(width: 8),
                ChoiceChip(
                  key: Key('currency-filter-$code'),
                  label: Text(code),
                  selected: currency == code,
                  onSelected: (_) => onCurrency(code),
                ),
              ],
            ],
          ),
        ),
      ],
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(
            child: Text(
              'العمليات: $count',
              key: const Key('statement-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.jibiMuted,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
          Flexible(
            child: KeyedSubtree(
              key: sortKey,
              child: TextButton.icon(
                key: const Key('statement-sort'),
                onPressed: onToggleSort,
                icon: Icon(
                  newestFirst ? Icons.arrow_downward : Icons.arrow_upward,
                  size: 16,
                ),
                label: Text(
                  newestFirst ? 'الأحدث أولاً' : 'الأقدم أولاً',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          KeyedSubtree(
            key: filterKey,
            child: Badge(
              isLabelVisible: filterActive,
              smallSize: 8,
              child: IconButton(
                key: const Key('statement-filters'),
                tooltip: 'تصفية',
                icon: const Icon(Icons.filter_list),
                onPressed: onFilters,
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

/// Column layout shared by the pinned header and every row so they align.
/// Visual order in RTL, right to left: date, amount, details, balance.
const int _flexDate = 5;
const int _flexAmount = 5;
const int _flexDetails = 5;
const int _flexBalance = 5;

class _TableHeaderDelegate extends SliverPersistentHeaderDelegate {
  @override
  double get minExtent => 40;

  @override
  double get maxExtent => 40;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    TextStyle style() => TextStyle(
      color: context.jibiMuted,
      fontSize: 12,
      fontWeight: FontWeight.w800,
    );
    Widget cell(String label, int flex) => Expanded(
      flex: flex,
      child: Text(label, style: style()),
    );
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: overlapsContent ? 1 : 0,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Row(
          children: [
            cell('التاريخ', _flexDate),
            cell('المبلغ', _flexAmount),
            cell('التفاصيل', _flexDetails),
            cell('الرصيد', _flexBalance),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) =>
      false;
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({
    required this.book,
    required this.account,
    required this.transaction,
    required this.paymentLabel,
    required this.onTap,
    super.key,
  });

  final BookServices book;
  final BookAccount account;
  final BookTransaction transaction;

  /// The payment method as the user sees it («نقدًا» or the wallet's name);
  /// null when the transaction has none (or the names are still loading).
  final String? paymentLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final prefs = context.bookPrefs;
    final labels = prefs.labels;
    final side = sideOfEntry(transaction.type);
    final color = context.sideColor(side);
    final balanceSide = balanceSideOf(transaction.balanceAfter);
    final attachment = transaction.attachments.firstOrNull;
    final muted = TextStyle(color: context.jibiMuted, fontSize: 11);
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: _flexDate,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prefs.date(transaction.date),
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '#${transaction.number}',
                    textDirection: TextDirection.ltr,
                    style: muted,
                  ),
                  if (prefs.showTime)
                    Text(
                      transaction.time,
                      key: Key('row-time-${transaction.id}'),
                      textDirection: TextDirection.ltr,
                      style: muted,
                    ),
                ],
              ),
            ),
            Expanded(
              flex: _flexAmount,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            bookAmount(
                              book.currencies,
                              transaction.currencyCode,
                              transaction.amountMinor,
                            ),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(sideIcon(side), size: 14, color: color),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${transaction.currencyCode} · ${labels.entry(transaction.type)}',
                    style: muted,
                  ),
                ],
              ),
            ),
            Expanded(
              flex: _flexDetails,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (paymentLabel != null) ...[
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 15,
                          color: context.jibiMuted,
                        ),
                        const SizedBox(width: 2),
                      ],
                      if (attachment != null) ...[
                        Icon(
                          Icons.attach_file,
                          size: 15,
                          color: JibiColors.goldSoft,
                        ),
                        const SizedBox(width: 2),
                      ],
                      Expanded(
                        child: Text(
                          transaction.details ?? '—',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (attachment != null || paymentLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        [
                          ?paymentLabel,
                          if (attachment != null)
                            attachmentKindLabel(attachment.kind),
                        ].join(' · '),
                        key: Key('row-payment-${transaction.id}'),
                        style: muted,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: _flexBalance,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prefs.balance(
                      bookAmount(
                        book.currencies,
                        transaction.currencyCode,
                        transaction.balanceAfter.abs(),
                      ),
                    ),
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  SidePill(side: balanceSide, compact: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalsBar extends StatelessWidget {
  const _TotalsBar({
    required this.addKey,
    required this.book,
    required this.summary,
    required this.currencyCode,
    required this.onAdd,
  });

  final GlobalKey addKey;
  final BookServices book;
  final AccountSummary summary;

  /// The currency the list is filtered to; null shows every currency of the
  /// account, each on its own row.
  final String? currencyCode;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final prefs = context.bookPrefs;
    final labels = prefs.labels;
    final shown = currencyCode == null
        ? summary.currencies
        : [
            ?summary.totalsOf(currencyCode!),
          ];
    final several = shown.length > 1;
    Widget cell({
      required String label,
      required String value,
      required Color color,
      bool highlighted = false,
      Key? key,
    }) => Expanded(
      child: Container(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: highlighted
              ? Theme.of(context).colorScheme.surface
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: context.jibiMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    /// The debit / net / credit of ONE currency of the account. With several
    /// currencies each gets its own row, keyed by its code.
    Widget totals(AccountCurrencyTotals line) {
      final code = line.currencyCode;
      final side = line.side;
      String amount(int minor) => prefs.balance(
        bookAmount(book.currencies, code, minor.abs()),
      );
      String suffix(String key) => several ? '-$code' : '';
      return Container(
        padding: const EdgeInsets.all(4),
        margin: EdgeInsets.only(bottom: several ? 6 : 0),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest
              .withValues(alpha: context.jibiIsDark ? 0.5 : 0.7),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            cell(
              key: Key('total-debit${suffix('debit')}'),
              label: 'إجمالي ${labels.debit}',
              value: '$code ${amount(line.debitMinor)}',
              color: context.sideColor(BalanceSide.debit),
            ),
            cell(
              key: Key('total-net${suffix('net')}'),
              label: 'الرصيد الصافي',
              value: '${amount(line.netMinor)} ${labels.side(side)}',
              color: context.sideColor(side),
              highlighted: true,
            ),
            cell(
              key: Key('total-credit${suffix('credit')}'),
              label: 'إجمالي ${labels.credit}',
              value: '$code ${amount(line.creditMinor)}',
              color: context.sideColor(BalanceSide.credit),
            ),
          ],
        ),
      );
    }

    return Material(
      elevation: 8,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (shown.isNotEmpty)
                several
                    // Never taller than about two rows; the rest scroll.
                    ? ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 150),
                        child: SingleChildScrollView(
                          key: const Key('totals-per-currency'),
                          child: Column(children: [for (final line in shown) totals(line)]),
                        ),
                      )
                    : totals(shown.single),
              if (shown.isNotEmpty) const SizedBox(height: 10),
              SizedBox(
                key: addKey,
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('add-transaction-button'),
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('إضافة جديد'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.book,
    required this.account,
    required this.initial,
    required this.amountCurrency,
  });

  final BookServices book;
  final BookAccount account;
  final BookTransactionFilter initial;

  /// The one currency an amount range is read in; null when the account uses
  /// several and none is chosen (the range is then unavailable).
  final String? amountCurrency;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late EntryType? _type = widget.initial.type;
  late String? _from = widget.initial.fromDate;
  late String? _to = widget.initial.toDate;
  late bool _withAttachments = widget.initial.withAttachments;
  late String? _walletId = widget.initial.walletId;
  List<WalletSummary> _wallets = const [];
  late final TextEditingController _min = TextEditingController(
    text: widget.initial.minAmountMinor == null
        ? ''
        : bookAmount(
            widget.book.currencies,
            widget.amountCurrency ?? widget.book.defaultCurrencyCode(),
            widget.initial.minAmountMinor!,
          ),
  );
  late final TextEditingController _max = TextEditingController(
    text: widget.initial.maxAmountMinor == null
        ? ''
        : bookAmount(
            widget.book.currencies,
            widget.amountCurrency ?? widget.book.defaultCurrencyCode(),
            widget.initial.maxAmountMinor!,
          ),
  );

  @override
  void initState() {
    super.initState();
    _loadWallets();
  }

  Future<void> _loadWallets() async {
    final all = await widget.book.wallets.summaries(includeArchived: true);
    final matching = paymentWalletOrder([
      for (final summary in all)
        if (summary.wallet.status == WalletStatus.active ||
            summary.wallet.id == _walletId)
          summary,
    ]);
    if (!mounted) return;
    setState(() => _wallets = matching);
  }

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  int? _parse(String text) {
    final currency = widget.amountCurrency;
    if (currency == null) return null;
    final canonical = canonicalAmountInput(text);
    if (canonical.isEmpty) return null;
    try {
      return widget.book.currencies
          .parseAmount(input: canonical, currencyCode: currency)
          .amountMinor;
    } on Object {
      return null;
    }
  }

  Future<void> _pickDate({required bool from}) async {
    final current =
        DateTime.tryParse((from ? _from : _to) ?? '') ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        final iso = BookTransaction.formatDate(picked);
        if (from) {
          _from = iso;
        } else {
          _to = iso;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.bookPrefs.labels;
    final amountCurrency = widget.amountCurrency;
    final fraction = widget.book.currencies
        .byCode(amountCurrency ?? widget.book.defaultCurrencyCode())
        .fractionDigits;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'تصفية العمليات',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    key: const Key('filter-type-all'),
                    label: const Text('الكل'),
                    selected: _type == null,
                    onSelected: (_) => setState(() => _type = null),
                  ),
                  ChoiceChip(
                    key: const Key('filter-type-debit'),
                    label: Text('${labels.debit} فقط'),
                    selected: _type == EntryType.debit,
                    onSelected: (_) => setState(() => _type = EntryType.debit),
                  ),
                  ChoiceChip(
                    key: const Key('filter-type-credit'),
                    label: Text('${labels.credit} فقط'),
                    selected: _type == EntryType.credit,
                    onSelected: (_) => setState(() => _type = EntryType.credit),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('filter-from'),
                      onPressed: () => _pickDate(from: true),
                      child: Text(_from == null ? 'من تاريخ' : 'من $_from'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('filter-to'),
                      onPressed: () => _pickDate(from: false),
                      child: Text(_to == null ? 'إلى تاريخ' : 'إلى $_to'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (amountCurrency == null)
                Text(
                  'اختر عملة معيّنة من شريط العملات لتحديد نطاق للمبلغ.',
                  key: const Key('filter-amount-needs-currency'),
                  style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
                )
              else
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('filter-min'),
                      controller: _min,
                      textDirection: TextDirection.ltr,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        ThousandsInputFormatter(fractionDigits: fraction),
                      ],
                      decoration: const InputDecoration(labelText: 'مبلغ من'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      key: const Key('filter-max'),
                      controller: _max,
                      textDirection: TextDirection.ltr,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        ThousandsInputFormatter(fractionDigits: fraction),
                      ],
                      decoration: const InputDecoration(labelText: 'مبلغ إلى'),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                key: const Key('filter-attachments'),
                contentPadding: EdgeInsets.zero,
                title: const Text('عمليات تحتوي على مرفقات'),
                value: _withAttachments,
                onChanged: (value) => setState(() => _withAttachments = value),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  'وسيلة الدفع',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    key: const Key('filter-payment-all'),
                    label: const Text('الكل'),
                    selected: _walletId == null,
                    onSelected: (_) => setState(() => _walletId = null),
                  ),
                  for (final summary in _wallets)
                    ChoiceChip(
                      key: Key('filter-payment-wallet-${summary.wallet.id}'),
                      label: Text(
                        summary.wallet.paymentLabel,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: _walletId == summary.wallet.id,
                      onSelected: (_) =>
                          setState(() => _walletId = summary.wallet.id),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('filter-clear'),
                      // Clearing keeps the chosen currency: that is picked on
                      // the page itself, next to the list.
                      onPressed: () => Navigator.of(context).pop(
                        BookTransactionFilter(
                          currencyCode: widget.initial.currencyCode,
                        ),
                      ),
                      child: const Text('مسح'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      key: const Key('filter-apply'),
                      onPressed: () => Navigator.of(context).pop(
                        BookTransactionFilter(
                          type: _type,
                          fromDate: _from,
                          toDate: _to,
                          minAmountMinor: _parse(_min.text),
                          maxAmountMinor: _parse(_max.text),
                          withAttachments: _withAttachments,
                          walletId: _walletId,
                          currencyCode: widget.initial.currencyCode,
                        ),
                      ),
                      child: const Text('تطبيق'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
