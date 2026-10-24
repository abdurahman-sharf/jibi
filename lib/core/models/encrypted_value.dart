import 'model_validation.dart';

/// Opaque, versioned ciphertext suitable for persistence only.
final class EncryptedValue {
  EncryptedValue(String value) : value = requireText(value, 'encrypted_value');

  final String value;

  @override
  String toString() => 'EncryptedValue([redacted])';
}
