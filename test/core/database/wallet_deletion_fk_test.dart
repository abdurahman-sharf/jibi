import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/book_wallets.dart';
import '../../support/test_currencies.dart';

/// Requirement 11 of the financial-cycle review: this used to fail with a
/// `FOREIGN KEY` violation, because `book_transactions.wallet_id` and
/// `wallet_transactions.wallet_id` both reference `wallets(id) ON DELETE
/// RESTRICT`. As of the wallets/payment-method plan (schema v11+, still true
/// at v14), [cascadeDeleteWallet] avoids that by clearing every referencing
/// row BEFORE dropping the wallet: it hard-deletes the wallet's own
/// movements, unlinks (not deletes) every book transaction paid through it —
/// live AND soft-deleted — then removes the wallet.
///
/// This test proves it on a REAL file-backed SQLite database (not the FFI
/// in-memory shim) with `PRAGMA foreign_keys = ON`, exactly as the shipped app
/// opens it, on a wallet that has: a live linked transaction, a soft-deleted
/// linked transaction, and a plain (unlinked) deposit — the two-legged
/// FOREIGN KEY exposure `cascadeDeleteWallet`'s doc comment describes.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory sandbox;
  late String path;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi_wallet_fk_');
    path = '${sandbox.path}${Platform.pathSeparator}database.sqlite';
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test(
    'deleting a wallet used by live and soft-deleted book transactions '
    'succeeds on a real, foreign-key-enforced file database',
    () async {
      final appDatabase = AppDatabase(path: path);
      final repository = SqliteBookRepository(appDatabase);
      final currencies = testCurrencyRegistry();
      await seedMainWallet(repository, currencies: const ['YER']);
      final book = BookServices(
        repository: repository,
        currencies: currencies,
        defaultCurrencyCode: () => 'YER',
      );

      final raji = await book.wallets.create(
        WalletDraft.single(name: 'محفظة الراجحي', currencyCode: 'YER'),
      );
      final category = await book.categories.create(
        const BookCategoryDraft(name: 'الأصدقاء'),
      );
      final ahmad = await book.accounts.create(
        BookAccountDraft(categoryId: category.id, name: 'أحمد'),
      );

      // A live transaction paid through راجحي…
      final live = await book.transactions.create(
        BookTransactionDraft(
          accountId: ahmad.id,
          currencyCode: 'YER',
          type: EntryType.debit,
          amountMinor: 500,
          date: '2026-01-01',
          walletId: raji.id,
        ),
      );
      // …one that is soft-deleted (its `linked` wallet_transactions row keeps
      // existing, just flagged deleted — still a live FOREIGN KEY row)…
      final softDeleted = await book.transactions.create(
        BookTransactionDraft(
          accountId: ahmad.id,
          currencyCode: 'YER',
          type: EntryType.credit,
          amountMinor: 200,
          date: '2026-01-02',
          walletId: raji.id,
        ),
      );
      await book.transactions.delete(softDeleted.id);
      // …and a plain deposit with no book transaction behind it at all.
      await book.walletTransactions.deposit(
        WalletDepositDraft(walletId: raji.id, amountMinor: 1000, date: '2026-01-03'),
      );

      final db = await appDatabase.database;
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(
        (await db.query('wallet_transactions', where: 'wallet_id = ?', whereArgs: [raji.id])),
        hasLength(3),
        reason: 'live linked + soft-deleted linked + plain deposit',
      );

      // The delete itself must not throw.
      await book.wallets.delete(raji.id);

      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(await db.rawQuery('PRAGMA integrity_check'), [
        {'integrity_check': 'ok'},
      ]);
      expect(await db.query('wallets', where: 'id = ?', whereArgs: [raji.id]), isEmpty);
      expect(
        await db.query('wallet_transactions', where: 'wallet_id = ?', whereArgs: [raji.id]),
        isEmpty,
        reason: 'every movement of the deleted wallet is gone, cleanly',
      );

      // Both book transactions survive, unlinked — the book is the source of
      // truth for them, per cascadeDeleteWallet's contract.
      final liveAfter = (await repository.transaction(live.id))!;
      expect(liveAfter.walletId, isNull);
      expect(liveAfter.walletEffect, isNull);
      expect(liveAfter.isDeleted, isFalse);
      final softAfter = (await repository.transaction(softDeleted.id))!;
      expect(softAfter.walletId, isNull);
      expect(softAfter.isDeleted, isTrue, reason: 'soft delete state is untouched');
      expect(await repository.countBalanceMismatches(ahmad.id), 0);

      await repository.dispose();
      await appDatabase.close();
    },
  );

  test(
    'deleting the wallet flagged is_main (نقدًا) does not violate the FK '
    'either, even mid-transaction-history',
    () async {
      final appDatabase = AppDatabase(path: path);
      final repository = SqliteBookRepository(appDatabase);
      await seedMainWallet(repository, currencies: const ['YER']);
      final book = BookServices(
        repository: repository,
        currencies: testCurrencyRegistry(),
        defaultCurrencyCode: () => 'YER',
      );
      final category = await book.categories.create(
        const BookCategoryDraft(name: 'الأصدقاء'),
      );
      final ahmad = await book.accounts.create(
        BookAccountDraft(categoryId: category.id, name: 'أحمد'),
      );
      await book.transactions.create(
        BookTransactionDraft(
          accountId: ahmad.id,
          currencyCode: 'YER',
          type: EntryType.debit,
          amountMinor: 500,
          date: '2026-01-01',
          walletId: seededMainWalletId,
        ),
      );

      await book.wallets.delete(seededMainWalletId);

      final db = await appDatabase.database;
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(await db.query('wallets', where: 'is_main = 1'), isEmpty);

      await repository.dispose();
      await appDatabase.close();
    },
  );
}
