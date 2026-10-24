import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/models.dart';
import '../../core/storage/document_source_picker.dart';
import '../../core/storage/secure_file_storage.dart';
import '../../features/book/book.dart';
import '../../shared/formatting/money_format.dart';
import '../../shared/widgets/external_activity_scope.dart';
import '../../shared/widgets/jibi_design.dart';
import '../jibi_app_shell.dart';
import '../wallets/wallet_forms.dart';
import 'book_widgets.dart';

/// Opens the transaction form full screen. Pass [transaction] to edit it.
/// Returns true after a save.
Future<bool?> openTransactionForm(
  BuildContext context,
  BookServices book, {
  required BookAccount account,
  BookTransaction? transaction,
  EntryType? defaultType,
  String? initialCurrencyCode,
  DocumentSourcePicker picker = const AndroidDocumentSourcePicker(),
}) => pushFormPage<bool>(
  context,
  BookTransactionFormPage(
    book: book,
    account: account,
    transaction: transaction,
    defaultType: defaultType,
    initialCurrencyCode: initialCurrencyCode,
    picker: picker,
  ),
);

/// Quick and simple, as the spec asks: amount, debit/credit, date and time,
/// details, notes, save.
class BookTransactionFormPage extends StatefulWidget {
  const BookTransactionFormPage({
    required this.book,
    required this.account,
    super.key,
    this.transaction,
    this.defaultType,
    this.initialCurrencyCode,
    this.picker = const AndroidDocumentSourcePicker(),
  });

  final BookServices book;
  final BookAccount account;
  final BookTransaction? transaction;

  /// The side a new transaction starts on; null uses the setting.
  final EntryType? defaultType;

  /// The currency a new transaction starts on (for example the one the
  /// statement is filtered to); null picks the account's only currency, or the
  /// base currency.
  final String? initialCurrencyCode;
  final DocumentSourcePicker picker;

  @override
  State<BookTransactionFormPage> createState() =>
      _BookTransactionFormPageState();
}

class _BookTransactionFormPageState extends State<BookTransactionFormPage> {
  final TextEditingController _amount = TextEditingController();
  late final TextEditingController _details = TextEditingController(
    text: widget.transaction?.details ?? '',
  );
  late final TextEditingController _notes = TextEditingController(
    text: widget.transaction?.notes ?? '',
  );
  late EntryType _type;
  bool _typeReady = false;

  /// The currency of this transaction. The account has none of its own: every
  /// transaction names its own, and the wallet movement of its payment method
  /// follows it.
  late String _currency = _startingCurrency();
  bool _currencyTouched = false;
  late DateTime _occurredAt = widget.transaction?.occurredAt ?? DateTime.now();
  // The payment method *is* a wallet: the main wallet reads «نقدًا», every
  // other wallet reads as the name the user gave it. A brand-new transaction
  // starts on the main wallet (see _loadWallets); only a row from before
  // wallets were linked can be edited with none selected.
  late String? _walletId = widget.transaction?.walletId;
  late WalletBalanceEffect _walletEffect;
  bool _effectTouched = false;

  /// Every wallet that could be a payment method at all: the active ones, and
  /// the one already on the transaction (even if archived since). Which of them
  /// are offered depends on the currency — see [_eligibleWallets].
  List<WalletSummary> _wallets = const [];
  bool _walletsLoaded = false;

  /// True once the user picked a payment method themselves (the main wallet is
  /// only a default until then).
  bool _walletTouched = false;

  /// The name of the payment method a change of currency just took away, so the
  /// form can say why nothing is selected any more.
  String? _droppedWalletName;
  bool _saving = false;
  bool _picking = false;

  /// Files chosen but not yet encrypted and attached (they are attached when
  /// the transaction is saved).
  final List<_PendingAttachment> _pending = [];

  /// Attachments of the edited transaction, minus those marked for removal.
  late final List<BookAttachment> _existing = [
    ...?widget.transaction?.attachments,
  ];
  final Set<String> _removed = <String>{};

  int get _fractionDigits =>
      widget.book.currencies.byCode(_currency).fractionDigits;

