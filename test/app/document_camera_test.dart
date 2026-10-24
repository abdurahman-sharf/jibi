import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/app/jibi_application.dart';
import 'package:jibi/app/jibi_feature_pages.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/core/storage/document_source_picker.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';
import 'package:jibi/shared/widgets/external_activity_scope.dart';

import '../support/memory_keys.dart' show MemoryKeys, NoBiometrics;

class _FakePicker implements DocumentSourcePicker {
  _FakePicker(this.photo, {this.failure});

  final File? photo;
  final AppException? failure;
  int captures = 0;

  @override
  Future<FileImportRequest?> captureImage() async {
    captures += 1;
    if (failure != null) throw failure!;
    final file = photo;
    return file == null
        ? null
        : FileImportRequest(
            sourceFile: file,
            originalExtension: 'jpg',
            mimeType: 'image/jpeg',
          );
  }

  @override
  Future<FileImportRequest?> pickFile() async => null;
}

void main() {
  late Directory directory;
  late JibiApplication app;

  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<void> createApp(WidgetTester tester) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('jibi-camera-');
      final security = AesGcmSecurityService(
        keyStore: MemoryKeys(),
        biometricAuthenticator: NoBiometrics(),
      );
      await security.initialize(pin: '123456');
      app = await JibiApplication.create(
        directory: directory,
        securityService: security,
      );
    });
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await app.dispose();
      await directory.delete(recursive: true);
    });
  }

  Future<File> makePhoto(WidgetTester tester) async {
    final photo = await tester.runAsync(() async {
      final file = File('${directory.path}${Platform.pathSeparator}shot.jpg');
      await file.writeAsBytes(List<int>.filled(64, 7));
      return file;
    });
    return photo!;
  }

  testWidgets('captured photo is listed, encrypted on save, and cache removed', (
    tester,
  ) async {
    await createApp(tester);
    final photo = await makePhoto(tester);
    final picker = _FakePicker(photo);
    var duringCapture = false;
    final guarded = _GuardProbe(app, onCapture: () => duringCapture = true);

    await tester.pumpWidget(
      MaterialApp(
        home: ExternalActivityScope(
          run: guarded.run,
          child: DocumentFormPage(controller: app.documents, picker: picker),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'جواز السفر');
    final camera = find.text('التقاط صورة بالكاميرا');
    await tester.ensureVisible(camera);
    await tester.tap(camera);
    await tester.pumpAndSettle();

    expect(picker.captures, 1);
    expect(guarded.runs, 1, reason: 'capture runs inside the external guard');
    expect(duringCapture, isTrue);
    expect(find.text('shot.jpg'), findsOneWidget);

    final save = find.widgetWithText(FilledButton, 'حفظ');
    await tester.ensureVisible(save);
    await tester.runAsync(() async {
      await tester.tap(save);
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();

    final documents = await tester.runAsync(
      () => app.documents.watchDocuments().first,
    );
    expect(documents!.single.title, 'جواز السفر');
    final files = await tester.runAsync(
      () => app.documents.listFiles(documents.single.id),
    );
    expect(files, hasLength(1));
    expect(files!.single.mimeType, 'image/jpeg');
    expect(
      await tester.runAsync(photo.exists),
      isFalse,
      reason: 'the plaintext photo must not stay in the cache',
    );
    await tearDownApp(tester);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('cancelling the camera adds nothing', (tester) async {
    await createApp(tester);
    final picker = _FakePicker(null);

    await tester.pumpWidget(
      MaterialApp(
        home: DocumentFormPage(controller: app.documents, picker: picker),
      ),
    );
    final camera = find.text('التقاط صورة بالكاميرا');
    await tester.ensureVisible(camera);
    await tester.tap(camera);
    await tester.pumpAndSettle();

    expect(picker.captures, 1);
    expect(find.textContaining('.jpg'), findsNothing);
    expect(tester.takeException(), isNull);
    await tearDownApp(tester);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a missing camera app shows its own message', (tester) async {
    await createApp(tester);
    final picker = _FakePicker(
      null,
      failure: const StorageException(
        code: 'document_capture_failed',
        userMessage: 'لا يوجد تطبيق كاميرا على هذا الجهاز.',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentFormPage(controller: app.documents, picker: picker),
        ),
      ),
    );
    final camera = find.text('التقاط صورة بالكاميرا');
    await tester.ensureVisible(camera);
    await tester.tap(camera);
    await tester.pumpAndSettle();

    expect(find.text('لا يوجد تطبيق كاميرا على هذا الجهاز.'), findsOneWidget);
    await tearDownApp(tester);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Records that the external-activity guard was active while the platform
/// call ran, by delegating to the real application guard.
class _GuardProbe {
  _GuardProbe(this.app, {required this.onCapture});

  final JibiApplication app;
  final VoidCallback onCapture;
  int runs = 0;

  Future<T> run<T>(
    Future<T> Function() action, {
    bool holdUntilResumed = false,
  }) {
    runs += 1;
    return app.runExternalActivity(() {
      if (app.isExternalActivityInProgress) onCapture();
      return action();
    }, holdUntilResumed: holdUntilResumed);
  }
}
