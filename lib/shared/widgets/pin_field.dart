import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A PIN text field with an eye button that shows or hides the digits, so the
/// person can check what they typed. It always starts hidden.
class PinField extends StatefulWidget {
  const PinField({
    super.key,
    required this.controller,
    required this.label,
    this.autofocus = false,
    this.errorText,
    this.hintText,
    this.maxLength,
    this.textInputAction,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final String? errorText;
  final String? hintText;
  final int? maxLength;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PinField> createState() => _PinFieldState();
}

class _PinFieldState extends State<PinField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    autofocus: widget.autofocus,
    obscureText: !_visible,
    autocorrect: false,
    enableSuggestions: false,
    keyboardType: TextInputType.number,
    textInputAction: widget.textInputAction,
    maxLength: widget.maxLength,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    onSubmitted: widget.onSubmitted,
    decoration: InputDecoration(
      labelText: widget.label,
      hintText: widget.hintText,
      errorText: widget.errorText,
      counterText: widget.maxLength == null ? null : '',
      suffixIcon: IconButton(
        key: const Key('pin-field-eye'),
        tooltip: _visible ? 'إخفاء الرمز' : 'إظهار الرمز',
        icon: Icon(
          _visible
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
        ),
        onPressed: () => setState(() => _visible = !_visible),
      ),
    ),
  );
}
