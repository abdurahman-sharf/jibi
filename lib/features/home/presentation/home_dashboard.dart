import 'package:flutter/material.dart';
import 'package:jibi/shared/widgets/jibi_design.dart';
import 'package:jibi/shared/widgets/jibi_page.dart';

import '../../../core/models/currency.dart';
import '../../../core/models/wallet.dart';
import '../../../core/models/wallet_views.dart';
import '../../book/domain/book_labels.dart';
import '../../../core/models/money.dart';
import '../../../shared/widgets/jibi_feedback.dart';
import '../domain/backup_status.dart';
import '../domain/recent_activity.dart';
import 'dashboard_summary.dart';

/// A repository-free dashboard preview. Feature code supplies callbacks only.
class HomeDashboard extends StatelessWidget {
  const HomeDashboard({
    super.key,
    this.onAddTransaction,
    this.onAddAccount,
    this.onAddPassword,
    this.onAddDocument,
    this.onOpenSettings,
    this.summary,
    this.currencies,
    this.recentActivity,
    this.backupStatus,
    this.onBackupNow,
    this.onOpenActivity,
    this.labels = BookLabels.standard,
    this.hideBalances = false,
    this.hideToggleKey,
    this.walletSummaries,
    this.walletTotals,
    this.onOpenWallet,
    this.onOpenWallets,
    this.onAddWallet,
    this.defaultCurrencyCode = 'YER',
  });

  /// Key of the hide-amounts eye, for the hint tours (التلميحات المرئية).
  final GlobalKey? hideToggleKey;

  /// The wording of the two sides, from the settings.
  final BookLabels labels;

  /// Starts with the amounts hidden (the "hide balances" setting). The eye on
  /// the card still shows or hides them for the current visit.
  final bool hideBalances;

  final VoidCallback? onAddTransaction;
  final VoidCallback? onAddAccount;
  final VoidCallback? onAddPassword;
  final VoidCallback? onAddDocument;
  final VoidCallback? onOpenSettings;
  final Stream<DashboardSummary>? summary;
  final CurrencyRegistry? currencies;
  final Stream<List<RecentActivityItem>>? recentActivity;
  final Future<BackupStatus>? backupStatus;

  /// Creates a backup right away (asks for the PIN). Shown on the banner only
  /// while a backup is missing or overdue.
  final VoidCallback? onBackupNow;
  final ValueChanged<RecentActivityKind>? onOpenActivity;

  /// Wallets in display order (main first); the horizontal shortcuts row is
  /// left out entirely while this is null.
  final Stream<List<WalletSummary>>? walletSummaries;

  /// Total cash per currency, over every non-archived wallet.
  final Stream<List<WalletCurrencyTotal>>? walletTotals;
  final ValueChanged<String>? onOpenWallet;
  final VoidCallback? onOpenWallets;
  final VoidCallback? onAddWallet;

  /// The user's chosen base currency — the hero card's reference currency
  /// when no receivable, payable or cash amount decides it otherwise.
  final String defaultCurrencyCode;

