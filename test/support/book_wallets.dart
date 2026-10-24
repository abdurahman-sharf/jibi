import 'package:jibi/core/database/wallets_migration.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/repositories/book_repository.dart';

/// Id of the main wallet («الصندوق الرئيسي», shown as «نقدًا» wherever a
/// payment method appears). The real database seeds it in MigrationV11.
const String seededMainWalletId = MigrationV11.mainWalletId;

/// The currencies the seeded main wallet holds in tests by default. A wallet is
/// only a payment method in a currency it ALREADY holds (linking a transaction
/// never adds a currency to a wallet), so tests that pay in SAR or USD from
/// «نقدًا» need it to hold them; the currencies the real `currencies` table
/// has after schema v13.
const List<String> seededMainWalletCurrencies = ['YER', 'SAR', 'USD'];

/// The main wallet, seeding it when [repository] has none, and making sure it
/// holds [currencies] (a zero opening balance each — nothing is removed). The
/// real database already has a main wallet (holding just the base currency);
/// the in-memory repository starts empty, and every new transaction needs a
/// payment method. Seeded straight into the repository like the migration does
/// (no audit entry).
Future<Wallet> seedMainWallet(
  BookRepository repository, {
  List<String> currencies = seededMainWalletCurrencies,
}) async {
  Wallet? main;
  for (final summary in await repository.walletSummaries()) {
    if (summary.wallet.isMain) main = summary.wallet;
  }
  final at = DateTime.utc(2000);
  final wallet =
      main ??
      Wallet(
        id: seededMainWalletId,
        name: MigrationV11.mainWalletName,
        isMain: true,
        createdAt: at,
        updatedAt: at,
      );
  await repository.write((writer) async {
    if (main == null) await writer.putWallet(wallet);
    for (final code in currencies) {
      if (await writer.walletBalance(wallet.id, code) != null) continue;
      await writer.putWalletBalance(
        WalletBalance(
          walletId: wallet.id,
          currencyCode: code,
          createdAt: at,
          updatedAt: at,
        ),
      );
    }
  });
  return wallet;
}
