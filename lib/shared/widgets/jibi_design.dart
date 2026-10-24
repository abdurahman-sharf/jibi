import 'package:flutter/material.dart';

/// Shared design tokens and presentation widgets for the redesigned Jibi
/// interface. Colors are hand-tuned to the product palette: deep green
/// surfaces, mint backgrounds, and warm gold accents.
abstract final class JibiColors {
  static const Color deepGreen = Color(0xFF0F5747);
  static const Color deepGreenLight = Color(0xFF186854);
  static const Color deepGreenDark = Color(0xFF083A2F);
  static const Color mint = Color(0xFFEFF4F1);
  static const Color mintCard = Color(0xFFE3EEE8);
  static const Color gold = Color(0xFFF2C14E);
  static const Color goldSoft = Color(0xFFE8C87C);
  static const Color ink = Color(0xFF12251F);
  static const Color muted = Color(0xFF6D817A);
  static const Color danger = Color(0xFFC0392B);

  /// Tokens for text drawn over the light mint/gold tinted surfaces above.
  /// These containers keep their light background in both modes, so text on
  /// them must stay dark even when the ambient theme is dark.
  static const Color onTintInk = ink;
  static const Color onTintMuted = muted;

  static const LinearGradient heroGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF146352), Color(0xFF0A4034)],
  );
}

/// Formats a [DateTime] as a short Arabic relative label used across cards.
String jibiRelativeTimeAr(DateTime value) {
  final now = DateTime.now();
  final local = value.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final difference = today.difference(day).inDays;
  final hour = local.hour;
  final minute = local.minute.toString().padLeft(2, '0');
  final clock = '${hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour)}:$minute'
      ' ${hour < 12 ? 'ص' : 'م'}';
  if (difference <= 0) {
    return 'اليوم $clock';
  }
  if (difference == 1) {
    return 'أمس $clock';
  }
  if (difference < 7) {
    return 'منذ $difference أيام';
  }
  return '${local.day}/${local.month}/${local.year}';
}

/// Brightness-aware text and surface tokens for the custom (non-Theme)
/// components. The redesigned light palette is the product default; these
/// getters keep the same hierarchy readable in dark mode.
extension JibiAdaptive on BuildContext {
  bool get jibiIsDark => Theme.of(this).brightness == Brightness.dark;

  /// Primary text color over adaptive cards and the scaffold background.
  Color get jibiInk => jibiIsDark ? const Color(0xFFE9F1ED) : JibiColors.ink;

  /// Secondary text color over adaptive cards and the scaffold background.
  Color get jibiMuted =>
      jibiIsDark ? const Color(0xFF9CB6AC) : JibiColors.muted;
}

/// Rounded icon bubble used as the leading visual of most redesigned cards.
class JibiIconBubble extends StatelessWidget {
  const JibiIconBubble({
    required this.icon,
    required this.tint,
    required this.foreground,
    super.key,
    this.size = 46,
    this.iconSize,
    this.radius,
  });

  final IconData icon;
  final Color tint;
  final Color foreground;
  final double size;
  final double? iconSize;
  final double? radius;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: tint,
      borderRadius: BorderRadius.circular(radius ?? size * 0.32),
    ),
    child: Icon(icon, color: foreground, size: iconSize ?? size * 0.5),
  );
}

/// Small pill badge with optional leading icon.
class JibiBadge extends StatelessWidget {
  const JibiBadge(
    this.label, {
    required this.background,
    required this.foreground,
    super.key,
    this.icon,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: foreground),
          const SizedBox(width: 4),
        ],
        // Flexible so a long label ellipsizes inside a narrow parent instead of
        // overflowing it (large font on a small phone).
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foreground,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Section title row with an optional count badge and trailing action.
class JibiSectionHeader extends StatelessWidget {
  const JibiSectionHeader({
    required this.title,
    super.key,
    this.count,
    this.actionLabel,
    this.onAction,
    this.trailing,
  });