  @override
  Widget build(BuildContext context) {
    return JibiPage(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: JibiColors.deepGreen,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'مرحباً بك في جيبي 👋',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w900, fontSize: 21),
                ),
              ),
              JibiBadge(
                'مشفر بالكامل AES-256',
                background: JibiColors.mintCard,
                foreground: JibiColors.deepGreen,
                icon: Icons.verified_user_outlined,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 18),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                'أموالك وبياناتك المهمة، في مكان واحد وآمن.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: context.jibiMuted),
              ),
            ),
          ),
          const SizedBox(height: 20),
          _HeroBalanceCard(
            summary: summary,
            currencies: currencies,
            labels: labels,
            hideBalances: hideBalances,
            toggleKey: hideToggleKey,
            defaultCurrencyCode: defaultCurrencyCode,
          ),
          const SizedBox(height: 24),
          const JibiSectionHeader(title: 'إجراءات سريعة'),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 12.0;
              final tileWidth = (constraints.maxWidth - gap) / 2;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  SizedBox(
                    width: tileWidth,
                    child: JibiQuickActionCard(
                      icon: Icons.person_add_alt_1_outlined,
                      title: 'عملية ${labels.debit} / ${labels.credit}',
                      subtitle: 'سجّلها في أحد الحسابات',
                      tint: JibiColors.mintCard,
                      foreground: JibiColors.deepGreen,
                      onTap: onAddTransaction ?? () {},
                    ),
                  ),
                  SizedBox(
                    width: tileWidth,
                    child: JibiQuickActionCard(
                      icon: Icons.group_add_outlined,
                      title: 'حساب جديد',
                      subtitle: 'شخص أو جهة جديدة',
                      tint: JibiColors.mintCard,
                      foreground: JibiColors.deepGreen,
                      onTap: onAddAccount ?? () {},
                    ),
                  ),
                  SizedBox(
                    width: tileWidth,
                    child: JibiQuickActionCard(
                      icon: Icons.key_outlined,
                      title: 'إضافة كلمة مرور',
                      subtitle: 'خزنة كلمات المرور',
                      tint: JibiColors.goldSoft.withValues(alpha: 0.5),
                      foreground: const Color(0xFF9C7A1B),
                      onTap: onAddPassword ?? () {},
                    ),
                  ),
                  SizedBox(
                    width: tileWidth,
                    child: JibiQuickActionCard(
                      icon: Icons.note_add_outlined,
                      title: 'إضافة مستند',
                      subtitle: 'صورة مشفرة أو عقد',
                      tint: JibiColors.mintCard,
                      foreground: JibiColors.deepGreen,
                      onTap: onAddDocument ?? () {},
                    ),
                  ),
                ],
              );
            },
          ),
          if (walletSummaries != null) ...[
            _WalletsSection(
              summaries: walletSummaries!,
              totals: walletTotals,
              currencies: currencies,
              hidden: hideBalances,
              onOpenWallet: onOpenWallet,
              onOpenWallets: onOpenWallets,
              onAddWallet: onAddWallet,
            ),
            const SizedBox(height: 24),
          ],
          _BackupBanner(
            status: backupStatus,
            onOpenSettings: onOpenSettings,
            onBackupNow: onBackupNow,
          ),
          const SizedBox(height: 24),
          _RecentSection(
            recentActivity: recentActivity,
            onOpen: onOpenActivity,
          ),
        ],
      ),
    );
  }
}

/// The wallets shortcuts row: a small total line per currency, then one
/// horizontally scrollable card per wallet (main first) plus an "add" tile.
class _WalletsSection extends StatelessWidget {
  const _WalletsSection({
    required this.summaries,
    this.totals,
    this.currencies,
    this.hidden = false,
    this.onOpenWallet,
    this.onOpenWallets,
    this.onAddWallet,
  });

  final Stream<List<WalletSummary>> summaries;
  final Stream<List<WalletCurrencyTotal>>? totals;
  final CurrencyRegistry? currencies;
  final bool hidden;
  final ValueChanged<String>? onOpenWallet;
  final VoidCallback? onOpenWallets;
  final VoidCallback? onAddWallet;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<WalletSummary>>(
    stream: summaries,
    builder: (context, snapshot) {
      final items = snapshot.data;
      if (items == null) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          JibiSectionHeader(
            title: 'المحافظ',
            actionLabel: 'عرض الكل',
            onAction: onOpenWallets,
          ),
          if (totals != null)
            StreamBuilder<List<WalletCurrencyTotal>>(
              stream: totals,
              builder: (context, totalsSnapshot) {
                final rows = totalsSnapshot.data;
                if (rows == null || rows.isEmpty || currencies == null) {
                  return const SizedBox(height: 8);
                }
                return Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 2,
                    top: 2,
                    bottom: 10,
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    children: [
                      for (final total in rows)
                        Text(
                          hidden
                              ? 'إجمالي ${total.currencyCode} ••••'
                              : 'إجمالي ${total.currencyCode} '
                                    '${currencies!.format(Money(amountMinor: total.totalMinor, currencyCode: total.currencyCode))}',
                          style: TextStyle(
                            color: context.jibiMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                );
              },
            )
          else
            const SizedBox(height: 8),
          SizedBox(
            height: 144,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length + (onAddWallet == null ? 0 : 1),
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                if (index >= items.length) {
                  return _AddWalletTile(onTap: onAddWallet);
                }
                final summary = items[index];
                return _WalletTile(
                  key: Key('home-wallet-${summary.wallet.id}'),
                  summary: summary,
                  currencies: currencies,
                  hidden: hidden,
                  onTap: onOpenWallet == null
                      ? null
                      : () => onOpenWallet!(summary.wallet.id),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}

class _WalletTile extends StatelessWidget {
  const _WalletTile({
    super.key,
    required this.summary,
    this.currencies,
    this.hidden = false,
    this.onTap,
  });

  final WalletSummary summary;
  final CurrencyRegistry? currencies;
  final bool hidden;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final wallet = summary.wallet;
    final primary = summary.primary;
    final amountText = hidden
        ? '••••'
        : primary == null
        ? '—'
        : currencies == null
        ? primary.balanceMinor.toString()
        : currencies!.format(
            Money(
              amountMinor: primary.balanceMinor,
              currencyCode: primary.currencyCode,
            ),
          );
    return SizedBox(
      width: 112,
      child: JibiSoftCard(
        onTap: onTap,
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _WalletTileAvatar(wallet: wallet),
            const SizedBox(height: 8),
            Text(
              wallet.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                amountText,
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: context.jibiInk,
                ),
              ),
            ),
            if (!hidden && summary.isMultiCurrency)
              Text(
                '${summary.nonZero.length} عملات',
                style: TextStyle(fontSize: 10, color: context.jibiMuted),
              ),
          ],
        ),
      ),
    );
  }
}

/// The wallet's picture, or a tinted circle with its type icon. Kept local
/// (rather than reusing the `app/wallets` avatar) so the dashboard stays a
/// repository-free preview with no dependency on the app layer.
class _WalletTileAvatar extends StatelessWidget {
  const _WalletTileAvatar({required this.wallet});

