/// The accents a currency can wear on the home card and in the currency list.
///
/// Plain ARGB integers (no Flutter types) so the database migration and the
/// model layer can share them. The first three belong to the shipped
/// currencies: YER green, SAR gold, USD blue.
const List<int> currencyPalette = <int>[
  0xFF2E7D5B, // green
  0xFFC58F1B, // gold
  0xFF1E6FB8, // blue
  0xFF7B4FB8, // purple
  0xFF00838F, // teal
  0xFFC2445B, // rose
  0xFFD9661F, // orange
  0xFF3F51B5, // indigo
  0xFF8D5A3B, // brown
  0xFF546E7A, // slate
];

/// The colors the three shipped currencies start with.
const int yerCurrencyColor = 0xFF2E7D5B;
const int sarCurrencyColor = 0xFFC58F1B;
const int usdCurrencyColor = 0xFF1E6FB8;

/// A stable color for a currency the owner has not colored: derived from the
/// code, so it never changes when currencies are reordered or archived.
int automaticCurrencyColor(String code) {
  var hash = 0;
  for (final unit in code.toUpperCase().codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return currencyPalette[hash % currencyPalette.length];
}

/// The first palette color not in [taken], or the automatic one when the whole
/// palette is in use. Used to give a newly created currency its own color.
int nextFreeCurrencyColor(Iterable<int?> taken, String code) {
  final used = {for (final value in taken) ?value};
  for (final value in currencyPalette) {
    if (!used.contains(value)) return value;
  }
  return automaticCurrencyColor(code);
}
