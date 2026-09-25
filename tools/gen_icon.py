#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
2DDBD -- application icon packer.

Godot's Windows exporter refuses a .svg or .png icon; it wants a real multi-size
.ico. This renders the same procedural hook sigil at several sizes and packs
them into an ICO container (PNG-compressed entries, supported by Windows Vista+),
so the exported exe shows a proper icon in Explorer and the taskbar.

Usage:
    python tools/gen_icon.py
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_sprites as gs  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZES = [16, 24, 32, 48, 64, 128, 256]


def render(size: int) -> "gs.Canvas":
    """Draw the sigil directly at the target size so it stays crisp."""
    return gs.make_app_icon(size)


def pack_ico(paths_by_size) -> bytes:
    entries = []
    images = []
    offset = 6 + 16 * len(paths_by_size)

    for size, png in sorted(paths_by_size.items()):
        w = 0 if size >= 256 else size
        h = 0 if size >= 256 else size
        entry = struct.pack(
            "<BBBBHHII",
            w, h,            # 0 means 256 in the ICO format
            0,               # palette colours
            0,               # reserved
            1,               # colour planes
            32,              # bits per pixel
            len(png),
            offset,
        )
        entries.append(entry)
        images.append(png)
        offset += len(png)

    header = struct.pack("<HHH", 0, 1, len(paths_by_size))
    return header + b"".join(entries) + b"".join(images)


def main() -> None:
    out_dir = os.path.join(ROOT, "assets", "sprites", "ui")
    os.makedirs(out_dir, exist_ok=True)

    pngs = {}
    for size in SIZES:
        canvas = render(size)
        pngs[size] = canvas.to_png()
        with open(os.path.join(out_dir, "icon_%d.png" % size), "wb") as f:
            f.write(pngs[size])
        print("   icon_%d.png  %dx%d  %d bytes" % (size, size, size, len(pngs[size])))

    ico = pack_ico(pngs)
    ico_path = os.path.join(ROOT, "icon.ico")
    with open(ico_path, "wb") as f:
        f.write(ico)
    print("[gen_icon] wrote icon.ico (%d bytes, %d sizes)" % (len(ico), len(SIZES)))


if __name__ == "__main__":
    main()