  final String title;
  final int? count;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        if (trailing != null) ...[
          Icon(trailing, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            title,
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .primary
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
        const Spacer(),
        if (actionLabel != null)
          GestureDetector(
            onTap: onAction,
            child: Text(
              actionLabel!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

/// LTR-safe money text. [magnitude] must already be a formatted positive
/// number; the sign is rendered explicitly for consistent RTL layout.
class JibiMoneyText extends StatelessWidget {
  const JibiMoneyText({
    required this.magnitude,
    required this.currency,
    super.key,
    this.isNegative = false,
    this.style,
    this.currencyStyle,
    this.showSign = true,
  });

  final String magnitude;
  final String currency;
  final bool isNegative;
  final TextStyle? style;
  final TextStyle? currencyStyle;
  final bool showSign;

  @override
  Widget build(BuildContext context) {
    final amount = showSign ? '${isNegative ? '-' : '+'} $magnitude' : magnitude;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: amount,
              style: style ?? Theme.of(context).textTheme.titleMedium,
            ),
            TextSpan(
              text: ' $currency',
              style:
                  currencyStyle ??
                  (style ?? Theme.of(context).textTheme.titleMedium)
                      ?.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// The custom top bar shown on every shell tab: brand + subtitle at the
/// start, utility actions at the end.
class JibiTopBar extends StatelessWidget implements PreferredSizeWidget {
  const JibiTopBar({
    required this.onSearch,
    required this.onThemeChanged,
    required this.onSettings,
    required this.onVault,
    required this.onProfile,
    super.key,
    this.vaultKey,
    this.searchKey,
    this.themeKey,
    this.settingsKey,
  });

  /// Keys of the buttons, for the hint tours (التلميحات المرئية).
  final GlobalKey? vaultKey;
  final GlobalKey? searchKey;
  final GlobalKey? themeKey;
  final GlobalKey? settingsKey;

  final VoidCallback onSearch;
  final ValueChanged<ThemeMode> onThemeChanged;
  final VoidCallback onSettings;
  final VoidCallback onVault;
  final VoidCallback onProfile;

  static const double height = 92;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 20, 4),
          child: Row(
            children: [
              KeyedSubtree(
                key: vaultKey,
                child: _TopBarButton(
                  tooltip: 'الخزنة',
                  onTap: onVault,
                  background: colors.primary.withValues(alpha: 0.14),
                  foreground: colors.primary,
                  icon: Icons.account_balance_wallet_outlined,
                ),
              ),
              const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'جيبي',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w900,
                                fontSize: 22,
                                color: context.jibiInk,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'خزنتك الآمنة الذكية',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: context.jibiMuted,
                                fontSize: 11.5,
                              ),
                        ),
                      ],
                    ),
                  ),
              KeyedSubtree(
                key: searchKey,
                child: _TopBarButton(
                  tooltip: 'بحث',
                  onTap: onSearch,
                  background: Colors.transparent,
                  foreground: context.jibiInk,
                  icon: Icons.search,
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<ThemeMode>(
                key: themeKey,
                tooltip: 'المظهر',
                onSelected: onThemeChanged,
                icon: Icon(Icons.palette_outlined, color: context.jibiInk),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: ThemeMode.system,
                    child: Text('حسب النظام'),
                  ),
                  PopupMenuItem(value: ThemeMode.light, child: Text('فاتح')),
                  PopupMenuItem(value: ThemeMode.dark, child: Text('داكن')),
                ],
              ),
              const SizedBox(width: 4),
              KeyedSubtree(
                key: settingsKey,
                child: _TopBarButton(
                  tooltip: 'الإعدادات',
                  onTap: onSettings,
                  background: Colors.transparent,
                  foreground: context.jibiInk,
                  icon: Icons.tune,
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: onProfile,
                child: Tooltip(
                  message: 'الملف الشخصي',
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: const BoxDecoration(
                      color: JibiColors.deepGreen,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person_outline,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBarButton extends StatelessWidget {
  const _TopBarButton({
    required this.tooltip,
    required this.onTap,
    required this.background,
    required this.foreground,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: foreground, size: 22),
      ),
    ),
  );
}

/// The hero gradient in the hue of [accent]: the same dark lightness range as
/// [JibiColors.heroGradient], so white text stays legible on any accent.
LinearGradient jibiHeroGradientFor(Color accent) {
  final hsl = HSLColor.fromColor(accent);
  final saturation = hsl.saturation.clamp(0.3, 0.7);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      hsl.withSaturation(saturation).withLightness(0.24).toColor(),
      hsl.withSaturation(saturation).withLightness(0.15).toColor(),
    ],
  );
}

/// Deep gradient panel used for hero summaries: green by default, or in the
/// hue of [accent] (a currency's color) when one is given.
class JibiDarkPanel extends StatelessWidget {
  const JibiDarkPanel({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(20),
    this.radius = 26,
    this.accent,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final gradient = accent == null
        ? JibiColors.heroGradient
        : jibiHeroGradientFor(accent!);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: padding,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: gradient.colors.last.withValues(alpha: 0.25),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// White rounded card with a soft shadow, matching the redesigned surfaces.
/// Without an explicit color it adapts to the ambient brightness.
class JibiSoftCard extends StatelessWidget {
  const JibiSoftCard({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.onTap,
    this.color,
    this.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final Color? color;
  final Border? border;

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        color ??
        (Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF22302B)
            : Colors.white);
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: effectiveColor,
        borderRadius: BorderRadius.circular(radius),
        border: border,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(radius),
        child: Padding(padding: padding, child: child),
      ),
    );
    if (onTap == null) {
      return card;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: card,
    );
  }
}

/// Quick-action grid tile (إجراءات سريعة).
class JibiQuickActionCard extends StatelessWidget {
  const JibiQuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tint,
    required this.foreground,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => JibiSoftCard(
    onTap: onTap,
    padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 10, 14),
    child: Row(
      children: [
        JibiIconBubble(
          icon: icon,
          tint: tint,
          foreground: foreground,
          size: 44,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14.5,
                  color: context.jibiInk,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 11.5, color: context.jibiMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Thin rounded progress track with gold fill used on dark panels.
class JibiProgressBar extends StatelessWidget {
  const JibiProgressBar({
    required this.value,
    super.key,
    this.height = 6,
    this.trackColor = const Color(0x33FFFFFF),
    this.fillColor = JibiColors.gold,
  });

  final double value;
  final double height;
  final Color trackColor;
  final Color fillColor;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(height),
    child: SizedBox(
      height: height,
      child: Stack(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: trackColor),
            child: const SizedBox.expand(),
          ),
          FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(color: fillColor),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    ),
  );
}
