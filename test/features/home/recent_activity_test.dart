import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/models/book.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/features/credentials/credentials.dart';
import 'package:jibi/features/documents/models/document_draft.dart';
import 'package:jibi/features/home/domain/recent_activity.dart';
import 'package:jibi/features/wallets/wallets.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../support/book_wallets.dart';

class _MemoryKeys implements SecureKeyStore {
  final values = <String, Uint8List>{};
  @override
  Future<Uint8List?> read(String key) async => values[key];
  @override
  Future<void> write(String key, Uint8List value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _NoBiometrics implements BiometricAuthenticator {
  @override
  Future<bool> authenticate({required String reason}) async => false;

  @override
  Future<bool> canAuthenticate() async => false;
}

void main() {
  test('mergeRecentActivities sorts by time and enforces limit', () {
    final items = <RecentActivityItem>[
      RecentActivityItem(
        id: 'a',
        kind: RecentActivityKind.credential,
        title: 'old',
        subtitle: '',
        occurredAt: DateTime.utc(2025),
      ),
      RecentActivityItem(
        id: 'b',
        kind: RecentActivityKind.transaction,
        title: 'new',
        subtitle: '',
        occurredAt: DateTime.utc(2026),
      ),
      RecentActivityItem(
        id: 'c',
        kind: RecentActivityKind.document,
        title: 'mid',
        subtitle: '',
        occurredAt: DateTime.utc(2025, 6),
      ),
    ];
    final merged = mergeRecentActivities(items, limit: 2);
    expect(merged.map((item) => item.id), ['b', 'c']);
  });

  testWidgets('readRecentActivity returns real last items across features', (
    tester,
  ) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    late Directory directory;
    late JibiApplication app;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-recent-');
      final security = AesGcmSecurityService(
        keyStore: _MemoryKeys(),
        biometricAuthenticator: _NoBiometrics(),
      );
      await security.initialize(pin: '123456');
      app = await JibiApplication.create(
        directory: directory,
        securityService: security,
      );
    });
    late List<RecentActivityItem> recent;
    try {
      await tester.runAsync(() async {
        final category = await app.book.categories.create(
          const BookCategoryDraft(name: 'الأشخاص'),
        );
        // The real main wallet holds just the base currency; paying in SAR
        // needs it added explicitly (a transaction never adds one).
        await app.book.wallets.update(
          seededMainWalletId,
          const WalletDraft(
            name: 'الصندوق الرئيسي',
            openings: [
              WalletOpeningDraft(currencyCode: 'YER'),
              WalletOpeningDraft(currencyCode: 'SAR'),
            ],
          ),
        );
        final account = await app.book.accounts.create(
          BookAccountDraft.single(
            categoryId: category.id,
            name: 'أحمد',
            currencyCode: 'SAR',
          ),
        );
        await app.book.transactions.create(
          BookTransactionDraft(
            accountId: account.id,
            currencyCode: 'SAR',
            walletId: seededMainWalletId,
            type: EntryType.debit,
            amountMinor: 50000,
            date: '2026-01-02',
          ),
        );
        await app.book.transactions.create(
          BookTransactionDraft(
            accountId: account.id,
            currencyCode: 'SAR',
            walletId: seededMainWalletId,
            type: EntryType.credit,
            amountMinor: 20000,
            date: '2026-01-04',
          ),
        );
        await app.credentials.create(
          const CredentialInput(
            title: 'Gmail',
            username: 'user',
            email: 'user@gmail.com',
            password: 'secret-123',
            notes: '',
          ),
        );
        await app.documents.createDocument(
          DocumentDraft(title: 'جواز السفر'),
        );

        recent = await app.readRecentActivity(limit: 5);
      });

      expect(recent.length, 4);
      final ledger = recent.where(
        (item) => item.kind == RecentActivityKind.transaction,
      );
      expect(ledger, hasLength(2));
      // The book feeds the activity: account name, side and grouped amount.
      expect(ledger.every((item) => item.title == 'أحمد'), isTrue);
      expect(
        ledger.map((item) => item.subtitle),
        // SAR ships without decimals, so 50000 minor units read as 50,000.
        containsAll(['مدين 50,000 SAR', 'دائن 20,000 SAR']),
      );
      expect(recent.any((item) => item.title == 'Gmail'), isTrue);
      expect(recent.any((item) => item.title == 'جواز السفر'), isTrue);
      for (var index = 1; index < recent.length; index++) {
        expect(
          recent[index - 1].occurredAt.isAfter(recent[index].occurredAt) ||
              recent[index - 1].occurredAt.isAtSameMomentAs(
                recent[index].occurredAt,
              ),
          isTrue,
        );
      }
    } finally {
      await tester.runAsync(() async {
        await app.dispose();
        try {
          await directory.delete(recursive: true);
        } on PathAccessException {
          // Windows keeps SQLite handles briefly after close; data already verified.
        }
      });
    }
  });
}
