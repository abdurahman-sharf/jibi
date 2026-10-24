import 'model_validation.dart';

enum AttachmentOwnerType { expense }

/// A reference that prevents deleting a shared encrypted document file.
final class AttachmentRef {
  AttachmentRef({
    required String id,
    required this.ownerType,
    required String ownerId,
    required String documentFileId,
    required this.createdAt,
  }) : id = requireId(id, 'attachment_ref_id'),
       ownerId = requireId(ownerId, 'attachment_owner_id'),
       documentFileId = requireId(documentFileId, 'document_file_id');

  final String id;
  final AttachmentOwnerType ownerType;
  final String ownerId;
  final String documentFileId;
  final DateTime createdAt;
}
