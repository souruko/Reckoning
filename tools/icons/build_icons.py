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
TMP = Path(tempfile.mkdtemp(prefix="basil-icons-"))

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


def write_solid(width, height, filename):
    """A plain opaque white block -- not a Phosphor icon, and no network needed.

    `line.tga` is the polyline stroke sprite (UI/AnalysisGraph.lua, UI/RotationProbe.lua).
    It exists because the only production-proven SetRotation configuration anywhere --
    Gibberish3's circular timer, UI_ELEMENTS/TIMER/CIRCEL/Element.lua -- rotates a
    control that carries a BACKGROUND IMAGE, never one painted with SetBackColor alone;
    whether a bare back-colour fill rotates at all is exactly what /basil probe asks.

    Drawn with SetStretchMode(2) + SetBackColorBlendMode(Overlay) + SetBackColor, so the
    8x8 source scales to whatever the segment needs and takes the series colour. Fully
    opaque rather than soft-edged: at a 2px stroke a baked-in feathered edge would eat
    most of the line's own width.
    """
    header = struct.pack(
        "<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 0x28
    )
    body = bytes((255, 255, 255, 255)) * (width * height)  # BGRA
    (OUT / filename).write_bytes(header + bytes(body))
    print(f"{filename:20} {width}x{height}")


write_solid(8, 8, "line.tga")

# The stroke source the probe and (if rotation ever works) the plot actually draw from. 256x4
# rather than 8x8 because SetStretchMode has never been confirmed to scale a file-path .tga in
# this client -- Icon.Apply (Constants.lua) dropped it entirely in round 7 of the self-buff icon
# saga, and every icon this codebase renders successfully is drawn at its asset's native size.
# Without stretch Turbine CLIPS the image to the control, so one long white block crops down to
# any segment length for free, which is exactly what a uniform stroke wants.
write_solid(256, 4, "line_long.tga")


def write_wedge(size, filename):
    """A 36x36 asymmetric wedge (filled upper-left triangle), for /basil probe.

    Round three's rotation cells used a 16x16 lens glyph, which at that size is
    hard to judge at a glance. A big filled triangle is unmistakable at 45, 90
    and 180, and it is authored at exactly the control's size so the probe can
    reproduce Gibberish3's own configuration -- an image the same size as the
    control it fills -- rather than an approximation of it.
    """
    header = struct.pack(
        "<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x28
    )
    body = bytearray()
    for y in range(size):
        for x in range(size):
            body += bytes((255, 255, 255, 255)) if (x + y) < size else bytes((0, 0, 0, 0))
    (OUT / filename).write_bytes(header + bytes(body))
    print(f"{filename:20} {size}x{size}")


write_wedge(36, "wedge.tga")


def write_stroke(size, band, filename):
    """One rung of the polyline's stroke ladder: a square sprite with a
    full-width band through its centre, transparent elsewhere.

    SQUARE is load-bearing. The engine rotates a control's IMAGE and then fits
    the result to the control's rect (probe round five, cell E: a 64x16 wedge at
    90 came back still 64x16 with its content reoriented, not 16x64). A square
    control means that fit is a uniform scale, so a rotated line stays a
    straight line at the angle asked for; any other aspect ratio shears it.

    THE LADDER exists because the segment control is sized to the segment's own
    LENGTH, so the band -- a fraction of the sprite -- scales with it. One
    sprite gives a stroke proportional to length: ~1px on a flat second and
    ~6px on a steep spike, which is exactly what shipped and looked wrong.
    Instead there is a sprite per band width, and UI/AnalysisGraph.lua picks the
    rung whose `band * length / 64` lands nearest 2px. That holds the drawn
    stroke between about 1.7 and 2.2px across every length the plot produces.

    Alpha is the band's COVERAGE of each row, which is both the antialiasing and
    what lets a band be a fraction of a pixel wide -- the 1.5 rung is what keeps
    long segments near 2px, where whole-pixel bands can only manage 1.4 or 2.8.
    """
    lo, hi = size / 2.0 - band / 2.0, size / 2.0 + band / 2.0
    header = struct.pack(
        "<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x28
    )
    body = bytearray()
    for y in range(size):
        cover = max(0.0, min(hi, y + 1) - max(lo, y))
        body += bytes((255, 255, 255, int(round(255 * cover)))) * size
    (OUT / filename).write_bytes(header + bytes(body))
    print(f"{filename:20} {size}x{size} band {band}")


# Rungs, in band pixels. The names carry the band times ten, so the fractional
# rung has an honest filename. UI/AnalysisGraph.lua's STROKE_SPRITES must list
# the same set.
for _band in (1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0):
    write_stroke(64, _band, f"stroke_{int(round(_band * 10))}.tga")
