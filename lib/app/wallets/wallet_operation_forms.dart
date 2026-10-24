import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/models.dart';
import '../../features/book/book.dart';
import '../../features/wallets/wallets.dart';
import '../../shared/formatting/money_format.dart';
import '../jibi_app_shell.dart';
import 'wallet_widgets.dart';

/// Splits a typed exchange-rate string into an exact fraction (numerator over
/// a power-of-ten scale) — a rate is not a currency amount, so it is not
/// constrained to any currency's fraction digits the way [CurrencyRegistry]
/// amounts are. Returns null for empty or malformed input.
({BigInt numerator, BigInt scale})? parseExchangeRate(String text) {
  final typed = canonicalAmountInput(text).trim();
  if (typed.isEmpty) return null;
  final parts = typed.split('.');
  if (parts.length > 2) return null;
  final integerPart = parts[0].isEmpty ? '0' : parts[0];
  final fractionPart = parts.length == 2 ? parts[1] : '';
  final digits = RegExp(r'^\d+$');
  if (!digits.hasMatch(integerPart)) return null;
  if (fractionPart.isNotEmpty && !digits.hasMatch(fractionPart)) return null;
  final scale = BigInt.from(10).pow(fractionPart.length);
  final numerator =
      BigInt.parse(integerPart) * scale +
      (fractionPart.isEmpty ? BigInt.zero : BigInt.parse(fractionPart));
  if (numerator == BigInt.zero) return null; // a zero rate suggests nothing
  return (numerator: numerator, scale: scale);
}

/// Rounds a non-negative fraction to the nearest integer, half away from
/// zero — the project's one rounding policy for money math, applied exactly
/// once at the end of a computation. Returns null if the result would not
/// fit safely in an [int] (the same ceiling `CurrencyRegistry` enforces).
int? roundHalfAwayFromZero(BigInt numerator, BigInt denominator) {
  final quotient = numerator ~/ denominator;
  final remainder = numerator - quotient * denominator;
  final rounded = remainder * BigInt.two >= denominator ? quotient + BigInt.one : quotient;
  const safeMax = 9007199254740991;
  if (rounded > BigInt.from(safeMax)) return null;
  return rounded.toInt();
}

enum _OperationKind { deposit, withdrawal, transfer, exchange }

/// Opens a direct deposit (إيداع) form for [wallet]. Returns true after a save.
///
/// [initialCurrency] (the currency the caller is showing) is preselected when
/// the wallet can use it; the four openers below share this rule.
Future<bool?> openWalletDepositForm(
  BuildContext context,
  BookServices book,
  Wallet wallet, {
  String? initialCurrency,
}) => pushFormPage<bool>(
  context,
  _WalletOperationFormPage(
    book: book,
    wallet: wallet,
    kind: _OperationKind.deposit,
    initialCurrency: initialCurrency,
  ),
);

/// Opens a direct withdrawal (سحب) form for [wallet]. Returns true after a save.
Future<bool?> openWalletWithdrawalForm(
  BuildContext context,
  BookServices book,
  Wallet wallet, {
  String? initialCurrency,
}) => pushFormPage<bool>(
  context,
  _WalletOperationFormPage(
    book: book,
    wallet: wallet,
    kind: _OperationKind.withdrawal,
    initialCurrency: initialCurrency,
  ),
);

/// Opens a transfer (تحويل) form from [wallet] to another wallet, in the same
/// currency or across two. Returns true after a save.
Future<bool?> openWalletTransferForm(
  BuildContext context,
  BookServices book,
  Wallet wallet, {
  String? initialCurrency,
}) => pushFormPage<bool>(
  context,
  _WalletOperationFormPage(
    book: book,
    wallet: wallet,
    kind: _OperationKind.transfer,
    initialCurrency: initialCurrency,
  ),
);

