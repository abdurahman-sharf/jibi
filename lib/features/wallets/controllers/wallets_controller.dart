import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../../book/controllers/book_watch.dart';
import '../domain/wallet_balance.dart';
import '../domain/wallet_cascade.dart';
import '../domain/wallet_drafts.dart';

/// Rules for wallets (المحافظ): places money is kept, each able to hold
/// several currencies at once (see [WalletBalance]).
///
/// A currency already used by a movement cannot be removed from a wallet, but
/// its opening balance can still be edited (that only recomputes that one
/// currency's running balance, never the wallet's other currencies). A new
/// currency can be added at any time — set an opening balance for it in the
/// wallet form, or simply record a movement in it, which creates the balance
/// row automatically at opening zero. Deleting a wallet with movements
/// cascades: every movement and balance (and, for a transfer, the paired leg
/// on the other wallet) goes with it — the same immediate, confirm-and-delete
/// policy as categories and accounts.
final class WalletsController {
  WalletsController({
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

  Stream<List<WalletSummary>> watchSummaries({bool includeArchived = true}) =>
      watchBookQuery(
        _repository.changes,
        () => _repository.walletSummaries(includeArchived: includeArchived),
      );

  Stream<WalletSummary?> watchSummary(String id) =>
      watchBookQuery(_repository.changes, () => _repository.walletSummary(id));

  Stream<List<WalletCurrencyTotal>> watchTotalsByCurrency() => watchBookQuery(
    _repository.changes,
    () => _repository.walletTotalsByCurrency(),
  );

  /// A one-off read of the same list [watchSummaries] streams.
  Future<List<WalletSummary>> summaries({bool includeArchived = true}) =>
      _repository.walletSummaries(includeArchived: includeArchived);

  Future<WalletSummary?> summary(String id) => _repository.walletSummary(id);

  Future<Wallet?> find(String id) => _repository.wallet(id);

  Future<Wallet> create(WalletDraft draft) async {
    final name = _validName(draft.name);
    final openings = _validOpenings(draft.openings);
    final now = _now;
    final wallet = Wallet(
      id: _newId(),
      name: name,
      accountNumber: optionalWalletText(draft.accountNumber),
      image: draft.image,
      notes: optionalWalletText(draft.notes),
      createdAt: now,
      updatedAt: now,
    );
    return _repository.write((writer) async {
      await writer.putWallet(wallet);
      for (final opening in openings) {
        await writer.putWalletBalance(
          WalletBalance(
            walletId: wallet.id,
            currencyCode: opening.currencyCode,
            openingMinor: opening.openingMinor,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      await writer.audit('wallet', wallet.id, 'created', details: name);
      return wallet;
    });
  }

  Future<Wallet> update(String id, WalletDraft draft) async {
    final name = _validName(draft.name);
    final openings = _validOpenings(draft.openings);
    return _repository.write((writer) async {
      final current = await _require(writer, id);
      final existing = await writer.walletBalances(id);
      final existingByCode = {
        for (final balance in existing) balance.currencyCode: balance,
      };
      final keptCodes = <String>{};
      final now = _now;
      for (final opening in openings) {
        keptCodes.add(opening.currencyCode);
        final previous = existingByCode[opening.currencyCode];
        if (previous == null) {
          await writer.putWalletBalance(
            WalletBalance(
              walletId: id,
              currencyCode: opening.currencyCode,
              openingMinor: opening.openingMinor,
              createdAt: now,
              updatedAt: now,
            ),
          );
        } else if (previous.openingMinor != opening.openingMinor) {
          final updatedBalance = previous.copyWith(
            openingMinor: opening.openingMinor,
            updatedAt: now,
          );
          await writer.putWalletBalance(updatedBalance);
          await WalletBalanceEngine.recomputeWalletCurrency(
            writer,
            updatedBalance,
          );
        }
      }
      for (final balance in existing) {
        if (keptCodes.contains(balance.currencyCode)) continue;
        final movementCount = await writer.walletTransactionCount(
          id,
          currencyCode: balance.currencyCode,
        );
        if (movementCount > 0) {
          throw const ConflictException(
            code: 'wallet_currency_has_movements',
            userMessage: 'لا يمكن إزالة عملة فيها حركات.',
          );
        }
        await writer.deleteWalletBalance(id, balance.currencyCode);
      }
      final updated = current.copyWith(
        name: name,
        accountNumber: () => optionalWalletText(draft.accountNumber),
        image: () => draft.image,
        notes: () => optionalWalletText(draft.notes),
        updatedAt: now,
      );
      await writer.putWallet(updated);
      await writer.audit('wallet', id, 'updated', details: name);
      return updated;
    });
  }

  /// Validates every opening: a known, active currency, a non-negative
  /// amount, and no currency repeated.
  List<WalletOpeningDraft> _validOpenings(List<WalletOpeningDraft> openings) {
    final seen = <String>{};
    for (final opening in openings) {
      final currency = _currencies.byCode(opening.currencyCode);
      if (!currency.isActive) {
        throw const ValidationException(
          code: 'currency_inactive',
          userMessage: 'هذه العملة موقوفة. اختر عملة مفعّلة.',
        );
      }
      if (opening.openingMinor < 0) {
        throw const ValidationException(
          code: 'invalid_opening_balance',
          userMessage: 'الرصيد الافتتاحي لا يمكن أن يكون سالباً.',
        );
      }
      if (!seen.add(currency.code)) {
        throw const ValidationException(
          code: 'duplicate_wallet_currency',
          userMessage: 'لا يمكن تكرار نفس العملة في المحفظة.',
        );
      }
    }
    return [
      for (final opening in openings)
        WalletOpeningDraft(
          currencyCode: _currencies.byCode(opening.currencyCode).code,
          openingMinor: opening.openingMinor,
        ),
    ];
  }

  Future<void> setStatus(String id, WalletStatus status) =>
      _repository.write((writer) async {
        final current = await _require(writer, id);
        await writer.putWallet(
          current.copyWith(status: status, updatedAt: _now),
        );
        await writer.audit('wallet', id, 'status', details: status.dbValue);
      });

  /// Flags [id] as the main wallet, demoting whichever one held that flag.
  Future<void> setMain(String id) => _repository.write((writer) async {
    final target = await _require(writer, id);
    if (target.isMain) return;
    final now = _now;
    final previous = await writer.mainWallet();
    if (previous != null) {
      await writer.putWallet(
        previous.copyWith(isMain: false, updatedAt: now),
      );
    }
    await writer.putWallet(target.copyWith(isMain: true, updatedAt: now));
    await writer.audit('wallet', id, 'set_main', details: target.name);
  });

  /// Deletes the wallet and, when it has any, every one of its movements —
  /// permanently, with no undo. A transfer's other leg (on a different
  /// wallet) is removed and that wallet's balance recomputed too.
  Future<void> delete(String id) => _repository.write((writer) async {
    final current = await _require(writer, id);
    final movementCount = await writer.walletTransactionCount(id);
    final affectedWallets = await cascadeDeleteWallet(writer, current);
    for (final walletId in affectedWallets) {
      await WalletBalanceEngine.recomputeWallet(writer, walletId);
    }
    await writer.audit(
      'wallet',
      id,
      'deleted',
      details: movementCount > 0
          ? '${current.name} · $movementCount حركة'
          : current.name,
    );
  });

  static String _validName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      throw const ValidationException(
        code: 'wallet_name_required',
        userMessage: 'أدخل اسم المحفظة.',
      );
    }
    return name;
  }

  static Future<Wallet> _require(BookWriter writer, String id) async {
    final wallet = await writer.wallet(id);
    if (wallet == null) {
      throw const NotFoundException(
        code: 'wallet_not_found',
        userMessage: 'المحفظة المطلوبة غير موجودة.',
      );
    }
    return wallet;
  }
}