  /// The transaction's own currency, else the one asked for, else the base
  /// currency if it is active, else the first active one.
  String _startingCurrency() {
    final existing = widget.transaction?.currencyCode;
    if (existing != null) return existing;
    final asked = widget.initialCurrencyCode?.toUpperCase();
    if (asked != null) return asked;
    final active = widget.book.currencies.activeCurrencies;
    final base = widget.book.defaultCurrencyCode();
    if (active.any((currency) => currency.code == base)) return base;
    return active.isEmpty ? base : active.first.code;
  }

  @override
  void initState() {
    super.initState();
    final existing = widget.transaction;
    if (existing != null) {
      _amount.text = bookAmount(
        widget.book.currencies,
        existing.currencyCode,
        existing.amountMinor,
      );
    }
    _loadWallets();
    _loadCurrencies();
  }

  /// A new transaction on an account that uses exactly one currency starts on
  /// that currency (unless one was asked for or already picked).
  Future<void> _loadCurrencies() async {
    if (widget.transaction != null || widget.initialCurrencyCode != null) return;
    final summary = await widget.book.accounts.summary(widget.account.id);
    if (!mounted || _currencyTouched || summary == null) return;
    if (summary.currencies.length == 1) {
      final only = summary.currencies.single.currencyCode;
      if (only != _currency) _selectCurrency(only, touched: false);
    }
  }

  /// Switches the currency and re-applies its decimal rule to what was typed.
  void _selectCurrency(String code, {bool touched = true}) {
    setState(() {
      _currency = code;
      if (touched) _currencyTouched = true;
      // A payment method that does not hold the new currency is dropped; the
      // user must pick one that does before the transaction can be saved.
      _reconcileWallet();
    });
    _amount.value = ThousandsInputFormatter(
      fractionDigits: _fractionDigits,
    ).formatEditUpdate(
      _amount.value,
      TextEditingValue(text: reshapeAmountText(_amount.text, _fractionDigits)),
    );
  }

  Future<void> _loadWallets() async {
    // The active wallets are the payment methods; the wallet already on the
    // transaction stays in the list even if archived since, so editing it does
    // not silently change its payment method. Which ones are OFFERED depends on
    // the currency (see [_eligibleWallets]).
    final all = await widget.book.wallets.summaries(includeArchived: true);
    final keep = widget.transaction?.walletId;
    final matching = paymentWalletOrder([
      for (final summary in all)
        if (summary.wallet.status == WalletStatus.active ||
            summary.wallet.id == keep)
          summary,
    ]);
    if (!mounted) return;
    setState(() {
      _wallets = matching;
      _walletsLoaded = true;
      _reconcileWallet();
    });
  }

  /// The wallets this transaction can be paid through in [_currency]: only
  /// those that ALREADY HOLD it. Nothing here (or in saving) adds a currency to
  /// a wallet — that is an explicit action on the wallet's own screen.
  List<WalletSummary> get _eligibleWallets => [
    for (final summary in _wallets)
      if (summary.currencies.contains(_currency)) summary,
  ];

  /// Keeps the selection valid for the current currency: a selected wallet that
  /// does not hold it is deselected (and remembered, to explain it); a brand-new
  /// transaction the user has not chosen a payment for starts on the main wallet
  /// («نقدًا») whenever that one holds the currency. Call inside setState.
  void _reconcileWallet() {
    final eligible = _eligibleWallets;
    final current = _walletId;
    if (current != null && !eligible.any((s) => s.wallet.id == current)) {
      for (final summary in _wallets) {
        if (summary.wallet.id == current) {
          _droppedWalletName = summary.wallet.paymentLabel;
        }
      }
      _walletId = null;
    }
    if (_walletId == null && widget.transaction == null && !_walletTouched) {
      for (final summary in eligible) {
        if (summary.wallet.isMain) {
          _walletId = summary.wallet.id;
          _droppedWalletName = null;
          break;
        }
      }
    }
  }

  /// The «add this currency» shortcut of the main wallet: opens the wallet's
  /// own screen, where the currency is added explicitly (with its opening
  /// balance), then reloads the payment methods.
  Future<void> _addCurrencyToWallet(Wallet wallet) async {
    await openWalletForm(context, widget.book, wallet: wallet);
    if (mounted) await _loadWallets();
  }

