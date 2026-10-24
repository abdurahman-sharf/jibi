import 'package:flutter/material.dart';

import 'jibi_design.dart';

/// One card of the welcome tour.
class WalkthroughCard {
  const WalkthroughCard({
    required this.icon,
    required this.title,
    required this.description,
    this.accentIcons = const <IconData>[],
  });

  final IconData icon;
  final String title;
  final String description;

  /// Small icons drawn around the main one, to hint at what the feature covers.
  final List<IconData> accentIcons;
}

/// What the tour tells a new user (الشاشات الترحيبية).
const List<WalkthroughCard> jibiWalkthroughCards = <WalkthroughCard>[
  WalkthroughCard(
    icon: Icons.account_tree_outlined,
    title: 'حساباتك مرتّبة',
    description:
        'صنّف حساباتك (حسابات اليمن، الأشخاص، المشاريع...) وسجّل لكل حساب '
        'عمليات مدين ودائن. الرصيد يُحسب تلقائياً بعد كل عملية.',
    accentIcons: [Icons.folder_outlined, Icons.person_outline, Icons.tag],
  ),
  WalkthroughCard(
    icon: Icons.add_circle_outline,
    title: 'سجّل في ثوانٍ',
    description:
        'زر «+» في الأسفل يفتح إضافة عملية أو حساب أو تصنيف بخطوات قليلة، '
        'ويمكنك تعديل أي عملية قديمة فتُعاد الأرصدة بعدها تلقائياً.',
    accentIcons: [Icons.edit_outlined, Icons.history, Icons.attach_file],
  ),
  WalkthroughCard(
    icon: Icons.picture_as_pdf_outlined,
    title: 'تقارير جاهزة للمشاركة',
    description:
        'كشف حساب وتقارير التصنيف بصيغة PDF أو Excel أو عبر واتساب، '
        'بشعارك وتوقيعك وختمك.',
    accentIcons: [Icons.table_chart_outlined, Icons.share_outlined, Icons.print_outlined],
  ),
  WalkthroughCard(
    icon: Icons.shield_outlined,
    title: 'محمي ومشفّر',
    description:
        'رمز PIN وبصمة وتشفير قوي للبيانات الحساسة. بياناتك تبقى على '
        'هاتفك ولا تُرسَل إلى أي جهة إلا بمشاركتك أنت.',
    accentIcons: [Icons.fingerprint, Icons.lock_outline, Icons.visibility_off_outlined],
  ),
  WalkthroughCard(
    icon: Icons.key_outlined,
    title: 'كلمات المرور والمستندات',
    description:
        'خزنة مشفرة لكلمات المرور ومستنداتك المهمة، مع صور وملفات مرفقة '
        'تُفتح داخل التطبيق.',
    accentIcons: [Icons.folder_open_outlined, Icons.badge_outlined, Icons.photo_camera_outlined],
  ),
  WalkthroughCard(
    icon: Icons.backup_outlined,
    title: 'نسخة احتياطية بيدك',
    description:
        'انسخ بياناتك في ملف مشفر واحفظه أو شاركه، ثم استعده على أي هاتف. '
        'ذكّرنا بموعد النسخ كي لا تنساه.',
    accentIcons: [Icons.cloud_upload_outlined, Icons.restore_outlined, Icons.notifications_none],
  ),
];

/// Swipeable cards that introduce the app's main features, with a page
/// indicator, "التالي" and "تخطي". Calls [onFinished] on the last card's button
/// and when skipped.
class JibiWalkthrough extends StatefulWidget {
  const JibiWalkthrough({
    required this.onFinished,
    this.cards = jibiWalkthroughCards,
    this.finishLabel = 'ابدأ',
    super.key,
  }) : assert(cards.length > 0);

  final VoidCallback onFinished;
  final List<WalkthroughCard> cards;

  /// The last card's button.
  final String finishLabel;

  @override
  State<JibiWalkthrough> createState() => _JibiWalkthroughState();
}

class _JibiWalkthroughState extends State<JibiWalkthrough> {
  final PageController _controller = PageController();
  int _page = 0;

  bool get _isLast => _page == widget.cards.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_isLast) {
      widget.onFinished();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    key: const Key('walkthrough'),
    child: Column(
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextButton(
              key: const Key('walkthrough-skip'),
              onPressed: widget.onFinished,
              child: const Text('تخطي'),
            ),
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.cards.length,
            onPageChanged: (value) => setState(() => _page = value),
            itemBuilder: (context, index) => _CardPage(
              key: Key('walkthrough-page-$index'),
              card: widget.cards[index],
              active: index == _page,
            ),
          ),
        ),
        Semantics(
          label: 'الصفحة ${_page + 1} من ${widget.cards.length}',
          child: Row(
            key: const Key('walkthrough-dots'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var index = 0; index < widget.cards.length; index++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: index == _page ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: index == _page
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('walkthrough-next'),
              onPressed: _next,
              child: Text(_isLast ? widget.finishLabel : 'التالي'),
            ),
          ),
        ),
      ],
    ),
  );
}

class _CardPage extends StatelessWidget {
  const _CardPage({required this.card, required this.active, super.key});

  final WalkthroughCard card;
  final bool active;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedScale(
              scale: active ? 1 : 0.88,
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeOutBack,
              child: AnimatedOpacity(
                opacity: active ? 1 : 0.4,
                duration: const Duration(milliseconds: 300),
                child: _Illustration(card: card),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              card.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              card.description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: context.jibiMuted,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The picture of a card: the feature's icon on the brand gradient with the
/// related icons floating around it.
class _Illustration extends StatelessWidget {
  const _Illustration({required this.card});

  final WalkthroughCard card;

  @override
  Widget build(BuildContext context) {
    // Positions (as fractions of the panel) for up to three accents.
    const spots = <Alignment>[
      Alignment(-0.78, -0.62),
      Alignment(0.8, -0.3),
      Alignment(-0.55, 0.72),
    ];
    return Container(
      height: 220,
      decoration: BoxDecoration(
        gradient: JibiColors.heroGradient,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: JibiColors.deepGreen.withValues(alpha: 0.28),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        children: [
          for (var index = 0; index < card.accentIcons.length && index < spots.length; index++)
            Align(
              alignment: spots[index],
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  card.accentIcons[index],
                  color: Colors.white.withValues(alpha: 0.85),
                  size: 22,
                ),
              ),
            ),
          Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                shape: BoxShape.circle,
                border: Border.all(
                  color: JibiColors.gold.withValues(alpha: 0.7),
                  width: 2,
                ),
              ),
              child: Icon(card.icon, color: Colors.white, size: 56),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the tour on its own page (from Settings: "جولة تعريفية"). Pops when
/// finished or skipped.
Future<void> showJibiWalkthrough(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => Scaffold(
          body: JibiWalkthrough(
            finishLabel: 'تم',
            onFinished: () => Navigator.of(routeContext).pop(),
          ),
        ),
      ),
    );
