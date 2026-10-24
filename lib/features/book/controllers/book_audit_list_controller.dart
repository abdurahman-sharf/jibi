import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';

/// What the audit-log screen shows.
final class BookAuditListState {
  const BookAuditListState({
    this.items = const <BookAuditEntry>[],
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = false,
    this.entity,
    this.error,
  });

  final List<BookAuditEntry> items;

  /// The first page is being read.
  final bool loading;
  final bool loadingMore;
  final bool hasMore;

  /// The kind of entry shown; null means all.
  final BookAuditEntity? entity;
  final Object? error;

  BookAuditListState copyWith({
    List<BookAuditEntry>? items,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    BookAuditEntity? Function()? entity,
    Object? Function()? error,
  }) => BookAuditListState(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
    entity: entity == null ? this.entity : entity(),
    error: error == null ? this.error : error(),
  );
}

/// Pages the audit log (newest first), optionally for one account, and
/// refreshes when the book changes so a new edit shows at once.
final class BookAuditListController extends ValueNotifier<BookAuditListState> {
  BookAuditListController({
    required this._repository,
    this.accountId,
    this.pageSize = 40,
    BookAuditEntity? entity,
  }) : super(BookAuditListState(entity: entity)) {
    _subscription = _repository.changes.listen((_) => unawaited(reload()));
    unawaited(reload());
  }

  final BookRepository _repository;
  final String? accountId;
  final int pageSize;
  StreamSubscription<void>? _subscription;
  int _generation = 0;
  bool _disposed = false;

  Future<void> setEntity(BookAuditEntity? entity) {
    value = value.copyWith(entity: () => entity, loading: true);
    return reload();
  }

  /// Reads from the top again, keeping as many rows as are already shown.
  Future<void> reload() async {
    final generation = ++_generation;
    final state = value;
    final limit = state.items.length > pageSize ? state.items.length : pageSize;
    try {
      final page = await _repository.auditPage(
        accountId: accountId,
        entity: state.entity,
        limit: limit,
      );
      if (_disposed || generation != _generation) return;
      value = value.copyWith(
        items: page.items,
        hasMore: page.hasMore,
        loading: false,
        loadingMore: false,
        error: () => null,
      );
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      value = value.copyWith(
        loading: false,
        loadingMore: false,
        error: () => error,
      );
    }
  }

  /// Appends the next page. Does nothing while loading or at the end.
  Future<void> loadMore() async {
    final state = value;
    if (!state.hasMore || state.loadingMore || state.loading) return;
    final generation = _generation;
    value = state.copyWith(loadingMore: true);
    try {
      final page = await _repository.auditPage(
        accountId: accountId,
        entity: state.entity,
        after: state.items.last,
        limit: pageSize,
      );
      if (_disposed || generation != _generation) return;
      value = value.copyWith(
        items: [...value.items, ...page.items],
        hasMore: page.hasMore,
        loadingMore: false,
      );
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      value = value.copyWith(loadingMore: false, error: () => error);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
