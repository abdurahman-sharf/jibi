"""Builds every app icon from design/app_icon_source.png.

Run from the project root with:  py tool/make_app_icons.py
(needs Pillow: py -m pip install -r tool/requirements.txt)

The source is a black leather pocket (with a card, a page and a padlock) on a
transparent background. The launcher icons put it on a light mint tile, where
the black pocket stands out; the adaptive foreground keeps it inside the safe
zone so no launcher mask (circle, squircle, rounded square) cuts it.

Outputs: the Android launcher icons, the themed (monochrome) layer, the
notification icon, the launch picture, the in-app icon and the Google Play
store graphics (docs/release/assets).

Keep the tile colours in step with android/.../drawable/ic_launcher_background.xml
and values/colors.xml (launch_background_color).
"""
from PIL import Image, ImageDraw, ImageFilter
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = Image.open(os.path.join(ROOT, "design", "app_icon_source.png")).convert("RGBA")
# Crop to the artwork so the scale below is relative to the pocket itself. The
# source has a very faint halo, so the box comes from clearly visible pixels
# only; a plain getbbox() would include it and push the pocket off centre.
SRC = SRC.crop(SRC.getchannel("A").point(lambda v: 255 if v > 24 else 0).getbbox())
GREEN_TOP = (238, 247, 242)
GREEN_BOTTOM = (178, 214, 198)


def res(*parts):
    return os.path.join(ROOT, *parts)


def gradient(size):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(1, size - 1)
        c = tuple(int(GREEN_TOP[i] + (GREEN_BOTTOM[i] - GREEN_TOP[i]) * t) for i in range(3))
        d.line([(0, y), (size, y)], fill=c)
    return img.convert("RGBA")


def art(size, fraction):
    """The pocket scaled so its longest side is `fraction` of `size`, centred."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    scale = size * fraction / max(SRC.size)
    w, h = max(1, round(SRC.width * scale)), max(1, round(SRC.height * scale))
    piece = SRC.resize((w, h), Image.LANCZOS)
    layer.paste(piece, ((size - w) // 2, (size - h) // 2), piece)
    return layer


def rounded(img, radius_fraction):
    size = img.width
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * radius_fraction), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def circle(img):
    size = img.width
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def mono(layer):
    """White drawing for the themed icon: dark leather stays, light details go."""
    rgba = layer.copy()
    px = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            r, g, b, a = px[x, y]
            luminance = 0.299 * r + 0.587 * g + 0.114 * b
            # Fully kept below 150, fully cut above 195, soft in between. Leather
            # grain rarely gets that bright, so the body stays mostly solid.
            keep = 1.0 if luminance <= 150 else 0.0 if luminance >= 195 else (195 - luminance) / 45
            px[x, y] = (255, 255, 255, round(a * keep))
    return rgba


def silhouette(layer):
    """Solid white shape of the drawing: what a status-bar icon should be (fine
    details such as the padlock turn into noise at 24dp)."""
    rgba = Image.new("RGBA", layer.size, (255, 255, 255, 0))
    rgba.putalpha(layer.getchannel("A").point(lambda v: 255 if v > 24 else 0))
    return rgba


def full_bleed(size, fraction):
    base = gradient(size)
    base.alpha_composite(art(size, fraction))
    return base


def save(img, *parts, opaque=False):
    path = res(*parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if opaque:
        img = img.convert("RGB")
    img.save(path)


def hires(size, builder):
    """Draws at 4x and reduces, for smooth edges on small icons."""
    return builder(size * 4).resize((size, size), Image.LANCZOS)


# ---- Android ---------------------------------------------------------------
android = res("android", "app", "src", "main", "res")
LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
# 24dp status-bar icon (a notification icon must be white on transparent, or
# Android draws a solid white square).
NOTIFICATION = {"mdpi": 24, "hdpi": 36, "xhdpi": 48, "xxhdpi": 72, "xxxhdpi": 96}
for density, size in LEGACY.items():
    square = hires(size, lambda s: rounded(full_bleed(s, 0.74), 0.22))
    save(square, android, f"mipmap-{density}", "ic_launcher.png")
    round_icon = hires(size, lambda s: circle(full_bleed(s, 0.62)))
    save(round_icon, android, f"mipmap-{density}", "ic_launcher_round.png")
for density, size in ADAPTIVE.items():
    # 66dp of 108dp is the safe zone (a circle of radius 33dp). The pocket is
    # taller than wide, so its top corners are what reaches furthest: at 58% of
    # the canvas they sit about 32dp from the centre, inside the safe zone.
    save(hires(size, lambda s: art(s, 0.58)), android, f"mipmap-{density}", "ic_launcher_foreground.png")
    # Themed (monochrome) icon. Android paints only the alpha, so a plain
    # silhouette would be a blank block: the light parts (stitches, padlock,
    # rivets, chip, page) are cut out so the drawing still reads.
    save(hires(size, lambda s: mono(art(s, 0.58))), android, f"mipmap-{density}", "ic_launcher_monochrome.png")
for density, size in NOTIFICATION.items():
    save(hires(size, lambda s: silhouette(art(s, 0.86))), android, f"drawable-{density}", "ic_stat_jibi.png")
# Launch screen picture (pre Android 12): the pocket, about 130dp tall.
save(art(640, 0.81).resize((480, 480), Image.LANCZOS), android, "drawable-xxhdpi", "splash_wallet.png")

# ---- In-app picture ---------------------------------------------------------
# A whole tile, so the black pocket reads on the dark theme as well as the light.
save(hires(512, lambda s: rounded(full_bleed(s, 0.74), 0.22)), res("assets", "images"), "app_icon.png")

# ---- Google Play store graphics ----------------------------------------------
# The store icon must be a full-bleed square (Play rounds it itself), 512 px.
store = res("docs", "release", "assets")
save(hires(512, lambda s: full_bleed(s, 0.70)), store, "icon-512.png", opaque=True)
# Feature graphic 1024x500: a simple placeholder (the icon tile on the brand
# mint gradient). Replace it with a designed banner if you like.
banner = Image.new("RGBA", (1024, 500))
column = gradient(500).resize((1, 500))
for x in range(1024):
    banner.paste(column, (x, 0))
tile = hires(340, lambda s: rounded(full_bleed(s, 0.74), 0.22))
shadow = Image.new("RGBA", (420, 420), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((40, 56, 380, 396), radius=75, fill=(20, 60, 45, 70))
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
banner.alpha_composite(shadow, ((1024 - 420) // 2, (500 - 420) // 2))
banner.alpha_composite(tile, ((1024 - 340) // 2, (500 - 340) // 2))
save(banner, store, "feature-graphic-1024x500.png", opaque=True)
print("icons written")
