"""Procedural pixel font.

Builds a 5x7 bitmap font for printable ASCII and writes it as an AngelCode BMFont
(.fnt + PNG atlas), which Godot 4 imports natively as a FontFile.

WHY A BITMAP FONT
-----------------
The UI was falling back to the engine's vector font, which is a proportional
anti-aliased typeface: at 11 px it looks nothing like the pixel art and, more
practically, it is unreadable when the whole screen is rendered at 1:1 pixels.

WHY HAND-WRITTEN GLYPHS
-----------------------
Deriving the shapes from a system TTF would mean thresholding an anti-aliased
raster, and the result is soft, uneven and font-dependent. A 5x7 matrix written out
by hand is exact, reproducible on any machine, and the shapes are legible at the
size the game actually draws them.

Chinese text is not covered -- 95 glyphs of Latin is the whole point of a bitmap
font at this size. The font is registered with the engine font as a fallback, so
CJK characters still render.

Usage:
    python tools/gen_font.py
"""

import os
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_sprites import Canvas  # noqa: E402

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "assets", "fonts")

CELL_W, CELL_H = 6, 9      # glyph cell: 5x7 of ink plus spacing
ATLAS_COLS = 16
GLYPH_W, GLYPH_H = 5, 7
ASCENT = 8                 # baseline row; glyphs occupy rows 1..7 above it
LINE_HEIGHT = 11
DESIGN_SIZE = 11           # matches the theme's default font size, so it draws 1:1

FG = (232, 230, 224, 255)

