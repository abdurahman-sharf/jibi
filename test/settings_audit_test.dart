import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/app/settings/settings_hub_page.dart';
import 'package:jibi/core/security/security.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/memory_keys.dart' show MemoryKeys, NoBiometrics;

void main() {
  testWidgets(
    'settings screens reload a changed currency and safely cancel the backup dialog',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.jibi.jibi/screen_protection'),
        (_) async => null,
      );
      late Directory directory;
      late JibiApplication app;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'jibi-settings-audit-',
        );
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
      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: const [Locale('ar')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(body: SettingsHubPage(application: app)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings-currencies')));
        await tester.runAsync(() async {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        final newCode = app.currencyRegistry.activeCurrencies
            .firstWhere((c) => c.code != app.settings.defaultCurrencyCode)
            .code;
        final menu = find.byKey(Key('currency-menu-$newCode'));
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('جعلها العملة الأساسية'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(app.settings.defaultCurrencyCode, newCode);
        expect(find.text('إضافة عملة'), findsOneWidget);
        Navigator.of(tester.element(find.text('إضافة عملة'))).pop();
        await tester.pumpAndSettle();
        // The general settings read the default currency afresh.
        await tester.tap(find.byKey(const Key('settings-general')));
        await tester.pumpAndSettle();
        expect(
          tester
              .state<FormFieldState<String>>(
                find.byType(DropdownButtonFormField<String>),
              )
              .value,
          newCode,
        );
        Navigator.of(tester.element(find.text('الإعدادات العامة'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings-backup')));
        await tester.runAsync(() async {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('backup-share')), findsOneWidget);
        final backup = find.byKey(const Key('backup-save-device'));
        await tester.ensureVisible(backup);
        await tester.tap(backup);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '123456',
        );
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        expect(
          await tester.runAsync(() => app.backupDirectory.list().toList()),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await app.dispose();
          await directory.delete(recursive: true);
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.jibi.jibi/screen_protection'),
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.jibi.jibi/backup_file_transfer'),
          null,
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
