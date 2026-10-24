import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/models.dart';
import 'transactions_controller.dart';

/// What a transaction list shows right now.
@immutable
final class TransactionListState {
  const TransactionListState({
    this.items = const <BookTransaction>[],
    this.hasMore = false,
    this.loading = true,
    this.loadingMore = false,
    this.error,
    this.filter = BookTransactionFilter.none,
    this.newestFirst = true,
    this.matchCount = 0,
  });

  final List<BookTransaction> items;
  final bool hasMore;

  /// True until the first page arrived.
  final bool loading;
  final bool loadingMore;
  final Object? error;
  final BookTransactionFilter filter;
  final bool newestFirst;

  /// Live transactions matching [filter] (not only the loaded pages).
  final int matchCount;

  TransactionListState copyWith({
    List<BookTransaction>? items,
    bool? hasMore,
    bool? loading,
    bool? loadingMore,
    Object? Function()? error,
    BookTransactionFilter? filter,
    bool? newestFirst,
    int? matchCount,
  }) => TransactionListState(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    error: error != null ? error() : this.error,
    filter: filter ?? this.filter,
    newestFirst: newestFirst ?? this.newestFirst,
    matchCount: matchCount ?? this.matchCount,
  );
}

/// Pages one account's transactions (keyset pagination) and keeps the loaded
/// window fresh after every write, without losing the scroll depth.
final class TransactionListController
    extends ValueNotifier<TransactionListState> {
  TransactionListController({
    required TransactionsController transactions,
    required this.accountId,
    this.pageSize = 50,
    bool newestFirst = true,
  }) : _transactions = transactions,
       super(TransactionListState(newestFirst: newestFirst)) {
    _subscription = _transactions.changes.listen((_) => unawaited(reload()));
    unawaited(reload());
  }

  final TransactionsController _transactions;
  final String accountId;
  final int pageSize;
  StreamSubscription<void>? _subscription;
  bool _disposed = false;
  int _generation = 0;

  Future<void> setFilter(BookTransactionFilter filter) {
    value = value.copyWith(filter: filter, loading: true);
    return reload();
  }

  Future<void> setNewestFirst(bool newestFirst) {
    value = value.copyWith(newestFirst: newestFirst, loading: true);
    return reload();
  }

  /// Reloads from the top, re-reading as many rows as are already loaded.
  Future<void> reload() async {
    final generation = ++_generation;
    final state = value;
    final limit = state.items.length > pageSize ? state.items.length : pageSize;
    try {
      final page = await _transactions.page(
        accountId,
        filter: state.filter,
        limit: limit,
        newestFirst: state.newestFirst,
      );
      final totals = await _transactions.matchTotals(
        accountId,
        filter: state.filter,
      );
      if (_disposed || generation != _generation) return;
      value = value.copyWith(
        items: page.items,
        hasMore: page.hasMore,
        loading: false,
        loadingMore: false,
        error: () => null,
        matchCount: totals.fold<int>(
          0,
          (sum, line) => sum + line.transactionCount,
        ),
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
      final page = await _transactions.page(
        accountId,
        filter: state.filter,
        after: BookOrderKey.of(state.items.last),
        limit: pageSize,
        newestFirst: state.newestFirst,
      );
      if (_disposed || generation != _generation) return;
      value = value.copyWith(
        items: [...state.items, ...page.items],
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
