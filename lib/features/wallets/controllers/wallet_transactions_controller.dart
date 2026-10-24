import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../domain/wallet_balance.dart';
import '../domain/wallet_drafts.dart';

/// Rules for wallet movements (حركات المحفظة): deposits, withdrawals,
/// transfers between two wallets (same currency or crossing two), and
/// exchanges between two currencies inside one wallet — entered directly
/// against a wallet, or (in a later phase) through a book transaction.
///
/// Every write keeps the stored running balance of the (wallet, currency)
/// pair(s) it touches in step, in the same atomic unit of work. Deleting is
/// soft. Numbers (`WTX-000001`) are never reused. A transfer or an exchange
/// is not editable: delete it and record a new one.
final class WalletTransactionsController {
  WalletTransactionsController({
    required BookRepository repository,
    String Function()? newId,
    DateTime Function()? clock,
  }) : _repository = repository,
       _newId = newId ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final BookRepository _repository;
  final String Function() _newId;
  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  Future<WalletTransaction?> find(String id) => _repository.walletTransaction(id);

  /// One page of a wallet's movements. Pass [after] (the last key of the
  /// previous page) to continue. [currencyCode] narrows to one of the
  /// wallet's currencies; null pages across all of them.
  Future<WalletTransactionPage> page(
    String walletId, {
    String? currencyCode,
    WalletTransactionFilter filter = WalletTransactionFilter.none,
    WalletOrderKey? after,
    int limit = 50,
    bool newestFirst = true,
  }) => _repository.walletTransactionPage(
    walletId,
    currencyCode: currencyCode,
    filter: filter,
    after: after,
    limit: limit,
    newestFirst: newestFirst,
  );

  Stream<void> get changes => _repository.changes;

  Future<WalletTransaction> deposit(WalletDepositDraft draft) => _record(
    walletId: draft.walletId,
    currencyCode: draft.currencyCode,
    type: WalletTransactionType.deposit,
    direction: WalletDirection.incoming,
    amountMinor: draft.amountMinor,
    date: draft.date,
    time: draft.time,
    notes: draft.notes,
    auditAction: 'deposited',
  );

  Future<WalletTransaction> withdraw(WalletWithdrawalDraft draft) => _record(
    walletId: draft.walletId,
    currencyCode: draft.currencyCode,
    type: WalletTransactionType.withdrawal,
    direction: WalletDirection.outgoing,
    amountMinor: draft.amountMinor,
    date: draft.date,
    time: draft.time,
    notes: draft.notes,
    auditAction: 'withdrawn',
  );

  Future<WalletTransaction> _record({
    required String walletId,
    String? currencyCode,
    required WalletTransactionType type,
    required WalletDirection direction,
    required int amountMinor,
    required String date,
    required String time,
    String? notes,
    required String auditAction,
  }) async {
    final now = _now;
    return _repository.write((writer) async {
      final wallet = await _requireActive(writer, walletId);
      final code = await _resolveCurrency(writer, wallet.id, currencyCode);
      final balance = await _ensureBalance(writer, wallet.id, code, now);
      final transaction = WalletTransaction(
        id: _newId(),
        number: await writer.nextWalletTransactionNumber(),
        walletId: wallet.id,
        currencyCode: code,
        type: type,
        direction: direction,
        amountMinor: amountMinor,
        date: date,
        time: time,
        notes: optionalWalletText(notes),
        createdAt: now,
        updatedAt: now,
      );
      await writer.putWalletTransaction(transaction);
      await WalletBalanceEngine.recomputeWalletCurrency(
        writer,
        balance,
        from: WalletOrderKey.of(transaction),
      );
      await writer.audit(
        'wallet',
        wallet.id,
        auditAction,
        details: '${transaction.number} $amountMinor $code',
      );
      return (await writer.walletTransaction(transaction.id))!;
    });
  }

