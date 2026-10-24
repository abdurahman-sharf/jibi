import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../../../core/storage/secure_file_storage.dart';
import '../domain/book_balance.dart';
import '../domain/book_cascade.dart';
import '../domain/book_drafts.dart';
import 'book_watch.dart';

/// Rules for accounts (الحسابات) inside categories.
///
/// An account is a person or entity in one category. It has no currency of its
/// own: every transaction names its currency, and each currency the account uses
/// has its own opening balance and its own running balance (see
/// [BookAccountBalance]). Deleting an account with transactions cascades: every
/// transaction and its attachments go with it.
final class BookAccountsController {
  BookAccountsController({
    required BookRepository repository,
    required CurrencyRegistry currencies,
    SecureFileStorage? storage,
    String Function()? newId,
    DateTime Function()? clock,
  }) : _repository = repository,
       _currencies = currencies,
       _storage = storage,
       _newId = newId ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final BookRepository _repository;
  final CurrencyRegistry _currencies;

  /// Null in tests that do not exercise file storage; cascade delete then
  /// simply leaves no attachments to clean up (there is no storage to own a
  /// file in the first place).
  final SecureFileStorage? _storage;
  final String Function() _newId;
  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  Stream<List<AccountSummary>> watchSummaries({
    String? categoryId,
    bool includeArchived = true,
  }) => watchBookQuery(
    _repository.changes,
    () => _repository.accountSummaries(
      categoryId: categoryId,
      includeArchived: includeArchived,
    ),
  );

  /// Accounts whose name or any currency they use contains [text] (all when
  /// empty), for global search. Archived accounts and switched-off categories
  /// are left out.
  Stream<List<AccountSummary>> watchSearch(String text) {
    final query = text.trim().toLowerCase();
    return watchBookQuery(_repository.changes, () async {
      final all = await _repository.accountSummaries(
        includeArchived: false,
        activeCategoriesOnly: true,
      );
      return [
        for (final summary in all)
          if (query.isEmpty ||
              summary.account.name.toLowerCase().contains(query) ||
              summary.currencyCodes.any(
                (code) => code.toLowerCase().contains(query),
              ))
            summary,
      ];
    });
  }

  Stream<AccountSummary?> watchSummary(String id) =>
      watchBookQuery(_repository.changes, () => _repository.accountSummary(id));

  /// A one-off read of the same list [watchSummaries] streams.
  Future<List<AccountSummary>> summaries({
    String? categoryId,
    bool includeArchived = true,
    bool activeCategoriesOnly = false,
  }) => _repository.accountSummaries(
    categoryId: categoryId,
    includeArchived: includeArchived,
    activeCategoriesOnly: activeCategoriesOnly,
  );

  Future<AccountSummary?> summary(String id) =>
      _repository.accountSummary(id);

  Future<BookAccount?> find(String id) => _repository.account(id);

  /// The opening-balance rows of an account, one per currency it uses.
  Future<List<BookAccountBalance>> balances(String accountId) =>
      _repository.accountBalancesOf(accountId);

