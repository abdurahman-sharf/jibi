import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/app/settings/general_settings_page.dart';
import 'package:jibi/app/settings/settings_hub_page.dart';
import 'package:jibi/app/settings/user_profile_page.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/book/book.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';

import '../../support/memory_keys.dart' show MemoryKeys, NoBiometrics;
import '../../support/book_wallets.dart';

/// A 1x1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
  });
}

Widget _host(Widget page) => MaterialApp(
  theme: JibiTheme.light(),
  locale: const Locale('ar'),
  supportedLocales: const [Locale('ar')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Material(child: page),
  ),
);

void main() {
  late Directory directory;
  late JibiApplication app;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<void> createApp(WidgetTester tester, {bool locked = false}) async {
    tester.view.physicalSize = const Size(390, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.jibi.jibi/screen_protection'),
      (_) async => null,
    );
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-settings-ui-');
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: NoBiometrics(),
      );
      await security.initialize(pin: '123456');
      if (locked) await security.lock();
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
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.jibi.jibi/screen_protection'),
      null,
    );
  }

  /// Taps and lets real async work (database, image codec) finish.
  Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await _settle(tester);
  }

  group('hub', () {
    testWidgets('each entry opens its own screen', (tester) async {
      await createApp(tester);
      await tester.pumpWidget(_host(SettingsHubPage(application: app)));
      await _settle(tester);

      for (final entry in {
        'settings-user': 'profile-form',
        'settings-general': 'general-settings',
        'settings-currencies': null,
        'settings-categories': null,
        'settings-backup': 'backup-settings',
        'settings-audit': 'audit-empty',
        'settings-archive': 'archive-empty',
        'settings-contact': 'contact-us',
        'settings-privacy': 'privacy-policy',
      }.entries) {
        await tapAndWait(tester, find.byKey(Key(entry.key)));
        if (entry.value != null) {
          expect(find.byKey(Key(entry.value!)), findsOneWidget, reason: entry.key);
        }
        Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
        await _settle(tester);
        expect(find.byKey(const Key('settings-hub')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('support and privacy come right after the tools', (
      tester,
    ) async {
      await createApp(tester);
      await tester.pumpWidget(_host(SettingsHubPage(application: app)));
      await _settle(tester);

      double top(String key) =>
          tester.getTopLeft(find.byKey(Key(key), skipOffstage: false)).dy;
      expect(find.text('الدعم والمعلومات'), findsOneWidget);
      expect(top('settings-archive'), lessThan(top('settings-contact')));
      expect(top('settings-contact'), lessThan(top('settings-privacy')));
      expect(find.text('تواصل معنا'), findsOneWidget);
      expect(find.text('سياسة الخصوصية'), findsOneWidget);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('the card shows the saved name and the logo', (tester) async {
      await createApp(tester);
      await tester.runAsync(
        () => app.profile.save(
          UserProfile.validated(nameAr: 'عبدالرحمن شرف', logo: _png),
        ),
      );
      await tester.pumpWidget(_host(SettingsHubPage(application: app)));
      await _settle(tester);

      expect(find.text('عبدالرحمن شرف'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('settings-profile-card')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(find.text('لم تُدخل بياناتك بعد'), findsNothing);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('without a profile it invites the user to fill one in', (
      tester,
    ) async {
      await createApp(tester);
      await tester.pumpWidget(_host(SettingsHubPage(application: app)));
      await _settle(tester);

      expect(find.text('لم تُدخل بياناتك بعد'), findsOneWidget);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('user data', () {
    testWidgets('saves names and contact details', (tester) async {
      await createApp(tester);
      await tester.pumpWidget(_host(UserProfilePage(application: app)));
      await _settle(tester);

      await tester.enterText(
        find.byKey(const Key('profile-name-ar')),
        'عبدالرحمن شرف',
      );
      await tester.enterText(
        find.byKey(const Key('profile-name-en')),
        'Abdulrahman Sharaf',
      );
      await tester.enterText(find.byKey(const Key('profile-phone')), '777123456');
      await tester.enterText(
        find.byKey(const Key('profile-email')),
        'a@example.com',
      );
      await tapAndWait(tester, find.byKey(const Key('profile-save')));

      final saved = await tester.runAsync(app.repository.readUserProfile);
      expect(saved!.nameAr, 'عبدالرحمن شرف');
      expect(saved.nameEn, 'Abdulrahman Sharaf');
      expect(saved.phone, '777123456');
      expect(saved.email, 'a@example.com');
      expect(app.profile.current.nameAr, 'عبدالرحمن شرف');
      expect(tester.takeException(), isNull);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('a wrong e-mail is refused with a message and nothing is saved',
        (tester) async {
      await createApp(tester);
      await tester.pumpWidget(_host(UserProfilePage(application: app)));
      await _settle(tester);

      await tester.enterText(find.byKey(const Key('profile-name-ar')), 'اسم');
      await tester.enterText(find.byKey(const Key('profile-email')), 'oops');
      await tapAndWait(tester, find.byKey(const Key('profile-save')));

      expect(find.text('صيغة البريد الإلكتروني غير صحيحة.'), findsOneWidget);
      expect(app.profile.current.isBlank, isTrue);
      final stored = await tester.runAsync(app.repository.readUserProfile);
      expect(stored!.isBlank, isTrue);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('a picked picture is shrunk, previewed and saved', (
      tester,
    ) async {
      await createApp(tester);
      final sources = <ProfileImageSource>[];
      await tester.pumpWidget(
        _host(
          UserProfilePage(
            application: app,
            pickImage: (source) async {
              sources.add(source);
              return _png;
            },
          ),
        ),
      );
      await _settle(tester);

      await tapAndWait(tester, find.byKey(const Key('profile-logo-pick')));
      await tapAndWait(tester, find.byKey(const Key('profile-source-files')));

      expect(sources, [ProfileImageSource.files]);
      expect(
        find.descendant(
          of: find.byKey(const Key('profile-logo-preview')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('profile-logo-delete')), findsOneWidget);

      await tapAndWait(tester, find.byKey(const Key('profile-signature-pick')));
      await tapAndWait(tester, find.byKey(const Key('profile-source-camera')));
      expect(sources.last, ProfileImageSource.camera);

      await tapAndWait(tester, find.byKey(const Key('profile-save')));

      final logo = app.profile.current.logo!;
      // Re-encoded as a PNG by the platform codec.
      expect(logo.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(app.profile.current.signature, isNotNull);
      expect(app.profile.current.stamp, isNull);
      expect(tester.takeException(), isNull);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('a file that is not a picture is refused', (tester) async {
      await createApp(tester);
      await tester.pumpWidget(
        _host(
          UserProfilePage(
            application: app,
            pickImage: (_) async => Uint8List.fromList([1, 2, 3, 4, 5]),
          ),
        ),
      );
      await _settle(tester);

      await tapAndWait(tester, find.byKey(const Key('profile-stamp-pick')));
      await tapAndWait(tester, find.byKey(const Key('profile-source-files')));

      expect(find.textContaining('تعذر قراءة الصورة'), findsOneWidget);
      expect(find.byKey(const Key('profile-stamp-delete')), findsNothing);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('a picture can be removed and switched off for reports', (
      tester,
    ) async {
      await createApp(tester);
      await tester.runAsync(
        () => app.profile.save(
          UserProfile.validated(nameAr: 'أنا', logo: _png, signature: _png),
        ),
      );
      await tester.pumpWidget(_host(UserProfilePage(application: app)));
      await _settle(tester);

      await tapAndWait(tester, find.byKey(const Key('profile-logo-delete')));
      expect(find.byKey(const Key('profile-logo-delete')), findsNothing);
      await tapAndWait(tester, find.byKey(const Key('profile-signature-show')));
      await tapAndWait(tester, find.byKey(const Key('profile-save')));

      expect(app.profile.current.logo, isNull);
      expect(app.profile.current.signature, isNotNull);
      expect(app.profile.current.showSignature, isFalse);
      expect(app.profile.current.showLogo, isTrue);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('leaving with unsaved changes asks first', (tester) async {
      await createApp(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: JibiTheme.light(),
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Builder(
            builder: (context) => Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Directionality(
                        textDirection: TextDirection.rtl,
                        child: UserProfilePage(application: app),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);

      await tester.enterText(find.byKey(const Key('profile-name-ar')), 'اسم');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('تجاهل التغييرات؟'), findsOneWidget);

      // Staying keeps the page.
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('profile-form')), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'تجاهل'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('profile-form')), findsNothing);
      expect(app.profile.current.isBlank, isTrue);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('general settings', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(_host(GeneralSettingsPage(application: app)));
      await _settle(tester);
    }

    testWidgets('switches are saved', (tester) async {
      await createApp(tester);
      await open(tester);

      await tapAndWait(tester, find.byKey(const Key('general-hide-balances')));
      expect(app.settings.hideBalances, isTrue);
      await tapAndWait(tester, find.byKey(const Key('general-show-time')));
      expect(app.settings.showTransactionTime, isFalse);
      await tapAndWait(tester, find.byKey(const Key('general-confirm-delete')));
      expect(app.settings.confirmBeforeDelete, isFalse);

      final stored = await tester.runAsync(app.repository.read);
      expect(stored!.hideBalances, isTrue);
      expect(stored.showTransactionTime, isFalse);
      expect(stored.confirmBeforeDelete, isFalse);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('the order and the default side are chosen with a tap', (
      tester,
    ) async {
      await createApp(tester);
      await open(tester);

      await tapAndWait(
        tester,
        find.descendant(
          of: find.byKey(const Key('general-order')),
          matching: find.text('الأقدم أولاً'),
        ),
      );
      expect(app.settings.newestFirst, isFalse);
      await tapAndWait(
        tester,
        find.descendant(
          of: find.byKey(const Key('general-default-type')),
          matching: find.text('دائن'),
        ),
      );
      expect(app.settings.defaultEntryType, EntryType.credit);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('the date format is chosen from examples', (tester) async {
      await createApp(tester);
      await open(tester);

      await tester.ensureVisible(find.byKey(const ValueKey('date-yearMonthDay')));
      await tester.tap(find.byKey(const ValueKey('date-yearMonthDay')));
      await _settle(tester);
      expect(find.text('20/09/2026'), findsOneWidget);
      expect(find.text('20-09-2026'), findsOneWidget);
      await tapAndWait(tester, find.text('20/09/2026'));

      expect(app.settings.dateFormat, DateDisplayFormat.dayMonthYearSlash);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('the language is shown as Arabic only', (tester) async {
      await createApp(tester);
      await open(tester);

      expect(find.byKey(const Key('general-language')), findsOneWidget);
      expect(find.textContaining('اللغة المتاحة حالياً'), findsOneWidget);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('the decimals row explains they are set per currency', (
      tester,
    ) async {
      await createApp(tester);
      await open(tester);

      expect(find.textContaining('تُحدَّد لكل عملة'), findsOneWidget);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('the wording of debit and credit is saved and can be reset', (
      tester,
    ) async {
      await createApp(tester);
      await open(tester);

      await tapAndWait(tester, find.byKey(const Key('general-advanced')));
      await tester.enterText(find.byKey(const Key('label-debit')), 'مستحق لي');
      await tester.enterText(find.byKey(const Key('label-credit')), 'مستحق علي');
      await tapAndWait(tester, find.byKey(const Key('labels-save')));

      expect(app.settings.debitLabel, 'مستحق لي');
      expect(app.settings.creditLabel, 'مستحق علي');
      // The default-side control now uses the new words.
      expect(
        find.descendant(
          of: find.byKey(const Key('general-default-type')),
          matching: find.text('مستحق لي'),
        ),
        findsOneWidget,
      );

      await tapAndWait(tester, find.byKey(const Key('labels-reset')));
      expect(app.settings.debitLabel, isNull);
      expect(app.settings.creditLabel, isNull);
      expect(
        tester.widget<TextField>(find.byKey(const Key('label-debit'))).controller!.text,
        isEmpty,
      );
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('the same word on both sides is refused', (tester) async {
      await createApp(tester);
      await open(tester);

      await tapAndWait(tester, find.byKey(const Key('general-advanced')));
      await tester.enterText(find.byKey(const Key('label-debit')), 'سلف');
      await tester.enterText(find.byKey(const Key('label-credit')), 'سلف');
      await tapAndWait(tester, find.byKey(const Key('labels-save')));

      expect(find.byKey(const Key('labels-error')), findsOneWidget);
      expect(app.settings.debitLabel, isNull);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('inside the app', () {
    Future<void> openApp(WidgetTester tester) async {
      await createApp(tester, locked: true);
      await tester.pumpWidget(
        JibiApp(application: app, initialView: JibiInitialView.shell),
      );
      await _settle(tester);
      expect(find.text('جيبي مقفل'), findsOneWidget);
      await tester.runAsync(() => app.security.unlockWithPin('123456'));
      await _settle(tester);
    }

    testWidgets('Settings is a tab of the accounts bar and keeps the bar', (
      tester,
    ) async {
      await openApp(tester);

      await tester.tap(find.text('الحسابات').last);
      await _settle(tester);
      await tester.tap(find.text('الإعدادات'));
      await _settle(tester);

      expect(find.byKey(const Key('settings-hub')), findsOneWidget);
      // The bar is still there, with Settings as the selected destination.
      expect(find.text('التقارير'), findsOneWidget);
      expect(find.text('الرئيسية'), findsWidgets);

      // Category management keeps the bar (as in the design); the other
      // screens open full screen so the bar's "+" never covers their buttons.
      await tester.tap(find.byKey(const Key('settings-categories')));
      await _settle(tester);
      expect(find.text('إدارة التصنيفات'), findsWidgets);
      expect(find.text('التقارير'), findsOneWidget);
      Navigator.of(tester.element(find.text('إدارة التصنيفات').first)).pop();
      await _settle(tester);

      await tester.tap(find.byKey(const Key('settings-general')));
      await _settle(tester);
      expect(find.byKey(const Key('general-settings')), findsOneWidget);
      expect(find.text('التقارير'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(tester.takeException(), isNull);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('the top bar opens the same hub as a screen of its own', (
      tester,
    ) async {
      await openApp(tester);

      await tester.tap(find.byTooltip('الإعدادات'));
      await _settle(tester);

      expect(find.byKey(const Key('settings-hub')), findsOneWidget);
      expect(find.text('النسخ الاحتياطي'), findsOneWidget);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('choosing the dark theme in the settings changes the app', (
      tester,
    ) async {
      await openApp(tester);
      ThemeMode themeMode() =>
          tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;
      expect(themeMode(), ThemeMode.system);

      await tester.tap(find.byTooltip('الإعدادات'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('settings-general')));
      await _settle(tester);
      await tapAndWait(
        tester,
        find.descendant(
          of: find.byKey(const Key('general-theme')),
          matching: find.text('داكن'),
        ),
      );

      expect(app.settings.themePreference, AppThemePreference.dark);
      expect(themeMode(), ThemeMode.dark);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('a saved wording reaches the accounts screens', (tester) async {
      await openApp(tester);
      await tester.runAsync(() async {
        final category = await app.book.categories.create(
          const BookCategoryDraft(name: 'حسابات اليمن'),
        );
        final account = await app.book.accounts.create(
          BookAccountDraft.single(
            categoryId: category.id,
            name: 'علي أخي',
            currencyCode: 'YER',
          ),
        );
        await app.book.transactions.create(
          BookTransactionDraft(
            accountId: account.id,
            currencyCode: 'YER',
            walletId: seededMainWalletId,
            type: EntryType.debit,
            amountMinor: 30000,
            date: '2024-12-13',
          ),
        );
        await app.saveSettings(
          app.settings.withSideLabels(debit: 'مستحق لي', credit: 'مستحق علي'),
        );
      });
      // Every write above reloads several live lists (wallets, totals,
      // categories); let them all land before looking at the accounts tab.
      await _settle(tester);
      await tester.tap(find.text('الحسابات').last);
      await _settle(tester);
      await tester.tap(find.text('حسابات اليمن'));
      await _settle(tester);

      expect(find.textContaining('مستحق لي'), findsWidgets);
      expect(find.text('مدين'), findsNothing);
      await tearDownApp(tester);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
