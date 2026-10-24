import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/currency_palette.dart';
import 'app_database.dart';

/// Schema v13: the app ships with three currencies — the Yemeni rial (the
/// base), the Saudi rial and the US dollar — without decimal places, and each
/// currency can carry an accent color.
///
/// The migration never touches money that already exists:
/// - a currency's decimal places change only while nothing is stored in it
///   (amounts are kept in minor units, so a change would corrupt every balance);
/// - a currency is deleted only while no table references it;
/// - the base currency moves to the Yemeni rial only on a device that holds no
///   accounts and no wallet movements, where the saved "SAR" was never a choice
///   (onboarding persists the fallback).
final class MigrationV13 implements DatabaseMigration {
  const MigrationV13();

  @override
  int get version => 13;

  /// The names the older migrations seeded, so a name the owner edited is left
  /// alone.
  static const Map<String, ({String oldName, String newName, int color})>
  _shipped = {
    'YER': (
      oldName: 'ريال يمني',
      newName: 'الريال اليمني',
      color: yerCurrencyColor,
    ),
    'SAR': (
      oldName: 'ريال سعودي',
      newName: 'الريال السعودي',
      color: sarCurrencyColor,
    ),
    'USD': (
      oldName: 'دولار أمريكي',
      newName: 'الدولار الأمريكي',
      color: usdCurrencyColor,
    ),
  };

  /// Seeded by the older migrations and dropped here while unused.
  static const List<String> _extraSeeds = <String>[
    'EUR',
    'AED',
    'KWD',
    'BHD',
    'OMR',
    'QAR',
    'GBP',
  ];

  static const List<(String, String, String, int)> _seedRows =
      <(String, String, String, int)>[
        ('YER', 'الريال اليمني', 'ر.ي', 0),
        ('SAR', 'الريال السعودي', 'ر.س', 0),
        ('USD', 'الدولار الأمريكي', r'$', 0),
      ];

  @override
  Future<void> apply(Transaction transaction) async {
    await transaction.execute('ALTER TABLE currencies ADD COLUMN color INTEGER');
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;

    for (final (code, name, symbol, digits) in _seedRows) {
      await transaction.rawInsert(
        'INSERT OR IGNORE INTO currencies '
        '(code, name, symbol, fraction_digits, sort_order, is_active, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, 0, 1, ?, ?)',
        <Object?>[code, name, symbol, digits, now, now],
      );
    }

    var order = 0;
    for (final code in _shipped.keys) {
      final shipped = _shipped[code]!;
      await transaction.rawUpdate(
        'UPDATE currencies SET is_active = 1, sort_order = ?, '
        'name = CASE WHEN name = ? THEN ? ELSE name END, '
        'color = COALESCE(color, ?), updated_at = ? WHERE code = ?',
        <Object?>[order, shipped.oldName, shipped.newName, shipped.color, now, code],
      );
      if (!await _holdsData(transaction, code)) {
        await transaction.rawUpdate(
          'UPDATE currencies SET fraction_digits = 0 WHERE code = ?',
          <Object?>[code],
        );
      }
      order++;
    }

    for (final code in _extraSeeds) {
      if (!await _isReferenced(transaction, code)) {
        await transaction.rawDelete(
          'DELETE FROM currencies WHERE code = ?',
          <Object?>[code],
        );
      }
    }

    // Whatever else is left (used seeds, currencies the owner added) follows
    // the three, in its previous order.
    final rest = await transaction.rawQuery(
      'SELECT code FROM currencies WHERE code NOT IN (?, ?, ?) '
      'ORDER BY sort_order ASC, code ASC',
      _shipped.keys.toList(),
    );
    for (final row in rest) {
      await transaction.rawUpdate(
        'UPDATE currencies SET sort_order = ? WHERE code = ?',
        <Object?>[order++, row['code']],
      );
    }

    if (await _isPristine(transaction)) {
      await _moveBaseToRial(transaction, now: now);
    }
  }

  /// True when [code] appears in any table that stores currency codes.
  Future<bool> _isReferenced(Transaction txn, String code) async {
    for (final table in const <String>[
      'book_accounts',
      'wallet_balances',
      'wallet_transactions',
    ]) {
      if (await _count(
            txn,
            'SELECT COUNT(*) FROM $table WHERE currency_code = ?',
            <Object?>[code],
          ) >
          0) {
        return true;
      }
    }
    return false;
  }

  /// True when money is stored in [code]: an account, a wallet movement or a
  /// non-zero opening balance. An empty holding row (a wallet that merely lists
  /// the currency) is not data, since no amount depends on the decimal places.
  Future<bool> _holdsData(Transaction txn, String code) async {
    final args = <Object?>[code];
    if (await _count(txn, 'SELECT COUNT(*) FROM book_accounts WHERE currency_code = ?', args) > 0) {
      return true;
    }
    if (await _count(txn, 'SELECT COUNT(*) FROM wallet_transactions WHERE currency_code = ?', args) > 0) {
      return true;
    }
    return await _count(
          txn,
          'SELECT COUNT(*) FROM wallet_balances '
          'WHERE currency_code = ? AND opening_minor != 0',
          args,
        ) >
        0;
  }

  /// No account, no wallet movement, no non-zero opening balance anywhere.
  Future<bool> _isPristine(Transaction txn) async {
    final counts = <int>[
      await _count(txn, 'SELECT COUNT(*) FROM book_accounts', const <Object?>[]),
      await _count(txn, 'SELECT COUNT(*) FROM wallet_transactions', const <Object?>[]),
      await _count(
        txn,
        'SELECT COUNT(*) FROM wallet_balances WHERE opening_minor != 0',
        const <Object?>[],
      ),
    ];
    return counts.every((count) => count == 0);
  }

  /// Makes the Yemeni rial the saved base currency (only when the saved one is
  /// still the old default "SAR") and points the main wallet's empty balance
  /// row at it.
  Future<void> _moveBaseToRial(Transaction txn, {required int now}) async {
    final rows = await txn.query(
      'app_settings',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>['settings_v1'],
    );
    if (rows.isNotEmpty) {
      try {
        final decoded = jsonDecode(rows.single['value']! as String);
        if (decoded is Map<String, Object?> &&
            decoded['defaultCurrencyCode'] == 'SAR') {
          decoded['defaultCurrencyCode'] = 'YER';
          await txn.update(
            'app_settings',
            <String, Object?>{'value': jsonEncode(decoded), 'updated_at': now},
            where: 'key = ?',
            whereArgs: <Object?>['settings_v1'],
          );
        }
      } on Object {
        // An unreadable settings row falls back to the defaults on read.
      }
    }
    const mainWallets = "(SELECT id FROM wallets WHERE is_main = 1)";
    final hasRialRow = await _count(
      txn,
      'SELECT COUNT(*) FROM wallet_balances '
      "WHERE currency_code = 'YER' AND wallet_id IN $mainWallets",
      const <Object?>[],
    );
    if (hasRialRow > 0) {
      await txn.rawDelete(
        'DELETE FROM wallet_balances '
        "WHERE currency_code = 'SAR' AND wallet_id IN $mainWallets",
      );
    } else {
      await txn.rawUpdate(
        "UPDATE wallet_balances SET currency_code = 'YER', updated_at = ? "
        "WHERE currency_code = 'SAR' AND wallet_id IN $mainWallets",
        <Object?>[now],
      );
    }
  }

  Future<int> _count(
    Transaction txn,
    String sql,
    List<Object?> arguments,
  ) async =>
      Sqflite.firstIntValue(await txn.rawQuery(sql, arguments)) ?? 0;
}
