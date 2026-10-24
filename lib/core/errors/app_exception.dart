/// Failures safe to expose to the presentation layer.
sealed class AppException implements Exception {
  const AppException({
    required this.code,
    required this.userMessage,
    this.cause,
  });

  final String code;
  final String userMessage;

  /// Internal diagnostic only; never render or log it without redaction.
  final Object? cause;

  @override
  String toString() => 'AppException($code)';
}

final class ValidationException extends AppException {
  const ValidationException({required super.code, required super.userMessage});
}

final class NotFoundException extends AppException {
  const NotFoundException({required super.code, required super.userMessage});
}

final class ConflictException extends AppException {
  const ConflictException({required super.code, required super.userMessage});
}

final class StorageException extends AppException {
  const StorageException({
    required super.code,
    required super.userMessage,
    super.cause,
  });
}

final class SecurityException extends AppException {
  const SecurityException({
    required super.code,
    required super.userMessage,
    super.cause,
  });
}

final class BackupException extends AppException {
  const BackupException({
    required super.code,
    required super.userMessage,
    super.cause,
  });
}
