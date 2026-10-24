import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/app/jibi_feature_pages.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/credentials/credentials.dart';
import 'package:jibi/features/documents/models/document_draft.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/memory_keys.dart' show MemoryKeys, NoBiometrics;

void main() {
  testWidgets(
    'document and credential editors persist changes without replacing identities',
    (tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      late Directory directory;
      late JibiApplication app;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('jibi-edit-');
        final security = AesGcmSecurityService(
          keyStore: MemoryKeys(),
          biometricAuthenticator: NoBiometrics(),
        );
        await security.initialize(pin: '123456');
        app = await JibiApplication.create(
          directory: directory,
          securityService: security,
        );
      });
      Future<void> open(Widget page) async {
        await tester.pumpWidget(
          MaterialApp(home: const Scaffold(body: Text('home'))),
        );
        final context = tester.element(find.text('home'));
        Navigator.of(context)
            .push<void>(MaterialPageRoute<void>(builder: (_) => page));
        await tester.pumpAndSettle();
      }

      Future<void> save() async {
        final button = find.widgetWithText(FilledButton, 'حفظ');
        await tester.ensureVisible(button);
        await tester.runAsync(() async {
          await tester.tap(button);
          await Future<void>.delayed(const Duration(milliseconds: 400));
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('home'), findsOneWidget);
      }

      try {
        final document = (await tester.runAsync(
          () => app.documents.createDocument(
            DocumentDraft(
              title: 'Original',
              documentNumber: '123',
              issueDate: DateTime(2025),
              expiryDate: DateTime(2030),
            ),
          ),
        ))!;
        final details = await tester.runAsync(
          () => app.documents.readDetails(document),
        );
        await open(
          DocumentFormPage(
            controller: app.documents,
            document: document,
            details: details,
          ),
        );
        await tester.enterText(
          find.byType(TextField).at(0),
          'Updated document',
        );
        await tester.enterText(find.byType(TextField).at(1), '456');
        await save();
        final updated = (await tester.runAsync(
          () => app.documents.findDocument(document.id),
        ))!;
        expect(updated.title, 'Updated document');
        expect(updated.createdAt.millisecondsSinceEpoch, document.createdAt.millisecondsSinceEpoch);
        expect(updated.issueDate, document.issueDate);
        final updatedDetails = await tester.runAsync(
          () => app.documents.readDetails(updated),
        );
        expect(updatedDetails!['رقم المستند'], '456');

        final credential = (await tester.runAsync(
          () => app.credentials.create(
            const CredentialInput(
              title: 'Service',
              username: 'user',
              email: 'test@example.com',
              password: 'old-secret',
              notes: '',
              url: 'https://example.com',
            ),
          ),
        ))!;
        await open(
          CredentialFormPage(
            controller: app.credentials,
            details: CredentialDetails(
              credential: credential,
              username: 'user',
              email: 'test@example.com',
              password: 'old-secret',
              notes: '',
            ),
          ),
        );
        await tester.enterText(find.byType(TextField).at(0), 'Updated service');
        await tester.enterText(find.byType(TextField).at(3), 'new-secret');
        await save();
        final stored = (await tester.runAsync(
          () => app.repository.findCredential(credential.id),
        ))!;
        expect(stored.title, 'Updated service');
        expect(stored.createdAt.millisecondsSinceEpoch, credential.createdAt.millisecondsSinceEpoch);
        expect(stored.url, credential.url);
        expect(stored.passwordEncrypted.value, isNot(contains('new-secret')));
        final clear = await tester.runAsync(
          () => app.security.decryptText(stored.passwordEncrypted),
        );
        expect(clear, 'new-secret');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await app.dispose();
          await directory.delete(recursive: true);
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
