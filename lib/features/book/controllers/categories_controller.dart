import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../../../core/storage/secure_file_storage.dart';
import '../domain/book_cascade.dart';
import '../domain/book_drafts.dart';
import 'book_watch.dart';

/// Rules for account categories (التصنيفات).
///
/// A category can be switched off (hidden everywhere, data kept) or archived
/// instead of deleted. Deleting one with accounts cascades: every account,
/// its transactions and their attachments go with it.
final class CategoriesController {
  CategoriesController({
    required BookRepository repository,
    SecureFileStorage? storage,
    String Function()? newId,
    DateTime Function()? clock,
  }) : _repository = repository,
       _storage = storage,
       _newId = newId ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final BookRepository _repository;

  /// Null in tests that do not exercise file storage.
  final SecureFileStorage? _storage;
  final String Function() _newId;
  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  Stream<List<CategorySummary>> watchSummaries({
    bool includeInactive = false,
    bool includeArchived = false,
  }) => watchBookQuery(
    _repository.changes,
    () => _repository.categorySummaries(
      includeInactive: includeInactive,
      includeArchived: includeArchived,
    ),
  );

  /// A one-off read of the same list [watchSummaries] streams.
  Future<List<CategorySummary>> summaries({
    bool includeInactive = false,
    bool includeArchived = false,
  }) => _repository.categorySummaries(
    includeInactive: includeInactive,
    includeArchived: includeArchived,
  );

  Future<BookCategory?> find(String id) => _repository.category(id);

  Future<BookCategory> create(BookCategoryDraft draft) async {
    final name = _validName(draft.name);
    final existing = await _repository.categorySummaries(
      includeInactive: true,
      includeArchived: true,
    );
    _requireUniqueName(existing, name);
    final now = _now;
    final category = BookCategory(
      id: _newId(),
      name: name,
      icon: optionalBookText(draft.icon),
      description: optionalBookText(draft.description),
      sortOrder: existing.isEmpty
          ? 0
          : existing
                    .map((summary) => summary.category.sortOrder)
                    .reduce((left, right) => left > right ? left : right) +
                1,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.write((writer) async {
      await writer.putCategory(category);
      await writer.audit('category', category.id, 'created', details: name);
    });
    return category;
  }

  Future<BookCategory> update(String id, BookCategoryDraft draft) async {
    final name = _validName(draft.name);
    final existing = await _repository.categorySummaries(
      includeInactive: true,
      includeArchived: true,
    );
    _requireUniqueName(existing, name, exceptId: id);
    return _repository.write((writer) async {
      final current = await _require(writer, id);
      final updated = current.copyWith(
        name: name,
        icon: () => optionalBookText(draft.icon),
        description: () => optionalBookText(draft.description),
        updatedAt: _now,
      );
      await writer.putCategory(updated);
      await writer.audit('category', id, 'updated', details: name);
      return updated;
    });
  }

  /// Switching a category off hides it and its accounts from the app screens
  /// and from the account form; nothing is deleted.
  Future<void> setActive(String id, {required bool isActive}) =>
      _repository.write((writer) async {
        final current = await _require(writer, id);
        await writer.putCategory(
          current.copyWith(isActive: isActive, updatedAt: _now),
        );
        await writer.audit(
          'category',
          id,
          isActive ? 'activated' : 'deactivated',
        );
      });

  Future<void> setArchived(String id, {required bool archived}) =>
      _repository.write((writer) async {
        final current = await _require(writer, id);
        await writer.putCategory(
          current.copyWith(isArchived: archived, updatedAt: _now),
        );
        await writer.audit(
          'category',
          id,
          archived ? 'archived' : 'unarchived',
        );
      });

  /// Persists the display order: [orderedIds] first to last.
  Future<void> reorder(List<String> orderedIds) =>
      _repository.write((writer) async {
        for (var index = 0; index < orderedIds.length; index++) {
          final current = await writer.category(orderedIds[index]);
          if (current != null && current.sortOrder != index) {
            await writer.putCategory(
              current.copyWith(sortOrder: index, updatedAt: _now),
            );
          }
        }
      });

  /// Deletes the category and, when it has any, every one of its accounts,
  /// their transactions and attachments — permanently, with no undo.
  Future<void> delete(String id) async {
    final removedAttachments = await _repository.write((writer) async {
      final current = await _require(writer, id);
      final accountCount = await writer.categoryAccountCount(id);
      final removed = await cascadeDeleteCategory(writer, current);
      await writer.audit(
        'category',
        id,
        'deleted',
        details: accountCount > 0
            ? '${current.name} · $accountCount حساب'
            : current.name,
      );
      return removed;
    });
    final storage = _storage;
    if (storage != null && removedAttachments.isNotEmpty) {
      await deleteOwnedAttachmentFiles(storage, removedAttachments);
    }
  }

  static String _validName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      throw const ValidationException(
        code: 'category_name_required',
        userMessage: 'أدخل اسم التصنيف.',
      );
    }
    return name;
  }

  static void _requireUniqueName(
    List<CategorySummary> existing,
    String name, {
    String? exceptId,
  }) {
    final lower = name.toLowerCase();
    final clash = existing.any(
      (summary) =>
          summary.category.id != exceptId &&
          summary.category.name.toLowerCase() == lower,
    );
    if (clash) {
      throw const ConflictException(
        code: 'category_name_exists',
        userMessage: 'يوجد تصنيف بهذا الاسم بالفعل.',
      );
    }
  }

  static Future<BookCategory> _require(BookWriter writer, String id) async {
    final category = await writer.category(id);
    if (category == null) {
      throw const NotFoundException(
        code: 'category_not_found',
        userMessage: 'التصنيف المطلوب غير موجود.',
      );
    }
    return category;
  }
}
