import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../jibi_app_shell.dart';
import 'book_category_page.dart';
import 'book_forms.dart';
import 'book_widgets.dart';

/// "إدارة التصنيفات": every category with its on/off switch. Switching a
/// category off hides it and its accounts; nothing is deleted.
class BookCategoryManagementPage extends StatefulWidget {
  const BookCategoryManagementPage({required this.book, super.key});

  final BookServices book;

  @override
  State<BookCategoryManagementPage> createState() =>
      _BookCategoryManagementPageState();
}

class _BookCategoryManagementPageState
    extends State<BookCategoryManagementPage> {
  late final Stream<List<CategorySummary>> _summaries = widget.book.categories
      .watchSummaries(includeInactive: true, includeArchived: true);
  bool _showArchived = false;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    }
  }

  Future<void> _delete(BookCategory category, int accountCount) async {
    final confirmed = await JibiConfirmationDialog.show(
      context,
      title: 'حذف التصنيف',
      message: accountCount > 0
          ? 'سيُحذف التصنيف «${category.name}» وحساباته الـ$accountCount '
                'نهائياً. هل تريد المتابعة؟'
          : 'سيُحذف التصنيف «${category.name}» نهائياً. هل تريد المتابعة؟',
      confirmLabel: 'حذف',
      isDestructive: true,
    );
    if (confirmed == true) {
      await _run(() => widget.book.categories.delete(category.id));
    }
  }

  Future<void> _move(
    List<CategorySummary> ordered,
    CategorySummary summary,
    int delta,
  ) async {
    final ids = [for (final item in ordered) item.category.id];
    final index = ids.indexOf(summary.category.id);
    final target = index + delta;
    if (target < 0 || target >= ids.length) return;
    ids
      ..removeAt(index)
      ..insert(target, summary.category.id);
    await _run(() => widget.book.categories.reorder(ids));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('إدارة التصنيفات')),
    body: StreamBuilder<List<CategorySummary>>(
      stream: _summaries,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text(bookErrorMessage(snapshot.error!)));
        }
        final all = snapshot.data;
        if (all == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final active = all
            .where((s) => !s.category.isArchived)
            .toList(growable: false);
        final archived = all.length - active.length;
        final shown = _showArchived ? all : active;
        return ListView(
          padding: bookPagePadding,
          children: [
            _Banner(activeCount: active.where((s) => s.category.isActive).length),
            const SizedBox(height: 16),
            if (archived > 0)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilterChip(
                  key: const Key('chip-archived-categories'),
                  label: Text('المؤرشفة ($archived)'),
                  selected: _showArchived,
                  onSelected: (value) => setState(() => _showArchived = value),
                ),
              ),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: JibiEmptyState(
                  icon: Icons.folder_open_outlined,
                  title: 'لا توجد تصنيفات حتى الآن',
                  message: 'أنشئ تصنيفاً لتنظيم حساباتك.',
                  actionLabel: 'إضافة تصنيف',
                  onAction: () => openCategoryForm(context, widget.book),
                ),
              ),
            for (final summary in shown) ...[
              _ManagedCategoryCard(
                key: Key('managed-${summary.category.id}'),
                book: widget.book,
                summary: summary,
                onToggle: (value) => _run(
                  () => widget.book.categories.setActive(
                    summary.category.id,
                    isActive: value,
                  ),
                ),
                onEdit: () => openCategoryForm(
                  context,
                  widget.book,
                  category: summary.category,
                ),
                onArchive: () => _run(
                  () => widget.book.categories.setArchived(
                    summary.category.id,
                    archived: !summary.category.isArchived,
                  ),
                ),
                onDelete: () => _delete(summary.category, summary.accountCount),
                onMoveUp: () => _move(shown, summary, -1),
                onMoveDown: () => _move(shown, summary, 1),
              ),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          key: const Key('add-category-button'),
          onPressed: () => openCategoryForm(context, widget.book),
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('إضافة تصنيف جديد'),
        ),
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.activeCount});

  final int activeCount;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: JibiColors.heroGradient,
      borderRadius: BorderRadius.circular(22),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.shield_outlined, color: JibiColors.gold, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'مدونة الحسابات المستقلة',
                style: TextStyle(
                  color: JibiColors.gold,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            JibiBadge(
              '$activeCount تصنيفات مفعلة',
              background: Colors.white.withValues(alpha: 0.16),
              foreground: Colors.white,
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'كل تصنيف يضم حساباته وعملياته بنظام مدين / دائن، وأرصدة كل عملة '
          'منفصلة بلا دمج وهمي.',
          style: TextStyle(color: Colors.white, fontSize: 12.5, height: 1.5),
        ),
      ],
    ),
  );
}

