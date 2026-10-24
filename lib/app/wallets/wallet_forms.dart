import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../core/storage/document_source_picker.dart';
import '../../core/storage/profile_image_shrinker.dart';
import '../../features/book/book.dart';
import '../../features/wallets/wallets.dart';
import '../../shared/formatting/money_format.dart';
import '../../shared/widgets/external_activity_scope.dart';
import '../jibi_app_shell.dart';
import 'wallet_widgets.dart';

const int walletImageMaxSide = 512;

/// Opens the wallet form full screen. Pass [wallet] to edit it. Returns true
/// after a save.
Future<bool?> openWalletForm(
  BuildContext context,
  BookServices book, {
  Wallet? wallet,
  DocumentSourcePicker picker = const AndroidDocumentSourcePicker(),
}) => pushFormPage<bool>(
  context,
  WalletFormPage(book: book, wallet: wallet, picker: picker),
);

class WalletFormPage extends StatefulWidget {
  const WalletFormPage({
    required this.book,
    super.key,
    this.wallet,
    this.picker = const AndroidDocumentSourcePicker(),
  });

  final BookServices book;
  final Wallet? wallet;
  final DocumentSourcePicker picker;

  @override
  State<WalletFormPage> createState() => _WalletFormPageState();
}

/// One row of the "الأرصدة الافتتاحية" section: a currency and its opening
/// amount. [locked] once that currency has any movement — its currency
/// cannot change and it cannot be removed, but the amount stays editable.
final class _OpeningRow {
  _OpeningRow({required this.currencyCode, String openingText = '', this.locked = false})
    : amount = TextEditingController(text: openingText);

  String currencyCode;
  final TextEditingController amount;
  bool locked;

  void dispose() => amount.dispose();
}

