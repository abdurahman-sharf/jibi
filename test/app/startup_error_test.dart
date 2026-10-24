import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/app/startup_error.dart';
import 'package:jibi/core/errors/app_exception.dart';

void main() {
  test('an upgrade failure reports its own message and safety', () {
    const error = StorageException(
      code: 'database_migration_failed',
      userMessage: 'تعذر تحديث قاعدة البيانات. بياناتك سليمة ولم تتغير.',
    );
    final text = startupFailureText(error);
    expect(text.title, 'تعذر تحديث بياناتك');
    expect(text.message, contains('بياناتك سليمة'));
  });

  test('a snapshot failure is an upgrade failure too', () {
    const error = StorageException(
      code: 'migration_snapshot_failed',
      userMessage: 'تعذر إنشاء نسخة أمان.',
    );
    expect(startupFailureText(error).title, 'تعذر تحديث بياناتك');
  });

  test('any other failure keeps the generic device-security message', () {
    expect(startupFailureText(StateError('x')).title, 'تعذر تشغيل جيبي');
    expect(
      startupFailureText(
        const SecurityException(code: 'keystore', userMessage: 'سر'),
      ).message,
      contains('إعدادات أمان الجهاز'),
    );
  });

  testWidgets('the error app renders the message in RTL', (tester) async {
    await tester.pumpWidget(
      startupErrorApp(
        const StorageException(
          code: 'database_migration_failed',
          userMessage: 'بياناتك سليمة.',
        ),
      ),
    );
    expect(find.text('تعذر تحديث بياناتك'), findsOneWidget);
    expect(find.text('بياناتك سليمة.'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.text('بياناتك سليمة.'))),
      TextDirection.rtl,
    );
  });
}
