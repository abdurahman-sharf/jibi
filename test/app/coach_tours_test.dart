import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/coach_tours.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';
import 'package:jibi/shared/widgets/coach_marks.dart';

/// Lets the zero-length wait of the host pass, the route open and its
/// animation finish. (Awaiting the host's future without pumping would wait
/// forever under the test's fake clock.)
Future<void> _showing(WidgetTester tester) async {
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  final target = GlobalKey(debugLabel: 'target');
  late Set<String> seen;
  late bool enabled;
  late CoachTourHost host;
  late List<String> marked;

  setUp(() {
    seen = {};
    marked = [];
    enabled = true;
    host = CoachTourHost(
      isEnabled: () => enabled,
      isSeen: seen.contains,
      markSeen: (id) async {
        marked.add(id);
        seen.add(id);
      },
      delay: Duration.zero,
      retryDelay: Duration.zero,
    );
  });

  List<CoachStep> steps() => [
    CoachStep(target: target, title: 'هدف', message: 'رسالة'),
  ];

  Future<BuildContext> pump(
    WidgetTester tester, {
    Widget? extra,
    bool ticking = true,
    bool withScope = true,
    void Function(BuildContext)? onFrame,
  }) async {
    late BuildContext captured;
    final inner =
        extra ??
        Scaffold(
          body: Center(
            child: ElevatedButton(
              key: target,
              onPressed: () {},
              child: const Text('زر'),
            ),
          ),
        );
    final page = TickerMode(
      enabled: ticking,
      child: Builder(
        builder: (context) {
          captured = context;
          return inner;
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        builder: (context, child) => Directionality(
          textDirection: TextDirection.rtl,
          child: withScope ? CoachScope(host: host, child: child!) : child!,
        ),
        home: page,
      ),
    );
    return captured;
  }

  group('CoachTourHost', () {
    testWidgets('shows a tour once and remembers it', (tester) async {
      final context = await pump(tester);

      final future = host.startOnce(context, CoachTourIds.home, steps);
      await _showing(tester);
      expect(find.byKey(const Key('coach-overlay')), findsOneWidget);
      expect(host.isRunning, isTrue);

      await tester.tap(find.byKey(const Key('coach-next')));
      await tester.pumpAndSettle();

      expect(await future, CoachTourResult.finished);
      expect(marked, [CoachTourIds.home]);
      expect(host.isRunning, isFalse);

      // A second request finds it seen and does nothing.
      final again = host.startOnce(context, CoachTourIds.home, steps);
      await _showing(tester);
      expect(await again, isNull);
      expect(find.byKey(const Key('coach-overlay')), findsNothing);
    });

    testWidgets('a skipped tour counts as seen', (tester) async {
      // Two visible targets, so the first hint has a "skip" button.
      final second = GlobalKey(debugLabel: 'second');
      final context = await pump(
        tester,
        extra: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                ElevatedButton(key: target, onPressed: () {}, child: const Text('أ')),
                ElevatedButton(key: second, onPressed: () {}, child: const Text('ب')),
              ],
            ),
          ),
        ),
      );
      final future = host.startOnce(
        context,
        CoachTourIds.account,
        () => [
          CoachStep(target: target, title: 'أول', message: 'a'),
          CoachStep(target: second, title: 'ثان', message: 'b'),
        ],
      );
      await _showing(tester);
      await tester.tap(find.byKey(const Key('coach-skip')));
      await tester.pumpAndSettle();

      expect(await future, CoachTourResult.skipped);
      expect(marked, [CoachTourIds.account]);
    });

    testWidgets('does nothing while the hints are switched off', (tester) async {
      final context = await pump(tester);
      enabled = false;

      expect(await host.startOnce(context, CoachTourIds.home, steps), isNull);
      expect(marked, isEmpty);
      expect(find.byKey(const Key('coach-overlay')), findsNothing);
    });

    testWidgets('a tour that found nothing to point at is not counted', (
      tester,
    ) async {
      final context = await pump(tester);

      final future = host.startOnce(
        context,
        CoachTourIds.accounts,
        () => [CoachStep(target: GlobalKey(), title: 'x', message: 'y')],
      );
      await _showing(tester);

      expect(await future, CoachTourResult.nothingToShow);
      expect(marked, isEmpty);
      expect(host.isRunning, isFalse);
    });

    testWidgets('only one tour runs at a time', (tester) async {
      final context = await pump(tester);

      final first = host.startOnce(context, CoachTourIds.home, steps);
      await _showing(tester);
      final second = host.startOnce(context, CoachTourIds.accounts, steps);
      await _showing(tester);

      expect(await second, isNull);
      await tester.tap(find.byKey(const Key('coach-next')));
      await tester.pumpAndSettle();
      await first;
      expect(marked, [CoachTourIds.home]);
    });

    testWidgets('a screen that is no longer in front gets no hints', (
      tester,
    ) async {
      final context = await pump(tester);

      final future = host.startOnce(
        context,
        CoachTourIds.home,
        steps,
        stillApplicable: () => false,
      );
      await _showing(tester);

      expect(await future, isNull);
      expect(marked, isEmpty);
      expect(find.byKey(const Key('coach-overlay')), findsNothing);
    });
  });

  group('startTourOnce', () {
    testWidgets('starts from a screen that is in front', (tester) async {
      final context = await pump(tester);

      context.startTourOnce(CoachTourIds.home, steps);
      await _showing(tester);

      expect(find.byKey(const Key('coach-overlay')), findsOneWidget);
    });

    testWidgets('waits for a tab that is not showing', (tester) async {
      final context = await pump(tester, ticking: false);

      context.startTourOnce(CoachTourIds.home, steps);
      await _showing(tester);

      expect(find.byKey(const Key('coach-overlay')), findsNothing);
      expect(marked, isEmpty);
    });

    testWidgets('does nothing when the app runs no tours', (tester) async {
      final context = await pump(tester, withScope: false);

      context.startTourOnce(CoachTourIds.home, steps);
      await _showing(tester);

      expect(find.byKey(const Key('coach-overlay')), findsNothing);
    });
  });
}
