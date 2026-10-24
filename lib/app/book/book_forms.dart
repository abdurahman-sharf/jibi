import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../shared/formatting/money_format.dart';
import '../../shared/widgets/jibi_design.dart';
import '../jibi_app_shell.dart';
import 'book_widgets.dart';

/// Opens the category form full screen. Returns true after a save.
Future<bool?> openCategoryForm(
  BuildContext context,
  BookServices book, {
  BookCategory? category,
}) => pushFormPage<bool>(
  context,
  BookCategoryFormPage(book: book, category: category),
);

/// Opens the account form full screen. Returns true after a save.
Future<bool?> openAccountForm(
  BuildContext context,
  BookServices book, {
  String? categoryId,
  BookAccount? account,
}) => pushFormPage<bool>(
  context,
  BookAccountFormPage(book: book, categoryId: categoryId, account: account),
);

class BookCategoryFormPage extends StatefulWidget {
  const BookCategoryFormPage({required this.book, super.key, this.category});

  final BookServices book;
  final BookCategory? category;

  @override
  State<BookCategoryFormPage> createState() => _BookCategoryFormPageState();
}

class _BookCategoryFormPageState extends State<BookCategoryFormPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.category?.name ?? '',
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.category?.description ?? '',
  );
  late String _icon = widget.category?.icon ?? 'folder';
  late bool _active = widget.category?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final draft = BookCategoryDraft(
        name: _name.text,
        icon: _icon,
        description: _description.text,
      );
      final existing = widget.category;
      if (existing == null) {
        final created = await widget.book.categories.create(draft);
        if (!_active) {
          await widget.book.categories.setActive(created.id, isActive: false);
        }
      } else {
        await widget.book.categories.update(existing.id, draft);
        if (_active != existing.isActive) {
          await widget.book.categories.setActive(
            existing.id,
            isActive: _active,
          );
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.category != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'تعديل التصنيف' : 'إضافة تصنيف جديد')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            key: const Key('category-name'),
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'اسم التصنيف'),
          ),
          const SizedBox(height: 20),
          Text(
            'الأيقونة',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final entry in bookCategoryIcons.entries)
                Semantics(
                  button: true,
                  selected: _icon == entry.key,
                  label: entry.key,
                  child: InkWell(
                    key: Key('icon-${entry.key}'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _icon = entry.key),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: _icon == entry.key
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.primary
                                  .withValues(alpha: 0.10),
                      ),
                      child: Icon(
                        entry.value,
                        color: _icon == entry.key
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('category-description'),
            controller: _description,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'وصف (اختياري)'),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const Key('category-active'),
            contentPadding: EdgeInsets.zero,
            title: const Text('مفعّل'),
            subtitle: const Text(
              'التصنيف الموقوف يختفي من شاشة الحسابات ومن اختيار التصنيف، '
              'وتبقى بياناته محفوظة.',
            ),
            value: _active,
            onChanged: _saving ? null : (value) => setState(() => _active = value),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('save-button'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
  }
}

class BookAccountFormPage extends StatefulWidget {
  const BookAccountFormPage({
    required this.book,
    super.key,
    this.account,
    this.categoryId,
  });

  final BookServices book;
  final BookAccount? account;

  /// The category preselected for a new account.
  final String? categoryId;

  @override
  State<BookAccountFormPage> createState() => _BookAccountFormPageState();
}

/// One opening balance being edited: a currency, its side and its amount.
class _OpeningRow {
  _OpeningRow({required this.currency, required this.type, String amount = ''})
    : amount = TextEditingController(text: amount);

  String currency;
  OpeningType type;
  final TextEditingController amount;
}