  final Wallet wallet;

  static const _size = 40.0;

  @override
  Widget build(BuildContext context) {
    final image = wallet.image;
    if (image == null) return _fallback();
    return ClipOval(
      child: Image.memory(
        image,
        width: _size,
        height: _size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _fallback(),
      ),
    );
  }

  Widget _fallback() => Container(
    width: _size,
    height: _size,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      color: JibiColors.mintCard,
    ),
    child: Icon(
      Icons.account_balance_wallet_outlined,
      color: JibiColors.deepGreen,
      size: 20,
    ),
  );
}

class _AddWalletTile extends StatelessWidget {
  const _AddWalletTile({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 112,
    child: JibiSoftCard(
      onTap: onTap,
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.add_circle_outline,
            color: JibiColors.deepGreen,
            size: 32,
          ),
          const SizedBox(height: 8),
          Text(
            'إضافة محفظة',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: context.jibiMuted,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Dark gradient hero with the net financial position and monthly spend.
class _HeroBalanceCard extends StatefulWidget {
  const _HeroBalanceCard({
    this.summary,
    this.currencies,
    this.labels = BookLabels.standard,
    this.hideBalances = false,
    this.toggleKey,
    this.defaultCurrencyCode = 'YER',
  });

  final GlobalKey? toggleKey;
  final Stream<DashboardSummary>? summary;
  final CurrencyRegistry? currencies;
  final BookLabels labels;
  final bool hideBalances;
  final String defaultCurrencyCode;

  @override
  State<_HeroBalanceCard> createState() => _HeroBalanceCardState();
}

class _HeroBalanceCardState extends State<_HeroBalanceCard> {
  late bool _hidden = widget.hideBalances;

  @override
  void didUpdateWidget(_HeroBalanceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hideBalances != widget.hideBalances) {
      _hidden = widget.hideBalances;
    }
  }

  void _toggleHidden() => setState(() => _hidden = !_hidden);

  @override
  Widget build(BuildContext context) {
    final currencies = widget.currencies ?? CurrencyRegistry.defaults();
    // Before the data arrives the panel already wears the base currency.
    Widget framed(Widget child) => _HeroPanel(
      currencies: currencies,
      code: widget.defaultCurrencyCode,
      hidden: _hidden,
      onToggleHidden: _toggleHidden,
      toggleKey: widget.toggleKey,
      child: child,
    );
    if (widget.summary == null) return framed(const _HeroPlaceholder());
    return StreamBuilder<DashboardSummary>(
      stream: widget.summary,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return framed(
            const JibiErrorState(message: 'تعذر تحميل الملخص المالي.'),
          );
        }
        if (!snapshot.hasData) {
          return framed(
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  color: JibiColors.gold,
                  backgroundColor: Color(0x33FFFFFF),
                ),
              ),
            ),
          );
        }
        return _HeroContent(
          summary: snapshot.data!,
          currencies: currencies,
          hidden: _hidden,
          onToggleHidden: _toggleHidden,
          toggleKey: widget.toggleKey,
          labels: widget.labels,
          defaultCurrencyCode: widget.defaultCurrencyCode,
        );
      },
    );
  }
}

