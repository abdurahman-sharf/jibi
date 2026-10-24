import '../../../core/models/models.dart';
import '../../../shared/formatting/money_format.dart';
import 'book_labels.dart';
import 'book_preferences.dart';

/// What kind of change an audit entry is, for choosing its icon.
enum BookAuditKind { created, edited, deleted, restored, attachment, status }

/// An audit entry put into words (المتطلب 68): "تم تعديل مبلغ العملية...".
final class BookAuditDescription {
  const BookAuditDescription({
    required this.kind,
    required this.title,
    this.detail,
  });

  final BookAuditKind kind;
  final String title;

  /// A second line: the amounts, dates or names involved.
  final String? detail;
}

/// Writes audit entries the way the screens word things: the side names and
/// the date format follow the user's settings, and amounts use the decimals of
/// the account's currency.
final class BookAuditText {
  const BookAuditText({required this.preferences, required this.currencies});

  final BookPreferences preferences;
  final CurrencyRegistry currencies;

  BookLabels get _labels => preferences.labels;

  BookAuditDescription describe(BookAuditEntry entry) => switch (entry.entity) {
    BookAuditEntity.transaction => _transaction(entry),
    BookAuditEntity.account => _account(entry),
    BookAuditEntity.category => _category(entry),
    BookAuditEntity.wallet => _wallet(entry),
  };

  String _money(int minor, String? currencyCode) {
    var digits = 2;
    if (currencyCode != null) {
      try {
        digits = currencies.byCode(currencyCode).fractionDigits;
      } on Object {
        // An unknown currency is shown with the common two decimals.
      }
    }
    final text = formatMinorGrouped(minor, digits);
    return currencyCode == null ? text : '$text $currencyCode';
  }

  /// The two sides of `a->b`, or null when [details] is not of that form.
  static (String, String)? _arrow(String? details) {
    final parts = details?.split('->');
    if (parts == null || parts.length != 2) return null;
    return (parts[0], parts[1]);
  }

  /// `30000 SAR` -> (30000, SAR); `30000` -> (30000, null).
  static (int, String?)? _amountAndCurrency(String value) {
    final parts = value.trim().split(' ');
    final amount = int.tryParse(parts.first);
    if (amount == null) return null;
    return (amount, parts.length > 1 ? parts[1] : null);
  }

  EntryType? _type(String value) {
    for (final type in EntryType.values) {
      if (type.dbValue == value) return type;
    }
    return null;
  }

  String _dateTime(String value) {
    final parts = value.trim().split(' ');
    final date = preferences.date(parts.first);
    return parts.length > 1 ? '$date ${parts[1]}' : date;
  }

  BookAuditDescription _transaction(BookAuditEntry entry) {
    // "TX-000001 DEBIT 30000" / "TX-000001 30000" are what the writer keeps;
    // the live number wins when the transaction can still be found.
    final words = entry.details?.split(' ') ?? const <String>[];
    final number =
        entry.transactionNumber ??
        (words.isNotEmpty && words.first.startsWith('TX-') ? words.first : null);
    final named = number == null ? 'العملية' : 'العملية $number';
    // The currency belongs to the transaction: the writer records it in the
    // details (`TX-000001 DEBIT 30000 SAR`), the live row is the fallback.
    var currency = entry.currencyCode;
    switch (entry.action) {
      case 'created':
        final type = words.length > 1 ? _type(words[1]) : null;
        final amount = words.length > 2 ? int.tryParse(words[2]) : null;
        if (words.length > 3) currency = words[3];
        return BookAuditDescription(
          kind: BookAuditKind.created,
          title: 'تم إنشاء $named',
          detail: type == null || amount == null
              ? null
              : '${_labels.entry(type)} ${_money(amount, currency)}',
        );
      case 'currency_changed':
        final change = _arrow(entry.details);
        final from = change == null ? null : _amountAndCurrency(change.$1);
        final to = change == null ? null : _amountAndCurrency(change.$2);
        return BookAuditDescription(
          kind: BookAuditKind.edited,
          title: 'تم تغيير عملة $named',
          detail: from == null || to == null
              ? null
              : 'من ${_money(from.$1, from.$2)} إلى ${_money(to.$1, to.$2)}',
        );
      case 'amount_changed':
        final change = _arrow(entry.details);
        final from = change == null ? null : int.tryParse(change.$1);
        final to = change == null ? null : int.tryParse(change.$2);
        return BookAuditDescription(
          kind: BookAuditKind.edited,
          title: 'تم تعديل مبلغ $named',
          detail: from == null || to == null
              ? null
              : 'من ${_money(from, currency)} إلى ${_money(to, currency)}',
        );
      case 'date_changed':
        final change = _arrow(entry.details);
        return BookAuditDescription(
          kind: BookAuditKind.edited,
          title: 'تم تعديل تاريخ $named',
          detail: change == null
              ? null
              : 'من ${_dateTime(change.$1)} إلى ${_dateTime(change.$2)}',
        );
      case 'type_changed':
        final change = _arrow(entry.details);
        final from = change == null ? null : _type(change.$1);
        final to = change == null ? null : _type(change.$2);
        return BookAuditDescription(
          kind: BookAuditKind.edited,
          title: from == null || to == null
              ? 'تم تغيير نوع $named'
              : 'تم تغيير $named من ${_labels.entry(from)} إلى ${_labels.entry(to)}',
        );
      case 'updated':
        return BookAuditDescription(
          kind: BookAuditKind.edited,
          title: 'تم تعديل تفاصيل $named',
        );
      case 'deleted':
        final amount = words.length > 1 ? int.tryParse(words[1]) : null;
        if (words.length > 2) currency = words[2];
        return BookAuditDescription(
          kind: BookAuditKind.deleted,
          title: 'تم حذف $named',
          detail: amount == null ? null : _money(amount, currency),
        );
      case 'restored':
        return BookAuditDescription(
          kind: BookAuditKind.restored,
          title: 'تم استرجاع $named',
        );
      case 'attachment_added':
        return BookAuditDescription(
          kind: BookAuditKind.attachment,
          title: 'أُضيف مرفق إلى $named',
          detail: entry.details,
        );
      case 'attachment_removed':
        return BookAuditDescription(
          kind: BookAuditKind.attachment,
          title: 'حُذف مرفق من $named',
          detail: entry.details,
        );
    }
    return BookAuditDescription(
      kind: BookAuditKind.edited,
      title: 'تعديل على $named',
    );
  }

