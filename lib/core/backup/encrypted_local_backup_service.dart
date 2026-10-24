import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

import '../app_info.dart';
import '../database/app_database.dart';
import '../errors/app_exception.dart';
import '../models/encrypted_value.dart';
import '../security/security_primitives.dart';
import '../security/security_service.dart';
import 'backup_service.dart';

/// Versioned encrypted backup container for an app-private SQLite database and
/// encrypted document files. It deliberately has no Google Drive transport.
final class EncryptedLocalBackupService implements BackupService {
  EncryptedLocalBackupService({
    required AppDatabase database,
    required SecurityService securityService,
    required Directory encryptedFilesDirectory,
    Directory? rollbackDirectory,
    DateTime Function()? clock,
  }) : _database = database,
       _securityService = securityService,
       _encryptedFilesDirectory = encryptedFilesDirectory,
       _rollbackDirectory = rollbackDirectory,
       _clock = clock ?? DateTime.now;

  static const _magic = 'JIBI_BACKUP_V1\n';
  static const _backupFormatVersion = 1;
  static const _encryptionVersion = 1;
  static const _kdfIterations = 600000;
  static const _saltLength = 16;
  static const _nonceLength = 12;
  static const _keyCheck = 'jibi-backup-key-check-v1';
  static const _appVersion = String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: AppInfo.version,
  );

  final AppDatabase _database;
  final SecurityService _securityService;
  final Directory _encryptedFilesDirectory;
  final Directory? _rollbackDirectory;
  final DateTime Function() _clock;
  final AesGcm _cipher = AesGcm.with256bits();

  @override
  Future<BackupDescriptor> createLocalBackup({
    required File destination,
    required String recoveryPassword,
  }) async {
    validateBackupPin(recoveryPassword);
    final snapshot = await _captureCurrentData();
    final manifest = BackupManifest(
      backupFormatVersion: _backupFormatVersion,
      databaseSchemaVersion: AppDatabase.schemaVersion,
      appVersion: _appVersion,
      createdAt: _clock().toUtc(),
      encryptionVersion: _encryptionVersion,
      numberOfAccounts: snapshot.accountCount,
      numberOfCredentials: snapshot.credentialCount,
      numberOfDocuments: snapshot.documentCount,
      numberOfAttachments: snapshot.files.length,
    );
    final wrappedDataKey = await _securityService.wrapDataKeyForRecovery(
      recoveryPassword,
    );
    final keyCheck = await _securityService.encryptText(_keyCheck);
    final payload = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object>{
          'manifest': _manifestToJson(manifest),
          'wrappedDataKey': base64UrlEncode(wrappedDataKey),
          'keyCheck': keyCheck.value,
          'database': base64UrlEncode(snapshot.databaseBytes),
          'files': [
            for (final file in snapshot.files)
              <String, Object>{
                'name': file.name,
                'bytes': base64UrlEncode(file.bytes),
              },
          ],
        }),
      ),
    );

    final salt = secureRandomBytes(_saltLength);
    final encryptionKey = await deriveKeyFromSecret(recoveryPassword, salt, _kdfIterations);
    final nonce = secureRandomBytes(_nonceLength);
    final encrypted = await _cipher.encrypt(
      payload,
      secretKey: encryptionKey,
      nonce: nonce,
    );
    final header = _BackupHeader(
      manifest: manifest,
      salt: salt,
      nonce: Uint8List.fromList(encrypted.nonce),
      mac: Uint8List.fromList(encrypted.mac.bytes),
    );

    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.partial');
    try {
      await partial.writeAsBytes(
        _encodeContainer(header, Uint8List.fromList(encrypted.cipherText)),
        flush: true,
      );
      if (await destination.exists()) {
        await destination.delete();
      }
      await partial.rename(destination.path);
    } on Object catch (error) {
      throw StorageException(
        code: 'backup_write_failed',
        userMessage: 'تعذر إنشاء النسخة الاحتياطية المحلية.',
        cause: error,
      );
    } finally {
      if (await partial.exists()) {
        await partial.delete();
      }
    }

    return BackupDescriptor(
      id: _backupId(destination),
      createdAt: manifest.createdAt,
      sizeBytes: await destination.length(),
      manifest: manifest,
    );
  }

  @override
  Future<BackupManifest> inspect(File source) async {
    final container = await _readContainer(source);
    return container.header.manifest;
  }

  @override
  Future<void> restoreLocalBackup({
    required File source,
    required String recoveryPassword,
  }) async {
    validateBackupPin(recoveryPassword);
    final decoded = await _decodeAndValidate(source, recoveryPassword);
    final initialized = await _securityService.isInitialized;
    if (initialized) {
      await _validateCurrentKey(decoded.keyCheck);
    } else {
      if (await _securityService.isRecoverySetupPending) {
        throw const SecurityException(
          code: 'recovery_setup_pending',
          userMessage: 'أكمل إعداد رمز الدخول قبل استعادة نسخة أخرى.',
        );
      }
      await _securityService.restoreWrappedDataKey(
        wrappedKey: decoded.wrappedDataKey,
        recoveryPassword: recoveryPassword,
      );
      await _validateCurrentKey(decoded.keyCheck);
    }

    if (initialized) {
      final rollback = File(
        '${(await _rollbackRoot()).path}${Platform.pathSeparator}'
        'before_restore_${_clock().toUtc().millisecondsSinceEpoch}.jibi',
      );
      await createLocalBackup(
        destination: rollback,
        recoveryPassword: recoveryPassword,
      );
    }

    await _replaceCurrentData(decoded);
  }

  /// Every encrypted file the database points at: the document vault's and
  /// the files owned by book attachments (migrated attachments only reference
  /// vault files, so they add nothing here). Backup, restore validation and
  /// the manifest count must all use this one set.
  static const _encryptedFilesQuery =
      'SELECT encrypted_file_name, checksum FROM document_files '
      'UNION '
      'SELECT encrypted_file_name, checksum FROM book_attachments '
      'WHERE encrypted_file_name IS NOT NULL '
      'ORDER BY encrypted_file_name ASC';

  Future<_CapturedData> _captureCurrentData() async {
    final database = await _database.database;
    final accountCount = await _count(database, 'book_accounts');
    final credentialCount = await _count(database, 'credentials');
    final documentCount = await _count(database, 'documents');
    final rows = await database.rawQuery(_encryptedFilesQuery);
    // wal_checkpoint returns a result row, so it must be executed as a query.
    // Keeping the shared database open also prevents active screens and
    // repository streams from failing while a backup is being prepared.
    try {
      await database.rawQuery('PRAGMA wal_checkpoint(FULL)');
    } on Object catch (error) {
      throw StorageException(
        code: 'backup_checkpoint_failed',
        userMessage: 'تعذر تجهيز قاعدة البيانات للنسخة الاحتياطية.',
        cause: error,
      );
    }

    try {
      final databaseFile = File(_database.path);
      if (!await databaseFile.exists()) {
        throw const StorageException(
          code: 'database_missing',
          userMessage: 'تعذر العثور على البيانات المحلية.',
        );
      }
      final files = <_BackupFile>[];
      for (final row in rows) {
        final name = row['encrypted_file_name']! as String;
        _validateEncryptedFileName(name);
        final file = File(
          '${_encryptedFilesDirectory.path}${Platform.pathSeparator}$name',
        );
        if (!await file.exists()) {
          throw const StorageException(
            code: 'backup_attachment_missing',
            userMessage: 'تعذر العثور على أحد الملفات المرفقة.',
          );
        }
        final bytes = await file.readAsBytes();
        final hash = await Sha256().hash(bytes);
        final checksum = hash.bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        if (checksum != row['checksum']) {
          throw const StorageException(
            code: 'backup_attachment_checksum_mismatch',
            userMessage: 'تعذر التحقق من سلامة أحد الملفات المرفقة.',
          );
        }
        files.add(_BackupFile(name, bytes));
      }
      return _CapturedData(
        databaseBytes: await databaseFile.readAsBytes(),
        files: files,
        accountCount: accountCount,
        credentialCount: credentialCount,
        documentCount: documentCount,
      );
    } on AppException {
      rethrow;
    } on Object catch (error) {
      throw StorageException(
        code: 'backup_snapshot_failed',
        userMessage: 'تعذر تجهيز النسخة الاحتياطية المحلية.',
        cause: error,
      );
    }
  }

  Future<_DecodedBackup> _decodeAndValidate(
    File source,
    String recoveryPassword,
  ) async {
    final container = await _readContainer(source);
    final manifest = container.header.manifest;
    if (manifest.backupFormatVersion != _backupFormatVersion ||
        manifest.encryptionVersion != _encryptionVersion ||
        manifest.databaseSchemaVersion > AppDatabase.schemaVersion) {
      throw const ValidationException(
        code: 'unsupported_backup_version',
        userMessage: 'إصدار النسخة الاحتياطية غير مدعوم.',
      );
    }
    try {
      final key = await deriveKeyFromSecret(
        recoveryPassword,
        container.header.salt,
        _kdfIterations,
      );
      final clearBytes = await _cipher.decrypt(
        SecretBox(
          container.ciphertext,
          nonce: container.header.nonce,
          mac: Mac(container.header.mac),
        ),
        secretKey: key,
      );
      final payload =
          jsonDecode(utf8.decode(clearBytes)) as Map<String, Object?>;
      final payloadManifest = _manifestFromJson(
        payload['manifest']! as Map<String, Object?>,
      );
      if (!_sameManifest(manifest, payloadManifest)) {
        throw const FormatException('Header and payload differ.');
      }
      final databaseBytes = base64Url.decode(
        base64Url.normalize(payload['database']! as String),
      );
      if (databaseBytes.length < 16 ||
          utf8.decode(databaseBytes.sublist(0, 16), allowMalformed: true) !=
              'SQLite format 3\u0000') {
        throw const FormatException('Invalid SQLite payload.');
      }
      final files = <_BackupFile>[];
      final fileValues = payload['files']! as List<Object?>;
      for (final value in fileValues) {
        final file = value! as Map<String, Object?>;
        final name = file['name']! as String;
        _validateEncryptedFileName(name);
        files.add(
          _BackupFile(
            name,
            Uint8List.fromList(
              base64Url.decode(base64Url.normalize(file['bytes']! as String)),
            ),
          ),
        );
      }
      if (files.length != manifest.numberOfAttachments) {
        throw const FormatException('Attachment count differs.');
      }
      return _DecodedBackup(
        manifest: manifest,
        databaseBytes: Uint8List.fromList(databaseBytes),
        files: files,
        wrappedDataKey: Uint8List.fromList(
          base64Url.decode(
            base64Url.normalize(payload['wrappedDataKey']! as String),
          ),
        ),
        keyCheck: payload['keyCheck']! as String,
      );
    } on AppException {
      rethrow;
    } on Object catch (error) {
      throw SecurityException(
        code: 'backup_authentication_failed',
        userMessage: 'تعذر التحقق من كلمة الاستعادة أو سلامة النسخة.',
        cause: error,
      );
    }
  }

  Future<void> _validateCurrentKey(String encryptedCheck) async {
    final check = await _securityService.decryptText(
      EncryptedValue(encryptedCheck),
    );
    if (check != _keyCheck) {
      throw const SecurityException(
        code: 'backup_key_mismatch',
        userMessage: 'هذه النسخة الاحتياطية تخص مفتاح حماية مختلف.',
      );
    }
  }

  Future<void> _replaceCurrentData(_DecodedBackup backup) async {
    final databaseFile = File(_database.path);
    final databasePartial = File('${databaseFile.path}.restore.partial');
    final databasePrevious = File('${databaseFile.path}.restore.previous');
    final filesPartial = Directory('${_encryptedFilesDirectory.path}.restore');
    final filesPrevious = Directory(
      '${_encryptedFilesDirectory.path}.previous',
    );
    await _writeRestoredFiles(filesPartial, backup.files);
    await databasePartial.writeAsBytes(backup.databaseBytes, flush: true);

    await _database.close();
    var databaseMoved = false;
    var filesMoved = false;
    try {
      if (await databasePrevious.exists()) {
        await databasePrevious.delete();
      }
      if (await filesPrevious.exists()) {
        await filesPrevious.delete(recursive: true);
      }
      if (await databaseFile.exists()) {
        await databaseFile.rename(databasePrevious.path);
        databaseMoved = true;
      }
      if (await _encryptedFilesDirectory.exists()) {
        await _encryptedFilesDirectory.rename(filesPrevious.path);
        filesMoved = true;
      }
      await databasePartial.rename(databaseFile.path);
      await filesPartial.rename(_encryptedFilesDirectory.path);

      final restored = await _database.database;
      final integrity = await restored.rawQuery('PRAGMA integrity_check');
      if (integrity.single.values.single != 'ok') {
        throw const FormatException('SQLite integrity check failed.');
      }
      await _validateRestoredAttachments(
        restored,
        expectedCount: backup.manifest.numberOfAttachments,
      );
      if (await databasePrevious.exists()) {
        await databasePrevious.delete();
      }
      if (await filesPrevious.exists()) {
        await filesPrevious.delete(recursive: true);
      }
    } on Object catch (error) {
      await _database.close();
      if (await databaseFile.exists()) {
        await databaseFile.delete();
      }
      if (databaseMoved && await databasePrevious.exists()) {
        await databasePrevious.rename(databaseFile.path);
      }
      if (await _encryptedFilesDirectory.exists()) {
        await _encryptedFilesDirectory.delete(recursive: true);
      }
      if (filesMoved && await filesPrevious.exists()) {
        await filesPrevious.rename(_encryptedFilesDirectory.path);
      }
      throw StorageException(
        code: 'backup_restore_failed',
        userMessage: 'تعذر استعادة النسخة دون تغيير بياناتك الحالية.',
        cause: error,
      );
    } finally {
      if (await databasePartial.exists()) {
        await databasePartial.delete();
      }
      if (await filesPartial.exists()) {
        await filesPartial.delete(recursive: true);
      }
    }
  }

  Future<void> _writeRestoredFiles(
    Directory destination,
    List<_BackupFile> files,
  ) async {
    if (await destination.exists()) {
      await destination.delete(recursive: true);
    }
    await destination.create(recursive: true);
    for (final file in files) {
      await File('${destination.path}${Platform.pathSeparator}${file.name}')
          .writeAsBytes(file.bytes, flush: true);
    }
  }

  Future<void> _validateRestoredAttachments(
    Database database, {
    required int expectedCount,
  }) async {
    final rows = await database.rawQuery(_encryptedFilesQuery);
    if (rows.length != expectedCount) {
      throw const FormatException('Database attachment count differs.');
    }
    for (final row in rows) {
      final name = row['encrypted_file_name']! as String;
      _validateEncryptedFileName(name);
      final bytes = await File(
        '${_encryptedFilesDirectory.path}${Platform.pathSeparator}$name',
      ).readAsBytes();
      final hash = await Sha256().hash(bytes);
      final checksum = hash.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (checksum != row['checksum']) {
        throw const FormatException('Attachment checksum differs.');
      }
    }
  }

  Future<_BackupContainer> _readContainer(File source) async {
    try {
      final bytes = await source.readAsBytes();
      final magic = utf8.encode(_magic);
      if (bytes.length < magic.length + 4 ||
          !constantTimeEquals(bytes.sublist(0, magic.length), magic)) {
        throw const FormatException('Unexpected backup header.');
      }
      final headerLength = ByteData.sublistView(
        bytes.sublist(magic.length, magic.length + 4),
      ).getUint32(0, Endian.big);
      final headerStart = magic.length + 4;
      final ciphertextStart = headerStart + headerLength;
      if (headerLength < 2 || ciphertextStart >= bytes.length) {
        throw const FormatException('Incomplete backup.');
      }
      final rawHeader = jsonDecode(
        utf8.decode(bytes.sublist(headerStart, ciphertextStart)),
      ) as Map<String, Object?>;
      return _BackupContainer(
        header: _BackupHeader.fromJson(rawHeader),
        ciphertext: Uint8List.fromList(bytes.sublist(ciphertextStart)),
      );
    } on AppException {
      rethrow;
    } on Object catch (error) {
      throw StorageException(
        code: 'backup_unreadable',
        userMessage: 'تعذر قراءة ملف النسخة الاحتياطية.',
        cause: error,
      );
    }
  }

  Uint8List _encodeContainer(_BackupHeader header, Uint8List ciphertext) {
    final magic = utf8.encode(_magic);
    final encodedHeader = utf8.encode(jsonEncode(header.toJson()));
    final prefix = ByteData(4)..setUint32(0, encodedHeader.length, Endian.big);
    return Uint8List.fromList(<int>[
      ...magic,
      ...prefix.buffer.asUint8List(),
      ...encodedHeader,
      ...ciphertext,
    ]);
  }

  Future<Directory> _rollbackRoot() async {
    final root = _rollbackDirectory ?? _encryptedFilesDirectory.parent;
    await root.create(recursive: true);
    return root;
  }

  static Future<int> _count(Database database, String table) async =>
      Sqflite.firstIntValue(
        await database.rawQuery('SELECT COUNT(*) FROM $table'),
      ) ??
      0;

  static Map<String, Object> _manifestToJson(BackupManifest manifest) =>
      <String, Object>{
        'backupFormatVersion': manifest.backupFormatVersion,
        'databaseSchemaVersion': manifest.databaseSchemaVersion,
        'appVersion': manifest.appVersion,
        'createdAt': manifest.createdAt.toUtc().toIso8601String(),
        'encryptionVersion': manifest.encryptionVersion,
        'numberOfAccounts': manifest.numberOfAccounts,
        'numberOfCredentials': manifest.numberOfCredentials,
        'numberOfDocuments': manifest.numberOfDocuments,
        'numberOfAttachments': manifest.numberOfAttachments,
      };

  static BackupManifest _manifestFromJson(Map<String, Object?> json) =>
      BackupManifest(
        backupFormatVersion: json['backupFormatVersion']! as int,
        databaseSchemaVersion: json['databaseSchemaVersion']! as int,
        appVersion: json['appVersion']! as String,
        createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
        encryptionVersion: json['encryptionVersion']! as int,
        numberOfAccounts: json['numberOfAccounts']! as int,
        numberOfCredentials: json['numberOfCredentials']! as int,
        numberOfDocuments: json['numberOfDocuments']! as int,
        numberOfAttachments: json['numberOfAttachments']! as int,
      );

  static bool _sameManifest(BackupManifest left, BackupManifest right) =>
      left.backupFormatVersion == right.backupFormatVersion &&
      left.databaseSchemaVersion == right.databaseSchemaVersion &&
      left.appVersion == right.appVersion &&
      left.createdAt == right.createdAt &&
      left.encryptionVersion == right.encryptionVersion &&
      left.numberOfAccounts == right.numberOfAccounts &&
      left.numberOfCredentials == right.numberOfCredentials &&
      left.numberOfDocuments == right.numberOfDocuments &&
      left.numberOfAttachments == right.numberOfAttachments;

  static String _backupId(File destination) =>
      destination.uri.pathSegments.isEmpty
      ? destination.path
      : destination.uri.pathSegments.last;

  static void _validateEncryptedFileName(String name) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*\.enc$').hasMatch(name)) {
      throw const ValidationException(
        code: 'invalid_backup_attachment_name',
        userMessage: 'ملف النسخة يحتوي على اسم مرفق غير صالح.',
      );
    }
  }
}

