import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:jibi/core/backup/encrypted_local_backup_service.dart';
import 'package:jibi/core/database/app_database.dart';
import 'package:jibi/core/database/sqlite_jibi_repository.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';
import 'package:jibi/core/security/security.dart';
import 'package:jibi/core/storage/secure_file_storage.dart';
import 'package:jibi/features/credentials/credentials.dart';
import 'package:jibi/features/documents/documents_controller.dart';
import 'package:jibi/features/documents/models/document_draft.dart';

void main() {
  late Directory sandbox;
  late AppDatabase appDatabase;
  late SqliteJibiRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    sandbox = Directory(
      'test${Platform.pathSeparator}_sqlite_integration_test',
    );
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
    await sandbox.create(recursive: true);
    appDatabase = AppDatabase(
      path: File('${sandbox.path}${Platform.pathSeparator}database.sqlite')
          .absolute
          .path,
    );
    repository = SqliteJibiRepository(appDatabase);
  });

  tearDown(() async {
    await repository.dispose();
    await appDatabase.close();
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test(
    'upgrades version 3 to the current schema and keeps the currencies it seeded',
    () async {
      final legacy = await openDatabase(
        appDatabase.path,
        version: 3,
        onCreate: (db, version) async {
          await db.transaction((txn) async {
            await const MigrationV1().apply(txn);
            await const MigrationV2().apply(txn);
            await const MigrationV3().apply(txn);
          });
        },
      );
      await legacy.close();
      final database = await appDatabase.database;
      expect(await database.getVersion(), AppDatabase.schemaVersion);
      // v13 keeps the three shipped currencies (the unused seeded ones go).
      expect(await repository.findCurrency('SAR'), isNotNull);
      expect(await repository.findCurrency('YER'), isNotNull);
      expect(await repository.findCurrency('USD'), isNotNull);
      expect(
        Sqflite.firstIntValue(await database.rawQuery('SELECT COUNT(*) FROM currencies')),
        3,
      );
    },
  );

  test(
    'migrates the complete schema and persists encrypted vault fields',
    () async {
      final database = await appDatabase.database;
      expect(await database.getVersion(), AppDatabase.schemaVersion);
      // The expenses feature is gone (schema v9).
      final tables = <String>{
        for (final row in await database.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ))
          row['name']! as String,
      };
      expect(tables, isNot(contains('expenses')));
      expect(tables, isNot(contains('expense_categories')));

      final security = await _initializedSecurity();
      final vault = CredentialVaultController(
        repository: repository,
        securityService: security,
        clipboard: SensitiveClipboardController(clipboard: _Clipboard()),
        createId: () => 'credential-id',
      );
      await vault.create(
        const CredentialInput(
          title: 'Gmail',
          username: 'owner@example.com',
          email: 'owner@example.com',
          password: 'plaintext-must-not-reach-sqlite',
          notes: 'private note',
        ),
      );

      final row = (await database.query('credentials')).single;
      expect(
        row['password_encrypted'],
        isNot(contains('plaintext-must-not-reach-sqlite')),
      );
      expect(
        await repository.watchCredentials(query: 'Gmail').first,
        hasLength(1),
      );
      expect(
        await repository
            .watchCredentials(query: 'plaintext-must-not-reach-sqlite')
            .first,
        isEmpty,
      );
    },
  );

  test(
    'enforces attachment references across document file deletion',
    () async {
      final now = DateTime.utc(2026, 9, 5);
      await repository.saveDocument(
        Document(
          id: 'document-id',
          title: 'Identity',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.saveDocumentFile(
        DocumentFile(
          id: 'file-id',
          documentId: 'document-id',
          encryptedFileName: 'file-id.enc',
          originalExtension: 'pdf',
          mimeType: 'application/pdf',
          encryptedSizeBytes: 4,
          checksum: List<String>.filled(64, 'a').join(),
          createdAt: now,
        ),
      );
      final attachment = AttachmentRef(
        id: 'attachment-ref-id',
        ownerType: AttachmentOwnerType.expense,
        ownerId: 'expense-id',
        documentFileId: 'file-id',
        createdAt: now,
      );
      await repository.addAttachmentReference(attachment);

      final references = await repository.listAttachmentReferences('file-id');
      expect(references, hasLength(1));
      expect(references.single.id, attachment.id);
      expect(references.single.documentFileId, attachment.documentFileId);
      await expectLater(
        repository.deleteDocumentFile('file-id'),
        throwsA(isA<ConflictException>()),
      );

      await repository.removeAttachmentReference(attachment.id);
      expect(await repository.listAttachmentReferences('file-id'), isEmpty);
      await repository.deleteDocumentFile('file-id');
      await repository.deleteDocument('document-id');
    },
  );

  test('creates and restores a PIN-encrypted local backup', () async {
    final security = await _initializedSecurity();
    final fileStorage = FileSystemSecureFileStorage(
      encryptedDirectory: Directory(
        '${sandbox.path}${Platform.pathSeparator}encrypted',
      ),
      temporaryDirectory: Directory(
        '${sandbox.path}${Platform.pathSeparator}temporary',
      ),
      securityService: security,
      idGenerator: () => 'encrypted-file',
    );
    final documents = DocumentsController(
      repository: repository,
      fileStorage: fileStorage,
      securityService: security,
      idGenerator: () => 'document-id',
      clock: () => DateTime.utc(2026, 9, 5),
    );
    final source = File('${sandbox.path}${Platform.pathSeparator}passport.pdf');
    await source.writeAsBytes(utf8.encode('document plaintext'));
    final document = await documents.createDocument(
      DocumentDraft(title: 'Passport', documentNumber: 'P12345678'),
    );
    await documents.importFile(
      documentId: document.id,
      request: FileImportRequest(
        sourceFile: source,
        originalExtension: 'pdf',
        mimeType: 'application/pdf',
      ),
    );
    // Any row of the database travels with a backup; a tag stands in.
    Future<List<Map<String, Object?>>> tagRows() async =>
        (await appDatabase.database).query('tags');
    await (await appDatabase.database).insert('tags', <String, Object?>{
      'id': 'tag-id',
      'name': 'Ahmed',
    });
    final backup = File('${sandbox.path}${Platform.pathSeparator}backup.jibi');
    final service = EncryptedLocalBackupService(
      database: appDatabase,
      securityService: security,
      encryptedFilesDirectory: Directory(
        '${sandbox.path}${Platform.pathSeparator}encrypted',
      ),
      rollbackDirectory: Directory(
        '${sandbox.path}${Platform.pathSeparator}rollbacks',
      ),
      clock: () => DateTime.utc(2026, 9, 5),
    );

    final descriptor = await service.createLocalBackup(
      destination: backup,
      recoveryPassword: '123456',
    );
    // The manifest counts the accounts of the book; this test has none.
    expect(descriptor.manifest.numberOfAccounts, 0);
    expect(descriptor.manifest.numberOfAttachments, 1);
    expect(
      latin1.decode(await backup.readAsBytes(), allowInvalid: true),
      isNot(contains('document plaintext')),
    );
    await (await appDatabase.database).delete(
      'tags',
      where: 'id = ?',
      whereArgs: <Object?>['tag-id'],
    );
    expect(await tagRows(), isEmpty);

    await service.restoreLocalBackup(
      source: backup,
      recoveryPassword: '123456',
    );

    expect((await tagRows()).single['name'], 'Ahmed');
    expect(await repository.listFiles('document-id'), hasLength(1));
    expect(
      (await service.inspect(backup)).databaseSchemaVersion,
      AppDatabase.schemaVersion,
    );

    final tampered = File(
      '${sandbox.path}${Platform.pathSeparator}tampered_backup.jibi',
    );
    final bytes = await backup.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await tampered.writeAsBytes(bytes);
    await expectLater(
      service.restoreLocalBackup(source: tampered, recoveryPassword: '123456'),
      throwsA(
        isA<SecurityException>().having(
          (error) => error.code,
          'code',
          'backup_authentication_failed',
        ),
      ),
    );
    expect((await tagRows()).single['name'], 'Ahmed');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<AesGcmSecurityService> _initializedSecurity() async {
  final security = AesGcmSecurityService(
    keyStore: _MemoryKeyStore(),
    biometricAuthenticator: const _Biometric(),
  );
  await security.initialize(pin: '123456');
  return security;
}

final class _MemoryKeyStore implements SecureKeyStore {
  final Map<String, Uint8List> _values = <String, Uint8List>{};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<Uint8List?> read(String key) async {
    final value = _values[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    _values[key] = Uint8List.fromList(value);
  }
}

final class _Biometric implements BiometricAuthenticator {
  const _Biometric();

  @override
  Future<bool> authenticate({required String reason}) async => true;

  @override
  Future<bool> canAuthenticate() async => true;
}

final class _Clipboard implements ClipboardPort {
  String? _value;

  @override
  Future<String?> readText() async => _value;

  @override
  Future<void> writeText(String value) async {
    _value = value;
  }
}
