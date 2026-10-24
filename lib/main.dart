import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:jibi/app/jibi_app.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/app/startup_error.dart';
import 'package:jibi/core/security/kdf.dart';
import 'package:jibi/features/reminders/data/local_notification_scheduler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _keepErrorDetailsOutOfTheLog();
  // 600k-iteration PBKDF2 would otherwise freeze the UI for seconds when a PIN
  // is checked or a backup is created. `Kdf` itself arms native (Android)
  // PBKDF2 acceleration where it is safe to, isolate by isolate, with a
  // pure-Dart fallback on any failure — see kdf.dart. Nothing else in the app
  // touches `Cryptography.instance`: AES-GCM (all stored data) and every
  // other cipher keep using the plain, always-correct pure-Dart path, so this
  // performance fix cannot affect data encryption/decryption.
  Kdf.useBackgroundIsolate = true;
  try {
    final application = await JibiApplication.create(
      notificationScheduler: LocalNotificationScheduler(),
    );
    final initialized = await application.security.isInitialized;
    runApp(
      JibiApp(
        application: application,
        initialView: initialized
            ? JibiInitialView.shell
            : JibiInitialView.onboarding,
        showTips: true,
      ),
    );
  } on Object catch (error, stackTrace) {
    debugPrint('Jibi startup failed: ${error.runtimeType}');
    if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
    runApp(startupErrorApp(error));
  }
}

/// In a release build an uncaught error would print its whole message to the
/// system log, and a failed database call carries the SQL and its arguments
/// (names, amounts). Only the error type is kept there; debug builds keep the
/// full report for developers.
void _keepErrorDetailsOutOfTheLog() {
  if (!kReleaseMode) return;
  FlutterError.onError = (details) {
    debugPrint('Jibi framework error: ${details.exception.runtimeType}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Jibi error: ${error.runtimeType}');
    return true;
  };
}
