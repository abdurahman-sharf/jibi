import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/jibi_app_shell.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';

class _Opener extends StatelessWidget {
  const _Opener({required this.label, required this.page});

  final String label;
  final Widget page;

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      onPressed: () => pushShellPage<void>(context, page),
      child: Text(label),
    ),
  );
}

/// The production arrangement: four normal tabs (home, accounts, passwords,
/// documents) plus a lazy "reports" tab that only the accounts bar shows.
Widget _shell({
  required List<String> log,
  List<String>? builds,
  int initialIndex = 0,
}) => MaterialApp(
  theme: JibiTheme.light(),
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: JibiAppShell(
      initialIndex: initialIndex,
      appBar: AppBar(title: const Text('الشريط العلوي')),
      quickActions: [
        JibiQuickAction(
          label: 'إجراء عادي',
          icon: Icons.add,
          onPressed: () => log.add('normal'),
        ),
      ],
      barTabIndices: const [0, 1, 2, 3],
      alternateLayout: JibiShellLayout(
        activeWhen: const {1, 4},
        primaryIndex: 1,
        items: [
          const JibiBarItem.tab(0),
          const JibiBarItem.tab(1),
          const JibiBarItem.tab(4),
          JibiBarItem.action(
            label: 'الإعدادات',
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            onPressed: () => log.add('settings'),
          ),
        ],
        quickActions: [
          JibiQuickAction(
            label: 'عملية جديدة',
            icon: Icons.receipt_long_outlined,
            onPressed: () => log.add('accounts-add'),
          ),
        ],
      ),
      tabs: [
        const JibiShellTab(
          label: 'الرئيسية',
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
          child: Center(child: Text('محتوى الرئيسية')),
        ),
        JibiShellTab(
          label: 'الحسابات',
          icon: Icons.category_outlined,
          selectedIcon: Icons.category,
          child: _Opener(
            label: 'افتح تصنيفاً',
            page: const Scaffold(body: Center(child: Text('صفحة التصنيف'))),
          ),
        ),
        const JibiShellTab(
          label: 'كلمات المرور',
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
        JibiShellTab(
          label: 'التقارير',
          icon: Icons.bar_chart_outlined,
          selectedIcon: Icons.bar_chart,
          lazy: true,
          child: Builder(
            builder: (_) {
              builds?.add('reports');
              return const Center(child: Text('محتوى التقارير'));
            },
          ),
        ),
      ],
    ),
  ),
);