  Future<BookAccount> create(BookAccountDraft draft) async {
    final name = _validName(draft.name);
    final phone = _validPhone(draft.phone);
    final openings = _validOpenings(draft.openings ?? const []);
    final now = _now;
    return _repository.write((writer) async {
      final category = await writer.category(draft.categoryId);
      if (category == null || category.isArchived) {
        throw const NotFoundException(
          code: 'category_not_found',
          userMessage: 'التصنيف المطلوب غير موجود.',
        );
      }
      if (!category.isActive) {
        throw const ConflictException(
          code: 'category_inactive',
          userMessage: 'التصنيف موقوف. فعّله أولاً لإضافة حساب إليه.',
        );
      }
      final account = BookAccount(
        id: _newId(),
        categoryId: draft.categoryId,
        name: name,
        notes: optionalBookText(draft.notes),
        phone: phone,
        createdAt: now,
        updatedAt: now,
      );
      await writer.putAccount(account);
      for (final opening in openings) {
        _requireActive(opening.$1);
        await writer.putAccountBalance(
          BookAccountBalance(
            accountId: account.id,
            currencyCode: opening.$1,
            openingMinor: opening.$2,
            openingType: opening.$3,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      await writer.audit('account', account.id, 'created', details: name);
      return account;
    });
  }

  Future<BookAccount> update(String id, BookAccountDraft draft) async {
    final name = _validName(draft.name);
    final phone = _validPhone(draft.phone);
    final requested = draft.openings == null
        ? null
        : _validOpenings(draft.openings!);
    return _repository.write((writer) async {
      final current = await _require(writer, id);
      if (draft.categoryId != current.categoryId) {
        final target = await writer.category(draft.categoryId);
        if (target == null || target.isArchived || !target.isActive) {
          throw const ConflictException(
            code: 'category_unavailable',
            userMessage: 'التصنيف المحدد غير متاح.',
          );
        }
      }
      final now = _now;
      final updated = current.copyWith(
        categoryId: draft.categoryId,
        name: name,
        notes: () => optionalBookText(draft.notes),
        phone: () => phone,
        updatedAt: now,
      );
      await writer.putAccount(updated);
      if (requested != null) {
        await _applyOpenings(writer, id, requested, now);
      }
      await writer.audit('account', id, 'updated', details: name);
      return updated;
    });
  }

  /// Replaces the opening balances of [accountId] with [requested]: a currency
  /// listed gets that opening (a new one needs an active currency), a currency
  /// the account already uses but the list leaves out is reset to zero (or its
  /// row removed when it has no transactions at all). Only the currencies whose
  /// opening changed are recomputed, each on its own.
  Future<void> _applyOpenings(
    BookWriter writer,
    String accountId,
    List<(String, int, OpeningType)> requested,
    DateTime now,
  ) async {
    final existing = {
      for (final balance in await writer.accountBalances(accountId))
        balance.currencyCode: balance,
    };
    final wanted = {for (final opening in requested) opening.$1: opening};
    final changed = <String>[];

    Future<void> log(BookAccountBalance? before, String code, int minor, OpeningType type) =>
        writer.audit(
          'account',
          accountId,
          'opening_changed',
          details:
              '$code ${(before?.openingType ?? OpeningType.zero).dbValue}:'
              '${before?.openingMinor ?? 0}->${type.dbValue}:$minor',
        );

    for (final opening in requested) {
      final code = opening.$1;
      final previous = existing[code];
      if (previous == null) {
        _requireActive(code);
        await writer.putAccountBalance(
          BookAccountBalance(
            accountId: accountId,
            currencyCode: code,
            openingMinor: opening.$2,
            openingType: opening.$3,
            createdAt: now,
            updatedAt: now,
          ),
        );
        if (opening.$2 != 0) {
          changed.add(code);
          await log(null, code, opening.$2, opening.$3);
        }
      } else if (previous.openingMinor != opening.$2 ||
          previous.openingType != opening.$3) {
        await writer.putAccountBalance(
          previous.copyWith(
            openingMinor: opening.$2,
            openingType: opening.$3,
            updatedAt: now,
          ),
        );
        changed.add(code);
        await log(previous, code, opening.$2, opening.$3);
      }
    }
    for (final previous in existing.values) {
      if (wanted.containsKey(previous.currencyCode)) continue;
      final used =
          await writer.accountTransactionCount(
            accountId,
            currencyCode: previous.currencyCode,
          ) >
          0;
      if (!used) {
        await writer.deleteAccountBalance(accountId, previous.currencyCode);
      } else if (previous.openingMinor != 0) {
        await writer.putAccountBalance(
          previous.copyWith(
            openingMinor: 0,
            openingType: OpeningType.zero,
            updatedAt: now,
          ),
        );
        changed.add(previous.currencyCode);
        await log(previous, previous.currencyCode, 0, OpeningType.zero);
      }
    }
    // Every running balance of a currency is seeded from its opening balance.
    for (final code in changed) {
      await BookBalanceEngine.recomputeCurrency(writer, accountId, code);
    }
  }

  /// Suspended accounts stay readable but accept no new transactions;
  /// archived accounts are hidden from the default lists.
  Future<void> setStatus(String id, BookAccountStatus status) =>
      _repository.write((writer) async {
        final current = await _require(writer, id);
        await writer.putAccount(
          current.copyWith(status: status, updatedAt: _now),
        );
        await writer.audit('account', id, 'status', details: status.dbValue);
      });

  /// Deletes the account and, when it has any, every one of its transactions
  /// and their attachments — permanently, with no undo.
  Future<void> delete(String id) async {
    final removedAttachments = await _repository.write((writer) async {
      final current = await _require(writer, id);
      final transactionCount = await writer.accountTransactionCount(id);
      final removed = await cascadeDeleteAccount(writer, current);
      await writer.audit(
        'account',
        id,
        'deleted',
        details: transactionCount > 0
            ? '${current.name} · $transactionCount عملية'
            : current.name,
      );
      return removed;
    });
    final storage = _storage;
    if (storage != null && removedAttachments.isNotEmpty) {
      await deleteOwnedAttachmentFiles(storage, removedAttachments);
    }
  }

  static String _validName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      throw const ValidationException(
        code: 'account_name_required',
        userMessage: 'أدخل اسم الحساب.',
      );
    }
    return name;
  }

  static String? _validPhone(String? value) {
    final phone = value?.trim();
    if (phone == null || phone.isEmpty) return null;
    if (phone.length > 30) {
      throw const ValidationException(
        code: 'phone_too_long',
        userMessage: 'رقم الجوال طويل جداً.',
      );
    }
    if (!RegExp(r'^[0-9+\-\s()٠-٩]+$').hasMatch(phone)) {
      throw const ValidationException(
        code: 'invalid_phone',
        userMessage: 'رقم الجوال يقبل الأرقام والرمز + والشرطة فقط.',
      );
    }
    return phone;
  }

  /// Validates the opening balances of a draft and returns them as
  /// `(currency code, amount, side)`: every currency must exist, none may
  /// repeat, an amount cannot be negative, an amount of zero is always side
  /// "zero" and a debit/credit side needs an amount. Whether a currency is
  /// active matters only for one the account does not use yet
  /// ([_requireActive]).
  List<(String, int, OpeningType)> _validOpenings(
    List<BookAccountOpeningDraft> drafts,
  ) {
    final seen = <String>{};
    final result = <(String, int, OpeningType)>[];
    for (final draft in drafts) {
      final currency = _currencies.byCode(draft.currencyCode);
      if (!seen.add(currency.code)) {
        throw const ValidationException(
          code: 'duplicate_account_currency',
          userMessage: 'لا يمكن تكرار نفس العملة في الحساب.',
        );
      }
      if (draft.openingMinor < 0) {
        throw const ValidationException(
          code: 'invalid_opening_balance',
          userMessage: 'الرصيد الافتتاحي لا يمكن أن يكون سالباً.',
        );
      }
      if (draft.openingMinor > 0 && draft.openingType == OpeningType.zero) {
        throw const ValidationException(
          code: 'opening_type_required',
          userMessage: 'حدد نوع الرصيد الافتتاحي (مدين أو دائن).',
        );
      }
      final zero = draft.openingMinor == 0 || draft.openingType == OpeningType.zero;
      result.add((
        currency.code,
        zero ? 0 : draft.openingMinor,
        zero ? OpeningType.zero : draft.openingType,
      ));
    }
    return result;
  }

  /// A currency an account starts using now must be active; one it already
  /// uses may stay even after being switched off.
  void _requireActive(String code) {
    if (!_currencies.byCode(code).isActive) {
      throw const ValidationException(
        code: 'currency_inactive',
        userMessage: 'هذه العملة موقوفة. اختر عملة مفعّلة.',
      );
    }
  }

  static Future<BookAccount> _require(BookWriter writer, String id) async {
    final account = await writer.account(id);
    if (account == null) {
      throw const NotFoundException(
        code: 'account_not_found',
        userMessage: 'الحساب المطلوب غير موجود.',
      );
    }
    return account;
  }
}
