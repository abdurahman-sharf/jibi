import 'dart:io';

final class BackupManifest {
  const BackupManifest({
    required this.backupFormatVersion,
    required this.databaseSchemaVersion,
    required this.appVersion,
    required this.createdAt,
    required this.encryptionVersion,
    this.numberOfAccounts = 0,
    this.numberOfCredentials = 0,
    this.numberOfDocuments = 0,
    this.numberOfAttachments = 0,
  });

  final int backupFormatVersion;
  final int databaseSchemaVersion;
  final String appVersion;
  final DateTime createdAt;
  final int encryptionVersion;
  final int numberOfAccounts;
  final int numberOfCredentials;
  final int numberOfDocuments;
  final int numberOfAttachments;
}

final class BackupDescriptor {
  const BackupDescriptor({
    required this.id,
    required this.createdAt,
    required this.sizeBytes,
    required this.manifest,
    this.remoteId,
  });

  final String id;
  final DateTime createdAt;
  final int sizeBytes;
  final BackupManifest manifest;
  final String? remoteId;
}

/// A backup just created by the application layer: the encrypted file, its
/// descriptor, and the name to offer when sharing it as a ZIP.
final class CreatedBackup {
  const CreatedBackup({
    required this.file,
    required this.descriptor,
    required this.shareName,
  });

  final File file;
  final BackupDescriptor descriptor;
  final String shareName;
}

abstract interface class BackupService {
  Future<BackupDescriptor> createLocalBackup({
    required File destination,
    required String recoveryPassword,
  });
  Future<BackupManifest> inspect(File source);

  /// Must validate fully and create a current backup before replacing data.
  Future<void> restoreLocalBackup({
    required File source,
    required String recoveryPassword,
  });
}
