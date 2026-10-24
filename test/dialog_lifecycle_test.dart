import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/shared/widgets/jibi_feedback.dart';

void main() {
  testWidgets('dialog controller survives the reverse transition', (
    tester,
  ) async {
    var disposed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  final controller = TextEditingController();
                  try {
                    await showJibiDialog<String>(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          content: TextField(
                            controller: controller,
                            autofocus: true,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () {
                                Navigator.pop(context, controller.text);
                              },
                              child: const Text('close'),
                            ),
                          ],
                        );
                      },
                    );
                  } finally {
                    controller.dispose();
                    disposed = true;
                  }
                },
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'test recovery value');
    await tester.tap(find.text('close'));
    await tester.pump();
    expect(disposed, isFalse);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(disposed, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
