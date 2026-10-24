import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/support/contact_us_page.dart';
import 'package:jibi/app/support/support_info.dart';
import 'package:jibi/core/app_info.dart';
import 'package:jibi/core/platform/external_link_launcher.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';
import 'package:jibi/shared/widgets/external_activity_scope.dart';
import 'package:jibi/shared/widgets/whatsapp_glyph.dart';

/// A launcher that records what it is asked and answers as told.
class _FakeLauncher implements ExternalLinkLauncher {
  final List<(String, Map<String, Object?>)> calls = [];
  bool opened = true;
  Object? failure;
  Completer<bool>? gate;

  Future<bool> _answer(String name, Map<String, Object?> arguments) async {
    calls.add((name, arguments));
    if (failure != null) throw failure!;
    final pending = gate;
    if (pending != null) return pending.future;
    return opened;
  }

  @override
  Future<bool> openWhatsApp({required String phone, required String message}) =>
      _answer('whatsapp', {'phone': phone, 'message': message});

  @override
  Future<bool> dial(String phone) => _answer('dial', {'phone': phone});

  @override
  Future<bool> composeEmail({
    required String to,
    required String subject,
    required String body,
  }) => _answer('email', {'to': to, 'subject': subject, 'body': body});

  @override
  Future<bool> openWebsite(Uri url) => _answer('website', {'url': '$url'});
}

