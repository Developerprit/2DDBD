"""Build the props showcase for the README: pallet / broken pallet / window, 6x."""
import os
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_sprites import Canvas  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCALE, PAD = 6, 8
BG = (22, 22, 26, 255)


def load(path):
    d = open(path, 'rb').read()
    pos, idat, w, h = 8, b'', 0, 0
    while pos < len(d):
        ln = int.from_bytes(d[pos:pos + 4], 'big')
        tag = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if tag == b'IHDR':
            w = int.from_bytes(data[0:4], 'big')
            h = int.from_bytes(data[4:8], 'big')
        elif tag == b'IDAT':
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    c = Canvas(w, h)
    stride = w * 4
    for y in range(h):
        row = raw[y * (stride + 1) + 1:y * (stride + 1) + 1 + stride]
        for x in range(w):
            px = row[x * 4:x * 4 + 4]
            if px[3] > 0:
                c.set(x, y, (px[0], px[1], px[2], px[3]))
    return c


def main():
    names = ['props/pallet', 'props/pallet_broken', 'props/window']
    imgs = [load(os.path.join(ROOT, 'assets', 'sprites', n + '.png')) for n in names]
    w = max(i.w for i in imgs) * SCALE + PAD * 2
    h = sum(i.h * SCALE + PAD for i in imgs) + PAD
    out = Canvas(w, h)
    for yy in range(h):
        for xx in range(w):
            out.set(xx, yy, BG)
    oy = PAD
    for img in imgs:
        for y in range(img.h):
            for x in range(img.w):
                col = img.px.get((x, y))
                if col is None:
                    continue
                for dy in range(SCALE):
                    for dx in range(SCALE):
                        out.set(PAD + x * SCALE + dx, oy + y * SCALE + dy, col)
        oy += img.h * SCALE + PAD
    dst = os.path.join(ROOT, 'docs', 'props.png')
    open(dst, 'wb').write(out.to_png())
    print('wrote', dst, out.w, out.h)


if __name__ == '__main__':
    main()