  BookAuditDescription _account(BookAuditEntry entry) {
    final name = entry.accountName ?? entry.details;
    final named = name == null ? 'الحساب' : 'الحساب $name';
    switch (entry.action) {
      case 'created':
        return BookAuditDescription(
          kind: BookAuditKind.created,
          title: 'تم إنشاء $named',
        );
      case 'updated':
        return BookAuditDescription(
          kind: BookAuditKind.edited,
          title: 'تم تعديل $named',
        );
      case 'deleted':
        return BookAuditDescription(
          kind: BookAuditKind.deleted,
          title: 'تم حذف $named',
        );
      case 'opening_changed':
        // `SAR DEBIT:1000->CREDIT:200`: one currency's opening balance.
        final parts = entry.details?.split(' ');
        final code = parts != null && parts.length == 2 ? parts[0] : null;
        final change = _arrow(parts != null && parts.length == 2 ? parts[1] : null);
        String? side(String value) {
          final pair = value.split(':');
          final type = pair.length == 2 ? _type(pair[0]) : null;
          final amount = pair.length == 2 ? int.tryParse(pair[1]) : null;
          if (amount == null) return null;
          if (amount == 0) return 'صفر';
          return type == null ? null : '${_labels.entry(type)} ${_money(amount, code)}';
        }
        final from = change == null ? null : side(change.$1);
        final to = change == null ? null : side(change.$2);
        return BookAuditDescription(
          kind: BookAuditKind.edited,
          title: 'تم تعديل الرصيد الافتتاحي في $named',
          detail: from == null || to == null ? null : 'من $from إلى $to',
        );
      case 'status':
        final title = switch (entry.details) {
          'active' => 'تم تفعيل $named',
          'suspended' => 'تم إيقاف $named',
          'archived' => 'تمت أرشفة $named',
          _ => 'تغيرت حالة $named',
        };
        return BookAuditDescription(kind: BookAuditKind.status, title: title);
    }
    return BookAuditDescription(
      kind: BookAuditKind.edited,
      title: 'تعديل على $named',
    );
  }

  BookAuditDescription _category(BookAuditEntry entry) {
    final name = entry.categoryName ?? entry.details;
    final named = name == null ? 'التصنيف' : 'التصنيف $name';
    return switch (entry.action) {
      'created' => BookAuditDescription(
        kind: BookAuditKind.created,
        title: 'تم إنشاء $named',
      ),
      'updated' => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'تم تعديل $named',
      ),
      'deleted' => BookAuditDescription(
        kind: BookAuditKind.deleted,
        title: 'تم حذف $named',
      ),
      'activated' => BookAuditDescription(
        kind: BookAuditKind.status,
        title: 'تم تفعيل $named',
      ),
      'deactivated' => BookAuditDescription(
        kind: BookAuditKind.status,
        title: 'تم إيقاف $named',
      ),
      'archived' => BookAuditDescription(
        kind: BookAuditKind.status,
        title: 'تمت أرشفة $named',
      ),
      'unarchived' => BookAuditDescription(
        kind: BookAuditKind.status,
        title: 'أُلغيت أرشفة $named',
      ),
      _ => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'تعديل على $named',
      ),
    };
  }

  BookAuditDescription _wallet(BookAuditEntry entry) {
    final name = entry.details;
    final named = name == null ? 'المحفظة' : 'المحفظة $name';
    return switch (entry.action) {
      'created' => BookAuditDescription(
        kind: BookAuditKind.created,
        title: 'تم إنشاء $named',
      ),
      'updated' => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'تم تعديل $named',
      ),
      'deleted' => BookAuditDescription(
        kind: BookAuditKind.deleted,
        title: 'تم حذف $named',
      ),
      'status' => BookAuditDescription(
        kind: BookAuditKind.status,
        title: 'تغيرت حالة $named',
      ),
      'set_main' => BookAuditDescription(
        kind: BookAuditKind.status,
        title: name == null
            ? 'تعيين محفظة رئيسية جديدة'
            : 'أصبحت $name المحفظة الرئيسية',
      ),
      'deposited' => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'إيداع في $named',
      ),
      'withdrawn' => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'سحب من $named',
      ),
      'transferred_out' => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'تحويل من $named',
      ),
      'transferred_in' => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'تحويل إلى $named',
      ),
      'exchanged_out' => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'صرف من $named',
      ),
      'exchanged_in' => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'صرف إلى $named',
      ),
      'movement_deleted' => BookAuditDescription(
        kind: BookAuditKind.deleted,
        title: 'حذف حركة من $named',
      ),
      'movement_restored' => BookAuditDescription(
        kind: BookAuditKind.restored,
        title: 'استرجاع حركة في $named',
      ),
      _ => BookAuditDescription(
        kind: BookAuditKind.edited,
        title: 'تعديل على $named',
      ),
    };
  }
}
