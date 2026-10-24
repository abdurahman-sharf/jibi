import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/models/money.dart';
import 'package:jibi/core/models/wallet.dart';
import 'package:jibi/core/models/wallet_views.dart';
import 'package:jibi/features/home/domain/backup_status.dart';
import 'package:jibi/features/home/domain/recent_activity.dart';
import 'package:jibi/features/home/presentation/dashboard_summary.dart';
import 'package:jibi/features/home/presentation/home_dashboard.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';
import 'package:jibi/shared/widgets/jibi_design.dart';

import '../../support/test_currencies.dart';

Money _money(String code, int minor) =>
    Money(amountMinor: minor, currencyCode: code);

Widget _host(Widget dashboard) => MaterialApp(
  theme: JibiTheme.light(),
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(body: dashboard),
  ),
);

RecentActivityItem _activity(int index, RecentActivityKind kind) =>
    RecentActivityItem(
      id: 'item-$index',
      kind: kind,
      title: 'نشاط $index',
      subtitle: 'تفصيل',
      occurredAt: DateTime(2026, 9, 1).add(Duration(hours: index)),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'hero gives every currency an equal page, default currency first',
    (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _host(
          HomeDashboard(
            currencies: testCurrencyRegistry(),
            defaultCurrencyCode: 'SAR',
            summary: Stream.value(
              DashboardSummary(
                receivable: [_money('SAR', 50000), _money('USD', 12000)],
                payable: [_money('SAR', 10000), _money('KWD', 4000)],
                cash: const [],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The default currency (SAR) opens first — its page is built, the
      // others are not yet (a PageView only realizes the current page).
      expect(find.byKey(const Key('hero-page-SAR')), findsOneWidget);
      expect(find.byKey(const Key('hero-page-KWD')), findsNothing);
      expect(find.byKey(const Key('hero-page-USD')), findsNothing);
      // Three tracked currencies ⇒ a page-dot indicator.
      expect(find.byKey(const Key('hero-dots')), findsOneWidget);

      // Swiping moves to the next page (alphabetical after the default:
      // KWD then USD) with the exact same treatment — no currency is
      // rendered any differently from another. A plain drag (not a fling)
      // past the halfway point, since the hero's narrow viewport means a
      // walkthrough-style fling velocity would overshoot straight past KWD
      // to USD.
      await tester.drag(
        find.byKey(const Key('hero-page-SAR')),
        const Offset(200, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hero-page-KWD')), findsOneWidget);
      expect(find.byKey(const Key('hero-page-SAR')), findsNothing);
      // KWD is only owed, so its net is negative.
      expect(find.textContaining('علينا'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the hero is titled with the currency name and wears its color', (
    tester,
  ) async {
    _phone(tester);
    final registry = testCurrencyRegistry();
    registry.upsert(registry.byCode('SAR').copyWith(colorValue: 0xFF7B4FB8));
    await tester.pumpWidget(
      _host(
        HomeDashboard(
          currencies: registry,
          defaultCurrencyCode: 'SAR',
          summary: Stream.value(
            DashboardSummary(
              receivable: [_money('SAR', 50000), _money('USD', 12000)],
              payable: [_money('SAR', 10000)],
              cash: const [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    String title() =>
        tester.widget<Text>(find.byKey(const Key('hero-title'))).data!;
    Color panelTop() {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(const Key('hero-panel')),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      return (decoration.gradient! as LinearGradient).colors.first;
    }

    // The old generic wording is gone: the currency's own name leads.
    expect(find.text('صافي المركز المالي المتاح'), findsNothing);
    expect(title(), 'ريال سعودي');
    expect(
      panelTop(),
      jibiHeroGradientFor(const Color(0xFF7B4FB8)).colors.first,
    );
    // Credit is shown next to debit, not folded into it.
    expect(find.textContaining('100.00'), findsWidgets);
    final sarColor = panelTop();

    await tester.drag(
      find.byKey(const Key('hero-page-SAR')),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(title(), 'دولار أمريكي');
    expect(
      panelTop(),
      jibiHeroGradientFor(Color(registry.colorValueOf('USD'))).colors.first,
    );
    expect(panelTop(), isNot(sarColor));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the hero shows the currency name before the data arrives', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _host(
        HomeDashboard(
          currencies: testCurrencyRegistry(),
          defaultCurrencyCode: 'YER',
          summary: const Stream<DashboardSummary>.empty(),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<Text>(find.byKey(const Key('hero-title'))).data,
      'ريال يمني',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('hero folds wallet cash into the net and shows it separately', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _host(
        HomeDashboard(
          currencies: testCurrencyRegistry(),
          defaultCurrencyCode: 'SAR',
          summary: Stream.value(
            DashboardSummary(
              cash: [_money('SAR', 100000)],
              receivable: [_money('SAR', 30000)],
              payable: [_money('SAR', 10000)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1,000 cash + 300 receivable - 100 payable = 1200.00.
    expect(find.text('1200.00'), findsOneWidget);
    expect(find.byKey(const Key('hero-cash-SAR')), findsOneWidget);
    expect(find.textContaining('الأجمالي '), findsOneWidget);
    // A single tracked currency needs no page-dot indicator.
    expect(find.byKey(const Key('hero-dots')), findsNothing);
  });

  testWidgets("the wallet-cash line only shows on a currency's own page", (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _host(
        HomeDashboard(
          currencies: testCurrencyRegistry(),
          defaultCurrencyCode: 'SAR',
          summary: Stream.value(
            DashboardSummary(
              cash: [_money('SAR', 100000)],
              receivable: [_money('USD', 12000)],
              payable: const [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('hero-cash-SAR')), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('hero-page-SAR')),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hero-page-USD')), findsOneWidget);
    expect(find.byKey(const Key('hero-cash-USD')), findsNothing);
  });

  testWidgets('a normal linked transaction does not double count in the net', (
    tester,
  ) async {
    _phone(tester);
    // A DEBIT of 100 linked to a wallet moves cash -100 and receivable
    // +100 by the same amount — the net must be unchanged.
    await tester.pumpWidget(
      _host(
        HomeDashboard(
          currencies: testCurrencyRegistry(),
          defaultCurrencyCode: 'SAR',
          summary: Stream.value(
            DashboardSummary(
              cash: [_money('SAR', 90000)],
              receivable: [_money('SAR', 40000)],
              payable: [_money('SAR', 10000)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 900 + 400 - 100 = 1200.00, same as the un-linked baseline above.
    expect(find.text('1200.00'), findsOneWidget);
  });

  testWidgets('a multi-currency wallet card does not overflow its tile', (
    tester,
  ) async {
    _phone(tester);
    final now = DateTime(2026, 9, 1);
    final wallet = Wallet(
      id: 'w1',
      name: 'جيب',
      createdAt: now,
      updatedAt: now,
    );
    final summary = WalletSummary(
      wallet: wallet,
      balances: const [
        WalletCurrencyBalance(
          currencyCode: 'SAR',
          openingMinor: 0,
          balanceMinor: 100000,
          transactionCount: 1,
        ),
        WalletCurrencyBalance(
          currencyCode: 'USD',
          openingMinor: 0,
          balanceMinor: 5000,
          transactionCount: 1,
        ),
      ],
      transactionCount: 2,
    );
    await tester.pumpWidget(
      _host(
        HomeDashboard(
          currencies: testCurrencyRegistry(),
          defaultCurrencyCode: 'SAR',
          walletSummaries: Stream.value([summary]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('عملات'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hero has no page-dot indicator for a single currency', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _host(
        HomeDashboard(
          currencies: testCurrencyRegistry(),
          defaultCurrencyCode: 'SAR',
          summary: Stream.value(
            DashboardSummary(
              receivable: [_money('SAR', 50000)],
              payable: const [],
              cash: const [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('hero-dots')), findsNothing);
  });

  testWidgets('quick actions offer a new account, not an expense', (
    tester,
  ) async {
    _phone(tester);
    var opened = 0;
    await tester.pumpWidget(_host(HomeDashboard(onAddAccount: () => opened++)));
    await tester.pumpAndSettle();

    expect(find.text('إضافة مصروف'), findsNothing);
    expect(find.text('مصاريف هذا الشهر'), findsNothing);
    expect(find.text('إضافة كلمة مرور'), findsOneWidget);
    expect(find.text('إضافة مستند'), findsOneWidget);
    await tester.tap(find.text('حساب جديد'));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  group('backup banner', () {
    Future<void> show(WidgetTester tester, BackupStatus status) async {
      _phone(tester);
      await tester.pumpWidget(
        _host(HomeDashboard(backupStatus: Future.value(status))),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('asks for a first backup when none exists', (tester) async {
      await show(tester, const BackupStatus(lastBackupAt: null, due: true));

      expect(find.text('لم تنشئ نسخة احتياطية بعد'), findsOneWidget);
      expect(find.text('مطلوبة'), findsOneWidget);
    });

    testWidgets('says a backup is due when the schedule is overdue', (
      tester,
    ) async {
      await show(
        tester,
        BackupStatus(
          lastBackupAt: DateTime.now().subtract(const Duration(days: 9)),
          due: true,
        ),
      );

      expect(find.text('حان موعد النسخ الاحتياطي'), findsOneWidget);
      expect(find.textContaining('آخر نسخة'), findsOneWidget);
    });

    testWidgets('offers "back up now" only while a backup is due', (
      tester,
    ) async {
      var backups = 0;
      _phone(tester);
      await tester.pumpWidget(
        _host(
          HomeDashboard(
            backupStatus: Future.value(
              const BackupStatus(lastBackupAt: null, due: true),
            ),
            onBackupNow: () => backups += 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('نسخ الآن'), findsOneWidget);
      expect(find.text('مطلوبة'), findsNothing);
      await tester.tap(find.text('نسخ الآن'));
      expect(backups, 1);

      await tester.pumpWidget(
        _host(
          HomeDashboard(
            backupStatus: Future.value(
              BackupStatus(lastBackupAt: DateTime.now(), due: false),
            ),
            onBackupNow: () => backups += 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('نسخ الآن'), findsNothing);
      expect(find.text('محدّثة'), findsOneWidget);
    });

    testWidgets('reassures when the last backup is recent', (tester) async {
      await show(
        tester,
        BackupStatus(lastBackupAt: DateTime.now(), due: false),
      );

      expect(find.text('بياناتك محفوظة في نسخة احتياطية'), findsOneWidget);
      expect(find.text('محدّثة'), findsOneWidget);
      expect(find.text('النسخ الاحتياطي السحابي معطل'), findsNothing);
    });
  });

  group('recent activity', () {
    testWidgets('shows five rows, expands to all, and rows are tappable', (
      tester,
    ) async {
      _phone(tester);
      final opened = <RecentActivityKind>[];
      final items = [
        for (var index = 1; index <= 8; index++)
          _activity(
            index,
            index.isEven
                ? RecentActivityKind.credential
                : RecentActivityKind.document,
          ),
      ];
      await tester.pumpWidget(
        _host(
          HomeDashboard(
            recentActivity: Stream.value(items),
            onOpenActivity: opened.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('نشاط '), findsNWidgets(5));

      await tester.ensureVisible(find.text('عرض الكل'));
      await tester.tap(find.text('عرض الكل'));
      await tester.pumpAndSettle();
      expect(find.textContaining('نشاط '), findsNWidgets(8));

      await tester.ensureVisible(find.text('نشاط 1'));
      await tester.tap(find.text('نشاط 1'));
      await tester.pump();
      expect(opened, [RecentActivityKind.document]);
    });
  });
}
