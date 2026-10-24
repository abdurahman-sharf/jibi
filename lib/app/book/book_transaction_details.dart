import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../core/storage/secure_file_storage.dart';
import '../../core/storage/text_sharing.dart';
import '../../features/book/book.dart';
import '../../features/book/domain/book_share_text.dart';
import '../../shared/widgets/external_activity_scope.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../document_preview.dart';
import 'book_transaction_form.dart';
import 'book_widgets.dart';

/// "تفاصيل العملية": a sectioned bottom sheet with edit, share and delete.
Future<void> showBookTransactionDetails(
  BuildContext context, {
  required BookServices book,
  required BookAccount account,
  required String transactionId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useRootNavigator: true,
  useSafeArea: true,
  builder: (sheetContext) => _DetailsSheet(
    book: book,
    account: account,
    transactionId: transactionId,
    pageContext: context,
  ),
);

class _DetailsSheet extends StatefulWidget {
  const _DetailsSheet({
    required this.book,
    required this.account,
    required this.transactionId,
    required this.pageContext,
  });

  final BookServices book;
  final BookAccount account;
  final String transactionId;

  /// The screen that opened the sheet; it outlives the sheet, so it is the
  /// context for follow-up screens and messages.
  final BuildContext pageContext;

  @override
  State<_DetailsSheet> createState() => _DetailsSheetState();
}

class _DetailsSheetState extends State<_DetailsSheet> {
  late final Future<BookTransaction?> _transaction = widget.book.transactions.find(
    widget.transactionId,
  );

  final Map<String, Future<Wallet?>> _walletCache = {};

  Future<Wallet?> _walletFor(String id) =>
      _walletCache.putIfAbsent(id, () => widget.book.wallets.find(id));

  /// The payment method as the user sees it: «نقدًا» for the main wallet, the
  /// wallet's own name otherwise; null for a transaction that has none.
  Future<String?> _paymentLabelOf(BookTransaction transaction) async {
    final id = transaction.walletId;
    if (id == null) return null;
    return (await _walletFor(id))?.paymentLabel;
  }

  /// [minor] of [currencyCode] with its own decimals — the currency belongs to
  /// the transaction, the account has none.
  String _amount(int minor, String currencyCode) =>
      bookAmount(widget.book.currencies, currencyCode, minor.abs());

  Future<void> _edit(BookTransaction transaction) async {
    final navigator = Navigator.of(context);
    final page = widget.pageContext;
    navigator.pop();
    if (page.mounted) {
      await openTransactionForm(
        page,
        widget.book,
        account: widget.account,
        transaction: transaction,
      );
    }
  }

  /// Decrypts the attachment to a temporary file, shows it, and always
  /// removes the plaintext afterwards.
  Future<void> _preview(BookAttachment attachment) async {
    final attachments = widget.book.attachments;
    if (attachments == null) return;
    final isPdf = attachment.mimeType == 'application/pdf';
    if (!attachment.isImage && !isPdf) {
      showJibiMessage(context, 'لا يمكن معاينة هذا النوع من الملفات.');
      return;
    }
    TemporaryFileHandle? handle;
    try {
      handle = await attachments.open(attachment);
      if (!mounted) return;
      final file = handle.file;
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => DocumentPreviewPage(file: file, isPdf: isPdf),
        ),
      );
    } on Object catch (error) {
      if (mounted) showBookError(context, error, 'تعذر فتح المرفق.');
    } finally {
      await handle?.delete();
    }
  }

  Future<void> _share(BookTransaction transaction) async {
    final labels = context.bookPrefs.labels;
    final balanceSide = balanceSideOf(transaction.balanceAfter);
    final paymentLabel = await _paymentLabelOf(transaction);
    if (!mounted) return;
    final text = bookTransactionShareText(
      accountName: widget.account.name,
      transaction: transaction,
      currencyCode: transaction.currencyCode,
      typeLabel: labels.entry(transaction.type),
      amountText: _amount(transaction.amountMinor, transaction.currencyCode),
      balanceText: _amount(transaction.balanceAfter, transaction.currencyCode),
      balanceSideLabel: labels.side(balanceSide),
      paymentLabel: paymentLabel,
    );
    try {
      await ExternalActivityScope.of(context)(
        () => const AndroidTextSharing().share(
          text,
          chooserTitle: 'مشاركة العملية',
        ),
        holdUntilResumed: true,
      );
    } on Object {
      if (mounted) showJibiMessage(context, 'تعذرت مشاركة العملية.');
    }
  }

  Future<void> _delete(BookTransaction transaction) async {
    // With "confirm before delete" off the deletion happens at once; the
    // message that follows still offers to undo it.
    final confirmed = context.bookPrefs.confirmBeforeDelete
        ? await JibiConfirmationDialog.show(
            context,
            title: 'حذف العملية',
            message:
                'سيؤدي حذف هذه العملية إلى تغيير رصيد الحساب والعمليات التالية. '
                'هل تريد المتابعة؟',
            confirmLabel: 'حذف',
            isDestructive: true,
          )
        : true;
    if (confirmed != true || !mounted) return;
    final page = widget.pageContext;
    final navigator = Navigator.of(context);
    try {
      await widget.book.transactions.delete(transaction.id);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
      return;
    }
    navigator.pop();
    if (!page.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(page);
    messenger?.showSnackBar(
      SnackBar(
        content: const Text('تم حذف العملية'),
        action: SnackBarAction(
          label: 'تراجع',
          onPressed: () async {
            try {
              await widget.book.transactions.restore(transaction.id);
            } on Object catch (error) {
              if (page.mounted) showBookError(page, error);
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<BookTransaction?>(
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
          child: Center(child: Text('العملية غير موجودة.')),
        );
      }
      return _content(context, transaction);
    },
  );

  Widget _content(BuildContext context, BookTransaction transaction) {
    final prefs = context.bookPrefs;
    final labels = prefs.labels;
    final side = sideOfEntry(transaction.type);
    final color = context.sideColor(side);
    final balanceSide = balanceSideOf(transaction.balanceAfter);
    final editable = widget.account.status != BookAccountStatus.archived;
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
                    'تفاصيل العملية',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  transaction.number,
                  key: const Key('details-number'),
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
                _Row(label: 'الحساب', value: widget.account.name),
                Row(
                  children: [
                    Text(
                      'المبلغ',
                      style: TextStyle(color: context.jibiMuted, fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    SidePill(side: side, labels: labels),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: BookAmountText(
                            key: const Key('details-amount'),
                            text: _amount(
                              transaction.amountMinor,
                              transaction.currencyCode,
                            ),
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
                  label: 'الرصيد بعد العملية',
                  value:
                      '${prefs.balance(_amount(transaction.balanceAfter, transaction.currencyCode))} '
                      '${transaction.currencyCode} · '
                      '${labels.side(balanceSide)}',
                  ltr: true,
                ),
              ],
            ),
            if (transaction.walletId != null) ...[
              const SizedBox(height: 12),
              KeyedSubtree(
                key: const Key('details-payment-info'),
                child: _Section(
                  children: [
                    FutureBuilder<Wallet?>(
                      key: const Key('details-wallet'),
                      future: _walletFor(transaction.walletId!),
                      builder: (context, snapshot) => _Row(
                        label: 'وسيلة الدفع',
                        value: switch (snapshot.data) {
                          final wallet? =>
                            '${wallet.paymentLabel} · '
                                '${walletEffectLabel(transaction.walletEffect!)}',
                          null => '…',
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (transaction.details?.isNotEmpty ?? false) ...[
              const SizedBox(height: 12),
              _Section(
                children: [
                  _Block(label: 'التفاصيل', value: transaction.details!),
                ],
              ),
            ],
            if (transaction.notes?.isNotEmpty ?? false) ...[
              const SizedBox(height: 12),
              _Section(
                children: [_Block(label: 'الملاحظات', value: transaction.notes!)],
              ),
            ],
            if (transaction.attachments.isNotEmpty) ...[
              const SizedBox(height: 12),
              _Section(
                children: [
                  Text(
                    'المرفقات (${transaction.attachments.length})',
                    style: TextStyle(color: context.jibiMuted, fontSize: 13),
                  ),
                  for (final attachment in transaction.attachments)
                    InkWell(
                      key: Key('attachment-${attachment.id}'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _preview(attachment),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Icon(
                              attachment.isImage
                                  ? Icons.image_outlined
                                  : Icons.attach_file,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                attachment.fileName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              attachmentKindLabel(attachment.kind),
                              style: TextStyle(
                                color: context.jibiMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('details-edit'),
                    onPressed: editable ? () => _edit(transaction) : null,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('تعديل'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('details-share'),
                    onPressed: () => _share(transaction),
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('مشاركة'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('details-delete'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: editable ? () => _delete(transaction) : null,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('حذف'),
                  ),
                ),
              ],
            ),
          ],
        ),
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
