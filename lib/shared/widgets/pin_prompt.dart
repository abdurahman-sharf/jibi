import 'package:flutter/material.dart';

import 'jibi_feedback.dart';
import 'pin_field.dart';

/// Asks for the PIN in a dialog. Returns null when cancelled. The caller must
/// verify the PIN (for example with `SecurityService.verifyPin`).
Future<String?> askPinDialog(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final input = TextEditingController();
  try {
    return await showJibiDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
            PinField(
              key: const Key('pin-prompt-input'),
              controller: input,
              autofocus: true,
              label: 'رمز PIN',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
  } finally {
    WidgetsBinding.instance.addPostFrameCallback((_) => input.dispose());
  }
}
