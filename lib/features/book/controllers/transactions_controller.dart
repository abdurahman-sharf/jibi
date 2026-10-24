import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../domain/book_balance.dart';
import '../domain/book_drafts.dart';
import '../domain/book_wallet_link.dart';

/// Rules for transactions (العمليات): every write keeps the stored running
/// balance of the account IN THE TRANSACTION'S CURRENCY in step, and the wallet
/// movement of its payment method, all in the same atomic unit of work. An
/// account can use several currencies; each one is a separate running balance
/// and no write ever touches another currency's rows.
///
/// Deleting is soft. Numbers (`TX-000001`) are never reused.
final class TransactionsController {
  TransactionsController({
    required BookRepository repository,
    required CurrencyRegistry currencies,
    String Function()? newId,
    DateTime Function()? clock,
  }) : _repository = repository,
       _currencies = currencies,
       _newId = newId ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final BookRepository _repository;
  final CurrencyRegistry _currencies;
  final String Function() _newId;
  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  Future<BookTransaction?> find(String id) => _repository.transaction(id);

  /// One page of an account's transactions. Pass [after] (the last key of the
  /// previous page) to continue.
  Future<TransactionPage> page(
    String accountId, {
    BookTransactionFilter filter = BookTransactionFilter.none,
    BookOrderKey? after,
    int limit = 50,
    bool newestFirst = true,
  }) => _repository.transactionPage(
    accountId,
    filter: filter,
    after: after,
    limit: limit,
    newestFirst: newestFirst,
  );

  /// Count and debit/credit sums of the transactions matching [filter], one
  /// entry per currency (never added together).
  Future<List<AccountCurrencyTotals>> matchTotals(
    String accountId, {
    BookTransactionFilter filter = BookTransactionFilter.none,
  }) => _repository.filteredTotals(accountId, filter: filter);

  Stream<void> get changes => _repository.changes;

  /// Creates a transaction. It must name its payment method (a wallet — the
  /// main wallet is «نقدًا»): a transaction is never created without one.
  Future<BookTransaction> create(BookTransactionDraft draft) async {
    final now = _now;
    if (draft.walletId == null) throw _paymentRequired;
    final currency = _requireActiveCurrency(draft.currencyCode);
    return _repository.write((writer) async {
      final account = await _requireAccount(writer, draft.accountId);
      if (!account.acceptsTransactions) {
        throw const ConflictException(
          code: 'account_not_active',
          userMessage: 'الحساب متوقف أو مؤرشف ولا يقبل عمليات جديدة.',
        );
      }
      // The first transaction in a currency declares that the account uses
      // it (an opening balance of zero).
      await BookBalanceEngine.ensureBalance(
        writer,
        account.id,
        currency.code,
        now,
      );
      final transaction = BookTransaction(
        id: _newId(),
        number: await writer.nextTransactionNumber(),
        accountId: account.id,
        currencyCode: currency.code,
        type: draft.type,
        amountMinor: draft.amountMinor,
        date: draft.date,
        time: draft.time,
        details: optionalBookText(draft.details),
        notes: optionalBookText(draft.notes),
        createdAt: now,
        updatedAt: now,
        walletId: draft.walletId,
        walletEffect: draft.walletEffect ?? WalletBalanceEffect.forEntry(draft.type),
      );
      await writer.putTransaction(transaction);
      await BookBalanceEngine.recomputeCurrency(
        writer,
        account.id,
        transaction.currencyCode,
        from: BookOrderKey.of(transaction),
      );
      await syncWalletLink(
        writer,
        transaction: transaction,
        newId: _newId,
        now: now,
      );
      await writer.audit(
        'transaction',
        transaction.id,
        'created',
        details:
            '${transaction.number} ${transaction.type.dbValue} '
            '${transaction.amountMinor} ${transaction.currencyCode}',
      );
      return (await writer.transaction(transaction.id))!;
    });
  }

