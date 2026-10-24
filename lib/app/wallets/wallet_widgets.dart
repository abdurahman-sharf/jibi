import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../book/book_widgets.dart';

export '../book/book_widgets.dart' show bookPagePadding, bookAmount, bookErrorMessage, showBookError;

/// The one fallback icon for a wallet's avatar — the picture (or, for the
/// wallet form, the name) is what tells wallets apart now, not a type.
const IconData walletFallbackIcon = Icons.account_balance_wallet_outlined;

String walletStatusLabel(WalletStatus status) => switch (status) {
  WalletStatus.active => 'نشطة',
  WalletStatus.archived => 'مؤرشفة',
};

String walletMovementTypeLabel(WalletTransactionType type) => switch (type) {
  WalletTransactionType.deposit => 'إيداع',
  WalletTransactionType.withdrawal => 'سحب',
  WalletTransactionType.transfer => 'تحويل',
  WalletTransactionType.exchange => 'صرف',
  WalletTransactionType.linked => 'عملية مرتبطة',
};

/// The wallet's picture when it has one, otherwise a tinted circle with the
/// generic wallet icon (mirrors [BookAvatar]'s shape, but wallets show a
/// picture more often than an account does).
class WalletAvatar extends StatelessWidget {
  const WalletAvatar({required this.wallet, super.key, this.size = 46});

  final Wallet wallet;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = wallet.image;
    if (image == null) {
      return BookAvatar(name: wallet.name, size: size, icon: walletFallbackIcon);
    }
    return ClipOval(
      child: Image.memory(
        image,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => BookAvatar(
          name: wallet.name,
          size: size,
          icon: walletFallbackIcon,
        ),
      ),
    );
  }
}
