import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/wallets/wallet_detail_page.dart';
import 'package:jibi/app/wallets/wallet_forms.dart';
import 'package:jibi/app/wallets/wallets_list_page.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';
import 'package:jibi/features/wallets/wallets.dart';

import '../../support/book_harness.dart';
import '../../support/fake_secure_storage.dart';

Future<Uint8List> _samplePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 40, 40),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(40, 40);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  late BookFixture fixture;

  setUp(() async {
    fixture = await BookFixture.create(seed: false);
  });

  tearDown(() => fixture.dispose());

  Future<void> openList(WidgetTester tester) => pumpBookPage(
    tester,
    WalletsListPage(book: fixture.book),
    size: const Size(390, 1600),
  );

  Future<void> openDetail(WidgetTester tester, String walletId) => pumpBookPage(
    tester,
    WalletDetailPage(book: fixture.book, walletId: walletId),
    size: const Size(390, 2200),
  );

  group('list', () {
    testWidgets('an empty book offers to add the first wallet', (tester) async {
      await openList(tester);
      expect(find.text('لا توجد محافظ حتى الآن'), findsOneWidget);

      await tester.tap(find.text('إضافة محفظة'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('wallet-name')), 'محفظتي');
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      expect(find.text('محفظتي'), findsOneWidget);
      final summary = (await fixture.book.wallets.summaries()).single;
      // The form pre-fills one opening row with the base currency at zero.
      expect(summary.balances.single.currencyCode, 'SAR');
      expect(summary.balances.single.openingMinor, 0);
    });

    testWidgets('shows each balance and lets you set a main wallet', (
      tester,
    ) async {
      final a = await fixture.book.wallets.create(
        WalletDraft.single(
          name: 'أ',
          currencyCode: 'SAR',
          openingMinor: 100000,
        ),
      );
      await fixture.book.wallets.create(
        WalletDraft.single(name: 'ب', currencyCode: 'SAR'),
      );
      await openList(tester);

      expect(find.text('أ'), findsOneWidget);
      expect(find.text('ب'), findsOneWidget);
      expect(find.text('رئيسية'), findsNothing);

      await tester.tap(find.byKey(Key('wallet-menu-${a.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تعيين كمحفظة رئيسية'));
      await tester.pumpAndSettle();

      expect(find.text('رئيسية'), findsOneWidget);
      expect((await fixture.book.wallets.find(a.id))!.isMain, isTrue);
    });

    testWidgets('archiving hides a wallet until asked for', (tester) async {
      final w = await fixture.book.wallets.create(
        WalletDraft.single(name: 'أرشفها', currencyCode: 'SAR'),
      );
      await openList(tester);

      await tester.tap(find.byKey(Key('wallet-menu-${w.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('أرشفة'));
      await tester.pumpAndSettle();
      expect(find.text('أرشفها'), findsNothing);

      await tester.tap(find.text('إظهار المؤرشفة'));
      await tester.pumpAndSettle();
      expect(find.text('أرشفها'), findsOneWidget);

      await tester.tap(find.byKey(Key('wallet-menu-${w.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء الأرشفة'));
      await tester.pumpAndSettle();
      expect(
        (await fixture.book.wallets.find(w.id))!.status,
        WalletStatus.active,
      );
    });

    testWidgets('deleting a wallet with movements cascades', (tester) async {
      final w = await fixture.book.wallets.create(
        WalletDraft.single(name: 'للحذف', currencyCode: 'SAR'),
      );
      await fixture.book.walletTransactions.deposit(
        WalletDepositDraft(walletId: w.id, amountMinor: 1000, date: '2025-01-01'),
      );
      await openList(tester);

      await tester.tap(find.byKey(Key('wallet-menu-${w.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حذف'));
      await tester.pumpAndSettle();
      expect(find.textContaining('للحذف'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
      await tester.pumpAndSettle();

      expect(find.text('للحذف'), findsNothing);
      expect(await fixture.book.wallets.find(w.id), isNull);
    });
  });

  group('form', () {
    testWidgets('currency is locked once the wallet has a movement', (
      tester,
    ) async {
      final w = await fixture.book.wallets.create(
        WalletDraft.single(name: 'مقفلة', currencyCode: 'SAR'),
      );
      await fixture.book.walletTransactions.deposit(
        WalletDepositDraft(walletId: w.id, amountMinor: 500, date: '2025-01-01'),
      );
      await pumpBookPage(
        tester,
        WalletFormPage(book: fixture.book, wallet: w),
        size: const Size(390, 1600),
      );
      expect(find.textContaining('عملة فيها حركات'), findsOneWidget);
      final currencyField = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('wallet-opening-currency-SAR')),
      );
      expect(currencyField.onChanged, isNull);
      // The amount stays editable even though the currency is locked.
      final amountField = tester.widget<TextField>(
        find.byKey(const Key('wallet-opening-amount-SAR')),
      );
      expect(amountField.enabled ?? true, isTrue);
    });

    testWidgets('a picked image is shrunk, previewed and saved with the wallet', (
      tester,
    ) async {
      late Uint8List png;
      await tester.runAsync(() async {
        png = await _samplePng();
      });
      final sandbox = Directory.systemTemp.createTempSync('jibi_wallet_image_');
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final file = File('${sandbox.path}${Platform.pathSeparator}logo.png')
        ..writeAsBytesSync(png);
      final picker = FakeDocumentSourcePicker()
        ..pickResults.add(
          FileImportRequest(
            sourceFile: file,
            originalExtension: 'png',
            mimeType: 'image/png',
          ),
        );

      await pumpBookPage(
        tester,
        WalletFormPage(book: fixture.book, picker: picker),
        size: const Size(390, 1600),
      );
      await tester.enterText(find.byKey(const Key('wallet-name')), 'بصورة');

      Future<void> tapAndWait(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pump();
        await tester.runAsync(() async {
          await tester.tap(finder);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
      }

      await tapAndWait(find.byKey(const Key('wallet-image-pick')));
      await tapAndWait(find.byKey(const Key('wallet-image-files')));

      expect(picker.pickCalls, 1);
      expect(find.byKey(const Key('wallet-image-remove')), findsOneWidget);

      await tapAndWait(find.byKey(const Key('save-button')));

      final created = (await fixture.book.wallets.summaries())
          .map((s) => s.wallet)
          .firstWhere((w) => w.name == 'بصورة');
      expect(created.image, isNotNull);
      // The cache file the picker returned is deleted after import.
      expect(file.existsSync(), isFalse);
    });
  });

  group('detail', () {
    testWidgets('deposit, withdrawal and transfer all recompute the balance', (
      tester,
    ) async {
      final main = await fixture.book.wallets.create(
        WalletDraft.single(
          name: 'الرئيسية',
          currencyCode: 'SAR',
        ),
      );
      final bank = await fixture.book.wallets.create(
        WalletDraft.single(
          name: 'بنكية',
          currencyCode: 'SAR',
        ),
      );
      await openDetail(tester, main.id);
      expect(find.text('لا توجد حركات لهذه المحفظة'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wallet-deposit-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('wtx-amount')), '1000');
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect((await fixture.book.wallets.summary(main.id))!.balanceOf('SAR'), 100000);

      await tester.tap(find.byKey(const Key('wallet-withdraw-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('wtx-amount')), '200');
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect((await fixture.book.wallets.summary(main.id))!.balanceOf('SAR'), 80000);

      await tester.tap(find.byKey(const Key('wallet-transfer-button')));
      await tester.pumpAndSettle();
      expect(find.text('بنكية'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('wtx-amount')), '300');
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      expect((await fixture.book.wallets.summary(main.id))!.balanceOf('SAR'), 50000);
      expect((await fixture.book.wallets.summary(bank.id))!.balanceOf('SAR'), 30000);

      // Each label also names the action button and the filter chip, so one
      // movement of each kind means 3 matches (button + chip + row).
      expect(find.text('إيداع'), findsNWidgets(3));
      expect(find.text('سحب'), findsNWidgets(3));
      expect(find.text('تحويل'), findsNWidgets(3));
    });

    testWidgets('a transfer needs another wallet to exist at all', (
      tester,
    ) async {
      final w = await fixture.book.wallets.create(
        WalletDraft.single(name: 'وحيدة', currencyCode: 'SAR'),
      );
      await openDetail(tester, w.id);
      await tester.tap(find.byKey(const Key('wallet-transfer-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('لا توجد محفظة أخرى للتحويل إليها'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('save-button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets(
      'a transfer to a wallet of a different currency offers a received field',
      (tester) async {
        final from = await fixture.book.wallets.create(
          WalletDraft.single(name: 'من', currencyCode: 'SAR'),
        );
        await fixture.book.wallets.create(
          WalletDraft.single(name: 'إلى', currencyCode: 'USD'),
        );
        await openDetail(tester, from.id);
        await tester.tap(find.byKey(const Key('wallet-transfer-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('wtx-target-wallet')), findsOneWidget);
        expect(find.text('إلى'), findsOneWidget);
        expect(find.byKey(const Key('wtx-received')), findsOneWidget);

        await tester.enterText(find.byKey(const Key('wtx-amount')), '100');
        await tester.enterText(find.byKey(const Key('wtx-received')), '375');
        await tester.tap(find.byKey(const Key('save-button')));
        await tester.pumpAndSettle();

        final fromSummary = await fixture.book.wallets.summary(from.id);
        expect(fromSummary!.balanceOf('SAR'), -10000);
      },
    );

    testWidgets(
      'صرف: a typed exchange rate computes the received amount and locks it',
      (tester) async {
        final wallet = await fixture.book.wallets.create(
          WalletDraft.single(name: 'جيب', currencyCode: 'SAR'),
        );
        await openDetail(tester, wallet.id);
        await tester.tap(find.byKey(const Key('wallet-exchange-button')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('wtx-to-currency')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('YER').last);
        await tester.pumpAndSettle();

        await tester.enterText(find.byKey(const Key('wtx-amount')), '100');
        await tester.enterText(find.byKey(const Key('wtx-rate')), '140');
        await tester.pumpAndSettle();

        expect(find.text('14,000'), findsOneWidget);
        final received = tester.widget<TextField>(
          find.byKey(const Key('wtx-received')),
        );
        expect(received.enabled, isFalse);

        // Clearing the rate hands the field back for manual entry, without
        // wiping what was last computed.
        await tester.enterText(find.byKey(const Key('wtx-rate')), '');
        await tester.pumpAndSettle();
        final reEnabled = tester.widget<TextField>(
          find.byKey(const Key('wtx-received')),
        );
        expect(reEnabled.enabled, isTrue);
        expect(find.text('14,000'), findsOneWidget);
      },
    );

    testWidgets(
      'صرف: changing either currency clears the stale rate and received amount',
      (tester) async {
        final wallet = await fixture.book.wallets.create(
          WalletDraft.single(name: 'جيب', currencyCode: 'SAR'),
        );
        await openDetail(tester, wallet.id);
        await tester.tap(find.byKey(const Key('wallet-exchange-button')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('wtx-to-currency')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('YER').last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('wtx-amount')), '100');
        await tester.enterText(find.byKey(const Key('wtx-rate')), '140');
        await tester.pumpAndSettle();
        expect(find.text('14,000'), findsOneWidget);

        // A rate for SAR→YER means nothing for SAR→USD.
        await tester.tap(find.byKey(const Key('wtx-to-currency')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('USD').last);
        await tester.pumpAndSettle();

        expect(find.text('14,000'), findsNothing);
        final rate = tester.widget<TextField>(find.byKey(const Key('wtx-rate')));
        expect(rate.controller!.text, isEmpty);
        final received = tester.widget<TextField>(
          find.byKey(const Key('wtx-received')),
        );
        expect(received.controller!.text, isEmpty);
        expect(received.enabled, isTrue);
      },
    );

    testWidgets('a movement can be deleted and undone from its details', (
      tester,
    ) async {
      final w = await fixture.book.wallets.create(
        WalletDraft.single(name: 'محفظة', currencyCode: 'SAR'),
      );
      final tx = await fixture.book.walletTransactions.deposit(
        WalletDepositDraft(
          walletId: w.id,
          amountMinor: 100000,
          date: '2025-01-01',
        ),
      );
      await openDetail(tester, w.id);

      await tester.tap(find.byKey(Key('wtx-row-${tx.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wtx-details-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
      await tester.pumpAndSettle();

      expect(find.text('تم حذف الحركة'), findsOneWidget);
      expect((await fixture.book.wallets.summary(w.id))!.balanceOf('SAR'), 0);

      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
      expect((await fixture.book.wallets.summary(w.id))!.balanceOf('SAR'), 100000);
    });

    testWidgets('the type filter narrows the movement list', (tester) async {
      final w = await fixture.book.wallets.create(
        WalletDraft.single(name: 'محفظة', currencyCode: 'SAR'),
      );
      await fixture.book.walletTransactions.deposit(
        WalletDepositDraft(walletId: w.id, amountMinor: 1000, date: '2025-01-01'),
      );
      await fixture.book.walletTransactions.withdraw(
        WalletWithdrawalDraft(walletId: w.id, amountMinor: 200, date: '2025-01-02'),
      );
      await openDetail(tester, w.id);
      // Button + chip + row for each.
      expect(find.text('إيداع'), findsNWidgets(3));
      expect(find.text('سحب'), findsNWidgets(3));

      await tester.tap(find.byKey(const Key('wallet-filter-withdrawal')));
      await tester.pumpAndSettle();
      // The deposit row is gone; only the button and the chip still say
      // "إيداع". The withdrawal row now joins its own button and chip.
      expect(find.text('إيداع'), findsNWidgets(2));
      expect(find.text('سحب'), findsNWidgets(3));
    });
  });
}
