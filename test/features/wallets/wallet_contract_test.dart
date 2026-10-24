import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/book_repository.dart';
import 'package:jibi/features/book/data/in_memory_book_repository.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/test_currencies.dart';

final class _Harness {
  _Harness(this.repository, this.dispose);

  final BookRepository repository;
  final Future<void> Function() dispose;
}

Future<_Harness> _openMemory() async {
  final repository = InMemoryBookRepository();
  return _Harness(repository, repository.dispose);
}

Future<_Harness> _openSqlite() async {
  final database = AppDatabase(path: inMemoryDatabasePath);
  final repository = SqliteBookRepository(database);
  return _Harness(repository, () async {
    await repository.dispose();
    await database.close();
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  _suite('in-memory repository', _openMemory);
  _suite('sqlite repository', _openSqlite);
}

void _suite(String name, Future<_Harness> Function() open) {
  group(name, () {
    late _Harness harness;
    late CurrencyRegistry currencies;
    late WalletsController wallets;
    late WalletTransactionsController movements;
    var sequence = 0;
    // Safely after any real DateTime.now() the sqlite backend's migration
    // used to seed the main wallet (see the cleanup below).
    var tick = DateTime.utc(2099, 1, 1);

    setUp(() async {
      sequence = 0;
      tick = DateTime.utc(2099, 1, 1);
      harness = await open();
      currencies = testCurrencyRegistry();
      String newId() => 'id-${++sequence}';
      DateTime clock() => tick = tick.add(const Duration(seconds: 1));
      wallets = WalletsController(
        repository: harness.repository,
        currencies: currencies,
        newId: newId,
        clock: clock,
      );
      movements = WalletTransactionsController(
        repository: harness.repository,
        newId: newId,
        clock: clock,
      );
      // The real app always seeds one main wallet (MigrationV11); the
      // in-memory double does not. Normalize both to a blank slate so this
      // contract test proves identical behaviour from the same starting
      // point — the seed itself is proven separately in migration_v11_test.
      for (final summary in await wallets.summaries()) {
        await harness.repository.write(
          (writer) => writer.deleteWallet(summary.wallet.id),
        );
      }
    });

    tearDown(() => harness.dispose());

    Future<Wallet> wallet({
      String name = 'الصندوق الرئيسي',
      String currency = 'SAR',
      int opening = 0,
    }) => wallets.create(
      WalletDraft.single(name: name, currencyCode: currency, openingMinor: opening),
    );

    Future<WalletTransaction> deposit(
      Wallet wallet,
      int amount,
      String date, {
      String time = '00:00',
      String? currencyCode,
    }) => movements.deposit(
      WalletDepositDraft(
        walletId: wallet.id,
        currencyCode: currencyCode,
        amountMinor: amount,
        date: date,
        time: time,
      ),
    );

    Future<WalletTransaction> withdraw(
      Wallet wallet,
      int amount,
      String date,
    ) => movements.withdraw(
      WalletWithdrawalDraft(walletId: wallet.id, amountMinor: amount, date: date),
    );

    Future<List<WalletTransaction>> ascending(
      Wallet wallet, {
      String currencyCode = 'SAR',
    }) async => (await harness.repository.walletTransactionPage(
      wallet.id,
      currencyCode: currencyCode,
      newestFirst: false,
      limit: 500,
    )).items;

    group('wallet rules', () {
      test('rejects an empty name, a negative opening and an unknown currency',
          () async {
        expect(
          () => wallets.create(
            WalletDraft.single(name: '  ', currencyCode: 'SAR'),
          ),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => wallets.create(
            WalletDraft.single(
              name: 'محفظة',
              currencyCode: 'SAR',
              openingMinor: -1,
            ),
          ),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => wallets.create(
            WalletDraft.single(name: 'محفظة', currencyCode: 'XXX'),
          ),
          throwsA(isA<ValidationException>()),
        );
      });

      test('rejects the same currency listed twice', () async {
        expect(
          () => wallets.create(
            const WalletDraft(
              name: 'محفظة',
              openings: [
                WalletOpeningDraft(currencyCode: 'SAR', openingMinor: 100),
                WalletOpeningDraft(currencyCode: 'sar', openingMinor: 200),
              ],
            ),
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.code,
              'code',
              'duplicate_wallet_currency',
            ),
          ),
        );
      });

      test('creates a wallet with an account number, notes and an opening balance',
          () async {
        final created = await wallets.create(
          WalletDraft.single(
            name: 'محفظة البنك الأهلي',
            accountNumber: 'SA0000000000000000000000',
            currencyCode: 'SAR',
            openingMinor: 50000,
            notes: 'ملاحظة',
          ),
        );
        expect(created.accountNumber, 'SA0000000000000000000000');
        expect(created.isMain, isFalse);
        final summary = await wallets.summary(created.id);
        expect(summary!.balanceOf('SAR'), 50000);
        expect(summary.transactionCount, 0);
      });

      test('a wallet can hold several currencies at once, each independent',
          () async {
        final w = await wallets.create(
          const WalletDraft(
            name: 'متعددة',
            openings: [
              WalletOpeningDraft(currencyCode: 'SAR', openingMinor: 1000),
              WalletOpeningDraft(currencyCode: 'USD', openingMinor: 200),
            ],
          ),
        );
        await deposit(w, 500, '2025-01-01', currencyCode: 'SAR');
        await deposit(w, 50, '2025-01-01', currencyCode: 'USD');

        final summary = (await wallets.summary(w.id))!;
        expect(summary.currencies, containsAll(<String>['SAR', 'USD']));
        expect(summary.balanceOf('SAR'), 1500);
        expect(summary.balanceOf('USD'), 250);
        expect(summary.isMultiCurrency, isTrue);
      });

      test(
        'a movement in a currency the wallet does not hold yet creates that '
        'balance automatically, at opening zero',
        () async {
          final w = await wallet(currency: 'SAR');
          await deposit(w, 300, '2025-01-01', currencyCode: 'USD');

          final summary = (await wallets.summary(w.id))!;
          expect(summary.currencies, containsAll(<String>['SAR', 'USD']));
          final usd = summary.balances.singleWhere((b) => b.currencyCode == 'USD');
          expect(usd.openingMinor, 0);
          expect(usd.balanceMinor, 300);
        },
      );

      test(
        'a movement with no explicit currency needs one when the wallet '
        'holds more than one',
        () async {
          final w = await wallets.create(
            const WalletDraft(
              name: 'متعددة',
              openings: [
                WalletOpeningDraft(currencyCode: 'SAR'),
                WalletOpeningDraft(currencyCode: 'USD'),
              ],
            ),
          );
          expect(
            () => deposit(w, 100, '2025-01-01'),
            throwsA(
              isA<ValidationException>().having(
                (e) => e.code,
                'code',
                'wallet_currency_required',
              ),
            ),
          );
        },
      );

      test('a currency with movements cannot be removed from a wallet',
          () async {
        final w = await wallet();
        await deposit(w, 1000, '2025-01-10');
        expect(
          () => wallets.update(w.id, const WalletDraft(name: 'الصندوق الرئيسي')),
          throwsA(
            isA<ConflictException>().having(
              (e) => e.code,
              'code',
              'wallet_currency_has_movements',
            ),
          ),
        );
      });

      test('a currency with no movements can be removed', () async {
        final w = await wallets.create(
          const WalletDraft(
            name: 'متعددة',
            openings: [
              WalletOpeningDraft(currencyCode: 'SAR', openingMinor: 100),
              WalletOpeningDraft(currencyCode: 'USD', openingMinor: 50),
            ],
          ),
        );
        await wallets.update(
          w.id,
          const WalletDraft(
            name: 'متعددة',
            openings: [WalletOpeningDraft(currencyCode: 'SAR', openingMinor: 100)],
          ),
        );
        final summary = (await wallets.summary(w.id))!;
        expect(summary.currencies, ['SAR']);
      });

      test('changing the opening balance rebuilds only that currency',
          () async {
        final w = await wallets.create(
          const WalletDraft(
            name: 'متعددة',
            openings: [
              WalletOpeningDraft(currencyCode: 'SAR'),
              WalletOpeningDraft(currencyCode: 'USD'),
            ],
          ),
        );
        await deposit(w, 1000, '2025-01-10', currencyCode: 'SAR');
        await deposit(w, 500, '2025-01-11', currencyCode: 'SAR');
        await deposit(w, 70, '2025-01-10', currencyCode: 'USD');
        await wallets.update(
          w.id,
          const WalletDraft(
            name: 'متعددة',
            openings: [
              WalletOpeningDraft(currencyCode: 'SAR', openingMinor: 2000),
              WalletOpeningDraft(currencyCode: 'USD', openingMinor: 0),
            ],
          ),
        );
        expect(
          (await ascending(w)).map((r) => r.balanceAfter),
          [3000, 3500],
        );
        // USD's own sequence is untouched by the SAR opening edit.
        expect(
          (await ascending(w, currencyCode: 'USD')).single.balanceAfter,
          70,
        );
      });

      test('setMain promotes one wallet and demotes the previous one',
          () async {
        final first = await wallet(name: 'الأول');
        final second = await wallet(name: 'الثاني');
        expect(first.isMain, isFalse);

        await wallets.setMain(first.id);
        expect((await wallets.find(first.id))!.isMain, isTrue);

        await wallets.setMain(second.id);
        expect((await wallets.find(first.id))!.isMain, isFalse);
        expect((await wallets.find(second.id))!.isMain, isTrue);
      });

      test('deleting an empty wallet just removes it', () async {
        final w = await wallet(name: 'فارغة');
        await wallets.delete(w.id);
        expect(await wallets.find(w.id), isNull);
      });

      test('deleting a wallet with movements cascades: every movement and '
          'balance is gone', () async {
        final w = await wallet();
        final live = await deposit(w, 1000, '2025-01-10');
        final removed = await withdraw(w, 400, '2025-01-11');
        await movements.delete(removed.id); // soft-deleted, still a row

        await wallets.delete(w.id);

        expect(await wallets.find(w.id), isNull);
        expect(await movements.find(live.id), isNull);
        expect(await movements.find(removed.id), isNull);
        expect(await harness.repository.walletBalancesOf(w.id), isEmpty);
      });

      test(
        'deleting a multi-currency wallet removes every currency\'s '
        'balance and movements',
        () async {
          final w = await wallets.create(
            const WalletDraft(
              name: 'متعددة',
              openings: [
                WalletOpeningDraft(currencyCode: 'SAR'),
                WalletOpeningDraft(currencyCode: 'USD'),
              ],
            ),
          );
          await deposit(w, 100, '2025-01-01', currencyCode: 'SAR');
          await deposit(w, 10, '2025-01-01', currencyCode: 'USD');

          await wallets.delete(w.id);

          expect(await wallets.find(w.id), isNull);
          expect(await harness.repository.walletBalancesOf(w.id), isEmpty);
        },
      );

      test(
        'deleting a wallet that is one side of a transfer removes the '
        'other leg too and recomputes the other wallet',
        () async {
          final a = await wallet(name: 'أ');
          final b = await wallet(name: 'ب');
          await deposit(b, 5000, '2025-01-01');
          await movements.transfer(
            WalletTransferDraft(
              fromWalletId: b.id,
              toWalletId: a.id,
              amountMinor: 1000,
              date: '2025-01-05',
            ),
          );
          expect((await wallets.summary(a.id))!.balanceOf('SAR'), 1000);
          expect((await wallets.summary(b.id))!.balanceOf('SAR'), 4000);

          await wallets.delete(a.id);

          expect(await wallets.find(a.id), isNull);
          // b's own deposit stays; the transfer-out leg is gone too.
          expect((await wallets.summary(b.id))!.balanceOf('SAR'), 5000);
          expect((await ascending(b)).length, 1);
        },
      );
    });

    group('movement rules', () {
      test('a deposit and a withdrawal recompute the running balance',
          () async {
        final w = await wallet(opening: 1000);
        await deposit(w, 500, '2025-01-10');
        await withdraw(w, 200, '2025-01-11');
        expect((await ascending(w)).map((r) => r.balanceAfter), [1500, 1300]);
      });

      test('a withdrawal can take the balance negative', () async {
        final w = await wallet();
        final row = await withdraw(w, 500, '2025-01-10');
        expect(row.balanceAfter, -500);
      });

      test('a back-dated deposit is placed by date and rebalances later rows',
          () async {
        final w = await wallet();
        await deposit(w, 1000, '2025-01-10');
        await deposit(w, 500, '2025-01-01'); // earlier date, inserted after
        expect((await ascending(w)).map((r) => r.balanceAfter), [500, 1500]);
      });

      test('numbers are never reused after a delete', () async {
        final w = await wallet();
        final first = await deposit(w, 100, '2025-01-01');
        final second = await deposit(w, 100, '2025-01-02');
        expect(first.number, 'WTX-000001');
        expect(second.number, 'WTX-000002');
        await movements.delete(second.id);
        final third = await deposit(w, 100, '2025-01-03');
        expect(third.number, 'WTX-000003');
      });

      test('soft delete removes a row from the balance and undo restores it',
          () async {
        final w = await wallet();
        final first = await deposit(w, 1000, '2025-01-01');
        final second = await deposit(w, 500, '2025-01-02');
        await movements.delete(first.id);
        expect((await ascending(w)).single.id, second.id);
        expect((await ascending(w)).single.balanceAfter, 500);

        await movements.restore(first.id);
        expect((await ascending(w)).map((r) => r.balanceAfter), [1000, 1500]);
      });

      test('an archived wallet accepts no new movements', () async {
        final w = await wallet();
        await wallets.setStatus(w.id, WalletStatus.archived);
        expect(
          () => deposit(w, 100, '2025-01-01'),
          throwsA(isA<ConflictException>()),
        );
      });

      test('filters by type and date range', () async {
        final w = await wallet();
        await deposit(w, 1000, '2025-01-05');
        await withdraw(w, 250, '2025-02-05');
        await deposit(w, 7777, '2025-03-05');

        Future<List<int>> amounts(WalletTransactionFilter filter) async =>
            (await harness.repository.walletTransactionPage(
              w.id,
              filter: filter,
              newestFirst: false,
            )).items.map((r) => r.amountMinor).toList();

        expect(
          await amounts(
            const WalletTransactionFilter(type: WalletTransactionType.withdrawal),
          ),
          [250],
        );
        expect(
          await amounts(
            const WalletTransactionFilter(
              fromDate: '2025-02-01',
              toDate: '2025-03-31',
            ),
          ),
          [250, 7777],
        );
      });

      test(
        'walletReportTransactions returns live movements up to a date, '
        'ascending',
        () async {
          final w = await wallet();
          await deposit(w, 1000, '2025-01-05');
          final toDelete = await withdraw(w, 250, '2025-02-05');
          await deposit(w, 7777, '2025-03-05');
          await movements.delete(toDelete.id);

          final all = await harness.repository.walletReportTransactions(w.id);
          expect(all.map((r) => r.amountMinor), [1000, 7777]);

          final upToFeb = await harness.repository.walletReportTransactions(
            w.id,
            toDate: '2025-02-28',
          );
          expect(upToFeb.map((r) => r.amountMinor), [1000]);
        },
      );

      test('keyset paging continues where the previous page ended', () async {
        final w = await wallet();
        for (var day = 1; day <= 5; day++) {
          await deposit(w, 100, '2025-01-0$day');
        }
        final firstPage = await movements.page(w.id, limit: 2, newestFirst: false);
        expect(firstPage.items, hasLength(2));
        expect(firstPage.hasMore, isTrue);
        final secondPage = await movements.page(
          w.id,
          limit: 2,
          newestFirst: false,
          after: firstPage.lastKey,
        );
        expect(secondPage.items, hasLength(2));
        expect(
          secondPage.items.first.date,
          isNot(firstPage.items.last.date),
        );
      });

      test(
        'keyset paging is scoped per currency: neither the balance nor the '
        'cursor leaks across currencies',
        () async {
          final w = await wallets.create(
            const WalletDraft(
              name: 'متعددة',
              openings: [
                WalletOpeningDraft(currencyCode: 'SAR'),
                WalletOpeningDraft(currencyCode: 'USD'),
              ],
            ),
          );
          await deposit(w, 100, '2025-01-01', currencyCode: 'SAR');
          await deposit(w, 10, '2025-01-02', currencyCode: 'USD');
          await deposit(w, 100, '2025-01-03', currencyCode: 'SAR');
          await deposit(w, 10, '2025-01-04', currencyCode: 'USD');

          final sarPage = await movements.page(
            w.id,
            currencyCode: 'SAR',
            newestFirst: false,
          );
          expect(sarPage.items, hasLength(2));
          expect(sarPage.items.map((r) => r.currencyCode), everyElement('SAR'));
          expect(sarPage.items.map((r) => r.balanceAfter), [100, 200]);

          final usdPage = await movements.page(
            w.id,
            currencyCode: 'USD',
            newestFirst: false,
          );
          expect(usdPage.items, hasLength(2));
          expect(usdPage.items.map((r) => r.currencyCode), everyElement('USD'));
          expect(usdPage.items.map((r) => r.balanceAfter), [10, 20]);
        },
      );
    });

    group('transfer rules', () {
      test('rejects a transfer to the same wallet', () async {
        final w = await wallet();
        expect(
          () => movements.transfer(
            WalletTransferDraft(
              fromWalletId: w.id,
              toWalletId: w.id,
              amountMinor: 100,
              date: '2025-01-01',
            ),
          ),
          throwsA(isA<ValidationException>()),
        );
      });

      test(
        'a transfer may cross currencies and records each leg in its own',
        () async {
          final a = await wallet(name: 'أ', currency: 'SAR');
          final b = await wallet(name: 'ب', currency: 'USD');
          await movements.transfer(
            WalletTransferDraft(
              fromWalletId: a.id,
              toWalletId: b.id,
              amountMinor: 37500,
              receivedMinor: 10000,
              date: '2025-01-01',
            ),
          );
          final outgoing = (await ascending(a)).single;
          final incoming = (await ascending(b, currencyCode: 'USD')).single;
          expect(outgoing.currencyCode, 'SAR');
          expect(incoming.currencyCode, 'USD');
          expect(outgoing.amountMinor, 37500);
          expect(incoming.amountMinor, 10000);
          expect(outgoing.legGroupId, incoming.legGroupId);
          expect((await wallets.summary(a.id))!.balanceOf('SAR'), -37500);
          expect((await wallets.summary(b.id))!.balanceOf('USD'), 10000);
        },
      );

      test(
        'a same-currency transfer requires the received amount to match the '
        'sent one',
        () async {
          final a = await wallet(name: 'أ', currency: 'SAR');
          final b = await wallet(name: 'ب', currency: 'SAR');
          expect(
            () => movements.transfer(
              WalletTransferDraft(
                fromWalletId: a.id,
                toWalletId: b.id,
                amountMinor: 100,
                receivedMinor: 90,
                date: '2025-01-01',
              ),
            ),
            throwsA(
              isA<ConflictException>().having(
                (e) => e.code,
                'code',
                'transfer_amount_mismatch',
              ),
            ),
          );
        },
      );

      test('moves money from one wallet to the other, in one write', () async {
        final a = await wallet(name: 'أ', opening: 5000);
        final b = await wallet(name: 'ب');
        await movements.transfer(
          WalletTransferDraft(
            fromWalletId: a.id,
            toWalletId: b.id,
            amountMinor: 2000,
            date: '2025-01-05',
          ),
        );
        expect((await wallets.summary(a.id))!.balanceOf('SAR'), 3000);
        expect((await wallets.summary(b.id))!.balanceOf('SAR'), 2000);
        final outgoing = (await ascending(a)).single;
        final incoming = (await ascending(b)).single;
        expect(outgoing.legGroupId, incoming.legGroupId);
        expect(outgoing.direction, WalletDirection.outgoing);
        expect(incoming.direction, WalletDirection.incoming);
      });

      test('deleting one leg deletes the other and restores both together',
          () async {
        final a = await wallet(name: 'أ', opening: 5000);
        final b = await wallet(name: 'ب');
        await movements.transfer(
          WalletTransferDraft(
            fromWalletId: a.id,
            toWalletId: b.id,
            amountMinor: 2000,
            date: '2025-01-05',
          ),
        );
        final leg = (await ascending(a)).single;

        await movements.delete(leg.id);
        expect((await wallets.summary(a.id))!.balanceOf('SAR'), 5000);
        expect((await wallets.summary(b.id))!.balanceOf('SAR'), 0);

        await movements.restore(leg.id);
        expect((await wallets.summary(a.id))!.balanceOf('SAR'), 3000);
        expect((await wallets.summary(b.id))!.balanceOf('SAR'), 2000);
      });
    });

    group('exchange rules', () {
      test('rejects exchanging a currency into itself', () async {
        final w = await wallet(currency: 'SAR');
        expect(
          () => movements.exchange(
            WalletExchangeDraft(
              walletId: w.id,
              fromCurrencyCode: 'SAR',
              toCurrencyCode: 'sar',
              soldMinor: 100,
              boughtMinor: 100,
              date: '2025-01-01',
            ),
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.code,
              'code',
              'exchange_same_currency',
            ),
          ),
        );
      });

      test(
        'converts between two currencies inside one wallet: two legs, one '
        'group, independent balances',
        () async {
          final w = await wallet(currency: 'SAR', opening: 100000);
          await movements.exchange(
            WalletExchangeDraft(
              walletId: w.id,
              fromCurrencyCode: 'SAR',
              toCurrencyCode: 'USD',
              soldMinor: 37500,
              boughtMinor: 10000,
              date: '2025-01-01',
            ),
          );
          final summary = (await wallets.summary(w.id))!;
          expect(summary.balanceOf('SAR'), 62500);
          expect(summary.balanceOf('USD'), 10000);
          final sold = (await ascending(w)).single;
          final bought = (await ascending(w, currencyCode: 'USD')).single;
          expect(sold.walletId, bought.walletId);
          expect(sold.legGroupId, bought.legGroupId);
          expect(sold.type, WalletTransactionType.exchange);
          expect(sold.direction, WalletDirection.outgoing);
          expect(bought.direction, WalletDirection.incoming);
        },
      );

      test('deleting one leg of an exchange deletes the other, and restore '
          'brings both back', () async {
        final w = await wallet(currency: 'SAR', opening: 100000);
        await movements.exchange(
          WalletExchangeDraft(
            walletId: w.id,
            fromCurrencyCode: 'SAR',
            toCurrencyCode: 'USD',
            soldMinor: 37500,
            boughtMinor: 10000,
            date: '2025-01-01',
          ),
        );
        final sold = (await ascending(w)).single;

        await movements.delete(sold.id);
        var summary = (await wallets.summary(w.id))!;
        expect(summary.balanceOf('SAR'), 100000);
        expect(summary.balanceOf('USD'), 0);

        await movements.restore(sold.id);
        summary = (await wallets.summary(w.id))!;
        expect(summary.balanceOf('SAR'), 62500);
        expect(summary.balanceOf('USD'), 10000);
      });
    });

    group('totals', () {
      test('never mixes currencies and skips archived wallets', () async {
        final sar1 = await wallet(name: 'ص1', currency: 'SAR', opening: 1000);
        final sar2 = await wallet(name: 'ص2', currency: 'SAR', opening: 500);
        final usd = await wallet(name: 'د', currency: 'USD', opening: 200);
        final archived = await wallet(
          name: 'مؤرشفة',
          currency: 'SAR',
          opening: 999999,
        );
        await wallets.setStatus(archived.id, WalletStatus.archived);

        final totals = await harness.repository.walletTotalsByCurrency();
        final sarTotal = totals.singleWhere((t) => t.currencyCode == 'SAR');
        final usdTotal = totals.singleWhere((t) => t.currencyCode == 'USD');
        expect(sarTotal.totalMinor, 1500);
        expect(sarTotal.walletCount, 2);
        expect(usdTotal.totalMinor, 200);
        expect(usdTotal.walletCount, 1);
        expect(
          totals.where((t) => t.totalMinor == 999999),
          isEmpty,
        );
        // Both wallets exist even though only one is asserted on above.
        final sar1Summary = (await wallets.summary(sar1.id))!;
        final sar2Summary = (await wallets.summary(sar2.id))!;
        final usdSummary = (await wallets.summary(usd.id))!;
        expect(sar1Summary.currencies, ['SAR']);
        expect(sar2Summary.currencies, ['SAR']);
        expect(usdSummary.currencies, ['USD']);
      });
    });

    test('a failing write rolls back everything it did', () async {
      final w = await wallet();
      await deposit(w, 1000, '2025-01-01');
      await expectLater(
        harness.repository.write((writer) async {
          await writer.putWallet(
            (await writer.wallet(w.id))!.copyWith(
              name: 'اسم جديد',
              updatedAt: tick.add(const Duration(seconds: 1)),
            ),
          );
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect((await wallets.find(w.id))!.name, w.name);
    });

    test(
      'a write that fails after its first leg leaves neither leg, no new '
      'balance row, and no consumed number — as if it never ran',
      () async {
        final w = await wallets.create(
          const WalletDraft(name: 'متعددة', openings: [WalletOpeningDraft(currencyCode: 'SAR')]),
        );
        final beforeNumber = await harness.repository.write(
          (writer) => writer.nextWalletTransactionNumber(),
        );

        await expectLater(
          harness.repository.write((writer) async {
            final firstLeg = WalletTransaction(
              id: 'attempt-leg-1',
              number: await writer.nextWalletTransactionNumber(),
              walletId: w.id,
              currencyCode: 'SAR',
              type: WalletTransactionType.exchange,
              direction: WalletDirection.outgoing,
              amountMinor: 100,
              legGroupId: 'attempt-group',
              date: '2025-01-01',
              createdAt: tick,
              updatedAt: tick,
            );
            await writer.putWalletTransaction(firstLeg);
            // A new currency's balance row would be created here by the
            // real exchange() before the second leg — simulate that too.
            await writer.putWalletBalance(
              WalletBalance(
                walletId: w.id,
                currencyCode: 'USD',
                createdAt: tick,
                updatedAt: tick,
              ),
            );
            throw StateError('the second leg never got written');
          }),
          throwsStateError,
        );

        expect(await harness.repository.walletTransaction('attempt-leg-1'), isNull);
        final summary = (await wallets.summary(w.id))!;
        expect(summary.currencies, ['SAR']);
        final nextNumber = await harness.repository.write(
          (writer) => writer.nextWalletTransactionNumber(),
        );
        // Exactly one number was consumed by the two write() calls that
        // bracket the failed attempt — the failed attempt's own call to
        // nextWalletTransactionNumber() did not leave a gap either, since
        // its whole transaction (including the counter update) rolled back.
        expect(
          int.parse(nextNumber.split('-').last),
          int.parse(beforeNumber.split('-').last) + 1,
        );
      },
    );

    test('watchers refresh after every write', () async {
      final w = await wallet();
      final iterator = StreamIterator(wallets.watchSummary(w.id));
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current!.balanceOf('SAR'), 0);
      await deposit(w, 1000, '2025-01-01');
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current!.balanceOf('SAR'), 1000);
      await iterator.cancel();
    });
  });
}
