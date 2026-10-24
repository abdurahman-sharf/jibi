import '../../core/models/models.dart';
import '../../core/repositories/book_repository.dart';
import '../../core/storage/secure_file_storage.dart';
import '../wallets/controllers/wallet_transactions_controller.dart';
import '../wallets/controllers/wallets_controller.dart';
import 'controllers/book_accounts_controller.dart';
import 'controllers/book_attachments_controller.dart';
import 'controllers/categories_controller.dart';
import 'controllers/transactions_controller.dart';
import 'reports/report_builder.dart';
import 'reports/report_exporter.dart';

/// The accounts book as the UI sees it: one repository and the controllers
/// that carry its rules, sharing one currency registry.
final class BookServices {
  BookServices({
    required this.repository,
    required this.currencies,
    required this.defaultCurrencyCode,
    this.attachments,
    this.exporter,
    SecureFileStorage? storage,
    BookReportBuilder? reports,
  }) : categories = CategoriesController(
         repository: repository,
         storage: storage,
       ),
       accounts = BookAccountsController(
         repository: repository,
         currencies: currencies,
         storage: storage,
       ),
       transactions = TransactionsController(
         repository: repository,
         currencies: currencies,
       ),
       wallets = WalletsController(
         repository: repository,
         currencies: currencies,
       ),
       walletTransactions = WalletTransactionsController(
         repository: repository,
       ),
       reports =
           reports ??
           BookReportBuilder(repository: repository, currencies: currencies);

  final BookRepository repository;
  final CurrencyRegistry currencies;

  /// The user's chosen base currency (`AppSettings.defaultCurrencyCode`), read
  /// live so forms always see the current value.
  final String Function() defaultCurrencyCode;
  final CategoriesController categories;
  final BookAccountsController accounts;
  final TransactionsController transactions;
  final WalletsController wallets;
  final WalletTransactionsController walletTransactions;

  /// Builds the reports (statements, category totals...) from the real
  /// transactions.
  final BookReportBuilder reports;

  /// Null when no encrypted file storage is available (some tests).
  final BookAttachmentsController? attachments;

  /// Sends a report out as PDF, Excel or text. Null in tests that do not
  /// exercise sharing: the export buttons are then not offered.
  final ReportExporter? exporter;
}
