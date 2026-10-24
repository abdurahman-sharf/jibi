import 'package:flutter/material.dart';

import '../../../core/models/models.dart';
import '../../../features/book/book.dart';
import '../../../shared/widgets/jibi_design.dart';
import '../../../shared/widgets/jibi_feedback.dart';
import '../book_widgets.dart';
import 'book_report_launcher.dart';

enum _HubView { categories, accounts }

/// The "التقارير" tab: pick a category or an account, then the report.
class BookReportsHubPage extends StatefulWidget {
  const BookReportsHubPage({required this.book, super.key});

  final BookServices book;

  @override
  State<BookReportsHubPage> createState() => _BookReportsHubPageState();
}

class _BookReportsHubPageState extends State<BookReportsHubPage> {
  late final Stream<List<CategorySummary>> _categories = widget.book.categories
      .watchSummaries();
  late final Stream<List<AccountSummary>> _accounts = widget.book.accounts
      .watchSearch('');
  final TextEditingController _query = TextEditingController();
  _HubView _view = _HubView.categories;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<CategorySummary>>(
    stream: _categories,
    builder: (context, categorySnapshot) {
      if (categorySnapshot.hasError) {
        return JibiErrorState(
          message: bookErrorMessage(categorySnapshot.error!),
        );
      }
      final categories = categorySnapshot.data;
      if (categories == null) return const JibiLoadingState();
      if (categories.isEmpty) {
        return const JibiEmptyState(
          icon: Icons.bar_chart_outlined,
          title: 'لا توجد تقارير بعد',
          message: 'أنشئ تصنيفاً وأضف إليه حسابات وعمليات لتظهر تقاريرها هنا.',
        );
      }
      return ListView(
        key: const Key('reports-hub'),
        padding: bookPagePadding,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'التقارير',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'اختر تصنيفاً أو حساباً ثم التقرير، وشاركه PDF أو Excel أو عبر واتساب.',
              style: TextStyle(color: context.jibiMuted),
            ),
          ),
          SegmentedButton<_HubView>(
            key: const Key('reports-hub-view'),
            segments: const [
              ButtonSegment(
                value: _HubView.categories,
                icon: Icon(Icons.folder_outlined),
                label: Text('التصنيفات'),
              ),
              ButtonSegment(
                value: _HubView.accounts,
                icon: Icon(Icons.person_outline),
                label: Text('الحسابات'),
              ),
            ],
            selected: {_view},
            onSelectionChanged: (selection) =>
                setState(() => _view = selection.single),
          ),
          const SizedBox(height: 12),
          if (_view == _HubView.categories)
            ..._categoryTiles(context, categories)
          else
            ..._accountTiles(context, categories),
        ],
      );
    },
  );

  List<Widget> _categoryTiles(
    BuildContext context,
    List<CategorySummary> categories,
  ) => [
    for (final summary in categories)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: BookCard(
          key: Key('report-category-${summary.category.id}'),
          onTap: () =>
              showCategoryReports(context, widget.book, summary.category),
          child: Row(
            children: [
              JibiIconBubble(
                icon: bookCategoryIcon(summary.category.icon),
                tint: Theme.of(context).colorScheme.primary.withValues(
                  alpha: 0.12,
                ),
                foreground: Theme.of(context).colorScheme.primary,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.category.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${summary.accountCount} حساب',
                      style: TextStyle(color: context.jibiMuted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left),
            ],
          ),
        ),
      ),
  ];

  List<Widget> _accountTiles(
    BuildContext context,
    List<CategorySummary> categories,
  ) {
    final names = {
      for (final summary in categories) summary.category.id: summary.category.name,
    };
    return [
      TextField(
        key: const Key('reports-hub-search'),
        controller: _query,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          hintText: 'ابحث عن حساب',
          prefixIcon: Icon(Icons.search),
        ),
      ),
      const SizedBox(height: 12),
      StreamBuilder<List<AccountSummary>>(
        stream: _accounts,
        builder: (context, snapshot) {
          final all = snapshot.data;
          if (all == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final query = _query.text.trim().toLowerCase();
          final shown = [
            for (final summary in all)
              if (query.isEmpty ||
                  summary.account.name.toLowerCase().contains(query) ||
                  (names[summary.account.categoryId] ?? '')
                      .toLowerCase()
                      .contains(query))
                summary,
          ];
          if (shown.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  query.isEmpty ? 'لا توجد حسابات.' : 'لا توجد نتائج.',
                  style: TextStyle(color: context.jibiMuted),
                ),
              ),
            );
          }
          return Column(
            children: [
              for (final summary in shown)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: BookCard(
                    key: Key('report-account-${summary.account.id}'),
                    onTap: () => showAccountReports(
                      context,
                      widget.book,
                      summary.account,
                    ),
                    child: Row(
                      children: [
                        BookAvatar(name: summary.account.name, size: 40),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                summary.account.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                [
                                  names[summary.account.categoryId] ?? '',
                                  if (summary.currencies.isNotEmpty)
                                    summary.currencyCodes.join(' · '),
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: context.jibiMuted),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_left),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }
}
