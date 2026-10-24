import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/shared/widgets/pin_field.dart';
import 'package:jibi/shared/widgets/pin_prompt.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
);

bool _obscured(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).obscureText;

void main() {
  testWidgets('starts hidden and the eye shows and hides the digits', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(PinField(controller: controller, label: 'رمز PIN')),
    );

    expect(_obscured(tester), isTrue);
    expect(find.byTooltip('إظهار الرمز'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.byKey(const Key('pin-field-eye')));
    await tester.pump();
    expect(_obscured(tester), isFalse);
    expect(find.byTooltip('إخفاء الرمز'), findsOneWidget);
    // Showing the digits never changes what was typed.
    expect(controller.text, '123456');

    await tester.tap(find.byKey(const Key('pin-field-eye')));
    await tester.pump();
    expect(_obscured(tester), isTrue);
    expect(controller.text, '123456');
  });

  testWidgets('accepts digits only and reports submit', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String? submitted;
    await tester.pumpWidget(
      _host(
        PinField(
          controller: controller,
          label: 'رمز PIN',
          onSubmitted: (value) => submitted = value,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '12ab34-56 ');
    expect(controller.text, '123456');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(submitted, '123456');
  });

  testWidgets('shows its label and an error message', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        PinField(
          controller: controller,
          label: 'تأكيد رمز PIN',
          errorText: 'الرمزان غير متطابقين.',
        ),
      ),
    );

    expect(find.text('تأكيد رمز PIN'), findsOneWidget);
    expect(find.text('الرمزان غير متطابقين.'), findsOneWidget);
  });

  testWidgets('every PIN dialog of the app offers the eye', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final result = askPinDialog(context, title: 'تأكيد', message: 'أدخل الرمز');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pin-field-eye')), findsOneWidget);
    expect(_obscured(tester), isTrue);
    await tester.tap(find.byKey(const Key('pin-field-eye')));
    await tester.pump();
    expect(_obscured(tester), isFalse);

    await tester.enterText(find.byKey(const Key('pin-prompt-input')), '246810');
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();
    expect(await result, '246810');
  });
}
