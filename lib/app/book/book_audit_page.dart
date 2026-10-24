import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import 'book_category_page.dart' show openBookAccount;
import 'book_widgets.dart';

/// "سجل التعديلات" (المتطلب 68): every sensitive change of the book, newest
/// first, in words ("تم تعديل مبلغ العملية TX-000001 من 30,000 إلى 20,000").
/// With [accountId] it shows only that account and its transactions.
class BookAuditLogPage extends StatefulWidget {
  const BookAuditLogPage({required this.book, this.accountId, super.key});

  final BookServices book;
  final String? accountId;

  @override
  State<BookAuditLogPage> createState() => _BookAuditLogPageState();
}

class _BookAuditLogPageState extends State<BookAuditLogPage> {
  late final BookAuditListController _list = BookAuditListController(
    repository: widget.book.repository,
    accountId: widget.accountId,
  );
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.extentAfter < 400) {
        _list.loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _list.dispose();
    super.dispose();
  }

  static IconData _icon(BookAuditKind kind) => switch (kind) {
    BookAuditKind.created => Icons.add_circle_outline,
    BookAuditKind.edited => Icons.edit_outlined,
    BookAuditKind.deleted => Icons.delete_outline,
    BookAuditKind.restored => Icons.restore,
    BookAuditKind.attachment => Icons.attach_file,
    BookAuditKind.status => Icons.toggle_on_outlined,
  };

  static String _time(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    final local = value.toLocal();
    return '${two(local.hour)}:${two(local.minute)}';
  }

  /// "اليوم", "أمس", or the date the way the user chose to read dates.
  String _dayLabel(DateTime day, BookPreferences prefs) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(day.year, day.month, day.day);
    final gap = today.difference(that).inDays;
    if (gap == 0) return 'اليوم';
    if (gap == 1) return 'أمس';
    return prefs.date(BookTransaction.formatDate(that));
  }

  Widget _filters(BookAuditListState state) {
    final filters = <(String, BookAuditEntity?)>[
      ('الكل', null),
      ('العمليات', BookAuditEntity.transaction),
      ('الحسابات', BookAuditEntity.account),
      if (widget.accountId == null) ('التصنيفات', BookAuditEntity.category),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          for (final (label, entity) in filters) ...[
            ChoiceChip(
              key: Key('audit-filter-${entity?.dbValue ?? 'all'}'),
              label: Text(label),
              selected: state.entity == entity,
              onSelected: (_) => _list.setEntity(entity),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _entry(BookAuditEntry entry, BookAuditText text) {
    final description = text.describe(entry);
    final scope = entry.entity == BookAuditEntity.category
        ? entry.categoryName
        : entry.accountName;
    final canOpen =
        widget.accountId == null &&
        entry.accountId != null &&
        entry.entity != BookAuditEntity.category;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: BookCard(
        key: Key('audit-entry-${entry.id}'),
        onTap: canOpen
            ? () => openBookAccount(context, widget.book, entry.accountId!)
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            JibiIconBubble(
              icon: _icon(description.kind),
              tint: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
              foreground: Theme.of(context).colorScheme.primary,
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    description.title,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (description.detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      description.detail!,
                      style: TextStyle(fontSize: 13, color: context.jibiMuted),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    [
                      ?scope,
                      _time(entry.createdAt),
                    ].join('  ·  '),
                    style: TextStyle(fontSize: 11.5, color: context.jibiMuted),
                  ),
                ],
              ),
            ),
            if (canOpen)
              Icon(Icons.chevron_left, color: context.jibiMuted, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _body(BookAuditListState state) {
    if (state.error != null && state.items.isEmpty) {
      return JibiErrorState(message: bookErrorMessage(state.error!));
    }
    if (state.loading && state.items.isEmpty) {
      return const JibiLoadingState();
    }
    if (state.items.isEmpty) {
      return const JibiEmptyState(
        key: Key('audit-empty'),
        icon: Icons.history,
        title: 'لا توجد تعديلات مسجلة',
        message: 'تظهر هنا إضافة العمليات وتعديلها وحذفها وتغييرات الحسابات.',
      );
    }
    final prefs = context.bookPrefs;
    final text = BookAuditText(
      preferences: prefs,
      currencies: widget.book.currencies,
    );
    final rows = <Object>[];
    DateTime? lastDay;
    for (final entry in state.items) {
      final local = entry.createdAt.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (lastDay != day) {
        rows.add(day);
        lastDay = day;
      }
      rows.add(entry);
    }
    return ListView.builder(
      key: const Key('audit-list'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: rows.length + (state.loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= rows.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final row = rows[index];
        if (row is DateTime) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
            child: Text(
              _dayLabel(row, prefs),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: context.jibiMuted,
              ),
            ),
          );
        }
        return _entry(row as BookAuditEntry, text);
      },
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.accountId == null ? 'سجل التعديلات' : 'سجل الحساب'),
    ),
    body: ValueListenableBuilder<BookAuditListState>(
      valueListenable: _list,
      builder: (context, state, _) => Column(
        children: [
          _filters(state),
          Expanded(child: _body(state)),
        ],
      ),
    ),
  );
}
