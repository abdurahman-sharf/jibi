import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/book/book_export_scope.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/book/reports/report_exporter.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';
import 'book_wallets.dart';
import 'test_currencies.dart';

export 'book_wallets.dart';

/// A book backed by the in-memory repository, with the sample data of the
/// design mock-ups: a category «حسابات اليمن» with debit, credit and settled
/// accounts, plus a SAR account so currencies can be told apart. Seeded data
/// is paid through the main wallet («نقدًا»), which the real database seeds
/// but the in-memory repository does not, so a seeded fixture creates it.
final class BookFixture {
  BookFixture._(this.book, this.category);

  final BookServices book;
  final BookCategory category;
  late BookAccount ali;
  late BookAccount incoming;
  late BookAccount osama;
  late BookAccount sar;

  /// The main wallet (created when [create] seeds; see [ensureMainWallet]).
  late Wallet mainWallet;

  static Future<BookFixture> create({
    bool seed = true,
    SecureFileStorage? storage,
    ReportExporter? exporter,
  }) async {
    final repository = InMemoryBookRepository();
    final book = BookServices(
      repository: repository,
      currencies: testCurrencyRegistry(),
      defaultCurrencyCode: () => 'SAR',
      exporter: exporter,
      attachments: storage == null
          ? null
          : BookAttachmentsController(repository: repository, storage: storage),
    );
    final category = await book.categories.create(
      const BookCategoryDraft(name: 'حسابات اليمن', icon: 'bank'),
    );
    final fixture = BookFixture._(book, category);
    if (!seed) return fixture;
    fixture.mainWallet = await fixture.ensureMainWallet();

    Future<BookAccount> account(String name, String currency) =>
        book.accounts.create(
          BookAccountDraft.single(
            categoryId: category.id,
            name: name,
            currencyCode: currency,
          ),
        );
    Future<void> tx(
      BookAccount account,
      EntryType type,
      int amount,
      String date, {
      String? details,
      String currency = 'YER',
    }) => book.transactions.create(
      BookTransactionDraft(
        accountId: account.id,
        currencyCode: currency,
        type: type,
        amountMinor: amount,
        date: date,
        details: details,
        walletId: fixture.mainWallet.id,
      ),
    );

    fixture.ali = await account('علي أخي', 'YER');
    fixture.incoming = await account('التحويلات الواردة', 'YER');
    fixture.osama = await account('أسامة أخي', 'YER');
    fixture.sar = await account('حساب سعودي', 'SAR');
    await tx(fixture.ali, EntryType.debit, 30000, '2024-12-13',
        details: 'يوم موت أبي علي');
    await tx(fixture.ali, EntryType.debit, 100, '2026-09-20',
        details: 'سداد جزئي');
    await tx(fixture.incoming, EntryType.credit, 302500, '2025-01-05',
        details: 'حوالة');
    await tx(fixture.sar, EntryType.debit, 485000, '2025-02-01', currency: 'SAR');
    return fixture;
  }

  /// The main wallet (the payment method «نقدًا»), seeded when the book has
  /// none yet — every new transaction needs a payment method.
  Future<Wallet> ensureMainWallet({
    List<String> currencies = seededMainWalletCurrencies,
  }) => seedMainWallet(book.repository, currencies: currencies);

  Future<void> dispose() => book.repository.dispose();
}

/// A phone-sized screen with the app theme, Arabic locale and RTL.
Future<void> pumpBookPage(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(390, 844),
  ExportAuthorizer? authorize,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: JibiTheme.light(),
      darkTheme: JibiTheme.dark(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) {
        final page = Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
        return authorize == null
            ? page
            : BookExportScope(authorize: authorize, child: page);
      },
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}
