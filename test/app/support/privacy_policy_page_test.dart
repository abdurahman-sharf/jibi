import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/support/privacy_policy_page.dart';
import 'package:jibi/app/support/privacy_policy_text.dart';
import 'package:jibi/core/app_info.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(390, 800),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const PrivacyPolicyPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) => tester
      .scrollUntilVisible(finder, 300, scrollable: find.byType(Scrollable).first);

  testWidgets('opens with the banner, its date and the version', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('privacy-policy')), findsOneWidget);
    expect(find.text('سياسة الخصوصية'), findsOneWidget);
    expect(find.text('خصوصيتك أولًا'), findsOneWidget);
    expect(
      find.text('آخر تحديث: $privacyPolicyUpdated • الإصدار ${AppInfo.display}'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('every section can be reached and read', (tester) async {
    await pumpPage(tester);

    for (final section in privacyPolicySections) {
      final card = find.byKey(Key('privacy-section-${section.title}'));
      await reveal(tester, card);
      expect(card, findsOneWidget, reason: section.title);
      expect(
        find.descendant(of: card, matching: find.text(section.title)),
        findsOneWidget,
      );
      for (final paragraph in section.paragraphs) {
        expect(
          find.descendant(of: card, matching: find.text(paragraph)),
          findsOneWidget,
          reason: paragraph,
        );
      }
      for (final bullet in section.bullets) {
        expect(
          find.descendant(of: card, matching: find.text(bullet)),
          findsOneWidget,
          reason: bullet,
        );
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('offers the way to the support screen', (tester) async {
    await pumpPage(tester);

    final link = find.byKey(const Key('privacy-contact'));
    await reveal(tester, link);
    await tester.tap(link);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('contact-us')), findsOneWidget);
  });

  testWidgets('fits a small phone with large text', (tester) async {
    await pumpPage(tester, size: const Size(320, 640), textScale: 1.6);

    for (final section in privacyPolicySections) {
      await reveal(tester, find.byKey(Key('privacy-section-${section.title}')));
    }
    expect(tester.takeException(), isNull);
  });

  test('the policy keeps its essential promises and warnings', () {
    final all = [
      for (final section in privacyPolicySections) ...[
        section.title,
        ...section.paragraphs,
        ...section.bullets,
      ],
    ].join('\n');

    // What is promised.
    expect(all, contains('لا يرسل التطبيق بياناتك إلى أي خادم'));
    expect(all, contains('لا أدوات تحليل ولا إعلانات'));
    // What the user must be warned about.
    expect(all, contains('غير مشفرة'));
    expect(all, contains('لا نستطيع استرجاعها'));
    expect(all, contains('الـPIN'));
    // No section is empty, and titles are unique (they key the cards).
    final titles = [for (final section in privacyPolicySections) section.title];
    expect(titles.toSet(), hasLength(titles.length));
    for (final section in privacyPolicySections) {
      expect(section.paragraphs.length + section.bullets.length, greaterThan(0));
    }
  });
}
