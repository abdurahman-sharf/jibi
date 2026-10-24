import 'package:flutter/widgets.dart';

import '../../features/book/domain/book_preferences.dart';

/// Hands the display settings (side wording, date format, time, hidden
/// balances) to every accounts screen below it. A screen that reads them
/// rebuilds when the settings change; without a scope the standard wording is
/// used.
class BookPreferencesScope extends InheritedWidget {
  const BookPreferencesScope({
    required this.preferences,
    required super.child,
    super.key,
  });

  final BookPreferences preferences;

  static BookPreferences of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BookPreferencesScope>()
          ?.preferences ??
      BookPreferences.standard;

  @override
  bool updateShouldNotify(BookPreferencesScope oldWidget) =>
      oldWidget.preferences != preferences;
}

extension BookPreferencesContext on BuildContext {
  BookPreferences get bookPrefs => BookPreferencesScope.of(this);
}
