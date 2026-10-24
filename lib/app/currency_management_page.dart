import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/errors/app_exception.dart';
import '../core/models/currency.dart';
import '../core/models/currency_palette.dart';
import '../features/currencies/currencies.dart';
import '../shared/widgets/jibi_design.dart';
import '../shared/widgets/jibi_feedback.dart';
import 'book/book_widgets.dart';
import 'jibi_application.dart';

/// Lets the user add, rename, reorder, archive, and delete currencies.
///
/// Archived currencies stay visible in historical records but disappear from
/// pickers for new transactions. A currency in use can never be deleted, and
/// its decimal places can never change once it has been used.
///
/// Laid out like the category management screen: a summary banner, one card
/// per currency, and the add button fixed at the bottom.
class CurrencyManagementPage extends StatefulWidget {
  const CurrencyManagementPage({required this.application, super.key});

  final JibiApplication application;

  @override
  State<CurrencyManagementPage> createState() => _CurrencyManagementPageState();
}

class _CurrencyManagementPageState extends State<CurrencyManagementPage> {
  bool _busy = false;

  // One subscription for the life of the page: a new stream on every rebuild
  // would make the list flash back to its loading state.
  late final Stream<List<Currency>> _stream = _controller.watchCurrencies();

  CurrenciesController get _controller => widget.application.currencies;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('إدارة العملات')),
    body: StreamBuilder<List<Currency>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const JibiErrorState(message: 'تعذر تحميل العملات.');
        }
        if (!snapshot.hasData) {
          return const JibiLoadingState();
        }
        final currencies = [...snapshot.data!]
          ..sort((left, right) => left.sortOrder.compareTo(right.sortOrder));
        final defaultCode = widget.application.settings.defaultCurrencyCode;
        final defaultCurrency = currencies
            .where((currency) => currency.code == defaultCode)
            .firstOrNull;
        return ListView(
          padding: bookPagePadding,
          children: [
            _Banner(
              defaultCurrency: defaultCurrency,
              activeCount: currencies.where((c) => c.isActive).length,
            ),
            const SizedBox(height: 16),
            for (var index = 0; index < currencies.length; index++) ...[
              _CurrencyCard(
                key: ValueKey(currencies[index].code),
                currency: currencies[index],
                isDefault: currencies[index].code == defaultCode,
                busy: _busy,
                canMoveUp: index > 0,
                canMoveDown: index < currencies.length - 1,
                onToggleActive: (value) => _setActive(currencies[index], value),
                onAction: (action) =>
                    _onAction(action, currencies, currencies[index]),
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
          key: const Key('add-currency-button'),
          onPressed: _busy ? null : _openCreateForm,
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('إضافة عملة'),
        ),
      ),
    ),
  );

  void _onAction(
    _CurrencyAction action,
    List<Currency> ordered,
    Currency currency,
  ) {
    switch (action) {
      case _CurrencyAction.edit:
        _openEditForm(currency);
      case _CurrencyAction.makeDefault:
        _setDefault(currency.code);
      case _CurrencyAction.moveUp:
        _move(ordered, currency, -1);
      case _CurrencyAction.moveDown:
        _move(ordered, currency, 1);
      case _CurrencyAction.delete:
        _delete(currency);
    }
  }

  Future<void> _setDefault(String code) async {
    if (code == widget.application.settings.defaultCurrencyCode) {
      return;
    }
    await _run(() async {
      await widget.application.saveSettings(
        widget.application.settings.copyWith(defaultCurrencyCode: code),
      );
    });
  }

  Future<void> _setActive(Currency currency, bool isActive) async {
    await _run(() => _controller.setActive(currency.code, isActive: isActive));
  }

  Future<void> _move(
    List<Currency> ordered,
    Currency currency,
    int delta,
  ) async {
    final codes = [for (final item in ordered) item.code];
    final index = codes.indexOf(currency.code);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= codes.length) return;
    codes
      ..removeAt(index)
      ..insert(target, currency.code);
    await _run(() => _controller.reorder(codes));
  }

  Future<void> _delete(Currency currency) async {
    final confirmed = await JibiConfirmationDialog.show(
      context,
      title: 'حذف العملة',
      message: 'هل تريد حذف عملة ${currency.name} نهائياً؟',
      confirmLabel: 'حذف',
      isDestructive: true,
    );
    if (confirmed != true) {
      return;
    }
    await _run(() => _controller.deleteCurrency(currency.code));
  }

  Future<void> _openCreateForm() async {
    final result = await showDialog<_CurrencyFormResult>(
      context: context,
      builder: (_) => const _CurrencyFormDialog(),
    );
    if (result == null) {
      return;
    }
    await _run(
      () => _controller.createCurrency(
        code: result.code!,
        draft: CurrencyDraft(
          name: result.name,
          symbol: result.symbol,
          fractionDigits: result.fractionDigits,
          colorValue: result.colorValue,
        ),
      ),
    );
  }

  Future<void> _openEditForm(Currency currency) async {
    final result = await showDialog<_CurrencyFormResult>(
      context: context,
      builder: (_) => _CurrencyFormDialog(existing: currency),
    );
    if (result == null) {
      return;
    }
    await _run(
      () => _controller.updateCurrency(
        currency.code,
        CurrencyDraft(
          name: result.name,
          symbol: result.symbol,
          fractionDigits: result.fractionDigits,
          colorValue: result.colorValue,
        ),
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AppException catch (error) {
      if (mounted) showJibiMessage(context, error.userMessage);
    } on Object {
      if (mounted) {
        showJibiMessage(context, 'تعذر إتمام العملية. حاول مرة أخرى.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

enum _CurrencyAction { edit, makeDefault, moveUp, moveDown, delete }

class _Banner extends StatelessWidget {
  const _Banner({required this.defaultCurrency, required this.activeCount});

  final Currency? defaultCurrency;
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
            const Icon(
              Icons.payments_outlined,
              color: JibiColors.gold,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                defaultCurrency == null
                    ? 'العملات'
                    : 'العملة الأساسية: ${defaultCurrency!.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: JibiColors.gold,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            JibiBadge(
              '$activeCount مفعلة',
              background: Colors.white.withValues(alpha: 0.16),
              foreground: Colors.white,
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'كل حساب بعملة واحدة، والأرصدة لا تُجمع بين عملتين. العملة المستعملة '
          'في عمليات محفوظة لا تُحذف ولا تتغير منازلها العشرية.',
          style: TextStyle(color: Colors.white, fontSize: 12.5, height: 1.5),
        ),
      ],
    ),
  );
}

class _CurrencyCard extends StatelessWidget {
  const _CurrencyCard({
    required this.currency,
    required this.isDefault,
    required this.busy,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onToggleActive,
    required this.onAction,
    super.key,
  });

  final Currency currency;
  final bool isDefault;
  final bool busy;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool> onToggleActive;
  final ValueChanged<_CurrencyAction> onAction;

  @override
  Widget build(BuildContext context) {
    final primary = Color(
      currency.colorValue ?? automaticCurrencyColor(currency.code),
    );
    final symbol = currency.symbol?.trim();
    return BookCard(
      key: Key('currency-card-${currency.code}'),
      dimmed: !currency.isActive,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(15),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                symbol == null || symbol.isEmpty ? currency.code : symbol,
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currency.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    JibiBadge(
                      currency.code,
                      background: JibiColors.gold.withValues(alpha: 0.25),
                      foreground: JibiColors.onTintInk,
                    ),
                    Text(
                      currency.fractionDigits == 0
                          ? 'بلا منازل عشرية'
                          : '${currency.fractionDigits} منازل عشرية',
                      style: TextStyle(
                        color: context.jibiMuted,
                        fontSize: 12.5,
                      ),
                    ),
                    if (isDefault)
                      JibiBadge(
                        'الأساسية',
                        icon: Icons.star,
                        background: primary.withValues(alpha: 0.12),
                        foreground: primary,
                      ),
                    if (!currency.isActive)
                      JibiBadge(
                        'معطّلة',
                        background: context.jibiMuted.withValues(alpha: 0.16),
                        foreground: context.jibiMuted,
                      ),
                  ],
                ),
              ],
            ),
          ),
          Semantics(
            label: 'تفعيل ${currency.name}',
            child: Switch(
              key: Key('currency-switch-${currency.code}'),
              value: currency.isActive,
              onChanged: busy ? null : onToggleActive,
            ),
          ),
          PopupMenuButton<_CurrencyAction>(
            key: Key('currency-menu-${currency.code}'),
            tooltip: 'خيارات العملة',
            enabled: !busy,
            onSelected: onAction,
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: _CurrencyAction.edit,
                child: Text('تعديل'),
              ),
              if (!isDefault && currency.isActive)
                const PopupMenuItem(
                  value: _CurrencyAction.makeDefault,
                  child: Text('جعلها العملة الأساسية'),
                ),
              PopupMenuItem(
                value: _CurrencyAction.moveUp,
                enabled: canMoveUp,
                child: const Text('نقل للأعلى'),
              ),
              PopupMenuItem(
                value: _CurrencyAction.moveDown,
                enabled: canMoveDown,
                child: const Text('نقل للأسفل'),
              ),
              if (!isDefault)
                const PopupMenuItem(
                  value: _CurrencyAction.delete,
                  child: Text('حذف'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CurrencyFormResult {
  const _CurrencyFormResult({
    this.code,
    required this.name,
    this.symbol,
    required this.fractionDigits,
    this.colorValue,
  });

  final String? code;
  final String name;
  final String? symbol;
  final int fractionDigits;

  /// The picked accent (ARGB); null means "automatic".
  final int? colorValue;
}

class _CurrencyFormDialog extends StatefulWidget {
  const _CurrencyFormDialog({this.existing});

  final Currency? existing;

  @override
  State<_CurrencyFormDialog> createState() => _CurrencyFormDialogState();
}

class _CurrencyFormDialogState extends State<_CurrencyFormDialog> {
  late final _code = TextEditingController(text: widget.existing?.code ?? '');
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _symbol = TextEditingController(
    text: widget.existing?.symbol ?? '',
  );
  late int _fractionDigits = widget.existing?.fractionDigits ?? 0;
  late int? _color = widget.existing?.colorValue;
  String? _error;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _symbol.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_isNew ? 'إضافة عملة' : 'تعديل عملة'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isNew) ...[
            TextField(
              key: const Key('currency-code-field'),
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              textDirection: TextDirection.ltr,
              textInputAction: TextInputAction.next,
              maxLength: 3,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')),
              ],
              decoration: const InputDecoration(
                labelText: 'رمز العملة *',
                hintText: 'مثال: SAR',
                helperText: 'ثلاثة أحرف إنجليزية، ولا يتغير بعد الإضافة.',
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            key: const Key('currency-name-field'),
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'اسم العملة *',
              hintText: 'مثال: ريال سعودي',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('currency-symbol-field'),
            controller: _symbol,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'رمز العرض',
              hintText: 'مثال: ر.س',
              helperText: 'اختياري: رمز مختصر للعملة.',
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'عدد المنازل العشرية',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            key: const Key('currency-digits-field'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('0')),
              ButtonSegment(value: 1, label: Text('1')),
              ButtonSegment(value: 2, label: Text('2')),
              ButtonSegment(value: 3, label: Text('3')),
            ],
            selected: {_fractionDigits},
            onSelectionChanged: (value) =>
                setState(() => _fractionDigits = value.first),
          ),
          const SizedBox(height: 6),
          Text(
            'لا يمكن تغييرها بعد استعمال العملة في عمليات محفوظة.',
            style: TextStyle(color: context.jibiMuted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Text(
            'لون العملة',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _ColorDot(
                key: const Key('currency-color-auto'),
                color: null,
                label: 'تلقائي',
                selected: _color == null,
                onTap: () => setState(() => _color = null),
              ),
              for (final value in currencyPalette)
                _ColorDot(
                  key: Key('currency-color-${value.toRadixString(16).toUpperCase()}'),
                  color: Color(value),
                  label: 'لون',
                  selected: _color == value,
                  onTap: () => setState(() => _color = value),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'يظهر في بطاقة صافي المركز المالي.',
            style: TextStyle(color: context.jibiMuted, fontSize: 12),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        key: const Key('currency-save-button'),
        onPressed: _submit,
        child: const Text('حفظ'),
      ),
    ],
  );

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'أدخل اسم العملة.');
      return;
    }
    String? code;
    if (_isNew) {
      code = _code.text.trim().toUpperCase();
      if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
        setState(
          () => _error = 'رمز العملة يجب أن يتكون من ثلاثة أحرف إنجليزية.',
        );
        return;
      }
    }
    final symbol = _symbol.text.trim();
    Navigator.pop(
      context,
      _CurrencyFormResult(
        code: code,
        name: name,
        symbol: symbol.isEmpty ? null : symbol,
        fractionDigits: _fractionDigits,
        colorValue: _color,
      ),
    );
  }
}

/// One choice in the currency color row: a filled circle (or a dashed one for
/// "automatic") with a check mark on the selected one.
class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final Color? color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color ?? scheme.surfaceContainerHighest,
            border: Border.all(
              color: selected ? scheme.onSurface : scheme.outlineVariant,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: selected
              ? Icon(
                  Icons.check,
                  size: 18,
                  color: color == null ? scheme.onSurface : Colors.white,
                )
              : color == null
              ? Icon(Icons.auto_awesome, size: 16, color: scheme.onSurfaceVariant)
              : null,
        ),
      ),
    );
  }
}