  /// Edits a transaction. A changed date, time, type or amount moves it in the
  /// account timeline and every later balance of its currency is recomputed. A
  /// changed currency moves the transaction between two independent running
  /// balances: both are recomputed, and the wallet movement of its payment
  /// method is reversed in the old currency and applied in the new one.
  Future<BookTransaction> update(String id, BookTransactionDraft draft) async {
    final now = _now;
    final code = draft.currencyCode.toUpperCase();
    return _repository.write((writer) async {
      final current = await _requireLive(writer, id);
      if (draft.accountId != current.accountId) {
        throw const ValidationException(
          code: 'transaction_account_locked',
          userMessage: 'لا يمكن نقل العملية إلى حساب آخر.',
        );
      }
      final account = await _requireAccount(writer, current.accountId);
      _requireEditable(account);
      // A row from before wallets were linked may stay unlinked, but a linked
      // one can never lose its payment method.
      if (draft.walletId == null && current.walletId != null) {
        throw _paymentRequired;
      }
      // A currency it already had may stay even if it was switched off since;
      // moving to another one needs an active currency.
      final currencyChanged = code != current.currencyCode;
      final currency = currencyChanged
          ? _requireActiveCurrency(code)
          : _currencies.byCode(code);
      if (currencyChanged) {
        await BookBalanceEngine.ensureBalance(
          writer,
          account.id,
          currency.code,
          now,
        );
      }
      final updated = current.copyWith(
        currencyCode: currency.code,
        type: draft.type,
        amountMinor: draft.amountMinor,
        date: draft.date,
        time: draft.time,
        details: () => optionalBookText(draft.details),
        notes: () => optionalBookText(draft.notes),
        walletId: () => draft.walletId,
        walletEffect: () => draft.walletId == null
            ? null
            : draft.walletEffect ?? WalletBalanceEffect.forEntry(draft.type),
        updatedAt: now,
      );
      await writer.putTransaction(updated);
      final oldKey = BookOrderKey.of(current);
      final newKey = BookOrderKey.of(updated);
      if (currencyChanged) {
        // Two independent running balances: the old currency lost this row,
        // the new one gained it. Neither touches any other currency.
        await BookBalanceEngine.recomputeCurrency(
          writer,
          account.id,
          current.currencyCode,
          from: oldKey,
        );
        await BookBalanceEngine.recomputeCurrency(
          writer,
          account.id,
          updated.currencyCode,
          from: newKey,
        );
      } else {
        await BookBalanceEngine.recomputeCurrency(
          writer,
          account.id,
          updated.currencyCode,
          from: oldKey.compareTo(newKey) <= 0 ? oldKey : newKey,
        );
      }
      await syncWalletLink(
        writer,
        transaction: updated,
        newId: _newId,
        now: now,
      );
      if (currencyChanged) {
        await writer.audit(
          'transaction',
          id,
          'currency_changed',
          details:
              '${current.amountMinor} ${current.currencyCode}->'
              '${updated.amountMinor} ${updated.currencyCode}',
        );
      } else if (current.amountMinor != updated.amountMinor) {
        await writer.audit(
          'transaction',
          id,
          'amount_changed',
          details: '${current.amountMinor}->${updated.amountMinor}',
        );
      }
      if (current.date != updated.date || current.time != updated.time) {
        await writer.audit(
          'transaction',
          id,
          'date_changed',
          details:
              '${current.date} ${current.time}->${updated.date} ${updated.time}',
        );
      }
      if (current.type != updated.type) {
        await writer.audit(
          'transaction',
          id,
          'type_changed',
          details: '${current.type.dbValue}->${updated.type.dbValue}',
        );
      }
      if (current.details != updated.details ||
          current.notes != updated.notes) {
        await writer.audit('transaction', id, 'updated');
      }
      return (await writer.transaction(id))!;
    });
  }

  /// Soft delete: the row stays (for undo and the audit trail) but no longer
  /// counts in any balance or total.
  Future<void> delete(String id) async {
    final now = _now;
    await _repository.write((writer) async {
      final current = await _requireLive(writer, id);
      final account = await _requireAccount(writer, current.accountId);
      _requireEditable(account);
      await writer.putTransaction(
        current.copyWith(deletedAt: () => now, updatedAt: now),
      );
      await BookBalanceEngine.recomputeCurrency(
        writer,
        account.id,
        current.currencyCode,
        from: BookOrderKey.of(current),
      );
      await softDeleteWalletLink(writer, bookTransactionId: id, now: now);
      await writer.audit(
        'transaction',
        id,
        'deleted',
        details:
            '${current.number} ${current.amountMinor} ${current.currencyCode}',
      );
    });
  }

  /// Undoes [delete].
  Future<void> restore(String id) async {
    final now = _now;
    await _repository.write((writer) async {
      final current = await writer.transaction(id);
      if (current == null) {
        throw const NotFoundException(
          code: 'transaction_not_found',
          userMessage: 'العملية المطلوبة غير موجودة.',
        );
      }
      if (!current.isDeleted) {
        return;
      }
      final account = await _requireAccount(writer, current.accountId);
      _requireEditable(account);
      await writer.putTransaction(
        current.copyWith(deletedAt: () => null, updatedAt: now),
      );
      // Its currency's balance row is kept for as long as the account exists,
      // but make sure (a row could only be missing in a damaged database).
      await BookBalanceEngine.ensureBalance(
        writer,
        account.id,
        current.currencyCode,
        now,
      );
      await BookBalanceEngine.recomputeCurrency(
        writer,
        account.id,
        current.currencyCode,
        from: BookOrderKey.of(current),
      );
      await restoreWalletLink(writer, bookTransactionId: id, now: now);
      await writer.audit('transaction', id, 'restored');
    });
  }

  /// The currency of a transaction being created (or moved to): it must exist
  /// and be active.
  Currency _requireActiveCurrency(String code) {
    final currency = _currencies.byCode(code);
    if (!currency.isActive) {
      throw const ValidationException(
        code: 'currency_inactive',
        userMessage: 'هذه العملة موقوفة. اختر عملة مفعّلة.',
      );
    }
    return currency;
  }

  static const ValidationException _paymentRequired = ValidationException(
    code: 'payment_wallet_required',
    userMessage: 'اختر وسيلة الدفع: نقدًا أو إحدى المحافظ.',
  );

  static void _requireEditable(BookAccount account) {
    if (account.status == BookAccountStatus.archived) {
      throw const ConflictException(
        code: 'account_archived',
        userMessage: 'الحساب مؤرشف. أعد تفعيله لتعديل عملياته.',
      );
    }
  }

  static Future<BookAccount> _requireAccount(
    BookWriter writer,
    String id,
  ) async {
    final account = await writer.account(id);
    if (account == null) {
      throw const NotFoundException(
        code: 'account_not_found',
        userMessage: 'الحساب المطلوب غير موجود.',
      );
    }
    return account;
  }

  static Future<BookTransaction> _requireLive(
    BookWriter writer,
    String id,
  ) async {
    final transaction = await writer.transaction(id);
    if (transaction == null || transaction.isDeleted) {
      throw const NotFoundException(
        code: 'transaction_not_found',
        userMessage: 'العملية المطلوبة غير موجودة.',
      );
    }
    return transaction;
  }
}
