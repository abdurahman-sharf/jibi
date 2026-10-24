import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../errors/app_exception.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import 'app_database.dart';

/// The single SQLite-backed repository used by the production composition.
///
/// It keeps database access out of widgets and treats vault/document fields as
/// opaque ciphertext. Credential search intentionally indexes only a service
/// title: neither a password nor a deterministic password index is persisted.
final class SqliteJibiRepository
    implements
        CredentialsRepository,
        DocumentsRepository,
        SettingsRepository,
        UserProfileRepository,
        CurrenciesRepository {
  SqliteJibiRepository(this._appDatabase);

  final AppDatabase _appDatabase;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Future<Database> get _database => _appDatabase.database;
  Stream<void> get changes => _changes.stream;

  void refresh() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Stream<List<Credential>> watchCredentials({
    String? query,
    String? categoryId,
    bool favoritesOnly = false,
  }) {
    return _watch(() async {
      final clauses = <String>[];
      final arguments = <Object?>[];
      final normalized = query?.trim();
      if (normalized != null && normalized.isNotEmpty) {
        clauses.add('title LIKE ? COLLATE NOCASE');
        arguments.add('%$normalized%');
      }
      if (categoryId != null) {
        clauses.add('category_id = ?');
        arguments.add(categoryId);
      }
      if (favoritesOnly) {
        clauses.add('is_favorite = 1');
      }
      final rows = await (await _database).query(
        'credentials',
        where: clauses.isEmpty ? null : clauses.join(' AND '),
        whereArgs: arguments,
        orderBy: 'title COLLATE NOCASE ASC, updated_at DESC',
      );
      return List<Credential>.unmodifiable(rows.map(_credentialFromRow));
    });
  }

  @override
  Future<Credential?> findCredential(String id) async {
    final rows = await (await _database).query(
      'credentials',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _credentialFromRow(rows.single);
  }

  @override
  Future<void> saveCredential(Credential credential) async {
    await _upsert(await _database, 'credentials', <String, Object?>{
      'id': credential.id,
      'title': credential.title,
      'username_encrypted': credential.usernameEncrypted.value,
      'email_encrypted': credential.emailEncrypted.value,
      'password_encrypted': credential.passwordEncrypted.value,
      'url': credential.url,
      'notes_encrypted': credential.notesEncrypted.value,
      'category_id': credential.categoryId,
      'is_favorite': credential.isFavorite ? 1 : 0,
      'created_at': _time(credential.createdAt),
      'updated_at': _time(credential.updatedAt),
    });
    _changed();
  }

  @override
  Future<void> deleteCredential(String id) async {
    final deleted = await (await _database).delete(
      'credentials',
      where: 'id = ?',
      whereArgs: [id],
    );
    _requireChanged(
      deleted,
      'credential_not_found',
      'بيانات الدخول المطلوبة غير موجودة.',
    );
    _changed();
  }

  @override
  Stream<List<Document>> watchDocuments({String? query, String? categoryId}) {
    return _watch(() async {
      final clauses = <String>[];
      final arguments = <Object?>[];
      final normalized = query?.trim();
      if (normalized != null && normalized.isNotEmpty) {
        clauses.add('title LIKE ? COLLATE NOCASE');
        arguments.add('%$normalized%');
      }
      if (categoryId != null) {
        clauses.add('category_id = ?');
        arguments.add(categoryId);
      }
      final rows = await (await _database).query(
        'documents',
        where: clauses.isEmpty ? null : clauses.join(' AND '),
        whereArgs: arguments,
        orderBy: 'updated_at DESC',
      );
      final documents = <Document>[];
      for (final row in rows) {
        documents.add(await _documentFromRow(row));
      }
      return List<Document>.unmodifiable(documents);
    });
  }

  @override
  Future<Document?> findDocument(String id) async {
    final rows = await (await _database).query(
      'documents',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _documentFromRow(rows.single);
  }

  @override
  Future<List<DocumentFile>> listFiles(String documentId) async {
    final rows = await (await _database).query(
      'document_files',
      where: 'document_id = ?',
      whereArgs: [documentId],
      orderBy: 'created_at ASC',
    );
    return List<DocumentFile>.unmodifiable(rows.map(_documentFileFromRow));
  }

  @override
  Future<void> saveDocument(Document document) async {
    final database = await _database;
    await database.transaction((transaction) async {
      await _upsert(transaction, 'documents', <String, Object?>{
        'id': document.id,
        'title': document.title,
        'category_id': document.categoryId,
        'document_number_encrypted': document.documentNumberEncrypted?.value,
        'issuer_encrypted': document.issuerEncrypted?.value,
        'issue_date': document.issueDate == null
            ? null
            : _time(document.issueDate!),
        'expiry_date': document.expiryDate == null
            ? null
            : _time(document.expiryDate!),
        'notes_encrypted': document.notesEncrypted?.value,
        'created_at': _time(document.createdAt),
        'updated_at': _time(document.updatedAt),
      });
      await transaction.delete(
        'document_tags',
        where: 'document_id = ?',
        whereArgs: [document.id],
      );
      for (final tagId in document.tagIds) {
        final knownTag = await transaction.query(
          'tags',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [tagId],
          limit: 1,
        );
        if (knownTag.isEmpty) {
          await transaction.insert('tags', <String, Object?>{
            'id': tagId,
            'name': tagId,
          });
        }
        await transaction.insert('document_tags', <String, Object?>{
          'document_id': document.id,
          'tag_id': tagId,
        });
      }
    });
    _changed();
  }

  @override
  Future<void> saveDocumentFile(DocumentFile file) async {
    await _upsert(await _database, 'document_files', <String, Object?>{
      'id': file.id,
      'document_id': file.documentId,
      'encrypted_file_name': file.encryptedFileName,
      'original_extension': file.originalExtension,
      'mime_type': file.mimeType,
      'encrypted_size': file.encryptedSizeBytes,
      'checksum': file.checksum,
      'created_at': _time(file.createdAt),
    });
    _changed();
  }

  @override
  Future<void> deleteDocument(String id) async {
    final files = await listFiles(id);
    for (final file in files) {
      final references = await listAttachmentReferences(file.id);
      if (references.isNotEmpty) {
        throw const ConflictException(
          code: 'document_file_is_attached',
          userMessage: 'لا يمكن حذف ملف مرتبط بسجل آخر.',
        );
      }
    }
    final deleted = await (await _database).delete(
      'documents',
      where: 'id = ?',
      whereArgs: [id],
    );
    _requireChanged(
      deleted,
      'document_not_found',
      'المستند المطلوب غير موجود.',
    );
    _changed();
  }

  @override
  Future<void> deleteDocumentFile(String id) async {
    final references = await listAttachmentReferences(id);
    if (references.isNotEmpty) {
      throw const ConflictException(
        code: 'document_file_is_attached',
        userMessage: 'لا يمكن حذف ملف مرتبط بسجل آخر.',
      );
    }
    final deleted = await (await _database).delete(
      'document_files',
      where: 'id = ?',
      whereArgs: [id],
    );
    _requireChanged(
      deleted,
      'document_file_not_found',
      'الملف المطلوب غير موجود.',
    );
    _changed();
  }

  @override
  Future<void> addAttachmentReference(AttachmentRef reference) async {
    final database = await _database;
    await database.transaction((transaction) async {
      await _validateAttachment(transaction, reference.documentFileId);
      await transaction.delete(
        'attachment_refs',
        where: 'owner_type = ? AND owner_id = ? AND id != ?',
        whereArgs: [
          _attachmentOwnerTypeValue(reference.ownerType),
          reference.ownerId,
          reference.id,
        ],
      );
      await _upsert(
        transaction,
        'attachment_refs',
        _attachmentValues(reference),
      );
    });
    _changed();
  }

  @override
  Future<void> removeAttachmentReference(String referenceId) async {
    final deleted = await (await _database).delete(
      'attachment_refs',
      where: 'id = ?',
      whereArgs: [referenceId],
    );
    _requireChanged(
      deleted,
      'attachment_reference_not_found',
      'مرجع الملف المطلوب غير موجود.',
    );
    _changed();
  }

  @override
  Future<List<AttachmentRef>> listAttachmentReferences(
    String documentFileId,
  ) async {
    final rows = await (await _database).query(
      'attachment_refs',
      where: 'document_file_id = ?',
      whereArgs: [documentFileId],
      orderBy: 'created_at ASC',
    );
    return List<AttachmentRef>.unmodifiable(rows.map(_attachmentFromRow));
  }

  @override
  Future<AppSettings> read() async {
    final rows = await (await _database).query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['settings_v1'],
      limit: 1,
    );
    if (rows.isEmpty) {
      return AppSettings(defaultCurrencyCode: 'YER');
    }
    return _settingsFromJson(rows.single['value']! as String);
  }

  @override
  Future<void> save(AppSettings settings) async {
    await _upsert(await _database, 'app_settings', <String, Object?>{
      'key': 'settings_v1',
      'value': jsonEncode(<String, Object>{
        'defaultCurrencyCode': settings.defaultCurrencyCode,
        'localeCode': settings.localeCode,
        'themePreference': settings.themePreference.name,
        'autoLockDuration': settings.autoLockDuration.name,
        'biometricsEnabled': settings.biometricsEnabled,
        'screenshotProtectionEnabled': settings.screenshotProtectionEnabled,
        'clipboardClearAfterMs': settings.clipboardClearAfter.inMilliseconds,
        'backupSchedule': settings.backupSchedule.name,
        'autoBackupOnUnlock': settings.autoBackupOnUnlock,
        'backupRetentionCount': settings.backupRetentionCount,
        'dateFormat': settings.dateFormat.name,
        'showTransactionTime': settings.showTransactionTime,
        'hideBalances': settings.hideBalances,
        'newestFirst': settings.newestFirst,
        'confirmBeforeDelete': settings.confirmBeforeDelete,
        'defaultEntryType': settings.defaultEntryType.name,
        if (settings.debitLabel != null) 'debitLabel': settings.debitLabel!,
        if (settings.creditLabel != null) 'creditLabel': settings.creditLabel!,
        'showCoachMarks': settings.showCoachMarks,
        'seenTours': settings.seenTours.toList()..sort(),
      }),
      'updated_at': _time(DateTime.now()),
    });
    _changed();
  }

  static const _profileKey = 'user_profile_v1';

  @override
  Future<UserProfile> readUserProfile() async {
    final rows = await (await _database).query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_profileKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return UserProfile.empty;
    }
    try {
      final value = jsonDecode(rows.single['value']! as String);
      if (value is! Map<String, Object?>) {
        return UserProfile.empty;
      }
      Uint8List? image(String key) {
        final stored = value[key];
        if (stored is! String || stored.isEmpty) return null;
        try {
          return base64Decode(stored);
        } on FormatException {
          return null;
        }
      }

      String? text(String key) {
        final stored = value[key];
        return stored is String ? stored : null;
      }

      bool flag(String key) {
        final stored = value[key];
        return stored is bool ? stored : true;
      }

      // Rebuilt through the validating factory so a row edited elsewhere can
      // only ever produce a well-formed profile.
      return UserProfile.validated(
        nameAr: text('nameAr'),
        nameEn: text('nameEn'),
        addressAr: text('addressAr'),
        addressEn: text('addressEn'),
        phone: text('phone'),
        email: text('email'),
        logo: image('logo'),
        signature: image('signature'),
        stamp: image('stamp'),
        showLogo: flag('showLogo'),
        showSignature: flag('showSignature'),
        showStamp: flag('showStamp'),
      );
    } on Object {
      return UserProfile.empty;
    }
  }

  @override
  Future<void> saveUserProfile(UserProfile profile) async {
    await _upsert(await _database, 'app_settings', <String, Object?>{
      'key': _profileKey,
      'value': jsonEncode(<String, Object>{
        if (profile.nameAr != null) 'nameAr': profile.nameAr!,
        if (profile.nameEn != null) 'nameEn': profile.nameEn!,
        if (profile.addressAr != null) 'addressAr': profile.addressAr!,
        if (profile.addressEn != null) 'addressEn': profile.addressEn!,
        if (profile.phone != null) 'phone': profile.phone!,
        if (profile.email != null) 'email': profile.email!,
        if (profile.logo != null) 'logo': base64Encode(profile.logo!),
        if (profile.signature != null)
          'signature': base64Encode(profile.signature!),
        if (profile.stamp != null) 'stamp': base64Encode(profile.stamp!),
        'showLogo': profile.showLogo,
        'showSignature': profile.showSignature,
        'showStamp': profile.showStamp,
      }),
      'updated_at': _time(DateTime.now()),
    });
  }

  @override
  Stream<List<Currency>> watchCurrencies() {
    return _watch(() async {
      final rows = await (await _database).query(
        'currencies',
        orderBy: 'sort_order ASC, code ASC',
      );
      return List<Currency>.unmodifiable(rows.map(_currencyFromRow));
    });
  }

  @override
  Future<Currency?> findCurrency(String code) async {
    final rows = await (await _database).query(
      'currencies',
      where: 'code = ?',
      whereArgs: [code.toUpperCase()],
      limit: 1,
    );
    return rows.isEmpty ? null : _currencyFromRow(rows.single);
  }

  @override
  Future<void> createCurrency(Currency currency) async {
    final database = await _database;
    final existing = await database.query(
      'currencies',
      where: 'code = ?',
      whereArgs: [currency.code],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      throw const ConflictException(
        code: 'currency_code_exists',
        userMessage: 'رمز العملة مستخدم بالفعل.',
      );
    }
    final now = _time(DateTime.now());
    await database.insert('currencies', <String, Object?>{
      ..._currencyValues(currency),
      'created_at': now,
      'updated_at': now,
    });
    _changed();
  }

  @override
  Future<void> updateCurrency(Currency currency) async {
    final database = await _database;
    final updated = await database.update(
      'currencies',
      <String, Object?>{
        'name': currency.name,
        'symbol': currency.symbol,
        'fraction_digits': currency.fractionDigits,
        'sort_order': currency.sortOrder,
        'is_active': currency.isActive ? 1 : 0,
        'color': currency.colorValue,
        'updated_at': _time(DateTime.now()),
      },
      where: 'code = ?',
      whereArgs: [currency.code],
    );
    _requireChanged(
      updated,
      'currency_not_found',
      'العملة المطلوبة غير موجودة.',
    );
    _changed();
  }

  @override
  Future<void> setActive(String code, {required bool isActive}) async {
    final database = await _database;
    final updated = await database.update(
      'currencies',
      <String, Object?>{
        'is_active': isActive ? 1 : 0,
        'updated_at': _time(DateTime.now()),
      },
      where: 'code = ?',
      whereArgs: [code.toUpperCase()],
    );
    _requireChanged(
      updated,
      'currency_not_found',
      'العملة المطلوبة غير موجودة.',
    );
    _changed();
  }

  @override
  Future<void> reorder(List<String> orderedCodes) async {
    final database = await _database;
    await database.transaction((transaction) async {
      for (var index = 0; index < orderedCodes.length; index++) {
        await transaction.update(
          'currencies',
          <String, Object?>{
            'sort_order': index,
            'updated_at': _time(DateTime.now()),
          },
          where: 'code = ?',
          whereArgs: [orderedCodes[index].toUpperCase()],
        );
      }
    });
    _changed();
  }

  @override
  Future<bool> isCurrencyUsed(String code) async {
    final database = await _database;
    final upperCode = code.toUpperCase();
    // Every table that stores a currency code, so a used currency can never be
    // deleted or have its decimals changed.
    for (final table in _currencyBearingTables) {
      final count = Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM $table WHERE currency_code = ?',
          [upperCode],
        ),
      );
      if ((count ?? 0) > 0) {
        return true;
      }
    }
    return false;
  }

  /// Every table that references `currencies`: an account's opening balances
  /// and each book transaction (an account has no currency of its own), and the
  /// wallets' balances and movements.
  static const List<String> _currencyBearingTables = <String>[
    'book_account_balances',
    'book_transactions',
    'wallet_balances',
    'wallet_transactions',
  ];

  @override
  Future<void> deleteCurrency(String code) async {
    if (await isCurrencyUsed(code)) {
      throw const ConflictException(
        code: 'currency_in_use',
        userMessage: 'لا يمكن حذف عملة مستخدمة في عمليات محفوظة.',
      );
    }
    final deleted = await (await _database).delete(
      'currencies',
      where: 'code = ?',
      whereArgs: [code.toUpperCase()],
    );
    _requireChanged(
      deleted,
      'currency_not_found',
      'العملة المطلوبة غير موجودة.',
    );
    _changed();
  }

  static Map<String, Object?> _currencyValues(Currency currency) =>
      <String, Object?>{
        'code': currency.code,
        'name': currency.name,
        'symbol': currency.symbol,
        'fraction_digits': currency.fractionDigits,
        'sort_order': currency.sortOrder,
        'is_active': currency.isActive ? 1 : 0,
        'color': currency.colorValue,
      };

  static Currency _currencyFromRow(Map<String, Object?> row) => Currency(
    code: row['code']! as String,
    name: row['name']! as String,
    symbol: row['symbol'] as String?,
    fractionDigits: row['fraction_digits']! as int,
    sortOrder: row['sort_order']! as int,
    isActive: row['is_active'] == 1,
    colorValue: row['color'] as int?,
  );

  Future<void> dispose() async {
    await _changes.close();
  }

  Stream<List<T>> _watch<T>(Future<List<T>> Function() snapshot) async* {
    yield await snapshot();
    await for (final _ in _changes.stream) {
      yield await snapshot();
    }
  }

  Future<void> _validateAttachment(
    DatabaseExecutor executor,
    String? documentFileId,
  ) async {
    if (documentFileId == null) {
      return;
    }
    final files = await executor.query(
      'document_files',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [documentFileId],
      limit: 1,
    );
    if (files.isEmpty) {
      throw const NotFoundException(
        code: 'document_file_not_found',
        userMessage: 'الملف المرفق المطلوب غير موجود.',
      );
    }
  }

  Future<void> _upsert(
    DatabaseExecutor executor,
    String table,
    Map<String, Object?> values,
  ) async {
    final id = values['id'];
    if (id == null) {
      await executor.insert(
        table,
        values,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return;
    }
    final updated = await executor.update(
      table,
      values..remove('id'),
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated == 0) {
      await executor.insert(table, <String, Object?>{'id': id, ...values});
    }
  }

  void _changed() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  static void _requireChanged(int changed, String code, String userMessage) {
    if (changed == 0) {
      throw NotFoundException(code: code, userMessage: userMessage);
    }
  }

  static Credential _credentialFromRow(Map<String, Object?> row) => Credential(
    id: row['id']! as String,
    title: row['title']! as String,
    usernameEncrypted: EncryptedValue(row['username_encrypted']! as String),
    emailEncrypted: EncryptedValue(row['email_encrypted']! as String),
    passwordEncrypted: EncryptedValue(row['password_encrypted']! as String),
    url: row['url'] as String?,
    notesEncrypted: EncryptedValue(row['notes_encrypted']! as String),
    categoryId: row['category_id'] as String?,
    isFavorite: row['is_favorite'] == 1,
    createdAt: _date(row['created_at']),
    updatedAt: _date(row['updated_at']),
  );

  Future<Document> _documentFromRow(Map<String, Object?> row) async {
    final tagRows = await (await _database).query(
      'document_tags',
      columns: ['tag_id'],
      where: 'document_id = ?',
      whereArgs: [row['id']],
      orderBy: 'tag_id ASC',
    );
    return Document(
      id: row['id']! as String,
      title: row['title']! as String,
      categoryId: row['category_id'] as String?,
      documentNumberEncrypted: _encrypted(row['document_number_encrypted']),
      issuerEncrypted: _encrypted(row['issuer_encrypted']),
      issueDate: _nullableDate(row['issue_date']),
      expiryDate: _nullableDate(row['expiry_date']),
      notesEncrypted: _encrypted(row['notes_encrypted']),
      tagIds: tagRows.map((tag) => tag['tag_id']! as String).toList(),
      createdAt: _date(row['created_at']),
      updatedAt: _date(row['updated_at']),
    );
  }

  static DocumentFile _documentFileFromRow(Map<String, Object?> row) =>
      DocumentFile(
        id: row['id']! as String,
        documentId: row['document_id']! as String,
        encryptedFileName: row['encrypted_file_name']! as String,
        originalExtension: row['original_extension']! as String,
        mimeType: row['mime_type']! as String,
        encryptedSizeBytes: row['encrypted_size']! as int,
        checksum: row['checksum']! as String,
        createdAt: _date(row['created_at']),
      );

  static Map<String, Object?> _attachmentValues(AttachmentRef reference) =>
      <String, Object?>{
        'id': reference.id,
        'owner_type': _attachmentOwnerTypeValue(reference.ownerType),
        'owner_id': reference.ownerId,
        'document_file_id': reference.documentFileId,
        'created_at': _time(reference.createdAt),
      };

  static AttachmentRef _attachmentFromRow(Map<String, Object?> row) =>
      AttachmentRef(
        id: row['id']! as String,
        ownerType: _attachmentOwnerTypeFromValue(row['owner_type']! as String),
        ownerId: row['owner_id']! as String,
        documentFileId: row['document_file_id']! as String,
        createdAt: _date(row['created_at']),
      );

  static AppSettings _settingsFromJson(String raw) {
    try {
      final value = jsonDecode(raw) as Map<String, Object?>;
      final defaults = AppSettings(defaultCurrencyCode: 'YER');
      // Every key falls back to its default when absent or of the wrong type,
      // so a settings row written by another build never blocks startup.
      T pick<T>(String key, T fallback) {
        final stored = value[key];
        return stored is T ? stored : fallback;
      }

      final clipboardMs = pick<int>('clipboardClearAfterMs', -1);
      final retention = pick<int>('backupRetentionCount', 0);
      // A custom wording that is no longer valid (too long, or equal to the
      // other side) falls back to the standard words instead of blocking
      // startup.
      String? debitLabel = pick<String?>('debitLabel', null);
      String? creditLabel = pick<String?>('creditLabel', null);
      try {
        AppSettings(
          defaultCurrencyCode: 'YER',
          debitLabel: debitLabel,
          creditLabel: creditLabel,
        );
      } on Object {
        debitLabel = null;
        creditLabel = null;
      }
      return AppSettings(
        defaultCurrencyCode: pick('defaultCurrencyCode', defaults.defaultCurrencyCode),
        localeCode: pick('localeCode', defaults.localeCode),
        themePreference:
            AppThemePreference.values.asNameMap()[value['themePreference']] ??
            defaults.themePreference,
        autoLockDuration:
            AutoLockDuration.values.asNameMap()[value['autoLockDuration']] ??
            defaults.autoLockDuration,
        biometricsEnabled: pick('biometricsEnabled', defaults.biometricsEnabled),
        screenshotProtectionEnabled: pick(
          'screenshotProtectionEnabled',
          defaults.screenshotProtectionEnabled,
        ),
        clipboardClearAfter: clipboardMs >= 0
            ? Duration(milliseconds: clipboardMs)
            : defaults.clipboardClearAfter,
        backupSchedule:
            BackupSchedule.values.asNameMap()[value['backupSchedule']] ??
            defaults.backupSchedule,
        autoBackupOnUnlock: pick(
          'autoBackupOnUnlock',
          defaults.autoBackupOnUnlock,
        ),
        backupRetentionCount: retention >= 1
            ? retention
            : defaults.backupRetentionCount,
        dateFormat:
            DateDisplayFormat.values.asNameMap()[value['dateFormat']] ??
            defaults.dateFormat,
        showTransactionTime: pick(
          'showTransactionTime',
          defaults.showTransactionTime,
        ),
        hideBalances: pick('hideBalances', defaults.hideBalances),
        newestFirst: pick('newestFirst', defaults.newestFirst),
        confirmBeforeDelete: pick(
          'confirmBeforeDelete',
          defaults.confirmBeforeDelete,
        ),
        defaultEntryType:
            EntryType.values.asNameMap()[value['defaultEntryType']] ??
            defaults.defaultEntryType,
        debitLabel: debitLabel,
        creditLabel: creditLabel,
        showCoachMarks: pick('showCoachMarks', defaults.showCoachMarks),
        seenTours: {
          if (value['seenTours'] case final List<Object?> stored)
            for (final id in stored)
              if (id is String && id.isNotEmpty && id.length <= 40) id,
        },
      );
    } on Object catch (error) {
      throw StorageException(
        code: 'invalid_settings',
        userMessage: 'تعذر قراءة الإعدادات المحفوظة.',
        cause: error,
      );
    }
  }

  static EncryptedValue? _encrypted(Object? value) =>
      value == null ? null : EncryptedValue(value as String);

  static DateTime _date(Object? timestamp) =>
      DateTime.fromMillisecondsSinceEpoch(timestamp! as int, isUtc: true);

  static DateTime? _nullableDate(Object? timestamp) =>
      timestamp == null ? null : _date(timestamp);

  static int _time(DateTime value) => value.toUtc().millisecondsSinceEpoch;

  static String _attachmentOwnerTypeValue(AttachmentOwnerType type) =>
      switch (type) {
        AttachmentOwnerType.expense => 'expense',
      };

  static AttachmentOwnerType _attachmentOwnerTypeFromValue(String value) =>
      switch (value) {
        'expense' => AttachmentOwnerType.expense,
        _ => throw const StorageException(
          code: 'invalid_attachment_owner_type',
          userMessage: 'بيانات المرفق غير صالحة.',
        ),
      };
}
