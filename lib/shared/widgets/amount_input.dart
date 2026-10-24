/// Normalize keyboard-localized digits at the UI boundary only.
/// Group separators remain invalid to avoid ambiguous monetary values.
String normalizeAmountInput(String input) {
  return String.fromCharCodes(
    input.trim().runes.map((rune) {
      if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660 + 48;
      if (rune >= 0x06f0 && rune <= 0x06f9) return rune - 0x06f0 + 48;
      if (rune == 0x066b) return 46;
      return rune;
    }),
  );
}
