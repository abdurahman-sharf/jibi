import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_book_repository.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/book_repository.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/wallets/wallets.dart';
import '../../support/book_wallets.dart';
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
    late CategoriesController categories;
    late BookAccountsController accounts;
    late TransactionsController transactions;
    late WalletsController wallets;
    var sequence = 0;
    var tick = DateTime.utc(2026, 1, 1);

    setUp(() async {
      sequence = 0;
      tick = DateTime.utc(2026, 1, 1);
      harness = await open();
      // Every new transaction is paid through a wallet: the real database
      // seeds the main one, the in-memory repository needs it seeded.
      await seedMainWallet(harness.repository);
      currencies = testCurrencyRegistry();
      String newId() => 'id-${++sequence}';
      DateTime clock() => tick = tick.add(const Duration(seconds: 1));
      categories = CategoriesController(
        repository: harness.repository,
        newId: newId,
        clock: clock,
      );
      accounts = BookAccountsController(
        repository: harness.repository,
        currencies: currencies,
        newId: newId,
        clock: clock,
      );
      transactions = TransactionsController(
        repository: harness.repository,
        currencies: currencies,
        newId: newId,
        clock: clock,
      );
      wallets = WalletsController(
        repository: harness.repository,
        currencies: currencies,
        newId: newId,
        clock: clock,
      );
    });

    tearDown(() => harness.dispose());

    Future<Wallet> wallet({
      String name = 'محفظة الاختبار',
      String currency = 'YER',
    }) => wallets.create(
      WalletDraft.single(name: name, currencyCode: currency),
    );

    Future<BookCategory> category([String name = 'حسابات اليمن']) =>
        categories.create(BookCategoryDraft(name: name));

    Future<BookAccount> account(
      BookCategory category, {
      String name = 'علي أخي',
      String currency = 'YER',
      int opening = 0,
      OpeningType openingType = OpeningType.zero,
    }) => accounts.create(
      BookAccountDraft.single(
        categoryId: category.id,
        name: name,
        currencyCode: currency,
        openingMinor: opening,
        openingType: openingType,
      ),
    );

    Future<BookTransaction> tx(
      BookAccount account,
      EntryType type,
      int amount,
      String date, {
      String time = '00:00',
      String? details,
      String walletId = seededMainWalletId,
      WalletBalanceEffect? walletEffect,
      String currency = 'YER',
    }) => transactions.create(
      BookTransactionDraft(
        accountId: account.id,
        currencyCode: currency,
        type: type,
        amountMinor: amount,
        date: date,
        time: time,
        details: details,
        walletId: walletId,
        walletEffect: walletEffect,
      ),
    );

    Future<List<BookTransaction>> ascending(BookAccount account) async =>
        (await harness.repository.transactionPage(
          account.id,
          newestFirst: false,
          limit: 500,
        )).items;

    Future<void> expectConsistent(BookAccount account) async {
      expect(
        await harness.repository.countBalanceMismatches(account.id),
        0,
        reason: 'stored balance_after must equal the recomputed balance',
      );
    }

    group('running balance', () {
      test('follows debit and credit and numbers every transaction', () async {
        final a = await account(await category());
        await tx(a, EntryType.debit, 10000, '2025-01-01');
        await tx(a, EntryType.credit, 2500, '2025-01-02');
        await tx(a, EntryType.debit, 500, '2025-01-03');

        final rows = await ascending(a);
        expect(rows.map((r) => r.balanceAfter), [10000, 7500, 8000]);
        expect(rows.map((r) => r.number), [
          'TX-000001',
          'TX-000002',
          'TX-000003',
        ]);
        final summary = (await harness.repository.accountSummary(a.id))!;
        final yer = summary.totalsOf('YER')!;
        expect(yer.debitMinor, 10500);
        expect(yer.creditMinor, 2500);
        expect(yer.netMinor, 8000);
        expect(yer.transactionCount, 3);
        expect(yer.side, BalanceSide.debit);
        await expectConsistent(a);
      });

      test('starts from the opening balance on its own side', () async {
        final a = await account(
          await category(),
          opening: 3000,
          openingType: OpeningType.credit,
        );
        await tx(a, EntryType.debit, 1000, '2025-01-01');
        final rows = await ascending(a);
        expect(rows.single.balanceAfter, -2000);
        final totals = (await harness.repository.accountSummary(a.id))!
            .totalsOf('YER')!;
        expect(totals.creditMinor, 3000);
        expect(totals.debitMinor, 1000);
        expect(totals.netMinor, -2000);
        expect(totals.side, BalanceSide.credit);
        await expectConsistent(a);
      });

      test('a back-dated transaction is placed by date and rebalances',
          () async {
        final a = await account(await category());
        await tx(a, EntryType.debit, 100, '2025-01-10');
        await tx(a, EntryType.debit, 300, '2025-01-20');
        final middle = await tx(a, EntryType.credit, 50, '2025-01-15');

        final rows = await ascending(a);
        expect(rows.map((r) => r.date), [
          '2025-01-10',
          '2025-01-15',
          '2025-01-20',
        ]);
        expect(rows.map((r) => r.balanceAfter), [100, 50, 350]);
        // Numbers follow creation, not date.
        expect(middle.number, 'TX-000003');
        await expectConsistent(a);
      });

      test('editing amount, date and type rebalances every later row',
          () async {
        final a = await account(await category());
        final first = await tx(a, EntryType.debit, 100, '2025-01-10');
        final second = await tx(a, EntryType.credit, 50, '2025-01-15');
        final third = await tx(a, EntryType.debit, 300, '2025-01-20');

        BookTransactionDraft draft(
          BookTransaction of, {
          EntryType? type,
          int? amount,
          String? date,
        }) => BookTransactionDraft(
          accountId: a.id,
          currencyCode: 'YER',
          type: type ?? of.type,
          amountMinor: amount ?? of.amountMinor,
          date: date ?? of.date,
          time: of.time,
          walletId: of.walletId,
        );

        await transactions.update(first.id, draft(first, amount: 400));
        expect((await ascending(a)).map((r) => r.balanceAfter), [
          400,
          350,
          650,
        ]);

        await transactions.update(first.id, draft(first, amount: 400, date: '2025-01-25'));
        final moved = await ascending(a);
        expect(moved.map((r) => r.id), [second.id, third.id, first.id]);
        expect(moved.map((r) => r.balanceAfter), [-50, 250, 650]);

        await transactions.update(
          third.id,
          draft(third, type: EntryType.credit),
        );
        expect((await ascending(a)).map((r) => r.balanceAfter), [
          -50,
          -350,
          50,
        ]);
        await expectConsistent(a);
      });

      test('soft delete removes a row from balances and undo restores it',
          () async {
        final a = await account(await category());
        await tx(a, EntryType.debit, 100, '2025-01-10');
        final middle = await tx(a, EntryType.debit, 200, '2025-01-11');
        await tx(a, EntryType.debit, 300, '2025-01-12');

        await transactions.delete(middle.id);
        expect((await ascending(a)).map((r) => r.balanceAfter), [100, 400]);
        var totals = (await harness.repository.accountSummary(a.id))!
            .totalsOf('YER')!;
        expect(totals.debitMinor, 400);
        expect(totals.transactionCount, 2);
        expect((await transactions.find(middle.id))!.isDeleted, isTrue);

        await transactions.restore(middle.id);
        expect((await ascending(a)).map((r) => r.balanceAfter), [
          100,
          300,
          600,
        ]);
        totals = (await harness.repository.accountSummary(a.id))!
            .totalsOf('YER')!;
        expect(totals.transactionCount, 3);
        await expectConsistent(a);
      });

      test('numbers are never reused after a delete', () async {
        final a = await account(await category());
        await tx(a, EntryType.debit, 100, '2025-01-10');
        final second = await tx(a, EntryType.debit, 100, '2025-01-11');
        await transactions.delete(second.id);
        final third = await tx(a, EntryType.debit, 100, '2025-01-12');
        expect(third.number, 'TX-000003');
      });

      test('changing the opening balance rebuilds all balances', () async {
        final c = await category();
        final a = await account(c);
        await tx(a, EntryType.debit, 100, '2025-01-10');
        await tx(a, EntryType.debit, 100, '2025-01-11');
        await accounts.update(
          a.id,
          BookAccountDraft.single(
            categoryId: c.id,
            name: a.name,
            currencyCode: 'YER',
            openingMinor: 1000,
            openingType: OpeningType.debit,
          ),
        );
        expect((await ascending(a)).map((r) => r.balanceAfter), [1100, 1200]);
        await expectConsistent(a);
      });
    });

    group('account rules', () {
      test('rejects unknown or inactive currencies and bad openings',
          () async {
        final c = await category();
        expect(
          () => account(c, currency: 'XXX'),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => accounts.create(
            BookAccountDraft.single(
              categoryId: c.id,
              name: 'x',
              currencyCode: 'YER',
              openingMinor: 10,
            ),
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.code,
              'code',
              'opening_type_required',
            ),
          ),
        );
        expect(
          () => accounts.create(
            BookAccountDraft.single(categoryId: c.id, name: '  ', currencyCode: 'YER'),
          ),
          throwsA(isA<ValidationException>()),
        );
        final zero = await accounts.create(
          BookAccountDraft.single(
            categoryId: c.id,
            name: 'zero',
            currencyCode: 'YER',
            openingMinor: 0,
            openingType: OpeningType.debit,
          ),
        );
        expect(
          (await harness.repository.accountBalancesOf(zero.id)).single.openingType,
          OpeningType.zero,
        );
      });

      test('an account can carry an optional phone number', () async {
        final c = await category();
        final noPhone = await account(c, name: 'no-phone');
        expect(noPhone.phone, isNull);

        final withPhone = await accounts.create(
          BookAccountDraft.single(
            categoryId: c.id,
            name: 'with-phone',
            currencyCode: 'YER',
            phone: ' 0530882752 ',
          ),
        );
        expect(withPhone.phone, '0530882752');

        expect(
          () => accounts.create(
            BookAccountDraft.single(
              categoryId: c.id,
              name: 'bad-phone',
              currencyCode: 'YER',
              phone: 'abc',
            ),
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.code,
              'code',
              'invalid_phone',
            ),
          ),
        );

        final cleared = await accounts.update(
          withPhone.id,
          BookAccountDraft(categoryId: c.id, name: withPhone.name),
        );
        expect(cleared.phone, isNull);
      });

      test('deleting an empty account just removes it', () async {
        final c = await category();
        final empty = await account(c, name: 'empty');
        await accounts.delete(empty.id);
        expect(await accounts.find(empty.id), isNull);
      });

      test(
        'deleting an account with transactions cascades: transactions, '
        'their attachments and the account itself are all gone',
        () async {
          final c = await category();
          final used = await account(c, name: 'used');
          final live = await tx(used, EntryType.debit, 100, '2025-01-10');
          final deleted = await tx(used, EntryType.credit, 40, '2025-01-11');
          await transactions.delete(deleted.id); // soft-deleted, still rows
          await harness.repository.write((writer) async {
            await writer.putAttachment(
              BookAttachment(
                id: 'att-cascade',
                transactionId: live.id,
                fileName: 'سند.jpg',
                mimeType: 'image/jpeg',
                encryptedFileName: 'cascade.enc',
                checksum: 'abc',
                createdAt: DateTime.utc(2026),
              ),
            );
          });

          await accounts.delete(used.id);

          expect(await accounts.find(used.id), isNull);
          expect(await harness.repository.transaction(live.id), isNull);
          expect(await harness.repository.transaction(deleted.id), isNull);
        },
      );

      test(
        'deleting an account with a wallet-linked transaction removes the '
        'linked movement too and recomputes the wallet balance',
        () async {
          final w = await wallet();
          final c = await category();
          final used = await account(c, name: 'used');
          await tx(
            used,
            EntryType.debit,
            500,
            '2025-01-10',
            walletId: w.id,
            walletEffect: WalletBalanceEffect.decrease,
          );
          expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), -500);

          await accounts.delete(used.id);

          expect(await accounts.find(used.id), isNull);
          final summary = (await harness.repository.walletSummary(w.id))!;
          expect(summary.balanceOf('YER'), 0);
          expect(summary.transactionCount, 0);
        },
      );

      test('a transaction cannot move to another account', () async {
        final c = await category();
        final a = await account(c, name: 'a');
        final b = await account(c, name: 'b');
        final row = await tx(a, EntryType.debit, 100, '2025-01-10');
        expect(
          () => transactions.update(
            row.id,
            BookTransactionDraft(
              accountId: b.id,
              currencyCode: 'YER',
              type: EntryType.debit,
              amountMinor: 100,
              date: '2025-01-10',
            ),
          ),
          throwsA(isA<ValidationException>()),
        );
      });

      test('rejects invalid amounts and dates', () async {
        final a = await account(await category());
        expect(
          () => tx(a, EntryType.debit, 0, '2025-01-10'),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => tx(a, EntryType.debit, 5, '2025-02-30'),
          throwsA(isA<ValidationException>()),
        );
      });
    });

    group('category rules', () {
      test('names are unique, deactivating hides but keeps data', () async {
        final c = await category('التصنيف');
        expect(
          () => category('  التصنيف '),
          throwsA(isA<ConflictException>()),
        );
        final a = await account(c);
        await tx(a, EntryType.debit, 100, '2025-01-10');

        await categories.setActive(c.id, isActive: false);
        expect(await harness.repository.categorySummaries(), isEmpty);
        expect(
          await harness.repository.categorySummaries(includeInactive: true),
          hasLength(1),
        );
        expect(await harness.repository.netPosition(), isEmpty);
        expect(await harness.repository.recentTransactions(), isEmpty);
        expect(
          () => account(c, name: 'new'),
          throwsA(
            isA<ConflictException>().having(
              (e) => e.code,
              'code',
              'category_inactive',
            ),
          ),
        );
        // Data is intact and the account is still readable.
        expect(
          (await harness.repository.accountSummary(a.id))!
              .totalsOf('YER')!
              .debitMinor,
          100,
        );

        await categories.setActive(c.id, isActive: true);
        expect(await harness.repository.categorySummaries(), hasLength(1));
      });

      test('deleting an empty category just removes it', () async {
        final empty = await category('فارغ');
        await categories.delete(empty.id);
        expect(await categories.find(empty.id), isNull);
      });

      test(
        'deleting a category with accounts cascades: accounts, their '
        'transactions and the category itself are all gone',
        () async {
          final c = await category();
          final a = await account(c, name: 'a');
          final b = await account(c, name: 'b');
          final rowA = await tx(a, EntryType.debit, 100, '2025-01-10');
          final rowB = await tx(b, EntryType.credit, 50, '2025-01-11');

          await categories.delete(c.id);

          expect(await categories.find(c.id), isNull);
          expect(await accounts.find(a.id), isNull);
          expect(await accounts.find(b.id), isNull);
          expect(await harness.repository.transaction(rowA.id), isNull);
          expect(await harness.repository.transaction(rowB.id), isNull);
        },
      );

      test(
        'deleting a category cascades wallet-linked transactions across '
        'every one of its accounts and recomputes each affected wallet',
        () async {
          final w = await wallet();
          final c = await category();
          final a = await account(c, name: 'a');
          final b = await account(c, name: 'b');
          await tx(
            a,
            EntryType.debit,
            200,
            '2025-01-10',
            walletId: w.id,
            walletEffect: WalletBalanceEffect.decrease,
          );
          await tx(
            b,
            EntryType.credit,
            300,
            '2025-01-11',
            walletId: w.id,
            walletEffect: WalletBalanceEffect.increase,
          );
          expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), 100);

          await categories.delete(c.id);

          expect(await categories.find(c.id), isNull);
          final summary = (await harness.repository.walletSummary(w.id))!;
          expect(summary.balanceOf('YER'), 0);
          expect(summary.transactionCount, 0);
        },
      );

      test('reorder persists the display order', () async {
        final first = await category('أ');
        final second = await category('ب');
        await categories.reorder([second.id, first.id]);
        final names = (await harness.repository.categorySummaries())
            .map((s) => s.category.name)
            .toList();
        expect(names, ['ب', 'أ']);
      });
    });

    group('wallet link', () {
      Future<WalletTransaction?> linkOf(String bookTransactionId) =>
          harness.repository.write(
            (writer) =>
                writer.walletTransactionForBookTransaction(bookTransactionId),
          );

      test(
        'creating a transaction with a wallet creates a matching linked '
        'movement and moves the wallet balance',
        () async {
          final w = await wallet();
          final a = await account(await category());
          final row = await tx(
            a,
            EntryType.debit,
            500,
            '2025-01-10',
            walletId: w.id,
            walletEffect: WalletBalanceEffect.decrease,
          );
          final link = await linkOf(row.id);
          expect(link, isNotNull);
          expect(link!.type, WalletTransactionType.linked);
          expect(link.direction, WalletDirection.outgoing);
          expect(link.amountMinor, 500);
          expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), -500);
        },
      );

      test('an "increase" effect moves the wallet balance up', () async {
        final w = await wallet();
        final a = await account(await category());
        await tx(
          a,
          EntryType.credit,
          500,
          '2025-01-10',
          walletId: w.id,
          walletEffect: WalletBalanceEffect.increase,
        );
        expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), 500);
      });

      test(
        'editing only the amount on the same wallet and effect updates the '
        'existing linked row instead of replacing it',
        () async {
          final w = await wallet();
          final a = await account(await category());
          final row = await tx(
            a,
            EntryType.debit,
            500,
            '2025-01-10',
            walletId: w.id,
            walletEffect: WalletBalanceEffect.decrease,
          );
          final before = await linkOf(row.id);
          await transactions.update(
            row.id,
            BookTransactionDraft(
              accountId: a.id,
              currencyCode: 'YER',
              type: EntryType.debit,
              amountMinor: 700,
              date: '2025-01-10',
              walletId: w.id,
              walletEffect: WalletBalanceEffect.decrease,
            ),
          );
          final after = await linkOf(row.id);
          expect(after!.id, before!.id);
          expect(after.amountMinor, 700);
          expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), -700);
        },
      );

      test(
        'moving a transaction to another wallet detaches the old link and '
        'recomputes both wallets',
        () async {
          final w1 = await wallet(name: 'محفظة 1');
          final w2 = await wallet(name: 'محفظة 2');
          final a = await account(await category());
          final row = await tx(
            a,
            EntryType.debit,
            500,
            '2025-01-10',
            walletId: w1.id,
            walletEffect: WalletBalanceEffect.decrease,
          );
          await transactions.update(
            row.id,
            BookTransactionDraft(
              accountId: a.id,
              currencyCode: 'YER',
              type: EntryType.debit,
              amountMinor: 500,
              date: '2025-01-10',
              walletId: w2.id,
              walletEffect: WalletBalanceEffect.decrease,
            ),
          );
          final w1Summary = (await harness.repository.walletSummary(w1.id))!;
          expect(w1Summary.balanceOf('YER'), 0);
          expect(w1Summary.transactionCount, 0);
          expect((await harness.repository.walletSummary(w2.id))!.balanceOf('YER'), -500);
        },
      );

      test(
        'flipping the effect direction on the same wallet detaches and '
        'reattaches the link',
        () async {
          final w = await wallet();
          final a = await account(await category());
          final row = await tx(
            a,
            EntryType.debit,
            500,
            '2025-01-10',
            walletId: w.id,
            walletEffect: WalletBalanceEffect.decrease,
          );
          await transactions.update(
            row.id,
            BookTransactionDraft(
              accountId: a.id,
              currencyCode: 'YER',
              type: EntryType.debit,
              amountMinor: 500,
              date: '2025-01-10',
              walletId: w.id,
              walletEffect: WalletBalanceEffect.increase,
            ),
          );
          expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), 500);
        },
      );

      test('a linked transaction cannot lose its payment method', () async {
        final w = await wallet();
        final a = await account(await category());
        final row = await tx(
          a,
          EntryType.debit,
          500,
          '2025-01-10',
          walletId: w.id,
          walletEffect: WalletBalanceEffect.decrease,
        );
        await expectLater(
          transactions.update(
            row.id,
            BookTransactionDraft(
              accountId: a.id,
              currencyCode: 'YER',
              type: EntryType.debit,
              amountMinor: 500,
              date: '2025-01-10',
            ),
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.code,
              'code',
              'payment_wallet_required',
            ),
          ),
        );
        // Nothing changed: still linked, the wallet still carries the effect.
        expect((await transactions.find(row.id))!.walletId, w.id);
        expect(await linkOf(row.id), isNotNull);
        expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), -500);
      });

      test(
        'deleting a transaction soft-deletes its linked movement and '
        'restoring it brings both back',
        () async {
          final w = await wallet();
          final a = await account(await category());
          final row = await tx(
            a,
            EntryType.debit,
            500,
            '2025-01-10',
            walletId: w.id,
            walletEffect: WalletBalanceEffect.decrease,
          );

          await transactions.delete(row.id);
          expect((await linkOf(row.id))!.isDeleted, isTrue);
          expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), 0);

          await transactions.restore(row.id);
          expect((await linkOf(row.id))!.isDeleted, isFalse);
          expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), -500);
        },
      );

      test(
        'linking to a wallet that does not hold the currency is refused and '
        'creates nothing in it',
        () async {
          final w = await wallet(currency: 'SAR');
          final a = await account(await category(), currency: 'YER');
          await expectLater(
            tx(
              a,
              EntryType.debit,
              500,
              '2025-01-10',
              walletId: w.id,
              walletEffect: WalletBalanceEffect.decrease,
            ),
            throwsA(
              isA<ValidationException>().having(
                (e) => e.code,
                'code',
                'wallet_currency_unsupported',
              ),
            ),
          );
          // Nothing was saved and the wallet did not gain a YER balance.
          expect(await ascending(a), isEmpty);
          final summary = (await harness.repository.walletSummary(w.id))!;
          expect(summary.currencies, ['SAR']);
          expect(summary.balanceOf('SAR'), 0);
        },
      );

      test('linking to an archived wallet is rejected', () async {
        final w = await wallet();
        await wallets.setStatus(w.id, WalletStatus.archived);
        final a = await account(await category());
        expect(
          () => tx(
            a,
            EntryType.debit,
            500,
            '2025-01-10',
            walletId: w.id,
            walletEffect: WalletBalanceEffect.decrease,
          ),
          throwsA(
            isA<ConflictException>().having(
              (e) => e.code,
              'code',
              'wallet_archived',
            ),
          ),
        );
      });

      test('the wallet effect follows the type when none is given', () async {
        final w = await wallet();
        final a = await account(await category());
        final out = await tx(a, EntryType.debit, 500, '2025-01-10', walletId: w.id);
        final into = await tx(a, EntryType.credit, 200, '2025-01-11', walletId: w.id);
        expect(out.walletEffect, WalletBalanceEffect.decrease);
        expect(into.walletEffect, WalletBalanceEffect.increase);
        expect((await harness.repository.walletSummary(w.id))!.balanceOf('YER'), -300);
      });

      test('a wallet link without an effect is not a valid transaction', () {
        final at = DateTime.utc(2026);
        expect(
          () => BookTransaction(
            id: 't',
            number: 'TX-000001',
            accountId: 'a',
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 1,
            date: '2025-01-10',
            walletId: 'w',
            createdAt: at,
            updatedAt: at,
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.code,
              'code',
              'wallet_effect_required',
            ),
          ),
        );
      });
    });

    group('the payment method is a wallet', () {
      Future<int> balance(String walletId, [String code = 'YER']) async =>
          (await harness.repository.walletSummary(walletId))!.balanceOf(code);

      /// A transaction as an older version left it: no wallet, no effect.
      Future<BookTransaction> legacy(BookAccount a, int amount) async {
        final at = DateTime.utc(2020);
        final number = ++sequence;
        final row = BookTransaction(
          id: 'legacy-$number',
          number: 'TX-9${number.toString().padLeft(5, '0')}',
          accountId: a.id,
          currencyCode: 'YER',
          type: EntryType.debit,
          amountMinor: amount,
          date: '2020-01-01',
          createdAt: at,
          updatedAt: at,
        );
        await harness.repository.write((writer) async {
          await writer.putTransaction(row);
          await BookBalanceEngine.recomputeAccount(writer, a.id);
        });
        return row;
      }

      BookTransactionDraft draftOf(
        BookAccount a,
        BookTransaction row, {
        String? walletId,
        int? amount,
        EntryType? type,
      }) => BookTransactionDraft(
        accountId: a.id,
        currencyCode: 'YER',
        type: type ?? row.type,
        amountMinor: amount ?? row.amountMinor,
        date: row.date,
        time: row.time,
        walletId: walletId,
      );

      test('a transaction cannot be created without one', () async {
        final a = await account(await category());
        await expectLater(
          transactions.create(
            BookTransactionDraft(
              accountId: a.id,
              currencyCode: 'YER',
              type: EntryType.debit,
              amountMinor: 500,
              date: '2025-01-10',
            ),
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.code,
              'code',
              'payment_wallet_required',
            ),
          ),
        );
        expect(await ascending(a), isEmpty);
        expect(await balance(seededMainWalletId), 0);
      });

      test('نقدًا is the main wallet: its balance moves, no other does', () async {
        final other = await wallet(name: 'محفظة جيب');
        final a = await account(await category());
        final out = await tx(a, EntryType.debit, 500, '2025-01-10');
        expect(out.walletId, seededMainWalletId);
        expect(await balance(seededMainWalletId), -500);

        await tx(a, EntryType.credit, 200, '2025-01-11');
        expect(await balance(seededMainWalletId), -300);
        expect(await balance(other.id), 0);
        final main = (await wallets.find(seededMainWalletId))!;
        expect(main.isMain, isTrue);
        expect(main.paymentLabel, 'نقدًا');
      });

      test('another wallet moves only its own balance and reads as its name',
          () async {
        final box = await wallet(name: 'حساب الراجحي');
        final a = await account(await category());
        await tx(a, EntryType.debit, 500, '2025-01-10', walletId: box.id);
        expect(await balance(box.id), -500);
        expect(await balance(seededMainWalletId), 0);
        expect(box.paymentLabel, 'حساب الراجحي');
      });

      test('money out lowers the chosen wallet and money in raises it', () async {
        final box = await wallet(name: 'محفظة كاش');
        final a = await account(await category());
        await tx(a, EntryType.debit, 900, '2025-01-10', walletId: box.id);
        await tx(a, EntryType.credit, 400, '2025-01-11', walletId: box.id);
        expect(await balance(box.id), -500);
        expect(await ascending(a), hasLength(2));
      });

      test(
        'changing the payment between wallets reverses the old effect and '
        'applies the new one',
        () async {
          final first = await wallet(name: 'محفظة جيب');
          final second = await wallet(name: 'حساب الراجحي');
          final a = await account(await category());
          final row = await tx(a, EntryType.debit, 500, '2025-01-10');
          expect(await balance(seededMainWalletId), -500);

          var current = await transactions.update(
            row.id,
            draftOf(a, row, walletId: first.id),
          );
          expect(await balance(seededMainWalletId), 0);
          expect(await balance(first.id), -500);
          expect(current.walletId, first.id);

          current = await transactions.update(
            row.id,
            draftOf(a, current, walletId: second.id),
          );
          expect(await balance(first.id), 0);
          expect(await balance(second.id), -500);

          // …and back to نقدًا.
          await transactions.update(
            row.id,
            draftOf(a, current, walletId: seededMainWalletId),
          );
          expect(await balance(second.id), 0);
          expect(await balance(seededMainWalletId), -500);
          await expectConsistent(a);
        },
      );

      test('changing the type flips the effect on the same wallet', () async {
        final a = await account(await category());
        final row = await tx(a, EntryType.debit, 500, '2025-01-10');
        expect(await balance(seededMainWalletId), -500);
        await transactions.update(
          row.id,
          draftOf(a, row, walletId: seededMainWalletId, type: EntryType.credit),
        );
        expect(await balance(seededMainWalletId), 500);
      });

      test('deleting and restoring a transaction reverses and restores the effect',
          () async {
        final box = await wallet(name: 'محفظة جيب');
        final a = await account(await category());
        final viaCash = await tx(a, EntryType.debit, 500, '2025-01-10');
        final viaBox = await tx(
          a,
          EntryType.credit,
          300,
          '2025-01-11',
          walletId: box.id,
        );
        expect(await balance(seededMainWalletId), -500);
        expect(await balance(box.id), 300);

        await transactions.delete(viaCash.id);
        expect(await balance(seededMainWalletId), 0);
        expect(await balance(box.id), 300);

        await transactions.delete(viaBox.id);
        expect(await balance(box.id), 0);

        await transactions.restore(viaCash.id);
        await transactions.restore(viaBox.id);
        expect(await balance(seededMainWalletId), -500);
        expect(await balance(box.id), 300);
      });

      test(
        'a transaction from before wallets were linked changes no balance, '
        'whatever is done to it',
        () async {
          final box = await wallet(name: 'محفظة جيب');
          final a = await account(await category());
          final old = await legacy(a, 700);
          final paid = await tx(a, EntryType.debit, 100, '2025-01-10');
          expect(await balance(seededMainWalletId), -100);
          expect(await balance(box.id), 0);

          // Edited without choosing a payment: stays unlinked, moves nothing.
          final edited = await transactions.update(
            old.id,
            draftOf(a, old, amount: 900),
          );
          expect(edited.walletId, isNull);
          expect(edited.walletEffect, isNull);

          await transactions.delete(old.id);
          await transactions.restore(old.id);
          expect(await balance(seededMainWalletId), -100);
          expect(await balance(box.id), 0);
          // The account balance still follows the book.
          expect((await ascending(a)).map((r) => r.balanceAfter), [900, 1000]);
          expect(paid.walletId, seededMainWalletId);
          await expectConsistent(a);
        },
      );

      test('choosing a payment for an old transaction links it from then on',
          () async {
        final a = await account(await category());
        final old = await legacy(a, 700);
        expect(await balance(seededMainWalletId), 0);

        await transactions.update(
          old.id,
          draftOf(a, old, walletId: seededMainWalletId),
        );
        expect(await balance(seededMainWalletId), -700);
        expect((await transactions.find(old.id))!.walletId, seededMainWalletId);
      });

      test('the payment is a filter: نقدًا or one wallet', () async {
        final box = await wallet(name: 'محفظة جيب');
        final a = await account(await category());
        await tx(a, EntryType.debit, 100, '2025-01-10');
        await tx(a, EntryType.debit, 200, '2025-01-11', walletId: box.id);
        await tx(a, EntryType.debit, 300, '2025-01-12', walletId: box.id);
        final cash = await harness.repository.transactionPage(
          a.id,
          filter: const BookTransactionFilter(walletId: seededMainWalletId),
          newestFirst: false,
        );
        final boxed = await harness.repository.transactionPage(
          a.id,
          filter: BookTransactionFilter(walletId: box.id),
          newestFirst: false,
        );
        expect(cash.items.map((r) => r.amountMinor), [100]);
        expect(boxed.items.map((r) => r.amountMinor), [200, 300]);
        expect(BookTransactionFilter.none.isEmpty, isTrue);
        expect(BookTransactionFilter(walletId: box.id).isEmpty, isFalse);
      });

      test(
        'deleting a wallet keeps the transactions paid through it, unlinked, '
        'with their account balances untouched',
        () async {
          final box = await wallet(name: 'محفظة جيب');
          final a = await account(await category());
          final viaBox = await tx(a, EntryType.debit, 500, '2025-01-10', walletId: box.id);
          final viaCash = await tx(a, EntryType.debit, 100, '2025-01-11');

          await wallets.delete(box.id);

          expect(await wallets.find(box.id), isNull);
          final kept = (await transactions.find(viaBox.id))!;
          expect(kept.walletId, isNull);
          expect(kept.walletEffect, isNull);
          expect(kept.isDeleted, isFalse);
          expect((await ascending(a)).map((r) => r.balanceAfter), [500, 600]);
          expect(await balance(seededMainWalletId), -100);
          expect((await transactions.find(viaCash.id))!.walletId, seededMainWalletId);
          await expectConsistent(a);
        },
      );

      test('deleting the main wallet does not fail on its transactions', () async {
        final a = await account(await category());
        final row = await tx(a, EntryType.debit, 500, '2025-01-10');

        await wallets.delete(seededMainWalletId);

        expect(await wallets.find(seededMainWalletId), isNull);
        expect((await transactions.find(row.id))!.walletId, isNull);
        expect((await ascending(a)).single.balanceAfter, 500);
      });
    });

    group('totals never mix currencies', () {
      test('category and net position group by currency', () async {
        final c = await category();
        final yer = await account(c, name: 'y', currency: 'YER');
        final sar = await account(c, name: 's', currency: 'SAR');
        final archived = await account(c, name: 'old', currency: 'YER');
        await tx(yer, EntryType.debit, 500, '2025-01-01');
        await tx(yer, EntryType.credit, 200, '2025-01-02');
        await tx(sar, EntryType.debit, 10000, '2025-01-03', currency: 'SAR');
        await tx(archived, EntryType.debit, 9999, '2025-01-04');
        await accounts.setStatus(archived.id, BookAccountStatus.archived);

        final summary = (await harness.repository.categorySummaries()).single;
        expect(summary.accountCount, 2);
        expect(summary.totals.map((t) => t.currencyCode), ['SAR', 'YER']);
        final yerTotals = summary.totals.last;
        expect(yerTotals.debitMinor, 500);
        expect(yerTotals.creditMinor, 200);
        expect(yerTotals.netMinor, 300);
        expect(summary.totals.first.netMinor, 10000);

        final position = await harness.repository.netPosition();
        expect(position.map((t) => t.currencyCode), ['SAR', 'YER']);
        expect(position.last.netMinor, 300);
        // Gross sums (like the accounts tab): the credit side is not netted
        // away against the debit side of the same account.
        expect(position.last.debitMinor, 500);
        expect(position.last.creditMinor, 200);
      });
    });

    group('listing', () {
      test('keyset pages continue where the previous page ended', () async {
        final a = await account(await category());
        for (var day = 1; day <= 5; day++) {
          await tx(a, EntryType.debit, day * 10, '2025-01-0$day');
        }
        final first = await harness.repository.transactionPage(a.id, limit: 2);
        expect(first.items.map((r) => r.amountMinor), [50, 40]);
        expect(first.hasMore, isTrue);
        final second = await harness.repository.transactionPage(
          a.id,
          limit: 2,
          after: first.lastKey,
        );
        expect(second.items.map((r) => r.amountMinor), [30, 20]);
        final third = await harness.repository.transactionPage(
          a.id,
          limit: 2,
          after: second.lastKey,
        );
        expect(third.items.map((r) => r.amountMinor), [10]);
        expect(third.hasMore, isFalse);

        final oldest = await harness.repository.transactionPage(
          a.id,
          limit: 2,
          newestFirst: false,
        );
        expect(oldest.items.map((r) => r.amountMinor), [10, 20]);
        final next = await harness.repository.transactionPage(
          a.id,
          limit: 2,
          newestFirst: false,
          after: oldest.lastKey,
        );
        expect(next.items.map((r) => r.amountMinor), [30, 40]);
      });

      test('same-day rows are ordered by time then creation', () async {
        final a = await account(await category());
        await tx(a, EntryType.debit, 1, '2025-01-05', time: '18:00');
        await tx(a, EntryType.debit, 2, '2025-01-05', time: '08:00');
        await tx(a, EntryType.debit, 3, '2025-01-05', time: '08:00');
        expect((await ascending(a)).map((r) => r.amountMinor), [2, 3, 1]);
        await expectConsistent(a);
      });

      test('filters by type, dates, amounts, text and attachments', () async {
        final a = await account(await category());
        final debit = await tx(
          a,
          EntryType.debit,
          1000,
          '2025-01-05',
          details: 'يوم موت أبي',
        );
        await tx(a, EntryType.credit, 250, '2025-02-05', details: 'سداد');
        await tx(a, EntryType.debit, 7777, '2025-03-05');
        await harness.repository.write((writer) async {
          await writer.putAttachment(
            BookAttachment(
              id: 'att-1',
              transactionId: debit.id,
              fileName: 'سند.jpg',
              mimeType: 'image/jpeg',
              encryptedFileName: 'a.enc',
              checksum: 'abc',
              createdAt: DateTime.utc(2026),
            ),
          );
        });

        Future<List<int>> amounts(BookTransactionFilter filter) async =>
            (await harness.repository.transactionPage(
              a.id,
              filter: filter,
              newestFirst: false,
            )).items.map((r) => r.amountMinor).toList();

        expect(await amounts(const BookTransactionFilter(type: EntryType.credit)), [250]);
        expect(
          await amounts(
            const BookTransactionFilter(
              fromDate: '2025-02-01',
              toDate: '2025-03-31',
            ),
          ),
          [250, 7777],
        );
        expect(
          await amounts(
            const BookTransactionFilter(minAmountMinor: 500, maxAmountMinor: 2000),
          ),
          [1000],
        );
        expect(await amounts(const BookTransactionFilter(text: 'موت')), [1000]);
        expect(await amounts(const BookTransactionFilter(text: 'TX-000002')), [250]);
        expect(await amounts(const BookTransactionFilter(text: '2025-03')), [7777]);
        expect(
          await amounts(
            const BookTransactionFilter(
              text: '7.777',
              textAmountsMinor: {'YER': 7777},
            ),
          ),
          [7777],
        );
        expect(await amounts(const BookTransactionFilter(text: '%')), isEmpty);
        expect(
          await amounts(const BookTransactionFilter(withAttachments: true)),
          [1000],
        );

        final totals = await harness.repository.filteredTotals(
          a.id,
          filter: const BookTransactionFilter(fromDate: '2025-02-01'),
        );
        expect(totals.single.currencyCode, 'YER');
        expect(totals.single.debitMinor, 7777);
        expect(totals.single.creditMinor, 250);
        expect(totals.single.transactionCount, 2);

        final loaded = (await harness.repository.transaction(debit.id))!;
        expect(loaded.attachments.single.fileName, 'سند.jpg');
      });
    });

    test('a failing write rolls back everything it did', () async {
      final c = await category('باقٍ');
      await expectLater(
        harness.repository.write((writer) async {
          final now = DateTime.utc(2026);
          await writer.putCategory(
            BookCategory(
              id: 'ghost',
              name: 'شبح',
              createdAt: now,
              updatedAt: now,
            ),
          );
          await writer.putAccount(
            BookAccount(
              id: 'ghost-account',
              categoryId: c.id,
              name: 'x',
              createdAt: now,
              updatedAt: now,
            ),
          );
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(await harness.repository.category('ghost'), isNull);
      expect(await harness.repository.account('ghost-account'), isNull);
      expect(await harness.repository.category(c.id), isNotNull);
    });

    test('watchers refresh after every write', () async {
      final iterator = StreamIterator(categories.watchSummaries());
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, isEmpty);
      await category('جديد');
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.single.category.name, 'جديد');
      await iterator.cancel();
    });
  });
}