class _BookAccountFormPageState extends State<BookAccountFormPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.account?.name ?? '',
  );
  late final TextEditingController _phone = TextEditingController(
    text: widget.account?.phone ?? '',
  );
  late final TextEditingController _notes = TextEditingController(
    text: widget.account?.notes ?? '',
  );

  /// The opening balances, one row per currency. An account has no currency of
  /// its own: any active currency can be used later without another account, so
  /// a new account starts with no rows at all.
  final List<_OpeningRow> _openings = [];
  List<BookCategory> _categories = const [];
  bool _loaded = false;
  String? _categoryId;
  late BookAccountStatus _status =
      widget.account?.status ?? BookAccountStatus.active;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _categoryId = widget.account?.categoryId ?? widget.categoryId;
    _load();
  }

  Future<void> _load() async {
    final summaries = await widget.book.categories.summaries(
      includeInactive: true,
    );
    final account = widget.account;
    final rows = <_OpeningRow>[];
    if (account != null) {
      for (final balance in await widget.book.accounts.balances(account.id)) {
        if (balance.openingMinor == 0) continue;
        rows.add(
          _OpeningRow(
            currency: balance.currencyCode,
            type: balance.openingType,
            amount: bookAmount(
              widget.book.currencies,
              balance.currencyCode,
              balance.openingMinor,
            ),
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _categories = [
        for (final summary in summaries)
          if (summary.category.isActive ||
              summary.category.id == widget.account?.categoryId)
            summary.category,
      ];
      _categoryId ??= _categories.isEmpty ? null : _categories.first.id;
      _openings.addAll(rows);
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _notes.dispose();
    for (final row in _openings) {
      row.amount.dispose();
    }
    super.dispose();
  }

  int _digits(String currency) =>
      widget.book.currencies.byCode(currency).fractionDigits;

  /// The currencies a row may still pick: active ones no other row uses, plus
  /// its own (even if it has since been switched off).
  List<Currency> _choices(_OpeningRow row) => [
    for (final currency in widget.book.currencies.currencies)
      if (currency.code == row.currency ||
          (currency.isActive &&
              !_openings.any((other) => other.currency == currency.code)))
        currency,
  ];

  /// The user's base currency first, then whatever else is active and unused.
  String? _nextFreeCurrency() {
    final free = [
      for (final currency in widget.book.currencies.activeCurrencies)
        if (!_openings.any((row) => row.currency == currency.code))
          currency.code,
    ];
    if (free.isEmpty) return null;
    final preferred = widget.book.defaultCurrencyCode();
    return free.contains(preferred) ? preferred : free.first;
  }

  void _addOpening() {
    final code = _nextFreeCurrency();
    if (code == null) return;
    setState(() => _openings.add(_OpeningRow(currency: code, type: OpeningType.debit)));
  }

  void _changeCurrency(_OpeningRow row, String code) {
    setState(() => row.currency = code);
    // Re-apply the new decimal rule to what was already typed.
    row.amount.value = ThousandsInputFormatter(
      fractionDigits: _digits(code),
    ).formatEditUpdate(
      row.amount.value,
      TextEditingValue(text: reshapeAmountText(row.amount.text, _digits(code))),
    );
  }

  void _removeOpening(_OpeningRow row) {
    setState(() => _openings.remove(row));
    row.amount.dispose();
  }

  Future<void> _save() async {
    final categoryId = _categoryId;
    if (categoryId == null) {
      showBookError(context, const ValidationException(
        code: 'category_required',
        userMessage: 'اختر التصنيف أولاً.',
      ));
      return;
    }
    setState(() => _saving = true);
    try {
      final openings = <BookAccountOpeningDraft>[];
      for (final row in _openings) {
        final typed = canonicalAmountInput(row.amount.text);
        // A row with no amount is simply no opening balance in that currency.
        if (typed.isEmpty || typed == '.') continue;
        openings.add(
          BookAccountOpeningDraft(
            currencyCode: row.currency,
            openingMinor: widget.book.currencies
                .parseAmount(input: typed, currencyCode: row.currency)
                .amountMinor,
            openingType: row.type,
          ),
        );
      }
      final draft = BookAccountDraft(
        categoryId: categoryId,
        name: _name.text,
        openings: openings,
        notes: _notes.text,
        phone: _phone.text,
      );
      final existing = widget.account;
      if (existing == null) {
        await widget.book.accounts.create(draft);
      } else {
        await widget.book.accounts.update(existing.id, draft);
        if (_status != existing.status) {
          await widget.book.accounts.setStatus(existing.id, _status);
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _statusLabel(BookAccountStatus status) => switch (status) {
    BookAccountStatus.active => 'نشط',
    BookAccountStatus.suspended => 'متوقف',
    BookAccountStatus.archived => 'مؤرشف',
  };

  Widget _openingRow(BuildContext context, int index, _OpeningRow row) {
    final labels = context.bookPrefs.labels;
    return Container(
      key: Key('opening-row-$index'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
          alpha: context.jibiIsDark ? 0.5 : 0.55,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: Key('opening-currency-$index'),
                  isExpanded: true,
                  initialValue: row.currency,
                  decoration: const InputDecoration(labelText: 'العملة'),
                  items: [
                    for (final currency in _choices(row))
                      DropdownMenuItem(
                        value: currency.code,
                        child: Text(
                          '${currency.name} (${currency.code})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value != null) _changeCurrency(row, value);
                        },
                ),
              ),
              IconButton(
                key: Key('opening-remove-$index'),
                tooltip: 'إزالة الرصيد الافتتاحي',
                icon: const Icon(Icons.close),
                onPressed: _saving ? null : () => _removeOpening(row),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SegmentedButton<OpeningType>(
            key: Key('opening-type-$index'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: OpeningType.debit,
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(labels.debit),
                ),
              ),
              ButtonSegment(
                value: OpeningType.credit,
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(labels.credit),
                ),
              ),
            ],
            selected: {row.type},
            onSelectionChanged: _saving
                ? null
                : (selection) => setState(() => row.type = selection.single),
          ),
          const SizedBox(height: 10),
          TextField(
            key: Key('opening-amount-$index'),
            controller: row.amount,
            textDirection: TextDirection.ltr,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              ThousandsInputFormatter(fractionDigits: _digits(row.currency)),
            ],
            decoration: InputDecoration(
              labelText: 'المبلغ',
              suffixText: row.currency,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.account != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'تعديل الحساب' : 'إضافة حساب جديد')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                TextField(
                  key: const Key('account-name'),
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'اسم الحساب'),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('account-phone'),
                  controller: _phone,
                  textInputAction: TextInputAction.next,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'رقم الجوال (اختياري)',
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: const Key('account-category'),
                  isExpanded: true,
                  initialValue: _categoryId,
                  decoration: const InputDecoration(labelText: 'التصنيف'),
                  items: [
                    for (final category in _categories)
                      DropdownMenuItem(
                        value: category.id,
                        child: Text(category.name),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _categoryId = value),
                ),
                const SizedBox(height: 20),
                Text(
                  'الأرصدة الافتتاحية (اختياري)',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'الحساب هو الشخص أو الجهة، وله رصيد مستقل لكل عملة تُسجَّل له. '
                  'لا حاجة لاختيار عملة الآن: كل عملية تحدّد عملتها. أضف رصيدًا '
                  'افتتاحيًا فقط إن كان له رصيد سابق بعملة معيّنة.',
                  key: const Key('account-openings-hint'),
                  style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                for (var index = 0; index < _openings.length; index++)
                  _openingRow(context, index, _openings[index]),
                OutlinedButton.icon(
                  key: const Key('add-opening'),
                  onPressed: _saving || _nextFreeCurrency() == null
                      ? null
                      : _addOpening,
                  icon: const Icon(Icons.add),
                  label: Text(
                    _openings.isEmpty
                        ? 'إضافة رصيد افتتاحي'
                        : 'إضافة رصيد بعملة أخرى',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('account-notes'),
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'ملاحظات (اختياري)'),
                ),
                if (editing) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<BookAccountStatus>(
                    key: const Key('account-status'),
                    isExpanded: true,
                    initialValue: _status,
                    decoration: const InputDecoration(labelText: 'حالة الحساب'),
                    items: [
                      for (final status in BookAccountStatus.values)
                        DropdownMenuItem(
                          value: status,
                          child: Text(_statusLabel(status)),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value != null) setState(() => _status = value);
                          },
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('save-button'),
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('إلغاء'),
                ),
              ],
            ),
    );
  }
}
