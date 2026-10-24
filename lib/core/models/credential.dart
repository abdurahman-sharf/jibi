import 'encrypted_value.dart';
import 'model_validation.dart';

final class Credential {
  Credential({
    required String id,
    required String title,
    required this.usernameEncrypted,
    required this.emailEncrypted,
    required this.passwordEncrypted,
    this.url,
    required this.notesEncrypted,
    this.categoryId,
    this.isFavorite = false,
    required this.createdAt,
    required DateTime updatedAt,
  }) : id = requireId(id, 'credential_id'),
       title = requireText(title, 'credential_title'),
       updatedAt = requireChronologicalDates(createdAt, updatedAt);

  final String id;
  final String title;
  final EncryptedValue usernameEncrypted;
  final EncryptedValue emailEncrypted;
  final EncryptedValue passwordEncrypted;
  final String? url;
  final EncryptedValue notesEncrypted;
  final String? categoryId;
  final bool isFavorite;
  final DateTime createdAt;
  final DateTime updatedAt;
}
