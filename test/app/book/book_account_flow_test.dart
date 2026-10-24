import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/book/book_account_page.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/platform/external_link_launcher.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/wallets/wallets.dart';

import '../../support/book_harness.dart';

/// A launcher that records what it is asked and always says it opened.
class _FakeLauncher implements ExternalLinkLauncher {
  final List<(String, Map<String, Object?>)> calls = [];

  Future<bool> _answer(String name, Map<String, Object?> arguments) async {
    calls.add((name, arguments));
    return true;
  }

  @override
  Future<bool> openWhatsApp({required String phone, required String message}) =>
      _answer('whatsapp', {'phone': phone, 'message': message});

  @override
  Future<bool> dial(String phone) => _answer('dial', {'phone': phone});

  @override
  Future<bool> composeEmail({
    required String to,
    required String subject,
    required String body,
  }) => _answer('email', {'to': to, 'subject': subject, 'body': body});

  @override
  Future<bool> openWebsite(Uri url) => _answer('website', {'url': '$url'});
}

Future<List<BookTransaction>> _rows(BookFixture f, BookAccount a) async =>
    (await f.book.repository.transactionPage(
      a.id,
      newestFirst: false,
      limit: 500,
    )).items;

Finder _row(BookTransaction t) => find.byKey(Key('tx-row-${t.id}'));

Future<void> _openStatement(
  WidgetTester tester,
  BookFixture fixture,
  BookAccount account,
) => pumpBookPage(
  tester,
  BookAccountPage(book: fixture.book, accountId: account.id),
);

/// Scrolls the transaction form until its payment section is on screen and
/// its wallets have loaded.
Future<void> _showPayment(WidgetTester tester) async {
  await tester.dragUntilVisible(
    find.byKey(const Key('tx-payment-method')),
    find.byType(ListView),
    const Offset(0, -300),
    maxIteration: 50,
  );
  await tester.pumpAndSettle();
}

/// The labels of the payment chips, in the order they are shown.
List<String> _paymentChipLabels(WidgetTester tester) => [
  for (final chip in tester.widgetList<ChoiceChip>(
    find.descendant(
      of: find.byKey(const Key('tx-payment-method')),
      matching: find.byType(ChoiceChip),
    ),
  ))
    (chip.label as Text).data!,
];

