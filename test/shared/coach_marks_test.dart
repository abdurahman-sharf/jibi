import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/shared/theme/jibi_theme.dart';
import 'package:jibi/shared/widgets/coach_marks.dart';

/// A page with a button at the top, one in the middle and one at the bottom.
class _Page extends StatelessWidget {
  const _Page({
    required this.top,
    required this.middle,
    required this.bottom,
    required this.onStart,
    this.taps,
  });

  final GlobalKey top;
  final GlobalKey middle;
  final GlobalKey bottom;
  final VoidCallback onStart;
  final List<String>? taps;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        Positioned(
          top: 60,
          right: 20,
          child: ElevatedButton(
            key: top,
            onPressed: () => taps?.add('top'),
            child: const Text('أعلى'),
          ),
        ),
        Center(
          child: ElevatedButton(
            key: middle,
            onPressed: () => taps?.add('middle'),
            child: const Text('وسط'),
          ),
        ),
        Positioned(
          bottom: 40,
          left: 20,
          child: ElevatedButton(
            key: bottom,
            onPressed: () => taps?.add('bottom'),
            child: const Text('أسفل'),
          ),
        ),
        Positioned(
          top: 300,
          left: 20,
          child: TextButton(
            key: const Key('start'),
            onPressed: onStart,
            child: const Text('ابدأ'),
          ),
        ),
      ],
    ),
  );
}

