import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/shared/theme/jibi_theme.dart';
import 'package:jibi/shared/widgets/jibi_onboarding.dart';
import 'package:jibi/shared/widgets/jibi_walkthrough.dart';

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  theme: JibiTheme.light(),
  builder: (context, page) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
    child: Directionality(textDirection: TextDirection.rtl, child: page!),
  ),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('starts on the first card and moves on with "التالي"', (
    tester,
  ) async {
    var finished = 0;
    await tester.pumpWidget(_host(JibiWalkthrough(onFinished: () => finished++)));

    expect(find.text(jibiWalkthroughCards.first.title), findsOneWidget);
    expect(find.text('التالي'), findsOneWidget);
    await tester.tap(find.byKey(const Key('walkthrough-next')));
    await tester.pumpAndSettle();

    expect(find.text(jibiWalkthroughCards[1].title), findsOneWidget);
    expect(finished, 0);
  });

  testWidgets('every card is reachable and the last button finishes the tour', (
    tester,
  ) async {
    var finished = 0;
    await tester.pumpWidget(
      _host(JibiWalkthrough(onFinished: () => finished++, finishLabel: 'ابدأ الآن')),
    );

    for (var index = 0; index < jibiWalkthroughCards.length; index++) {
      expect(
        find.text(jibiWalkthroughCards[index].title),
        findsOneWidget,
        reason: 'card $index',
      );
      if (index < jibiWalkthroughCards.length - 1) {
        await tester.tap(find.byKey(const Key('walkthrough-next')));
        await tester.pumpAndSettle();
      }
    }
    expect(find.text('ابدأ الآن'), findsOneWidget);
    expect(find.text('التالي'), findsNothing);
    expect(finished, 0);

    await tester.tap(find.byKey(const Key('walkthrough-next')));
    expect(finished, 1);
  });

  testWidgets('swiping turns the cards (right to left)', (tester) async {
    await tester.pumpWidget(_host(JibiWalkthrough(onFinished: () {})));

    await tester.fling(
      find.byKey(const Key('walkthrough-page-0')),
      const Offset(400, 0),
      1000,
    );
    await tester.pumpAndSettle();

    expect(find.text(jibiWalkthroughCards[1].title), findsOneWidget);
  });

  testWidgets('skipping finishes at once from any card', (tester) async {
    var finished = 0;
    await tester.pumpWidget(_host(JibiWalkthrough(onFinished: () => finished++)));
    await tester.tap(find.byKey(const Key('walkthrough-next')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('walkthrough-skip')));

    expect(finished, 1);
  });

  testWidgets('the indicator has one dot per card', (tester) async {
    await tester.pumpWidget(_host(JibiWalkthrough(onFinished: () {})));

    final dots = find.descendant(
      of: find.byKey(const Key('walkthrough-dots')),
      matching: find.byType(AnimatedContainer),
    );
    expect(dots, findsNWidgets(jibiWalkthroughCards.length));
  });

  testWidgets('fits a small phone and large text without overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(JibiWalkthrough(onFinished: () {}), textScale: 1.6),
    );

    for (var index = 0; index < jibiWalkthroughCards.length; index++) {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'card $index');
      if (index < jibiWalkthroughCards.length - 1) {
        await tester.tap(find.byKey(const Key('walkthrough-next')));
      }
    }
  });

  testWidgets('the standalone tour closes its page when finished', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        builder: (context, page) =>
            Directionality(textDirection: TextDirection.rtl, child: page!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showJibiWalkthrough(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('walkthrough')), findsOneWidget);

    await tester.tap(find.byKey(const Key('walkthrough-skip')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('walkthrough')), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  group('inside the first-run flow', () {
    testWidgets('the tour sits between the welcome page and the PIN step', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: JibiTheme.light(),
          builder: (context, page) =>
              Directionality(textDirection: TextDirection.rtl, child: page!),
          home: JibiOnboardingFlow(onRestoreRequested: () async => false),
        ),
      );

      expect(find.text('أهلاً بك في جيبي'), findsOneWidget);
      await tester.tap(find.text('ابدأ'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('walkthrough')), findsOneWidget);
      expect(find.text('رمز PIN الرئيسي'), findsNothing);

      await tester.tap(find.byKey(const Key('walkthrough-skip')));
      await tester.pumpAndSettle();
      expect(find.text('رمز PIN الرئيسي'), findsOneWidget);
    });

    testWidgets('finishing the last card also leads to the PIN step', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: JibiTheme.light(),
          builder: (context, page) =>
              Directionality(textDirection: TextDirection.rtl, child: page!),
          home: const JibiOnboardingFlow(),
        ),
      );
      await tester.tap(find.text('ابدأ'));
      await tester.pumpAndSettle();
      for (var index = 0; index < jibiWalkthroughCards.length; index++) {
        await tester.tap(find.byKey(const Key('walkthrough-next')));
        await tester.pumpAndSettle();
      }

      expect(find.text('رمز PIN الرئيسي'), findsOneWidget);
    });

    testWidgets('a restored backup skips the tour and asks for a new PIN', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: JibiTheme.light(),
          builder: (context, page) =>
              Directionality(textDirection: TextDirection.rtl, child: page!),
          home: JibiOnboardingFlow(onRestoreRequested: () async => true),
        ),
      );

      await tester.tap(find.text('استعادة نسخة من هاتف سابق'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('walkthrough')), findsNothing);
      expect(find.text('رمز PIN الرئيسي'), findsOneWidget);
    });
  });
}
