#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
2DDBD -- procedural sound synthesiser.

Every sound in the game is generated here from scratch (pure Python, stdlib
only). No sampled or licensed audio is used anywhere in the project.

    assets/audio/*.wav        22 050 Hz, 16-bit mono

The palette is deliberately small: noise bursts for impacts, FM tones for UI,
detuned saw stacks for drones and a tiny step sequencer for the music beds.

Usage:
    python tools/gen_audio.py
    python tools/gen_audio.py --only heartbeat,hit
"""

import argparse
import array
import math
import os
import struct
import sys
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "audio")
SR = 22050

_rng_state = 0x1234567


def rnd():
    """Deterministic white noise in [-1, 1)."""
    global _rng_state
    _rng_state = (_rng_state * 1103515245 + 12345) & 0x7FFFFFFF
    return (_rng_state / 1073741823.5) - 1.0


def seed(s):
    global _rng_state
    _rng_state = s & 0x7FFFFFFF


# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------
def env_ad(n, attack, decay, curve=2.0):
    """Percussive envelope: fast attack, exponential decay."""
    a = max(1, int(attack * SR))
    out = [0.0] * n
    for i in range(n):
        if i < a:
            out[i] = i / float(a)
        else:
            t = (i - a) / float(max(1, n - a))
            out[i] = math.pow(max(0.0, 1.0 - t), curve)
    return out


def env_adsr(n, a, d, s, r):
    a_n = max(1, int(a * SR))
    d_n = max(1, int(d * SR))
    r_n = max(1, int(r * SR))
    s_n = max(1, n - a_n - d_n - r_n)
    out = []
    for i in range(a_n):
        out.append(i / float(a_n))
    for i in range(d_n):
        out.append(1.0 - (1.0 - s) * (i / float(d_n)))
    for _ in range(s_n):
        out.append(s)
    for i in range(r_n):
        out.append(s * (1.0 - i / float(r_n)))
    out = out[:n]
    while len(out) < n:
        out.append(0.0)
    return out


def osc(kind, freq, n, phase=0.0, detune=0.0):
    out = [0.0] * n
    ph = phase
    ph2 = phase
    inc = freq / SR
    inc2 = (freq * (1.0 + detune)) / SR
    for i in range(n):
        if kind == "sine":
            v = math.sin(2 * math.pi * ph)
        elif kind == "tri":
            x = ph % 1.0
            v = 4.0 * abs(x - 0.5) - 1.0
        elif kind == "saw":
            v = 2.0 * (ph % 1.0) - 1.0
        elif kind == "sq":
            v = 1.0 if (ph % 1.0) < 0.5 else -1.0
        else:
            v = math.sin(2 * math.pi * ph)
        if detune:
            x = ph2 % 1.0
            v = (v + (2.0 * x - 1.0)) * 0.5
        out[i] = v
        ph += inc
        ph2 += inc2
    return out


def noise(n, lp=0.0):
    out = [0.0] * n
    prev = 0.0
    for i in range(n):
        v = rnd()
        if lp > 0.0:
            prev = prev * lp + v * (1.0 - lp)
            v = prev
        out[i] = v
    return out


def apply(sig, envelope):
    return [sig[i] * envelope[i] for i in range(len(sig))]


def mix(*sigs):
    n = max(len(s) for s in sigs)
    out = [0.0] * n
    for s in sigs:
        for i, v in enumerate(s):
            out[i] += v
    return out


def gain(sig, g):
    return [v * g for v in sig]


def lowpass(sig, alpha):
    out = [0.0] * len(sig)
    prev = 0.0
    for i, v in enumerate(sig):
        prev = prev + alpha * (v - prev)
        out[i] = prev
    return out


def highpass(sig, alpha):
    out = [0.0] * len(sig)
    prev_in = 0.0
    prev_out = 0.0
    for i, v in enumerate(sig):
        prev_out = alpha * (prev_out + v - prev_in)
        prev_in = v
        out[i] = prev_out
    return out


def sweep(kind, f0, f1, n, curve=1.0):
    out = [0.0] * n
    ph = 0.0
    for i in range(n):
        t = (i / float(max(1, n - 1))) ** curve
        f = f0 + (f1 - f0) * t
        if kind == "sine":
            v = math.sin(2 * math.pi * ph)
        elif kind == "saw":
            v = 2.0 * (ph % 1.0) - 1.0
        elif kind == "tri":
            x = ph % 1.0
            v = 4.0 * abs(x - 0.5) - 1.0
        else:
            v = 1.0 if (ph % 1.0) < 0.5 else -1.0
        out[i] = v
        ph += f / SR
    return out


def silence(dur):
    return [0.0] * int(dur * SR)


def concat(*sigs):
    out = []
    for s in sigs:
        out.extend(s)
    return out


def normalize(sig, peak=0.9):
    m = 0.0
    for v in sig:
        a = abs(v)
        if a > m:
            m = a
    if m < 1e-6:
        return sig
    k = peak / m
    return [v * k for v in sig]


def fade_edges(sig, ms=6):
    n = len(sig)
    f = max(1, int(SR * ms / 1000.0))
    out = list(sig)
    for i in range(min(f, n)):
        out[i] *= i / float(f)
        out[n - 1 - i] *= i / float(f)
    return out


def make_loop(sig, ms=40):
    """Cross-fade a tail into the head so the WAV loops seamlessly."""
    n = len(sig)
    f = max(1, int(SR * ms / 1000.0))
    if f * 2 >= n:
        return sig
    out = list(sig)
    for i in range(f):
        t = i / float(f)
        out[i] = out[i] * t + sig[n - f + i] * (1.0 - t)
    return out[: n - f]


# ---------------------------------------------------------------------------
# Sound definitions
# ---------------------------------------------------------------------------
def s_heartbeat(rate=1.0, base=52.0):
    def thump(f, dur, amp):
        body = osc("sine", f, int(dur * SR))
        body = apply(body, env_ad(len(body), 0.004, dur, 2.6))
        click = apply(lowpass(noise(int(0.03 * SR)), 0.35), env_ad(int(0.03 * SR), 0.001, 0.03, 3.0))
        return gain(body, amp) if not click else mix(gain(body, amp), gain(click, amp * 0.35))
    if rate >= 2.0:
        return normalize(concat(thump(base * 1.15, 0.16, 1.0), silence(0.09),
                                thump(base * 1.0, 0.13, 0.72)), 0.85)
    return normalize(concat(thump(base, 0.20, 1.0), silence(0.14), thump(base * 0.85, 0.16, 0.7)), 0.85)


def s_gen_loop():
    n = int(0.75 * SR)
    hum = mix(gain(osc("sine", 98.0, n), 0.5),
              gain(osc("saw", 196.0, n, detune=0.004), 0.16),
              gain(osc("sine", 294.0, n), 0.10))
    chatter = gain(apply(lowpass(noise(n), 0.10), [0.35 + 0.25 * math.sin(2 * math.pi * 6 * i / SR) for i in range(n)]), 0.22)
    sig = lowpass(mix(hum, chatter), 0.55)
    return make_loop(normalize(sig, 0.55))


def s_gen_done():
    a = apply(osc("tri", 523.25, int(0.14 * SR)), env_ad(int(0.14 * SR), 0.005, 0.14, 2.0))
    b = apply(osc("tri", 659.25, int(0.14 * SR)), env_ad(int(0.14 * SR), 0.005, 0.14, 2.0))
    c = apply(osc("tri", 783.99, int(0.55 * SR)), env_ad(int(0.55 * SR), 0.005, 0.55, 2.4))
    return normalize(concat(gain(a, 0.6), gain(b, 0.6), gain(c, 0.8)), 0.8)


def s_gen_explode():
    n = int(0.85 * SR)
    boom = apply(sweep("sine", 160.0, 34.0, n, 1.7), env_ad(n, 0.002, 0.85, 2.0))
    sh = apply(lowpass(noise(n), 0.14), env_ad(n, 0.001, 0.45, 2.6))
    return normalize(mix(gain(boom, 1.0), gain(sh, 0.75)), 0.95)


def _blip(f, dur, kind="tri", amp=1.0, curve=2.0):
    n = int(dur * SR)
    return gain(apply(osc(kind, f, n), env_ad(n, 0.003, dur, curve)), amp)


def s_skillcheck_appear():
    return normalize(concat(_blip(1320, 0.09, "sine"), _blip(1760, 0.05, "sine", 0.4)), 0.7)


def s_skillcheck_good():
    return normalize(concat(_blip(880, 0.10), _blip(1174, 0.12, "tri", 0.8)), 0.75)


def s_skillcheck_great():
    return normalize(concat(_blip(1046, 0.08, "sine"), _blip(1318, 0.08, "sine", 0.9),
                            _blip(1568, 0.20, "sine", 0.9)), 0.8)


def s_skillcheck_miss():
    n = int(0.35 * SR)
    buzz = gain(apply(sweep("saw", 240.0, 70.0, n, 1.4), env_ad(n, 0.002, 0.35, 2.0)), 0.7)
    nz = gain(apply(lowpass(noise(n), 0.25), env_ad(n, 0.001, 0.25, 2.8)), 0.6)
    return normalize(mix(buzz, nz), 0.9)


def s_hit():
    n = int(0.22 * SR)
    body = apply(sweep("sine", 240.0, 60.0, n, 1.5), env_ad(n, 0.001, 0.22, 2.2))
    slap = apply(highpass(noise(n), 0.6), env_ad(n, 0.0005, 0.09, 3.0))
    return normalize(mix(gain(body, 1.0), gain(slap, 0.8)), 0.95)


def s_hit_heavy():
    n = int(0.45 * SR)
    body = apply(sweep("sine", 180.0, 38.0, n, 1.8), env_ad(n, 0.002, 0.45, 2.0))
    sh = apply(lowpass(noise(n), 0.2), env_ad(n, 0.001, 0.3, 2.4))
    return normalize(mix(gain(body, 1.1), gain(sh, 0.7)), 1.0)


def s_scream(f0=210.0, dur=0.85):
    n = int(dur * SR)
    vib = [1.0 + 0.035 * math.sin(2 * math.pi * 6.5 * i / SR) for i in range(n)]
    out = [0.0] * n
    ph1 = ph2 = ph3 = 0.0
    for i in range(n):
        f = f0 * (1.25 - 0.35 * (i / float(n))) * vib[i]
        ph1 += f / SR
        ph2 += (f * 2.02) / SR
        ph3 += (f * 3.05) / SR
        out[i] = (math.sin(2 * math.pi * ph1) * 0.6
                  + math.sin(2 * math.pi * ph2) * 0.3
                  + math.sin(2 * math.pi * ph3) * 0.16)
    breath = gain(lowpass(noise(n), 0.35), 0.25)
    e = env_adsr(n, 0.04, 0.15, 0.75, 0.4)
    return normalize(apply(mix(out, breath), e), 0.9)


def s_scream_m():
    return s_scream(148.0, 0.95)


def s_scream_f():
    return s_scream(255.0, 0.85)


def s_hook():
    n = int(0.7 * SR)
    clank = mix(gain(apply(osc("sq", 720.0, n), env_ad(n, 0.001, 0.10, 3.0)), 0.35),
                gain(apply(highpass(noise(n), 0.75), env_ad(n, 0.0005, 0.08, 3.2)), 0.9))
    ring = gain(apply(mix(osc("sine", 1420.0, n), osc("sine", 2134.0, n)), env_ad(n, 0.002, 0.7, 3.4)), 0.4)
    chain = []
    for k in range(7):
        seg = apply(highpass(noise(int(0.045 * SR)), 0.7), env_ad(int(0.045 * SR), 0.0005, 0.045, 3.0))
        chain.append(gain(seg, 0.55 - k * 0.06))
        chain.append(silence(0.030 + 0.008 * k))
    return normalize(concat(gain(clank, 1.0), concat(*chain), gain(ring, 0.5), silence(0.05)), 0.95)


def s_unhook():
    out = [silence(0.02)]
    for k in range(5):
        seg = apply(highpass(noise(int(0.05 * SR)), 0.7), env_ad(int(0.05 * SR), 0.0005, 0.05, 3.0))
        out.append(gain(seg, 0.5 - k * 0.05))
        out.append(silence(0.04))
    out.append(gain(apply(osc("sine", 900.0, int(0.2 * SR)), env_ad(int(0.2 * SR), 0.002, 0.2, 3.0)), 0.4))
    return normalize(concat(*out), 0.85)


def s_sacrifice():
    n = int(2.2 * SR)
    rise = apply(sweep("saw", 55.0, 220.0, n, 2.2), env_ad(n, 0.4, 2.2, 1.4))
    rise = lowpass(rise, 0.25)
    drone = gain(apply(osc("sine", 41.0, n, detune=0.01), env_adsr(n, 0.5, 0.5, 0.8, 0.8)), 0.8)
    shriek = gain(apply(sweep("sine", 900.0, 2400.0, n, 2.0), env_ad(n, 0.9, 2.2, 1.8)), 0.16)
    return normalize(mix(gain(rise, 0.5), drone, shriek), 0.95)


def s_pallet_drop():
    n = int(0.4 * SR)
    body = apply(sweep("tri", 300.0, 90.0, n, 1.6), env_ad(n, 0.001, 0.4, 2.0))
    crack = apply(lowpass(noise(n), 0.45), env_ad(n, 0.0005, 0.12, 3.0))
    return normalize(mix(gain(body, 0.9), gain(crack, 0.8)), 0.95)


def s_pallet_break():
    out = [silence(0.005)]
    for k in range(6):
        seg = apply(lowpass(noise(int(0.07 * SR)), 0.5), env_ad(int(0.07 * SR), 0.0005, 0.07, 2.6))
        out.append(gain(seg, 0.85 - k * 0.1))
        out.append(silence(0.025 + 0.01 * k))
    out.append(gain(apply(sweep("sine", 200.0, 60.0, int(0.25 * SR), 1.5),
                          env_ad(int(0.25 * SR), 0.001, 0.25, 2.0)), 0.7))
    return normalize(concat(*out), 0.95)


def s_pallet_stun():
    n = int(0.9 * SR)
    ring = mix(gain(apply(osc("sine", 620.0, n), env_ad(n, 0.002, 0.9, 2.4)), 0.5),
               gain(apply(osc("sine", 931.0, n), env_ad(n, 0.002, 0.7, 2.8)), 0.3),
               gain(apply(osc("sine", 1244.0, n), env_ad(n, 0.002, 0.5, 3.0)), 0.2))
    thud = gain(apply(sweep("sine", 150.0, 45.0, int(0.3 * SR), 1.6),
                      env_ad(int(0.3 * SR), 0.001, 0.3, 2.0)), 0.6)
    return normalize(mix(ring, concat(thud, silence(0.6))), 0.9)


def s_vault():
    n = int(0.35 * SR)
    whoosh = gain(apply(lowpass(noise(n), 0.28), env_adsr(n, 0.02, 0.06, 0.5, 0.22)), 0.5)
    thud = gain(apply(sweep("sine", 180.0, 70.0, int(0.15 * SR), 1.5),
                      env_ad(int(0.15 * SR), 0.001, 0.15, 2.0)), 0.7)
    return normalize(concat(whoosh[:int(0.20 * SR)], thud), 0.85)


def s_window_break():
    out = []
    for k in range(10):
        seg = apply(highpass(noise(int(0.09 * SR)), 0.82), env_ad(int(0.09 * SR), 0.0003, 0.09, 3.2))
        out.append(gain(seg, 0.8 - k * 0.06))
        out.append(silence(0.012 + k * 0.004))
    return normalize(concat(*out), 0.9)


def s_locker_enter():
    n = int(0.5 * SR)
    clank = gain(apply(highpass(noise(n), 0.6), env_ad(n, 0.001, 0.1, 3.0)), 0.7)
    boom = gain(apply(sweep("sine", 130.0, 55.0, n, 1.6), env_ad(n, 0.002, 0.5, 2.0)), 0.8)
    return normalize(mix(clank, boom), 0.9)


def s_locker_exit():
    n = int(0.45 * SR)
    creak = []
    for k in range(4):
        seg = apply(highpass(noise(int(0.07 * SR)), 0.66), env_ad(int(0.07 * SR), 0.01, 0.07, 2.0))
        creak.append(gain(seg, 0.35 - k * 0.03))
        creak.append(silence(0.03))
    bang = gain(apply(sweep("sine", 160.0, 60.0, int(0.25 * SR), 1.6),
                      env_ad(int(0.25 * SR), 0.001, 0.25, 2.0)), 0.8)
    return normalize(concat(concat(*creak), bang), 0.9)


def s_locker_grab():
    return normalize(concat(s_locker_exit(), gain(s_scream(180.0, 0.6), 0.7)), 0.95)


def s_gate_switch():
    n = int(0.9 * SR)
    motor = gain(lowpass(mix(osc("saw", 74.0, n, detune=0.02), osc("sine", 148.0, n)), 0.3),
                 [0.5 for _ in range(n)])
    e = env_adsr(n, 0.05, 0.1, 0.8, 0.3)
    spark = []
    for k in range(5):
        seg = apply(highpass(noise(int(0.03 * SR)), 0.85), env_ad(int(0.03 * SR), 0.0003, 0.03, 3.0))
        spark.append(gain(seg, 0.3))
        spark.append(silence(0.12))
    return normalize(mix(apply(motor, e), concat(*spark)), 0.8)


def s_gate_open():
    n = int(2.6 * SR)
    rumble = gain(lowpass(mix(osc("saw", 46.0, n, detune=0.03), osc("sine", 92.0, n)), 0.25), 0.9)
    e = env_adsr(n, 0.3, 0.3, 0.85, 0.8)
    squeal = gain(apply(sweep("sine", 320.0, 780.0, n, 1.8), env_ad(n, 0.6, 2.6, 1.6)), 0.18)
    return normalize(mix(apply(rumble, e), squeal), 0.9)


def s_hatch_open():
    n = int(1.1 * SR)
    stone = gain(apply(lowpass(noise(n), 0.18), env_adsr(n, 0.02, 0.2, 0.6, 0.5)), 0.7)
    sub = gain(apply(sweep("sine", 90.0, 36.0, n, 1.4), env_ad(n, 0.01, 1.1, 1.8)), 0.9)
    return normalize(mix(stone, sub), 0.9)


def s_hatch_enter():
    n = int(1.4 * SR)
    drop = gain(apply(sweep("sine", 400.0, 60.0, n, 2.2), env_ad(n, 0.02, 1.4, 1.6)), 0.8)
    air = gain(apply(lowpass(noise(n), 0.3), env_adsr(n, 0.05, 0.2, 0.5, 0.6)), 0.45)
    return normalize(mix(drop, air), 0.9)


def s_trap_place():
    n = int(0.4 * SR)
    metal = gain(apply(highpass(noise(n), 0.62), env_ad(n, 0.001, 0.12, 3.0)), 0.7)
    clink = gain(apply(osc("sine", 1180.0, n), env_ad(n, 0.001, 0.35, 3.4)), 0.35)
    return normalize(mix(metal, clink), 0.85)


def s_trap_snap():
    n = int(0.5 * SR)
    snap = gain(apply(highpass(noise(n), 0.7), env_ad(n, 0.0003, 0.06, 3.6)), 1.0)
    spring = gain(apply(sweep("sq", 1800.0, 260.0, int(0.18 * SR), 1.8),
                        env_ad(int(0.18 * SR), 0.0005, 0.18, 2.6)), 0.45)
    tail = gain(apply(osc("sine", 640.0, n), env_ad(n, 0.002, 0.5, 2.8)), 0.3)
    return normalize(mix(concat(snap[:int(0.3 * SR)], silence(0.2)), spring, tail), 0.95)


def s_trap_escape():
    out = []
    for k in range(4):
        seg = apply(highpass(noise(int(0.09 * SR)), 0.6), env_ad(int(0.09 * SR), 0.001, 0.09, 2.4))
        out.append(gain(seg, 0.6 - k * 0.08))
        out.append(silence(0.05))
    out.append(gain(apply(osc("sine", 900.0, int(0.3 * SR)), env_ad(int(0.3 * SR), 0.002, 0.3, 3.0)), 0.4))
    return normalize(concat(*out), 0.85)


def s_chest_open():
    n = int(0.9 * SR)
    creak = gain(apply(highpass(noise(n), 0.55), env_adsr(n, 0.1, 0.2, 0.7, 0.3)), 0.4)
    latch = gain(apply(osc("sine", 760.0, n), env_ad(n, 0.001, 0.2, 3.2)), 0.35)
    return normalize(mix(creak, latch), 0.8)


def s_footstep(base=180.0, lp=0.5, dur=0.13):
    n = int(dur * SR)
    body = gain(apply(lowpass(noise(n), lp), env_ad(n, 0.0008, dur, 2.6)), 1.0)
    tick = gain(apply(highpass(noise(n), 0.7), env_ad(n, 0.0003, 0.03, 3.4)), 0.4)
    return normalize(mix(body, tick), 0.55)


def s_heal_loop():
    n = int(1.0 * SR)
    a = gain(osc("sine", 330.0, n), 0.35)
    b = gain(osc("sine", 495.0, n), 0.18)
    wob = [0.6 + 0.4 * math.sin(2 * math.pi * 1.6 * i / SR) for i in range(n)]
    return make_loop(normalize(apply(mix(a, b), wob), 0.5))


def s_heal_done():
    return normalize(concat(_blip(659, 0.12), _blip(880, 0.22, "sine", 0.9)), 0.7)


def s_ui_click():
    return normalize(mix(_blip(1180, 0.045, "sq", 0.4), _blip(1760, 0.03, "sine", 0.3)), 0.55)


def s_ui_hover():
    return normalize(_blip(940, 0.035, "sine", 0.5), 0.35)


def s_ui_back():
    return normalize(concat(_blip(720, 0.05, "tri", 0.6), _blip(520, 0.09, "tri", 0.6)), 0.55)


def s_ui_error():
    n = int(0.3 * SR)
    return normalize(concat(_blip(220, 0.12, "sq", 0.5), _blip(180, 0.16, "sq", 0.5)), 0.6)


def s_tier_up():
    out = []
    for f in (523, 659, 784, 1046):
        out.append(_blip(f, 0.11, "tri", 0.7))
    return normalize(concat(*out), 0.75)


def s_bloodlust():
    n = int(1.6 * SR)
    up = apply(sweep("saw", 90.0, 260.0, n, 2.0), env_adsr(n, 0.2, 0.2, 0.7, 0.5))
    return normalize(lowpass(up, 0.4), 0.8)


def s_chase_start():
    n = int(0.9 * SR)
    a = gain(apply(osc("saw", 110.0, n, detune=0.01), env_ad(n, 0.002, 0.9, 2.0)), 0.7)
    b = gain(apply(osc("saw", 116.5, n), env_ad(n, 0.002, 0.7, 2.2)), 0.5)
    hit_ = gain(apply(highpass(noise(n), 0.7), env_ad(n, 0.0005, 0.12, 3.0)), 0.8)
    return normalize(mix(a, b, hit_), 0.95)


def s_chase_end():
    n = int(0.8 * SR)
    down = apply(sweep("tri", 440.0, 110.0, n, 1.6), env_adsr(n, 0.01, 0.2, 0.4, 0.5))
    return normalize(down, 0.7)


def s_mori():
    n = int(2.0 * SR)
    sub = gain(apply(sweep("sine", 70.0, 28.0, n, 1.4), env_ad(n, 0.05, 2.0, 1.6)), 1.0)
    scr = gain(s_scream(230.0, 1.2)[:n], 0.5)
    return normalize(mix(sub, scr), 1.0)


def s_ambient_wind():
    n = int(3.0 * SR)
    base = lowpass(noise(n), 0.02)
    shape = [0.55 + 0.45 * math.sin(2 * math.pi * 0.18 * i / SR + 0.6 * math.sin(2 * math.pi * 0.07 * i / SR))
             for i in range(n)]
    return make_loop(normalize(apply(base, shape), 0.4), 120)


def s_ambient_drone():
    n = int(4.0 * SR)
    a = osc("sine", 55.0, n, detune=0.004)
    b = osc("sine", 82.5, n, detune=0.006)
    c = osc("tri", 110.0, n)
    sig = mix(gain(a, 0.6), gain(b, 0.3), gain(c, 0.12))
    return make_loop(normalize(lowpass(sig, 0.2), 0.5), 150)


# --- music beds -------------------------------------------------------------
A_MINOR = [220.00, 246.94, 261.63, 329.63, 349.23, 440.00, 523.25, 587.33]
CHASE_SCALE = [146.83, 155.56, 174.61, 196.00, 207.65, 233.08, 261.63, 293.66]


def _seq(notes, beat, wave="tri", amp=0.5, detune=0.0):
    out = []
    for i, f in enumerate(notes):
        if f is None:
            out.append(silence(beat))
            continue
        n = int(beat * SR)
        v = osc(wave, f, n, detune=detune)
        e = env_adsr(n, beat * 0.05, beat * 0.25, 0.55, beat * 0.55)
        out.append(gain(apply(v, e), amp))
    return concat(*out)


def _pad(freqs, dur, amp=0.3):
    n = int(dur * SR)
    sig = mix(*[gain(osc("saw", f, n, detune=0.008), amp / max(1, len(freqs))) for f in freqs])
    e = env_adsr(n, dur * 0.25, dur * 0.2, 0.7, dur * 0.4)
    return lowpass(apply(sig, e), 0.35)


def s_music_menu():
    """Slow, dread-soaked menu bed: a low pad under a sparse minor motif."""
    beat = 0.55
    pad1 = _pad([55.0, 82.5], 8.8, 0.30)
    pad2 = _pad([65.41, 98.0], 8.8, 0.22)
    motif = _seq([A_MINOR[0], None, A_MINOR[2], None, A_MINOR[1], None, A_MINOR[4],
                  None, A_MINOR[0], None, A_MINOR[5], None, A_MINOR[3], None, None, None],
                 beat, "tri", 0.22)
    bell = []
    for k in range(10):
        f = A_MINOR[(k * 3) % len(A_MINOR)] * 2
        bell.append(gain(apply(osc("sine", f, int(0.5 * SR)),
                               env_ad(int(0.5 * SR), 0.002, 0.5, 3.0)), 0.10))
        bell.append(silence(beat * 1.6))
    pad = concat(pad1, pad2)
    n = max(len(pad), len(motif), len(concat(*bell)))
    out = [0.0] * n
    for s in (pad, motif, concat(*bell)):
        for i, v in enumerate(s):
            out[i] += v
    return make_loop(normalize(out, 0.55), 200)


def s_music_chase():
    """Driving chase bed: pulsing bass eighth-notes with a rising stinger."""
    beat = 0.26
    bass_line = [CHASE_SCALE[0], CHASE_SCALE[0], CHASE_SCALE[3], CHASE_SCALE[0],
                 CHASE_SCALE[5], CHASE_SCALE[5], CHASE_SCALE[3], CHASE_SCALE[2]] * 4
    bass = _seq([f / 2.0 for f in bass_line], beat, "saw", 0.42, detune=0.01)
    lead_line = [None, CHASE_SCALE[4], None, CHASE_SCALE[6], None, CHASE_SCALE[5], None, CHASE_SCALE[7]] * 4
    lead = _seq(lead_line, beat, "sq", 0.16)
    perc = []
    for k in range(32):
        n = int(beat * SR)
        if k % 4 == 0:
            seg = gain(apply(sweep("sine", 120.0, 45.0, n, 1.6), env_ad(n, 0.001, beat, 2.4)), 0.6)
        else:
            seg = gain(apply(highpass(noise(int(beat * 0.4 * SR)), 0.8),
                             env_ad(int(beat * 0.4 * SR), 0.0005, beat * 0.4, 3.0)), 0.22)
            seg = concat(seg, silence(beat * 0.6))
        perc.append(seg)
    n = max(len(bass), len(lead), len(concat(*perc)))
    out = [0.0] * n
    for s in (bass, lead, concat(*perc)):
        for i, v in enumerate(s):
            out[i] += v
    return make_loop(normalize(out, 0.62), 120)


def s_music_calm():
    """Quiet exploration bed used when nothing is happening."""
    beat = 0.75
    pad = _pad([73.42, 110.0, 146.83], 9.0, 0.24)
    mel = _seq([A_MINOR[4], None, A_MINOR[5], None, A_MINOR[4], None, A_MINOR[2], None,
                A_MINOR[1], None, A_MINOR[2], None], beat, "sine", 0.18)
    n = max(len(pad), len(mel))
    out = [0.0] * n
    for s in (pad, mel):
        for i, v in enumerate(s):
            out[i] += v
    return make_loop(normalize(out, 0.45), 220)


SOUNDS = {
    "heartbeat": lambda: s_heartbeat(1.0),
    "heartbeat_fast": lambda: s_heartbeat(2.0),
    "gen_loop": s_gen_loop,
    "gen_done": s_gen_done,
    "gen_explode": s_gen_explode,
    "skillcheck_appear": s_skillcheck_appear,
    "skillcheck_good": s_skillcheck_good,
    "skillcheck_great": s_skillcheck_great,
    "skillcheck_miss": s_skillcheck_miss,
    "hit": s_hit,
    "hit_heavy": s_hit_heavy,
    "scream_m": s_scream_m,
    "scream_f": s_scream_f,
    "hook": s_hook,
    "unhook": s_unhook,
    "sacrifice": s_sacrifice,
    "pallet_drop": s_pallet_drop,
    "pallet_break": s_pallet_break,
    "pallet_stun": s_pallet_stun,
    "vault": s_vault,
    "window_break": s_window_break,
    "locker_enter": s_locker_enter,
    "locker_exit": s_locker_exit,
    "locker_grab": s_locker_grab,
    "gate_switch": s_gate_switch,
    "gate_open": s_gate_open,
    "hatch_open": s_hatch_open,
    "hatch_enter": s_hatch_enter,
    "trap_place": s_trap_place,
    "trap_snap": s_trap_snap,
    "trap_escape": s_trap_escape,
    "chest_open": s_chest_open,
    "footstep_grass": lambda: s_footstep(180.0, 0.45),
    "footstep_wood": lambda: s_footstep(220.0, 0.55, 0.11),
    "footstep_dirt": lambda: s_footstep(150.0, 0.35, 0.14),
    "heal_loop": s_heal_loop,
    "heal_done": s_heal_done,
    "ui_click": s_ui_click,
    "ui_hover": s_ui_hover,
    "ui_back": s_ui_back,
    "ui_error": s_ui_error,
    "tier_up": s_tier_up,
    "bloodlust": s_bloodlust,
    "chase_start": s_chase_start,
    "chase_end": s_chase_end,
    "mori": s_mori,
    "ambient_wind": s_ambient_wind,
    "ambient_drone": s_ambient_drone,
    "music_menu": s_music_menu,
    "music_chase": s_music_chase,
    "music_calm": s_music_calm,
}


def write_wav(name, samples):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name + ".wav")
    data = array.array("h", [int(max(-32767, min(32767, v * 32767))) for v in samples])
    if sys.byteorder == "big":
        data.byteswap()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    return len(samples) / float(SR)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    wanted = [s.strip() for s in args.only.split(",") if s.strip()]

    seed(20260925)
    total = 0.0
    for name in sorted(SOUNDS.keys()):
        if wanted and name not in wanted:
            continue
        try:
            sig = SOUNDS[name]()
        except Exception as exc:  # keep going, report clearly
            print("   !! %-22s FAILED: %s" % (name, exc))
            continue
        # Looping beds must not be faded at the edges or the loop dips.
        looping = (name.startswith("music_") or name.startswith("ambient_")
                   or name.endswith("_loop"))
        dur = write_wav(name, sig if looping else fade_edges(sig, 4))
        total += dur
        print("   %-22s %6.2f s%s" % (name, dur, "  [loop]" if looping else ""))
    print("[gen_audio] wrote %d files, %.1f s of audio" % (len(SOUNDS), total))


if __name__ == "__main__":
    main()