class _ManagedCategoryCard extends StatelessWidget {
  const _ManagedCategoryCard({
    required this.book,
    required this.summary,
    required this.onToggle,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
    super.key,
  });

  final BookServices book;
  final CategorySummary summary;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  Widget build(BuildContext context) {
    final category = summary.category;
    final currencies = [for (final total in summary.totals) total.currencyCode];
    final off = !category.isActive || category.isArchived;
    return BookCard(
      dimmed: off,
      onTap: category.isArchived
          ? null
          : () => pushShellPage<void>(
              context,
              BookCategoryPage(book: book, categoryId: category.id),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              JibiIconBubble(
                icon: bookCategoryIcon(category.icon),
                tint: Theme.of(context).colorScheme.primary.withValues(
                  alpha: 0.12,
                ),
                foreground: Theme.of(context).colorScheme.primary,
                size: 48,
              ),
              const SizedBox(width: 12),
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
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final code in currencies)
                          JibiBadge(
                            code,
                            background: JibiColors.gold.withValues(alpha: 0.25),
                            foreground: JibiColors.onTintInk,
                          ),
                        Text(
                          '${summary.accountCount} حساب',
                          style: TextStyle(
                            color: context.jibiMuted,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!category.isArchived)
                Switch(
                  key: Key('switch-${category.id}'),
                  value: category.isActive,
                  onChanged: onToggle,
                ),
              PopupMenuButton<String>(
                key: Key('category-menu-${category.id}'),
                tooltip: 'خيارات التصنيف',
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      onEdit();
                    case 'archive':
                      onArchive();
                    case 'delete':
                      onDelete();
                    case 'up':
                      onMoveUp();
                    case 'down':
                      onMoveDown();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('تعديل')),
                  const PopupMenuItem(value: 'up', child: Text('نقل للأعلى')),
                  const PopupMenuItem(value: 'down', child: Text('نقل للأسفل')),
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(category.isArchived ? 'إلغاء الأرشفة' : 'أرشفة'),
                  ),
                  const PopupMenuItem(value: 'delete', child: Text('حذف')),
                ],
              ),
            ],
          ),
          if (off) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: context.jibiMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    category.isArchived
                        ? 'مؤرشف – محفوظ بالكامل في قاعدة البيانات'
                        : 'معطل – محفوظ بالكامل، غير ظاهر في الحسابات',
                    style: TextStyle(color: context.jibiMuted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ] else if (summary.totals.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final total in summary.totals)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _NetLine(book: book, total: total),
              ),
          ],
        ],
      ),
    );
  }
}

class _NetLine extends StatelessWidget {
  const _NetLine({required this.book, required this.total});

  final BookServices book;
  final CurrencyTotals total;

  @override
  Widget build(BuildContext context) {
    final prefs = context.bookPrefs;
    final labels = prefs.labels;
    final side = total.side;
    final color = context.sideColor(side);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(sideIcon(side), size: 16, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'رصيد (${labels.side(side)}${labels.sideHint(side).isEmpty ? '' : ' – ${labels.sideHint(side)}'})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: BookAmountText(
                  text: prefs.balance(
                    bookAmount(
                      book.currencies,
                      total.currencyCode,
                      total.netMinor.abs(),
                    ),
                  ),
                  currencyCode: total.currencyCode,
                  size: 17,
                  color: side == BalanceSide.settled ? context.jibiInk : color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
