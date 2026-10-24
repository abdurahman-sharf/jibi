import '../../../core/errors/app_exception.dart';
import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../../wallets/domain/wallet_balance.dart';

/// Creates, updates or removes the `linked` wallet movement for
/// [transaction] so it matches its current [BookTransaction.walletId] /
/// [BookTransaction.walletEffect], and recomputes the balance of every
/// wallet touched. Call after `writer.putTransaction` has saved the
/// transaction itself.
///
/// The linked movement is always in the TRANSACTION's currency
/// ([BookTransaction.currencyCode]) — never the account's, which has none — so
/// a SAR transaction paid from a wallet moves that wallet's SAR balance only.
///
/// A wallet can only be paid through in a currency it ALREADY holds: linking
/// never creates a wallet's balance in a new currency as a side effect (that
/// would put a currency into a wallet by mistake). Adding a currency to a
/// wallet is an explicit action on the wallet's own screen; until then the
/// attempt is refused with `wallet_currency_unsupported`.
///
/// A change of wallet, of direction or of currency is done as
/// detach-then-reattach (a [WalletTransaction]'s `type`/`direction`/currency
/// are fixed once created): the old movement is removed and the balance of the
/// (wallet, old currency) it sat on is recomputed, then a fresh movement is
/// created in the new (wallet, currency). Only an amount/date/time change on the
/// *same* wallet, direction and currency updates the existing linked row in
/// place (its balance row exists already, so nothing is checked or created).
/// All of it runs inside the caller's write, so the account side and the wallet
/// side succeed or fail together.
Future<void> syncWalletLink(
  BookWriter writer, {
  required BookTransaction transaction,
  required String Function() newId,
  required DateTime now,
}) async {
  final existing = await writer.walletTransactionForBookTransaction(
    transaction.id,
  );
  final walletId = transaction.walletId;
  final direction = switch (transaction.walletEffect) {
    WalletBalanceEffect.increase => WalletDirection.incoming,
    WalletBalanceEffect.decrease => WalletDirection.outgoing,
    null => null,
  };

  final sameLink =
      existing != null &&
      !existing.isDeleted &&
      walletId != null &&
      existing.walletId == walletId &&
      existing.direction == direction &&
      existing.currencyCode == transaction.currencyCode;

  if (sameLink) {
    if (existing.amountMinor == transaction.amountMinor &&
        existing.date == transaction.date &&
        existing.time == transaction.time) {
      return;
    }
    final balance = await _requireBalance(writer, walletId, existing.currencyCode);
    final oldKey = WalletOrderKey.of(existing);
    final updated = existing.copyWith(
      amountMinor: transaction.amountMinor,
      date: transaction.date,
      time: transaction.time,
      updatedAt: now,
    );
    await writer.putWalletTransaction(updated);
    final newKey = WalletOrderKey.of(updated);
    await WalletBalanceEngine.recomputeWalletCurrency(
      writer,
      balance,
      from: oldKey.compareTo(newKey) <= 0 ? oldKey : newKey,
    );
    return;
  }

  // Detach the old link (if any) and attach a new one (if requested). A
  // full rebuild is used for the affected (wallet, currency) pair(s) rather
  // than a precise `from` key, since the old and new positions can differ
  // arbitrarily.
  (String, String)? oldTarget;
  if (existing != null) {
    oldTarget = (existing.walletId, existing.currencyCode);
    await writer.deleteWalletTransactionHard(existing.id);
  }
  (String, String)? newTarget;
  if (walletId != null && direction != null) {
    final wallet = await _requireLinkableWallet(writer, walletId);
    final code = transaction.currencyCode;
    await _requireHeldCurrency(writer, wallet, code);
    final linked = WalletTransaction(
      id: newId(),
      number: await writer.nextWalletTransactionNumber(),
      walletId: wallet.id,
      currencyCode: code,
      type: WalletTransactionType.linked,
      direction: direction,
      amountMinor: transaction.amountMinor,
      linkedBookTransactionId: transaction.id,
      date: transaction.date,
      time: transaction.time,
      createdAt: now,
      updatedAt: now,
    );
    await writer.putWalletTransaction(linked);
    newTarget = (wallet.id, code);
  }

  for (final target in <(String, String)>{?oldTarget, ?newTarget}) {
    final balance = await writer.walletBalance(target.$1, target.$2);
    if (balance != null) {
      await WalletBalanceEngine.recomputeWalletCurrency(writer, balance);
    }
  }
}

