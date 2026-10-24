import '../../../core/errors/app_exception.dart';
import '../../../core/models/currency.dart';
import '../../../core/models/currency_palette.dart';
import '../../../core/repositories/repositories.dart';
import '../domain/currency_draft.dart';

/// Presentation-independent CRUD service for managed currencies.
///
/// Every mutation also updates the shared [CurrencyRegistry] instance so
/// controllers and screens holding a reference to it see the change without
/// re-reading the database.
final class CurrenciesController {
  CurrenciesController({
    required this.repository,
    required this.registry,
    required String Function() defaultCurrencyCode,
  }) : _defaultCurrencyCode = defaultCurrencyCode;

  final CurrenciesRepository repository;
  final CurrencyRegistry registry;
  final String Function() _defaultCurrencyCode;

  Stream<List<Currency>> watchCurrencies() => repository.watchCurrencies();

  Future<bool> isCurrencyUsed(String code) => repository.isCurrencyUsed(code);

  Future<Currency> createCurrency({
    required String code,
    required CurrencyDraft draft,
  }) async {
    draft.validate();
    final normalizedCode = requireCurrencyCode(code);
    final currency = Currency(
      code: normalizedCode,
      name: draft.name,
      symbol: draft.symbol,
      fractionDigits: draft.fractionDigits,
      sortOrder: registry.currencies.length,
      // Every new currency gets its own accent unless the owner chose one.
      colorValue:
          draft.colorValue ??
          nextFreeCurrencyColor([
            for (final other in registry.currencies) other.colorValue,
          ], normalizedCode),
    );
    await repository.createCurrency(currency);
    registry.upsert(currency);
    return currency;
  }

  Future<Currency> updateCurrency(String code, CurrencyDraft draft) async {
    draft.validate();
    final existing = await _required(code);
    if (draft.fractionDigits != existing.fractionDigits &&
        await repository.isCurrencyUsed(existing.code)) {
      throw const ConflictException(
        code: 'currency_fraction_locked',
        userMessage: 'لا يمكن تغيير عدد المنازل العشرية بعد استخدام العملة.',
      );
    }
    final updated = Currency(
      code: existing.code,
      name: draft.name,
      symbol: draft.symbol,
      fractionDigits: draft.fractionDigits,
      isActive: existing.isActive,
      sortOrder: existing.sortOrder,
      colorValue: draft.colorValue,
    );
    await repository.updateCurrency(updated);
    registry.upsert(updated);
    return updated;
  }

  Future<void> setActive(String code, {required bool isActive}) async {
    final existing = await _required(code);
    if (!isActive) {
      if (existing.code == _defaultCurrencyCode()) {
        throw const ConflictException(
          code: 'currency_is_default',
          userMessage: 'اختر عملة افتراضية بديلة قبل أرشفة هذه العملة.',
        );
      }
      final stillActive = registry.activeCurrencies.where(
        (currency) => currency.code != existing.code,
      );
      if (stillActive.isEmpty) {
        throw const ConflictException(
          code: 'last_active_currency',
          userMessage: 'يجب أن تبقى عملة واحدة نشطة على الأقل.',
        );
      }
    }
    await repository.setActive(existing.code, isActive: isActive);
    registry.upsert(existing.copyWith(isActive: isActive));
  }

  Future<void> reorder(List<String> orderedCodes) async {
    await repository.reorder(orderedCodes);
    for (var index = 0; index < orderedCodes.length; index++) {
      final existing = registry.byCode(orderedCodes[index]);
      registry.upsert(existing.copyWith(sortOrder: index));
    }
  }

  Future<void> deleteCurrency(String code) async {
    final existing = await _required(code);
    if (existing.code == _defaultCurrencyCode()) {
      throw const ConflictException(
        code: 'currency_is_default',
        userMessage: 'لا يمكن حذف العملة الافتراضية.',
      );
    }
    await repository.deleteCurrency(existing.code);
    registry.remove(existing.code);
  }

  Future<Currency> _required(String code) async {
    final currency = await repository.findCurrency(code);
    if (currency == null) {
      throw const NotFoundException(
        code: 'currency_not_found',
        userMessage: 'العملة المطلوبة غير موجودة.',
      );
    }
    return currency;
  }
}