  @override
  void dispose() {
    _amount.dispose();
    _details.dispose();
    _notes.dispose();
    for (final item in _pending) {
      _deleteQuietly(item.request.sourceFile);
    }
    super.dispose();
  }

  static void _deleteQuietly(File file) {
    try {
      file.deleteSync();
    } on Object {
      // A cache file that is already gone needs no cleanup.
    }
  }

  Future<void> _addSource(
    Future<FileImportRequest?> Function() acquire,
    String failureMessage,
  ) async {
    setState(() => _picking = true);
    final runExternal = ExternalActivityScope.of(context);
    try {
      final request = await runExternal(acquire);
      if (request == null) return;
      if (!mounted) {
        _deleteQuietly(request.sourceFile);
        return;
      }
      setState(
        () => _pending.add(
          _PendingAttachment(
            request,
            BookAttachmentsController.kindFor(request.mimeType),
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        showBookError(context, error, failureMessage);
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _chooseSource() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('attach-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('التقاط صورة بالكاميرا'),
              onTap: () => Navigator.of(sheetContext).pop('camera'),
            ),
            ListTile(
              key: const Key('attach-file'),
              leading: const Icon(Icons.attach_file),
              title: const Text('صورة أو ملف من الجهاز'),
              subtitle: const Text('صور، PDF، إيصالات، فواتير…'),
              onTap: () => Navigator.of(sheetContext).pop('file'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'camera') {
      await _addSource(widget.picker.captureImage, 'تعذر التقاط الصورة.');
    } else {
      await _addSource(widget.picker.pickFile, 'تعذر اختيار الملف.');
    }
  }

  /// Encrypts the chosen files onto [transactionId] and applies removals.
  /// Returns false when any file could not be handled.
  Future<bool> _syncAttachments(String transactionId) async {
    final attachments = widget.book.attachments;
    if (attachments == null) return true;
    var ok = true;
    for (final id in _removed) {
      try {
        await attachments.remove(id);
      } on Object {
        ok = false;
      }
    }
    for (final item in List<_PendingAttachment>.of(_pending)) {
      try {
        await attachments.add(
          transactionId: transactionId,
          request: item.request,
          kind: item.kind,
        );
        _pending.remove(item);
        _deleteQuietly(item.request.sourceFile);
      } on Object {
        ok = false;
      }
    }
    return ok;
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

  Future<void> _save() async {
    // A payment method that holds the currency is required. Only a row from
    // before wallets were linked may be saved without one.
    final legacyUnlinked =
        widget.transaction != null && widget.transaction!.walletId == null;
    if (_walletId == null && !legacyUnlinked) {
      showBookError(
        context,
        ValidationException(
          code: 'payment_wallet_required',
          userMessage: 'اختر وسيلة دفع تدعم عملة $_currency.',
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final typed = canonicalAmountInput(_amount.text);
      final amount = widget.book.currencies
          .parseAmount(
            input: typed.isEmpty ? '0' : typed,
            currencyCode: _currency,
          )
          .amountMinor;
      final draft = BookTransactionDraft(
        accountId: widget.account.id,
        currencyCode: _currency,
        type: _type,
        amountMinor: amount,
        date: BookTransaction.formatDate(_occurredAt),
        time: BookTransaction.formatTime(_occurredAt),
        details: _details.text,
        notes: _notes.text,
        walletId: _walletId,
        walletEffect: _walletId == null ? null : _walletEffect,
      );
      final existing = widget.transaction;
      final saved = existing == null
          ? await widget.book.transactions.create(draft)
          : await widget.book.transactions.update(existing.id, draft);
      final attached = await _syncAttachments(saved.id);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      if (!attached) {
        // The transaction is saved; only some files failed.
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('تم حفظ العملية لكن تعذر حفظ بعض المرفقات.'),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) showBookError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The transaction's currency: any active currency (and the one it already
  /// has, even if switched off since). Balances, totals and the wallet movement
  /// of the payment method all stay in this currency and are never converted.
  Widget _currencySection(BuildContext context) {
    final choices = [
      for (final currency in widget.book.currencies.currencies)
        if (currency.isActive || currency.code == _currency) currency,
    ];
    return Column(
      key: const Key('tx-currency'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'العملة',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final currency in choices)
              ChoiceChip(
                key: Key('tx-currency-${currency.code}'),
                label: Text(currency.code),
                selected: _currency == currency.code,
                onSelected: _saving
                    ? null
                    : (_) => _selectCurrency(currency.code),
              ),
          ],
        ),
      ],
    );
  }

  /// One control for how the transaction was paid: «نقدًا» (the main wallet)
  /// or any other active wallet by its own name — nothing else. It is the
  /// wallet the transaction moves money through; the effect below says whether
  /// that wallet's balance goes up or down, seeded from the transaction's own
  /// nature (see [WalletBalanceEffect.forEntry]) until touched.
  Widget _paymentSection(BuildContext context) {
    final editingLegacy = widget.transaction != null && _walletId == null;
    final eligible = _eligibleWallets;
    WalletSummary? main;
    for (final summary in _wallets) {
      if (summary.wallet.isMain) main = summary;
    }
    // «نقدًا» is the usual payment method: if it is missing from the list only
    // because it does not hold this currency yet, say so and offer the explicit
    // way to add it (its own screen) — never a side effect of saving.
    final mainMissing =
        _walletsLoaded && main != null && !main.currencies.contains(_currency);
    final hint = !_walletsLoaded || _walletId != null
        ? null
        : editingLegacy && eligible.isNotEmpty
        ? 'هذه عملية قديمة غير مرتبطة بوسيلة دفع فلا تؤثر على أي محفظة. '
              'اختر وسيلة دفع لربطها، أو احفظها كما هي.'
        : eligible.isEmpty
        ? 'لا توجد وسيلة دفع تحمل عملة $_currency. أضف العملة إلى محفظة (أو إلى '
              'الصندوق الرئيسي) من شاشتها، ثم عُد لاختيارها.'
        : _droppedWalletName != null
        ? '«$_droppedWalletName» لا تحمل عملة $_currency. اختر وسيلة دفع '
              'تحملها.'
        : 'اختر وسيلة الدفع.';
    return Column(
      key: const Key('tx-payment-method'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'وسيلة الدفع',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final summary in eligible)
              ChoiceChip(
                key: Key('payment-wallet-${summary.wallet.id}'),
                avatar: Icon(
                  summary.wallet.isMain
                      ? Icons.payments_outlined
                      : Icons.account_balance_wallet_outlined,
                  size: 18,
                ),
                label: Text(
                  summary.wallet.paymentLabel,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: _walletId == summary.wallet.id,
                onSelected: _saving
                    ? null
                    : (_) => setState(() {
                        _walletId = summary.wallet.id;
                        _walletTouched = true;
                        _droppedWalletName = null;
                      }),
              ),
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(
            hint,
            key: const Key('tx-payment-hint'),
            style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
          ),
        ],
        if (mainMissing) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '«نقدًا» لا يحمل عملة $_currency.',
                  key: const Key('tx-main-missing-currency'),
                  style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
                ),
              ),
              TextButton(
                key: const Key('tx-add-currency-to-main'),
                onPressed: _saving
                    ? null
                    : () => _addCurrencyToWallet(main!.wallet),
                child: Text('إضافة $_currency إلى الصندوق'),
              ),
            ],
          ),
        ],
        if (_walletId != null) ...[
          const SizedBox(height: 12),
          SegmentedButton<WalletBalanceEffect>(
            key: const Key('tx-wallet-effect'),
            showSelectedIcon: false,
            segments: [
              for (final effect in WalletBalanceEffect.values)
                ButtonSegment(
                  value: effect,
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(walletEffectLabel(effect)),
                  ),
                ),
            ],
            selected: {_walletEffect},
            onSelectionChanged: _saving
                ? null
                : (selection) => setState(() {
                    _walletEffect = selection.single;
                    _effectTouched = true;
                  }),
          ),
        ],
      ],
    );
  }