final class _BackupHeader {
  const _BackupHeader({
    required this.manifest,
    required this.salt,
    required this.nonce,
    required this.mac,
  });

  factory _BackupHeader.fromJson(Map<String, Object?> json) => _BackupHeader(
    manifest: EncryptedLocalBackupService._manifestFromJson(
      json['manifest']! as Map<String, Object?>,
    ),
    salt: Uint8List.fromList(
      base64Url.decode(base64Url.normalize(json['salt']! as String)),
    ),
    nonce: Uint8List.fromList(
      base64Url.decode(base64Url.normalize(json['nonce']! as String)),
    ),
    mac: Uint8List.fromList(
      base64Url.decode(base64Url.normalize(json['mac']! as String)),
    ),
  );

  final BackupManifest manifest;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List mac;

  Map<String, Object> toJson() => <String, Object>{
    'manifest': EncryptedLocalBackupService._manifestToJson(manifest),
    'salt': base64UrlEncode(salt),
    'nonce': base64UrlEncode(nonce),
    'mac': base64UrlEncode(mac),
  };
}

final class _BackupContainer {
  const _BackupContainer({required this.header, required this.ciphertext});

  final _BackupHeader header;
  final Uint8List ciphertext;
}

final class _BackupFile {
  const _BackupFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

final class _CapturedData {
  const _CapturedData({
    required this.databaseBytes,
    required this.files,
    required this.accountCount,
    required this.credentialCount,
    required this.documentCount,
  });

  final Uint8List databaseBytes;
  final List<_BackupFile> files;
  final int accountCount;
  final int credentialCount;
  final int documentCount;
}

final class _DecodedBackup {
  const _DecodedBackup({
    required this.manifest,
    required this.databaseBytes,
    required this.files,
    required this.wrappedDataKey,
    required this.keyCheck,
  });

  final BackupManifest manifest;
  final Uint8List databaseBytes;
  final List<_BackupFile> files;
  final Uint8List wrappedDataKey;
  final String keyCheck;
}
