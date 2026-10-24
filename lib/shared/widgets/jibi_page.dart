import 'package:flutter/material.dart';

class JibiPage extends StatelessWidget {
  const JibiPage({
    required this.child,
    super.key,
    this.padding = const EdgeInsetsDirectional.fromSTEB(20, 20, 20, 96),
    this.scrollable = true,
    this.maxContentWidth = 760,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool scrollable;
  final double maxContentWidth;

  @override
  Widget build(BuildContext context) {
    final content = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxContentWidth),
        child: Padding(padding: padding, child: child),
      ),
    );

    return SafeArea(
      top: false,
      child: scrollable
          ? SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: content,
            )
          : content,
    );
  }
}

class JibiSection extends StatelessWidget {
  const JibiSection({
    required this.title,
    required this.child,
    super.key,
    this.actionLabel,
    this.onAction,
    this.padding,
  }) : assert(actionLabel == null || onAction != null);

  final String title;
  final Widget child;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: padding ?? const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: textTheme.titleLarge)),
              if (actionLabel != null)
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
