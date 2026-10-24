import 'package:flutter/material.dart';

/// Completes after the closing animation and removal of the dialog's overlay.
/// Callers may then safely dispose controllers used by the dialog.
Future<T?> showJibiDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(context: context, builder: builder);
  final result = await navigator.push<T>(route);
  await route.completed;
  return result;
}

/// Shows feedback from either a page state or a descendant of a Scaffold.
///
/// A State's context is above its page Scaffold, so calling
/// `ScaffoldMessenger.of(context)` directly from async callbacks can throw and
/// make a button appear to do nothing. Resolve the nearest messenger first and
/// fall back to the navigator's context.
void showJibiMessage(BuildContext context, String message) {
  final messenger =
      ScaffoldMessenger.maybeOf(context) ??
      ScaffoldMessenger.maybeOf(Navigator.maybeOf(context)?.context ?? context);
  messenger?.showSnackBar(SnackBar(content: Text(message)));
}

class JibiAmount extends StatelessWidget {
  const JibiAmount({
    required this.value,
    required this.currency,
    super.key,
    this.label,
    this.isNegative = false,
    this.style,
  });

  final String value;
  final String currency;
  final String? label;
  final bool isNegative;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final amountStyle =
        style ??
        Theme.of(context).textTheme.titleMedium!.copyWith(
          fontWeight: FontWeight.w700,
          color: isNegative ? colors.error : colors.primary,
        );
    final magnitude = isNegative && value.startsWith('-')
        ? value.substring(1)
        : value;
    final amount = '${isNegative ? '− ' : ''}$currency $magnitude';
    return Semantics(
      label: label == null ? amount : '$label: $amount',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            Text(label!, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
          ],
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(amount, style: amountStyle),
          ),
        ],
      ),
    );
  }
}

class JibiEmptyState extends StatelessWidget {
  const JibiEmptyState({
    required this.title,
    required this.message,
    super.key,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  }) : assert(actionLabel == null || onAction != null);

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => _JibiStateLayout(
    icon: icon,
    title: title,
    message: message,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

class JibiLoadingState extends StatelessWidget {
  const JibiLoadingState({super.key, this.message = 'جارٍ التحميل…'});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: message,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message),
        ],
      ),
    ),
  );
}

class JibiErrorState extends StatelessWidget {
  const JibiErrorState({
    required this.message,
    super.key,
    this.title = 'حدث خطأ',
    this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => _JibiStateLayout(
    icon: Icons.error_outline,
    title: title,
    message: message,
    actionLabel: onRetry == null ? null : 'إعادة المحاولة',
    onAction: onRetry,
    isError: true,
  );
}

class _JibiStateLayout extends StatelessWidget {
  const _JibiStateLayout({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.isError = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 48,
                color: isError ? colors.error : colors.primary,
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              if (actionLabel != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class JibiConfirmationDialog extends StatelessWidget {
  const JibiConfirmationDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    super.key,
    this.cancelLabel = 'إلغاء',
    this.isDestructive = false,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool isDestructive;

  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    String cancelLabel = 'إلغاء',
    bool isDestructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => JibiConfirmationDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        isDestructive: isDestructive,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: isDestructive
              ? FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
