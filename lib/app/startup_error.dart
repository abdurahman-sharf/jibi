import 'package:flutter/material.dart';

import '../core/errors/app_exception.dart';
import '../shared/theme/jibi_theme.dart';
import '../shared/widgets/jibi_feedback.dart';

/// Codes of failures that happen while the database is being upgraded. The
/// upgrade is atomic, so the data is untouched when one of them is reported.
const Set<String> databaseUpgradeFailureCodes = <String>{
  'database_migration_failed',
  'migration_snapshot_failed',
  'migration_snapshot_invalid',
};

/// What the user is told when the app cannot start.
({String title, String message}) startupFailureText(Object error) {
  if (error is AppException && databaseUpgradeFailureCodes.contains(error.code)) {
    return (title: 'تعذر تحديث بياناتك', message: error.userMessage);
  }
  return (
    title: 'تعذر تشغيل جيبي',
    message: 'تحقق من إعدادات أمان الجهاز ثم أعد تشغيل التطبيق.',
  );
}

/// The app shown instead of the normal one when startup fails.
Widget startupErrorApp(Object error) {
  final text = startupFailureText(error);
  return MaterialApp(
    theme: JibiTheme.light(),
    darkTheme: JibiTheme.dark(),
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: JibiErrorState(title: text.title, message: text.message),
      ),
    ),
  );
}
