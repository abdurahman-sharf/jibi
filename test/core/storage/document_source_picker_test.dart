import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/storage/document_source_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.jibi.jibi/document_source_picker');
  const picker = AndroidDocumentSourcePicker.withChannel(channel);
  late Directory sandbox;

  void mock(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('jibi-picker-');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('captureImage asks the platform for a photo and wraps the file', () async {
    final photo = File('${sandbox.path}${Platform.pathSeparator}shot.jpg');
    await photo.writeAsBytes(const [1, 2, 3]);
    MethodCall? received;
    mock((call) async {
      received = call;
      return <String, Object>{
        'path': photo.path,
        'extension': 'jpg',
        'mimeType': 'image/jpeg',
      };
    });

    final request = await picker.captureImage();

    expect(received?.method, 'captureDocument');
    expect(request?.sourceFile.path, photo.path);
    expect(request?.originalExtension, 'jpg');
    expect(request?.mimeType, 'image/jpeg');
  });

  test('captureImage returns null when the user cancels', () async {
    mock((call) async => null);

    expect(await picker.captureImage(), isNull);
  });

  test('a missing camera app gets a specific message', () async {
    mock((call) async => throw PlatformException(code: 'no_camera_app'));

    await expectLater(
      picker.captureImage(),
      throwsA(
        isA<StorageException>().having(
          (error) => error.userMessage,
          'userMessage',
          'لا يوجد تطبيق كاميرا على هذا الجهاز.',
        ),
      ),
    );
  });

  test('other camera failures use the generic capture message', () async {
    mock((call) async => throw PlatformException(code: 'camera_failed'));

    await expectLater(
      picker.captureImage(),
      throwsA(
        isA<StorageException>().having(
          (error) => error.userMessage,
          'userMessage',
          'تعذر التقاط الصورة.',
        ),
      ),
    );
  });

  test('a photo that vanished from the cache is rejected safely', () async {
    mock(
      (call) async => <String, Object>{
        'path': '${sandbox.path}${Platform.pathSeparator}gone.jpg',
        'extension': 'jpg',
        'mimeType': 'image/jpeg',
      },
    );

    await expectLater(
      picker.captureImage(),
      throwsA(isA<StorageException>()),
    );
  });

  test('pickFile still uses the document picker method', () async {
    MethodCall? received;
    mock((call) async {
      received = call;
      return null;
    });

    expect(await picker.pickFile(), isNull);
    expect(received?.method, 'pickDocument');
  });
}
