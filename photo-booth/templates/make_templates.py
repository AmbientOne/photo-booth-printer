r"""
Generate overlay alignment templates for the 2x6 booth strip.

Produces a transparent PNG at the exact print size (1200x3600) with every photo
well outlined and labelled, so a designer can drop it over their artwork as a
layer and see immediately whether anything lands on a face.

The measurements are computed the same way the booth computes them, from the
same constants, so the templates cannot drift from what actually prints. If a
strip setting changes in index.html, change it here and regenerate.

Run:  py make_templates.py
"""

import os
from PIL import Image, ImageDraw, ImageFont

# ---- constants mirrored from photo-booth/index.html renderStrip() ----------

W, H = 1200, 3600            # exactly 2x6 inches at 600 dpi
K = W / 700.0                # the strip design is authored 700px wide
SAFE_FRACTION = 0.04

STRIP_PAD = 36               # CONFIG.stripPad
STRIP_GAP = 16               # CONFIG.stripGap

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# Prepress guide colours: magenta for cut/safe, cyan for content areas. Both
# read clearly over any artwork, which plain black does not.
MAGENTA = (236, 0, 140, 255)
CYAN = (0, 158, 224, 255)
CYAN_FILL = (0, 158, 224, 28)
GREY = (120, 120, 120, 200)


def layout(shots, has_logo, footer="full"):
    """Return the same geometry renderStrip() would produce."""
    safe = round(W * SAFE_FRACTION)
    pad = max(safe, round(STRIP_PAD * K))
    gap = round(STRIP_GAP * K)

    if footer == "none":
        footer_h = round(150 * K) if has_logo else safe
    elif footer == "compact":
        footer_h = round((230 if has_logo else 150) * K)
    else:
        footer_h = round((300 if has_logo else 230) * K)
    footer_h = max(footer_h, safe)

    photo_w = W - pad * 2
    photo_h = (H - pad - footer_h - (shots - 1) * gap) // shots

    wells = []
    y = pad
    for _ in range(shots):
        wells.append((pad, y, pad + photo_w, y + photo_h))
        y += photo_h + gap
    bottom = y - gap

    return {
        "safe": safe, "pad": pad, "gap": gap,
        "photo_w": photo_w, "photo_h": photo_h,
        "wells": wells, "footer_top": bottom,
    }


def font(size, bold=True):
    name = "arialbd.ttf" if bold else "arial.ttf"
    try:
        return ImageFont.truetype(name, size)
    except OSError:
        try:
            return ImageFont.truetype("DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf", size)
        except OSError:
            return ImageFont.load_default()


def centred(draw, text, cx, cy, f, fill):
    l, t, r, b = draw.textbbox((0, 0), text, font=f)
    draw.text((cx - (r - l) / 2 - l, cy - (b - t) / 2 - t), text, font=f, fill=fill)


def dashed_rect(draw, box, colour, width, dash=40, space=28):
    x0, y0, x1, y1 = box
    for x in range(int(x0), int(x1), dash + space):
        draw.line([(x, y0), (min(x + dash, x1), y0)], fill=colour, width=width)
        draw.line([(x, y1), (min(x + dash, x1), y1)], fill=colour, width=width)
    for y in range(int(y0), int(y1), dash + space):
        draw.line([(x0, y), (x0, min(y + dash, y1))], fill=colour, width=width)
        draw.line([(x1, y), (x1, min(y + dash, y1))], fill=colour, width=width)


def build(shots, has_logo):
    g = layout(shots, has_logo)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    f_big = font(62)
    f_mid = font(46)
    f_small = font(34, bold=False)

    # Trim edge and safe margin.
    d.rectangle([0, 0, W - 1, H - 1], outline=MAGENTA, width=4)
    dashed_rect(d, (g["safe"], g["safe"], W - g["safe"], H - g["safe"]), MAGENTA, 4)
    centred(d, "SAFE MARGIN %d px" % g["safe"], W / 2, g["safe"] / 2, f_small, MAGENTA)

    # Photo wells.
    for i, (x0, y0, x1, y1) in enumerate(g["wells"], start=1):
        d.rectangle([x0, y0, x1, y1], fill=CYAN_FILL, outline=CYAN, width=5)
        cy = (y0 + y1) / 2
        centred(d, "PLACE HERE", W / 2, cy - 46, f_big, CYAN)
        centred(d, "TO SEE IF IT'S CORRECT", W / 2, cy + 30, f_mid, CYAN)
        centred(d, "photo %d  -  %d x %d px" % (i, g["photo_w"], g["photo_h"]),
                W / 2, cy + 96, f_small, GREY)
        # Centre ticks on each edge, so artwork can be registered to the middle
        # of the well without measuring. Kept short so they read as marks.
        t = 26
        d.line([(W / 2, y0), (W / 2, y0 + t)], fill=CYAN, width=4)
        d.line([(W / 2, y1 - t), (W / 2, y1)], fill=CYAN, width=4)
        d.line([(x0, cy), (x0 + t, cy)], fill=CYAN, width=4)
        d.line([(x1 - t, cy), (x1, cy)], fill=CYAN, width=4)

    # Footer zone.
    ft = g["footer_top"]
    dashed_rect(d, (g["pad"], ft, W - g["pad"], H - g["safe"]), CYAN, 4)
    centred(d, "FOOTER  %d px tall" % (H - g["safe"] - ft), W / 2, ft + 60, f_mid, CYAN)
    if has_logo:
        centred(d, "logo sits here, max 110 px tall", W / 2, ft + 130, f_small, GREY)

    # Corner stamp.
    stamp = "%d SHOTS  |  %s  |  %d x %d px  |  2x6in @ 600dpi" % (
        shots, "WITH LOGO" if has_logo else "NO LOGO", W, H)
    centred(d, stamp, W / 2, H - g["safe"] / 2, f_small, MAGENTA)

    name = "strip-%dshot%s.png" % (shots, "-logo" if has_logo else "")
    path = os.path.join(OUT_DIR, name)
    img.save(path)
    print("  %-26s photo well %d x %d, footer %d" % (
        name, g["photo_w"], g["photo_h"], H - g["safe"] - ft))
    return path


if __name__ == "__main__":
    print("Writing templates to %s" % OUT_DIR)
    for shots in (3, 4):
        for has_logo in (False, True):
            build(shots, has_logo)
    print("\nDrop one over your artwork as a layer. Anything covering the cyan")
    print("boxes will cover a guest's face; anything outside the magenta dashes")
    print("may be trimmed off by the cutter.")
