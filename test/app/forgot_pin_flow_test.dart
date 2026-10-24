import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/features/book/book.dart';

import '../support/device_identity.dart';
import '../support/memory_keys.dart' show MemoryKeys;

/// "نسيت رمز PIN؟" on the lock screen: the phone confirms the person, a new PIN
/// is chosen on the lock screen itself, and nothing stored is touched. No file
/// manager, backup or other screen is ever involved.

/// Every platform channel that can open a file manager, picker or share sheet.
const _fileChannels = <String>[
  'com.jibi.jibi/backup_file_transfer',
  'com.jibi.jibi/document_source_picker',
  'com.jibi.jibi/document_preview',
  'com.jibi.jibi/file_sharing',
  'com.jibi.jibi/external_links',
];

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
  });
}

/// Pumps the widget tree while real time passes, until [done] is true.
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(timeout);
    while (!done() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await tester.pump();
  });
}

void main() {
  late Directory directory;
  late JibiApplication app;
  late FakeDeviceIdentity device;
  late List<String> channelCalls;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    device = FakeDeviceIdentity();
    channelCalls = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in _fileChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        channelCalls.add('$name:${call.method}');
        return null;
      });
    }
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in _fileChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  /// A locked app that already holds an account in the book.
  Future<void> createLockedApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-forgot-pin-');
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: device,
      );
      await security.initialize(pin: '123456');
      app = await JibiApplication.create(
        directory: directory,
        securityService: security,
      );
      final category = await app.book.categories.create(
        const BookCategoryDraft(name: 'الأشخاص'),
      );
      await app.book.accounts.create(
        BookAccountDraft.single(
          categoryId: category.id,
          name: 'أحمد',
          currencyCode: 'SAR',
        ),
      );
      await security.lock();
    });
    await tester.pumpWidget(
      JibiApp(application: app, initialView: JibiInitialView.shell),
    );
    await _settle(tester);
    expect(find.text('جيبي مقفل'), findsOneWidget);
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await app.dispose();
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Windows keeps SQLite handles briefly after close; the test is done.
      }
    });
  }

  Future<void> tapForgotPin(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('lock-forgot-pin')));
    await _waitFor(
      tester,
      () =>
          find.text('إنشاء رمز PIN جديد').evaluate().isNotEmpty ||
          find.textContaining('لم يتم التحقق').evaluate().isNotEmpty ||
          find.textContaining('لا توجد بصمة').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 10),
    );
    await _settle(tester);
  }

  testWidgets(
    'the lock screen has an eye that shows the typed PIN',
    (tester) async {
      await createLockedApp(tester);

      bool obscured() => tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const Key('lock-pin')),
              matching: find.byType(TextField),
            ),
          )
          .obscureText;

      await tester.enterText(find.byKey(const Key('lock-pin')), '1234');
      expect(obscured(), isTrue);
      await tester.tap(find.byKey(const Key('pin-field-eye')));
      await tester.pump();
      expect(obscured(), isFalse);
      await tester.tap(find.byKey(const Key('pin-field-eye')));
      await tester.pump();
      expect(obscured(), isTrue);

      await tearDownApp(tester);
    },
  );

  testWidgets(
    'confirm on the phone, choose a new PIN, get in with all data kept',
    (tester) async {
      await createLockedApp(tester);
      await tapForgotPin(tester);

      // Step 1 happened on the phone; step 2 is on the lock screen itself.
      expect(device.prompts, 1);
      expect(find.text('إنشاء رمز PIN جديد'), findsOneWidget);
      expect(find.byKey(const Key('lock-new-pin')), findsOneWidget);
      expect(find.byKey(const Key('lock-confirm-pin')), findsOneWidget);
      expect(find.byKey(const Key('lock-pin')), findsNothing);
      expect(find.byType(BackButton), findsNothing);

      // Both new-PIN fields have the eye too.
      expect(find.byKey(const Key('pin-field-eye')), findsNWidgets(2));

      await tester.enterText(find.byKey(const Key('lock-new-pin')), '654321');
      await tester.enterText(find.byKey(const Key('lock-confirm-pin')), '654322');
      await tester.tap(find.byKey(const Key('lock-save-new-pin')));
      await tester.pump();
      expect(find.text('الرمزان غير متطابقين.'), findsOneWidget);
      expect(find.text('إنشاء رمز PIN جديد'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('lock-new-pin')), '123');
      await tester.enterText(find.byKey(const Key('lock-confirm-pin')), '123');
      await tester.tap(find.byKey(const Key('lock-save-new-pin')));
      await tester.pump();
      expect(
        find.text('رمز PIN يجب أن يتكون من 6 أرقام على الأقل.'),
        findsOneWidget,
      );
      expect(find.text('إنشاء رمز PIN جديد'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('lock-new-pin')), '654321');
      await tester.enterText(find.byKey(const Key('lock-confirm-pin')), '654321');
      await tester.tap(find.byKey(const Key('lock-save-new-pin')));
      // Storing the new PIN is a heavy key derivation in a debug VM.
      await _waitFor(
        tester,
        () => find.text('جيبي مقفل').evaluate().isEmpty &&
            find.text('إنشاء رمز PIN جديد').evaluate().isEmpty,
        timeout: const Duration(minutes: 3),
      );
      await _settle(tester);

      // In the app, told what happens to the old backups.
      expect(find.text('جيبي مقفل'), findsNothing);
      expect(find.text('مرحباً بك في جيبي 👋'), findsOneWidget);
      expect(find.textContaining('النسخ الاحتياطية السابقة'), findsOneWidget);

      // Nothing stored was touched: the account is still there...
      final categories = await tester.runAsync(
        () => app.book.categories.summaries(),
      );
      expect(categories, hasLength(1));
      final accounts = await tester.runAsync(
        () => app.book.accounts.summaries(),
      );
      expect(accounts!.single.account.name, 'أحمد');

      // ...and only the new PIN opens the app now.
      final oldPin = await tester.runAsync(() async {
        await app.security.lock();
        return (await app.security.unlockWithPin('123456')).authenticated;
      });
      final newPin = await tester.runAsync(
        () async => (await app.security.unlockWithPin('654321')).authenticated,
      );
      expect(oldPin, isFalse);
      expect(newPin, isTrue);

      // No file manager, picker or share sheet was opened at any point.
      expect(channelCalls, isEmpty);
      await tearDownApp(tester);
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  testWidgets(
    'a phone with no fingerprint and no screen lock gets a clear message',
    (tester) async {
      device.available = false;
      await createLockedApp(tester);
      await tapForgotPin(tester);

      expect(
        find.textContaining('لا توجد بصمة ولا قفل شاشة مفعّل على هذا الهاتف'),
        findsOneWidget,
      );
      // Still the lock screen; no prompt, no new-PIN form, nothing opened.
      expect(find.text('جيبي مقفل'), findsOneWidget);
      expect(find.byKey(const Key('lock-pin')), findsOneWidget);
      expect(find.text('إنشاء رمز PIN جديد'), findsNothing);
      expect(device.prompts, 0);
      expect(channelCalls, isEmpty);

      // The current PIN still works.
      await tester.enterText(find.byKey(const Key('lock-pin')), '123456');
      await tester.tap(find.text('فتح القفل'));
      await _waitFor(
        tester,
        () => find.text('جيبي مقفل').evaluate().isEmpty,
        timeout: const Duration(minutes: 3),
      );
      expect(find.text('جيبي مقفل'), findsNothing);
      await tearDownApp(tester);
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  testWidgets(
    'a cancelled system prompt leaves the lock screen and the PIN alone',
    (tester) async {
      device.confirms = false;
      await createLockedApp(tester);
      await tapForgotPin(tester);

      expect(device.prompts, 1);
      expect(find.textContaining('لم يتم التحقق من هويتك'), findsOneWidget);
      expect(find.text('جيبي مقفل'), findsOneWidget);
      expect(find.text('إنشاء رمز PIN جديد'), findsNothing);
      expect(channelCalls, isEmpty);
      await tearDownApp(tester);
    },
  );

  testWidgets(
    'going back forgets what was typed and a new attempt asks the phone again',
    (tester) async {
      await createLockedApp(tester);
      await tapForgotPin(tester);
      expect(device.prompts, 1);

      await tester.enterText(find.byKey(const Key('lock-new-pin')), '654321');
      await tester.enterText(find.byKey(const Key('lock-confirm-pin')), '654321');
      await tester.tap(find.byKey(const Key('lock-cancel-reset')));
      await tester.pump();
      expect(find.text('جيبي مقفل'), findsOneWidget);
      expect(find.byKey(const Key('lock-pin')), findsOneWidget);

      await tapForgotPin(tester);
      expect(device.prompts, 2);
      String typed(String key) => tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text;
      expect(typed('lock-new-pin'), isEmpty);
      expect(typed('lock-confirm-pin'), isEmpty);
      expect(channelCalls, isEmpty);
      await tearDownApp(tester);
    },
  );
}
