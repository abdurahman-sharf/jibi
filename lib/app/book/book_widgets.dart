import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/models.dart';
import '../../features/book/domain/book_labels.dart';
import '../../shared/formatting/money_format.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import 'book_preferences_scope.dart';

export '../../features/book/domain/book_preferences.dart';
export '../../features/book/domain/book_labels.dart';
export 'book_preferences_scope.dart';

/// Colors and icons for the two sides. Colour is only a helper: every place
/// that uses it also shows the side as text and as an arrow/check icon.
extension BookSideStyle on BuildContext {
  Color sideColor(BalanceSide side) => switch (side) {
    BalanceSide.debit =>
      jibiIsDark ? const Color(0xFFFF9C93) : const Color(0xFFB3261E),
    BalanceSide.credit =>
      jibiIsDark ? const Color(0xFF7FD6B8) : JibiColors.deepGreen,
    BalanceSide.settled => jibiMuted,
  };
}

IconData sideIcon(BalanceSide side) => switch (side) {
  BalanceSide.debit => Icons.arrow_upward_rounded,
  BalanceSide.credit => Icons.arrow_downward_rounded,
  BalanceSide.settled => Icons.check_rounded,
};

BalanceSide sideOfEntry(EntryType type) =>
    type == EntryType.debit ? BalanceSide.debit : BalanceSide.credit;

/// Formats [minor] of the currency [code] with thousands separators.
String bookAmount(CurrencyRegistry currencies, String code, int minor) =>
    formatMinorGrouped(minor, currencies.byCode(code).fractionDigits);

String bookErrorMessage(Object error, [String fallback = 'تعذر إتمام العملية.']) =>
    error is AppException ? error.userMessage : fallback;

void showBookError(BuildContext context, Object error, [String? fallback]) =>
    showJibiMessage(context, bookErrorMessage(error, fallback ?? 'تعذر إتمام العملية.'));

/// A small pill: "مدين ↑", "دائن ↓" or "متعادل ✓".
class SidePill extends StatelessWidget {
  const SidePill({
    required this.side,
    super.key,
    this.labels,
    this.compact = false,
  });

  final BalanceSide side;

  /// The wording; null follows the settings.
  final BookLabels? labels;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = context.sideColor(side);
    final labels = this.labels ?? context.bookPrefs.labels;
    return Semantics(
      label: labels.side(side),
      excludeSemantics: true,
      // A custom word can be long: the pill never grows past this width, its
      // text scales down instead.
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: compact ? 92 : 132),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 2 : 4,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(compact ? 8 : 10),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  labels.side(side),
                  style: TextStyle(
                    color: color,
                    fontSize: compact ? 10.5 : 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(width: compact ? 2 : 4),
                Icon(sideIcon(side), size: compact ? 12 : 14, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An amount with its currency code, always laid out left-to-right so the
/// digits never reorder inside the Arabic page.
class BookAmountText extends StatelessWidget {
  const BookAmountText({
    required this.text,
    required this.currencyCode,
    super.key,
    this.color,
    this.size = 20,
    this.weight = FontWeight.w800,
    this.showCurrency = true,
    this.currencyFirst = true,
  });

  final String text;
  final String currencyCode;
  final Color? color;
  final double size;
  final FontWeight weight;
  final bool showCurrency;
  final bool currencyFirst;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.jibiInk;
    final number = Text(
      text,
      style: TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: tint,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final code = Text(
      currencyCode,
      style: TextStyle(
        fontSize: (size * 0.5).clamp(10, 15).toDouble(),
        fontWeight: FontWeight.w700,
        color: context.jibiMuted,
      ),
    );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          if (showCurrency && currencyFirst) ...[code, const SizedBox(width: 4)],
          Flexible(child: number),
          if (showCurrency && !currencyFirst) ...[const SizedBox(width: 4), code],
        ],
      ),
    );
  }
}

/// "50,000 YER مدين": one currency line of an account, as text.
String balanceLineText(
  BuildContext context,
  CurrencyRegistry currencies,
  AccountCurrencyTotals line,
) {
  final prefs = context.bookPrefs;
  final amount = prefs.balance(
    bookAmount(currencies, line.currencyCode, line.netMinor.abs()),
  );
  return '$amount ${line.currencyCode} ${prefs.labels.side(line.side)}';
}

/// What an account is worth right now: one row per currency it uses — the
/// amount, its currency and its side — and NEVER a single figure that adds
/// different currencies. An account with nothing yet says so.
class AccountBalanceLines extends StatelessWidget {
  const AccountBalanceLines({
    required this.currencies,
    required this.summary,
    super.key,
    this.size = 22,
    this.compact = false,
  });

  final CurrencyRegistry currencies;
  final AccountSummary summary;

  /// Font size of the amounts.
  final double size;

