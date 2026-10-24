import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../book/book_widgets.dart';
import 'wallet_widgets.dart';

/// "تفاصيل الحركة": a sectioned bottom sheet with delete (soft, with undo).
/// Movements have no edit — a transfer is delete-and-recreate only, and a
/// deposit/withdrawal is small enough to just delete and re-enter.
Future<void> showWalletTransactionDetails(
  BuildContext context, {
  required BookServices book,
  required Wallet wallet,
  required String transactionId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useRootNavigator: true,
  useSafeArea: true,
  builder: (sheetContext) => _DetailsSheet(
    book: book,
    wallet: wallet,
    transactionId: transactionId,
    pageContext: context,
  ),
);

class _DetailsSheet extends StatefulWidget {
  const _DetailsSheet({
    required this.book,
    required this.wallet,
    required this.transactionId,
    required this.pageContext,
  });

  final BookServices book;
  final Wallet wallet;
  final String transactionId;

  /// The screen that opened the sheet; it outlives the sheet, so it is the
  /// context for follow-up messages.
  final BuildContext pageContext;

  @override
  State<_DetailsSheet> createState() => _DetailsSheetState();
}

class _DetailsSheetState extends State<_DetailsSheet> {
  late final Future<WalletTransaction?> _transaction = widget
      .book
      .walletTransactions
      .find(widget.transactionId);

  String _amount(int minor, String currencyCode) =>
      bookAmount(widget.book.currencies, currencyCode, minor.abs());

  Future<void> _delete(WalletTransaction transaction) async {
    final isTransfer = transaction.type == WalletTransactionType.transfer;
    final isExchange = transaction.type == WalletTransactionType.exchange;
    final confirmed = context.bookPrefs.confirmBeforeDelete
        ? await JibiConfirmationDialog.show(
            context,
            title: 'حذف الحركة',
            message: isTransfer
                ? 'سيؤدي حذف هذا التحويل إلى حذف طرفيه معاً وتغيير رصيد المحفظتين. '
                      'هل تريد المتابعة؟'
                : isExchange
                ? 'سيؤدي حذف عملية الصرف إلى حذف طرفيها معاً وتغيير رصيد العملتين. '
                      'هل تريد المتابعة؟'
                : 'سيؤدي حذف هذه الحركة إلى تغيير رصيد المحفظة. هل تريد المتابعة؟',
            confirmLabel: 'حذف',
            isDestructive: true,
          )
        : true;
    if (confirmed != true || !mounted) return;
    final page = widget.pageContext;
    final navigator = Navigator.of(context);
    try {
      await widget.book.walletTransactions.delete(transaction.id);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
      return;
    }
    navigator.pop();
    if (!page.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(page);
    messenger?.showSnackBar(
      SnackBar(
        content: const Text('تم حذف الحركة'),
        action: SnackBarAction(
          label: 'تراجع',
          onPressed: () async {
            try {
              await widget.book.walletTransactions.restore(transaction.id);
            } on Object catch (error) {
              if (page.mounted) showBookError(page, error);
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<WalletTransaction?>(
    future: _transaction,
    builder: (context, snapshot) {
      final transaction = snapshot.data;
      if (snapshot.connectionState != ConnectionState.done) {
        return const SizedBox(
          height: 220,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (transaction == null) {
        return const SizedBox(
          height: 220,
          child: Center(child: Text('الحركة غير موجودة.')),
        );
      }
      return _content(context, transaction);
    },
  );

  Widget _content(BuildContext context, WalletTransaction transaction) {
    final prefs = context.bookPrefs;
    final incoming = transaction.direction == WalletDirection.incoming;
    final color = incoming
        ? context.sideColor(BalanceSide.credit)
        : context.sideColor(BalanceSide.debit);
    final editable = widget.wallet.status != WalletStatus.archived;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'تفاصيل الحركة',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  transaction.number,
                  key: const Key('wtx-details-number'),
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    color: context.jibiMuted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              children: [
                _Row(label: 'المحفظة', value: widget.wallet.name),
                Row(
                  children: [
                    Text(
                      'النوع',
                      style: TextStyle(color: context.jibiMuted, fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    _DirectionPill(incoming: incoming, kind: transaction.type),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: BookAmountText(
                            key: const Key('wtx-details-amount'),
                            text: _amount(transaction.amountMinor, transaction.currencyCode),
                            currencyCode: transaction.currencyCode,
                            color: color,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            _Section(
              children: [
                _Row(
                  label: 'التاريخ',
                  value: prefs.date(transaction.date),
                  ltr: true,
                ),
                _Row(label: 'الوقت', value: transaction.time, ltr: true),
                _Row(
                  label: 'الرصيد بعد الحركة',
                  value:
                      '${prefs.balance(_amount(transaction.balanceAfter, transaction.currencyCode))} '
                      '${transaction.currencyCode}',
                  ltr: true,
                ),
              ],
            ),
            if (transaction.notes?.isNotEmpty ?? false) ...[
              const SizedBox(height: 12),
              _Section(
                children: [_Block(label: 'الملاحظات', value: transaction.notes!)],
              ),
            ],
            const SizedBox(height: 20),
            OutlinedButton.icon(
              key: const Key('wtx-details-delete'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: editable ? () => _delete(transaction) : null,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectionPill extends StatelessWidget {
  const _DirectionPill({required this.incoming, required this.kind});

  final bool incoming;
  final WalletTransactionType kind;

  @override
  Widget build(BuildContext context) {
    final color = incoming
        ? context.sideColor(BalanceSide.credit)
        : context.sideColor(BalanceSide.debit);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            walletMovementTypeLabel(kind),
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 4),
          Icon(
            incoming ? Icons.south_west : Icons.north_east,
            size: 14,
            color: color,
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
        alpha: context.jibiIsDark ? 0.5 : 0.55,
      ),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(height: 10),
          children[index],
        ],
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.ltr = false});

  final String label;
  final String value;
  final bool ltr;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(label, style: TextStyle(color: context.jibiMuted, fontSize: 13)),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          value,
          textAlign: TextAlign.end,
          textDirection: ltr ? TextDirection.ltr : null,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    ],
  );
}

class _Block extends StatelessWidget {
  const _Block({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(color: context.jibiMuted, fontSize: 13)),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );
}