  /// Moves money from [WalletTransferDraft.fromWalletId] to
  /// [WalletTransferDraft.toWalletId]: two rows sharing one leg group, each
  /// wallet's own currency recomputed, in one write. The two currencies may
  /// differ — [WalletTransferDraft.receivedMinor] then states what arrived,
  /// since no rate is assumed or stored.
  Future<void> transfer(WalletTransferDraft draft) async {
    if (draft.fromWalletId == draft.toWalletId) {
      throw const ValidationException(
        code: 'transfer_same_wallet',
        userMessage: 'اختر محفظتين مختلفتين للتحويل.',
      );
    }
    final now = _now;
    await _repository.write((writer) async {
      final from = await _requireActive(writer, draft.fromWalletId);
      final to = await _requireActive(writer, draft.toWalletId);
      final fromCode = await _resolveCurrency(
        writer,
        from.id,
        draft.fromCurrencyCode,
      );
      final toCode = await _resolveCurrency(writer, to.id, draft.toCurrencyCode);
      final receivedMinor = draft.receivedMinor ?? draft.amountMinor;
      if (receivedMinor <= 0) {
        throw const ValidationException(
          code: 'invalid_amount',
          userMessage: 'أدخل مبلغاً أكبر من صفر.',
        );
      }
      if (fromCode == toCode && receivedMinor != draft.amountMinor) {
        throw const ConflictException(
          code: 'transfer_amount_mismatch',
          userMessage:
              'المبلغ المرسل والمستلم يجب أن يتطابقا عند اتفاق العملة.',
        );
      }
      final fromBalance = await _ensureBalance(writer, from.id, fromCode, now);
      final toBalance = await _ensureBalance(writer, to.id, toCode, now);
      final groupId = _newId();
      final outgoing = WalletTransaction(
        id: _newId(),
        number: await writer.nextWalletTransactionNumber(),
        walletId: from.id,
        currencyCode: fromCode,
        type: WalletTransactionType.transfer,
        direction: WalletDirection.outgoing,
        amountMinor: draft.amountMinor,
        legGroupId: groupId,
        date: draft.date,
        time: draft.time,
        notes: optionalWalletText(draft.notes),
        createdAt: now,
        updatedAt: now,
      );
      final incoming = WalletTransaction(
        id: _newId(),
        number: await writer.nextWalletTransactionNumber(),
        walletId: to.id,
        currencyCode: toCode,
        type: WalletTransactionType.transfer,
        direction: WalletDirection.incoming,
        amountMinor: receivedMinor,
        legGroupId: groupId,
        date: draft.date,
        time: draft.time,
        notes: optionalWalletText(draft.notes),
        createdAt: now,
        updatedAt: now,
      );
      await writer.putWalletTransaction(outgoing);
      await writer.putWalletTransaction(incoming);
      await WalletBalanceEngine.recomputeWalletCurrency(
        writer,
        fromBalance,
        from: WalletOrderKey.of(outgoing),
      );
      await WalletBalanceEngine.recomputeWalletCurrency(
        writer,
        toBalance,
        from: WalletOrderKey.of(incoming),
      );
      await writer.audit(
        'wallet',
        from.id,
        'transferred_out',
        details: '${outgoing.number} ${draft.amountMinor} $fromCode -> ${to.name}',
      );
      await writer.audit(
        'wallet',
        to.id,
        'transferred_in',
        details: '${incoming.number} $receivedMinor $toCode <- ${from.name}',
      );
    });
  }

  /// Converts [WalletExchangeDraft.soldMinor] of [WalletExchangeDraft.fromCurrencyCode]
  /// into [WalletExchangeDraft.boughtMinor] of [WalletExchangeDraft.toCurrencyCode],
  /// inside the same wallet: two rows sharing one leg group, each currency's
  /// balance recomputed independently, in one write.
  Future<void> exchange(WalletExchangeDraft draft) async {
    final fromCode = draft.fromCurrencyCode.toUpperCase();
    final toCode = draft.toCurrencyCode.toUpperCase();
    if (fromCode == toCode) {
      throw const ValidationException(
        code: 'exchange_same_currency',
        userMessage: 'اختر عملتين مختلفتين للصرف.',
      );
    }
    final now = _now;
    await _repository.write((writer) async {
      final wallet = await _requireActive(writer, draft.walletId);
      final soldBalance = await _ensureBalance(writer, wallet.id, fromCode, now);
      final boughtBalance = await _ensureBalance(writer, wallet.id, toCode, now);
      final groupId = _newId();
      final sold = WalletTransaction(
        id: _newId(),
        number: await writer.nextWalletTransactionNumber(),
        walletId: wallet.id,
        currencyCode: fromCode,
        type: WalletTransactionType.exchange,
        direction: WalletDirection.outgoing,
        amountMinor: draft.soldMinor,
        legGroupId: groupId,
        date: draft.date,
        time: draft.time,
        notes: optionalWalletText(draft.notes),
        createdAt: now,
        updatedAt: now,
      );
      final bought = WalletTransaction(
        id: _newId(),
        number: await writer.nextWalletTransactionNumber(),
        walletId: wallet.id,
        currencyCode: toCode,
        type: WalletTransactionType.exchange,
        direction: WalletDirection.incoming,
        amountMinor: draft.boughtMinor,
        legGroupId: groupId,
        date: draft.date,
        time: draft.time,
        notes: optionalWalletText(draft.notes),
        createdAt: now,
        updatedAt: now,
      );
      await writer.putWalletTransaction(sold);
      await writer.putWalletTransaction(bought);
      await WalletBalanceEngine.recomputeWalletCurrency(
        writer,
        soldBalance,
        from: WalletOrderKey.of(sold),
      );
      await WalletBalanceEngine.recomputeWalletCurrency(
        writer,
        boughtBalance,
        from: WalletOrderKey.of(bought),
      );
      await writer.audit(
        'wallet',
        wallet.id,
        'exchanged_out',
        details: '${sold.number} ${draft.soldMinor} $fromCode',
      );
      await writer.audit(
        'wallet',
        wallet.id,
        'exchanged_in',
        details: '${bought.number} ${draft.boughtMinor} $toCode',
      );
    });
  }

