import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';

/// Deletes every movement of [wallet] (live or soft-deleted), every currency
/// balance it holds, and the wallet itself, inside the caller's
/// [BookRepository.write]. Book transactions that were paid through it are
/// kept, unlinked from any wallet.
///
/// A transfer's other leg lives on a different wallet, so it is removed too —
/// leaving a transfer with only one leg would misstate that other wallet's
/// balance. An exchange's other leg lives on this *same* wallet (converting
/// between two of its own currencies), so it needs no such cross-wallet
/// cleanup — the second pass over it below simply finds the group already
/// emptied and does nothing.
///
/// Returns the ids of the OTHER wallets whose balance needs a recompute
/// afterwards (never [wallet]'s own id, since it no longer exists).
Future<Set<String>> cascadeDeleteWallet(
  BookWriter writer,
  Wallet wallet,
) async {
  final movements = await writer.allWalletTransactionsOf(wallet.id);
  final affectedWallets = <String>{};
  for (final movement in movements) {
    final groupId = movement.legGroupId;
    if (groupId == null) {
      await writer.deleteWalletTransactionHard(movement.id);
      continue;
    }
    final pair = await writer.walletTransactionsInLegGroup(groupId);
    for (final leg in pair) {
      if (leg.walletId != wallet.id) {
        affectedWallets.add(leg.walletId);
      }
      await writer.deleteWalletTransactionHard(leg.id);
    }
  }
  // Book transactions paid through this wallet keep existing (the book is the
  // source of truth for them) but lose the link: the movement that mirrored
  // them just went with the wallet, and the database refuses to delete a
  // wallet a transaction still points at.
  await writer.unlinkBookTransactionsFromWallet(wallet.id);
  await writer.deleteWalletBalances(wallet.id);
  await writer.deleteWallet(wallet.id);
  return affectedWallets;
}
