import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/jibi_app_shell.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';

class _Opener extends StatelessWidget {
  const _Opener({required this.page, required this.label});

  final Widget page;
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      onPressed: () => pushShellPage<void>(context, page),
      child: Text(label),
    ),
  );
}

Widget _shell({
  List<JibiQuickAction>? quickActions,
  ThemeData? theme,
  ValueChanged<String>? onAction,
}) {
  final actions =
      quickActions ??
      [
        JibiQuickAction(
          label: 'سلفة',
          description: 'وصف السلفة',
          icon: Icons.swap_horiz,
          onPressed: () => onAction?.call('سلفة'),
        ),
        JibiQuickAction(
          label: 'مصروف',
          icon: Icons.receipt_long_outlined,
          onPressed: () => onAction?.call('مصروف'),
        ),
      ];
  return MaterialApp(
    theme: theme ?? JibiTheme.light(),
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: JibiAppShell(
        appBar: AppBar(title: const Text('الشريط العلوي')),
        quickActions: actions,
        tabs: [
          JibiShellTab(
            label: 'الرئيسية',
            icon: Icons.home_outlined,
            selectedIcon: Icons.home,
            child: _Opener(
              label: 'افتح التفاصيل',
              page: Scaffold(
                appBar: AppBar(title: const Text('صفحة التفاصيل')),
                body: const TextField(),
              ),
            ),
          ),
          const JibiShellTab(
            label: 'الحسابات',
            icon: Icons.people_outline,
            selectedIcon: Icons.people,
            child: Center(child: Text('محتوى الحسابات')),
          ),
          const JibiShellTab(
            label: 'المرور',
            icon: Icons.key_outlined,
            selectedIcon: Icons.key,
            child: Center(child: Text('محتوى المرور')),
          ),
          const JibiShellTab(
            label: 'المستندات',
            icon: Icons.folder_outlined,
            selectedIcon: Icons.folder,
            child: Center(child: Text('محتوى المستندات')),
          ),
        ],
      ),
    ),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('quick-add is docked in the middle of the bar', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_shell());

    final fab = tester.getRect(find.byType(FloatingActionButton));
    final bar = tester.getRect(find.byType(BottomAppBar));
    final second = tester.getCenter(find.text('الحسابات'));
    final third = tester.getCenter(find.text('المرور'));

    expect(fab.center.dx, closeTo(390 / 2, 1));
    // Docked: the button straddles the top edge of the bar instead of
    // floating above it.
    expect(fab.top, lessThan(bar.top));
    expect(fab.bottom, greaterThan(bar.top));
    // The gap sits between the second and third destinations, not on them.
    expect(fab.contains(second), isFalse);
    expect(fab.contains(third), isFalse);
    expect(
      (third.dx - second.dx).abs(),
      greaterThan(fab.width),
      reason: 'destinations leave room for the notch',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('bar and button share the theme colours in both modes', (
    tester,
  ) async {
    _phone(tester);
    for (final theme in [JibiTheme.light(), JibiTheme.dark()]) {
      await tester.pumpWidget(_shell(theme: theme));
      await tester.pumpAndSettle();

      final button = tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      final resolved = Theme.of(
        tester.element(find.byType(FloatingActionButton)),
      );
      expect(
        resolved.floatingActionButtonTheme.backgroundColor,
        theme.colorScheme.primary,
      );
      expect(button.backgroundColor, isNull, reason: 'colours come from theme');
      expect(button.shape, isNull, reason: 'shape comes from theme');
      final bar = tester.widget<PhysicalShape>(
        find
            .descendant(
              of: find.byType(BottomAppBar),
              matching: find.byType(PhysicalShape),
            )
            .first,
      );
      expect(bar.color, theme.bottomAppBarTheme.color);
    }
  });

  testWidgets('sheet lists actions and runs the chosen one after closing', (
    tester,
  ) async {
    _phone(tester);
    final chosen = <String>[];
    await tester.pumpWidget(_shell(onAction: chosen.add));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('إضافة سريعة'), findsOneWidget);
    expect(find.text('سلفة'), findsOneWidget);
    expect(find.text('وصف السلفة'), findsOneWidget);
    expect(find.text('مصروف'), findsOneWidget);

    await tester.tap(find.text('مصروف'));
    await tester.pumpAndSettle();
    expect(chosen, ['مصروف']);
    expect(find.text('إضافة سريعة'), findsNothing);
  });

  testWidgets('button and top bar disappear on pushed pages only', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_shell());
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('الشريط العلوي'), findsOneWidget);

    await tester.tap(find.text('افتح التفاصيل'));
    await tester.pumpAndSettle();

    expect(find.text('صفحة التفاصيل'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('الشريط العلوي'), findsNothing);
    // The bar itself stays so tabs remain reachable.
    expect(find.text('الحسابات'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('الشريط العلوي'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('re-tapping the active tab returns to its root', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_shell());
    await tester.tap(find.text('افتح التفاصيل'));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);

    await tester.tap(find.text('الرئيسية'));
    await tester.pumpAndSettle();

    expect(find.text('صفحة التفاصيل'), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('button and bar hide while the keyboard is open', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_shell());
    expect(find.byType(BottomAppBar), findsOneWidget);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(BottomAppBar), findsNothing);
    expect(tester.takeException(), isNull);

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byType(BottomAppBar), findsOneWidget);
  });

  testWidgets('no quick actions means no button and no gap', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_shell(quickActions: const []));

    expect(find.byType(FloatingActionButton), findsNothing);
    final second = tester.getCenter(find.text('الحسابات'));
    final third = tester.getCenter(find.text('المرور'));
    final first = tester.getCenter(find.text('الرئيسية'));
    // Evenly spaced destinations when nothing is docked in the middle.
    expect(
      (third.dx - second.dx).abs(),
      closeTo((second.dx - first.dx).abs(), 1),
    );
  });

  group('back button', () {
    late List<MethodCall> platformCalls;

    setUp(() {
      platformCalls = [];
    });

    Future<void> pressBack(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    testWidgets('pops the tab, then goes to the first tab, then exits', (
      tester,
    ) async {
      _phone(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(_shell());

      await tester.tap(find.text('افتح التفاصيل'));
      await tester.pumpAndSettle();
      await pressBack(tester);
      expect(find.text('صفحة التفاصيل'), findsNothing);
      expect(find.text('افتح التفاصيل'), findsOneWidget);

      await tester.tap(find.text('المستندات'));
      await tester.pumpAndSettle();
      expect(find.text('محتوى المستندات'), findsOneWidget);
      await pressBack(tester);
      expect(find.text('افتح التفاصيل'), findsOneWidget);
      expect(
        platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
        isEmpty,
      );

      await pressBack(tester);
      expect(
        platformCalls.where((call) => call.method == 'SystemNavigator.pop'),
        hasLength(1),
      );
    });
  });
}
