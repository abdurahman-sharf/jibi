import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_app_shell.dart';
import 'package:jibi/shared/theme/jibi_theme.dart';
import 'package:jibi/shared/widgets/jibi_onboarding.dart';

void main() {
  testWidgets('onboarding offers restore before creating a new PIN', (
    tester,
  ) async {
    var restoreCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: JibiOnboardingFlow(
          onRestoreRequested: () async {
            restoreCalls += 1;
            return true;
          },
        ),
      ),
    );

    await tester.tap(find.text('استعادة نسخة من هاتف سابق'));
    await tester.pumpAndSettle();

    expect(restoreCalls, 1);
    expect(find.text('رمز PIN الرئيسي'), findsOneWidget);
  });

  testWidgets('onboarding advances and can be skipped', (tester) async {
    var completed = false;
    var biometricsEnabled = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: JibiTheme.light(),
        home: JibiOnboardingFlow(
          onCompleted: () => completed = true,
          onBiometricPreferenceChanged: (value) => biometricsEnabled = value,
        ),
      ),
    );

    expect(find.text('أهلاً بك في جيبي'), findsOneWidget);
    await tester.tap(find.text('ابدأ'));
    await tester.pumpAndSettle();
    // The tour of the features comes before the PIN step.
    await tester.tap(find.byKey(const Key('walkthrough-skip')));
    await tester.pumpAndSettle();
    expect(find.text('رمز PIN الرئيسي'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(biometricsEnabled, isTrue);
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إنهاء الإعداد'));

    expect(completed, isTrue);
  });

  testWidgets('shell switches destinations and quick-add runs its action', (
    tester,
  ) async {
    var selected = -1;
    var actionCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: JibiAppShell(
            onDestinationSelected: (index) => selected = index,
            quickActions: [
              JibiQuickAction(
                label: 'أضف الأولى',
                icon: Icons.add,
                onPressed: () => actionCount += 1,
              ),
            ],
            tabs: const [
              JibiShellTab(
                label: 'الأولى',
                icon: Icons.home_outlined,
                selectedIcon: Icons.home,
                child: Text('المحتوى الأول'),
              ),
              JibiShellTab(
                label: 'الثانية',
                icon: Icons.key_outlined,
                selectedIcon: Icons.key,
                child: Text('المحتوى الثاني'),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('المحتوى الأول'), findsOneWidget);
    await tester.tap(find.text('الثانية'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(find.text('المحتوى الثاني'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أضف الأولى'));
    await tester.pumpAndSettle();
    expect(actionCount, 1);
  });

  testWidgets('app uses RTL and offers system theme selection', (tester) async {
    await tester.pumpWidget(const JibiApp(initialView: JibiInitialView.shell));

    expect(
      tester
          .widgetList<Directionality>(find.byType(Directionality))
          .any((widget) => widget.textDirection == TextDirection.rtl),
      isTrue,
    );
    await tester.tap(find.byTooltip('المظهر'));
    await tester.pumpAndSettle();
    expect(find.text('حسب النظام'), findsOneWidget);
    expect(find.text('فاتح'), findsOneWidget);
    expect(find.text('داكن'), findsOneWidget);
  });
}