/// The transaction form grew taller once payment method and wallet fields
/// were added, so the save button can now sit past the list view's initial
/// build range and needs a scroll to reach it.
Future<void> _tapSave(WidgetTester tester) async {
  await tester.dragUntilVisible(
    find.byKey(const Key('save-button')),
    find.byType(ListView),
    const Offset(0, -300),
    maxIteration: 50,
  );
  await tester.pumpAndSettle();
  // The form grew (currency chips): make sure the button is fully on screen.
  await tester.ensureVisible(find.byKey(const Key('save-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('save-button')));
}

void main() {
  group('statement', () {
    testWidgets('shows the balance, the table and the pinned totals', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openStatement(tester, fixture, fixture.ali);

      // Info card.
      expect(
        find.descendant(
          of: find.byKey(const Key('statement-balance')),
          matching: find.text('30,100'),
        ),
        findsOneWidget,
      );
      expect(find.text('حسابات اليمن'), findsOneWidget);
      // Table header and both rows, newest first.
      for (final title in ['التاريخ', 'المبلغ', 'التفاصيل', 'الرصيد']) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.text('2026-09-20'), findsOneWidget);
      expect(find.text('2024-12-13'), findsOneWidget);
      expect(find.text('#TX-000002'), findsOneWidget);
      expect(find.text('#TX-000001'), findsOneWidget);
      expect(find.text('سداد جزئي'), findsOneWidget);
      expect(find.text('العمليات: 2'), findsOneWidget);
      final newest = tester.getTopLeft(find.text('#TX-000002')).dy;
      final oldest = tester.getTopLeft(find.text('#TX-000001')).dy;
      expect(newest, lessThan(oldest));

      // Pinned totals: debit, net with its side, credit.
      expect(
        find.descendant(
          of: find.byKey(const Key('total-debit')),
          matching: find.text('YER 30,100'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('30,100 مدين'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('total-credit')),
          matching: find.text('YER 0'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the sort button reverses the order', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openStatement(tester, fixture, fixture.ali);

      await tester.tap(find.byKey(const Key('statement-sort')));
      await tester.pumpAndSettle();
      expect(find.text('الأقدم أولاً'), findsOneWidget);
      final first = tester.getTopLeft(find.text('#TX-000001')).dy;
      final second = tester.getTopLeft(find.text('#TX-000002')).dy;
      expect(first, lessThan(second));
    });

    testWidgets('an account without transactions shows the empty state', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openStatement(tester, fixture, fixture.osama);

      expect(find.text('لا توجد عمليات لهذا الحساب'), findsOneWidget);
      expect(find.text('إضافة أول عملية'), findsOneWidget);
    });

    testWidgets('the account phone number offers call and WhatsApp', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await fixture.book.accounts.update(
        fixture.ali.id,
        BookAccountDraft(
          categoryId: fixture.category.id,
          name: fixture.ali.name,
          phone: '0530882752',
        ),
      );
      final launcher = _FakeLauncher();
      await pumpBookPage(
        tester,
        BookAccountPage(
          book: fixture.book,
          accountId: fixture.ali.id,
          launcher: launcher,
        ),
      );

      expect(find.text('0530882752'), findsOneWidget);

      await tester.tap(find.byKey(const Key('account-phone-call')));
      await tester.pumpAndSettle();
      expect(launcher.calls.single.$1, 'dial');
      expect(launcher.calls.single.$2['phone'], '0530882752');

      await tester.tap(find.byKey(const Key('account-phone-whatsapp')));
      await tester.pumpAndSettle();
      expect(launcher.calls.last.$1, 'whatsapp');
      expect(launcher.calls.last.$2['phone'], '0530882752');
    });

    testWidgets('an account without a phone number shows no phone row', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openStatement(tester, fixture, fixture.ali);

      expect(find.byKey(const Key('account-phone-call')), findsNothing);
    });

    testWidgets('a suspended account cannot get new transactions', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await fixture.book.accounts.setStatus(
        fixture.ali.id,
        BookAccountStatus.suspended,
      );
      await _openStatement(tester, fixture, fixture.ali);

      expect(find.textContaining('الحساب متوقف'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('add-transaction-button')),
      );
      expect(button.onPressed, isNull);
      // Still readable.
      expect(find.text('سداد جزئي'), findsOneWidget);
    });

    testWidgets('search and filters narrow the rows', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openStatement(tester, fixture, fixture.ali);

      await tester.tap(find.byKey(const Key('statement-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('statement-query')), 'جزئي');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('العمليات: 1'), findsOneWidget);
      expect(find.text('#TX-000002'), findsOneWidget);
      expect(find.text('#TX-000001'), findsNothing);

      // Searching by the amount typed with separators finds it too.
      await tester.enterText(find.byKey(const Key('statement-query')), '30,000');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('#TX-000001'), findsOneWidget);
      expect(find.text('#TX-000002'), findsNothing);

      await tester.enterText(find.byKey(const Key('statement-query')), '');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // Credit only: nothing matches in this account.
      await tester.tap(find.byKey(const Key('statement-filters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-type-credit')));
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();
      expect(find.text('لا توجد عمليات مطابقة.'), findsOneWidget);
      expect(find.text('العمليات: 0'), findsOneWidget);
    });

    testWidgets(
      'the payment filter offers نقدًا and the wallets, and narrows the rows',
      (tester) async {
        final fixture = await BookFixture.create();
        addTearDown(fixture.dispose);
        final wallet = await fixture.book.wallets.create(
          WalletDraft.single(name: 'محفظة جيب', currencyCode: 'YER'),
        );
        await fixture.book.transactions.create(
          BookTransactionDraft(
            accountId: fixture.ali.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 900,
            date: '2026-01-01',
            walletId: wallet.id,
          ),
        );
        await _openStatement(tester, fixture, fixture.ali);
        // 2 seeded (paid in cash) + 1 new = 3 rows; only the new one is
        // paid through the wallet.
        expect(find.text('العمليات: 3'), findsOneWidget);

        await tester.tap(find.byKey(const Key('statement-filters')));
        await tester.pumpAndSettle();
        // Only «نقدًا» (the main wallet) and the wallets by name — none of the
        // old plain methods, and no "بدون".
        final cashChip = find.byKey(
          Key('filter-payment-wallet-${fixture.mainWallet.id}'),
        );
        expect(
          find.descendant(of: cashChip, matching: find.text('نقدًا')),
          findsOneWidget,
        );
        expect(find.text('الصندوق الرئيسي'), findsNothing);
        for (final old in ['تحويل بنكي', 'شبكة (بطاقة)', 'شيك', 'أخرى', 'بدون']) {
          expect(find.text(old), findsNothing, reason: old);
        }
        await tester.tap(find.byKey(Key('filter-payment-wallet-${wallet.id}')));
        await tester.tap(find.byKey(const Key('filter-apply')));
        await tester.pumpAndSettle();
        expect(find.text('العمليات: 1'), findsOneWidget);

        // «نقدًا» keeps only the two seeded rows.
        await tester.tap(find.byKey(const Key('statement-filters')));
        await tester.pumpAndSettle();
        await tester.tap(cashChip);
        await tester.tap(find.byKey(const Key('filter-apply')));
        await tester.pumpAndSettle();
        expect(find.text('العمليات: 2'), findsOneWidget);
      },
    );

    testWidgets('every row shows its payment: نقدًا or the wallet name', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      final wallet = await fixture.book.wallets.create(
        WalletDraft.single(name: 'حساب الراجحي', currencyCode: 'YER'),
      );
      final viaWallet = await fixture.book.transactions.create(
        BookTransactionDraft(
          accountId: fixture.ali.id,
          currencyCode: 'YER',
          type: EntryType.debit,
          amountMinor: 900,
          date: '2026-01-01',
          walletId: wallet.id,
        ),
      );
      final viaCash = (await _rows(fixture, fixture.ali)).first;
      await _openStatement(tester, fixture, fixture.ali);

      String paymentOf(BookTransaction row) =>
          tester.widget<Text>(find.byKey(Key('row-payment-${row.id}'))).data!;
      expect(paymentOf(viaCash), 'نقدًا');
      expect(paymentOf(viaWallet), 'حساب الراجحي');
      // The main wallet's own name never leaks into the rows.
      expect(find.text('الصندوق الرئيسي'), findsNothing);
    });

    testWidgets('the period chip limits the rows to this year', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      final year = DateTime.now().year;
      await fixture.book.transactions.create(
        BookTransactionDraft(
          accountId: fixture.ali.id,
          currencyCode: 'YER',
          walletId: fixture.mainWallet.id,
          type: EntryType.debit,
          amountMinor: 7,
          date: '$year-01-01',
          details: 'بداية السنة',
        ),
      );
      await _openStatement(tester, fixture, fixture.ali);
      expect(find.text('العمليات: 3'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('period-thisYear')));
      await tester.tap(find.byKey(const Key('period-thisYear')));
      await tester.pumpAndSettle();
      expect(find.text('بداية السنة'), findsOneWidget);
      expect(find.text('2024-12-13'), findsNothing);
      // The totals bar always shows the whole account, not the filtered view.
      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('30,107 مدين'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('scrolling to the end loads the next pages', (tester) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await fixture.book.accounts.create(
        BookAccountDraft.single(
          categoryId: fixture.category.id,
          name: 'كثير',
          currencyCode: 'YER',
        ),
      );
      final cash = await fixture.ensureMainWallet();
      for (var index = 1; index <= 120; index++) {
        final day = ((index - 1) % 28) + 1;
        final month = ((index - 1) ~/ 28) + 1;
        await fixture.book.transactions.create(
          BookTransactionDraft(
            accountId: account.id,
            currencyCode: 'YER',
            walletId: cash.id,
            type: EntryType.debit,
            amountMinor: index,
            date:
                '2025-${month.toString().padLeft(2, '0')}-'
                '${day.toString().padLeft(2, '0')}',
          ),
        );
      }
      await _openStatement(tester, fixture, account);
      expect(find.text('العمليات: 120'), findsOneWidget);

      final oldest = (await _rows(fixture, account)).first;
      expect(_row(oldest), findsNothing);
      await tester.dragUntilVisible(
        _row(oldest),
        find.byKey(const Key('statement-scroll')),
        const Offset(0, -400),
        maxIteration: 200,
      );
      expect(_row(oldest), findsOneWidget);
    });
  });

  group('adding and editing', () {
    testWidgets('a new transaction defaults its payment to نقدًا (the main wallet)', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      final other = await fixture.book.wallets.create(
        WalletDraft.single(name: 'محفظة جيب', currencyCode: 'YER'),
      );
      await _openStatement(tester, fixture, fixture.ali);

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();
      await _showPayment(tester);

      final cashChip = tester.widget<ChoiceChip>(
        find.byKey(Key('payment-wallet-${fixture.mainWallet.id}')),
      );
      final otherChip = tester.widget<ChoiceChip>(
        find.byKey(Key('payment-wallet-${other.id}')),
      );
      expect(cashChip.selected, isTrue);
      expect(otherChip.selected, isFalse);
      // The main wallet reads «نقدًا», never its own name.
      expect(_paymentChipLabels(tester), ['نقدًا', 'محفظة جيب']);
    });

    testWidgets(
      'the payment offers only نقدًا and the active wallets that hold the '
      'currency, main first',
      (tester) async {
        final fixture = await BookFixture.create();
        addTearDown(fixture.dispose);
        await fixture.book.wallets.create(
          WalletDraft.single(name: 'محفظة جيب', currencyCode: 'YER'),
        );
        await fixture.book.wallets.create(
          WalletDraft.single(name: 'حساب الراجحي', currencyCode: 'SAR'),
        );
        final archived = await fixture.book.wallets.create(
          WalletDraft.single(name: 'محفظة قديمة', currencyCode: 'YER'),
        );
        await fixture.book.wallets.setStatus(
          archived.id,
          WalletStatus.archived,
        );
        await _openStatement(tester, fixture, fixture.ali);

        await tester.tap(find.byKey(const Key('add-transaction-button')));
        await tester.pumpAndSettle();
        await _showPayment(tester);

        // Main first, then the wallets in their list order (by name). علي أخي
        // pays in YER: the SAR-only «حساب الراجحي» is not offered, and neither
        // is the archived wallet.
        expect(_paymentChipLabels(tester), ['نقدًا', 'محفظة جيب']);
        expect(find.text('حساب الراجحي'), findsNothing);
        expect(find.text('محفظة قديمة'), findsNothing);
        for (final old in ['تحويل بنكي', 'شبكة (بطاقة)', 'شيك', 'أخرى', 'بدون']) {
          expect(find.text(old), findsNothing, reason: old);
        }
        expect(find.byKey(const Key('payment-other-menu')), findsNothing);
      },
    );

    testWidgets(
      'switching to دائن flips the wallet effect until the toggle is '
      'touched, then it stops following',
      (tester) async {
        final fixture = await BookFixture.create();
        addTearDown(fixture.dispose);
        await _openStatement(tester, fixture, fixture.ali);

        await tester.tap(find.byKey(const Key('add-transaction-button')));
        await tester.pumpAndSettle();
        await _showPayment(tester);
        // The default entry type is مدين (debit) => نقص الرصيد, untouched.
        expect(find.text('نقص الرصيد'), findsOneWidget);

        // Manually overriding it to زيادة while still مدين (a deliberate
        // override the derivation would not have produced) touches it.
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('tx-wallet-effect')),
            matching: find.text('زيادة الرصيد'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('زيادة الرصيد'), findsOneWidget);

        // Switching to دائن and back to مدين would flip the effect twice if
        // it still followed the entry type — it must not: the override
        // stands.
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('tx-type')),
            matching: find.textContaining('دائن'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('tx-type')),
            matching: find.textContaining('مدين'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('زيادة الرصيد'), findsOneWidget);
      },
    );

    testWidgets('a new debit is saved, numbered and totalled', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openStatement(tester, fixture, fixture.ali);

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();
      expect(find.text('إضافة عملية'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('tx-amount')), '5000');
      await tester.pump();
      expect(find.text('5,000'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('tx-details')), 'دفعة جديدة');
      await _tapSave(tester);
      await tester.pumpAndSettle();

      expect(find.text('دفعة جديدة'), findsOneWidget);
      expect(find.text('#TX-000005'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('35,100 مدين'),
        ),
        findsOneWidget,
      );
      final rows = await _rows(fixture, fixture.ali);
      expect(rows.last.type, EntryType.debit);
      expect(rows.last.balanceAfter, 35100);
    });

    testWidgets('a credit lowers the balance and flips the side', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openStatement(tester, fixture, fixture.ali);

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tx-amount')), '40000');
      await tester.tap(find.descendant(
        of: find.byKey(const Key('tx-type')),
        matching: find.textContaining('دائن'),
      ));
      await tester.pumpAndSettle();
      await _tapSave(tester);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('9,900 دائن'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a zero amount is refused with a message', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openStatement(tester, fixture, fixture.ali);

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();
      await _tapSave(tester);
      await tester.pumpAndSettle();

      expect(find.text('أدخل مبلغاً أكبر من صفر.'), findsOneWidget);
      expect((await _rows(fixture, fixture.ali)), hasLength(2));
    });

    testWidgets('decimals follow the currency: SAR keeps two places', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      await _openStatement(tester, fixture, fixture.sar);

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tx-amount')), '1234.567');
      await tester.pump();
      expect(find.text('1,234.56'), findsOneWidget);
      await _tapSave(tester);
      await tester.pumpAndSettle();

      expect((await _rows(fixture, fixture.sar)).last.amountMinor, 123456);
    });

    testWidgets('the details sheet edits a transaction and rebalances', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      final rows = await _rows(fixture, fixture.ali);
      await _openStatement(tester, fixture, fixture.ali);

      await tester.tap(_row(rows.first));
      await tester.pumpAndSettle();
      expect(find.text('تفاصيل العملية'), findsOneWidget);
      expect(find.byKey(const Key('details-number')), findsOneWidget);
      await tester.tap(find.byKey(const Key('details-edit')));
      await tester.pumpAndSettle();

      expect(find.text('تعديل العملية'), findsOneWidget);
      // The form is prefilled and grouped.
      expect(find.text('30,000'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('tx-amount')), '20000');
      await _tapSave(tester);
      await tester.pumpAndSettle();

      final updated = await _rows(fixture, fixture.ali);
      expect(updated.map((r) => r.balanceAfter), [20000, 20100]);
      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('20,100 مدين'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'paying with نقدًا moves the main wallet only and shows نقدًا in the '
      'details',
      (tester) async {
        final fixture = await BookFixture.create();
        addTearDown(fixture.dispose);
        final other = await fixture.book.wallets.create(
          WalletDraft.single(name: 'محفظة جيب', currencyCode: 'YER'),
        );
        Future<int> balanceOf(String id) async =>
            (await fixture.book.wallets.summary(id))!.balanceOf('YER');
        final cashBefore = await balanceOf(fixture.mainWallet.id);
        await _openStatement(tester, fixture, fixture.ali);

        await tester.tap(find.byKey(const Key('add-transaction-button')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('tx-amount')), '5000');
        await _showPayment(tester);
        // The default entry type is مدين (debit): money out, نقص الرصيد.
        expect(find.text('نقص الرصيد'), findsOneWidget);
        await _tapSave(tester);
        await tester.pumpAndSettle();

        expect(await balanceOf(fixture.mainWallet.id), cashBefore - 5000);
        expect(await balanceOf(other.id), 0);
        final saved = (await _rows(fixture, fixture.ali)).last;
        expect(saved.walletId, fixture.mainWallet.id);

        await tester.tap(_row(saved));
        await tester.pumpAndSettle();
        final paymentInfo = find.byKey(const Key('details-payment-info'));
        expect(
          find.descendant(of: paymentInfo, matching: find.text('نقدًا · نقص الرصيد')),
          findsOneWidget,
        );
        expect(find.text('الصندوق الرئيسي'), findsNothing);
      },
    );

    testWidgets(
      'paying with another wallet moves that wallet only and shows its name',
      (tester) async {
        final fixture = await BookFixture.create();
        addTearDown(fixture.dispose);
        final wallet = await fixture.book.wallets.create(
          WalletDraft.single(name: 'محفظة جيب', currencyCode: 'YER'),
        );
        Future<int> balanceOf(String id) async =>
            (await fixture.book.wallets.summary(id))!.balanceOf('YER');
        final cashBefore = await balanceOf(fixture.mainWallet.id);
        await _openStatement(tester, fixture, fixture.ali);

        await tester.tap(find.byKey(const Key('add-transaction-button')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('tx-amount')), '5000');
        await _showPayment(tester);
        await tester.tap(find.byKey(Key('payment-wallet-${wallet.id}')));
        await tester.pumpAndSettle();
        await _tapSave(tester);
        await tester.pumpAndSettle();

        expect(await balanceOf(wallet.id), -5000);
        expect(await balanceOf(fixture.mainWallet.id), cashBefore);
        final saved = (await _rows(fixture, fixture.ali)).last;
        expect(saved.walletId, wallet.id);

        await tester.tap(_row(saved));
        await tester.pumpAndSettle();
        final paymentInfo = find.byKey(const Key('details-payment-info'));
        expect(
          find.descendant(
            of: paymentInfo,
            matching: find.text('${wallet.name} · نقص الرصيد'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'editing the payment from one wallet to another reverses the old '
      'effect and applies the new one',
      (tester) async {
        final fixture = await BookFixture.create();
        addTearDown(fixture.dispose);
        final first = await fixture.book.wallets.create(
          WalletDraft.single(name: 'محفظة جيب', currencyCode: 'YER'),
        );
        final second = await fixture.book.wallets.create(
          WalletDraft.single(name: 'حساب الراجحي', currencyCode: 'YER'),
        );
        final created = await fixture.book.transactions.create(
          BookTransactionDraft(
            accountId: fixture.ali.id,
            currencyCode: 'YER',
            type: EntryType.debit,
            amountMinor: 900,
            date: '2026-01-01',
            walletId: first.id,
          ),
        );
        Future<int> balanceOf(String id) async =>
            (await fixture.book.wallets.summary(id))!.balanceOf('YER');
        expect(await balanceOf(first.id), -900);
        await _openStatement(tester, fixture, fixture.ali);

        await tester.tap(_row(created));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('details-edit')));
        await tester.pumpAndSettle();
        await _showPayment(tester);
        await tester.tap(find.byKey(Key('payment-wallet-${second.id}')));
        await tester.pumpAndSettle();
        await _tapSave(tester);
        await tester.pumpAndSettle();

        expect(await balanceOf(first.id), 0);
        expect(await balanceOf(second.id), -900);
        expect(
          (await fixture.book.transactions.find(created.id))!.walletId,
          second.id,
        );
      },
    );

    testWidgets(
      'an old transaction with no wallet is edited without touching any '
      'balance, and stays unlinked until a payment is chosen',
      (tester) async {
        final fixture = await BookFixture.create();
        addTearDown(fixture.dispose);
        final now = DateTime.utc(2020);
        await fixture.book.repository.write(
          (writer) => writer.putTransaction(
            BookTransaction(
              id: 'legacy-1',
              number: 'TX-900001',
              accountId: fixture.osama.id,
              currencyCode: 'YER',
              type: EntryType.debit,
              amountMinor: 700,
              date: '2020-01-01',
              details: 'قديمة',
              createdAt: now,
              updatedAt: now,
            ),
          ),
        );
        Future<int> balanceOf(String id) async =>
            (await fixture.book.wallets.summary(id))!.balanceOf('YER');
        final cashBefore = await balanceOf(fixture.mainWallet.id);
        await _openStatement(tester, fixture, fixture.osama);

        await tester.tap(find.byKey(const Key('tx-row-legacy-1')));
        await tester.pumpAndSettle();
        // No payment row for a transaction that has none.
        expect(find.byKey(const Key('details-payment-info')), findsNothing);
        await tester.tap(find.byKey(const Key('details-edit')));
        await tester.pumpAndSettle();
        await _showPayment(tester);
        // Nothing is selected, the form says why, and there is no effect
        // toggle for a payment that is not there.
        expect(find.byKey(const Key('tx-payment-hint')), findsOneWidget);
        expect(find.byKey(const Key('tx-wallet-effect')), findsNothing);
        await tester.enterText(find.byKey(const Key('tx-details')), 'قديمة ١');
        await _tapSave(tester);
        await tester.pumpAndSettle();

        final legacy = (await fixture.book.transactions.find('legacy-1'))!;
        expect(legacy.walletId, isNull);
        expect(legacy.details, 'قديمة ١');
        expect(await balanceOf(fixture.mainWallet.id), cashBefore);
      },
    );

    testWidgets('a new transaction is refused when there is no payment method', (
      tester,
    ) async {
      final fixture = await BookFixture.create(seed: false);
      addTearDown(fixture.dispose);
      final account = await fixture.book.accounts.create(
        BookAccountDraft.single(
          categoryId: fixture.category.id,
          name: 'بلا صندوق',
          currencyCode: 'YER',
        ),
      );
      await _openStatement(tester, fixture, account);

      await tester.tap(find.byKey(const Key('add-transaction-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tx-amount')), '100');
      await _showPayment(tester);
      expect(find.byKey(const Key('tx-payment-hint')), findsOneWidget);
      await _tapSave(tester);
      await tester.pumpAndSettle();

      // The form itself refuses (no wallet holds the currency): nothing is
      // sent to be saved. The account has no currency yet, so it is the base
      // currency of the harness (SAR).
      expect(find.text('اختر وسيلة دفع تدعم عملة SAR.'), findsOneWidget);
      expect(await _rows(fixture, account), isEmpty);
    });

    testWidgets('deleting asks first, recomputes, and can be undone', (
      tester,
    ) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      final rows = await _rows(fixture, fixture.ali);
      await _openStatement(tester, fixture, fixture.ali);

      await tester.tap(_row(rows.first));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('details-delete')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'سيؤدي حذف هذه العملية إلى تغيير رصيد الحساب والعمليات التالية. '
          'هل تريد المتابعة؟',
        ),
        findsOneWidget,
      );
      // Cancelling changes nothing.
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect((await _rows(fixture, fixture.ali)), hasLength(2));

      await tester.tap(find.byKey(const Key('details-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
      await tester.pumpAndSettle();

      expect(find.text('تم حذف العملية'), findsOneWidget);
      expect(_row(rows.first), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('100 مدين'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
      expect(_row(rows.first), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('total-net')),
          matching: find.text('30,100 مدين'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('sharing sends the transaction as plain text', (tester) async {
      final fixture = await BookFixture.create();
      addTearDown(fixture.dispose);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.jibi.jibi/file_sharing'),
            (call) async {
              calls.add(call);
              return null;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.jibi.jibi/file_sharing'),
              null,
            ),
      );
      final rows = await _rows(fixture, fixture.ali);
      await _openStatement(tester, fixture, fixture.ali);

      await tester.tap(_row(rows.first));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('details-share')));
      await tester.pumpAndSettle();

      expect(calls.single.method, 'shareText');
      final text = (calls.single.arguments as Map)['text'] as String;
      expect(text, contains('الحساب: علي أخي'));
      expect(text, contains('رقم العملية: TX-000001'));
      expect(text, contains('التاريخ: 13/12/2024'));
      expect(text, contains('العملية: مدين'));
      expect(text, contains('المبلغ: 30,000 YER'));
      expect(text, contains('التفاصيل: يوم موت أبي علي'));
      expect(text, contains('وسيلة الدفع: نقدًا'));
      expect(text, contains('الرصيد: 30,000 YER (مدين)'));
    });
  });
}