  /// Soft delete: the row stays (for undo and the audit trail) but no longer
  /// counts in any balance. Deleting one leg of a transfer or an exchange
  /// deletes its pair.
  Future<void> delete(String id) async {
    final now = _now;
    await _repository.write((writer) async {
      final current = await _requireLive(writer, id);
      final legs = current.legGroupId == null
          ? [current]
          : await writer.walletTransactionsInLegGroup(current.legGroupId!);
      for (final leg in legs) {
        await _requireActive(writer, leg.walletId);
        await writer.putWalletTransaction(
          leg.copyWith(deletedAt: () => now, updatedAt: now),
        );
        await _recomputeLeg(writer, leg);
      }
      await writer.audit(
        'wallet',
        current.walletId,
        'movement_deleted',
        details: '${current.number} ${current.amountMinor} ${current.currencyCode}',
      );
    });
  }

  /// Undoes [delete]. Restoring one leg of a transfer or an exchange restores
  /// its pair.
  Future<void> restore(String id) async {
    final now = _now;
    await _repository.write((writer) async {
      final current = await writer.walletTransaction(id);
      if (current == null) {
        throw const NotFoundException(
          code: 'wallet_transaction_not_found',
          userMessage: 'الحركة المطلوبة غير موجودة.',
        );
      }
      if (!current.isDeleted) return;
      final legs = current.legGroupId == null
          ? [current]
          : await writer.walletTransactionsInLegGroup(current.legGroupId!);
      for (final leg in legs) {
        if (!leg.isDeleted) continue;
        await _requireActive(writer, leg.walletId);
        await writer.putWalletTransaction(
          leg.copyWith(deletedAt: () => null, updatedAt: now),
        );
        await _recomputeLeg(writer, leg);
      }
      await writer.audit('wallet', current.walletId, 'movement_restored');
    });
  }

  /// Recomputes the running balance of [leg]'s own (wallet, currency), from
  /// its position onward.
  Future<void> _recomputeLeg(BookWriter writer, WalletTransaction leg) async {
    final balance = await writer.walletBalance(leg.walletId, leg.currencyCode);
    if (balance == null) return;
    await WalletBalanceEngine.recomputeWalletCurrency(
      writer,
      balance,
      from: WalletOrderKey.of(leg),
    );
  }

  /// Explicit currency, else the wallet's only currency, else
  /// `wallet_currency_required`: a wallet holding several currencies needs
  /// one stated for every new movement.
  Future<String> _resolveCurrency(
    BookWriter writer,
    String walletId,
    String? explicit,
  ) async {
    if (explicit != null) return explicit.toUpperCase();
    final balances = await writer.walletBalances(walletId);
    if (balances.length == 1) return balances.single.currencyCode;
    throw const ValidationException(
      code: 'wallet_currency_required',
      userMessage: 'حدّد عملة الحركة.',
    );
  }

  /// The (wallet, currency) balance row, creating it at opening zero if the
  /// wallet does not hold this currency yet.
  Future<WalletBalance> _ensureBalance(
    BookWriter writer,
    String walletId,
    String currencyCode,
    DateTime now,
  ) async {
    final existing = await writer.walletBalance(walletId, currencyCode);
    if (existing != null) return existing;
    final created = WalletBalance(
      walletId: walletId,
      currencyCode: currencyCode,
      createdAt: now,
      updatedAt: now,
    );
    await writer.putWalletBalance(created);
    return created;
  }

  static Future<Wallet> _requireActive(BookWriter writer, String id) async {
    final wallet = await writer.wallet(id);
    if (wallet == null) {
      throw const NotFoundException(
        code: 'wallet_not_found',
        userMessage: 'المحفظة المطلوبة غير موجودة.',
      );
    }
    if (wallet.status == WalletStatus.archived) {
      throw const ConflictException(
        code: 'wallet_archived',
        userMessage: 'المحفظة مؤرشفة. أعد تفعيلها لتسجيل حركات جديدة.',
      );
    }
    return wallet;
  }

  static Future<WalletTransaction> _requireLive(
    BookWriter writer,
    String id,
  ) async {
    final transaction = await writer.walletTransaction(id);
    if (transaction == null || transaction.isDeleted) {
      throw const NotFoundException(
        code: 'wallet_transaction_not_found',
        userMessage: 'الحركة المطلوبة غير موجودة.',
      );
    }
    return transaction;
  }
}
