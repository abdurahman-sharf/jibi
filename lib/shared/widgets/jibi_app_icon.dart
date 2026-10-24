import 'package:flutter/material.dart';

/// The app's picture (a leather pocket with a card, a page and a padlock). Falls back to a plain wallet
/// icon if the asset cannot be shown, so a missing image never breaks a screen.
class JibiAppIcon extends StatelessWidget {
  const JibiAppIcon({this.size = 96, super.key});

  static const String asset = 'assets/images/app_icon.png';

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    asset,
    width: size,
    height: size,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.medium,
    // Decorative: the screens around it already say what they are.
    excludeFromSemantics: true,
    errorBuilder: (context, _, _) => Icon(
      Icons.account_balance_wallet_outlined,
      size: size * 0.7,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}
