import 'package:flutter_test/flutter_test.dart';
import 'package:jibi/core/errors/app_exception.dart';
import 'package:jibi/core/models/models.dart';

void main() {
  final createdAt = DateTime.utc(2026, 1, 1);
  final updatedAt = DateTime.utc(2026, 1, 2);

  test('credential only accepts opaque encrypted sensitive values', () {
    final credential = Credential(
      id: 'credential-id',
      title: 'Gmail',
      usernameEncrypted: EncryptedValue('v1:ciphertext'),
      emailEncrypted: EncryptedValue('v1:ciphertext'),
      passwordEncrypted: EncryptedValue('v1:ciphertext'),
      notesEncrypted: EncryptedValue('v1:ciphertext'),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

    expect(
      credential.passwordEncrypted.toString(),
      'EncryptedValue([redacted])',
    );
  });

  test('document preserves encrypted-only sensitive metadata fields', () {
    final suppliedTags = <String>['travel'];
    final document = Document(
      id: 'document-id',
      title: 'Passport',
      documentNumberEncrypted: EncryptedValue('v1:number'),
      issuerEncrypted: EncryptedValue('v1:issuer'),
      notesEncrypted: EncryptedValue('v1:notes'),
      issueDate: DateTime.utc(2025, 1, 1),
      expiryDate: DateTime.utc(2030, 1, 1),
      tagIds: suppliedTags,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

    expect(
      document.documentNumberEncrypted!.toString(),
      'EncryptedValue([redacted])',
    );
    suppliedTags.add('identity');
    expect(document.tagIds, <String>['travel']);
    expect(() => document.tagIds.add('other'), throwsUnsupportedError);
  });

  test('models reject timestamps that move backwards', () {
    expect(
      () => Credential(
        id: 'credential-id',
        title: 'Gmail',
        usernameEncrypted: EncryptedValue('v1:ciphertext'),
        emailEncrypted: EncryptedValue('v1:ciphertext'),
        passwordEncrypted: EncryptedValue('v1:ciphertext'),
        notesEncrypted: EncryptedValue('v1:ciphertext'),
        createdAt: updatedAt,
        updatedAt: createdAt,
      ),
      throwsA(isA<ValidationException>()),
    );
  });
}
