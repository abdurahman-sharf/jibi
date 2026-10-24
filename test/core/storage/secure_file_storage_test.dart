import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/models/encrypted_value.dart';
import 'package:jibi/core/security/security_service.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = Directory(
      'test${Platform.pathSeparator}_secure_file_storage_test',
    );
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
    await sandbox.create(recursive: true);
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('encrypts imports and cleans up decrypted temporary files', () async {
    final source = File('${sandbox.path}${Platform.pathSeparator}passport.jpg');
    final plaintext = Uint8List.fromList(<int>[1, 2, 3, 4]);
    await source.writeAsBytes(plaintext);
    final security = _RecordingSecurityService();
    final ids = <String>[
      'encrypted-file',
      'temporary-file',
      'temporary-file-2',
    ].iterator;
    final storage = FileSystemSecureFileStorage(
      encryptedDirectory: Directory(
        '${sandbox.path}${Platform.pathSeparator}encrypted',
      ),
      temporaryDirectory: Directory(
        '${sandbox.path}${Platform.pathSeparator}temporary',
      ),
      securityService: security,
      idGenerator: () {
        ids.moveNext();
        return ids.current;
      },
    );

    final file = await storage.importFile(
      documentId: 'document-id',
      request: FileImportRequest(
        sourceFile: source,
        originalExtension: '.JPG',
        mimeType: 'image/jpeg',
      ),
    );
    final encrypted = File(
      '${sandbox.path}${Platform.pathSeparator}encrypted'
      '${Platform.pathSeparator}${file.encryptedFileName}',
    );

    expect(file.encryptedFileName, 'encrypted-file.enc');
    expect(file.originalExtension, 'jpg');
    expect(await encrypted.exists(), isTrue);
    expect(await encrypted.readAsBytes(), isNot(equals(plaintext)));
    expect(security.encryptedInputs, <List<int>>[
      <int>[1, 2, 3, 4],
    ]);
    expect(file.checksum, matches(RegExp(r'^[a-f0-9]{64}$')));

    final temporary = await storage.openTemporaryFile(file);
    expect(await temporary.file.readAsBytes(), plaintext);
    expect(temporary.file.path, contains('jibi-doc-temporary-file.jpg'));
    await temporary.delete();
    await temporary.delete();
    expect(await temporary.file.exists(), isFalse);

    final anotherTemporary = await storage.openTemporaryFile(file);
    expect(await anotherTemporary.file.exists(), isTrue);
    await storage.cleanupTemporaryFiles();
    expect(await anotherTemporary.file.exists(), isFalse);
    expect(await storage.encryptedStorageSizeBytes(), await encrypted.length());
  });
}

final class _RecordingSecurityService implements SecurityService {
  final List<List<int>> encryptedInputs = <List<int>>[];

  @override
  Stream<AppLockState> get lockStates => const Stream<AppLockState>.empty();

  @override
  Future<AuthenticationResult> authenticateBiometrically() =>
      Future<AuthenticationResult>.value(
        const AuthenticationResult(authenticated: false),
      );

  @override
  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) async {}

  @override
  Future<void> completeRecoverySetup({required String pin}) async {}

  @override
  Future<Uint8List> decryptBytes(Uint8List ciphertext) async {
    return Uint8List.fromList(ciphertext.skip(1).toList().reversed.toList());
  }

  @override
  Future<String> decryptText(EncryptedValue encrypted) async =>
      throw UnimplementedError();

  @override
  Future<Uint8List> encryptBytes(Uint8List plaintext) async {
    encryptedInputs.add(List<int>.from(plaintext));
    return Uint8List.fromList(<int>[99, ...plaintext.reversed]);
  }

  @override
  Future<EncryptedValue> encryptText(String plaintext) async =>
      throw UnimplementedError();

  @override
  Future<bool> get isInitialized => Future<bool>.value(true);

  @override
  Future<bool> get isRecoverySetupPending => Future<bool>.value(false);

  @override
  Future<void> initialize({required String pin}) async {}

  @override
  Future<void> lock() async {}

  @override
  Future<AuthenticationResult> reauthenticate() =>
      Future<AuthenticationResult>.value(
        const AuthenticationResult(authenticated: false),
      );

  @override
  Future<void> restoreWrappedDataKey({
    required Uint8List wrappedKey,
    required String recoveryPassword,
  }) async {}

  @override
  Future<AuthenticationResult> unlockWithPin(String pin) =>
      Future<AuthenticationResult>.value(
        const AuthenticationResult(authenticated: false),
      );

  @override
  Future<bool> verifyPin(String pin) => Future<bool>.value(false);

  @override
  Future<Uint8List> wrapDataKeyForRecovery(String recoveryPassword) =>
      Future<Uint8List>.value(Uint8List(0));
}
