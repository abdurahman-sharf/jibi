"""Adds two missing code points to the bundled Tajawal fonts.

Why: the `pdf` package shapes Arabic through the `bidi` package, which writes an
isolated letter as its Arabic Presentation Forms-B code point. Tajawal has no
glyph mapped for the isolated forms; the package covers this with a table that
points each isolated code point at the base letter's glyph, but that table maps
YEH to U+FEEF (which is ALEF MAKSURA ISOLATED) instead of U+FEF1. The result is
that a yeh standing alone after a letter that does not join (the last letter of
"سعودي", "مهدي", "هادي") is not drawn, and an isolated alef maksura ("هدى")
is drawn with the dotted yeh glyph.

What: map U+FEF1 to the glyph of U+064A and U+FEEF to the glyph of U+0649 in
the fonts' own cmap. Nothing else in the fonts changes (SIL OFL 1.1 allows
modified versions; the fonts declare no Reserved Font Name).

Usage (needs `pip install fonttools`), from the project root:
    python tool/patch_tajawal_cmap.py
Running it twice is harmless.
"""

from fontTools.ttLib import TTFont

FONTS = ('assets/fonts/Tajawal-Regular.ttf', 'assets/fonts/Tajawal-Bold.ttf')
# presentation form -> base letter whose glyph it should use
ADDITIONS = {
    0xFEF1: 0x064A,  # YEH isolated -> YEH
    0xFEEF: 0x0649,  # ALEF MAKSURA isolated -> ALEF MAKSURA
}


def patch(path):
    font = TTFont(path)
    changed = False
    for table in font['cmap'].tables:
        if not table.isUnicode() or table.format not in (4, 12):
            continue
        for form, base in ADDITIONS.items():
            if form > 0xFFFF and table.format == 4:
                continue
            glyph = table.cmap.get(base)
            if glyph is None:
                raise SystemExit('%s has no glyph for U+%04X' % (path, base))
            if table.cmap.get(form) != glyph:
                table.cmap[form] = glyph
                changed = True
    if changed:
        font.save(path)
    print('%s: %s' % (path, 'patched' if changed else 'already patched'))


if __name__ == '__main__':
    for font_path in FONTS:
        patch(font_path)
