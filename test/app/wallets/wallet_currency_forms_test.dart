import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/wallets/wallet_detail_page.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/features/wallets/wallets.dart';

import '../../support/book_harness.dart';

/// The wallet operation forms (deposit / withdrawal / transfer / exchange)
/// must work with several currencies: their dropdowns always list the value
/// they show — even an archived currency the wallet still holds, which used to
/// fail Flutter's "exactly one item" assertion and turn the page red — and a
/// transfer starts in a currency that needs no exchange rate.
void main() {
  late BookFixture fixture;

  setUp(() async {
    fixture = await BookFixture.create(seed: false);
  });

  tearDown(() => fixture.dispose());

  Future<void> openDetail(WidgetTester tester, String walletId) => pumpBookPage(
    tester,
    WalletDetailPage(book: fixture.book, walletId: walletId),
    size: const Size(390, 2200),
  );

  Future<Wallet> wallet(String name, Map<String, int> holdings) =>
      fixture.book.wallets.create(
        WalletDraft(
          name: name,
          openings: [
            for (final entry in holdings.entries)
              WalletOpeningDraft(
                currencyCode: entry.key,
                openingMinor: entry.value,
              ),
          ],
        ),
      );

  void archive(String code) {
    final registry = fixture.book.currencies;
    registry.upsert(registry.byCode(code).copyWith(isActive: false));
  }

  String? dropdownValue(WidgetTester tester, String key) => tester
      .widget<DropdownButtonFormField<String>>(find.byKey(Key(key)))
      .initialValue;

  Future<void> pick(WidgetTester tester, String key, String code) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(code).last);
    await tester.pumpAndSettle();
  }

  testWidgets('exchange: choosing the sold currency as the bought one does '
      'not crash', (tester) async {
    final w = await wallet('جيب', {'SAR': 10000, 'USD': 10000});
    await openDetail(tester, w.id);
    await tester.tap(find.byKey(const Key('wallet-exchange-button')));
    await tester.pumpAndSettle();

    await pick(tester, 'wtx-to-currency', 'USD');
    expect(dropdownValue(tester, 'wtx-to-currency'), 'USD');

    await pick(tester, 'wtx-from-currency', 'USD');
    expect(tester.takeException(), isNull);
    // Selling and buying the same currency is meaningless: the target resets.
    expect(dropdownValue(tester, 'wtx-to-currency'), isNull);
    expect(dropdownValue(tester, 'wtx-from-currency'), 'USD');
  });

  testWidgets('transfer to a wallet whose currency was archived does not '
      'crash', (tester) async {
    final from = await wallet('من', {'SAR': 50000});
    await wallet('إلى', {'USD': 20000});
    archive('USD');
    await openDetail(tester, from.id);

    await tester.tap(find.byKey(const Key('wallet-transfer-button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The target holds no SAR, so it starts in the currency it holds.
    expect(dropdownValue(tester, 'wtx-to-currency'), 'USD');
    expect(find.byKey(const Key('wtx-rate')), findsOneWidget);
  });

  testWidgets('deposit into a wallet holding an archived currency does not '
      'crash', (tester) async {
    final w = await wallet('جيب', {'USD': 20000});
    archive('USD');
    await openDetail(tester, w.id);

    await tester.tap(find.byKey(const Key('wallet-deposit-button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The wallet's own (archived) currency stays selectable next to the
    // active ones.
    await tester.tap(find.byKey(const Key('wtx-from-currency')));
    await tester.pumpAndSettle();
    expect(find.text('USD'), findsWidgets);
    expect(find.text('YER'), findsWidgets);
  });

  testWidgets('transfer to an empty wallet starts in the sender currency, '
      'without a rate', (tester) async {
    final from = await wallet('من', {'SAR': 50000});
    final target = await fixture.book.wallets.create(
      const WalletDraft(name: 'فارغة'),
    );
    await openDetail(tester, from.id);
    await tester.tap(find.byKey(const Key('wallet-transfer-button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(dropdownValue(tester, 'wtx-to-currency'), 'SAR');
    expect(find.byKey(const Key('wtx-rate')), findsNothing);

    await tester.enterText(find.byKey(const Key('wtx-amount')), '100');
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    final summary = await fixture.book.wallets.summary(target.id);
    expect(summary!.balanceOf('SAR'), 10000);
  });

  testWidgets('transfer prefers the currency both wallets hold over the '
      "target's largest balance", (tester) async {
    final from = await wallet('من', {'SAR': 50000});
    await wallet('إلى', {'SAR': 100, 'YER': 900000});
    await openDetail(tester, from.id);
    await tester.tap(find.byKey(const Key('wallet-transfer-button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(dropdownValue(tester, 'wtx-to-currency'), 'SAR');
    expect(find.byKey(const Key('wtx-rate')), findsNothing);
  });

  testWidgets('the currency being viewed is preselected in the form', (
    tester,
  ) async {
    final w = await wallet('جيب', {'SAR': 50000, 'USD': 20000});
    await openDetail(tester, w.id);

    await tester.tap(find.byKey(const Key('wallet-currency-USD')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wallet-withdraw-button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(dropdownValue(tester, 'wtx-from-currency'), 'USD');
  });

  testWidgets('withdrawal only offers currencies the wallet holds', (
    tester,
  ) async {
    final w = await wallet('جيب', {'SAR': 50000, 'USD': 20000});
    await openDetail(tester, w.id);
    await tester.tap(find.byKey(const Key('wallet-withdraw-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('wtx-from-currency')));
    await tester.pumpAndSettle();
    expect(find.text('YER'), findsNothing);
    expect(find.text('USD'), findsWidgets);
  });

  testWidgets('with a single active currency every form still opens', (
    tester,
  ) async {
    // Wallets holding a currency are created first (a wallet cannot be opened
    // in an archived one), then every currency but SAR is archived — the state
    // of a device whose other currencies were switched off.
    final from = await wallet('من', {'SAR': 50000});
    await wallet('إلى', {'YER': 5000});
    for (final currency in fixture.book.currencies.currencies.toList()) {
      if (currency.code != 'SAR') archive(currency.code);
    }
    await openDetail(tester, from.id);

    for (final key in const [
      'wallet-deposit-button',
      'wallet-withdraw-button',
      'wallet-transfer-button',
      'wallet-exchange-button',
    ]) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: key);
      expect(find.byKey(const Key('save-button')), findsOneWidget, reason: key);
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
    }
  });
}