/// The card's frame: a panel in the hue of the currency being shown, with that
/// currency's name as the title («الريال اليمني»…) and the hide-amounts toggle.
class _HeroPanel extends StatelessWidget {
  const _HeroPanel({
    required this.currencies,
    required this.code,
    required this.hidden,
    required this.onToggleHidden,
    required this.child,
    this.toggleKey,
  });

  final CurrencyRegistry currencies;
  final String code;
  final bool hidden;
  final VoidCallback onToggleHidden;
  final GlobalKey? toggleKey;
  final Widget child;

  String get _title {
    try {
      return currencies.byCode(code).name;
    } on Object {
      return code;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Color(currencies.colorValueOf(code));
    return JibiDarkPanel(
      key: const Key('hero-panel'),
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.75),
                          width: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _title,
                        key: const Key('hero-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                key: toggleKey,
                message: hidden ? 'إظهار المبالغ' : 'إخفاء المبالغ',
                child: InkWell(
                  onTap: onToggleHidden,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      hidden
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

class _HeroPlaceholder extends StatelessWidget {
  const _HeroPlaceholder();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 22),
    child: Text(
      'ستظهر ملخصاتك المالية هنا بعد أول عملية.',
      style: TextStyle(color: Colors.white.withValues(alpha: 0.8)),
    ),
  );
}

/// Every currency the user holds gets an equal-weight swipeable page — no
/// currency is silently picked and shown big while the rest are demoted to a
/// small list. The user's default currency opens first (page 0); after that,
/// swiping is the only way to move between currencies, and every page is the
/// same treatment (big number, symbol, wallet-cash line, debit/credit cards).
class _HeroContent extends StatefulWidget {
  const _HeroContent({
    required this.summary,
    required this.currencies,
    required this.hidden,
    required this.onToggleHidden,
    required this.labels,
    required this.defaultCurrencyCode,
    this.toggleKey,
  });

  final DashboardSummary summary;
  final CurrencyRegistry currencies;
  final bool hidden;
  final VoidCallback onToggleHidden;
  final GlobalKey? toggleKey;
  final BookLabels labels;
  final String defaultCurrencyCode;

  @override
  State<_HeroContent> createState() => _HeroContentState();
}

class _HeroContentState extends State<_HeroContent> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _pick(List<Money> amounts, String code) {
    for (final amount in amounts) {
      if (amount.currencyCode == code) {
        return amount.amountMinor;
      }
    }
    return 0;
  }

  Widget _buildPage(String code) {
    final summary = widget.summary;
    final currencies = widget.currencies;
    final labels = widget.labels;
    final masked = widget.hidden;
    final symbol = currencies.byCode(code).symbol ?? code;
    final cash = _pick(summary.cash, code);
    final receivable = _pick(summary.receivable, code);
    final payable = _pick(summary.payable, code);
    // Cash plus what people owe the user, minus what the user owes them. A
    // book transaction linked to a wallet moves cash and receivable/payable
    // in opposite directions by the same amount, so it nets to zero here —
    // no double counting between the book and the wallet.
    final net = cash + receivable - payable;
    final hasCash = summary.cash.any((amount) => amount.currencyCode == code);
    final magnitude = currencies.format(
      Money(amountMinor: net.abs(), currencyCode: code),
    );
    final cashText = currencies.format(
      Money(amountMinor: cash, currencyCode: code),
    );
    final receivableText = currencies.format(
      Money(amountMinor: receivable, currencyCode: code),
    );
    final payableText = currencies.format(
      Money(amountMinor: payable, currencyCode: code),
    );

    return SingleChildScrollView(
      key: Key('hero-page-$code'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            masked ? '••••' : magnitude,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
              height: 1.15,
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              symbol,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (hasCash) ...[
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                key: Key('hero-cash-$code'),
                masked ? 'الأجمالي : ••••' : 'الأجمالي : $cashText',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _HeroStatCard(
                  label: labels.debitWithHint,
                  amount: masked ? '••••' : receivableText,
                  symbol: symbol,
                  icon: Icons.south_west,
                  iconTint: Colors.white.withValues(alpha: 0.16),
                  iconColor: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _HeroStatCard(
                  label: labels.creditWithHint,
                  amount: masked ? '••••' : payableText,
                  symbol: symbol,
                  icon: Icons.north_east,
                  iconTint: JibiColors.gold.withValues(alpha: 0.22),
                  iconColor: JibiColors.gold,
                  amountColor: JibiColors.goldSoft,
                ),
              ),
            ],
          ),
          if (net < 0 && !masked) ...[
            const SizedBox(height: 12),
            Text(
              '${labels.creditWithHint} يتجاوز ${labels.debitWithHint}',
              style: const TextStyle(
                color: JibiColors.goldSoft,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  int _sortOrderOf(String code) {
    try {
      return widget.currencies.byCode(code).sortOrder;
    } on Object {
      return 1 << 30;
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    // Every tracked currency gets its own page; the default currency is
    // always first so it opens on first paint, then the rest in the order of
    // the currency settings. Nothing makes one currency more prominent than
    // another.
    final codes = <String>{
      for (final amount in summary.cash) amount.currencyCode,
      for (final amount in summary.receivable) amount.currencyCode,
      for (final amount in summary.payable) amount.currencyCode,
    };
    if (codes.isEmpty) codes.add(widget.defaultCurrencyCode);
    final ordered = codes.toList()
      ..sort((a, b) {
        if (a == widget.defaultCurrencyCode) return -1;
        if (b == widget.defaultCurrencyCode) return 1;
        final order = _sortOrderOf(a).compareTo(_sortOrderOf(b));
        return order != 0 ? order : a.compareTo(b);
      });
    final current = ordered[_page.clamp(0, ordered.length - 1)];

    return _HeroPanel(
      currencies: widget.currencies,
      code: current,
      hidden: widget.hidden,
      onToggleHidden: widget.onToggleHidden,
      toggleKey: widget.toggleKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 200,
            child: PageView.builder(
              controller: _controller,
              itemCount: ordered.length,
              onPageChanged: (value) => setState(() => _page = value),
              itemBuilder: (context, index) => _buildPage(ordered[index]),
            ),
          ),
          if (ordered.length > 1) ...[
            const SizedBox(height: 10),
            Row(
              key: const Key('hero-dots'),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var index = 0; index < ordered.length; index++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: index == _page ? 20 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: index == _page
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroStatCard extends StatelessWidget {
  const _HeroStatCard({
    required this.label,
    required this.amount,
    required this.symbol,
    required this.icon,
    required this.iconTint,
    required this.iconColor,
    this.amountColor = Colors.white,
  });

  final String label;
  final String amount;
  final String symbol;
  final IconData icon;
  final Color iconTint;
  final Color iconColor;
  final Color amountColor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.72),
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    amount,
                    style: TextStyle(
                      color: amountColor,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    symbol,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconTint,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Backup banner driven by the real state of the local backups: never made,
/// overdue by the reminder schedule, or up to date.
class _BackupBanner extends StatelessWidget {
  const _BackupBanner({this.status, this.onOpenSettings, this.onBackupNow});

  final Future<BackupStatus>? status;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onBackupNow;

  @override
  Widget build(BuildContext context) => FutureBuilder<BackupStatus>(
    future: status,
    builder: (context, snapshot) {
      final value = snapshot.data;
      final never = value != null && value.lastBackupAt == null;
      final due = value != null && (never || value.due);
      final title = value == null
          ? 'النسخ الاحتياطي'
          : never
          ? 'لم تنشئ نسخة احتياطية بعد'
          : value.due
          ? 'حان موعد النسخ الاحتياطي'
          : 'بياناتك محفوظة في نسخة احتياطية';
      final subtitle = value == null
          ? 'أنشئ نسخة مشفرة لحماية بياناتك من الفقدان.'
          : never
          ? 'أنشئ نسخة مشفرة الآن لحماية بياناتك من الفقدان.'
          : 'آخر نسخة: ${jibiRelativeTimeAr(value.lastBackupAt!)}';
      return JibiSoftCard(
        onTap: onOpenSettings,
        color: JibiColors.mintCard.withValues(alpha: 0.6),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            JibiIconBubble(
              icon: due ? Icons.backup_outlined : Icons.cloud_done_outlined,
              tint: JibiColors.gold.withValues(alpha: 0.25),
              foreground: const Color(0xFF9C7A1B),
              size: 44,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: context.jibiInk,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11.5, color: context.jibiMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (due && onBackupNow != null)
              FilledButton.tonal(
                onPressed: onBackupNow,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                child: const Text('نسخ الآن'),
              )
            else if (value != null)
              JibiBadge(
                due ? 'مطلوبة' : 'محدّثة',
                background: due
                    ? JibiColors.gold.withValues(alpha: 0.25)
                    : JibiColors.deepGreen.withValues(alpha: 0.1),
                foreground: due
                    ? const Color(0xFF8A6A14)
                    : JibiColors.deepGreen,
                icon: due ? Icons.schedule : Icons.lock_outline,
              ),
          ],
        ),
      );
    },
  );
}

/// آخر النشاطات with a count badge and a show-all toggle.
class _RecentSection extends StatefulWidget {
  const _RecentSection({this.recentActivity, this.onOpen});

  final Stream<List<RecentActivityItem>>? recentActivity;
  final ValueChanged<RecentActivityKind>? onOpen;

  @override
  State<_RecentSection> createState() => _RecentSectionState();
}

class _RecentSectionState extends State<_RecentSection> {
  bool _showAll = false;

  IconData _iconFor(RecentActivityKind kind) => switch (kind) {
    RecentActivityKind.transaction => Icons.swap_horiz,
    RecentActivityKind.credential => Icons.key,
    RecentActivityKind.document => Icons.description_outlined,
  };

  Color _tintFor(RecentActivityKind kind) => switch (kind) {
    RecentActivityKind.transaction => JibiColors.mintCard,
    RecentActivityKind.credential => JibiColors.goldSoft.withValues(
      alpha: 0.35,
    ),
    RecentActivityKind.document => const Color(0xFFE4EEF8),
  };

  Color _foregroundFor(RecentActivityKind kind) => switch (kind) {
    RecentActivityKind.transaction => JibiColors.deepGreen,
    RecentActivityKind.credential => const Color(0xFF9C7A1B),
    RecentActivityKind.document => const Color(0xFF2E5E8C),
  };

  String _statusFor(RecentActivityKind kind) => switch (kind) {
    RecentActivityKind.transaction => 'عملية حسابات',
    RecentActivityKind.credential => 'بيانات دخول',
    RecentActivityKind.document => 'مستند مشفر',
  };

  @override
  Widget build(BuildContext context) {
    final body = widget.recentActivity == null
        ? Text(
            'ستظهر آخر العمليات هنا بعد أول استخدام.',
            style: TextStyle(color: context.jibiMuted),
          )
        : StreamBuilder<List<RecentActivityItem>>(
            stream: widget.recentActivity,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const JibiErrorState(message: 'تعذر تحميل النشاطات.');
              }
              if (!snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: LinearProgressIndicator(minHeight: 3),
                );
              }
              final items = snapshot.data!;
              if (items.isEmpty) {
                return Text(
                  'لا توجد نشاطات بعد.',
                  style: TextStyle(color: context.jibiMuted),
                );
              }
              final visible = _showAll ? items : items.take(5).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in visible)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: JibiSoftCard(
                        padding: const EdgeInsets.all(12),
                        radius: 18,
                        onTap: widget.onOpen == null
                            ? null
                            : () => widget.onOpen!(item.kind),
                        child: Row(
                          children: [
                            JibiIconBubble(
                              icon: _iconFor(item.kind),
                              tint: _tintFor(item.kind),
                              foreground: _foregroundFor(item.kind),
                              size: 42,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                      color: context.jibiInk,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${item.subtitle} • ${jibiRelativeTimeAr(item.occurredAt)}',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: context.jibiMuted,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _statusFor(item.kind),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: _foregroundFor(item.kind),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JibiSectionHeader(
          title: 'آخر النشاطات',
          actionLabel: _showAll ? 'إظهار أقل' : 'عرض الكل',
          onAction: widget.recentActivity == null
              ? null
              : () => setState(() => _showAll = !_showAll),
        ),
        const SizedBox(height: 12),
        body,
      ],
    );
  }
}