Future<WalletBalance> _requireBalance(
  BookWriter writer,
  String walletId,
  String currencyCode,
) async {
  final balance = await writer.walletBalance(walletId, currencyCode);
  if (balance == null) {
    throw const NotFoundException(
      code: 'wallet_balance_not_found',
      userMessage: 'رصيد المحفظة المطلوب غير موجود.',
    );
  }
  return balance;
}

/// A wallet may only be paid through in a currency it holds. Nothing is
/// created here: a wallet gains a currency only when the user adds it on the
/// wallet's own screen.
Future<void> _requireHeldCurrency(
  BookWriter writer,
  Wallet wallet,
  String currencyCode,
) async {
  if (await writer.walletBalance(wallet.id, currencyCode) != null) return;
  throw ValidationException(
    code: 'wallet_currency_unsupported',
    userMessage:
        'المحفظة «${wallet.paymentLabel}» لا تحمل عملة $currencyCode. أضف العملة '
        'إلى المحفظة من شاشتها أولاً، أو اختر وسيلة دفع أخرى.',
  );
}

/// Soft-deletes the linked wallet movement of [transaction] (mirroring the
/// transaction's own soft delete) and recomputes its (wallet, currency).
Future<void> softDeleteWalletLink(
  BookWriter writer, {
  required String bookTransactionId,
  required DateTime now,
}) async {
  final link = await writer.walletTransactionForBookTransaction(
    bookTransactionId,
  );
  if (link == null || link.isDeleted) return;
  final balance = await writer.walletBalance(link.walletId, link.currencyCode);
  await writer.putWalletTransaction(
    link.copyWith(deletedAt: () => now, updatedAt: now),
  );
  if (balance != null) {
    await WalletBalanceEngine.recomputeWalletCurrency(
      writer,
      balance,
      from: WalletOrderKey.of(link),
    );
  }
}

/// Undoes [softDeleteWalletLink].
Future<void> restoreWalletLink(
  BookWriter writer, {
  required String bookTransactionId,
  required DateTime now,
}) async {
  final link = await writer.walletTransactionForBookTransaction(
    bookTransactionId,
  );
  if (link == null || !link.isDeleted) return;
  final balance = await writer.walletBalance(link.walletId, link.currencyCode);
  await writer.putWalletTransaction(
    link.copyWith(deletedAt: () => null, updatedAt: now),
  );
  if (balance != null) {
    await WalletBalanceEngine.recomputeWalletCurrency(
      writer,
      balance,
      from: WalletOrderKey.of(link),
    );
  }
}

Future<Wallet> _requireWallet(BookWriter writer, String id) async {
  final wallet = await writer.wallet(id);
  if (wallet == null) {
    throw const NotFoundException(
      code: 'wallet_not_found',
      userMessage: 'المحفظة المطلوبة غير موجودة.',
    );
  }
  return wallet;
}

/// Like [_requireWallet], but only for establishing a brand-new link: the
/// wallet must also be active. The currency check is separate
/// ([_requireHeldCurrency]).
Future<Wallet> _requireLinkableWallet(BookWriter writer, String id) async {
  final wallet = await _requireWallet(writer, id);
  if (wallet.status == WalletStatus.archived) {
    throw const ConflictException(
      code: 'wallet_archived',
      userMessage: 'المحفظة مؤرشفة. أعد تفعيلها لربطها بعملية جديدة.',
    );
  }
  return wallet;
}
