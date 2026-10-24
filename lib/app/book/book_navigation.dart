import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../shared/widgets/jibi_design.dart';
import '../../shared/widgets/jibi_feedback.dart';
import '../jibi_app_shell.dart';
import 'book_forms.dart';
import 'book_transaction_form.dart';
import 'book_widgets.dart';

/// Lets the user choose one of the accounts that can take a new transaction.
/// Returns null when cancelled or when there is none.
Future<BookAccount?> pickBookAccount(
  BuildContext context,
  BookServices book,
) async {
  final categories = await book.categories.summaries();
  final accounts = await book.accounts.summaries(
    includeArchived: false,
    activeCategoriesOnly: true,
  );
  final names = {
    for (final summary in categories) summary.category.id: summary.category.name,
  };
  final eligible = [
    for (final summary in accounts)
      if (summary.account.acceptsTransactions &&
          names.containsKey(summary.account.categoryId))
        summary,
  ];
  if (!context.mounted) return null;
  if (eligible.isEmpty) {
    showJibiMessage(
      context,
      'لا توجد حسابات نشطة. أضف حساباً أولاً من شاشة الحسابات.',
    );
    return null;
  }
  return showModalBottomSheet<BookAccount>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useRootNavigator: true,
    useSafeArea: true,
    builder: (_) => _AccountPickerSheet(
      book: book,
      accounts: eligible,
      categoryNames: names,
    ),
  );
}

class _AccountPickerSheet extends StatefulWidget {
  const _AccountPickerSheet({
    required this.book,
    required this.accounts,
    required this.categoryNames,
  });

  final BookServices book;
  final List<AccountSummary> accounts;
  final Map<String, String> categoryNames;

  @override
  State<_AccountPickerSheet> createState() => _AccountPickerSheetState();
}

class _AccountPickerSheetState extends State<_AccountPickerSheet> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final shown = [
      for (final summary in widget.accounts)
        if (query.isEmpty ||
            summary.account.name.toLowerCase().contains(query) ||
            (widget.categoryNames[summary.account.categoryId] ?? '')
                .toLowerCase()
                .contains(query))
          summary,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                'اختر الحساب',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TextField(
              key: const Key('picker-search'),
              controller: _query,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'ابحث عن حساب',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              children: [
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        'لا توجد نتائج.',
                        style: TextStyle(color: context.jibiMuted),
                      ),
                    ),
                  ),
                for (final summary in shown)
                  ListTile(
                    key: Key('pick-${summary.account.id}'),
                    leading: BookAvatar(name: summary.account.name, size: 40),
                    title: Text(
                      summary.account.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      [
                        widget.categoryNames[summary.account.categoryId] ?? '',
                        if (summary.currencies.isNotEmpty)
                          summary.currencyCodes.join(' · '),
                      ].join(' · '),
                    ),
                    onTap: () => Navigator.of(context).pop(summary.account),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The quick-add "+" actions of the accounts layout.
List<JibiQuickAction> bookQuickActions({
  required BookServices book,
  required BuildContext Function() context,
}) => [
  JibiQuickAction(
    label: 'عملية جديدة',
    description: 'اختر الحساب ثم سجّل مدين أو دائن',
    icon: Icons.receipt_long_outlined,
    onPressed: () async {
      final ctx = context();
      final account = await pickBookAccount(ctx, book);
      if (account != null && ctx.mounted) {
        await openTransactionForm(ctx, book, account: account);
      }
    },
  ),
  JibiQuickAction(
    label: 'حساب جديد',
    description: 'داخل أحد التصنيفات',
    icon: Icons.person_add_alt_1_outlined,
    onPressed: () async {
      final ctx = context();
      final categories = await book.categories.summaries();
      if (!ctx.mounted) return;
      if (categories.isEmpty) {
        showJibiMessage(ctx, 'أنشئ تصنيفاً أولاً ثم أضف إليه حساباً.');
        await openCategoryForm(ctx, book);
        return;
      }
      await openAccountForm(ctx, book);
    },
  ),
  JibiQuickAction(
    label: 'تصنيف جديد',
    description: 'مثل: حسابات اليمن',
    icon: Icons.create_new_folder_outlined,
    onPressed: () => openCategoryForm(context(), book),
  ),
];
