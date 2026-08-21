# Icons

Every icon in this folder is derived from [Phosphor Icons](https://phosphoricons.com)
([phosphor-icons/core](https://github.com/phosphor-icons/core)), which is MIT licensed:

> MIT License
>
> Copyright (c) 2023 Phosphor Icons
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## What is what

| File | Phosphor icon | Weight | Size | Colour | Used by |
| --- | --- | --- | --- | --- | --- |
| `cross.tga` | `x` | regular | 16x16 | white | `UI/Frame.lua` window close button; `UI/Analysis.lua` search box clear glyph |
| `search.tga` | `magnifying-glass` | regular | 16x16 | white | `UI/Analysis.lua` search box, left of the text field |
| `pin_on.tga` | `push-pin-simple` | fill | 12x12 | white | `UI/Analysis.lua` session rail, pinned session |
| `pin_off.tga` | `push-pin-simple` | regular | 12x12 | white | `UI/Analysis.lua` session rail, unpinned session |

**Regular weight** (fill only for the "on" state of a two-state glyph), matching Gibberish3's and
LootLogs' own `RESOURCES`/`Ressources` -- all three plugins now share one window language. At 16px
a Phosphor regular stroke is exactly 1px and lands on the pixel grid, where bold lands on 1.5px
and blurs.

`pin_on.tga`/`pin_off.tga` replace the session rail's plain filled/dim square (see `CLAUDE.md`'s
"Build status" -- the mockup's Unicode pin diamonds, U+25C6/U+25C7, don't exist in this client's
fonts and rendered as `?`). A real pin glyph sidesteps that the same way Gibberish3's own
`OPTIONS2/WINDOW/LIBRARY/LibraryItem.lua` pin toggle does: two full white-on-transparent icons
swapped by state, `BlendMode.Overlay` over the row's own themed fill, no colour baked into the
asset and no font glyph involved.

**Sizes are not free.** Turbine clips a `.tga` to the control instead of scaling it, unless the
control sets `SetStretchMode`. Every file above is exactly the size of the control that draws it.

**Glyphs are white on transparent.** The UI tints them by drawing with `BlendMode.Overlay` over a
themed ground, so the colour must not be baked in.

## Format

The LOTRO client wants uncompressed 32-bit TGA. All files here are image type 2, 32 bpp,
descriptor `0x28` (8 alpha bits, top-left origin), BGRA, top row first.

## Rebuilding

    python3 tools/icons/build_icons.py

Downloads the SVGs, rasterises them and writes the TGA headers by hand. Needs `rsvg-convert`
(librsvg), Pillow and network access. Change the sizes, weights or icon names in that script
rather than editing the TGAs.
