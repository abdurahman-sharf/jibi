import '../models/models.dart';
export 'book_repository.dart';

abstract interface class CredentialsRepository {
  Stream<List<Credential>> watchCredentials({
    String? query,
    String? categoryId,
    bool favoritesOnly = false,
  });
  Future<Credential?> findCredential(String id);
  Future<void> saveCredential(Credential credential);
  Future<void> deleteCredential(String id);
}

abstract interface class DocumentsRepository {
  Stream<List<Document>> watchDocuments({String? query, String? categoryId});
  Future<Document?> findDocument(String id);
  Future<List<DocumentFile>> listFiles(String documentId);
  Future<void> saveDocument(Document document);
  Future<void> saveDocumentFile(DocumentFile file);

  /// Fails with [ConflictException] while the file has attachment references.
  Future<void> deleteDocument(String id);
  Future<void> deleteDocumentFile(String id);

  Future<void> addAttachmentReference(AttachmentRef reference);
  Future<void> removeAttachmentReference(String referenceId);
  Future<List<AttachmentRef>> listAttachmentReferences(String documentFileId);
}

abstract interface class SettingsRepository {
  Future<AppSettings> read();
  Future<void> save(AppSettings settings);
}

/// The issuer of the reports (names, contact, logo, signature, stamp).
abstract interface class UserProfileRepository {
  /// The saved profile, or an empty one. A damaged row never blocks startup.
  Future<UserProfile> readUserProfile();
  Future<void> saveUserProfile(UserProfile profile);
}

abstract interface class CurrenciesRepository {
  Stream<List<Currency>> watchCurrencies();
  Future<Currency?> findCurrency(String code);

  /// Inserts a brand-new currency. Fails if the code already exists.
  Future<void> createCurrency(Currency currency);

  /// Updates mutable metadata only; callers must not change the code.
  Future<void> updateCurrency(Currency currency);
  Future<void> setActive(String code, {required bool isActive});
  Future<void> reorder(List<String> orderedCodes);

  /// True when a book account or a wallet uses this currency code.
  Future<bool> isCurrencyUsed(String code);

  /// Fails with [ConflictException] while the currency is still in use.
  Future<void> deleteCurrency(String code);
}