void main() {
  late _FakeLauncher launcher;
  late List<bool> runs;
  late int releases;
  late List<String> clipboard;

  setUp(() {
    launcher = _FakeLauncher();
    runs = [];
    releases = 0;
    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add(
              (call.arguments as Map<Object?, Object?>)['text']! as String,
            );
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<T> run<T>(
    Future<T> Function() action, {
    bool holdUntilResumed = false,
  }) {
    runs.add(holdUntilResumed);
    return action();
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(390, 1700),
    double textScale = 1,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? JibiTheme.light(),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ExternalActivityScope(
          run: run,
          release: () => releases++,
          child: ContactUsPage(launcher: launcher),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  /// Snack bars queue up; clear the one on screen so the next shows at once.
  Future<void> clearMessages(WidgetTester tester) async {
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();
  }

  testWidgets('shows the four ways to reach the developer', (tester) async {
    await pumpPage(tester);

    expect(find.text('تواصل معنا'), findsOneWidget);
    expect(find.text('الدعم الفني'), findsOneWidget);
    for (final entry in {
      'contact-whatsapp': 'واتساب',
      'contact-call': 'اتصال',
      'contact-email': 'البريد الإلكتروني',
      'contact-website': 'الموقع الإلكتروني',
    }.entries) {
      expect(find.byKey(Key(entry.key)), findsOneWidget, reason: entry.key);
      expect(
        find.descendant(
          of: find.byKey(Key(entry.key)),
          matching: find.text(entry.value),
        ),
        findsOneWidget,
        reason: entry.value,
      );
    }
    // The email and the website are shown, WhatsApp has its own icon.
    expect(find.text('abdurahmansharf@gmail.com'), findsOneWidget);
    expect(find.text('alaw9l.com'), findsOneWidget);
    expect(find.byType(WhatsAppGlyph), findsOneWidget);
    expect(find.byIcon(Icons.mail_rounded), findsOneWidget);
    expect(
      find.text('الرسالة الجاهزة تتضمن رقم إصدار التطبيق فقط، ويمكنك تعديلها قبل الإرسال.'),
      findsOneWidget,
    );
    expect(find.textContaining(AppInfo.display), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the phone number appears nowhere on the screen', (tester) async {
    await pumpPage(tester);

    for (final digits in ['530882752', '966', '0530', '+966']) {
      expect(find.textContaining(digits), findsNothing, reason: digits);
    }
    // Not in any text, rich text or tooltip that is really built.
    for (final widget in tester.widgetList<Text>(find.byType(Text))) {
      final text = widget.data ?? widget.textSpan?.toPlainText() ?? '';
      expect(text, isNot(contains('530882752')));
    }
    for (final semantics in [
      for (final node in tester.allWidgets.whereType<Semantics>())
        '${node.properties.label} ${node.properties.hint}',
    ]) {
      expect(semantics, isNot(contains('530882752')));
    }
  });

  testWidgets('WhatsApp opens the chat with a support request typed in', (
    tester,
  ) async {
    await pumpPage(tester);

    await tap(tester, 'contact-whatsapp');

    final (name, arguments) = launcher.calls.single;
    expect(name, 'whatsapp');
    expect(arguments['phone'], SupportContact.phone);
    final message = arguments['message']! as String;
    expect(message, SupportContact.whatsAppMessage());
    expect(message, contains('دعم فني'));
    expect(message, contains(AppInfo.display));
    // Started as an external activity that outlives the call, no error shown.
    expect(runs, [true]);
    expect(releases, 0);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the call button opens the dialer', (tester) async {
    await pumpPage(tester);

    await tap(tester, 'contact-call');

    expect(launcher.calls.single.$1, 'dial');
    expect(launcher.calls.single.$2['phone'], SupportContact.phone);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the mail opens with the address, subject and body ready', (
    tester,
  ) async {
    await pumpPage(tester);

    await tap(tester, 'contact-email');

    final (name, arguments) = launcher.calls.single;
    expect(name, 'email');
    expect(arguments['to'], 'abdurahmansharf@gmail.com');
    expect(arguments['subject'], SupportContact.emailSubject());
    expect(arguments['body'], SupportContact.emailBody());
    expect(clipboard, isEmpty);
  });

  testWidgets('the website opens in the browser', (tester) async {
    await pumpPage(tester);

    await tap(tester, 'contact-website');

    expect(launcher.calls.single.$1, 'website');
    expect(launcher.calls.single.$2['url'], 'https://alaw9l.com/');
  });

  testWidgets('with nothing to handle it each button says so and frees the lock', (
    tester,
  ) async {
    launcher.opened = false;
    await pumpPage(tester);

    await tap(tester, 'contact-whatsapp');
    expect(find.text('تعذر فتح واتساب على هذا الجهاز.'), findsOneWidget);
    expect(releases, 1);
    await clearMessages(tester);

    await tap(tester, 'contact-call');
    expect(find.text('لا يوجد تطبيق اتصال على هذا الجهاز.'), findsOneWidget);
    expect(releases, 2);
    await clearMessages(tester);

    await tap(tester, 'contact-website');
    expect(find.text('تعذر فتح المتصفح.'), findsOneWidget);
    expect(releases, 3);

    // No message ever shows the number.
    for (final digits in ['530882752', '966']) {
      expect(find.textContaining(digits), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a mail app the address is copied and shown', (
    tester,
  ) async {
    launcher.opened = false;
    await pumpPage(tester);

    await tap(tester, 'contact-email');

    expect(clipboard, ['abdurahmansharf@gmail.com']);
    expect(
      find.textContaining('لا يوجد تطبيق بريد على هذا الجهاز'),
      findsOneWidget,
    );
    expect(find.textContaining('abdurahmansharf@gmail.com'), findsWidgets);
    expect(releases, 1);
  });

  testWidgets('a platform failure is a message, not a crash', (tester) async {
    launcher.failure = PlatformException(code: 'open_failed');
    await pumpPage(tester);

    await tap(tester, 'contact-whatsapp');

    expect(find.text('تعذر فتح واتساب على هذا الجهاز.'), findsOneWidget);
    expect(releases, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second tap while one is starting is ignored', (tester) async {
    launcher.gate = Completer<bool>();
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('contact-whatsapp')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('contact-call')));
    await tester.pump();
    expect(launcher.calls, hasLength(1));

    launcher.gate!.complete(true);
    await tester.pumpAndSettle();
    await tap(tester, 'contact-call');
    expect(launcher.calls, hasLength(2));
  });

  testWidgets('the privacy policy opens from here', (tester) async {
    await pumpPage(tester);

    await tester.ensureVisible(find.byKey(const Key('contact-privacy')));
    await tap(tester, 'contact-privacy');

    expect(find.byKey(const Key('privacy-policy')), findsOneWidget);
  });

  testWidgets('works without a scope (the app supplies one)', (tester) async {
    tester.view.physicalSize = const Size(390, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        home: ContactUsPage(launcher: launcher),
      ),
    );

    await tap(tester, 'contact-call');

    expect(launcher.calls.single.$1, 'dial');
  });

  testWidgets('fits a small phone with large text, light and dark', (
    tester,
  ) async {
    for (final theme in [JibiTheme.light(), JibiTheme.dark()]) {
      // A fresh page each time, back at the top of its list.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPage(
        tester,
        size: const Size(320, 700),
        textScale: 1.6,
        theme: theme,
      );
      expect(find.byKey(const Key('contact-whatsapp')), findsOneWidget);
      for (final key in ['contact-call', 'contact-email', 'contact-website']) {
        await tester.scrollUntilVisible(
          find.byKey(Key(key)),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byKey(Key(key)), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });
}