# ---------------------------------------------------------------------------
# Glyphs. '# ' is ink, '.' is empty; each entry is 7 rows of 5 separated by '|'.
# ---------------------------------------------------------------------------
GLYPHS = {
    ' ': ".....|.....|.....|.....|.....|.....|.....",
    '!': "..#..|..#..|..#..|..#..|..#..|.....|..#..",
    '"': ".#.#.|.#.#.|.....|.....|.....|.....|.....",
    '#': ".#.#.|#####|.#.#.|#####|.#.#.|.....|.....",
    '$': "..#..|.####|#.#..|.###.|..#.#|####.|..#..",
    '%': "##..#|##.#.|...#.|..#..|.##..|#..##|#..##",
    '&': ".##..|#..#.|#.#..|.#...|#.#.#|#..#.|.##.#",
    "'": "..#..|..#..|.....|.....|.....|.....|.....",
    '(': "...#.|..#..|.#...|.#...|.#...|..#..|...#.",
    ')': ".#...|..#..|...#.|...#.|...#.|..#..|.#...",
    '*': ".....|#.#.#|.###.|#####|.###.|#.#.#|.....",
    '+': ".....|..#..|..#..|#####|..#..|..#..|.....",
    ',': ".....|.....|.....|.....|..#..|..#..|.#...",
    '-': ".....|.....|.....|#####|.....|.....|.....",
    '.': ".....|.....|.....|.....|.....|.##..|.##..",
    '/': "....#|...#.|...#.|..#..|.#...|.#...|#....",
    '0': ".###.|#...#|#..##|#.#.#|##..#|#...#|.###.",
    '1': "..#..|.##..|..#..|..#..|..#..|..#..|.###.",
    '2': ".###.|#...#|....#|...#.|..#..|.#...|#####",
    '3': "#####|...#.|..#..|...#.|....#|#...#|.###.",
    '4': "...#.|..##.|.#.#.|#..#.|#####|...#.|...#.",
    '5': "#####|#....|####.|....#|....#|#...#|.###.",
    '6': "..##.|.#...|#....|####.|#...#|#...#|.###.",
    '7': "#####|....#|...#.|..#..|.#...|.#...|.#...",
    '8': ".###.|#...#|#...#|.###.|#...#|#...#|.###.",
    '9': ".###.|#...#|#...#|.####|....#|...#.|.##..",
    ':': ".....|.##..|.##..|.....|.##..|.##..|.....",
    ';': ".....|.##..|.##..|.....|.##..|..#..|.#...",
    '<': "...#.|..#..|.#...|#....|.#...|..#..|...#.",
    '=': ".....|.....|#####|.....|#####|.....|.....",
    '>': ".#...|..#..|...#.|....#|...#.|..#..|.#...",
    '?': ".###.|#...#|....#|...#.|..#..|.....|..#..",
    '@': ".###.|#...#|#.###|#.#.#|#.###|#....|.###.",
    'A': ".###.|#...#|#...#|#####|#...#|#...#|#...#",
    'B': "####.|#...#|#...#|####.|#...#|#...#|####.",
    'C': ".###.|#...#|#....|#....|#....|#...#|.###.",
    'D': "####.|#...#|#...#|#...#|#...#|#...#|####.",
    'E': "#####|#....|#....|####.|#....|#....|#####",
    'F': "#####|#....|#....|####.|#....|#....|#....",
    'G': ".###.|#...#|#....|#.###|#...#|#...#|.###.",
    'H': "#...#|#...#|#...#|#####|#...#|#...#|#...#",
    'I': ".###.|..#..|..#..|..#..|..#..|..#..|.###.",
    'J': "..###|...#.|...#.|...#.|...#.|#..#.|.##..",
    'K': "#...#|#..#.|#.#..|##...|#.#..|#..#.|#...#",
    'L': "#....|#....|#....|#....|#....|#....|#####",
    'M': "#...#|##.##|#.#.#|#.#.#|#...#|#...#|#...#",
    'N': "#...#|##..#|#.#.#|#..##|#...#|#...#|#...#",
    'O': ".###.|#...#|#...#|#...#|#...#|#...#|.###.",
    'P': "####.|#...#|#...#|####.|#....|#....|#....",
    'Q': ".###.|#...#|#...#|#...#|#.#.#|#..#.|.##.#",
    'R': "####.|#...#|#...#|####.|#.#..|#..#.|#...#",
    'S': ".####|#....|#....|.###.|....#|....#|####.",
    'T': "#####|..#..|..#..|..#..|..#..|..#..|..#..",
    'U': "#...#|#...#|#...#|#...#|#...#|#...#|.###.",
    'V': "#...#|#...#|#...#|#...#|#...#|.#.#.|..#..",
    'W': "#...#|#...#|#...#|#.#.#|#.#.#|##.##|#...#",
    'X': "#...#|#...#|.#.#.|..#..|.#.#.|#...#|#...#",
    'Y': "#...#|#...#|.#.#.|..#..|..#..|..#..|..#..",
    'Z': "#####|....#|...#.|..#..|.#...|#....|#####",
    '[': "..###|..#..|..#..|..#..|..#..|..#..|..###",
    '\\': "#....|.#...|.#...|..#..|...#.|...#.|....#",
    ']': "###..|..#..|..#..|..#..|..#..|..#..|###..",
    '^': "..#..|.#.#.|#...#|.....|.....|.....|.....",
    '_': ".....|.....|.....|.....|.....|.....|#####",
    '`': ".#...|..#..|.....|.....|.....|.....|.....",
    'a': ".....|.....|.###.|....#|.####|#...#|.####",
    'b': "#....|#....|####.|#...#|#...#|#...#|####.",
    'c': ".....|.....|.###.|#....|#....|#....|.###.",
    'd': "....#|....#|.####|#...#|#...#|#...#|.####",
    'e': ".....|.....|.###.|#...#|#####|#....|.###.",
    'f': "..##.|.#...|.#...|####.|.#...|.#...|.#...",
    'g': ".....|.####|#...#|#...#|.####|....#|.###.",
    'h': "#....|#....|####.|#...#|#...#|#...#|#...#",
    'i': "..#..|.....|.##..|..#..|..#..|..#..|.###.",
    'j': "...#.|.....|..##.|...#.|...#.|#..#.|.##..",
    'k': "#....|#....|#..#.|#.#..|##...|#.#..|#..#.",
    'l': ".##..|..#..|..#..|..#..|..#..|..#..|.###.",
    'm': ".....|.....|##.#.|#.#.#|#.#.#|#.#.#|#...#",
    'n': ".....|.....|####.|#...#|#...#|#...#|#...#",
    'o': ".....|.....|.###.|#...#|#...#|#...#|.###.",
    'p': ".....|####.|#...#|#...#|####.|#....|#....",
    'q': ".....|.####|#...#|#...#|.####|....#|....#",
    'r': ".....|.....|#.##.|##...|#....|#....|#....",
    's': ".....|.....|.####|#....|.###.|....#|####.",
    't': ".#...|.#...|####.|.#...|.#...|.#...|..##.",
    'u': ".....|.....|#...#|#...#|#...#|#..##|.##.#",
    'v': ".....|.....|#...#|#...#|#...#|.#.#.|..#..",
    'w': ".....|.....|#...#|#...#|#.#.#|#.#.#|.#.#.",
    'x': ".....|.....|#...#|.#.#.|..#..|.#.#.|#...#",
    'y': ".....|#...#|#...#|#...#|.####|....#|.###.",
    'z': ".....|.....|#####|...#.|..#..|.#...|#####",
    '{': "...##|..#..|..#..|.#...|..#..|..#..|...##",
    '|': "..#..|..#..|..#..|..#..|..#..|..#..|..#..",
    '}': "##...|..#..|..#..|...#.|..#..|..#..|##...",
    '~': ".....|.....|.#..#|#.#.#|#..#.|.....|.....",
}


