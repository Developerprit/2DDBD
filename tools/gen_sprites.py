#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
2DDBD -- procedural pixel-art generator.

Produces BOTH outputs from a single source of truth:

    assets/source_svg/**.svg   vector source, human-editable, infinitely scalable
    assets/sprites/**.png      runtime texture, guaranteed pixel-perfect

Why two formats: SVG keeps the art editable and tiny (repo-friendly), while a
1:1 PNG removes any dependency on the rasteriser's anti-aliasing so the game
never shows a soft edge. Zero third-party dependencies -- PNG is encoded by
hand with zlib.

Usage:
    python tools/gen_sprites.py            # write both formats
    python tools/gen_sprites.py --svg-only # only refresh the vector sources
"""

import argparse
import json
import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PNG_DIR = os.path.join(ROOT, "assets", "sprites")
SVG_DIR = os.path.join(ROOT, "assets", "source_svg")
DATA_DIR = os.path.join(ROOT, "src", "data")

TRANSPARENT = None


# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
def rgba(hexstr, a=255):
    h = hexstr.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), int(a))


def shade(col, factor):
    """Multiply RGB by `factor` (1.0 = unchanged) keeping alpha."""
    r, g, b, a = col
    return (max(0, min(255, int(r * factor))),
            max(0, min(255, int(g * factor))),
            max(0, min(255, int(b * factor))), a)


def mix(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(4))


def with_alpha(col, a):
    return (col[0], col[1], col[2], a)


# ---------------------------------------------------------------------------
# Canvas
# ---------------------------------------------------------------------------
class Canvas:
    """A sparse pixel buffer that can serialise to SVG runs or a raw PNG."""

    def __init__(self, w, h):
        self.w = w
        self.h = h
        self.px = {}

    # -- primitives ---------------------------------------------------------
    def set(self, x, y, col):
        if col is None:
            return
        x = int(x)
        y = int(y)
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[(x, y)] = col

    def rect(self, x0, y0, x1, y1, col):
        for y in range(int(math.floor(y0)), int(math.ceil(y1)) + 1):
            for x in range(int(math.floor(x0)), int(math.ceil(x1)) + 1):
                self.set(x, y, col)

    def hline(self, x0, x1, y, col):
        for x in range(int(math.floor(x0)), int(math.ceil(x1)) + 1):
            self.set(x, y, col)

    def vline(self, x, y0, y1, col):
        for y in range(int(math.floor(y0)), int(math.ceil(y1)) + 1):
            self.set(x, y, col)

    def ellipse(self, cx, cy, rx, ry, col, inner=None):
        if rx <= 0 or ry <= 0:
            return
        for y in range(int(math.floor(cy - ry)), int(math.ceil(cy + ry)) + 1):
            for x in range(int(math.floor(cx - rx)), int(math.ceil(cx + rx)) + 1):
                dx = (x + 0.5 - cx) / rx
                dy = (y + 0.5 - cy) / ry
                if dx * dx + dy * dy <= 1.0:
                    self.set(x, y, col if inner is None else inner)

    def ring(self, cx, cy, rx, ry, col):
        prev = set()
        for y in range(int(math.floor(cy - ry)) - 1, int(math.ceil(cy + ry)) + 2):
            row = set()
            for x in range(int(math.floor(cx - rx)) - 1, int(math.ceil(cx + rx)) + 2):
                dx = (x + 0.5 - cx) / rx
                dy = (y + 0.5 - cy) / ry
                if dx * dx + dy * dy <= 1.0:
                    row.add(x)
            for x in row:
                if x - 1 not in row or x + 1 not in row:
                    self.set(x, y, col)
            prev = row
        # vertical edges
        for x in range(int(math.floor(cx - rx)) - 1, int(math.ceil(cx + rx)) + 2):
            ys = [y for y in range(int(math.floor(cy - ry)) - 1,
                                   int(math.ceil(cy + ry)) + 2)
                  if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1.0]
            if ys:
                self.set(x, min(ys), col)
                self.set(x, max(ys), col)

    def line(self, x0, y0, x1, y1, col, thick=1):
        x0, y0, x1, y1 = int(x0), int(y0), int(x1), int(y1)
        dx = abs(x1 - x0)
        dy = -abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx + dy
        guard = 0
        while guard < 4096:
            guard += 1
            for ox in range(thick):
                for oy in range(thick):
                    self.set(x0 + ox, y0 + oy, col)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def blit(self, other, ox, oy):
        for (x, y), c in other.px.items():
            self.set(x + ox, y + oy, c)

    def outline(self, col):
        """Add a 1 px outline around every opaque region (classic pixel art)."""
        add = {}
        for (x, y) in list(self.px.keys()):
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                p = (x + dx, y + dy)
                if p not in self.px and 0 <= p[0] < self.w and 0 <= p[1] < self.h:
                    add[p] = col
        for p, c in add.items():
            self.px[p] = c

    def count(self):
        return len(self.px)

    # -- serialisation ------------------------------------------------------
    def to_svg(self, name=""):
        runs = []
        ys = sorted({y for (_, y) in self.px.keys()})
        for y in ys:
            xs = sorted(x for (x, yy) in self.px.keys() if yy == y)
            run_start = xs[0]
            run_col = self.px[(xs[0], y)]
            prev = xs[0]
            for x in xs[1:]:
                c = self.px[(x, y)]
                if x == prev + 1 and c == run_col:
                    prev = x
                    continue
                runs.append((run_start, y, prev - run_start + 1, run_col))
                run_start = x
                run_col = c
                prev = x
            runs.append((run_start, y, prev - run_start + 1, run_col))

        parts = [
            '<svg xmlns="http://www.w3.org/2000/svg" '
            'width="%d" height="%d" viewBox="0 0 %d %d" '
            'shape-rendering="crispEdges">' % (self.w, self.h, self.w, self.h)
        ]
        if name:
            parts.append("<title>%s</title>" % name)
        for (x, y, w, c) in runs:
            col = "#%02x%02x%02x" % (c[0], c[1], c[2])
            if c[3] >= 255:
                parts.append('<rect x="%d" y="%d" width="%d" height="1" fill="%s"/>'
                             % (x, y, w, col))
            else:
                parts.append('<rect x="%d" y="%d" width="%d" height="1" fill="%s" '
                             'fill-opacity="%.3f"/>' % (x, y, w, col, c[3] / 255.0))
        parts.append("</svg>\n")
        return "".join(parts)

    def to_png(self):
        rows = []
        for y in range(self.h):
            row = bytearray()
            for x in range(self.w):
                c = self.px.get((x, y))
                if c is None:
                    row += b"\x00\x00\x00\x00"
                else:
                    row += bytes((c[0], c[1], c[2], c[3]))
            rows.append(bytes(row))

        raw = b"".join(b"\x00" + r for r in rows)

        def chunk(tag, data):
            return (struct.pack(">I", len(data)) + tag + data
                    + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

        png = b"\x89PNG\r\n\x1a\n"
        png += chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw, 9))
        png += chunk(b"IEND", b"")
        return png


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
_svg_only = False


def write(canvas, subdir, name, animated=False):
    global _svg_only
    sdir = os.path.join(SVG_DIR, subdir)
    os.makedirs(sdir, exist_ok=True)
    with open(os.path.join(sdir, name + ".svg"), "w", encoding="utf-8") as f:
        f.write(canvas.to_svg(name))
    if _svg_only:
        return
    pdir = os.path.join(PNG_DIR, subdir)
    os.makedirs(pdir, exist_ok=True)
    with open(os.path.join(pdir, name + ".png"), "wb") as f:
        f.write(canvas.to_png())


# ===========================================================================
# HUMANOID RENDERER
# ===========================================================================
# A 3/4 top-down humanoid. Everything is parameterised so the same routine
# draws four survivors, the killer, and every animation frame.
#
# sprite box: SURV_W x SURV_H (16 x 20), feet at the bottom edge.

SURV_W, SURV_H = 16, 22
KILL_W, KILL_H = 24, 30

EYE = (22, 16, 12, 255)


def _draw_prone(c, ox, oy, W, H, top, pants, skin, hair, pal, killer, opts):
    """A body lying flat on the ground (downed / carried / dead)."""
    opts = opts or {}
    base_y = oy + H - 7
    cx = ox + W / 2.0
    c.ellipse(cx, base_y + 3.5, W * 0.40, 2.2, (0, 0, 0, 80))
    c.ellipse(cx - 0.5, base_y, W * 0.30, 2.9, top)
    c.ellipse(cx - W * 0.30, base_y + 0.4, 3.4, 2.9, pants)
    c.ellipse(cx + W * 0.28, base_y - 1.6, 3.2, 3.0, skin)
    c.ellipse(cx + W * 0.28, base_y - 2.8, 3.0, 2.3, hair)
    c.set(cx - W * 0.40, base_y + 2, rgba("#8b1a12", 210))
    if killer:
        c.ellipse(cx + W * 0.28, base_y - 1.4, 3.1, 2.2, pal.get("mask", shade(top, 0.6)))


class Rig:
    """Per-frame pose description."""

    def __init__(self):
        self.bob = 0.0        # vertical body offset in pixels
        self.leg = 0.0        # leg swing -1..1
        self.arm = 0.0        # arm swing -1..1
        self.crouch = 0.0     # 0 = standing, 1 = fully crouched
        self.prone = False
        self.lean = 0.0       # horizontal lean, -1..1
        self.reach = 0.0      # arm reach forward (interaction)
        self.weapon_phase = 0.0
        self.shrink = 0.0     # squashed (stun / hook)


def pose_rig(mode, t, facing, pal):
    r = Rig()
    tw = math.sin(t * math.pi * 2.0)
    if mode == "prone":
        r.prone = True
        return r
    if mode == "idle":
        r.bob = 0.35 * math.sin(t * math.pi * 2.0)
    elif mode == "walk":
        r.leg = tw * 0.55
        r.arm = -tw * 0.4
        r.bob = 0.5 * abs(math.sin(t * math.pi * 2.0))
    elif mode == "run":
        r.leg = tw * 1.0
        r.arm = -tw * 0.75
        r.bob = 1.0 * abs(math.sin(t * math.pi * 2.0))
        r.lean = 0.35
    elif mode == "chase":
        r.leg = tw * 1.0
        r.arm = -tw * 0.6
        r.bob = 1.1 * abs(math.sin(t * math.pi * 2.0))
        r.lean = 0.5
        r.weapon_phase = 0.5
    elif mode == "crouch_idle":
        r.crouch = 1.0
        r.bob = 0.25 * math.sin(t * math.pi * 2.0)
    elif mode == "crouch_run":
        r.crouch = 1.0
        r.leg = tw * 0.5
        r.arm = -tw * 0.3
        r.bob = 0.4 * abs(math.sin(t * math.pi * 2.0))
    elif mode == "vault":
        # 0 -> 1 arc over the obstacle
        r.bob = -3.2 * math.sin(t * math.pi)
        r.lean = math.sin(t * math.pi) * 0.8
        r.leg = 0.8 * math.sin(t * math.pi)
        r.arm = 0.9
    elif mode == "repair":
        r.crouch = 0.55
        r.reach = 0.5 + 0.35 * math.sin(t * math.pi * 4.0)
        r.lean = 0.25
    elif mode == "heal":
        r.crouch = 0.7
        r.reach = 0.4 + 0.2 * math.sin(t * math.pi * 2.0)
    elif mode == "struggle":
        r.shrink = 0.35 + 0.15 * math.sin(t * math.pi * 2.0)
        r.leg = 0.6 * tw
        r.arm = 0.7 * tw
    elif mode == "hooked":
        r.shrink = 0.5
        r.leg = 0.25 * tw
        r.arm = 0.45 * tw
    elif mode == "stun":
        r.lean = -0.6
        r.shrink = 0.2
        r.bob = 0.6 * abs(math.sin(t * math.pi * 2.0))
    elif mode == "place":
        r.crouch = 0.85
        r.reach = 0.7
        r.lean = 0.35
    elif mode == "attack_windup":
        r.lean = -0.4
        r.arm = -1.0
        r.weapon_phase = -1.0
    elif mode == "attack_hit":
        r.lean = 0.7
        r.arm = 1.0
        r.weapon_phase = 1.0
    elif mode == "attack_recover":
        r.lean = 0.3
        r.arm = 0.4
        r.weapon_phase = 0.3
    elif mode == "lunge":
        r.leg = tw * 1.0
        r.bob = 1.2 * abs(math.sin(t * math.pi * 2.0))
        r.lean = 0.9
        r.arm = 0.8
        r.weapon_phase = 0.8
    elif mode == "carry":
        r.crouch = 0.15
        r.leg = tw * 0.4
        r.arm = -0.9
    elif mode == "hooking":
        r.crouch = 0.2
        r.arm = 0.9
        r.reach = 0.8
    elif mode == "pickup":
        r.crouch = 0.9
        r.reach = 1.0
    return r


def draw_humanoid(c, ox, oy, pal, facing, mode, t, box, killer=False, opts=None):
    """Draw one frame of a humanoid into canvas `c` at offset (ox, oy)."""
    opts = opts or {}
    W, H = box
    r = pose_rig(mode, t, facing, pal)

    skin = pal["skin"]
    hair = pal["hair"]
    top = pal["top"]
    pants = pal["pants"]
    accent = pal.get("accent", top)
    dark = shade(top, 0.62)
    boot = shade(pants, 0.52)

    if killer:
        # Killers read as heavier: darker palette, wide shoulders, a weapon.
        skin = shade(skin, 0.72)
        top = shade(top, 0.85)
        pants = shade(pants, 0.8)

    is_side = (facing == "side")
    width_k = 0.74 if is_side else 1.0
    cx = ox + W / 2.0
    foot_y = oy + H - 1.0

    scale = 1.0 - 0.30 * r.crouch

    if r.prone:
        _draw_prone(c, ox, oy, W, H, top, pants, skin, hair, pal, killer, opts)
        return

    # ---- vertical layout --------------------------------------------------
    lean = r.lean * (1.6 if not killer else 1.9)
    cx += lean

    total_h = (H - 4.0) * scale
    head_r = (3.4 if not killer else 4.1) * (1.0 - 0.08 * r.crouch) * (0.95 if is_side else 1.0)
    head_cy = foot_y - total_h + head_r - r.bob
    torso_top = head_cy + head_r - 1.0
    torso_h = total_h * 0.40
    torso_cy = torso_top + torso_h * 0.5
    torso_w = (W * 0.28 if not killer else W * 0.31) * width_k
    hip_y = torso_top + torso_h - 0.5
    leg_len = max(2.5, foot_y - hip_y)
    head_cx = cx + (r.lean * 0.9 if is_side else 0.0)

    # ---- ground shadow ----------------------------------------------------
    c.ellipse(cx, foot_y + 0.6, (W * 0.30) * (1.0 - 0.22 * r.crouch) * width_k, 2.0,
              (0, 0, 0, 75))

    # ---- legs -------------------------------------------------------------
    swing = r.leg * (2.4 if mode in ("run", "chase", "lunge") else 1.5)
    for s in (-1, 1):
        lx = cx + s * torso_w * 0.44
        step = swing * (-s if not is_side else s)
        knee_y = hip_y + leg_len * 0.5
        ankle_y = foot_y - 1.2 - abs(step) * 0.2
        c.rect(lx - 1.4, hip_y, lx + 1.1, knee_y, pants)
        c.rect(lx - 1.4 + step * 0.42, knee_y, lx + 1.1 + step * 0.42, ankle_y, pants)
        c.rect(lx - 1.9 + step * 0.42, ankle_y, lx + 1.6 + step * 0.42, foot_y, boot)

    # ---- back arms --------------------------------------------------------
    arm_swing = r.arm * 2.2
    if facing == "up":
        _draw_arm(c, cx - torso_w * 0.92, torso_cy, arm_swing, top, skin, -1)
        _draw_arm(c, cx + torso_w * 0.92, torso_cy, -arm_swing, top, skin, 1)

    # ---- torso ------------------------------------------------------------
    c.ellipse(cx, torso_cy, torso_w, torso_h * 0.52, top)
    c.ellipse(cx, torso_cy - torso_h * 0.20, torso_w * 0.80, torso_h * 0.30, shade(top, 1.22))
    c.rect(cx - torso_w * 0.88, hip_y - 1.6, cx + torso_w * 0.88, hip_y - 0.6, accent)
    if killer:
        c.ellipse(cx - torso_w * 0.92, torso_cy - torso_h * 0.28, 2.5, 2.1, dark)
        c.ellipse(cx + torso_w * 0.92, torso_cy - torso_h * 0.28, 2.5, 2.1, dark)

    # ---- front arm --------------------------------------------------------
    if facing != "up":
        reach = r.reach * 3.2
        if is_side:
            _draw_arm(c, cx + torso_w * 0.55 + reach * 0.35, torso_cy + 0.5,
                      arm_swing, top, skin, 1, forward=reach * 0.75)
        else:
            _draw_arm(c, cx - torso_w * 0.92, torso_cy, arm_swing, top, skin, -1,
                      forward=-reach * 0.45)
            _draw_arm(c, cx + torso_w * 0.92, torso_cy, -arm_swing, top, skin, 1,
                      forward=reach * 0.45)

    # ---- head -------------------------------------------------------------
    c.ellipse(head_cx, head_cy, head_r, head_r, skin)
    if facing == "up":
        c.ellipse(head_cx, head_cy - 0.4, head_r, head_r, hair)
    elif is_side:
        c.ellipse(head_cx - 0.7, head_cy - 0.5, head_r, head_r * 0.96, hair)
        c.ellipse(head_cx + head_r * 0.42, head_cy + 0.25, head_r * 0.62, head_r * 0.70, skin)
        c.set(head_cx + head_r * 0.62, head_cy + 0.1, EYE)
    else:
        c.ellipse(head_cx, head_cy - 0.7, head_r, head_r * 0.9, hair)
        c.ellipse(head_cx, head_cy + head_r * 0.38, head_r * 0.80, head_r * 0.58, skin)
        c.set(head_cx - 1.6, head_cy + 0.9, EYE)
        c.set(head_cx + 1.6, head_cy + 0.9, EYE)

    if killer and opts.get("mask"):
        c.ellipse(head_cx, head_cy + 0.4, head_r * 0.90, head_r * 0.68,
                  pal.get("mask", shade(top, 0.6)))
        c.set(head_cx - 1.7, head_cy + 0.6, rgba("#c0392b"))
        c.set(head_cx + 1.7, head_cy + 0.6, rgba("#c0392b"))

    # ---- weapon -----------------------------------------------------------
    if killer and opts.get("weapon"):
        wx = cx + torso_w * (1.2 if facing != "up" else 0.4)
        wy = torso_cy + 1.0
        swing = r.weapon_phase
        if facing == "side":
            wx = cx + torso_w * 1.1 + swing * 3.0
        wl = 7 if not killer else 9
        blade = pal.get("weapon_col", rgba("#9aa4ad"))
        ang = -0.6 + swing * 1.6
        ex = wx + math.cos(ang) * wl
        ey = wy + math.sin(ang) * wl
        c.line(wx, wy, ex, ey, blade, thick=1)
        c.line(wx, wy + 1, ex, ey + 1, shade(blade, 0.70), thick=1)
        c.set(ex, ey, shade(blade, 1.35))
        c.rect(wx - 1, wy - 1, wx + 1, wy + 1, rgba("#3a2a1c"))

    # ---- carried survivor -------------------------------------------------
    if opts.get("carrying"):
        c.ellipse(cx, torso_cy - torso_h * 0.35, torso_w * 1.5, 3.0, pal.get("carry_col", rgba("#8a7a6a")))
        c.ellipse(cx + torso_w * 1.6, torso_cy - torso_h * 0.45, 3.2, 3.2, pal.get("carry_skin", rgba("#e8b98c")))


def _draw_arm(c, x, y, swing, top, skin, side, forward=0.0):
    c.rect(x - 1.5, y - 1.0, x + 1.5, y + 3.0 + swing, top)
    hx = x + forward
    hy = y + 3.5 + swing
    c.ellipse(hx, hy, 1.8, 1.8, skin)


# ===========================================================================
# ATLAS ASSEMBLY
# ===========================================================================
SURV_ANIMS = [
    # (name, frames, facing, mode, prefix_for_behaviour)
    ("idle_down", 2, "down", "idle"),
    ("idle_up", 2, "up", "idle"),
    ("idle_side", 2, "side", "idle"),
    ("walk_down", 4, "down", "walk"),
    ("walk_up", 4, "up", "walk"),
    ("walk_side", 4, "side", "walk"),
    ("run_down", 6, "down", "run"),
    ("run_up", 6, "up", "run"),
    ("run_side", 6, "side", "run"),
    ("crouch_down", 2, "down", "crouch_idle"),
    ("crouch_up", 2, "up", "crouch_idle"),
    ("crouch_side", 2, "side", "crouch_idle"),
    ("crouchwalk_down", 4, "down", "crouch_run"),
    ("crouchwalk_up", 4, "up", "crouch_run"),
    ("crouchwalk_side", 4, "side", "crouch_run"),
    ("vault_down", 4, "down", "vault"),
    ("vault_up", 4, "up", "vault"),
    ("vault_side", 4, "side", "vault"),
    ("repair", 2, "down", "repair"),
    ("heal", 2, "down", "heal"),
    ("downed", 2, "side", "prone"),
    ("hooked", 2, "down", "hooked"),
    ("struggle", 2, "down", "struggle"),
    ("carried", 2, "side", "prone"),
    ("dead", 2, "down", "hooked"),
]

KILLER_ANIMS = [
    ("idle_down", 2, "down", "idle"),
    ("idle_up", 2, "up", "idle"),
    ("idle_side", 2, "side", "idle"),
    ("walk_down", 4, "down", "walk"),
    ("walk_up", 4, "up", "walk"),
    ("walk_side", 4, "side", "walk"),
    ("chase_down", 6, "down", "chase"),
    ("chase_up", 6, "up", "chase"),
    ("chase_side", 6, "side", "chase"),
    ("attack_down", 4, "down", "attack"),
    ("attack_up", 4, "up", "attack"),
    ("attack_side", 4, "side", "attack"),
    ("lunge_down", 3, "down", "lunge"),
    ("lunge_side", 3, "side", "lunge"),
    ("carry_down", 2, "down", "carry"),
    ("carry_side", 2, "side", "carry"),
    ("stun", 2, "down", "stun"),
    ("place_down", 3, "down", "place"),
    ("pickup_side", 2, "side", "pickup"),
    ("hooking_down", 3, "down", "hooking"),
]


_ATTACK_SUB = {
    "attack": ["attack_windup", "attack_hit", "attack_recover", "attack_recover"],
}


def build_character_atlas(name, pal, anims, box, killer=False, opts=None):
    W, H = box
    max_frames = max(a[1] for a in anims)
    atlas = Canvas(W * max_frames, H * len(anims))
    meta = {"name": name, "frame_w": W, "frame_h": H, "rows": []}

    for row, entry in enumerate(anims):
        aname, frames, facing, mode = entry
        cells = []
        for f in range(frames):
            sub_mode = mode
            if mode == "attack":
                seq = _ATTACK_SUB["attack"]
                sub_mode = seq[min(f, len(seq) - 1)]
            t = f / float(frames) if frames > 1 else 0.0
            cell = Canvas(W, H)
            o = dict(opts or {})
            if sub_mode.startswith("attack") or sub_mode in ("chase", "lunge", "hooking"):
                o["weapon"] = True
            if sub_mode in ("carry", "hooking", "pickup"):
                o["weapon"] = False
            if killer:
                o.setdefault("weapon", True)
                o.setdefault("mask", True)
            draw = sub_mode
            draw_humanoid(cell, 0, 0, pal, facing, draw, t, box, killer, o)
            atlas.blit(cell, f * W, row * H)
            cells.append(f)
        meta["rows"].append({"anim": aname, "frames": frames, "row": row, "facing": facing})

    return atlas, meta


# ===========================================================================
# PROPS
# ===========================================================================
def make_generator():
    """32 x 40, 4 frames of piston animation laid horizontally."""
    FW, FH = 32, 40
    atlas = Canvas(FW * 4, FH)
    for f in range(4):
        c = Canvas(FW, FH)
        ox = f * FW
        body = rgba("#3c4a3a")
        metal = rgba("#6d7a6d")
        rust = rgba("#7a4a2c")
        glow = rgba("#f2c14e")
        dark = rgba("#1e261e")
        # base
        c.rect(ox + 4, 30, ox + 27, 37, dark)
        c.rect(ox + 5, 31, ox + 26, 36, body)
        # main block
        c.rect(ox + 6, 12, ox + 25, 31, body)
        c.rect(ox + 7, 13, ox + 24, 30, shade(body, 1.18))
        # cooling fins
        for i in range(4):
            c.rect(ox + 8, 15 + i * 3, ox + 23, 15 + i * 3, shade(body, 0.7))
        # piston towers
        lift = [0, 1, 2, 1][f]
        for i, px in enumerate((9, 15, 21)):
            c.rect(ox + px - 1, 6 - lift, ox + px + 1, 15, metal)
            c.rect(ox + px - 2, 4 - lift, ox + px + 2, 6 - lift, metal)
            c.set(ox + px, 3 - lift, shade(metal, 1.3))
        # rust patches
        c.set(ox + 8, 26, rust)
        c.set(ox + 23, 20, rust)
        c.set(ox + 13, 33, rust)
        # wire coil
        for i in range(5):
            c.set(ox + 26, 16 + i * 2, rgba("#c8a24a"))
        # progress lamp (dark by default, lit state handled in-engine)
        c.rect(ox + 26, 12, ox + 28, 14, rgba("#2a3a2a"))
        c.set(ox + 27, 13, glow)
        atlas.blit(c, ox, 0)
    return atlas


def make_hook():
    """16 x 28 hanging hook."""
    c = Canvas(16, 28)
    steel = rgba("#8b939b")
    dark = rgba("#454c52")
    rust = rgba("#7a4a2c")
    c.rect(7, 0, 8, 6, dark)
    c.rect(6, 1, 9, 2, steel)
    c.line(7, 6, 7, 14, steel, thick=1)
    c.line(8, 6, 8, 14, dark, thick=1)
    # hook curve
    pts = [(7, 15), (6, 16), (6, 17), (6, 18), (7, 19), (8, 20), (9, 20), (10, 19)]
    for p in pts:
        c.set(p[0], p[1], steel)
    c.set(3, 14, steel)
    c.set(4, 15, steel)
    c.set(10, 18, steel)
    c.set(11, 17, steel)
    c.set(3, 13, rust)
    c.set(6, 16, rust)
    # cross bar
    c.rect(2, 13, 13, 14, dark)
    c.hline(2, 13, 13, steel)
    return c


def make_pallet():
    """32 x 14 upright pallet.

    Redrawn for legibility. The old version was four flat bars with three vertical
    posts, which read as a bit of fence. This one has a dark outline so it separates
    from any ground tile, planks with a lit top edge and a shadowed underside so it
    reads as a solid object, and riveted steel straps -- the straps are what make it
    unmistakably a pallet.
    """
    c = Canvas(32, 14)
    outline = rgba("#17120c")
    steel = rgba("#8e949c")
    steel_dark = rgba("#565c64")
    rivet = rgba("#ccd2da")
    wood = rgba("#9a7742")
    wood_alt = rgba("#86663a")
    wood_dark = rgba("#5f4726")

    c.rect(0, 0, 31, 13, outline)

    # Five planks; 1 px of lit top edge and 1 px of shadowed underside each.
    for i in range(5):
        y = 1 + i * 2
        if y + 1 > 12:
            break
        base = wood if i % 2 == 0 else wood_alt
        c.rect(1, y, 30, y + 1, base)
        c.rect(1, y, 30, y, shade(base, 1.28))
        c.rect(1, y + 1, 30, y + 1, shade(base, 0.70))
        c.set(6 + (i * 5) % 18, y + 1, wood_dark)
        c.set(23 - (i * 3) % 15, y, wood_dark)

    # Riveted steel straps at both ends and through the middle.
    for x in (2, 14, 27):
        c.rect(x, 0, x + 2, 13, steel_dark)
        c.rect(x, 0, x + 1, 13, steel)
        c.set(x, 2, rivet)
        c.set(x + 1, 6, rivet)
        c.set(x, 10, rivet)
    return c


def make_pallet_broken():
    """32 x 10 shattered pallet: planks split apart, straps torn loose.

    The old version was four tan rectangles at slightly different heights and did
    not read as "this pallet is gone" -- which is exactly what the sprite has to
    communicate, since it is the only feedback that a loop has been closed.
    """
    c = Canvas(32, 10)
    wood = rgba("#8a6a3c")
    wood2 = rgba("#6a5029")
    wood_dark = rgba("#48341c")
    steel = rgba("#6c727a")

    # Three planks, split at different points with jagged ends.
    c.rect(1, 3, 9, 5, wood)
    c.rect(1, 5, 9, 5, wood_dark)
    c.set(10, 4, shade(wood, 1.25))
    c.set(11, 3, wood2)

    c.rect(11, 6, 19, 7, wood2)
    c.rect(11, 7, 19, 7, wood_dark)
    c.set(20, 6, wood2)

    c.rect(20, 1, 29, 3, wood)
    c.rect(20, 3, 29, 3, wood_dark)
    c.set(30, 2, shade(wood, 1.25))

    # A torn strap, bent out of shape.
    c.rect(7, 8, 13, 9, steel)
    c.set(14, 8, steel)
    c.set(6, 7, steel)

    # Splinters.
    c.set(4, 7, wood2)
    c.set(17, 2, wood_dark)
    c.set(26, 7, wood2)
    c.set(29, 6, steel)
    c.set(2, 2, wood2)
    return c


def make_pallet_dropped():
    """32 x 14 fallen pallet: the same board, now lying flat across the gap.

    Three states need three sprites -- upright, lying flat and intact, and smashed.
    The dropped state used to point at the broken sprite, so a pallet looked
    shattered the instant it was put down.

    "Lying flat" is communicated with a contact shadow underneath and planks a shade
    darker than the standing version: it is in the killer's shadow now and no longer
    catching light on a top edge.
    """
    c = Canvas(32, 14)
    shadow = rgba("#000000", 95)
    wood = rgba("#7d5f35")
    wood_alt = rgba("#6d5230")
    steel = rgba("#767c85")
    steel_dark = rgba("#4a5057")

    # Contact shadow underneath, tight against the planks so it reads as the board
    # sitting on the ground rather than as a separate bar.
    c.rect(1, 10, 30, 11, shadow)

    # Four planks running the width of the gap.
    for i in range(4):
        y = 2 + i * 2
        base = wood if i % 2 == 0 else wood_alt
        c.rect(0, y, 31, y + 1, base)
        c.rect(0, y, 31, y, shade(base, 1.14))
        c.rect(0, y + 1, 31, y + 1, shade(base, 0.76))

    # Board ends.
    c.rect(0, 2, 1, 9, shade(wood, 0.72))
    c.rect(30, 2, 31, 9, shade(wood, 0.72))

    # Steel straps, muted because they are not catching the light any more.
    for x in (5, 25):
        c.rect(x, 2, x + 1, 9, steel_dark)
        c.rect(x, 2, x, 9, steel)
        c.set(x, 3, shade(steel, 1.2))
        c.set(x + 1, 7, shade(steel_dark, 0.85))

    return c


def make_window():
    """32 x 10 window punched through a wall.

    Redrawn with masonry, a sill and actual glass. The old version was two parallel
    bars with two pixels of shimmer, which read as a fence rail rather than as
    something you vault through.
    """
    c = Canvas(32, 10)
    stone = rgba("#8f8a7c")
    stone_lit = rgba("#aca795")
    stone_dark = rgba("#5c584d")
    glass = rgba("#1b2a35")
    glass_mid = rgba("#2d475a")
    glint = rgba("#c2dcec")
    crack = rgba("#465866")

    # Lintel and sill.
    c.rect(0, 0, 31, 1, stone_dark)
    c.rect(0, 0, 31, 0, stone)
    c.rect(0, 8, 31, 9, stone_dark)
    c.rect(0, 8, 31, 8, stone_lit)

    # Jambs: both ends and the middle mullion.
    for x in (0, 1, 29, 30, 15, 16):
        c.rect(x, 0, x, 9, stone)
        c.set(x, 0, stone_lit)

    # Two glass panes.
    c.rect(2, 2, 14, 7, glass)
    c.rect(17, 2, 28, 7, glass)

    # The classic diagonal glint -- it is what says "glass" at this size.
    for i in range(9):
        c.set(3 + i, 7 - i, glint)
    for i in range(7):
        c.set(18 + i, 6 - i, glass_mid)
    c.rect(9, 2, 13, 2, glass_mid)

    # A crack in the right pane.
    c.set(24, 3, crack)
    c.set(23, 4, crack)
    c.set(24, 5, crack)
    c.set(25, 6, crack)
    return c


def make_locker():
    """16 x 28 metal locker."""
    c = Canvas(16, 28)
    body = rgba("#4a5560")
    body2 = rgba("#333c45")
    dark = rgba("#161c22")
    c.rect(1, 0, 14, 27, dark)
    c.rect(2, 1, 13, 26, body)
    c.rect(2, 1, 7, 26, shade(body, 1.15))
    c.rect(8, 1, 8, 26, dark)
    # vents
    for i in range(6):
        c.rect(3, 4 + i * 2, 6, 4 + i * 2, body2)
    # handle
    c.rect(9, 13, 10, 16, rgba("#9aa4ad"))
    c.set(10, 14, body2)
    # feet
    c.rect(1, 27, 3, 27, body2)
    c.rect(12, 27, 14, 27, body2)
    return c


def make_hatch(open_state):
    """24 x 24 hatch."""
    c = Canvas(24, 24)
    if open_state:
        c.ellipse(12, 12, 10, 9, rgba("#0a0c10", 255))
        c.ring(12, 12, 11, 10, rgba("#5a4a30"))
        c.ellipse(12, 12, 8, 7, rgba("#05070a", 255))
        # faint glow rising out
        for i, a in enumerate((90, 60, 35)):
            c.ring(12, 12, 6 - i, 5 - i, rgba("#6a8fa8", a))
    else:
        c.ellipse(12, 12, 10, 9, rgba("#3a3428"))
        c.ring(12, 12, 10, 9, rgba("#5a4a30"))
        c.rect(6, 11, 17, 12, rgba("#2a2620"))
        for i in range(4):
            c.set(8 + i * 3, 11, rgba("#4a4232"))
    return c


def make_exit_switch():
    """16 x 28 gate switch lever."""
    c = Canvas(16, 28)
    metal = rgba("#697079")
    dark = rgba("#20262c")
    c.rect(4, 6, 11, 27, dark)
    c.rect(5, 7, 10, 26, metal)
    c.rect(5, 7, 7, 26, shade(metal, 1.2))
    # lever
    c.rect(6, 10, 9, 14, rgba("#b8c0c8"))
    c.rect(7, 2, 8, 11, rgba("#c04a3a"))
    c.rect(6, 1, 9, 3, rgba("#e0644f"))
    # indicator
    c.rect(5, 18, 10, 21, rgba("#1a2028"))
    c.rect(6, 19, 9, 20, rgba("#7a2a22"))
    return c


def make_exit_gate(opened):
    """48 x 24 double gate."""
    c = Canvas(48, 24)
    if opened:
        # swung open, dark passage
        c.rect(0, 0, 47, 23, rgba("#05070a", 255))
        c.rect(0, 0, 5, 23, rgba("#4a5058"))
        c.rect(42, 0, 47, 23, rgba("#4a5058"))
        for i in range(6):
            c.rect(6 + i * 7, 1, 7 + i * 7, 22, rgba("#2a3038", 140))
        # moonlight spilling into the passage
        c.rect(10, 6, 37, 17, rgba("#8fa8bb", 40))
        c.rect(14, 9, 33, 15, rgba("#8fa8bb", 30))
    else:
        steel = rgba("#5d646c")
        c.rect(0, 0, 47, 23, rgba("#141a20"))
        c.rect(1, 1, 22, 22, steel)
        c.rect(25, 1, 46, 22, shade(steel, 0.88))
        for i in range(5):
            c.rect(3 + i * 4, 3, 4 + i * 4, 20, shade(steel, 1.15))
            c.rect(26 + i * 4, 3, 27 + i * 4, 20, shade(steel, 0.95))
        c.rect(23, 0, 24, 23, rgba("#2a3038"))
    return c


def make_chest():
    """20 x 18 wooden chest."""
    c = Canvas(20, 18)
    wood = rgba("#7a5a34")
    wood2 = rgba("#5a4126")
    iron = rgba("#4a4a48")
    c.rect(1, 5, 18, 16, wood2)
    c.rect(1, 5, 18, 11, wood)
    c.rect(1, 5, 18, 5, shade(wood, 1.2))
    for x in (3, 9, 15):
        c.rect(x, 5, x, 16, iron)
    c.rect(8, 10, 11, 13, iron)
    c.rect(9, 11, 10, 12, rgba("#2a2a28"))
    c.rect(0, 16, 19, 17, wood2)
    return c


def make_beartrap(open_state):
    """14 x 12 bear trap."""
    c = Canvas(14, 12)
    iron = rgba("#7d848c")
    iron2 = rgba("#4a5058")
    if open_state:
        c.ellipse(7, 7, 6, 4, iron2)
        c.ellipse(7, 7, 4, 2.4, rgba("#1a1c20"))
        # teeth
        for i in range(7):
            x = 1 + i * 2
            c.set(x, 3, iron)
            c.set(x, 2, shade(iron, 1.2))
            c.set(x, 11, iron)
            c.set(x, 10, shade(iron, 1.2))
        c.set(0, 7, iron)
        c.set(13, 7, iron)
    else:
        c.ellipse(7, 6, 6, 3.4, iron2)
        c.ellipse(7, 6, 4.5, 2.2, iron)
        for i in range(5):
            c.set(2 + i * 2.5, 4, shade(iron, 1.25))
    # base plate
    c.rect(1, 9, 12, 10, rgba("#2a2e33"))
    return c


# ===========================================================================
# TERRAIN TILES  (16 x 16 grid atlas)
# ===========================================================================
TILE_DEFS = [
    ("grass", "#2f3324", "#373b29"),
    ("grass_dark", "#282c1e", "#31351f"),
    ("dirt", "#31281d", "#3a2f22"),
    ("mud", "#2a2419", "#332b1e"),
    ("wood", "#3a2e1e", "#453723"),
    ("stone", "#2b2e33", "#343840"),
    ("gravel", "#33322c", "#3d3c34"),
    ("blood_floor", "#2c2222", "#3a2a26"),
    ("snow", "#3a4048", "#454c55"),
    ("metal", "#2a2e33", "#383d44"),
    ("water", "#1c2a30", "#24363e"),
    ("crop", "#3f4626", "#4b5430"),
    ("concrete", "#31343a", "#3b3f46"),
]

# Walls come in three vertical variants per material. Giving every wall tile its own
# top highlight and bottom shadow made a wall several tiles tall repeat that banding,
# so it read as a stack of planks instead of as a wall. Now only the piece genuinely
# open above gets the lit edge and only the piece open below gets the shadow; the
# body in between is plain, so a thick wall reads as one solid mass.
WALL_MATERIALS = [
    ("brick", "#4a3a2a", "#5a4632"),
    ("wood", "#42341f", "#514026"),
    ("rock", "#3a3d42", "#474b51"),
]

for _m, _base, _alt in WALL_MATERIALS:
    TILE_DEFS.append(("wall_%s" % _m, _base, _alt))         # body
    TILE_DEFS.append(("wall_%s_top" % _m, _base, _alt))     # open above
    TILE_DEFS.append(("wall_%s_bot" % _m, _base, _alt))     # open below


def make_tile_atlas(cols=8):
    FW = FH = 16
    rows = (len(TILE_DEFS) + cols - 1) // cols
    atlas = Canvas(FW * cols, FH * rows)
    rng = _Lcg(20260925)
    for i, (name, base, alt) in enumerate(TILE_DEFS):
        cx = (i % cols) * FW
        cy = (i // cols) * FH
        cell = Canvas(FW, FH)
        b = rgba(base)
        a = rgba(alt)
        for y in range(FH):
            for x in range(FW):
                v = rng.next()
                col = b
                if v > 0.86:
                    col = a
                elif v > 0.72:
                    col = mix(b, a, 0.45)
                if name.startswith("wall"):
                    if name.endswith("_top"):
                        # Only the row of wall tiles that is open above is lit.
                        if y < 3:
                            col = mix(col, rgba("#ffffff"), 0.16)
                        if y < 1:
                            col = mix(col, rgba("#ffffff"), 0.22)
                    elif name.endswith("_bot"):
                        if y > 12:
                            col = shade(col, 0.55)
                    # The body carries no bevel at all, so a thick wall is one
                    # continuous surface rather than a stack of bands.

                    # Material texture, so a wall reads as built rather than painted.
                    if "_brick" in name:
                        row = y // 4
                        offx = (row % 2) * 4
                        if y % 4 == 0:
                            col = shade(col, 0.80)
                        elif (x + offx) % 8 == 0:
                            col = shade(col, 0.86)
                    elif "_wood" in name:
                        if x % 8 == 0:
                            col = shade(col, 0.80)
                        if (y * 5 + x * 3) % 19 == 0:
                            col = shade(col, 0.88)
                    elif "_rock" in name:
                        if (x * 7 + y * 13) % 23 == 0:
                            col = shade(col, 0.84)
                        if (x * 3 + y * 11) % 29 == 0:
                            col = mix(col, rgba("#ffffff"), 0.05)
                if name == "water":
                    if (x + y) % 5 == 0:
                        col = mix(col, rgba("#7fa8b8"), 0.30)
                if name == "wood":
                    if y % 4 == 0:
                        col = shade(col, 0.78)
                    if x % 8 == 0:
                        col = shade(col, 0.85)
                if name == "concrete":
                    if (x * 3 + y * 5) % 17 == 0:
                        col = shade(col, 0.8)
                cell.set(x, y, col)
        atlas.blit(cell, cx, cy)
    return atlas, {"cols": cols, "frame_w": FW, "frame_h": FH,
                   "names": [t[0] for t in TILE_DEFS]}


class _Lcg:
    """Deterministic tiny RNG so regenerating art always yields the same file."""

    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFF

    def next(self):
        self.s = (self.s * 1664525 + 1013904223) & 0xFFFFFFFF
        return self.s / 4294967296.0

    def rand(self, a, b):
        return a + (b - a) * self.next()


# ===========================================================================
# UI ICONS  (16 x 16 grid atlas)
# ===========================================================================
UI_ICON_NAMES = [
    "generator", "hook", "pallet", "window", "hatch", "gate", "locker",
    "chest", "trap",
    "heal", "repair", "rescue", "escape", "skull", "downed", "injured",
    "perk", "item", "addon", "power",
    "heart", "chase", "scratch", "blood",
    "arrow_up", "arrow_down", "arrow_left", "arrow_right",
    "victim", "killer", "survivor", "objective",
]


def make_icon(canvas, name):
    W = canvas.w
    white = rgba("#e8e6e0")
    amber = rgba("#d8a848")
    red = rgba("#b8453a")
    c = canvas
    m = W / 16.0

    def s(x, y, col=white):
        c.rect(x * m, y * m, (x + 1) * m - 1, (y + 1) * m - 1, col)

    def box(x0, y0, x1, y1, col=white):
        c.rect(x0 * m, y0 * m, (x1 + 1) * m - 1, (y1 + 1) * m - 1, col)

    if name == "generator":
        box(4, 3, 11, 12, white)
        box(5, 5, 10, 11, amber)
        box(2, 6, 3, 12, white)
        box(12, 6, 13, 12, white)
        box(6, 13, 9, 14, white)
    elif name == "hook":
        box(7, 2, 8, 9, white)
        box(3, 2, 8, 3, white)
        for p in [(7, 10), (6, 11), (6, 12), (7, 13), (8, 13), (9, 12), (10, 11), (11, 10)]:
            s(p[0], p[1], amber)
        box(8, 13, 8, 13, red)
    elif name == "pallet":
        # Planks behind two steel straps, matching the world sprite. The old icon
        # was four horizontal bars and was indistinguishable from the window icon.
        box(2, 4, 13, 12, amber)
        box(2, 7, 13, 7, rgba("#8a6a3c"))
        box(2, 10, 13, 10, rgba("#8a6a3c"))
        box(2, 4, 13, 4, white)
        box(2, 12, 13, 12, white)
        box(4, 4, 4, 12, white)
        box(11, 4, 11, 12, white)
    elif name == "window":
        # A masonry frame with two panes of glass and a diagonal glint, so it reads
        # as a window you vault rather than as a box outline.
        box(1, 3, 14, 12, white)
        box(2, 4, 13, 11, rgba("#1b2a35"))
        box(7, 4, 8, 11, white)
        for i in range(5):
            s(3 + i, 9 - i, rgba("#c2dcec"))
        for i in range(4):
            s(10 + i, 10 - i, rgba("#8fb6cc"))
    elif name == "hatch":
        c.ring(W / 2.0, W / 2.0, W / 2.0 - 1, W / 2.0 - 1, amber)
        c.ellipse(W / 2.0, W / 2.0, W / 2.0 - 3, W / 2.0 - 3, rgba("#101418"))
    elif name == "gate":
        box(3, 2, 12, 13, white)
        box(7, 2, 8, 13, amber)
        box(3, 7, 12, 8, amber)
    elif name == "locker":
        box(4, 2, 11, 13, white)
        box(8, 2, 8, 13, amber)
        box(6, 6, 7, 8, amber)
    elif name == "chest":
        box(3, 6, 12, 13, amber)
        box(3, 6, 12, 8, white)
        box(7, 9, 8, 12, white)
    elif name == "trap":
        c.ellipse(8, 8, 7, 4, white)
        for i in range(5):
            s(2 + i * 3, 4, amber)
            s(2 + i * 3, 12, amber)
    elif name == "heal":
        box(6, 3, 9, 12, red)
        box(3, 6, 12, 9, red)
    elif name == "repair":
        for i in range(4):
            box(2, 4 + i * 3, 13, 5 + i * 3, amber)
        c.ellipse(11, 4, 3, 3, white)
    elif name == "rescue":
        box(7, 1, 8, 10, white)
        box(3, 1, 8, 2, white)
        box(7, 11, 8, 12, amber)
        box(9, 13, 12, 14, red)
        box(2, 13, 5, 14, red)
    elif name == "escape":
        for i in range(4):
            box(3 + i, 3, 4 + i, 12, white if i < 2 else amber)
        c.ellipse(13, 8, 3, 3, amber)
    elif name == "skull":
        c.ellipse(8, 7, 5, 5, white)
        box(4, 11, 11, 13, white)
        box(6, 6, 7, 8, rgba("#101418"))
        box(9, 6, 10, 8, rgba("#101418"))
        box(7, 10, 8, 11, rgba("#101418"))
    elif name == "downed":
        box(2, 9, 11, 12, white)
        c.ellipse(13, 9, 2.5, 2.5, amber)
    elif name == "injured":
        box(6, 2, 9, 13, white)
        box(3, 4, 12, 6, red)
    elif name == "perk":
        c.ellipse(8, 8, 7, 6, amber)
        c.ellipse(8, 8, 4, 3.5, rgba("#101418"))
    elif name == "item":
        box(4, 3, 11, 13, white)
        box(5, 5, 10, 11, amber)
        box(7, 1, 8, 3, white)
    elif name == "addon":
        box(3, 3, 12, 4, white)
        box(4, 5, 11, 12, amber)
        box(6, 6, 9, 9, white)
    elif name == "power":
        for i, p in enumerate([(8, 2), (5, 5), (11, 5), (8, 8), (5, 11), (11, 11), (8, 13)]):
            c.ellipse(p[0], p[1], 2, 2, amber if i % 2 else white)
    elif name == "heart":
        c.ellipse(6, 6, 3, 2.6, red)
        c.ellipse(10, 6, 3, 2.6, red)
        for y in range(6, 14):
            w = max(0, (13 - y))
            c.hline(8 - w, 8 + w - 1, y, red)
    elif name == "chase":
        box(2, 3, 4, 12, red)
        box(6, 5, 8, 12, amber)
        box(10, 7, 12, 12, white)
    elif name == "scratch":
        for i in range(3):
            c.line(3 + i * 4, 12, 6 + i * 4, 3, red, thick=1)
    elif name == "blood":
        c.ellipse(8, 9, 4, 5, red)
        c.ellipse(8, 4, 2, 3, red)
    elif name.startswith("arrow_"):
        d = name.split("_")[1]
        for i in range(6):
            if d == "up":
                c.hline(8 - i, 8 + i - 1, 4 + i, white)
            elif d == "down":
                c.hline(8 - (5 - i), 8 + (5 - i) - 1, 11 - i, white)
            elif d == "left":
                c.vline(4 + i, 8 - i, 8 + i - 1, white)
            else:
                c.vline(11 - i, 8 - i, 8 + i - 1, white)
    elif name == "victim":
        c.ellipse(8, 5, 3, 3, white)
        box(5, 9, 10, 14, white)
    elif name == "killer":
        c.ellipse(8, 5, 3.4, 3.4, red)
        box(4, 9, 11, 14, red)
        box(5, 10, 6, 13, rgba("#101418"))
        box(9, 10, 10, 13, rgba("#101418"))
    elif name == "survivor":
        c.ellipse(8, 5, 3, 3, white)
        box(5, 9, 10, 14, white)
        box(3, 10, 4, 13, amber)
        box(11, 10, 12, 13, amber)
    elif name == "objective":
        c.ring(8, 8, 6, 6, amber)
        box(7, 4, 8, 9, white)
        box(7, 10, 8, 11, white)
    else:
        box(4, 4, 11, 11, white)


def make_ui_atlas(cols=8):
    FW = FH = 16
    rows = (len(UI_ICON_NAMES) + cols - 1) // cols
    atlas = Canvas(FW * cols, FH * rows)
    for i, name in enumerate(UI_ICON_NAMES):
        cell = Canvas(FW, FH)
        make_icon(cell, name)
        atlas.blit(cell, (i % cols) * FW, (i // cols) * FH)
    return atlas, {"cols": cols, "frame_w": FW, "frame_h": FH, "names": UI_ICON_NAMES}


# ===========================================================================
# APP ICON + in-world decorations
# ===========================================================================
def make_app_icon(size=128):
    c = Canvas(size, size)
    bg = rgba("#101014")
    c.rect(0, 0, size - 1, size - 1, bg)
    # a stylised hook sigil, echoing the supplied reference mark
    white = rgba("#f2f0ea")
    cx = size / 2.0
    bar_w = size * 0.055
    c.rect(cx - size * 0.30, size * 0.20, cx + size * 0.30, size * 0.20 + bar_w, white)
    for i in range(4):
        x = cx - size * 0.22 + i * size * 0.147
        c.rect(x, size * 0.20, x + bar_w * 0.85, size * 0.62 - i * size * 0.03, white)
    c.rect(cx - bar_w * 0.5, size * 0.20, cx + bar_w * 0.5, size * 0.74, white)
    for i, p in enumerate([(1, 0), (1, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 5), (6, 4), (7, 3)]):
        c.rect(cx + (p[0] - 3) * bar_w * 0.8, size * 0.74 + p[1] * bar_w * 0.8, 
               cx + (p[0] - 3) * bar_w * 0.8 + bar_w * 0.8, size * 0.74 + p[1] * bar_w * 0.8 + bar_w * 0.8, white)
    return c


def make_scratch_mark():
    c = Canvas(10, 8)
    red = rgba("#8f1a14", 210)
    c.line(1, 7, 3, 0, red)
    c.line(5, 7, 6, 1, red)
    c.line(8, 7, 9, 2, red)
    return c


def make_blood_drop():
    c = Canvas(6, 6)
    red = rgba("#7a1210", 230)
    c.ellipse(3, 3, 2.4, 2.0, red)
    c.ellipse(3, 3, 1.2, 1.0, rgba("#a81c14", 240))
    return c


# ===========================================================================
# MAIN
# ===========================================================================
def load_palettes():
    with open(os.path.join(DATA_DIR, "survivors.json"), "r", encoding="utf-8") as f:
        data = json.load(f)
    out = {}
    for key, entry in data.items():
        out[key] = {k: rgba(v) for k, v in entry["palette"].items()}
    return out


KILLER_PALETTE = {
    "skin": rgba("#b8937a"),
    "hair": rgba("#2a221c"),
    "top": rgba("#4a5049"),
    "pants": rgba("#3d3d37"),
    "accent": rgba("#7a5a34"),
    "mask": rgba("#70726c"),
    "weapon_col": rgba("#c4cad0"),
    "carry_col": rgba("#5a4a42"),
    "carry_skin": rgba("#c99a72"),
}

WRAITH_PALETTE = {
    "skin": rgba("#cfc6bd"),
    "hair": rgba("#20242a"),
    "top": rgba("#b9c2c8"),
    "pants": rgba("#6f7780"),
    "accent": rgba("#d8e0e6"),
    "mask": rgba("#aeb6bc"),
    "weapon_col": rgba("#c4cad0"),
    "carry_col": rgba("#5a4a42"),
    "carry_skin": rgba("#c99a72"),
}

# Each killer: its palette and the build options (the Wraith carries a bell,
# not a cleaver, so it is drawn without the generic weapon).
KILLER_PALETTES = {
    "trapper": {"pal": KILLER_PALETTE, "opts": {"weapon": True, "mask": True}},
    "wraith": {"pal": WRAITH_PALETTE, "opts": {"mask": True}},
}


def main():
    global _svg_only
    ap = argparse.ArgumentParser()
    ap.add_argument("--svg-only", action="store_true")
    ap.add_argument("--png-only", action="store_true")
    args = ap.parse_args()
    _svg_only = args.svg_only

    palettes = load_palettes()
    manifest = {"characters": [], "props": [], "atlases": {}}

    print("[gen_sprites] characters ...")
    for name, pal in palettes.items():
        atlas, meta = build_character_atlas(name, pal, SURV_ANIMS, (SURV_W, SURV_H))
        write(atlas, "survivor", "survivor_" + name)
        meta["palette"] = {k: "#%02x%02x%02x" % (v[0], v[1], v[2]) for k, v in pal.items()}
        manifest["characters"].append(meta)
        print("   survivor_%s  %dx%d" % (name, atlas.w, atlas.h))

    for kname, kentry in KILLER_PALETTES.items():
        atlas, meta = build_character_atlas(kname, kentry["pal"], KILLER_ANIMS,
                                            (KILL_W, KILL_H), killer=True, opts=kentry["opts"])
        write(atlas, "killer", "killer_" + kname)
        meta["palette"] = {k: "#%02x%02x%02x" % (v[0], v[1], v[2]) for k, v in kentry["pal"].items()}
        manifest["characters"].append(meta)
        print("   killer_%s  %dx%d" % (kname, atlas.w, atlas.h))

    print("[gen_sprites] props ...")
    props = {
        "generator": make_generator(),
        "hook": make_hook(),
        "pallet": make_pallet(),
        "pallet_dropped": make_pallet_dropped(),
        "pallet_broken": make_pallet_broken(),
        "window": make_window(),
        "locker": make_locker(),
        "hatch_closed": make_hatch(False),
        "hatch_open": make_hatch(True),
        "exit_switch": make_exit_switch(),
        "exit_gate_closed": make_exit_gate(False),
        "exit_gate_open": make_exit_gate(True),
        "chest": make_chest(),
        "beartrap_open": make_beartrap(True),
        "beartrap_closed": make_beartrap(False),
        "scratch_mark": make_scratch_mark(),
        "blood_drop": make_blood_drop(),
    }
    for name, canvas in props.items():
        write(canvas, "props", name)
        manifest["props"].append({"name": name, "w": canvas.w, "h": canvas.h})
        print("   %-18s %dx%d" % (name, canvas.w, canvas.h))

    print("[gen_sprites] atlases ...")
    tile_atlas, tile_meta = make_tile_atlas()
    write(tile_atlas, "tiles", "tiles")
    manifest["atlases"]["tiles"] = tile_meta

    ui_atlas, ui_meta = make_ui_atlas()
    write(ui_atlas, "ui", "icons")
    manifest["atlases"]["icons"] = ui_meta

    icon = make_app_icon(128)
    write(icon, "ui", "app_icon")
    # The Godot project icon must be an .svg at the project root.
    with open(os.path.join(ROOT, "icon.svg"), "w", encoding="utf-8") as f:
        f.write(icon.to_svg("2DDBD"))

    os.makedirs(DATA_DIR, exist_ok=True)
    with open(os.path.join(DATA_DIR, "sprite_manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)

    total = sum(len(files) for _, _, files in os.walk(PNG_DIR))
    print("[gen_sprites] done. %d png files under assets/sprites/" % total)


if __name__ == "__main__":
    main()