class _WalletFormPageState extends State<WalletFormPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.wallet?.name ?? '',
  );
  late final TextEditingController _accountNumber = TextEditingController(
    text: widget.wallet?.accountNumber ?? '',
  );
  late final TextEditingController _notes = TextEditingController(
    text: widget.wallet?.notes ?? '',
  );
  final List<_OpeningRow> _openings = [];
  Uint8List? _image;
  bool _loaded = false;
  bool _saving = false;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _image = widget.wallet?.image;
    _load();
  }

  /// The user's base currency first, then whatever is active.
  String _preferredCurrency() {
    final active = widget.book.currencies.activeCurrencies;
    final preferred = widget.book.defaultCurrencyCode();
    return active.any((currency) => currency.code == preferred)
        ? preferred
        : active.first.code;
  }

  Future<void> _load() async {
    final wallet = widget.wallet;
    if (wallet == null) {
      _openings.add(_OpeningRow(currencyCode: _preferredCurrency()));
    } else {
      final summary = await widget.book.wallets.summary(wallet.id);
      for (final balance in summary?.balances ?? const <WalletCurrencyBalance>[]) {
        _openings.add(
          _OpeningRow(
            currencyCode: balance.currencyCode,
            openingText: balance.openingMinor == 0
                ? ''
                : bookAmount(widget.book.currencies, balance.currencyCode, balance.openingMinor),
            locked: balance.transactionCount > 0,
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _name.dispose();
    _accountNumber.dispose();
    _notes.dispose();
    for (final row in _openings) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('wallet-image-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('التقاط صورة بالكاميرا'),
              onTap: () => Navigator.of(sheetContext).pop('camera'),
            ),
            ListTile(
              key: const Key('wallet-image-files'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('من المعرض أو الملفات'),
              onTap: () => Navigator.of(sheetContext).pop('files'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;
    setState(() => _picking = true);
    final runExternal = ExternalActivityScope.of(context);
    try {
      final request = await runExternal(
        () => source == 'camera'
            ? widget.picker.captureImage()
            : widget.picker.pickFile(),
      );
      if (request == null) return;
      Uint8List bytes;
      try {
        bytes = await request.sourceFile.readAsBytes();
      } finally {
        try {
          await request.sourceFile.delete();
        } on Object {
          // A leftover cache file is cleaned by the system.
        }
      }
      final shrunk = await shrinkProfileImage(
        bytes,
        maxSide: walletImageMaxSide,
      );
      if (!mounted) return;
      setState(() => _image = shrunk);
    } on Object catch (error) {
      if (mounted) showBookError(context, error, 'تعذر تحميل الصورة.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _removeImage() => setState(() => _image = null);

  void _onRowCurrencyChanged(_OpeningRow row, String code) {
    setState(() {
      row.currencyCode = code;
      final digits = widget.book.currencies.byCode(code).fractionDigits;
      row.amount.value = ThousandsInputFormatter(fractionDigits: digits)
          .formatEditUpdate(
            row.amount.value,
            TextEditingValue(text: reshapeAmountText(row.amount.text, digits)),
          );
    });
  }

  void _addOpening() {
    final used = {for (final row in _openings) row.currencyCode};
    final active = widget.book.currencies.activeCurrencies;
    final next = active.firstWhere(
      (currency) => !used.contains(currency.code),
      orElse: () => active.first,
    );
    setState(() => _openings.add(_OpeningRow(currencyCode: next.code)));
  }

  void _removeOpening(_OpeningRow row) {
    setState(() {
      _openings.remove(row);
      row.dispose();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final openings = <WalletOpeningDraft>[
        for (final row in _openings)
          WalletOpeningDraft(
            currencyCode: row.currencyCode,
            openingMinor: _parseOpening(row),
          ),
      ];
      final draft = WalletDraft(
        name: _name.text,
        accountNumber: _accountNumber.text,
        image: _image,
        notes: _notes.text,
        openings: openings,
      );
      final existing = widget.wallet;
      if (existing == null) {
        await widget.book.wallets.create(draft);
      } else {
        await widget.book.wallets.update(existing.id, draft);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  int _parseOpening(_OpeningRow row) {
    final typed = canonicalAmountInput(row.amount.text);
    if (typed.isEmpty || typed == '.') return 0;
    return widget.book.currencies
        .parseAmount(input: typed, currencyCode: row.currencyCode)
        .amountMinor;
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.wallet != null;
    final currencies = widget.book.currencies.activeCurrencies;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'تعديل المحفظة' : 'إضافة محفظة جديدة'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onTap: _picking ? null : _pickImage,
                        child: Container(
                          key: const Key('wallet-image-preview'),
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.10),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: _image == null
                              ? Icon(
                                  walletFallbackIcon,
                                  size: 34,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : Image.memory(_image!, fit: BoxFit.cover),
                        ),
                      ),
                      Positioned(
                        bottom: -4,
                        left: -4,
                        child: Material(
                          color: Theme.of(context).colorScheme.primary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            key: const Key('wallet-image-pick'),
                            customBorder: const CircleBorder(),
                            onTap: _picking ? null : _pickImage,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: _picking
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Icon(
                                      Icons.camera_alt_outlined,
                                      size: 16,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimary,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_image != null)
                  Center(
                    child: TextButton.icon(
                      key: const Key('wallet-image-remove'),
                      onPressed: _picking ? null : _removeImage,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('إزالة الصورة'),
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('wallet-name'),
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'اسم المحفظة'),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('wallet-account-number'),
                  controller: _accountNumber,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'رقم الحساب (اختياري)',
                    helperText: 'إن كان لهذه المحفظة رقم حساب أو IBAN',
                  ),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    'الأرصدة الافتتاحية',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final row in _openings) ...[
                  _OpeningRowWidget(
                    key: ValueKey(row),
                    row: row,
                    currencies: currencies,
                    usedCodes: {
                      for (final other in _openings)
                        if (other != row) other.currencyCode,
                    },
                    fractionDigits:
                        widget.book.currencies.byCode(row.currencyCode).fractionDigits,
                    saving: _saving,
                    canRemove: !row.locked,
                    onCurrencyChanged: (code) => _onRowCurrencyChanged(row, code),
                    onRemove: () => _removeOpening(row),
                  ),
                  const SizedBox(height: 10),
                ],
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('wallet-add-currency'),
                    onPressed: _saving ? null : _addOpening,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('إضافة عملة أخرى'),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('wallet-notes'),
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'ملاحظات (اختياري)'),
                ),
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

class _OpeningRowWidget extends StatelessWidget {
  const _OpeningRowWidget({
    super.key,
    required this.row,
    required this.currencies,
    required this.usedCodes,
    required this.fractionDigits,
    required this.saving,
    required this.canRemove,
    required this.onCurrencyChanged,
    required this.onRemove,
  });

  final _OpeningRow row;
  final List<Currency> currencies;
  final Set<String> usedCodes;
  final int fractionDigits;
  final bool saving;
  final bool canRemove;
  final ValueChanged<String> onCurrencyChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final code = row.currencyCode;
    // The row's own currency is always listed, even one that has since been
    // archived: a dropdown whose value is missing from its items fails
    // Flutter's assertion and turns the whole page red.
    final options = <String>[
      for (final currency in currencies)
        if (currency.code == code || !usedCodes.contains(currency.code))
          currency.code,
    ];
    if (!options.contains(code)) options.insert(0, code);
    return Row(
      key: Key('wallet-opening-row-$code'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            key: Key('wallet-opening-currency-$code'),
            isExpanded: true,
            initialValue: code,
            decoration: InputDecoration(
              labelText: 'العملة',
              helperText: row.locked ? 'عملة فيها حركات — لا يمكن تغييرها' : null,
            ),
            items: [
              for (final option in options)
                DropdownMenuItem(
                  value: option,
                  child: Text(option, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: saving || row.locked
                ? null
                : (value) {
                    if (value != null) onCurrencyChanged(value);
                  },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TextField(
            key: Key('wallet-opening-amount-$code'),
            controller: row.amount,
            textDirection: TextDirection.ltr,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [ThousandsInputFormatter(fractionDigits: fractionDigits)],
            decoration: const InputDecoration(labelText: 'الرصيد الافتتاحي'),
          ),
        ),
        if (canRemove)
          IconButton(
            key: Key('wallet-opening-remove-$code'),
            tooltip: 'إزالة',
            onPressed: saving ? null : onRemove,
            icon: const Icon(Icons.close, size: 18),
          ),
      ],
    );
  }
}
