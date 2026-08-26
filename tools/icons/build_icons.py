#!/usr/bin/env python3
"""Rebuild Resources/*.tga from Phosphor Icons.

    python3 tools/icons/build_icons.py

Downloads the source SVGs from the Phosphor repo, rasterises them with
rsvg-convert and writes the TGA header by hand, so the output matches what the
LOTRO client expects: image type 2 (uncompressed true-colour), 32 bpp,
descriptor 0x28 (8 alpha bits + top-left origin), BGRA pixels top row first.

Same pipeline as LootLogs' docs/icons/build_icons.py and Gibberish3's own
RESOURCES/ (see ICONS.md in this folder) -- all three plugins now draw their
window chrome from the same icon language.

Glyphs are white on transparent -- the UI tints them by drawing with
BlendMode.Overlay over a themed ground, so the colour must not be baked in.

Needs: rsvg-convert (librsvg), Pillow, network access.
"""

import struct
import subprocess
import tempfile
import urllib.request
from pathlib import Path

from PIL import Image

REPO = "https://raw.githubusercontent.com/phosphor-icons/core/main/assets"
OUT = Path(__file__).resolve().parents[2] / "Resources"
TMP = Path(tempfile.mkdtemp(prefix="redbook-icons-"))

WHITE = (255, 255, 255)


def render(weight, name, size, color):
    """Fetch one Phosphor icon and rasterise it at `size` px in `color`."""
    stem = name if weight == "regular" else f"{name}-{weight}"
    svg = urllib.request.urlopen(f"{REPO}/{weight}/{stem}.svg").read().decode()

    src = TMP / f"{stem}.svg"
    src.write_text(svg.replace("currentColor", "#ffffff"))
    png = TMP / f"{stem}-{size}.png"
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), str(src), "-o", str(png)],
        check=True,
    )

    img = Image.open(png).convert("RGBA")
    flat = Image.new("RGBA", img.size, color + (255,))
    flat.putalpha(img.getchannel("A"))
    return flat


def write_tga(img, filename):
    img = img.convert("RGBA")
    width, height = img.size
    header = struct.pack(
        "<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 0x28
    )
    body = bytearray()
    for r, g, b, a in img.getdata():
        body += bytes((b, g, r, a))
    (OUT / filename).write_bytes(header + bytes(body))
    print(f"{filename:20} {width}x{height}")


# UI glyphs -- regular weight, matching Gibberish3/LootLogs. At 16px a regular
# stroke is exactly 1px and lands on the pixel grid, where bold blurs.
#
# Sizes are NOT free: Turbine clips a .tga to the control instead of scaling it
# (unless SetStretchMode is set), so each file must be exactly as big as the
# control that draws it. 16px matches Frame's close button and the search box's
# icons; 12px matches the session rail's pin marker.
write_tga(render("regular", "x", 16, WHITE), "cross.tga")
write_tga(render("regular", "magnifying-glass", 16, WHITE), "search.tga")
write_tga(render("fill", "push-pin-simple", 12, WHITE), "pin_on.tga")
write_tga(render("regular", "push-pin-simple", 12, WHITE), "pin_off.tga")
