import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../shared/widgets/coach_marks.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../coach_tours.dart';
import '../jibi_app_shell.dart';
import 'book_category_management_page.dart';
import 'book_category_page.dart';
import 'book_forms.dart';
import 'book_widgets.dart';

/// The root of the accounts section: the net position of the book and the
/// active categories. Categories that are switched off or archived do not
/// appear here; they are managed from "إدارة التصنيفات".
class BookCategoriesPage extends StatefulWidget {
  const BookCategoriesPage({required this.book, super.key});

  final BookServices book;

  @override
  State<BookCategoriesPage> createState() => _BookCategoriesPageState();
}

class _BookCategoriesPageState extends State<BookCategoriesPage> {
  late final Stream<List<CategorySummary>> _summaries = widget.book.categories
      .watchSummaries();

  // Targets of the hint tour.
  final _tipPosition = GlobalKey(debugLabel: 'tip-position');
  final _tipManage = GlobalKey(debugLabel: 'tip-manage-categories');
  final _tipFirstCategory = GlobalKey(debugLabel: 'tip-first-category');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The tab is built before it is opened: this runs again when it is.
    context.startTourOnce(CoachTourIds.accounts, _tourSteps);
  }

  List<CoachStep> _tourSteps() {
    final shell = context.findAncestorStateOfType<JibiAppShellState>();
    return [
      CoachStep(
        target: _tipPosition,
        title: 'الصافي لكل عملة',
        message: 'مجموع المدين والدائن لكل عملة على حدة؛ العملات المختلفة لا تُجمع معاً.',
      ),
      CoachStep(
        target: _tipManage,
        title: 'إدارة التصنيفات',
        message: 'أضف تصنيفاً أو عدّله أو أوقفه أو أرشفه أو رتّبه.',
      ),
      CoachStep(
        target: _tipFirstCategory,
        title: 'التصنيف',
        message: 'افتحه لترى حساباته وأرصدتها، وأضف حساباً أو عملية.',
      ),
      if (shell != null) ...[
        CoachStep(
          target: shell.fabKey,
          title: 'زر الإضافة',
          message: 'عملية جديدة أو حساب أو تصنيف، من أي مكان في قسم الحسابات.',
        ),
        CoachStep(
          target: shell.tabBarKey(4),
          title: 'التقارير',
          message:
              'تقارير التصنيفات والحسابات، وتصديرها PDF أو Excel أو واتساب.',
        ),
        CoachStep(
          target: shell.tabBarKey(5),
          title: 'الإعدادات',
          message:
              'بيانات المستخدم وتسمية المدين والدائن والأرشيف وسجل التعديلات.',
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<CategorySummary>>(
    stream: _summaries,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(child: Text(bookErrorMessage(snapshot.error!)));
      }
      final summaries = snapshot.data;
      if (summaries == null) {
        return const Center(child: CircularProgressIndicator());
      }
      if (summaries.isEmpty) {
        return JibiEmptyState(
          icon: Icons.folder_open_outlined,
          title: 'لا توجد تصنيفات حتى الآن',
          message: 'أنشئ تصنيفاً لتنظيم حساباتك، مثل «حسابات اليمن».',
          actionLabel: 'إضافة تصنيف',
          onAction: () => openCategoryForm(context, widget.book),
        );
      }
      return ListView(
        padding: bookPagePadding,
        children: [
          KeyedSubtree(
            key: _tipPosition,
            child: _PositionCard(book: widget.book, summaries: summaries),
          ),
          const SizedBox(height: 20),
          KeyedSubtree(
            key: _tipManage,
            child: JibiSectionHeader(
              title: 'التصنيفات',
              count: summaries.length,
              actionLabel: 'إدارة التصنيفات',
              onAction: () => pushShellPage<void>(
                context,
                BookCategoryManagementPage(book: widget.book),
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < summaries.length; index++) ...[
            KeyedSubtree(
              key: index == 0 ? _tipFirstCategory : null,
              child: _CategoryCard(
                book: widget.book,
                summary: summaries[index],
              ),
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: () => openCategoryForm(context, widget.book),
            icon: const Icon(Icons.add),
            label: const Text('إضافة تصنيف جديد'),
          ),
        ],
      );
    },
  );
}

/// What people owe the user and what the user owes, per currency, over every
/// visible category. Currencies are never added together.
class _PositionCard extends StatelessWidget {
  const _PositionCard({required this.book, required this.summaries});

  final BookServices book;
  final List<CategorySummary> summaries;

  @override
  Widget build(BuildContext context) {
    final byCurrency = <String, (int, int)>{};
    for (final summary in summaries) {
      for (final total in summary.totals) {
        final current = byCurrency[total.currencyCode] ?? (0, 0);
        byCurrency[total.currencyCode] = (
          current.$1 + total.debitMinor,
          current.$2 + total.creditMinor,
        );
      }
    }
    final codes = byCurrency.keys.toList()..sort();
    final labels = context.bookPrefs.labels;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: JibiColors.heroGradient,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.shield_outlined, color: JibiColors.gold, size: 18),
              SizedBox(width: 8),
              Text(
                'مدونة الحسابات',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'أرصدة كل عملة منفصلة ولا تُجمع مع غيرها.',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (codes.isEmpty)
            const Text(
              'لا توجد حسابات بعد.',
              style: TextStyle(color: Colors.white70),
            ),
          for (final code in codes)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PositionRow(
                currencyCode: code,
                debitMinor: byCurrency[code]!.$1,
                creditMinor: byCurrency[code]!.$2,
                book: book,
                labels: labels,
              ),
            ),
        ],
      ),
    );
  }
}

