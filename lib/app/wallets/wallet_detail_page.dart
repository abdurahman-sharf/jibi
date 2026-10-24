import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../features/wallets/wallets.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../book/book_widgets.dart';
import '../book/reports/book_report_launcher.dart';
import 'wallet_forms.dart';
import 'wallet_operation_forms.dart';
import 'wallet_transaction_details.dart';
import 'wallet_widgets.dart';

/// One wallet's statement: header card (a currency-chip strip when it holds
/// more than one), movement history, filters, and the
/// إيداع/سحب/تحويل/صرف actions.
class WalletDetailPage extends StatefulWidget {
  const WalletDetailPage({required this.book, required this.walletId, super.key});

  final BookServices book;
  final String walletId;

  @override
  State<WalletDetailPage> createState() => _WalletDetailPageState();
}

class _WalletDetailPageState extends State<WalletDetailPage> {
  late final Stream<WalletSummary?> _summary = widget.book.wallets.watchSummary(
    widget.walletId,
  );
  late final WalletTransactionListController _list;
  bool _listReady = false;
  bool _currencyReady = false;
  final ScrollController _scroll = ScrollController();
  WalletTransactionType? _typeFilter;
  String? _currency;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_listReady) {
      _list = WalletTransactionListController(
        movements: widget.book.walletTransactions,
        walletId: widget.walletId,
      );
      _listReady = true;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    if (_listReady) _list.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 400) {
      unawaited(_list.loadMore());
    }
  }

  void _applyTypeFilter(WalletTransactionType? type) {
    setState(() => _typeFilter = type);
    unawaited(_list.setFilter(WalletTransactionFilter(type: type)));
  }

  void _selectCurrency(String code) {
    setState(() => _currency = code);
    unawaited(_list.setCurrency(code));
  }

  /// The list starts scoped to the wallet's primary currency once the first
  /// summary arrives; done post-frame since [WalletTransactionListController]
  /// notifies its listeners synchronously and this runs from inside [build].
  void _ensureCurrencyReady(WalletSummary summary) {
    if (_currencyReady) return;
    _currencyReady = true;
    final code = summary.primary?.currencyCode;
    _currency = code;
    if (code != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_list.setCurrency(code));
      });
    }
  }

  Future<void> _delete(Wallet wallet, WalletSummary summary) async {
    final confirmed = await JibiConfirmationDialog.show(
      context,
      title: 'حذف المحفظة',
      message: summary.transactionCount > 0
          ? 'سيُحذف كل ما في محفظة «${wallet.name}» نهائياً، '
                'بما في ذلك حركاتها الـ${summary.transactionCount}. '
                'هل تريد المتابعة؟'
          : 'سيُحذف محفظة «${wallet.name}» نهائياً. هل تريد المتابعة؟',
      confirmLabel: 'حذف',
      isDestructive: true,
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.book.wallets.delete(wallet.id);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    }
  }

  Future<void> _setStatus(Wallet wallet, WalletStatus status) async {
    try {
      await widget.book.wallets.setStatus(wallet.id, status);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    }
  }

  Future<void> _setMain(Wallet wallet) async {
    try {
      await widget.book.wallets.setMain(wallet.id);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<WalletSummary?>(
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
          body: const Center(child: Text('المحفظة غير موجودة.')),
        );
      }
      _ensureCurrencyReady(summary);
      return _scaffold(context, summary);
    },
  );

  Widget _scaffold(BuildContext context, WalletSummary summary) {
    final wallet = summary.wallet;
    return Scaffold(
      appBar: AppBar(
        title: Text(wallet.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('wallet-reports'),
            tooltip: 'تقارير وتصدير',
            icon: const Icon(Icons.assessment_outlined),
            onPressed: () => showWalletReports(context, widget.book, wallet),
          ),
          PopupMenuButton<String>(
            key: const Key('wallet-detail-menu'),
            tooltip: 'المزيد',
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  openWalletForm(context, widget.book, wallet: wallet);
                case 'main':
                  _setMain(wallet);
                case 'archive':
                  _setStatus(wallet, WalletStatus.archived);
                case 'activate':
                  _setStatus(wallet, WalletStatus.active);
                case 'delete':
                  _delete(wallet, summary);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('تعديل المحفظة')),
              if (!wallet.isMain)
                const PopupMenuItem(
                  value: 'main',
                  child: Text('تعيين كمحفظة رئيسية'),
                ),
              if (wallet.status == WalletStatus.active)
                const PopupMenuItem(value: 'archive', child: Text('أرشفة'))
              else
                const PopupMenuItem(
                  value: 'activate',
                  child: Text('إلغاء الأرشفة'),
                ),
              const PopupMenuItem(value: 'delete', child: Text('حذف المحفظة')),
            ],
          ),
        ],
      ),
      body: ValueListenableBuilder<WalletTransactionListState>(
        valueListenable: _list,
        builder: (context, state, _) => _body(context, summary, state),
      ),
      bottomNavigationBar: wallet.status == WalletStatus.active
          ? _ActionsBar(
              book: widget.book,
              wallet: wallet,
              summary: summary,
              currency: _currency,
            )
          : null,
    );
  }

  Widget _body(
    BuildContext context,
    WalletSummary summary,
    WalletTransactionListState state,
  ) {
    final wallet = summary.wallet;
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              children: [
                _HeaderCard(
                  book: widget.book,
                  summary: summary,
                  selected: _currency,
                  onSelect: _selectCurrency,
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _TypeFilterChips(
                    selected: _typeFilter,
                    onChanged: _applyTypeFilter,
                  ),
                ),
                const SizedBox(height: 4),
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
            child: JibiEmptyState(
              icon: Icons.receipt_long_outlined,
              title: _typeFilter == null
                  ? 'لا توجد حركات لهذه المحفظة'
                  : 'لا توجد حركات مطابقة',
              message: wallet.status == WalletStatus.active
                  ? 'سجّل إيداعاً أو سحباً أو تحويلاً ليظهر هنا.'
                  : 'المحفظة مؤرشفة.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.separated(
              itemCount: state.items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) => _MovementRow(
                key: Key('wtx-row-${state.items[index].id}'),
                book: widget.book,
                wallet: wallet,
                transaction: state.items[index],
                onTap: () => showWalletTransactionDetails(
                  context,
                  book: widget.book,
                  wallet: wallet,
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
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.book,
    required this.summary,
    required this.selected,
    required this.onSelect,
  });

  final BookServices book;
  final WalletSummary summary;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final wallet = summary.wallet;
    final accountNumber = wallet.accountNumber;
    final shown = summary.balances.isEmpty
        ? null
        : summary.balances.firstWhere(
            (balance) => balance.currencyCode == selected,
            orElse: () => summary.primary ?? summary.balances.first,
          );
    final negative = (shown?.balanceMinor ?? 0) < 0;
    return BookCard(
      key: const Key('wallet-detail-header'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              WalletAvatar(wallet: wallet, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        wallet.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (wallet.isMain) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: JibiBadge(
                          'رئيسية',
                          background: JibiColors.gold.withValues(alpha: 0.22),
                          foreground: JibiColors.onTintInk,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (summary.balances.length > 1) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final balance in summary.balances)
                  ChoiceChip(
                    key: Key('wallet-currency-${balance.currencyCode}'),
                    label: Text(balance.currencyCode),
                    selected: balance.currencyCode == (shown?.currencyCode),
                    onSelected: (_) => onSelect(balance.currencyCode),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'الرصيد الحالي',
            style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
          ),
          const SizedBox(height: 4),
          if (shown == null)
            Text(
              'لا توجد عملة بعد',
              style: TextStyle(color: context.jibiMuted, fontSize: 14),
            )
          else
            BookAmountText(
              key: const Key('wallet-detail-balance'),
              text: context.bookPrefs.balance(
                bookAmount(book.currencies, shown.currencyCode, shown.balanceMinor.abs()),
              ),
              currencyCode: shown.currencyCode,
              size: 30,
              color: negative ? context.sideColor(BalanceSide.debit) : context.jibiInk,
            ),
          if (accountNumber != null && accountNumber.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.numbers, size: 16, color: context.jibiMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    accountNumber,
                    textDirection: TextDirection.ltr,
                    style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ],
          if (wallet.status == WalletStatus.archived) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: context.jibiMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'المحفظة مؤرشفة.',
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

class _TypeFilterChips extends StatelessWidget {
  const _TypeFilterChips({required this.selected, required this.onChanged});

  final WalletTransactionType? selected;
  final ValueChanged<WalletTransactionType?> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = <(String, WalletTransactionType?)>[
      ('الكل', null),
      ('إيداع', WalletTransactionType.deposit),
      ('سحب', WalletTransactionType.withdrawal),
      ('تحويل', WalletTransactionType.transfer),
      ('صرف', WalletTransactionType.exchange),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (label, type) in options) ...[
            ChoiceChip(
              key: Key('wallet-filter-${type?.dbValue ?? 'all'}'),
              label: Text(label),
              selected: selected == type,
              onSelected: (_) => onChanged(type),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({
    super.key,
    required this.book,
    required this.wallet,
    required this.transaction,
    required this.onTap,
  });

  final BookServices book;
  final Wallet wallet;
  final WalletTransaction transaction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final incoming = transaction.direction == WalletDirection.incoming;
    final color = incoming
        ? context.sideColor(BalanceSide.credit)
        : context.sideColor(BalanceSide.debit);
    final amount = bookAmount(
      book.currencies,
      transaction.currencyCode,
      transaction.amountMinor,
    );
    final balance = bookAmount(
      book.currencies,
      transaction.currencyCode,
      transaction.balanceAfter.abs(),
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.12),
              ),
              child: Icon(
                incoming ? Icons.south_west : Icons.north_east,
                color: color,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    walletMovementTypeLabel(transaction.type),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${context.bookPrefs.date(transaction.date)} • ${transaction.number}',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(color: context.jibiMuted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                BookAmountText(
                  text: '${incoming ? '+' : '-'}$amount',
                  currencyCode: transaction.currencyCode,
                  color: color,
                  size: 14,
                  currencyFirst: false,
                ),
                const SizedBox(height: 2),
                Text(
                  'الرصيد $balance',
                  style: TextStyle(color: context.jibiMuted, fontSize: 10.5),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionsBar extends StatelessWidget {
  const _ActionsBar({
    required this.book,
    required this.wallet,
    required this.summary,
    this.currency,
  });

  final BookServices book;
  final Wallet wallet;
  final WalletSummary summary;

  /// The currency the page is showing; the forms start from it.
  final String? currency;

  // Tight padding and a smaller, unified label size so all four actions fit
  // one row on a normal phone width without the label wrapping to two lines.
  static const ButtonStyle _style = ButtonStyle(
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
    visualDensity: VisualDensity.compact,
    textStyle: WidgetStatePropertyAll(
      TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    ),
  );

  static const _label = TextOverflow.ellipsis;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('wallet-deposit-button'),
              style: _style,
              onPressed: () => openWalletDepositForm(
                context,
                book,
                wallet,
                initialCurrency: currency,
              ),
              icon: const Icon(Icons.south_west, size: 18),
              label: const Text(
                'إيداع',
                maxLines: 1,
                softWrap: false,
                overflow: _label,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('wallet-withdraw-button'),
              style: _style,
              onPressed: () => openWalletWithdrawalForm(
                context,
                book,
                wallet,
                initialCurrency: currency,
              ),
              icon: const Icon(Icons.north_east, size: 18),
              label: const Text(
                'سحب',
                maxLines: 1,
                softWrap: false,
                overflow: _label,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('wallet-transfer-button'),
              style: _style,
              onPressed: () => openWalletTransferForm(
                context,
                book,
                wallet,
                initialCurrency: currency,
              ),
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: const Text(
                'تحويل',
                maxLines: 1,
                softWrap: false,
                overflow: _label,
              ),
            ),
          ),
          if (summary.balances.isNotEmpty) ...[
            const SizedBox(width: 6),
            Expanded(
              child: FilledButton.icon(
                key: const Key('wallet-exchange-button'),
                style: _style,
                onPressed: () => openWalletExchangeForm(
                  context,
                  book,
                  wallet,
                  initialCurrency: currency,
                ),
                icon: const Icon(Icons.currency_exchange, size: 18),
                label: const Text(
                  'صرف',
                  maxLines: 1,
                  softWrap: false,
                  overflow: _label,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