/// Opens an exchange (صرف) form: converts one currency of [wallet] into
/// another, inside the same wallet. Returns true after a save.
Future<bool?> openWalletExchangeForm(
  BuildContext context,
  BookServices book,
  Wallet wallet, {
  String? initialCurrency,
}) => pushFormPage<bool>(
  context,
  _WalletOperationFormPage(
    book: book,
    wallet: wallet,
    kind: _OperationKind.exchange,
    initialCurrency: initialCurrency,
  ),
);

class _WalletOperationFormPage extends StatefulWidget {
  const _WalletOperationFormPage({
    required this.book,
    required this.wallet,
    required this.kind,
    this.initialCurrency,
  });

  final BookServices book;
  final Wallet wallet;
  final _OperationKind kind;
  final String? initialCurrency;

  @override
  State<_WalletOperationFormPage> createState() =>
      _WalletOperationFormPageState();
}

class _WalletOperationFormPageState extends State<_WalletOperationFormPage> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _received = TextEditingController();
  final TextEditingController _rate = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  DateTime _occurredAt = DateTime.now();
  String? _toWalletId;
  String? _fromCurrency;
  String? _toCurrency;
  List<WalletSummary> _otherWallets = const [];

  /// The currencies the source wallet holds (its balance rows).
  List<String> _held = const [];
  bool _loaded = false;
  bool _saving = false;

  bool get _isTransfer => widget.kind == _OperationKind.transfer;
  bool get _isExchange => widget.kind == _OperationKind.exchange;
  bool get _crossCurrency =>
      (_isTransfer || _isExchange) && _fromCurrency != null && _toCurrency != null &&
      _fromCurrency != _toCurrency;

  int get _fractionDigits => _digitsOf(_fromCurrency);

  int get _receivedFractionDigits => _digitsOf(_toCurrency);

  /// Decimal places of [code]; never throws while building (a code missing
  /// from the registry falls back to no decimals instead of a red screen).
  int _digitsOf(String? code) {
    if (code == null) return 0;
    try {
      return widget.book.currencies.byCode(code).fractionDigits;
    } on Object {
      return 0;
    }
  }

  List<String> get _activeCodes => [
    for (final currency in widget.book.currencies.activeCurrencies)
      currency.code,
  ];

  /// [primary] followed by whatever of [extra] it does not contain yet, so a
  /// dropdown always lists the value it is showing (an archived currency the
  /// wallet still holds would otherwise fail Flutter's "exactly one item"
  /// assertion and turn the page red).
  List<String> _merged(
    Iterable<String> primary,
    Iterable<String> extra, {
    String? keep,
    String? without,
  }) {
    final out = <String>[];
    for (final code in [...primary, ...extra, ?keep]) {
      if (code != without && !out.contains(code)) out.add(code);
    }
    return out;
  }

  /// What the money can leave from / be paid in: a deposit may go into any
  /// active currency (a new one is created in the wallet), everything else
  /// only uses currencies the wallet actually holds — otherwise a phantom
  /// negative balance would appear in a currency it never had.
  List<String> get _sourceOptions {
    final keep = _fromCurrency;
    if (widget.kind == _OperationKind.deposit) {
      return _merged(_activeCodes, _held, keep: keep);
    }
    return _merged(_held.isNotEmpty ? _held : _activeCodes, const [], keep: keep);
  }

  /// The currencies offered for the receiving side of a transfer or exchange.
  List<String> get _targetOptions {
    if (_isExchange) {
      return _merged(
        _activeCodes,
        _held,
        keep: _toCurrency,
        without: _fromCurrency,
      );
    }
    final target = _targetSummary;
    return _merged(_activeCodes, target?.currencies ?? const [], keep: _toCurrency);
  }

  WalletSummary? get _targetSummary {
    for (final summary in _otherWallets) {
      if (summary.wallet.id == _toWalletId) return summary;
    }
    return null;
  }

  /// The currency a transfer pays out in on the target: the sender's own when
  /// the target holds it (no exchange rate needed), else the target's main one.
  String? _defaultTargetCurrency(WalletSummary target) {
    final from = _fromCurrency;
    if (from != null && target.currencies.contains(from)) return from;
    return target.primary?.currencyCode ?? from;
  }

  @override
  void initState() {
    super.initState();
    _loadWallet();
  }

  Future<void> _loadWallet() async {
    final summary = await widget.book.wallets.summary(widget.wallet.id);
    _held = summary?.currencies ?? const <String>[];
    final options = _sourceOptions;
    // The currency being viewed first, then the base currency, then what the
    // wallet mostly holds; whichever of them this operation can use.
    for (final candidate in [
      widget.initialCurrency,
      widget.book.defaultCurrencyCode(),
      summary?.primary?.currencyCode,
    ]) {
      if (candidate != null && options.contains(candidate)) {
        _fromCurrency = candidate;
        break;
      }
    }
    _fromCurrency ??= options.isEmpty ? null : options.first;
    if (_isTransfer) {
      await _loadOtherWallets();
    }
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  Future<void> _loadOtherWallets() async {
    final all = await widget.book.wallets.summaries(includeArchived: false);
    final others = [
      for (final summary in all)
        if (summary.wallet.id != widget.wallet.id) summary,
    ];
    _otherWallets = others;
    if (others.isNotEmpty) {
      _toWalletId = others.first.wallet.id;
      _toCurrency = _defaultTargetCurrency(others.first);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _received.dispose();
    _rate.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// Recomputes "المبلغ المستلم" from the sold amount and the typed rate,
  /// when a rate is present — the rate then drives the field and it stops
  /// being manually editable. An empty or unparsable rate leaves the
  /// received field exactly as the user last left it, editable by hand (the
  /// existing, unchanged behaviour when no rate is involved).
  void _recomputeReceived() {
    if (!_crossCurrency) return;
    final rate = parseExchangeRate(_rate.text);
    if (rate == null) {
      setState(() {}); // re-enable the field; keep its current text as-is
      return;
    }
    final fromCode = _fromCurrency!;
    final toCode = _toCurrency!;
    int soldMinor;
    try {
      soldMinor = _parseAmount(_amount.text, fromCode);
    } on Object {
      return; // sold amount not typed yet or invalid; nothing to compute
    }
    final fromDigits = widget.book.currencies.byCode(fromCode).fractionDigits;
    final toDigits = widget.book.currencies.byCode(toCode).fractionDigits;
    final numerator =
        BigInt.from(soldMinor) * rate.numerator * BigInt.from(10).pow(toDigits);
    final denominator = BigInt.from(10).pow(fromDigits) * rate.scale;
    final boughtMinor = roundHalfAwayFromZero(numerator, denominator);
    if (boughtMinor == null) return; // out of the safe integer range; ignore
    setState(() => _received.text = formatMinorGrouped(boughtMinor, toDigits));
  }

  void _onFromCurrencyChanged(String? value) {
    setState(() {
      _fromCurrency = value;
      if (!_isTransfer && !_isExchange) {
        _toCurrency = value;
      } else if (_isExchange && _toCurrency == value) {
        // Selling and buying the same currency is meaningless.
        _toCurrency = null;
      } else if (_isTransfer) {
        final target = _targetSummary;
        if (target != null) _toCurrency = _defaultTargetCurrency(target);
      }
      // A rate/received value for the old pair means nothing for the new one,
      // and the typed amount is re-read under the new currency's decimals.
      _rate.clear();
      _received.clear();
      _amount.value = ThousandsInputFormatter(fractionDigits: _digitsOf(value))
          .formatEditUpdate(
            _amount.value,
            TextEditingValue(
              text: reshapeAmountText(_amount.text, _digitsOf(value)),
            ),
          );
    });
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (date != null && mounted) {
      setState(() {
        _occurredAt = DateTime(
          date.year,
          date.month,
          date.day,
          _occurredAt.hour,
          _occurredAt.minute,
        );
      });
    }
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
    );
    if (time != null && mounted) {
      setState(() {
        _occurredAt = DateTime(
          _occurredAt.year,
          _occurredAt.month,
          _occurredAt.day,
          time.hour,
          time.minute,
        );
      });
    }
  }

  int _parseAmount(String text, String currencyCode) {
    final typed = canonicalAmountInput(text);
    return widget.book.currencies
        .parseAmount(input: typed.isEmpty ? '0' : typed, currencyCode: currencyCode)
        .amountMinor;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final fromCode = _fromCurrency;
      if (fromCode == null) {
        throw const ValidationException(
          code: 'wallet_currency_required',
          userMessage: 'حدّد عملة الحركة.',
        );
      }
      final amountMinor = _parseAmount(_amount.text, fromCode);
      final date = WalletTransaction.formatDate(_occurredAt);
      final time = WalletTransaction.formatTime(_occurredAt);
      switch (widget.kind) {
        case _OperationKind.deposit:
          await widget.book.walletTransactions.deposit(
            WalletDepositDraft(
              walletId: widget.wallet.id,
              currencyCode: fromCode,
              amountMinor: amountMinor,
              date: date,
              time: time,
              notes: _notes.text,
            ),
          );
        case _OperationKind.withdrawal:
          await widget.book.walletTransactions.withdraw(
            WalletWithdrawalDraft(
              walletId: widget.wallet.id,
              currencyCode: fromCode,
              amountMinor: amountMinor,
              date: date,
              time: time,
              notes: _notes.text,
            ),
          );
        case _OperationKind.transfer:
          final toWalletId = _toWalletId;
          final toCode = _toCurrency;
          if (toWalletId == null || toCode == null) {
            showBookError(
              context,
              const ValidationException(
                code: 'transfer_no_target',
                userMessage: 'لا توجد محفظة أخرى للتحويل إليها.',
              ),
            );
            return;
          }
          final receivedMinor = fromCode == toCode
              ? amountMinor
              : _parseAmount(_received.text, toCode);
          await widget.book.walletTransactions.transfer(
            WalletTransferDraft(
              fromWalletId: widget.wallet.id,
              toWalletId: toWalletId,
              fromCurrencyCode: fromCode,
              toCurrencyCode: toCode,
              amountMinor: amountMinor,
              receivedMinor: receivedMinor,
              date: date,
              time: time,
              notes: _notes.text,
            ),
          );
        case _OperationKind.exchange:
          final toCode = _toCurrency;
          if (toCode == null) {
            throw const ValidationException(
              code: 'wallet_currency_required',
              userMessage: 'حدّد العملة المستلمة.',
            );
          }
          final boughtMinor = _parseAmount(_received.text, toCode);
          await widget.book.walletTransactions.exchange(
            WalletExchangeDraft(
              walletId: widget.wallet.id,
              fromCurrencyCode: fromCode,
              toCurrencyCode: toCode,
              soldMinor: amountMinor,
              boughtMinor: boughtMinor,
              date: date,
              time: time,
              notes: _notes.text,
            ),
          );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _title => switch (widget.kind) {
    _OperationKind.deposit => 'إيداع في المحفظة',
    _OperationKind.withdrawal => 'سحب من المحفظة',
    _OperationKind.transfer => 'تحويل بين المحافظ',
    _OperationKind.exchange => 'صرف عملة داخل المحفظة',
  };

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final sourceOptions = _sourceOptions;
    final targetOptions = _targetOptions;
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  children: [
                    WalletAvatar(wallet: widget.wallet, size: 36),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.wallet.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (sourceOptions.length > 1 || _fromCurrency == null) ...[
                  DropdownButtonFormField<String>(
                    key: const Key('wtx-from-currency'),
                    isExpanded: true,
                    initialValue: _fromCurrency,
                    decoration: InputDecoration(
                      labelText: _isExchange ? 'من عملة' : 'العملة',
                    ),
                    items: [
                      for (final code in sourceOptions)
                        DropdownMenuItem(value: code, child: Text(code)),
                    ],
                    onChanged: _saving ? null : _onFromCurrencyChanged,
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  key: const Key('wtx-amount'),
                  controller: _amount,
                  autofocus: true,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.center,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    ThousandsInputFormatter(fractionDigits: _fractionDigits),
                  ],
                  onChanged: _saving ? null : (_) => _recomputeReceived(),
                  style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
                  decoration: InputDecoration(
                    labelText: _isExchange ? 'المبلغ المصروف' : 'المبلغ',
                    suffixText: _fromCurrency,
                  ),
                ),
                if (_isTransfer) ...[
                  const SizedBox(height: 16),
                  if (_otherWallets.isEmpty)
                    Text(
                      'لا توجد محفظة أخرى للتحويل إليها.',
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    )
                  else ...[
                    DropdownButtonFormField<String>(
                      key: const Key('wtx-target-wallet'),
                      isExpanded: true,
                      initialValue: _toWalletId,
                      decoration: const InputDecoration(labelText: 'التحويل إلى'),
                      items: [
                        for (final summary in _otherWallets)
                          DropdownMenuItem(
                            value: summary.wallet.id,
                            child: Text(summary.wallet.name),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() {
                              _toWalletId = value;
                              final target = _otherWallets.firstWhere(
                                (summary) => summary.wallet.id == value,
                              );
                              _toCurrency = _defaultTargetCurrency(target);
                              _rate.clear();
                              _received.clear();
                            }),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: const Key('wtx-to-currency'),
                      isExpanded: true,
                      initialValue: _toCurrency,
                      decoration: const InputDecoration(labelText: 'إلى عملة'),
                      items: [
                        for (final code in targetOptions)
                          DropdownMenuItem(value: code, child: Text(code)),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() {
                              _toCurrency = value;
                              _rate.clear();
                              _received.clear();
                            }),
                    ),
                  ],
                ],
                if (_isExchange) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('wtx-to-currency'),
                    isExpanded: true,
                    initialValue: _toCurrency,
                    decoration: const InputDecoration(labelText: 'إلى عملة'),
                    items: [
                      for (final code in targetOptions)
                        DropdownMenuItem(value: code, child: Text(code)),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) => setState(() {
                            _toCurrency = value;
                            _rate.clear();
                            _received.clear();
                          }),
                  ),
                ],
                if ((_isTransfer && _otherWallets.isNotEmpty) || _isExchange) ...[
                  if (_crossCurrency) ...[
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('wtx-rate'),
                      controller: _rate,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: _saving ? null : (_) => _recomputeReceived(),
                      decoration: InputDecoration(
                        labelText: 'سعر الصرف',
                        helperText: '١ $_fromCurrency = ؟ $_toCurrency',
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('wtx-received'),
                    controller: _received,
                    enabled:
                        (_isExchange || _crossCurrency) &&
                        !(_crossCurrency && _rate.text.trim().isNotEmpty),
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      ThousandsInputFormatter(fractionDigits: _receivedFractionDigits),
                    ],
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                    decoration: InputDecoration(
                      labelText: _isExchange ? 'المبلغ المستلم' : 'المبلغ المستلم',
                      suffixText: _toCurrency,
                      helperText: !_crossCurrency
                          ? 'نفس المبلغ المرسل — عملة واحدة'
                          : _rate.text.trim().isNotEmpty
                          ? 'محسوب من سعر الصرف'
                          : null,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('wtx-date'),
                        onPressed: _saving ? null : _pickDate,
                        icon: const Icon(Icons.event_outlined),
                        label: Text(WalletTransaction.formatDate(_occurredAt)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('wtx-time'),
                        onPressed: _saving ? null : _pickTime,
                        icon: const Icon(Icons.schedule),
                        label: Text(
                          localizations.formatTimeOfDay(
                            TimeOfDay.fromDateTime(_occurredAt),
                            alwaysUse24HourFormat: true,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('wtx-notes'),
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'ملاحظات (اختياري)'),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('save-button'),
                  onPressed: _saving ||
                          (_isTransfer && _otherWallets.isEmpty) ||
                          (_isExchange && _toCurrency == null)
                      ? null
                      : _save,
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
