import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../jibi_app_shell.dart';
import 'book_account_page.dart';
import 'book_forms.dart';
import 'book_transaction_form.dart';
import 'book_widgets.dart';
import 'reports/book_report_launcher.dart';

enum _SideFilter { all, debit, credit, settled }

/// One category: its summary per currency and its accounts as cards.
class BookCategoryPage extends StatefulWidget {
  const BookCategoryPage({
    required this.book,
    required this.categoryId,
    super.key,
  });

  final BookServices book;
  final String categoryId;

  @override
  State<BookCategoryPage> createState() => _BookCategoryPageState();
}

class _BookCategoryPageState extends State<BookCategoryPage> {
  late final Stream<List<AccountSummary>> _accounts = widget.book.accounts
      .watchSummaries(categoryId: widget.categoryId);
  late final Stream<List<CategorySummary>> _categories = widget.book.categories
      .watchSummaries(includeInactive: true, includeArchived: true);
  final TextEditingController _query = TextEditingController();
  _SideFilter _filter = _SideFilter.all;
  bool _showArchived = false;
  bool _searching = false;
  String? _currency;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _matchesSide(AccountSummary summary) => switch (_filter) {
    _SideFilter.all => true,
    _SideFilter.debit => summary.hasSide(BalanceSide.debit),
    _SideFilter.credit => summary.hasSide(BalanceSide.credit),
    _SideFilter.settled => summary.hasSide(BalanceSide.settled),
  };

  /// The name, any currency the account uses, or the amount of any of its
  /// currency balances.
  bool _matchesQuery(AccountSummary summary) {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    if (summary.account.name.toLowerCase().contains(query)) return true;
    final digits = query.replaceAll(',', '');
    for (final line in summary.currencies) {
      if (line.currencyCode.toLowerCase().contains(query)) return true;
      final amount = bookAmount(
        widget.book.currencies,
        line.currencyCode,
        line.netMinor.abs(),
      );
      if (amount.replaceAll(',', '').contains(digits)) return true;
    }
    return false;
  }