void main() {
  final top = GlobalKey(debugLabel: 'top');
  final middle = GlobalKey(debugLabel: 'middle');
  final bottom = GlobalKey(debugLabel: 'bottom');
  CoachTourResult? result;
  List<String> taps = [];

  Future<void> pumpPage(
    WidgetTester tester,
    List<CoachStep> Function() steps, {
    double textScale = 1,
    Size size = const Size(390, 844),
  }) async {
    result = null;
    taps = [];
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        builder: (context, page) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Directionality(textDirection: TextDirection.rtl, child: page!),
        ),
        home: Builder(
          builder: (context) => _Page(
            top: top,
            middle: middle,
            bottom: bottom,
            taps: taps,
            onStart: () async {
              result = await showCoachTour(context, steps());
            },
          ),
        ),
      ),
    );
  }

  List<CoachStep> threeSteps() => [
    CoachStep(target: top, title: 'الأول', message: 'رسالة الأول'),
    CoachStep(target: middle, title: 'الثاني', message: 'رسالة الثاني'),
    CoachStep(target: bottom, title: 'الثالث', message: 'رسالة الثالث'),
  ];

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('start')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('shows the first hint with its counter', (tester) async {
    await pumpPage(tester, threeSteps);
    await start(tester);

    expect(find.byKey(const Key('coach-overlay')), findsOneWidget);
    expect(find.text('الأول'), findsOneWidget);
    expect(find.text('رسالة الأول'), findsOneWidget);
    expect(find.byKey(const Key('coach-counter')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('coach-counter'))).data, '1 / 3');
    expect(find.text('تخطي'), findsOneWidget);
    expect(find.text('التالي'), findsOneWidget);
  });

  testWidgets('walks through every step and the last button finishes',
      (tester) async {
    await pumpPage(tester, threeSteps);
    await start(tester);

    await tester.tap(find.byKey(const Key('coach-next')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('الثاني'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('coach-counter'))).data, '2 / 3');

    await tester.tap(find.byKey(const Key('coach-next')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('الثالث'), findsOneWidget);
    // No "skip" on the last hint, and the button says it is understood.
    expect(find.text('تخطي'), findsNothing);
    expect(find.text('فهمت'), findsOneWidget);

    await tester.tap(find.byKey(const Key('coach-next')));
    await tester.pumpAndSettle();

    expect(result, CoachTourResult.finished);
    expect(find.byKey(const Key('coach-overlay')), findsNothing);
  });

  testWidgets('skipping ends the tour at once', (tester) async {
    await pumpPage(tester, threeSteps);
    await start(tester);

    await tester.tap(find.byKey(const Key('coach-skip')));
    await tester.pumpAndSettle();

    expect(result, CoachTourResult.skipped);
    expect(find.byKey(const Key('coach-overlay')), findsNothing);
  });

  testWidgets('Back counts as skipping', (tester) async {
    await pumpPage(tester, threeSteps);
    await start(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(result, CoachTourResult.skipped);
    expect(find.byKey(const Key('coach-overlay')), findsNothing);
  });

  testWidgets('a widget that is not on screen is left out', (tester) async {
    final missing = GlobalKey(debugLabel: 'missing');
    await pumpPage(
      tester,
      () => [
        CoachStep(target: missing, title: 'غائب', message: 'x'),
        CoachStep(target: top, title: 'الأول', message: 'a'),
        CoachStep(target: bottom, title: 'الثالث', message: 'c'),
      ],
    );
    await start(tester);

    expect(find.text('غائب'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('coach-counter'))).data, '1 / 2');
  });

  testWidgets('a widget scrolled out of view is left out', (tester) async {
    final hidden = GlobalKey(debugLabel: 'hidden');
    result = null;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        builder: (context, page) =>
            Directionality(textDirection: TextDirection.rtl, child: page!),
        home: Builder(
          builder: (context) => Scaffold(
            // Everything is built, but the last widget sits far below the screen.
            body: SingleChildScrollView(
              child: Column(
                children: [
                  TextButton(
                    key: const Key('start'),
                    onPressed: () async {
                      result = await showCoachTour(context, [
                        CoachStep(target: hidden, title: 'بعيد', message: 'x'),
                      ]);
                    },
                    child: const Text('ابدأ'),
                  ),
                  const SizedBox(height: 2000),
                  SizedBox(key: hidden, height: 40, width: 100),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('start')));
    await tester.pumpAndSettle();

    expect(result, CoachTourResult.nothingToShow);
    expect(find.byKey(const Key('coach-overlay')), findsNothing);
  });

  testWidgets('with nothing to show no overlay appears', (tester) async {
    await pumpPage(
      tester,
      () => [CoachStep(target: GlobalKey(), title: 'لا شيء', message: 'x')],
    );
    await start(tester);

    expect(result, CoachTourResult.nothingToShow);
    expect(find.byKey(const Key('coach-overlay')), findsNothing);
  });

  testWidgets('the page underneath cannot be tapped while the tour runs',
      (tester) async {
    await pumpPage(tester, threeSteps);
    await start(tester);

    await tester.tapAt(tester.getCenter(find.byKey(middle)));
    await tester.pump();

    expect(taps, isEmpty);
    expect(find.byKey(const Key('coach-overlay')), findsOneWidget);
  });

  testWidgets('the card sits below a widget near the top and above one near the bottom',
      (tester) async {
    await pumpPage(tester, threeSteps);
    await start(tester);

    final firstTarget = tester.getRect(find.byKey(top));
    final firstCard = tester.getRect(find.byKey(const Key('coach-card-0')));
    expect(firstCard.top, greaterThan(firstTarget.bottom));

    await tester.tap(find.byKey(const Key('coach-next')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('coach-next')));
    await tester.pump(const Duration(milliseconds: 400));

    final lastTarget = tester.getRect(find.byKey(bottom));
    final lastCard = tester.getRect(find.byKey(const Key('coach-card-2')));
    expect(lastCard.bottom, lessThan(lastTarget.top));
    // The card never leaves the screen.
    expect(lastCard.left, greaterThanOrEqualTo(0));
    expect(lastCard.right, lessThanOrEqualTo(390));
  });

  testWidgets('the lit hole follows each step\'s widget', (tester) async {
    await pumpPage(tester, threeSteps);
    await start(tester);

    // The painter is private; its public "hole" is the rectangle left clear.
    Rect hole() {
      for (final paint in tester.widgetList<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('coach-overlay')),
          matching: find.byType(CustomPaint),
        ),
      )) {
        try {
          return (paint.painter as dynamic).hole as Rect;
        } on Object {
          // The arrow's painter has no hole.
        }
      }
      throw StateError('no hole painted');
    }

    for (final key in [top, middle, bottom]) {
      // The rectangle of the target, grown a little around it.
      expect(hole(), tester.getRect(find.byKey(key)).inflate(6));
      await tester.tap(find.byKey(const Key('coach-next')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
    }
  });

  testWidgets('the ring keeps pulsing without breaking the frame', (tester) async {
    await pumpPage(tester, threeSteps);
    await start(tester);

    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('coach-overlay')), findsOneWidget);
  });

  testWidgets('fits a small phone with large text', (tester) async {
    await pumpPage(
      tester,
      threeSteps,
      textScale: 1.6,
      size: const Size(320, 568),
    );
    await start(tester);

    for (var index = 0; index < 3; index++) {
      expect(tester.takeException(), isNull, reason: 'step $index');
      await tester.tap(find.byKey(const Key('coach-next')));
      await tester.pump(const Duration(milliseconds: 400));
    }
  });
}
