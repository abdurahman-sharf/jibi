import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import 'book_category_page.dart' show openBookAccount;
import 'book_widgets.dart';

/// "الأرشيف": the categories and accounts that were archived, with a button to
/// bring each one back. Archiving only hides an item from the screens; its
/// transactions, reports and history stay (المتطلبات 7 و46).
class BookArchivePage extends StatefulWidget {
  const BookArchivePage({required this.book, super.key});

  final BookServices book;

  @override
  State<BookArchivePage> createState() => _BookArchivePageState();
}

class _BookArchivePageState extends State<BookArchivePage> {
  late final Stream<List<CategorySummary>> _categories = widget.book.categories
      .watchSummaries(includeInactive: true, includeArchived: true);
  late final Stream<List<AccountSummary>> _accounts = widget.book.accounts
      .watchSummaries();
  final Set<String> _busy = <String>{};

  Future<void> _restore(String key, Future<void> Function() action) async {
    setState(() => _busy.add(key));
    try {
      await action();
      if (mounted) showJibiMessage(context, 'تم الاسترجاع.');
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Widget _section(String title, int count, List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(
          '$title ($count)',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: context.jibiMuted,
          ),
        ),
      ),
      ...children,
    ],
  );

  Widget _categoryTile(CategorySummary summary) {
    final category = summary.category;
    final key = 'category-${category.id}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: BookCard(
        key: Key('archive-$key'),
        child: Row(
          children: [
            JibiIconBubble(
              icon: bookCategoryIcon(category.icon),
              tint: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
              foreground: Theme.of(context).colorScheme.primary,
              size: 44,
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
                  Text(
                    '${summary.accountCount} حساب',
                    style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: Key('archive-restore-$key'),
              onPressed: _busy.contains(key)
                  ? null
                  : () => _restore(
                      key,
                      () => widget.book.categories.setArchived(
                        category.id,
                        archived: false,
                      ),
                    ),
              child: const Text('استرجاع'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _accountTile(
    AccountSummary summary,
    Map<String, CategorySummary> categories,
  ) {
    final account = summary.account;
    final key = 'account-${account.id}';
    final category = categories[account.categoryId]?.category;
    // An account cannot come back under a category that is itself archived.
    final blocked = category?.isArchived ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: BookCard(
        key: Key('archive-$key'),
        onTap: () => openBookAccount(context, widget.book, account.id),
        child: Row(
          children: [
            BookAvatar(name: account.name, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    [
                      ?category?.name,
                      for (final line in summary.currencies)
                        balanceLineText(context, widget.book.currencies, line),
                    ].join('  ·  '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
                  ),
                  if (blocked)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'استرجع التصنيف أولاً.',
                        key: Key('archive-blocked-${account.id}'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: Key('archive-restore-$key'),
              onPressed: blocked || _busy.contains(key)
                  ? null
                  : () => _restore(
                      key,
                      () => widget.book.accounts.setStatus(
                        account.id,
                        BookAccountStatus.active,
                      ),
                    ),
              child: const Text('استرجاع'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الأرشيف')),
    body: StreamBuilder<List<CategorySummary>>(
      stream: _categories,
      builder: (context, categorySnapshot) => StreamBuilder<List<AccountSummary>>(
        stream: _accounts,
        builder: (context, accountSnapshot) {
          final error = categorySnapshot.error ?? accountSnapshot.error;
          if (error != null) {
            return JibiErrorState(message: bookErrorMessage(error));
          }
          final allCategories = categorySnapshot.data;
          final allAccounts = accountSnapshot.data;
          if (allCategories == null || allAccounts == null) {
            return const JibiLoadingState();
          }
          final categoryById = {
            for (final summary in allCategories) summary.category.id: summary,
          };
          final archivedCategories = [
            for (final summary in allCategories)
              if (summary.category.isArchived) summary,
          ];
          final archivedAccounts = [
            for (final summary in allAccounts)
              if (summary.account.status == BookAccountStatus.archived) summary,
          ];
          if (archivedCategories.isEmpty && archivedAccounts.isEmpty) {
            return const JibiEmptyState(
              key: Key('archive-empty'),
              icon: Icons.inventory_2_outlined,
              title: 'الأرشيف فارغ',
              message:
                  'الأرشفة تُخفي التصنيف أو الحساب من الشاشات دون حذف بياناته، '
                  'ويمكنك استرجاعه من هنا في أي وقت.',
            );
          }
          return ListView(
            key: const Key('archive-list'),
            padding: bookPagePadding,
            children: [
              Text(
                'العناصر المؤرشفة لا تظهر في الشاشات لكن عملياتها وتقاريرها '
                'وسجلها محفوظة.',
                style: TextStyle(color: context.jibiMuted, fontSize: 13),
              ),
              if (archivedCategories.isNotEmpty)
                _section('تصنيفات مؤرشفة', archivedCategories.length, [
                  for (final summary in archivedCategories)
                    _categoryTile(summary),
                ]),
              if (archivedAccounts.isNotEmpty)
                _section('حسابات مؤرشفة', archivedAccounts.length, [
                  for (final summary in archivedAccounts)
                    _accountTile(summary, categoryById),
                ]),
            ],
          );
        },
      ),
    ),
  );
}