  Future<void> _toggleStatus(
    BookAccount account,
    BookAccountStatus status,
  ) async {
    try {
      await widget.book.accounts.setStatus(account.id, status);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<CategorySummary>>(
    stream: _categories,
    builder: (context, categorySnapshot) {
      final category = categorySnapshot.data
          ?.where((summary) => summary.category.id == widget.categoryId)
          .map((summary) => summary.category)
          .firstOrNull;
      return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'مدونة الحسابات ‹ شجرة الحسابات',
                style: TextStyle(fontSize: 11, color: context.jibiMuted),
              ),
              Text(
                category?.name ?? '…',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          actions: [
            IconButton(
              key: const Key('category-reports'),
              tooltip: 'تقارير',
              icon: const Icon(Icons.assessment_outlined),
              onPressed: category == null
                  ? null
                  : () => showCategoryReports(context, widget.book, category),
            ),
            IconButton(
              key: const Key('category-search'),
              tooltip: 'بحث',
              icon: Icon(_searching ? Icons.search_off : Icons.search),
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _query.clear();
              }),
            ),
          ],
        ),
        body: StreamBuilder<List<AccountSummary>>(
          stream: _accounts,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text(bookErrorMessage(snapshot.error!)));
            }
            final all = snapshot.data;
            if (all == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return _body(context, all);
          },
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              key: const Key('add-account-button'),
              onPressed: () => openAccountForm(
                context,
                widget.book,
                categoryId: widget.categoryId,
              ),
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('إضافة حساب جديد إلى التصنيف'),
            ),
          ),
        ),
      );
    },
  );

  Widget _body(BuildContext context, List<AccountSummary> all) {
    final live = [
      for (final summary in all)
        if (summary.account.status != BookAccountStatus.archived) summary,
    ];
    if (all.isEmpty) {
      return JibiEmptyState(
        icon: Icons.account_circle_outlined,
        title: 'لا توجد حسابات في هذا التصنيف',
        message: 'أضف أول حساب لتبدأ تسجيل العمليات.',
        actionLabel: 'إضافة حساب',
        onAction: () => openAccountForm(
          context,
          widget.book,
          categoryId: widget.categoryId,
        ),
      );
    }
    final pool = _showArchived ? all : live;
    final shown = [
      for (final summary in pool)
        if (_matchesSide(summary) && _matchesQuery(summary)) summary,
    ];
    int count(bool Function(AccountSummary) test) => pool.where(test).length;
    final archivedCount = all.length - live.length;
    final labels = context.bookPrefs.labels;
    return ListView(
      padding: bookPagePadding,
      children: [
        if (_searching) ...[
          TextField(
            key: const Key('account-search'),
            controller: _query,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'ابحث بالاسم أو الرصيد أو العملة',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 12),
        ],
        // Accounts that use no currency yet (no opening balance, no
        // transaction) have nothing to total: the card appears once there is.
        if (BookBalanceEngine.currencyTotals(live).isNotEmpty) ...[
          _SummaryCard(
            book: widget.book,
            accounts: live,
            selectedCurrency: _currency,
            onCurrency: (code) => setState(() => _currency = code),
          ),
          const SizedBox(height: 14),
        ],
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _chip('الكل', pool.length, _SideFilter.all),
              const SizedBox(width: 8),
              _chip(
                labels.debit,
                count((s) => s.hasSide(BalanceSide.debit)),
                _SideFilter.debit,
              ),
              const SizedBox(width: 8),
              _chip(
                labels.credit,
                count((s) => s.hasSide(BalanceSide.credit)),
                _SideFilter.credit,
              ),
              const SizedBox(width: 8),
              _chip(
                labels.settled,
                count((s) => s.hasSide(BalanceSide.settled)),
                _SideFilter.settled,
              ),
              if (archivedCount > 0) ...[
                const SizedBox(width: 8),
                FilterChip(
                  key: const Key('chip-archived'),
                  label: Text('المؤرشفة ($archivedCount)'),
                  selected: _showArchived,
                  onSelected: (value) => setState(() => _showArchived = value),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                'لا توجد حسابات مطابقة.',
                style: TextStyle(color: context.jibiMuted),
              ),
            ),
          ),
        for (final summary in shown) ...[
          _AccountCard(
            key: Key('account-${summary.account.id}'),
            book: widget.book,
            summary: summary,
            onToggleStatus: _toggleStatus,
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _chip(String label, int count, _SideFilter value) => ChoiceChip(
    key: Key('chip-${value.name}'),
    label: Text('$label ($count)'),
    selected: _filter == value,
    onSelected: (_) => setState(() => _filter = value),
  );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.book,
    required this.accounts,
    required this.selectedCurrency,
    required this.onCurrency,
  });

  final BookServices book;
  final List<AccountSummary> accounts;
  final String? selectedCurrency;
  final ValueChanged<String> onCurrency;

  @override
  Widget build(BuildContext context) {
    final totals = BookBalanceEngine.currencyTotals(accounts);
    // Until the user picks one, show the currency with the most accounts.
    final selected = totals.firstWhere(
      (total) => total.currencyCode == selectedCurrency,
      orElse: () => totals.reduce(
        (best, next) => next.accountCount > best.accountCount ? next : best,
      ),
    );
    final prefs = context.bookPrefs;
    final labels = prefs.labels;
    String amount(int minor) => prefs.balance(
      bookAmount(book.currencies, selected.currencyCode, minor.abs()),
    );
    final side = selected.side;
    return BookCard(
      key: const Key('category-summary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.circle, size: 8, color: JibiColors.deepGreen),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'ملخص مالي للتصنيف',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              if (totals.length == 1)
                JibiBadge(
                  selected.currencyCode,
                  background: JibiColors.gold.withValues(alpha: 0.25),
                  foreground: JibiColors.onTintInk,
                ),
            ],
          ),
          if (totals.length > 1) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final total in totals)
                  ChoiceChip(
                    key: Key('currency-${total.currencyCode}'),
                    label: Text(total.currencyCode),
                    selected: total.currencyCode == selected.currencyCode,
                    onSelected: (_) => onCurrency(total.currencyCode),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: BookStatTile(
                  label: labels.debitWithHint,
                  amount: amount(selected.debitMinor),
                  currencyCode: selected.currencyCode,
                  color: context.sideColor(BalanceSide.debit),
                  icon: sideIcon(BalanceSide.debit),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: BookStatTile(
                  label: labels.creditWithHint,
                  amount: amount(selected.creditMinor),
                  currencyCode: selected.currencyCode,
                  color: context.sideColor(BalanceSide.credit),
                  icon: sideIcon(BalanceSide.credit),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: BookStatTile(
                  label: 'الصافي',
                  amount: amount(selected.netMinor),
                  currencyCode: selected.currencyCode,
                  color: context.sideColor(side),
                  icon: Icons.account_balance_outlined,
                  suffix: labels.side(side),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.book,
    required this.summary,
    required this.onToggleStatus,
    super.key,
  });

  final BookServices book;
  final AccountSummary summary;
  final Future<void> Function(BookAccount, BookAccountStatus) onToggleStatus;

  @override
  Widget build(BuildContext context) {
    final account = summary.account;
    final dimmed = account.status != BookAccountStatus.active;
    return BookCard(
      dimmed: account.status == BookAccountStatus.archived,
      onTap: () => openBookAccount(context, book, account.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BookAvatar(name: account.name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Icon(Icons.history, size: 14, color: context.jibiMuted),
                        Text(
                          '${summary.transactionCount} عملية مسجلة',
                          style: TextStyle(
                            color: context.jibiMuted,
                            fontSize: 12,
                          ),
                        ),
                        if (dimmed)
                          Text(
                            account.status == BookAccountStatus.suspended
                                ? '· متوقف'
                                : '· مؤرشف',
                            style: TextStyle(
                              color: context.jibiMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                key: Key('account-menu-${account.id}'),
                tooltip: 'خيارات الحساب',
                onSelected: (value) async {
                  switch (value) {
                    case 'add':
                      await openTransactionForm(
                        context,
                        book,
                        account: account,
                      );
                    case 'edit':
                      await openAccountForm(context, book, account: account);
                    case 'suspend':
                      await onToggleStatus(account, BookAccountStatus.suspended);
                    case 'activate':
                      await onToggleStatus(account, BookAccountStatus.active);
                    case 'archive':
                      await onToggleStatus(account, BookAccountStatus.archived);
                  }
                },
                itemBuilder: (_) => [
                  if (account.acceptsTransactions)
                    const PopupMenuItem(value: 'add', child: Text('إضافة عملية')),
                  const PopupMenuItem(value: 'edit', child: Text('تعديل الحساب')),
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
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest
                  .withValues(alpha: context.jibiIsDark ? 0.5 : 0.55),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary.currencies.length > 1
                      ? 'الأرصدة القائمة (لكل عملة على حدة)'
                      : 'الرصيد القائم',
                  style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
                ),
                const SizedBox(height: 4),
                AccountBalanceLines(
                  currencies: book.currencies,
                  summary: summary,
                  size: summary.currencies.length > 1 ? 20 : 24,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.chevron_left, size: 20, color: context.jibiMuted),
              const Spacer(),
              Text(
                'كشف الحساب وسجل السندات',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.visibility_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Opens an account's statement full screen (no bottom bar, as it has its own
/// totals bar).
Future<void> openBookAccount(
  BuildContext context,
  BookServices book,
  String accountId,
) => pushFormPage<void>(
  context,
  BookAccountPage(book: book, accountId: accountId),
);