  /// Smaller pills, for dense lists.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final prefs = context.bookPrefs;
    if (summary.currencies.isEmpty) {
      return Text(
        'لا توجد أرصدة بعد',
        key: const Key('balance-lines-empty'),
        style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final line in summary.currencies)
          Padding(
            key: Key('balance-line-${line.currencyCode}'),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: BookAmountText(
                        text: prefs.balance(
                          bookAmount(
                            currencies,
                            line.currencyCode,
                            line.netMinor.abs(),
                          ),
                        ),
                        currencyCode: line.currencyCode,
                        size: size,
                        color: line.side == BalanceSide.settled
                            ? context.jibiInk
                            : context.sideColor(line.side),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SidePill(side: line.side, compact: compact),
              ],
            ),
          ),
      ],
    );
  }
}

/// Side filters of an account list, over all of the account's currencies: an
/// account counts as "debit" when ANY of its currencies is on the debit side,
/// "credit" likewise, and "settled" only when every currency is settled (or it
/// has none yet).
extension AccountSummarySides on AccountSummary {
  bool hasSide(BalanceSide side) => side == BalanceSide.settled
      ? currencies.every((line) => line.side == BalanceSide.settled)
      : currencies.any((line) => line.side == side);
}

/// A labelled figure in a soft tile (the three totals of a category).
class BookStatTile extends StatelessWidget {
  const BookStatTile({
    required this.label,
    required this.amount,
    required this.currencyCode,
    required this.color,
    super.key,
    this.icon,
    this.suffix,
  });

  final String label;
  final String amount;
  final String currencyCode;
  final Color color;
  final IconData? icon;

  /// Extra text after the amount, e.g. "مدين" on the net tile.
  final String? suffix;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
        alpha: context.jibiIsDark ? 0.5 : 0.55,
      ),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: BookAmountText(
            text: amount,
            currencyCode: currencyCode,
            size: 19,
            color: context.jibiInk,
            currencyFirst: false,
          ),
        ),
        if (suffix != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              suffix!,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
      ],
    ),
  );
}

/// Round avatar with the account's first letter on a tint picked from its name.
class BookAvatar extends StatelessWidget {
  const BookAvatar({required this.name, super.key, this.size = 46, this.icon});

  final String name;
  final double size;
  final IconData? icon;

  static const _tints = <Color>[
    Color(0xFF0F5747),
    Color(0xFF8A5A00),
    Color(0xFF2F5D8A),
    Color(0xFF7A3E7A),
    Color(0xFF9A3B3B),
    Color(0xFF3F6B3F),
  ];

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final tint = _tints[trimmed.isEmpty ? 0 : trimmed.runes.first % _tints.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tint.withValues(alpha: context.jibiIsDark ? 0.35 : 0.14),
      ),
      child: icon != null
          ? Icon(icon, color: tint, size: size * 0.5)
          : Text(
              trimmed.isEmpty ? '؟' : String.fromCharCode(trimmed.runes.first),
              style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w800,
                color: context.jibiIsDark ? Colors.white : tint,
              ),
            ),
    );
  }
}

/// Icons a category can use, keyed by the value stored in `book_categories`.
const Map<String, IconData> bookCategoryIcons = <String, IconData>{
  'folder': Icons.folder_outlined,
  'people': Icons.people_alt_outlined,
  'bank': Icons.account_balance_outlined,
  'cash': Icons.payments_outlined,
  'company': Icons.business_outlined,
  'receipt': Icons.receipt_long_outlined,
  'home': Icons.home_outlined,
  'cart': Icons.shopping_cart_outlined,
  'heart': Icons.favorite_border,
  'briefcase': Icons.work_outline,
  'car': Icons.directions_car_outlined,
  'school': Icons.school_outlined,
};

IconData bookCategoryIcon(String? key) =>
    bookCategoryIcons[key] ?? Icons.folder_outlined;

/// A white/adaptive rounded card used by the book screens.
class BookCard extends StatelessWidget {
  const BookCard({
    required this.child,
    super.key,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.dimmed = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
    return dimmed ? Opacity(opacity: 0.6, child: card) : card;
  }
}

/// Page padding shared by the list screens.
const EdgeInsets bookPagePadding = EdgeInsets.fromLTRB(16, 8, 16, 24);

String attachmentKindLabel(BookAttachmentKind kind) => switch (kind) {
  BookAttachmentKind.image => 'صورة',
  BookAttachmentKind.transferNotice => 'إشعار تحويل',
  BookAttachmentKind.receipt => 'إيصال',
  BookAttachmentKind.invoice => 'فاتورة',
  BookAttachmentKind.voucher => 'سند',
  BookAttachmentKind.pdf => 'ملف PDF',
  BookAttachmentKind.document => 'مستند',
};

/// The wallets as payment methods, in the order the user sees them: the main
/// wallet («نقدًا») first, then the others in their list order.
List<WalletSummary> paymentWalletOrder(Iterable<WalletSummary> wallets) => [
  for (final summary in wallets)
    if (summary.wallet.isMain) summary,
  for (final summary in wallets)
    if (!summary.wallet.isMain) summary,
];

String walletEffectLabel(WalletBalanceEffect effect) => switch (effect) {
  WalletBalanceEffect.increase => 'زيادة الرصيد',
  WalletBalanceEffect.decrease => 'نقص الرصيد',
};
