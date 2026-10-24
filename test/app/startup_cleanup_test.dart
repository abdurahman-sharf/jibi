import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/core/security/security.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/memory_keys.dart' show MemoryKeys, NoBiometrics;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'starting the app deletes decrypted temporary files left by a crash',
    () async {
      final directory = await Directory.systemTemp.createTemp('jibi-startup-');
      final temporary = Directory(
        '${directory.path}${Platform.pathSeparator}temporary_documents',
      )..createSync(recursive: true);
      // A decrypted document or report that a killed process never removed.
      final leftover = File(
        '${temporary.path}${Platform.pathSeparator}jibi-doc-leftover.pdf',
      )..writeAsBytesSync([1, 2, 3]);
      // Something that is not one of ours must be left alone.
      final foreign = File(
        '${temporary.path}${Platform.pathSeparator}notes.txt',
      )..writeAsStringSync('keep');
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: NoBiometrics(),
      );
      await security.initialize(pin: '123456');

      final app = await JibiApplication.create(
        directory: directory,
        securityService: security,
      );
      try {
        expect(leftover.existsSync(), isFalse);
        expect(foreign.existsSync(), isTrue);
      } finally {
        await app.dispose();
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          // Windows keeps SQLite handles briefly after close.
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
