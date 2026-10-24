import 'package:flutter/widgets.dart';

/// Asks the user to authorise exporting or sharing financial data (the PIN
/// check). Returns true when the export may go ahead.
typedef ExportAuthorizer =
    Future<bool> Function(BuildContext context, {required String title});

/// Gives the book screens the application's export authorisation without
/// threading it through every constructor. Without a scope (standalone pages
/// in widget tests) export actions are simply not offered.
class BookExportScope extends InheritedWidget {
  const BookExportScope({
    required this.authorize,
    required super.child,
    super.key,
  });

  final ExportAuthorizer authorize;

  static ExportAuthorizer? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<BookExportScope>()
      ?.authorize;

  @override
  bool updateShouldNotify(BookExportScope oldWidget) =>
      authorize != oldWidget.authorize;
}