  Widget _attachmentsSection(BuildContext context) {
    final visibleExisting = [
      for (final attachment in _existing)
        if (!_removed.contains(attachment.id)) attachment,
    ];
    return Column(
      key: const Key('tx-attachments'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'المرفقات',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            TextButton.icon(
              key: const Key('add-attachment'),
              onPressed: _saving || _picking ? null : _chooseSource,
              icon: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: const Text('إضافة مرفق'),
            ),
          ],
        ),
        if (visibleExisting.isEmpty && _pending.isEmpty)
          Text(
            'صورة أو إيصال أو سند أو فاتورة أو PDF.',
            style: TextStyle(color: context.jibiMuted, fontSize: 12.5),
          ),
        for (final attachment in visibleExisting)
          ListTile(
            key: Key('existing-${attachment.id}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              attachment.isImage ? Icons.image_outlined : Icons.attach_file,
            ),
            title: Text(attachment.fileName, overflow: TextOverflow.ellipsis),
            subtitle: Text(attachmentKindLabel(attachment.kind)),
            trailing: IconButton(
              tooltip: 'إزالة المرفق',
              icon: const Icon(Icons.close),
              onPressed: _saving
                  ? null
                  : () => setState(() => _removed.add(attachment.id)),
            ),
          ),
        for (var index = 0; index < _pending.length; index++)
          ListTile(
            key: Key('pending-$index'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _pending[index].request.mimeType.startsWith('image/')
                  ? Icons.image_outlined
                  : Icons.attach_file,
            ),
            title: Text('مرفق جديد (${_pending[index].request.originalExtension})'),
            subtitle: DropdownButton<BookAttachmentKind>(
              isDense: true,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              value: _pending[index].kind,
              items: [
                for (final kind in BookAttachmentKind.values)
                  DropdownMenuItem(
                    value: kind,
                    child: Text(attachmentKindLabel(kind)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (kind) {
                      if (kind != null) {
                        setState(() => _pending[index].kind = kind);
                      }
                    },
            ),
            trailing: IconButton(
              tooltip: 'إزالة المرفق',
              icon: const Icon(Icons.close),
              onPressed: _saving
                  ? null
                  : () {
                      final removed = _pending.removeAt(index);
                      _deleteQuietly(removed.request.sourceFile);
                      setState(() {});
                    },
            ),
          ),
      ],
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_typeReady) {
      _type =
          widget.transaction?.type ??
          widget.defaultType ??
          context.bookPrefs.defaultEntryType;
      _typeReady = true;
      _walletEffect =
          widget.transaction?.walletEffect ?? WalletBalanceEffect.forEntry(_type);
      _effectTouched = widget.transaction?.walletEffect != null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.transaction != null;
    final prefs = context.bookPrefs;
    final labels = prefs.labels;
    final localizations = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'تعديل العملية' : 'إضافة عملية')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              BookAvatar(name: widget.account.name, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.account.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
              if (editing)
                Text(
                  widget.transaction!.number,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(color: context.jibiMuted),
                ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('tx-amount'),
            controller: _amount,
            autofocus: !editing,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              ThousandsInputFormatter(fractionDigits: _fractionDigits),
            ],
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              labelText: 'المبلغ',
              suffixText: _currency,
            ),
          ),
          const SizedBox(height: 16),
          _currencySection(context),
          const SizedBox(height: 16),
          SegmentedButton<EntryType>(
            key: const Key('tx-type'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: EntryType.debit,
                icon: Icon(sideIcon(BalanceSide.debit)),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(labels.debitWithHint),
                ),
              ),
              ButtonSegment(
                value: EntryType.credit,
                icon: Icon(sideIcon(BalanceSide.credit)),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(labels.creditWithHint),
                ),
              ),
            ],
            selected: {_type},
            onSelectionChanged: _saving
                ? null
                : (selection) => setState(() {
                    _type = selection.single;
                    if (!_effectTouched) {
                      _walletEffect = WalletBalanceEffect.forEntry(_type);
                    }
                  }),
          ),
          const SizedBox(height: 20),
          _paymentSection(context),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('tx-date'),
                  onPressed: _saving ? null : _pickDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(prefs.date(BookTransaction.formatDate(_occurredAt))),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('tx-time'),
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
            key: const Key('tx-details'),
            controller: _details,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'التفاصيل'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('tx-notes'),
            controller: _notes,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'ملاحظات (اختياري)'),
          ),
          if (widget.book.attachments != null) ...[
            const SizedBox(height: 20),
            _attachmentsSection(context),
          ],
          const SizedBox(height: 24),
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

class _PendingAttachment {
  _PendingAttachment(this.request, this.kind);

  final FileImportRequest request;
  BookAttachmentKind kind;
}