def build_atlas(chars):
    rows = (len(chars) + ATLAS_COLS - 1) // ATLAS_COLS
    atlas = Canvas(ATLAS_COLS * CELL_W, rows * CELL_H)
    metrics = {}
    for i, ch in enumerate(chars):
        cx = (i % ATLAS_COLS) * CELL_W
        cy = (i // ATLAS_COLS) * CELL_H
        art = GLYPHS[ch].split('|')
        if len(art) != GLYPH_H:
            raise ValueError("glyph %r has %d rows, expected %d" % (ch, len(art), GLYPH_H))
        for y, row in enumerate(art):
            if len(row) != GLYPH_W:
                raise ValueError("glyph %r row %d is %d wide, expected %d"
                                 % (ch, y, len(row), GLYPH_W))
            for x, c in enumerate(row):
                if c == '#':
                    atlas.set(cx + x, cy + 1 + y, FG)
        metrics[ch] = {"x": cx, "y": cy + 1, "w": GLYPH_W, "h": GLYPH_H}
    return atlas, metrics, rows


def write_fnt(path, chars, metrics, atlas_w, atlas_h):
    lines = [
        'info face="2DDBD Pixel" size=%d bold=0 italic=0 charset="" unicode=1 '
        'stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=0,0 outline=0'
        % DESIGN_SIZE,
        'common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0 '
        'alphaChnl=0 redChnl=0 greenChnl=0 blueChnl=0'
        % (LINE_HEIGHT, ASCENT, atlas_w, atlas_h),
        'page id=0 file="pixel_font.png"',
        'chars count=%d' % len(chars),
    ]
    for ch in chars:
        m = metrics[ch]
        # xadvance 6 = 5 px of glyph plus one column of tracking.
        lines.append('char id=%d x=%d y=%d width=%d height=%d xoffset=0 yoffset=1 '
                     'xadvance=6 page=0 chnl=15'
                     % (ord(ch), m["x"], m["y"], m["w"], m["h"]))
    open(path, 'w', encoding='ascii', newline='\n').write('\n'.join(lines) + '\n')


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    chars = [chr(c) for c in range(32, 127)]
    missing = [c for c in chars if c not in GLYPHS]
    if missing:
        raise SystemExit("missing glyphs: %r" % missing)

    atlas, metrics, rows = build_atlas(chars)
    png_path = os.path.join(OUT_DIR, "pixel_font.png")
    fnt_path = os.path.join(OUT_DIR, "pixel_font.fnt")

    open(png_path, 'wb').write(atlas.to_png())
    write_fnt(fnt_path, chars, metrics, atlas.w, atlas.h)

    print("[gen_font] %d glyphs, atlas %dx%d (%d rows)"
          % (len(chars), atlas.w, atlas.h, rows))
    print("[gen_font] wrote %s" % png_path)
    print("[gen_font] wrote %s" % fnt_path)


if __name__ == '__main__':
    main()