Finder _barText(String label) =>
    find.descendant(of: find.byType(BottomAppBar), matching: find.text(label));

Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starts with the normal bar and its own quick actions', (
    tester,
  ) async {
    final log = <String>[];
    await _pump(tester, _shell(log: log));

    for (final label in ['الرئيسية', 'الحسابات', 'كلمات المرور', 'المستندات']) {
      expect(_barText(label), findsOneWidget, reason: label);
    }
    expect(_barText('التقارير'), findsNothing);
    expect(_barText('الإعدادات'), findsNothing);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('إجراء عادي'), findsOneWidget);
    expect(find.text('عملية جديدة'), findsNothing);
  });

  testWidgets('entering accounts swaps the bar; home swaps it back', (
    tester,
  ) async {
    final log = <String>[];
    await _pump(tester, _shell(log: log));

    await tester.tap(_barText('الحسابات'));
    await tester.pumpAndSettle();

    // The accounts bar: home, accounts, reports, settings.
    for (final label in ['الرئيسية', 'الحسابات', 'التقارير', 'الإعدادات']) {
      expect(_barText(label), findsOneWidget, reason: label);
    }
    expect(_barText('كلمات المرور'), findsNothing);
    expect(_barText('المستندات'), findsNothing);
    expect(find.text('افتح تصنيفاً'), findsOneWidget);

    await tester.tap(_barText('الرئيسية'));
    await tester.pumpAndSettle();
    expect(find.text('محتوى الرئيسية'), findsOneWidget);
    expect(_barText('كلمات المرور'), findsOneWidget);
    expect(_barText('التقارير'), findsNothing);
  });

  testWidgets('the accounts bar keeps its "+" and its own actions on pushed pages', (
    tester,
  ) async {
    final log = <String>[];
    await _pump(tester, _shell(log: log));
    await tester.tap(_barText('الحسابات'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افتح تصنيفاً'));
    await tester.pumpAndSettle();

    expect(find.text('صفحة التصنيف'), findsOneWidget);
    // The bar and the "+" stay on a page pushed inside the accounts tab.
    expect(find.byType(BottomAppBar), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('عملية جديدة'), findsOneWidget);
    expect(find.text('إجراء عادي'), findsNothing);
    await tester.tap(find.text('عملية جديدة'));
    await tester.pumpAndSettle();
    expect(log, ['accounts-add']);
  });

  testWidgets('the normal bar shows its "+" on the root of a normal tab', (
    tester,
  ) async {
    final log = <String>[];
    await _pump(tester, _shell(log: log, initialIndex: 2));
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('the settings slot runs its action and does not change tabs', (
    tester,
  ) async {
    final log = <String>[];
    await _pump(tester, _shell(log: log));
    await tester.tap(_barText('الحسابات'));
    await tester.pumpAndSettle();

    await tester.tap(_barText('الإعدادات'));
    await tester.pumpAndSettle();

    expect(log, ['settings']);
    // Still on the accounts tab with the accounts bar.
    expect(find.text('افتح تصنيفاً'), findsOneWidget);
    expect(_barText('التقارير'), findsOneWidget);
  });

  testWidgets('the reports tab is built lazily, on first visit only', (
    tester,
  ) async {
    final log = <String>[];
    final builds = <String>[];
    await _pump(tester, _shell(log: log, builds: builds));
    expect(builds, isEmpty);

    await tester.tap(_barText('الحسابات'));
    await tester.pumpAndSettle();
    expect(builds, isEmpty);

    await tester.tap(_barText('التقارير'));
    await tester.pumpAndSettle();
    expect(find.text('محتوى التقارير'), findsOneWidget);
    expect(builds, ['reports']);

    await tester.tap(_barText('الحسابات'));
    await tester.pumpAndSettle();
    await tester.tap(_barText('التقارير'));
    await tester.pumpAndSettle();
    expect(builds, ['reports']);
  });

  testWidgets('Back goes reports -> accounts -> home -> leaves the app', (
    tester,
  ) async {
    final log = <String>[];
    var systemPops = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') systemPops++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester, _shell(log: log));
    await tester.tap(_barText('الحسابات'));
    await tester.pumpAndSettle();
    await tester.tap(_barText('التقارير'));
    await tester.pumpAndSettle();
    expect(find.text('محتوى التقارير'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // Back from reports lands on accounts, still with the accounts bar.
    expect(find.text('افتح تصنيفاً'), findsOneWidget);
    expect(_barText('التقارير'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('محتوى الرئيسية'), findsOneWidget);
    expect(_barText('كلمات المرور'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(systemPops, 1);
  });

  testWidgets('Back pops a pushed category page before changing tab', (
    tester,
  ) async {
    final log = <String>[];
    await _pump(tester, _shell(log: log));
    await tester.tap(_barText('الحسابات'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افتح تصنيفاً'));
    await tester.pumpAndSettle();
    expect(find.text('صفحة التصنيف'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('صفحة التصنيف'), findsNothing);
    expect(find.text('افتح تصنيفاً'), findsOneWidget);
    expect(_barText('التقارير'), findsOneWidget);
  });

  testWidgets('without an alternate layout the shell behaves as before', (
    tester,
  ) async {
    await _pump(
      tester,
      MaterialApp(
        theme: JibiTheme.light(),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: JibiAppShell(
            tabs: const [
              JibiShellTab(
                label: 'أ',
                icon: Icons.home_outlined,
                selectedIcon: Icons.home,
                child: Center(child: Text('محتوى أ')),
              ),
              JibiShellTab(
                label: 'ب',
                icon: Icons.key_outlined,
                selectedIcon: Icons.key,
                child: Center(child: Text('محتوى ب')),
              ),
            ],
          ),
        ),
      ),
    );
    expect(_barText('أ'), findsOneWidget);
    expect(_barText('ب'), findsOneWidget);
    await tester.tap(_barText('ب'));
    await tester.pumpAndSettle();
    expect(find.text('محتوى ب'), findsOneWidget);
  });
}