class _PositionRow extends StatelessWidget {
  const _PositionRow({
    required this.currencyCode,
    required this.debitMinor,
    required this.creditMinor,
    required this.book,
    required this.labels,
  });

  final String currencyCode;
  final int debitMinor;
  final int creditMinor;
  final BookServices book;
  final BookLabels labels;

  @override
  Widget build(BuildContext context) {
    final net = debitMinor - creditMinor;
    final side = balanceSideOf(net);
    final prefs = context.bookPrefs;
    String amount(int minor) =>
        prefs.balance(bookAmount(book.currencies, currencyCode, minor.abs()));
    Widget cell(String label, int minor) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: BookAmountText(
              text: amount(minor),
              currencyCode: currencyCode,
              color: Colors.white,
              size: 15,
              currencyFirst: false,
            ),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          cell(labels.debitWithHint, debitMinor),
          cell(labels.creditWithHint, creditMinor),
          // A custom word for the side can be long: scale the text down
          // instead of overflowing the row.
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text(
                  'الصافي',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${amount(net)} ${labels.side(side)}',
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.book, required this.summary});

  final BookServices book;
  final CategorySummary summary;

  @override
  Widget build(BuildContext context) {
    final category = summary.category;
    return BookCard(
      onTap: () => pushShellPage<void>(
        context,
        BookCategoryPage(book: book, categoryId: category.id),
      ),
      child: Row(
        children: [
          JibiIconBubble(
            icon: bookCategoryIcon(category.icon),
            tint: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
            foreground: Theme.of(context).colorScheme.primary,
            size: 48,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${summary.accountCount} حساب',
                  style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          // Capped, and each line scales down inside the cap, so a large
          // amount or a long custom side word never overflows the card.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (summary.totals.isEmpty)
                  Text('—', style: TextStyle(color: context.jibiMuted)),
                for (final total in summary.totals.take(3))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          BookAmountText(
                            text: context.bookPrefs.balance(
                              bookAmount(
                                book.currencies,
                                total.currencyCode,
                                total.netMinor.abs(),
                              ),
                            ),
                            currencyCode: total.currencyCode,
                            size: 14,
                            color: context.sideColor(total.side),
                            currencyFirst: false,
                          ),
                          const SizedBox(width: 6),
                          SidePill(side: total.side, compact: true),
                        ],
                      ),
                    ),
                  ),
                if (summary.totals.length > 3)
                  Text(
                    '+${summary.totals.length - 3} عملات',
                    style: TextStyle(color: context.jibiMuted, fontSize: 11),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_left, color: context.jibiMuted),
        ],
      ),
    );
  }
}
