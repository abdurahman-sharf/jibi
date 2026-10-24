import '../../../core/models/models.dart';
import '../../../core/repositories/book_repository.dart';
import '../../../core/storage/secure_file_storage.dart';
import '../../wallets/domain/wallet_balance.dart';

/// Deletes [account] and everything under it: every transaction (live or
/// soft-deleted) and, through the database's own `ON DELETE CASCADE`, their
/// attachment rows. Any transaction linked to a wallet has that link removed
/// too (its `linked_book_transaction_id` foreign key would otherwise block
/// the transaction's own deletion), and every wallet touched this way is
/// recomputed. Must run inside the caller's [BookRepository.write].
///
/// Returns the attachments that were removed, so their encrypted files can be
/// deleted afterwards (outside the write, the same way
/// [BookAttachmentsController.remove] does it) — a legacy-vault attachment
/// (no `encryptedFileName`) owns no file of its own and is filtered out by
/// [ownedAttachmentFile].
Future<List<BookAttachment>> cascadeDeleteAccount(
  BookWriter writer,
  BookAccount account,
) async {
  final transactions = await writer.allTransactionsOfAccount(account.id);
  final removedAttachments = <BookAttachment>[];
  final affectedWallets = <String>{};
  for (final transaction in transactions) {
    removedAttachments.addAll(await writer.attachments(transaction.id));
    final link = await writer.walletTransactionForBookTransaction(
      transaction.id,
    );
    if (link != null) {
      affectedWallets.add(link.walletId);
      await writer.deleteWalletTransactionHard(link.id);
    }
    await writer.deleteTransactionHard(transaction.id);
  }
  await writer.deleteAccount(account.id);
  for (final walletId in affectedWallets) {
    await WalletBalanceEngine.recomputeWallet(writer, walletId);
  }
  return removedAttachments;
}

/// Deletes [category] and everything under it: every account, their
/// transactions and attachment rows. Must run inside the caller's
/// [BookRepository.write].
Future<List<BookAttachment>> cascadeDeleteCategory(
  BookWriter writer,
  BookCategory category,
) async {
  final accounts = await writer.accountsOfCategory(category.id);
  final removedAttachments = <BookAttachment>[];
  for (final account in accounts) {
    removedAttachments.addAll(await cascadeDeleteAccount(writer, account));
  }
  await writer.deleteCategory(category.id);
  return removedAttachments;
}

/// The encrypted file [attachment] owns, if any (null for one migrated from
/// the legacy document vault, which is never deleted from here).
DocumentFile? ownedAttachmentFile(BookAttachment attachment) {
  final name = attachment.encryptedFileName;
  if (name == null) return null;
  return DocumentFile(
    id: attachment.id,
    documentId: attachment.transactionId,
    encryptedFileName: name,
    originalExtension: attachment.originalExtension ?? 'bin',
    mimeType: attachment.mimeType,
    encryptedSizeBytes: attachment.fileSize,
    checksum: attachment.checksum!,
    createdAt: attachment.createdAt,
  );
}

/// Deletes the encrypted file of every owned attachment in [attachments].
/// Call after the [BookRepository.write] that removed their rows commits.
Future<void> deleteOwnedAttachmentFiles(
  SecureFileStorage storage,
  List<BookAttachment> attachments,
) async {
  for (final attachment in attachments) {
    final owned = ownedAttachmentFile(attachment);
    if (owned != null) {
      await storage.deleteFile(owned);
    }
  }
}
