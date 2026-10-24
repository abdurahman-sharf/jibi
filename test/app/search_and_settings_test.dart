import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/app/jibi_feature_pages.dart';
import 'package:jibi/app/settings/backup_settings_page.dart';
import 'package:jibi/app/settings/general_settings_page.dart';
import 'package:jibi/app/settings/settings_hub_page.dart';
import 'package:jibi/core/app_info.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/credentials/credentials.dart';
import 'package:jibi/features/documents/models/document_draft.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';

import '../support/memory_keys.dart' show MemoryKeys, NoBiometrics;

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
    tester.view.physicalSize = const Size(390, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-search-');
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

  testWidgets(
    'search results open the matching item',
    (tester) async {
      await createApp(tester);
      await tester.runAsync(() async {
        await app.credentials.create(
          const CredentialInput(
            title: 'بنك الرياض',
            username: 'u',
            email: '',
            password: 'pw',
            notes: '',
          ),
        );
        await app.documents.createDocument(DocumentDraft(title: 'جواز بنكي'));
      });

      await tester.pumpWidget(host(GlobalSearchPage(application: app)));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'بنك');
      await _settle(tester);

      final credentialResult = find.text('بنك الرياض');
      await tester.ensureVisible(credentialResult);
      await tester.tap(credentialResult);
      await _settle(tester);
      expect(find.text('عرض البيانات'), findsOneWidget);
      expect(find.text('الحقول الحساسة مخفية حتى إعادة التحقق من الهوية.'), findsOneWidget);

      Navigator.of(tester.element(find.text('عرض البيانات'))).pop();
      await _settle(tester);

      final documentResult = find.text('جواز بنكي');
      await tester.ensureVisible(documentResult);
      await tester.tap(documentResult);
      await _settle(tester);
      expect(find.text('إرفاق ملف'), findsOneWidget);
      expect(find.text('التقاط صورة بالكاميرا'), findsOneWidget);
      await tearDownApp(tester);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'the settings hub lists the five entries and shows the version',
    (tester) async {
      await createApp(tester);

      await tester.pumpWidget(host(SettingsHubPage(application: app)));
      await _settle(tester);

      for (final title in [
        'بيانات المستخدم',
        'الإعدادات العامة',
        'التصنيفات',
        'العملات',
        'النسخ الاحتياطي',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.textContaining(AppInfo.display), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tearDownApp(tester);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'the general settings keep the clipboard timeout and security rows',
    (tester) async {
      await createApp(tester);

      await tester.pumpWidget(host(GeneralSettingsPage(application: app)));
      await _settle(tester);

      final clipboard = find.text('مسح الحافظة بعد نسخ كلمة مرور');
      await tester.ensureVisible(clipboard);
      expect(clipboard, findsOneWidget);
      expect(find.text('القفل التلقائي'), findsOneWidget);
      expect(find.text('مطوَّر 100%'), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownApp(tester);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'the backup screen says there is no backup yet',
    (tester) async {
      await createApp(tester);

      // Directory listings only complete on the real event loop, so build the
      // page inside runAsync for the "last backup" rows to resolve.
      await tester.runAsync(() async {
        await tester.pumpWidget(host(BackupSettingsPage(application: app)));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });
      await _settle(tester);

      expect(find.text('لا توجد نسخة بعد'), findsOneWidget);
      expect(find.text('حجم آخر نسخة'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tearDownApp(tester);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'turning biometrics on is refused when none is enrolled',
    (tester) async {
      await createApp(tester);

      await tester.pumpWidget(host(GeneralSettingsPage(application: app)));
      await _settle(tester);

      final toggle = find.widgetWithText(
        SwitchListTile,
        'الدخول بالبصمة / Face ID',
      );
      await tester.ensureVisible(toggle);
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(toggle);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await _settle(tester);

      expect(app.settings.biometricsEnabled, isFalse);
      expect(
        find.textContaining('لا توجد بصمة مسجلة'),
        findsOneWidget,
      );
      await tearDownApp(tester);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
