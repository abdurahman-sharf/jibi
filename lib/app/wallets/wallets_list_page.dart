import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../book/book_widgets.dart';
import '../jibi_app_shell.dart';
import 'wallet_detail_page.dart';
import 'wallet_forms.dart';
import 'wallet_widgets.dart';

/// "المحافظ": every wallet with its balance, and the management actions
/// (تعديل، تعيين كرئيسية، أرشفة، حذف).
class WalletsListPage extends StatefulWidget {
  const WalletsListPage({required this.book, super.key});

  final BookServices book;

  @override
  State<WalletsListPage> createState() => _WalletsListPageState();
}

class _WalletsListPageState extends State<WalletsListPage> {
  late final Stream<List<WalletSummary>> _summaries = widget.book.wallets
      .watchSummaries();
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('المحافظ')),
    body: StreamBuilder<List<WalletSummary>>(
      stream: _summaries,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text(bookErrorMessage(snapshot.error!)));
        }
        final all = snapshot.data;
        if (all == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (all.isEmpty) {
          return JibiEmptyState(
            icon: Icons.account_balance_wallet_outlined,
            title: 'لا توجد محافظ حتى الآن',
            message: 'أضف محفظة لتتبع نقدك أو حسابك البنكي.',
            actionLabel: 'إضافة محفظة',
            onAction: () => openWalletForm(context, widget.book),
          );
        }
        final visible = [
          for (final summary in all)
            if (_showArchived || summary.wallet.status != WalletStatus.archived)
              summary,
        ];
        return ListView(
          padding: bookPagePadding,
          children: [
            JibiSectionHeader(
              title: 'المحافظ',
              count: visible.length,
              actionLabel: _showArchived ? 'إخفاء المؤرشفة' : 'إظهار المؤرشفة',
              onAction: () => setState(() => _showArchived = !_showArchived),
            ),
            const SizedBox(height: 12),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'لا توجد محافظ نشطة.',
                  style: TextStyle(color: context.jibiMuted),
                ),
              ),
            for (final summary in visible) ...[
              _WalletCard(book: widget.book, summary: summary),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 4),
            OutlinedButton.icon(
              key: const Key('add-wallet-button'),
              onPressed: () => openWalletForm(context, widget.book),
              icon: const Icon(Icons.add),
              label: const Text('إضافة محفظة جديدة'),
            ),
          ],
        );
      },
    ),
  );
}

class _WalletCard extends StatelessWidget {
  const _WalletCard({required this.book, required this.summary});

  final BookServices book;
  final WalletSummary summary;

  Future<void> _delete(BuildContext context) async {
    final wallet = summary.wallet;
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
    if (confirmed != true || !context.mounted) return;
    try {
      await book.wallets.delete(wallet.id);
    } on Object catch (error) {
      if (context.mounted) showBookError(context, error);
    }
  }

  Future<void> _setStatus(BuildContext context, WalletStatus status) async {
    try {
      await book.wallets.setStatus(summary.wallet.id, status);
    } on Object catch (error) {
      if (context.mounted) showBookError(context, error);
    }
  }

  Future<void> _setMain(BuildContext context) async {
    try {
      await book.wallets.setMain(summary.wallet.id);
    } on Object catch (error) {
      if (context.mounted) showBookError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = summary.wallet;
    final primary = summary.primary;
    final amount = primary == null
        ? '—'
        : bookAmount(book.currencies, primary.currencyCode, primary.balanceMinor.abs());
    final otherCount = summary.isMultiCurrency ? summary.nonZero.length - 1 : 0;
    final accountNumber = wallet.accountNumber;
    return BookCard(
      dimmed: wallet.status == WalletStatus.archived,
      onTap: () => pushShellPage<void>(
        context,
        WalletDetailPage(book: book, walletId: wallet.id),
      ),
      child: Row(
        children: [
          WalletAvatar(wallet: wallet, size: 48),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        wallet.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
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
                if (accountNumber != null && accountNumber.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    accountNumber,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerEnd,
                  child: BookAmountText(
                    text: amount,
                    currencyCode: primary?.currencyCode ?? '',
                    size: 16,
                    currencyFirst: false,
                    color: (primary?.balanceMinor ?? 0) < 0
                        ? context.sideColor(BalanceSide.debit)
                        : null,
                  ),
                ),
                if (otherCount > 0)
                  Text(
                    '+$otherCount عملات أخرى',
                    style: TextStyle(color: context.jibiMuted, fontSize: 10.5),
                  ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            key: Key('wallet-menu-${wallet.id}'),
            tooltip: 'المزيد',
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  openWalletForm(context, book, wallet: wallet);
                case 'main':
                  _setMain(context);
                case 'archive':
                  _setStatus(context, WalletStatus.archived);
                case 'activate':
                  _setStatus(context, WalletStatus.active);
                case 'delete':
                  _delete(context);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('تعديل')),
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
              const PopupMenuItem(value: 'delete', child: Text('حذف')),
            ],
          ),
        ],
      ),
    );
  }
}
