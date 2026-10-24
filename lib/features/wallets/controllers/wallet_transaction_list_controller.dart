import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/models.dart';
import 'wallet_transactions_controller.dart';

/// What a wallet's movement list shows right now.
@immutable
final class WalletTransactionListState {
  const WalletTransactionListState({
    this.items = const <WalletTransaction>[],
    this.hasMore = false,
    this.loading = true,
    this.loadingMore = false,
    this.error,
    this.filter = WalletTransactionFilter.none,
  });

  final List<WalletTransaction> items;
  final bool hasMore;

  /// True until the first page arrives.
  final bool loading;
  final bool loadingMore;
  final Object? error;
  final WalletTransactionFilter filter;

  WalletTransactionListState copyWith({
    List<WalletTransaction>? items,
    bool? hasMore,
    bool? loading,
    bool? loadingMore,
    Object? Function()? error,
    WalletTransactionFilter? filter,
  }) => WalletTransactionListState(
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    error: error != null ? error() : this.error,
    filter: filter ?? this.filter,
  );
}

/// Pages one wallet's movements (keyset pagination, newest first) and keeps
/// the loaded window fresh after every write, without losing the scroll
/// depth. Mirrors [TransactionListController].
final class WalletTransactionListController
    extends ValueNotifier<WalletTransactionListState> {
  WalletTransactionListController({
    required WalletTransactionsController movements,
    required this.walletId,
    String? currencyCode,
    this.pageSize = 50,
  }) : _movements = movements,
       _currencyCode = currencyCode,
       super(const WalletTransactionListState()) {
    _subscription = _movements.changes.listen((_) => unawaited(reload()));
    unawaited(reload());
  }

  final WalletTransactionsController _movements;
  final String walletId;
  final int pageSize;
  String? _currencyCode;
  StreamSubscription<void>? _subscription;
  bool _disposed = false;
  int _generation = 0;

  Future<void> setFilter(WalletTransactionFilter filter) {
    value = value.copyWith(filter: filter, loading: true);
    return reload();
  }

  /// Switches which of the wallet's currencies the list shows (null pages
  /// across all of them), resetting the page.
  Future<void> setCurrency(String? currencyCode) {
    _currencyCode = currencyCode;
    value = value.copyWith(items: const [], hasMore: false, loading: true);
    return reload();
  }

  /// Reloads from the top, re-reading as many rows as are already loaded.
  Future<void> reload() async {
    final generation = ++_generation;
    final state = value;
    final limit = state.items.length > pageSize
        ? state.items.length
        : pageSize;
    try {
      final page = await _movements.page(
        walletId,
        currencyCode: _currencyCode,
        filter: state.filter,
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
      value = value.copyWith(loading: false, loadingMore: false, error: () => error);
    }
  }

  /// Appends the next page. Does nothing while loading or at the end.
  Future<void> loadMore() async {
    final state = value;
    if (!state.hasMore || state.loadingMore || state.loading) return;
    final generation = _generation;
    value = state.copyWith(loadingMore: true);
    try {
      final page = await _movements.page(
        walletId,
        currencyCode: _currencyCode,
        filter: state.filter,
        after: WalletOrderKey.of(state.items.last),
        limit: pageSize,
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
