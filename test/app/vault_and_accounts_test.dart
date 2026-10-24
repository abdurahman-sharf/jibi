import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/app/jibi_feature_pages.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/credentials/credentials.dart';
import 'package:jibi/features/documents/models/document_draft.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';

import '../support/memory_keys.dart' show MemoryKeys;

class _AlwaysBiometric implements BiometricAuthenticator {
  @override
  Future<bool> authenticate({required String reason}) async => true;

  @override
  Future<bool> canAuthenticate() async => true;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
  });
}

void main() {
  late Directory directory;
  late JibiApplication app;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<void> createApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-vault-');
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: _AlwaysBiometric(),
      );
      await security.initialize(pin: '123456');
      app = await JibiApplication.create(
        directory: directory,
        securityService: security,
      );
    });
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await app.dispose();
      await directory.delete(recursive: true);
    });
  }

  Widget host(Widget child) => MaterialApp(
    theme: JibiTheme.light(),
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Material(child: child),
    ),
  );

  group('vault', () {
    testWidgets(
      'segment bar shows both segments with live counts',
      (tester) async {
        await createApp(tester);
        await tester.runAsync(() async {
          for (final title in ['بنك', 'بريد']) {
            await app.credentials.create(
              CredentialInput(
                title: title,
                username: 'u',
                email: 'e@x.com',
                password: 'pass-$title',
                notes: '',
              ),
            );
          }
          await app.documents.createDocument(DocumentDraft(title: 'جواز'));
        });

        await tester.pumpWidget(
          host(
            CredentialsPage(
              controller: app.credentials,
              documents: app.documents,
              settings: app.settings,
            ),
          ),
        );
        await _settle(tester);

        expect(find.text('كلمات المرور'), findsOneWidget);
        expect(find.text('المستندات الحساسة'), findsOneWidget);
        expect(find.text('(2)'), findsOneWidget);
        expect(find.text('(1)'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('المستندات الحساسة'));
        await _settle(tester);
        expect(find.text('جواز'), findsOneWidget);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets('security card reflects the real settings', (tester) async {
      await createApp(tester);

      await tester.pumpWidget(
        host(
          CredentialsPage(
            controller: app.credentials,
            documents: app.documents,
            settings: app.settings,
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('حالة الأمان ممتازة'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('قفل فوري عند الخروج'), findsOneWidget);
      expect(find.text('لقطات الشاشة محظورة'), findsOneWidget);

      await tester.pumpWidget(
        host(
          CredentialsPage(
            controller: app.credentials,
            documents: app.documents,
            settings: app.settings.copyWith(
              screenshotProtectionEnabled: false,
              autoLockDuration: AutoLockDuration.fifteenMinutes,
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('حالة الأمان تحتاج تحسينًا'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('قفل بعد 15 دقيقة'), findsOneWidget);
      expect(find.text('لقطات الشاشة مسموحة'), findsOneWidget);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('credentials', () {
    testWidgets(
      'form can generate a strong password and toggle visibility',
      (tester) async {
        await createApp(tester);
        await tester.pumpWidget(
          host(CredentialFormPage(controller: app.credentials)),
        );

        final field = find.widgetWithText(TextField, 'كلمة المرور');
        expect(tester.widget<TextField>(field).obscureText, isTrue);

        await tester.tap(find.byTooltip('توليد كلمة مرور قوية'));
        await tester.pump();

        final generated = tester.widget<TextField>(field);
        expect(generated.controller!.text.length, greaterThanOrEqualTo(16));
        expect(generated.obscureText, isFalse, reason: 'shown once generated');

        await tester.tap(find.byTooltip('إخفاء كلمة المرور'));
        await tester.pump();
        expect(tester.widget<TextField>(field).obscureText, isTrue);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets(
      'details keep the password masked until the eye is tapped',
      (tester) async {
        await createApp(tester);
        final credential = (await tester.runAsync(
          () => app.credentials.create(
            const CredentialInput(
              title: 'خدمة',
              username: 'user-name',
              email: 'a@b.com',
              password: 'S3cret-value',
              notes: '',
            ),
          ),
        ))!;

        await tester.pumpWidget(
          host(
            CredentialDetailsPage(
              credential: credential,
              controller: app.credentials,
            ),
          ),
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('عرض البيانات'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await _settle(tester);

        expect(find.text('user-name'), findsOneWidget);
        expect(find.text('S3cret-value'), findsNothing);
        expect(find.text('••••••••••••'), findsOneWidget);

        await tester.tap(find.byTooltip('إظهار'));
        await tester.pump();
        expect(find.text('S3cret-value'), findsOneWidget);

        await tester.tap(find.byTooltip('إخفاء'));
        await tester.pump();
        expect(find.text('S3cret-value'), findsNothing);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets(
      'copying a username uses the timeout from settings',
      (tester) async {
        await createApp(tester);
        await tester.runAsync(
          () => app.saveSettings(
            app.settings.copyWith(clipboardClearAfter: const Duration(seconds: 60)),
          ),
        );
        expect(app.credentials.clipboardClearAfter, const Duration(seconds: 60));
        final credential = (await tester.runAsync(
          () => app.credentials.create(
            const CredentialInput(
              title: 'خدمة',
              username: 'user-name',
              email: '',
              password: 'x-password',
              notes: '',
            ),
          ),
        ))!;

        await tester.pumpWidget(
          host(
            CredentialDetailsPage(
              credential: credential,
              controller: app.credentials,
            ),
          ),
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('عرض البيانات'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await _settle(tester);
        final copyUsername = find.text('نسخ اسم المستخدم');
        await tester.ensureVisible(copyUsername);
        await tester.runAsync(() async {
          await tester.tap(copyUsername);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump();

        expect(find.textContaining('بعد 60 ثانية'), findsOneWidget);
        await tearDownApp(tester);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets('a favourite is labelled as such, not as work', (tester) async {
      await createApp(tester);
      await tester.runAsync(
        () => app.credentials.create(
          const CredentialInput(
            title: 'خدمة',
            username: 'u',
            email: '',
            password: 'pw',
            notes: '',
            isFavorite: true,
          ),
        ),
      );

      await tester.pumpWidget(
        host(
          CredentialsPage(
            controller: app.credentials,
            documents: app.documents,
            settings: app.settings,
          ),
        ),
      );
      await _settle(tester);

      expect(find.text('العمل'), findsNothing);
      expect(find.text('تم الالتصاق الآمن'), findsNothing);
      expect(find.text('مفضلة'), findsWidgets);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
